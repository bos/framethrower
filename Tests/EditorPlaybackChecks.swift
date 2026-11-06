@preconcurrency import AVFoundation
import Foundation

private enum PlaybackCheckError: Error { case failed(String), cancelled }

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PlaybackCheckError.failed(message) }
}

/// Deliberately ignores cancellation until finish() is called. Real decoder
/// cancellation also completes asynchronously, so a new request must wait.
@MainActor
private final class DecoderProbe {
    var started: [Int] = []
    var cancelled: [Int] = []
    var delivered: [Int] = []
    var failed: [Int] = []
    var maximumActive = 0
    private var continuations: [Int: CheckedContinuation<Int, any Error>] = [:]

    func generate(_ id: Int) async throws -> Int {
        started.append(id)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            maximumActive = max(maximumActive, continuations.count)
        }
    }

    func finish(_ id: Int, fails: Bool = false) throws {
        guard let continuation = continuations.removeValue(forKey: id) else {
            throw PlaybackCheckError.failed("request \(id) was not active")
        }
        if fails { continuation.resume(throwing: PlaybackCheckError.cancelled) }
        else { continuation.resume(returning: id) }
    }

    func submit(_ id: Int, to queue: LatestStillFrameQueue<Int>, policy: LatestStillFrameQueue<Int>.Policy = .latestOnly) {
        queue.request(generate: { try await self.generate(id) },
                      cancel: { self.cancelled.append(id) },
                      receive: { self.delivered.append($0) },
                      failure: { self.failed.append(id) }, policy: policy)
    }
}

@main
struct EditorPlaybackChecks {
    @MainActor
    private static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @MainActor
    static func main() async throws {
        let queue = LatestStillFrameQueue<Int>()
        let decoder = DecoderProbe()
        decoder.submit(1, to: queue)
        await settle()
        try require(decoder.started == [1], "initial decode did not start")
        for id in 2...1000 { decoder.submit(id, to: queue) }
        await settle()
        try require(decoder.started == [1], "scrubbing spawned overlapping decoder work")
        try require(decoder.cancelled == [1], "active decoder cancellation should happen once")
        try decoder.finish(1)
        await settle()
        try require(decoder.delivered.isEmpty, "obsolete frame was delivered")
        try require(decoder.started == [1, 1000], "pending seeks were not coalesced to newest frame")
        try decoder.finish(1000)
        await settle()
        try require(decoder.delivered == [1000], "latest frame did not arrive")
        try require(decoder.maximumActive == 1, "more than one decoder was active")

        // Rebuild/play/close all invalidate through the same path. An old
        // operation that succeeds despite cancellation must still be discarded.
        decoder.submit(1001, to: queue)
        await settle()
        decoder.submit(1002, to: queue)
        queue.invalidate()
        try decoder.finish(1001)
        await settle()
        try require(decoder.started == [1, 1000, 1001], "invalidated pending work was started")
        try require(decoder.delivered == [1000], "invalidated frame was delivered")
        decoder.submit(1003, to: queue)
        await settle()
        decoder.submit(1004, to: queue)
        try decoder.finish(1003, fails: true)
        await settle()
        try require(decoder.started.last == 1004, "decode failure prevented newest request")
        try decoder.finish(1004)
        await settle()
        try require(decoder.delivered == [1000, 1004], "queue did not recover after cancellation failure")
        try require(decoder.failed.isEmpty, "obsolete decoder error reached current preview")

        // Invalidation also suppresses work that has not reached the worker yet.
        decoder.submit(1005, to: queue)
        queue.invalidate()
        await settle()
        try require(!decoder.started.contains(1005), "queued decode survived immediate close")
        decoder.submit(1006, to: queue)
        await settle()
        try decoder.finish(1006, fails: true)
        await settle()
        try require(decoder.failed == [1006], "current decode error did not clear the stale preview")

        let liveQueue = LatestStillFrameQueue<Int>()
        let live = DecoderProbe()
        live.submit(1, to: liveQueue, policy: .coalesced)
        await settle()
        for id in 2...1000 { live.submit(id, to: liveQueue, policy: .coalesced) }
        try require(live.cancelled.isEmpty, "continuous draft gestures cancelled every active frame")
        try live.finish(1)
        await settle()
        try require(live.delivered == [1] && live.started == [1, 1000],
                    "live gesture did not display progress while coalescing pending work")
        live.submit(1001, to: liveQueue)
        try live.finish(1000)
        await settle()
        try require(live.delivered == [1], "stale draft survived a newer committed/seek request")
        try live.finish(1001)
        await settle()
        live.submit(1002, to: liveQueue, policy: .coalesced)
        await settle()
        liveQueue.invalidate()
        try live.finish(1002)
        await settle()
        try require(live.delivered == [1, 1001] && live.maximumActive == 1,
                    "draft cancellation leaked stale frames or overlapping decoders")

        let range = 1.0...1.01 // Shorter than a 30 fps frame, with a nonzero in point.
        let end = EditorPlayback.frameTime(at: range.upperBound, bounds: range).seconds
        try require(end >= range.lowerBound && end < range.upperBound,
                    "sub-frame trim must seek inside retained interval")
        try require(end > 1.009, "end seek jumped back to trim start")
        try require(EditorPlayback.frameTime(at: -100, bounds: range).seconds == range.lowerBound,
                    "seek before trim start was not clamped")
        try require(EditorPlayback.frameTime(at: .nan, bounds: range).seconds == range.lowerBound,
                    "non-finite seek was not clamped")
        let ordinary = EditorPlayback.frameTime(at: 3, bounds: 0...10).seconds
        try require(abs(ordinary - 3) < 0.000001, "ordinary seek position changed")
        let fractionalEnd = EditorPlayback.frameTime(at: 1.0 / 30, bounds: 0...(1.0 / 30)).seconds
        try require(fractionalEnd >= 0 && fractionalEnd < 1.0 / 30,
                    "fractional media end must remain exclusive")

        try await draftPreviewChecks()
        try await scrubbingChecks()

        let playback = EditorPlayback()
        playback.close()
        playback.seek(10)
        playback.togglePlayback()
        playback.close()
        try require(playback.stillFrame == nil && !playback.isPlaying && !playback.isLoading,
                    "closed player accepted new playback work")
        print("Editor playback checks passed (bounded scrubbing/drafts, live camera pixels, cancel/commit, lifecycle invalidation, and exclusive bounds).")
    }

