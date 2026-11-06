@preconcurrency import AVFoundation
import Foundation

private enum MasterCheckError: Error { case failed(String) }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw MasterCheckError.failed(message) }
}

private final class MasterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var first: [Double] = []
    private var failures: [String] = []
    private var ready = false
    func firstVideo(_ time: Double) { lock.withLock { first.append(time) } }
    func failed(_ error: any Error) { lock.withLock { failures.append(error.localizedDescription) } }
    func allowWrites() { lock.withLock { ready = true } }
    var isReady: Bool { lock.withLock { ready } }
    var firstTimes: [Double] { lock.withLock { first } }
    var failureCount: Int { lock.withLock { failures.count } }
}

@main
struct RecordingMasterChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-masters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for audio in [Set<ScreenMasterWriter.Track>(), [.microphone], [.systemAudio, .microphone]] {
            let suffix = audio.isEmpty ? "silent" : audio.count == 1 ? "microphone" : "both"
            try await master(at: directory.appendingPathComponent("\(suffix).mov"), audio: audio)
        }
        try await reversedArrival(at: directory.appendingPathComponent("reversed-arrival.mov"))
        try await latePreroll(at: directory.appendingPathComponent("late-preroll.mov"))
        try await earlyFinish(at: directory.appendingPathComponent("early-finish.mov"))
        try await emptyAudio(at: directory.appendingPathComponent("no-audio-yet.mov"))
        try await staticScreen(at: directory.appendingPathComponent("static.mov"))
        try await shortEncoderBurst(at: directory.appendingPathComponent("burst.mov"))
        try await boundedBackpressure(at: directory.appendingPathComponent("bounded.mov"))
        try await boundedBytes(at: directory.appendingPathComponent("bounded-bytes.mov"))
        try await stalledEncoder(at: directory.appendingPathComponent("stalled.mov"))
        try await cameraCodecs(in: directory)
        print("Recording master checks passed (actual ProRes/PCM codecs, native mic conversion, independent audio timelines, pixels, silent/static captures, bounded startup bursts/overload, orderly failures, and compact compatibility).")
    }

    private static func master(at url: URL, audio: Set<ScreenMasterWriter.Track>) async throws {
        let probe = MasterProbe()
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48, audioTracks: audio,
            frameDuration: CMTime(value: 1, timescale: 30), maximumPendingSamples: 128,
            onFirstVideo: { probe.firstVideo($0) }, onFailure: { probe.failed($0) })
        let micLead = audio.contains(.microphone) ? 0.05 : 0
        for frame in 0..<15 {
            if audio.contains(.microphone) {
                try require(writer.append(try audioSample(at: 100 + Double(frame) / 30 - micLead,
                    sampleRate: 44_100, channels: 1, values: [0.25]), track: .microphone), "native mic sample refused")
            }
            try require(writer.append(try videoSample(at: 100 + Double(frame) / 30), track: .video,
                                      hostTime: 500 + Double(frame) / 30), "screen sample refused")
            if audio.contains(.systemAudio) {
                try require(writer.append(try audioSample(at: 100 + Double(frame) / 30 + 0.02,
                    sampleRate: 48_000, channels: 2, values: [0.125, 0.375], nonInterleaved: true), track: .systemAudio), "system audio sample refused")
            }
        }
        try await finish(writer)
        try await finish(writer) // Finalization is idempotent after callback races.
        try require(probe.firstTimes == [500] && probe.failureCount == 0, "first written frame must report its host clock exactly once")
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try require(video.count == 1 && audioTracks.count == audio.count, "enabled audio sources must remain separate tracks")
        try await codec(video[0], is: kCMVideoCodecType_AppleProRes422LT)
        let firstVideo = try await ScreenRecorder.firstVideoPresentationTime(in: url)
        try require(abs(firstVideo - micLead) < 0.002, "camera/cursor alignment must see the encoded first-video offset: \(firstVideo), expected \(micLead)")
        try await videoPixels(video[0], in: asset, from: firstVideo)
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard let description = descriptions.first,
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { throw MasterCheckError.failed("PCM format") }
            try require(format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
                        format.mSampleRate == 48_000 && format.mChannelsPerFrame == 2,
                        "master audio must be uncompressed float32 stereo48k")
            let values = try await audioPixels(track, in: asset)
            let startsAtZero = values.start < 0.002
            try require(startsAtZero || abs(values.start - (micLead + 0.02)) < 0.002,
                        "independent late system/mic timestamps changed: \(values.start)")
            if startsAtZero {
                try require(values.left > 0.1 && values.left < 0.3 && abs(values.left - values.right) < 0.001,
                            "native mono microphone conversion changed channel alignment or lost its signal")
            } else {
                try require(abs(values.left - 0.125) < 0.000001 && abs(values.right - 0.375) < 0.000001,
                            "48k stereo PCM samples must remain exact")
            }
        }
        try require(writer.bufferUsage.count == 0 && writer.bufferUsage.bytes == 0,
                    "finished writer must release retained sample buffers")
        let bytes = try Data(contentsOf: url)
        do {
            _ = try ScreenMasterWriter(url: url, width: 64, height: 48, audioTracks: [],
                                       onFirstVideo: { _ in }, onFailure: { _ in })
            throw MasterCheckError.failed("existing master overwritten")
        } catch let error as MasterCheckError { throw error }
        catch { }
        try require(try Data(contentsOf: url) == bytes, "existing original media changed")
    }

    private static func emptyAudio(at url: URL) async throws {
        let probe = MasterProbe()
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48,
            audioTracks: [.systemAudio, .microphone], onFirstVideo: { probe.firstVideo($0) }, onFailure: { probe.failed($0) })
        for frame in 0..<3 {
            try require(writer.append(try videoSample(at: 100 + Double(frame) / 30), track: .video, hostTime: 500), "silent-start sample refused")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while probe.firstTimes.isEmpty {
            try require(ContinuousClock.now < deadline, "silent enabled audio tracks cannot indefinitely delay startup")
            try await Task.sleep(for: .milliseconds(5))
        }
        try await finish(writer)
        try require(probe.firstTimes == [500] && probe.failureCount == 0, "absent/silent audio tracks cannot block screen recording")
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        try require(tracks.count == 1, "silent startup must retain screen video")
    }

    private static func reversedArrival(at url: URL) async throws {
        let probe = MasterProbe()
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48,
            audioTracks: [.microphone, .systemAudio], frameDuration: CMTime(value: 1, timescale: 60),
            onFirstVideo: { probe.firstVideo($0) }, onFailure: { probe.failed($0) })
        try require(writer.append(try videoSample(at: 100), track: .video, hostTime: 500), "video-first startup sample")
        try await Task.sleep(for: .milliseconds(10))
        try require(probe.firstTimes.isEmpty, "video must remain buffered while the short startup reorder window is open")
        try require(writer.append(try audioSample(at: 99.95, sampleRate: 44_100, channels: 1,
            values: [0.25]), track: .microphone), "late callback with earlier microphone timestamp")
        try require(writer.append(try audioSample(at: 99.975, sampleRate: 48_000, channels: 2,
            values: [0.125, 0.375], nonInterleaved: true), track: .systemAudio), "late system callback with distinct earlier timestamp")
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while probe.firstTimes.isEmpty {
            try require(ContinuousClock.now < deadline, "bounded startup reorder must eventually encode without Stop")
            try await Task.sleep(for: .milliseconds(5))
        }
        try await finish(writer, end: CMTime(seconds: 100.2, preferredTimescale: 60_000))
        let asset = AVURLAsset(url: url)
        let offset = try await ScreenRecorder.firstVideoPresentationTime(in: url)
        try require(abs(offset - 0.05) < 0.002, "callback arrival order must not discard earlier microphone samples or move the screen origin")
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try require(audioTracks.count == 2, "reordered audio sources must remain independent")
        var starts: [Double] = []
        for track in audioTracks {
            let values = try await audioPixels(track, in: asset)
            starts.append(values.start)
            if values.start < 0.002 {
                try require(values.left > 0.1 && values.left < 0.3 && abs(values.left - values.right) < 0.001,
                            "earlier microphone PCM must retain its leading signal")
            } else {
                try require(abs(values.left - 0.125) < 0.000001 && abs(values.right - 0.375) < 0.000001,
                            "earlier system PCM must retain exact leading channel samples")
            }
            let segments = try await track.load(.segments)
            let duration = segments.first(where: { !$0.isEmpty })?.timeMapping.source.duration.seconds ?? 0
            try require(abs(duration - 1.0 / 30) < 0.002,
                        "late arrival must not shorten the earlier audio packet")
        }
        starts.sort()
        try require(abs(starts[0]) < 0.002 && abs(starts[1] - 0.025) < 0.002,
                    "reordering must preserve each audio source's actual leading offset")
        try require(probe.firstTimes == [500] && probe.failureCount == 0 && writer.bufferUsage.count == 0,
                    "bounded reorder must report the written host time once, finish cleanly, and release buffers")
    }

    private static func earlyFinish(at url: URL) async throws {
        let probe = MasterProbe()
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48, audioTracks: [],
            maximumPendingSamples: 1024, startupReorderWindow: 10,
            onFirstVideo: { probe.firstVideo($0) }, onFailure: { probe.failed($0) })
        try require(writer.append(try videoSample(at: 100), track: .video, hostTime: 500), "early Stop fixture")
        let began = ContinuousClock.now
        try await finish(writer)
        try require(began.duration(to: .now) < .seconds(2) && probe.firstTimes == [500] && probe.failureCount == 0,
                    "Stop must flush immediately instead of waiting for the startup reorder timer")
    }

    private static func latePreroll(at url: URL) async throws {
        let probe = MasterProbe()
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48, audioTracks: [.microphone],
            startupReorderWindow: 0, onFirstVideo: { probe.firstVideo($0) }, onFailure: { probe.failed($0) })
        try require(writer.append(try videoSample(at: 100), track: .video, hostTime: 500), "late-preroll origin picture")
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while probe.firstTimes.isEmpty {
            try require(ContinuousClock.now < deadline, "late-preroll fixture startup")
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(writer.append(try audioSample(at: 100 - 1.0 / 30, sampleRate: 48_000, channels: 1,
            values: [0.125]), track: .microphone), "late preroll packet must not interrupt capture")
        try require(writer.append(try audioSample(at: 100, sampleRate: 48_000, channels: 1,
            values: [0.375]), track: .microphone), "post-origin microphone packet must survive late preroll")
        try await finish(writer, end: CMTime(seconds: 100.2, preferredTimescale: 60_000))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try require(tracks.count == 1, "post-origin microphone audio must be retained")
        let values = try await audioPixels(tracks[0], in: asset)
        try require(abs(values.start) < 0.002 && values.left > 0.2 && values.left < 0.4 &&
                    abs(values.left - values.right) < 0.001,
                    "the finalized origin trims only preroll and preserves subsequent microphone timing and signal: \(values)")
        try require(probe.failureCount == 0 && writer.bufferUsage.count == 0,
                    "late preroll must finish normally without retained buffers or false failure notifications")
    }

    private static func staticScreen(at url: URL) async throws {
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48, audioTracks: [],
            onFirstVideo: { _ in }, onFailure: { _ in })
        try require(writer.append(try videoSample(at: 100), track: .video, hostTime: 500), "static first frame refused")
        try await finish(writer, end: CMTime(seconds: 103, preferredTimescale: 600))
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        try require(abs(duration - 3) < 0.002, "idle display movie must extend to Stop instead of ending at its last content change")
        let video = try await asset.loadTracks(withMediaType: .video)
        try await videoPixels(video[0], in: asset)
    }

    private static func boundedBackpressure(at url: URL) async throws {
        let probe = MasterProbe()
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48, audioTracks: [],
            maximumPendingSamples: 4, maximumPendingBytes: 64 * 1024, readiness: { _ in probe.isReady },
            onFirstVideo: { probe.firstVideo($0) }, onFailure: { probe.failed($0) })
        for frame in 0..<4 {
            try require(writer.append(try videoSample(at: 100 + Double(frame) / 30), track: .video, hostTime: 500), "bounded accepted sample refused early")
        }
        try require(!writer.append(try videoSample(at: 101), track: .video, hostTime: 501), "slow encoder must refuse work beyond its bounded budget")
        try require(writer.bufferUsage.peakCount == 4 && writer.bufferUsage.peakBytes <= 64 * 1024 && probe.failureCount == 1,
                    "backpressure must bound retained memory and report failure once")
        probe.allowWrites()
        do { try await finish(writer); throw MasterCheckError.failed("overflow did not report partial recording") }
        catch MasterRecordingError.encoderOverloaded { }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try require(tracks.count == 1 && writer.bufferUsage.count == 0, "accepted slow-writer media must flush and release memory")
        try await codec(tracks[0], is: kCMVideoCodecType_AppleProRes422LT)
        try await videoPixels(tracks[0], in: asset)
    }

    private static func shortEncoderBurst(at url: URL) async throws {
        let fourKFrameBytes = 3840 * 2160 * 4
        let fourKLimit = try ScreenMasterWriter.defaultBufferByteLimit(width: 3840, height: 2160)
        try require(fourKLimit >= fourKFrameBytes * 8 && fourKLimit <= 512 * 1024 * 1024,
                    "4K capture must tolerate eight retained frames without an unbounded queue")
        let sixKFrameBytes = 6144 * 3456 * 4
        let sixKLimit = try ScreenMasterWriter.defaultBufferByteLimit(width: 6144, height: 3456)
        try require(sixKLimit == 512 * 1024 * 1024 && sixKLimit >= sixKFrameBytes * 2,
                    "large captures must obey the hard cap while retaining room for the final and next frame")
        try require(try ScreenMasterWriter.defaultBufferByteLimit(width: 1920, height: 1080) == 128 * 1024 * 1024,
                    "smaller captures use the fixed bounded floor")
        let probe = MasterProbe()
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48, audioTracks: [],
            frameDuration: CMTime(value: 1, timescale: 60), readiness: { _ in probe.isReady },
            onFirstVideo: { probe.firstVideo($0) }, onFailure: { probe.failed($0) })
        // Model 100ms of startup latency at 60fps without allocating six real
        // 4K surfaces; the resolution policy is checked independently above.
        for frame in 0..<6 {
            try require(writer.append(try videoSample(at: 100 + Double(frame) / 60,
                duration: CMTime(value: 1, timescale: 60)), track: .video, hostTime: 500), "ordinary startup burst must be admitted")
        }
        try await Task.sleep(for: .milliseconds(100))
        try require(probe.failureCount == 0 && writer.bufferUsage.count == 6,
                    "a brief encoder readiness delay must retain the bounded burst without reporting overload")
        probe.allowWrites()
        try await finish(writer)
        try require(probe.failureCount == 0 && probe.firstTimes == [500] && writer.bufferUsage.count == 0,
                    "encoder recovery must flush the complete burst and release all reservations")
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        reader.add(output)
        try require(reader.startReading(), "startup burst reader")
        defer { reader.cancelReading() }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 && CMSampleBufferGetTotalSampleSize(sample) > 0 { count += 1 }
        }
        try require(count == 6, "recovering from startup latency must keep every accepted picture")
    }

    private static func stalledEncoder(at url: URL) async throws {
        let probe = MasterProbe()
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48, audioTracks: [], stallTimeout: 0.03,
            readiness: { _ in false }, onFirstVideo: { probe.firstVideo($0) }, onFailure: { probe.failed($0) })
        try require(writer.append(try videoSample(at: 100), track: .video, hostTime: 500), "stalled fixture initial acceptance")
        let began = ContinuousClock.now
        do { try await finish(writer); throw MasterCheckError.failed("stalled encoder did not fail") }
        catch MasterRecordingError.encoderStalled { }
        try require(began.duration(to: .now) < .seconds(2) && probe.firstTimes.isEmpty &&
                    probe.failureCount == 1 && writer.bufferUsage.count == 0, "stalled writer must resolve, release buffers, and never report a captured first frame")
    }

    private static func boundedBytes(at url: URL) async throws {
        let probe = MasterProbe()
        let writer = try ScreenMasterWriter(url: url, width: 64, height: 48, audioTracks: [],
            maximumPendingSamples: 32, maximumPendingBytes: 20 * 1024, readiness: { _ in probe.isReady },
            onFirstVideo: { probe.firstVideo($0) }, onFailure: { probe.failed($0) })
        try require(writer.append(try videoSample(at: 100), track: .video, hostTime: 500), "byte-budget first sample")
        try require(!writer.append(try videoSample(at: 100.1), track: .video, hostTime: 500.1), "byte budget must stop admission independently of the sample-count limit")
        try require(writer.bufferUsage.peakCount == 1 && writer.bufferUsage.peakBytes <= 20 * 1024 && probe.failureCount == 1,
                    "large buffers must remain inside the byte budget")
        probe.allowWrites()
        do { try await finish(writer); throw MasterCheckError.failed("byte overflow did not fail") }
        catch MasterRecordingError.encoderOverloaded { }
        try require(writer.bufferUsage.count == 0, "byte-bound partial flush must release retained media")
    }

    private static func cameraCodecs(in directory: URL) async throws {
        for quality in RecordingQuality.allCases {
            let url = directory.appendingPathComponent("camera-\(quality.rawValue).mov")
            let writer = CameraTrackWriter(url: url, quality: quality)
            let screen = quality == .highQuality ? try ScreenMasterWriter(
                url: directory.appendingPathComponent("concurrent-screen.mov"), width: 64, height: 48, audioTracks: [],
                onFirstVideo: { _ in }, onFailure: { _ in }) : nil
            for frame in 0..<4 {
                let buffer = try videoSample(at: 100 + Double(frame) / 30)
                if let screen {
                    try require(screen.append(buffer, track: .video, hostTime: 500 + Double(frame) / 30),
                                "concurrent ProRes screen/camera encoding")
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while try !writer.append(buffer, hostTime: 500 + Double(frame) / 30) {
                    try require(ContinuousClock.now < deadline, "camera writer readiness")
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                writer.finish { continuation.resume(with: $0) }
            }
            if let screen { try await finish(screen) }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            try await codec(tracks[0], is: quality == .highQuality ? kCMVideoCodecType_AppleProRes422LT : kCMVideoCodecType_H264)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            try require(audio.isEmpty, "camera quality must not duplicate microphone capture")
        }
    }

    private static func finish(_ writer: ScreenMasterWriter, end: CMTime? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.finish(at: end) { continuation.resume(with: $0) }
        }
    }

    private static func codec(_ track: AVAssetTrack, is expected: FourCharCode) async throws {
        let formats = try await track.load(.formatDescriptions)
        try require(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == expected, "encoded video codec does not match selected original quality")
    }

    private static func videoPixels(_ track: AVAssetTrack, in asset: AVAsset, from start: Double = 0) async throws {
        let reader = try AVAssetReader(asset: asset)
        if start > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                end: try await asset.load(.duration))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        try require(reader.startReading(), "video reader startup")
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else { throw MasterCheckError.failed("decoded master pixels") }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { throw MasterCheckError.failed("decoded pixel bytes") }
        let offset = 24 * CVPixelBufferGetBytesPerRow(pixels) + 32 * 4
        try require(abs(Int(base[offset]) - 20) <= 8 && abs(Int(base[offset + 1]) - 80) <= 8 && abs(Int(base[offset + 2]) - 220) <= 8,
                    "master codec changed source pixel colors beyond its expected encoding tolerance: BGR=\(base[offset]),\(base[offset + 1]),\(base[offset + 2])")
    }

    private static func audioPixels(_ track: AVAssetTrack, in asset: AVAsset) async throws -> (left: Float, right: Float, start: Double) {
        let reader = try AVAssetReader(asset: asset)
        let segments = try await track.load(.segments)
        let start = segments.first(where: { !$0.isEmpty })?.timeMapping.target.start.seconds ?? 0
        if start > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                end: try await asset.load(.duration))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        try require(reader.startReading(), "audio reader startup")
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) else { throw MasterCheckError.failed("decoded PCM samples") }
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        try require(status == noErr && values.count > 128, "PCM sample bytes")
        return (values[100], values[101], start)
    }

    private static func videoSample(at seconds: Double, duration: CMTime = CMTime(value: 1, timescale: 30)) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        try require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, "video fixture pixels")
        guard let pixels else { throw MasterCheckError.failed("video buffer") }
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixels, [])
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<48 { for x in 0..<64 { let offset = y * stride + x * 4; base[offset] = 20; base[offset + 1] = 80; base[offset + 2] = 220; base[offset + 3] = 255 } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var description: CMVideoFormatDescription?
        try require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescriptionOut: &description) == noErr, "video fixture format")
        var timing = CMSampleTimingInfo(duration: duration,
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try require(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, "video fixture sample")
        return sample!
    }

    private static func audioSample(at seconds: Double, sampleRate: Double, channels: Int, values: [Float], nonInterleaved: Bool = false) throws -> CMSampleBuffer {
        let frames = Int(sampleRate / 30)
        var data = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames { for channel in 0..<channels { data[nonInterleaved ? channel * frames + frame : frame * channels + channel] = values[channel] } }
        let bytesPerFrame = nonInterleaved ? 4 : channels * 4
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (nonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
            "audio fixture format")
        var block: CMBlockBuffer?
        try require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: data.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: data.count * 4, flags: 0, blockBufferOut: &block) == noErr, "audio fixture block")
        try require(data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) } == noErr,
                    "audio fixture bytes")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: Int32(sampleRate)), decodeTimeStamp: .invalid)
        var size = bytesPerFrame
        var sample: CMSampleBuffer?
        try require(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: description!,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, "audio fixture sample")
        return sample!
    }
}
