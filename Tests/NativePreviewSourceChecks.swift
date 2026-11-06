@preconcurrency import AVFoundation
import AppKit
import CoreImage
import Foundation

/// Validates the editor's native-source path without AVAssetImageGenerator,
/// capture hardware, permissions, accounts, or images written to disk.
@main
@MainActor
struct NativePreviewSourceChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            FileHandle.standardError.write(Data("Native preview source check timed out.\n".utf8))
            exit(1)
        }
        defer { watchdog.cancel() }
        try ownershipChecks()
        if CommandLine.arguments.contains("--ownership-only") {
            print("Native preview source ownership checks passed (explicit targets, closest-frame retention, zero-distance reuse, invalidation, detached sinks, and no ownership cycles).")
            return
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-native-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await EditorMovieFixtures.make(at: directory.appendingPathComponent("screen.mp4"),
                                           width: 1920, height: 1080, duration: 3, camera: false)
        try await EditorMovieFixtures.make(at: directory.appendingPathComponent("camera.mp4"),
                                           width: 640, height: 360, duration: 3, camera: true)
        let cursor = CursorRecording(duration: 3, logicalWidth: 1920, logicalHeight: 1080,
            samples: [CursorSample(time: 0, x: 0.6, y: 0.4), CursorSample(time: 3, x: 0.6, y: 0.4)],
            clicks: [CursorClick(time: 1, x: 0.6, y: 0.4, button: 0)])
        try cursor.write(to: directory.appendingPathComponent("cursor.json"))
        var project = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mp4",
                                       cursorFilename: "cursor.json", duration: 3)
        project.state.pipKeyframes[0].placement.shape = .circle
        project.state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 1.5, x: 0.6, y: 0.5)]
        project.state.cursorStyle.size = 3
        let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
        let initial = CMTime(seconds: 1, preferredTimescale: 600)
        rendered.previewFrames.request(at: initial) // before initial preroll
        let item = AVPlayerItem(asset: rendered.asset)
        item.videoComposition = rendered.videoComposition
        item.seekingWaitsForVideoCompositionRendering = true
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.suppressesPlayerRendering = true
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer {
            player.pause()
            item.remove(output)
            player.replaceCurrentItem(with: nil)
        }
        let deadline = Date().addingTimeInterval(8)
        while item.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try require(item.status == .readyToPlay, "native player is ready")
        var previousSources: LivePreviewSources?
        for seconds in [1.0, 1.5, 0.5] {
            let target = CMTime(seconds: seconds, preferredTimescale: 600)
            rendered.previewFrames.request(at: target)
            let completed = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            try require(completed, "native seek completes after custom frame rendering")
            let deadline = Date().addingTimeInterval(3)
            var nativePixels: [UInt8]?
            while nativePixels == nil, Date() < deadline {
                var display = CMTime.invalid
                if let buffer = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: &display),
                   display.seconds.isFinite, abs(display.seconds - seconds) < 1.0 / 30 + 0.001 {
                    nativePixels = try rgba(buffer)
                } else { try await Task.sleep(for: .milliseconds(5)) }
            }
            guard let nativePixels else { throw Failure.failed("native output pixels arrive at \(seconds)") }
            guard let sources = rendered.previewFrames.sources(at: target) else {
                throw Failure.failed("native compositor retained no source pair at \(seconds)")
            }
            if let previousSources { try require(previousSources !== sources, "new playhead replaces the prior frozen source pair") }
            previousSources = sources
            let nativeFirst = try await ProjectRenderer.prepareLiveSources(rendered, at: target)
            try require(nativeFirst === sources, "preparation reuses native sources without creating an image generator")
            guard let camera = try await sources.cameraImage() else { throw Failure.failed("native camera source is available for framing") }
            try require(camera.width == 640 && camera.height == 360, "framing uses full oriented camera source, without widget crop")
            let frozen = try await ProjectRenderer.renderLivePreview(sources, applying: project.state)
            try require(frozen.width == 1920 && frozen.height == 1080, "frozen preview preserves stable output dimensions")
            let difference = zip(nativePixels, try rgba(frozen)).map { abs(Int($0) - Int($1)) }.max() ?? 0
            try require(difference <= 2, "frozen native source rendering matches actual playback pixels: max delta \(difference)")
            var draft = project.state
            draft.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 2.2, x: 0.7, y: 0.6)]
            draft.pipKeyframes[0].placement.x = 0.05
            draft.pipKeyframes[0].placement.scale = 0.35
            draft.pipKeyframes[0].placement.sourceZoom = 2
            draft.cursorStyle.size = 4
            let changed = try await ProjectRenderer.renderLivePreview(sources, applying: draft)
            try require(try rgba(changed) != nativePixels, "zoom/pan/PIP/pointer drafts visibly update from the native source pair")
            rendered.previewFrames.request(at: target)
            try require(rendered.previewFrames.sources(at: target) === sources,
                        "zero-distance seek preserves native source snapshot when player skips a rerender")
            try require(item.error == nil && player.error == nil, "native path has no item/player errors")
        }
        print("Native preview source checks passed (bounded ownership/time matching, no cycles, 1080p native pixel parity, and live zoom/PIP/cursor drafts without image generators).")
    }

    private static func ownershipChecks() throws {
        var buffer: CVPixelBuffer?
        try require(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA,
                                       nil, &buffer) == kCVReturnSuccess, "test source buffer")
        guard let buffer else { throw Failure.failed("test buffer exists") }
        let store = PreviewSourceFrames()
        let instruction = PIPCompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600)),
            screenTrackID: 1, cameraTrackID: nil,
            screenGeometry: PIPSourceGeometry(size: CGSize(width: 2, height: 2), transform: .identity),
            cameraGeometry: nil, renderSize: CGSize(width: 2, height: 2), cameraStart: 0, cameraEnd: 0,
            state: EditState(trimStart: 0, trimEnd: 3, pipKeyframes: []), previewFrames: store)
        let target = CMTime(seconds: 1, preferredTimescale: 600)
        store.capture(screen: buffer, camera: nil, at: target, instruction: instruction)
        try require(store.sources(at: target) == nil, "exports/unrequested playheads retain no raw source frames")
        store.request(at: target)
        store.capture(screen: buffer, camera: nil, at: .zero, instruction: instruction)
        try require(store.sources(at: target) == nil, "distant prefetched frames cannot populate the requested playhead")
        store.capture(screen: buffer, camera: nil, at: CMTime(seconds: 1.02, preferredTimescale: 600), instruction: instruction)
        guard let first = store.sources(at: target) else { throw Failure.failed("nearby requested source pair captured") }
        store.request(at: target)
        try require(store.sources(at: target) === first, "same-time request retains frozen source")
        store.capture(screen: buffer, camera: nil, at: target, instruction: instruction)
        try require(store.sources(at: target) !== first, "closer matching source replaces prior candidate")
        try require(store.sources(at: CMTime(seconds: 1.001, preferredTimescale: 1_000_000)) == nil,
                    "a different requested playhead cannot borrow the old source pair")
        store.request(at: .invalid)
        try require(store.sources(at: target) == nil && store.sources(at: .invalid) == nil, "invalid request releases prior sources")
        try require(instruction.applying(instruction.state).previewFrames === store, "draft instruction preserves project store")
        let focused = FocusedFrameCapture(target: target, frameDuration: CMTime(value: 1, timescale: 30))
        try require(instruction.applying(instruction.state, focusedCapture: focused).previewFrames == nil,
                    "offline generator instructions cannot overwrite native snapshots")
        var owner: PreviewSourceFrames? = PreviewSourceFrames()
        weak let weakOwner = owner
        var ownedInstruction: PIPCompositionInstruction? = PIPCompositionInstruction(timeRange: instruction.timeRange,
            screenTrackID: 1, cameraTrackID: nil, screenGeometry: instruction.screenGeometry,
            cameraGeometry: nil, renderSize: instruction.renderSize, cameraStart: 0, cameraEnd: 0,
            state: instruction.state, previewFrames: owner)
        owner?.request(at: target)
        owner?.capture(screen: buffer, camera: nil, at: target, instruction: ownedInstruction!)
        let retainedSources = owner?.sources(at: target)
        ownedInstruction = nil
        owner = nil
        try require(weakOwner == nil && retainedSources != nil, "detached frozen instructions do not form a store ownership cycle")
    }

    private static func rgba(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        try require(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, "native output uses expected BGRA format")
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw Failure.failed("native output pixel memory") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let source = y * stride + x * 4, destination = (y * width + x) * 4
                bytes[destination] = base[source + 2]; bytes[destination + 1] = base[source + 1]
                bytes[destination + 2] = base[source]; bytes[destination + 3] = base[source + 3]
            }
        }
        return bytes
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.failed("image pixel context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
}