    @MainActor
    private static func draftPreviewChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-draft-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = directory.appendingPathComponent("screen.mov")
        let camera = directory.appendingPathComponent("camera.mov")
        try await movie(to: screen, width: 160, height: 120, camera: false)
        try await movie(to: camera, width: 80, height: 40, camera: true)
        let originalScreen = try Data(contentsOf: screen)
        let originalCamera = try Data(contentsOf: camera)
        var project = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", duration: 2)
        project.state.pipKeyframes[0].placement = PIPPlacement(x: 0, y: 0, scale: 0.25)
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "test project save")
        let originalProject = try Data(contentsOf: editor.url)
        let playback = EditorPlayback()
        defer { playback.close() }
        await playback.rebuild(editor: editor)
        _ = try await waitForFrame(playback, expected: CGRect(x: 0, y: 0, width: 40, height: 20))
        let item = playback.player.currentItem
        let position = playback.time
        let size = playback.screenSize
        let aspect = playback.cameraAspect
        var draft = project.state
        var parentChanges = 0
        var imageChanges = 0
        let parentObservation = playback.objectWillChange.sink { parentChanges += 1 }
        let imageObservation = playback.frameStore.objectWillChange.sink { imageChanges += 1 }
        playback.preview(draft)
        _ = try await waitForFrame(playback, expected: CGRect(x: 0, y: 0, width: 40, height: 20))
        await settle()
        parentChanges = 0
        imageChanges = 0
        // Simulate a burst of changed events. Only accepted worker items create
        // decoders, while the latest event must eventually move the actual PIP.
        for step in 0..<100 {
            draft.pipKeyframes[0].placement.x = Double(step) / 99
            draft.pipKeyframes[0].placement.y = Double(step) / 99
            playback.preview(draft)
        }
        _ = try await waitForFrame(playback, expected: CGRect(x: 120, y: 100, width: 40, height: 20))
        try require(parentChanges == 0 && imageChanges > 0,
                    "draft pixels invalidated the parent playback/layout observable")
        parentObservation.cancel()
        imageObservation.cancel()
        try require(playback.isPreviewing && !playback.isLoading && !playback.isPlaying,
                    "live gesture entered durable/loading playback state")
        try require(playback.player.currentItem === item && playback.time == position,
                    "live gesture replaced the player or moved its playhead")
        try require(playback.screenSize == size && playback.cameraAspect == aspect,
                    "live gesture changed source geometry")
        let unchangedProject = try Data(contentsOf: editor.url)
        try require(unchangedProject == originalProject && editor.project == project,
                    "draft gesture mutated the durable edit or undo history")
        playback.cancelPreview()
        _ = try await waitForFrame(playback, expected: CGRect(x: 0, y: 0, width: 40, height: 20))
        try require(!playback.isPreviewing, "cancel did not leave draft mode")

        draft.pipKeyframes[0].placement.scale = 0.4
        draft.pipKeyframes[0].placement.shape = .square
        playback.preview(draft)
        let displayedDraft = try await waitForFrame(playback, expected: CGRect(x: 96, y: 56, width: 64, height: 64))
        try require(editor.commit(draft, name: "Move and resize camera"), "commit of draft gesture failed")
        let rebuilding = Task { @MainActor in await playback.rebuild(editor: editor) }
        await settle()
        try require(playback.stillFrame != nil, "release flashed away the displayed draft during rebuild")
        if playback.isLoading {
            try require(playback.stillFrame === displayedDraft, "release replaced the live draft with an obsolete frame")
        }
        await rebuilding.value
        _ = try await waitForFrame(playback, expected: CGRect(x: 96, y: 56, width: 64, height: 64))
        try require(!playback.isPreviewing && editor.project.undoHistory.count == 1,
                    "gesture did not become exactly one durable edit")

        var rejected = draft
        rejected.pipKeyframes[0].placement = PIPPlacement(x: 0, y: 0, scale: 0.25)
        playback.preview(rejected)
        playback.cancelPreview()
        _ = try await waitForFrame(playback, expected: CGRect(x: 96, y: 56, width: 64, height: 64))
        playback.preview(rejected)
        playback.togglePlayback()
        try require(!playback.isPreviewing && playback.stillFrame == nil,
                    "stale draft overlay survived playback")
        playback.pause()
        _ = try await waitForFrame(playback, expected: CGRect(x: 96, y: 56, width: 64, height: 64))
        playback.preview(rejected)
        playback.close()
        try await Task.sleep(for: .milliseconds(100))
        try require(!playback.isPreviewing && playback.stillFrame == nil,
                    "in-flight draft survived close")
        let screenAfter = try Data(contentsOf: screen)
        let cameraAfter = try Data(contentsOf: camera)
        try require(screenAfter == originalScreen && cameraAfter == originalCamera,
                    "draft preview changed original captured media")
    }

    @MainActor
    private static func scrubbingChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-scrub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await movie(to: directory.appendingPathComponent("screen.mov"), width: 1920, height: 1080, camera: false)
        try await movie(to: directory.appendingPathComponent("camera.mov"), width: 640, height: 360, camera: true)
        var project = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", duration: 2)
        project.state.pipKeyframes[0].placement = PIPPlacement(x: 0, y: 0, scale: 0.25)
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("scrub.framethrower"))
        let playback = EditorPlayback()
        defer { playback.close() }
        await playback.rebuild(editor: editor)
        _ = try await waitForFrame(playback, expected: CGRect(x: 0, y: 0, width: 480, height: 270))
        guard let item = playback.player.currentItem else { throw PlaybackCheckError.failed("missing native player item") }
        try require(item.seekingWaitsForVideoCompositionRendering,
                    "native seek timing must wait for custom-composed frames before chasing the next target")
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.suppressesPlayerRendering = true
        item.add(output)
        defer { item.remove(output) }
        playback.beginScrubbing()
        var displayedColors = Set<UInt8>()
        var displayedFrames = Set<Int>()
        let target = 1.79
        for step in 0..<30 {
            let seconds = 0.05 + Double(step) * 0.06
            playback.scrub(to: seconds)
            try require(abs(playback.time - seconds) < 0.000_001,
                        "native chase overwrote the requested timeline position")
            try await Task.sleep(for: .milliseconds(16))
            try require(playback.isScrubbing && playback.stillFrame == nil,
                        "a stale still covered native video during active scrubbing")
            let requested = playback.player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: requested) {
                var displayed = CMTime.invalid
                if let buffer = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayed) {
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let offset = 540 * CVPixelBufferGetBytesPerRow(buffer) + 960 * 4
                    displayedColors.insert(bytes[offset + 2])
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    if displayed.seconds.isFinite { displayedFrames.insert(Int((displayed.seconds * 30).rounded())) }
                }
            }
        }
        try require(displayedColors.count >= 3 && displayedFrames.count >= 3,
                    "native video remained frozen before mouse-up (colors=\(displayedColors.count), frames=\(displayedFrames.count))")
        playback.endScrubbing()
        let deadline = Date().addingTimeInterval(5)
        while playback.isScrubbing && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try require(!playback.isScrubbing, "final chasing seek never settled")
        try require(abs(playback.player.currentTime().seconds - target) < 0.001,
                    "final native seek missed latest target")
        _ = try await waitForFrame(playback, expected: CGRect(x: 0, y: 0, width: 480, height: 270))
        try require(playback.player.currentItem === item, "scrubbing replaced the native player item")
        playback.beginScrubbing()
        playback.scrub(to: 0.4)
        playback.endScrubbing()
        playback.close()
        try await Task.sleep(for: .milliseconds(50))
        try require(playback.stillFrame == nil && !playback.isScrubbing,
                    "a late native seek restored pixels after close")
        print("Native scrub output changed before mouse-up (\(displayedFrames.count) frame times, \(displayedColors.count) changing source colors).")
    }

    @MainActor
    private static func waitForFrame(_ playback: EditorPlayback, expected: CGRect) async throws -> CGImage {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let frame = playback.stillFrame, let bounds = try cameraBounds(frame),
               abs(bounds.minX - expected.minX) <= 2 && abs(bounds.minY - expected.minY) <= 2,
               abs(bounds.width - expected.width) <= 3 && abs(bounds.height - expected.height) <= 3 {
                return frame
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PlaybackCheckError.failed("live camera pixels did not reach \(expected); error: \(playback.errorMessage ?? "none")")
    }

    private static func cameraBounds(_ image: CGImage) throws -> CGRect? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PlaybackCheckError.failed("pixel context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = (y * image.width + x) * 4
                if (bytes[index] > 150 || bytes[index + 1] > 150) && bytes[index + 2] < 100 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @MainActor
    private static func movie(to url: URL, width: Int, height: Int, camera: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PlaybackCheckError.failed("fixture writer") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<60 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else {
                    throw writer.error ?? PlaybackCheckError.failed("fixture encoder stalled")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      nil, &buffer) == kCVReturnSuccess, let buffer else {
                throw PlaybackCheckError.failed("fixture pixel buffer")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let pixels = base.advanced(by: y * row).assumingMemoryBound(to: UInt32.self)
                if camera {
                    pixels.initialize(repeating: 0xff00ff00, count: width / 2)
                    pixels.advanced(by: width / 2).initialize(repeating: 0xffff0000, count: width - width / 2)
                } else {
                    pixels.initialize(repeating: 0xff0000ff | UInt32(index * 2) << 16, count: width)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? PlaybackCheckError.failed("fixture frame append")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? PlaybackCheckError.failed("fixture finalization") }
    }

}
