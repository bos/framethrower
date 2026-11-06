@preconcurrency import AVFoundation
import AppKit
import AudioToolbox
import Foundation

private enum CursorCheckError: Error { case failed(String) }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw CursorCheckError.failed(message) }
}

@main
struct CursorRecordingChecks {
    @MainActor
    static func main() async throws {
        let display = CursorCaptureSource.display(bounds: CGRect(x: -1600, y: -900, width: 1600, height: 900))
        let quartz = CursorCaptureSource.quartzPoint(fromAppKit: CGPoint(x: -800, y: 1350), primaryDisplayTop: 900)
        try require(quartz == CGPoint(x: -800, y: -450), "negative-display AppKit/Quartz conversion")
        var displayBuilder = CursorCaptureBuilder(logicalSize: display.logicalSize)
        displayBuilder.append(hostTime: 10, point: quartz, bounds: display.bounds { _, _ in nil }, buttons: 0)
        let displayTrack = try displayBuilder.recording(screenStartHostTime: 10, duration: 1)
        try require(displayTrack.samples[0].x == 0.5 && displayTrack.samples[0].y == 0.5, "normalized negative-display source")
        let area = CursorCaptureSource.area(displayBounds: CGRect(x: 1920, y: -200, width: 1280, height: 720),
                                            sourceRect: CGRect(x: 100, y: 80, width: 640, height: 360))
        try require(area.bounds { _, _ in nil } == CGRect(x: 2020, y: -120, width: 640, height: 360),
                    "area did not use exact configured display-local top-left crop")
        var areaBuilder = CursorCaptureBuilder(logicalSize: area.logicalSize)
        areaBuilder.append(hostTime: 20, point: CGPoint(x: 2340, y: 60), bounds: area.bounds { _, _ in nil }, buttons: 0)
        let areaTrack = try areaBuilder.recording(screenStartHostTime: 20, duration: 1)
        try require(areaTrack.logicalSize == CGSize(width: 640, height: 360)
                    && areaTrack.samples[0].x == 0.5 && areaTrack.samples[0].y == 0.5, "area dimensions/normalization")

        let window = CursorCaptureSource.window(id: 42, processID: 314, logicalSize: CGSize(width: 1280, height: 720))
        var frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        let bounds: (CGWindowID, pid_t) -> CGRect? = { id, owner in id == 42 && owner == 314 ? frame : nil }
        var windowBuilder = CursorCaptureBuilder(logicalSize: window.logicalSize)
        windowBuilder.append(hostTime: 30, point: CGPoint(x: 500, y: 500), bounds: window.bounds(windowBounds: bounds), buttons: 0)
        frame = CGRect(x: 300, y: -100, width: 1600, height: 900)
        windowBuilder.append(hostTime: 30.5, point: CGPoint(x: 1100, y: 350), bounds: window.bounds(windowBounds: bounds), buttons: 0)
        windowBuilder.append(hostTime: 30.8, point: CGPoint(x: 1100, y: 350), bounds: nil, buttons: 0)
        let windowTrack = try windowBuilder.recording(screenStartHostTime: 30, duration: 1)
        try require(windowTrack.logicalSize == CGSize(width: 1280, height: 720), "resizing window changed original logical canvas")
        try require(windowTrack.pointer(at: 0.5)?.x == 0.5 && windowTrack.pointer(at: 0.5)?.y == 0.5,
                    "moving/resizing window shifted normalized hotspot")
        try require(windowTrack.pointer(at: 0.9)?.visible == false, "missing/closed window retained a visible cursor")

        try timingAndClicks()
        try smoothingAndDragging()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cursor.json")
        try displayTrack.write(to: destination)
        let original = try Data(contentsOf: destination)
        try require(try CursorRecording.load(from: destination) == displayTrack, "cursor sidecar did not round-trip")
        do {
            try areaTrack.write(to: destination)
            throw CursorCheckError.failed("overwrote immutable cursor source")
        } catch let error as CursorCheckError { throw error }
        catch {}
        try require(try Data(contentsOf: destination) == original, "existing cursor source bytes changed")
        try require(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["cursor.json"], "cursor publication leaked temporary files")
        var invalid = displayTrack
        invalid.logicalWidth = 1
        do { try invalid.validate(); throw CursorCheckError.failed("1px logical recording accepted") }
        catch CursorRecordingError.invalidData {}
        invalid = displayTrack; invalid.samples[0].x = .nan
        do { try invalid.validate(); throw CursorCheckError.failed("non-finite pointer coordinate accepted") }
        catch CursorRecordingError.invalidData {}
        let inactive = CursorRecorder()
        try require(!inactive.start(source: .display(bounds: CGRect(x: 0, y: 0, width: 1, height: 1))),
                    "invalid capture activated pointer monitors")
        inactive.cancel()
        let movie = directory.appendingPathComponent("leading-video-gap.mov")
        try await leadingGapMovie(to: movie)
        let firstTime = try await ScreenRecorder.firstVideoPresentationTime(in: movie)
        try require(abs(firstTime - 0.2) < 0.001,
                    "screen movie's leading video edit was lost: \(firstTime)")
        print("Cursor recording checks passed (all source spaces, moving windows, microclicks, file/host timing, precise dragging, smoothing, immutable sidecars).")
    }

