@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import QuartzCore

/// Exercises the custom compositor through AVPlayer's real streaming playback
/// path. No display, capture permission, camera, or microphone is required.
@main
@MainActor
struct ProjectPlaybackIntegrationChecks {
    private enum CheckError: Error { case failed(String) }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-streaming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await movie(to: directory.appendingPathComponent("screen.mov"), width: 160, height: 120, frames: 90, camera: false)
        try await movie(to: directory.appendingPathComponent("camera.mov"), width: 80, height: 40, frames: 45, camera: true)
        var project = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", cameraOffset: 0.5, duration: 3)
        project.state.pipKeyframes = [
            PIPKeyframe(time: 0, placement: PIPPlacement(x: 0, y: 0, scale: 0.25, shape: .circle)),
            PIPKeyframe(time: 1, placement: PIPPlacement(x: 1, y: 0, scale: 0.25, shape: .rectangle, aspectRatio: 4)),
            PIPKeyframe(time: 1.5, placement: PIPPlacement(x: 0, y: 1, scale: 0.4, shape: .circle, aspectRatio: 1), transition: .smooth, duration: 0.4)
        ]
        let cursor = CursorRecording(duration: 3, logicalWidth: 160, logicalHeight: 120,
            samples: [CursorSample(time: 0, x: 0.7, y: 0.5), CursorSample(time: 3, x: 0.7, y: 0.5)], clicks: [])
        try cursor.write(to: directory.appendingPathComponent("cursor.json"))
        project.cursorFilename = "cursor.json"
        project.state.cursorStyle = CursorStyle(visible: true, size: 1, smoothing: 0.5, clickHighlight: false)
        project.state.zoomKeyframes = [ZoomKeyframe(time: 0),
            ZoomKeyframe(time: 1, scale: 1.8, x: 0.6, y: 0.5, transition: .smooth, duration: 0.4),
            ZoomKeyframe(time: 2, transition: .smooth, duration: 0.4)]
        let delayed = try await play(project, directory: directory, cameraRange: 0.5..<2)
        try require(delayed.cursorFrames >= 65, "real streaming cursor frames track smooth screen zoom/pan")
        try require(delayed.before > 5, "streaming playback emitted frames before delayed camera start")
        try require(delayed.after > 15, "streaming playback continued after camera source ended")
        try require(delayed.circles > 8 && delayed.rectangles >= 2 && delayed.moving >= 5,
                    "playback sampled circle, free rectangle, and smooth transition frames")

        project.cameraOffset = -0.5
        let early = try await play(project, directory: directory, cameraRange: 0..<1)
        try require(early.cursorFrames >= 65, "cursor rendering remains independent of camera source offsets")
        try require(early.circles > 15, "camera that started earlier appears from screen time zero")
        try require(early.after > 35, "early camera end does not freeze or repeat its last frame")
        try await movie(to: directory.appendingPathComponent("late-screen.mov"), width: 160, height: 120, frames: 90, camera: false, firstFrame: 4)
        var delayedScreen = project
        delayedScreen.screenFilename = "late-screen.mov"
        delayedScreen.cameraOffset = 0.5
        delayedScreen.cursorFilename = nil
        let screenGap = try await play(delayedScreen, directory: directory, cameraRange: 0.5..<2, screenStart: 4.0 / 30)
        try require(screenGap.initialScreenGap >= 2, "missing initial video samples render black without failing streaming playback")
        try require(screenGap.circles > 8 && screenGap.after > 15, "playback recovers after initial source gap and continues through camera end")
        print("Project streaming playback checks passed (AVPlayerItemVideoOutput: \(delayed.frames + early.frames + screenGap.frames) frames, delayed/early camera, source gaps, timed circle/rectangle, smooth cursor/zoom motion, missing initial screen samples, and clean item/player status).")
    }

    private struct Counts {
        var frames = 0
        var before = 0
        var after = 0
        var circles = 0
        var rectangles = 0
        var moving = 0
        var initialScreenGap = 0
        var cursorFrames = 0
    }

    private static func play(_ project: RecordingProject, directory: URL, cameraRange: Range<Double>, screenStart: Double = 0) async throws -> Counts {
        let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
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
        player.automaticallyWaitsToMinimizeStalling = false
        defer {
            player.pause()
            item.remove(output)
            player.replaceCurrentItem(with: nil)
        }
        let readyDeadline = Date().addingTimeInterval(5)
        while item.status != .readyToPlay {
            try checkStatus(player, item: item)
            try require(Date() < readyDeadline, "AVPlayerItem became ready before timeout")
            try await Task.sleep(for: .milliseconds(5))
        }
        let seekSucceeded = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        try require(seekSucceeded, "player seeks to the screen-source beginning")
        try require(player.currentTime().seconds < 0.04, "explicit seek retains the recording's beginning")
        let prerollSucceeded = await player.preroll(atRate: 1)
        try require(prerollSucceeded, "streaming player prerolls source frames")
        player.play()
        var counts = Counts()
        var latestFrame = -Double.infinity
        let playbackDeadline = Date().addingTimeInterval(7)
        while latestFrame < project.duration - 0.05 {
            try checkStatus(player, item: item)
            try require(Date() < playbackDeadline,
                        "streaming playback advanced to the final screen frame (last=\(latestFrame), player=\(player.currentTime().seconds), reason=\(String(describing: player.reasonForWaitingToPlay)))")
            let requested = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: requested) {
                var displayTime = CMTime.invalid
                if let buffer = output.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayTime) {
                    let seconds = displayTime.seconds
                    if seconds.isFinite, seconds > latestFrame {
                        latestFrame = seconds
                        counts.frames += 1
                        try validate(buffer, at: seconds, project: project, cameraRange: cameraRange, screenStart: screenStart, counts: &counts)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        player.pause()
        if screenStart > 0 {
            // Chase real paused seeks into/out of the initial sample gap. Seek
            // completion must await custom composition, not only source decode.
            for seconds in [0.05, 1.6, 0.6, 2.8, 0.0] {
                let target = CMTime(seconds: seconds, preferredTimescale: 600)
                let completed = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                try require(completed, "paused custom-composition seek completes")
                var received = false
                let deadline = Date().addingTimeInterval(2)
                while !received, Date() < deadline {
                    var display = CMTime.invalid
                    if let frame = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: &display),
                       display.seconds.isFinite, abs(display.seconds - seconds) <= 1.0 / 30 + 0.001 {
                        var seekCounts = Counts()
                        try validate(frame, at: display.seconds, project: project, cameraRange: cameraRange,
                                     screenStart: screenStart, counts: &seekCounts)
                        received = true
                    }
                    if !received { try await Task.sleep(for: .milliseconds(5)) }
                }
                try require(received, "paused seek delivers a new composed video frame at requested time")
            }
        }
        try checkStatus(player, item: item)
        try require(counts.frames >= 65, "actual AVPlayer output supplied most playback frames")
        return counts
    }

    private static func checkStatus(_ player: AVPlayer, item: AVPlayerItem) throws {
        if let error = player.error { throw CheckError.failed("AVPlayer error: \(error)") }
        if let error = item.error { throw CheckError.failed("AVPlayerItem error: \(error)") }
        try require(item.status != .failed && player.status != .failed, "player and item remain usable")
        let events = item.errorLog()?.events ?? []
        try require(events.isEmpty, "player emitted no streaming errors: \(events.map { $0.errorComment ?? String($0.errorStatusCode) })")
    }

    private static func validate(_ buffer: CVPixelBuffer, at seconds: Double, project: RecordingProject,
                                 cameraRange: Range<Double>, screenStart: Double, counts: inout Counts) throws {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        try require(width == 160 && height == 120, "streaming composition preserves native screen size")
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw CheckError.failed("AVPlayer output has readable pixels")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func green(_ x: Int, _ y: Int) -> Bool {
            let offset = y * stride + x * 4
            return base[offset + 1] > 160 && base[offset + 2] < 100 && base[offset] < 100
        }
        func blue(_ x: Int, _ y: Int) -> Bool {
            let offset = y * stride + x * 4
            return base[offset] > 160 && base[offset + 1] < 100 && base[offset + 2] < 100
        }
        var greenCount = 0, minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where green(x, y) {
                greenCount += 1
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        if seconds < screenStart - 0.005 {
            for y in Swift.stride(from: 0, to: height, by: 10) {
                for x in Swift.stride(from: 0, to: width, by: 10) {
                    let offset = y * stride + x * 4
                    try require(base[offset] < 20 && base[offset + 1] < 20 && base[offset + 2] < 20,
                                "missing initial screen sample is black, not a borrowed future frame")
                }
            }
            counts.initialScreenGap += 1
            return
        }
        if project.cursorFilename != nil, project.state.cursorStyle.visible {
            var whiteMinX = width, whiteMinY = height, whiteMaxX = -1, whiteMaxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    if base[offset] > 180 && base[offset + 1] > 180 && base[offset + 2] > 180 {
                        whiteMinX = min(whiteMinX, x); whiteMinY = min(whiteMinY, y)
                        whiteMaxX = max(whiteMaxX, x); whiteMaxY = max(whiteMaxY, y)
                    }
                }
            }
            let zoom = project.state.zoom(at: seconds)
            let viewport = zoom.viewport(in: CGSize(width: width, height: height))
            let hotspot = CGPoint(x: (0.7 * Double(width) - viewport.minX) * zoom.scale,
                                  y: (0.5 * Double(height) - viewport.minY) * zoom.scale)
            let cursorWidth = Double(whiteMaxX - whiteMinX + 1)
            let cursorHeight = Double(whiteMaxY - whiteMinY + 1)
            try require(whiteMaxX >= 0 && Double(whiteMinX) >= hotspot.x - 2 &&
                        Double(whiteMinX) <= hotspot.x + 4 * zoom.scale &&
                        Double(whiteMinY) >= hotspot.y - 2 && Double(whiteMinY) <= hotspot.y + 4 * zoom.scale,
                        "streaming cursor hotspot follows source viewport at \(seconds)")
            try require(cursorWidth >= 12 * zoom.scale && cursorWidth <= 19 * zoom.scale &&
                        cursorHeight >= 20 * zoom.scale && cursorHeight <= 27 * zoom.scale,
                        "streaming cursor size follows smooth zoom scale at \(seconds)")
            counts.cursorFrames += 1
        }
        // Avoid a one-frame boundary ambiguity between output timebases; test
        // the complete stable intervals on both sides of each source boundary.
        if seconds < cameraRange.lowerBound - 0.05 {
            try require(greenCount == 0 && blue(80, 60), "no camera before its first source frame")
            counts.before += 1
            return
        }
        if seconds > cameraRange.upperBound + 0.05 {
            try require(greenCount == 0 && blue(80, 60), "camera disappears after its source ends; screen continues")
            counts.after += 1
            return
        }
        guard seconds >= cameraRange.lowerBound + 0.05, seconds < cameraRange.upperBound - 0.05,
              abs(seconds - 1) > 0.04, abs(seconds - 1.5) > 0.04 else { return }
        let placement = project.state.placement(at: seconds)
        let expected = placement.frame(in: CGSize(width: width, height: height), cameraAspect: 2)
        let actual = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        try require(greenCount > 0 && abs(actual.minX - expected.minX) <= 3 && abs(actual.minY - expected.minY) <= 3 &&
                    abs(actual.width - expected.width) <= 3 && abs(actual.height - expected.height) <= 3,
                    "streaming PIP frame at \(seconds): \(actual), expected \(expected)")
        try require(green(Int(expected.midX), Int(expected.midY)), "camera center is visible during streaming")
        if placement.shape == .circle {
            try require(blue(Int(expected.minX + 2), Int(expected.minY + 2)), "circle has transparent corners in actual playback")
            let fill = Double(greenCount) / (expected.width * expected.height)
            try require(fill > 0.7 && fill < 0.9, "streaming circle has circular pixel area")
            counts.circles += 1
        } else if placement.shape == .rectangle {
            try require(green(Int(expected.minX + 2), Int(expected.minY + 2)), "free rectangle retains its rectangular corner")
            counts.rectangles += 1
        }
        if seconds > 1.15 && seconds < 1.45 { counts.moving += 1 }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckError.failed(message) }
    }

    private static func movie(to url: URL, width: Int, height: Int, frames: Int, camera: Bool, firstFrame: Int = 0) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CheckError.failed("start synthetic movie writer") }
        writer.startSession(atSourceTime: .zero)
        for index in firstFrame..<frames {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                try require(writer.status == .writing && Date() < deadline, "synthetic movie writer stays responsive")
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            try require(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                        "create synthetic source frame")
            guard let buffer else { throw CheckError.failed("synthetic source buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    bytes[offset] = camera ? 0 : 255
                    bytes[offset + 1] = camera ? 255 : 0
                    bytes[offset + 2] = 0
                    bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)), "write synthetic source frame")
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        await writer.finishWriting()
        try require(writer.status == .completed, "finish synthetic source movie")
    }
}