    private static func timingAndClicks() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        var builder = CursorCaptureBuilder(logicalSize: bounds.size)
        builder.append(hostTime: 999.9, point: CGPoint(x: 20, y: 30), bounds: bounds, buttons: 0)
        builder.append(hostTime: 1000.016, point: CGPoint(x: 40, y: 50), bounds: bounds, buttons: 0)
        // Both edges occur between 60Hz motion ticks, delivered after a newer
        // timer sample. They must retain their actual event timestamps.
        builder.append(hostTime: 1000.005, point: CGPoint(x: 25, y: 35), bounds: bounds, buttons: 1, clickButton: 0)
        builder.append(hostTime: 1000.007, point: CGPoint(x: 25, y: 35), bounds: bounds, buttons: 0)
        builder.append(hostTime: 1000.5, point: CGPoint(x: 150, y: 50), bounds: bounds, buttons: 2, clickButton: 1)
        builder.append(hostTime: 1000.6, point: CGPoint(x: 50, y: 50), bounds: bounds, buttons: 0)
        builder.append(hostTime: 1002, point: CGPoint(x: 90, y: 90), bounds: bounds, buttons: 1, clickButton: 0)
        let track = try builder.recording(screenStartHostTime: 1000, duration: 1, firstFrameSourceTime: 0.125)
        try require(track.pointer(at: 0.1)?.visible == false, "cursor rendered in the screen movie's initial empty interval")
        try require(track.pointer(at: 0.125)?.visible == true, "cursor did not begin with the first screen frame")
        try require(track.clicks.count == 1 && abs(track.clicks[0].time - 0.13) < 0.000_001,
                    "microclick was lost, outside clicks leaked, or file timing was misaligned")
        try require(track.pointer(at: 0.131)?.buttons == 1 && track.pointer(at: 0.133)?.buttons == 0,
                    "button edges shorter than one motion frame were not retained")
        try require(track.pointer(at: 0.65)?.visible == false, "pointer outside the recorded source remained visible")
        try require(track.pointer(at: -0.1) == nil && track.pointer(at: 1.1) == nil,
                    "out-of-recording pointer request returned unrelated samples")
    }

    private static func smoothingAndDragging() throws {
        let samples = [
            CursorSample(time: 0, x: 0, y: 0.5), CursorSample(time: 0.1, x: 0.7, y: 0.5),
            CursorSample(time: 0.2, x: 0.3, y: 0.5), CursorSample(time: 0.3, x: 1, y: 0.5)
        ]
        let track = CursorRecording(duration: 0.3, logicalWidth: 100, logicalHeight: 100, samples: samples, clicks: [])
        try track.validate()
        try require(track.pointer(at: 0.1, smoothing: 1)!.x < track.pointer(at: 0.1, smoothing: 0)!.x,
                    "offline smoothing did not suppress pointer jitter")
        let times = [0.01, 0.05, 0.1, 0.15, 0.2, 0.29]
        let forward = times.map { track.pointer(at: $0, smoothing: 0.4) }
        let reverse = times.reversed().map { track.pointer(at: $0, smoothing: 0.4) }.reversed()
        try require(forward == Array(reverse), "smoothing depended on playback direction/history")
        let drag = CursorRecording(duration: 1, logicalWidth: 100, logicalHeight: 100, samples: [
            CursorSample(time: 0, x: 0, y: 0, buttons: 1),
            CursorSample(time: 0.1, x: 1, y: 0.3, buttons: 1),
            CursorSample(time: 0.2, x: 0.2, y: 0.9, buttons: 1),
            CursorSample(time: 1, x: 0.8, y: 1, buttons: 0)
        ], clicks: [CursorClick(time: 0, x: 0, y: 0, button: 0)])
        for time in [0.01, 0.05, 0.1, 0.15, 0.2, 0.7] {
            try require(drag.pointer(at: time, smoothing: 1) == drag.pointer(at: time, smoothing: 0),
                        "smoothing changed a precise held-button drag/drawing path")
        }
        let transitions = CursorRecording(duration: 0.3, logicalWidth: 100, logicalHeight: 100, samples: [
            CursorSample(time: 0, x: 0, y: 0), CursorSample(time: 0.09, x: 0, y: 0),
            CursorSample(time: 0.1, x: 1, y: 1, buttons: 1), CursorSample(time: 0.19, x: 1, y: 1, buttons: 1),
            CursorSample(time: 0.2, x: 0, y: 0), CursorSample(time: 0.3, x: 0, y: 0)
        ], clicks: [CursorClick(time: 0.1, x: 1, y: 1, button: 0)])
        try require(transitions.pointer(at: 0.08, smoothing: 1)?.x == 0
                    && transitions.pointer(at: 0.2, smoothing: 1)?.x == 0,
                    "smoothing blended positions across a button transition")
        try require(transitions.pointer(at: 0.1, smoothing: 1)?.x == 1,
                    "click target gained smoothing lag")
        let anchors = CursorRecording(duration: 1, logicalWidth: 100, logicalHeight: 100,
            samples: [CursorSample(time: 0, x: 0, y: 0), CursorSample(time: 1, x: 1, y: 1)],
            clicks: [CursorClick(time: 0.5, x: 0.25, y: 0.75, button: 0)])
        try require(anchors.pointer(at: 0.5, smoothing: 1)?.x == 0.25
                    && anchors.pointer(at: 0.5, smoothing: 1)?.y == 0.75, "exact click anchor was not preserved")
    }

    private static func leadingGapMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48
        ])
        writer.add(input)
        let audioSample = try silentAudio()
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
            sourceFormatHint: CMSampleBufferGetFormatDescription(audioSample))
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? CursorCheckError.failed("gap fixture writer") }
        writer.startSession(atSourceTime: .zero)
        guard audio.append(audioSample) else { throw writer.error ?? CursorCheckError.failed("gap fixture audio") }
        audio.markAsFinished()
        for index in 1...2 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw CursorCheckError.failed("gap fixture writer stalled") }
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess,
                  let pixel else { throw CursorCheckError.failed("gap fixture buffer") }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) { memset(base, 0, CVPixelBufferGetBytesPerRow(pixel) * 48) }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 5)) else {
                throw writer.error ?? CursorCheckError.failed("gap fixture append")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 5))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CursorCheckError.failed("gap fixture finalization") }
    }

    private static func silentAudio() throws -> CMSampleBuffer {
        let count = 28_800
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw CursorCheckError.failed("gap audio format")
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == noErr,
            let block else { throw CursorCheckError.failed("gap audio buffer") }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: count * 2)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else {
            throw CursorCheckError.failed("gap audio sample")
        }
        return sample
    }

}
