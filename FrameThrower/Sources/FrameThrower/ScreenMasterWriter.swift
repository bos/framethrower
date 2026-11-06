@preconcurrency import AVFoundation
import Foundation

enum MasterRecordingError: LocalizedError {
    case unsupportedFormat
    case invalidSample
    case encoderOverloaded
    case encoderStalled
    case noVideo

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "This recording format could not be encoded on this Mac."
        case .invalidSample: return "Capture supplied an invalid media timestamp or format."
        case .encoderOverloaded: return "Recording stopped because the encoder could not keep up. Try Smaller files or a smaller capture area."
        case .encoderStalled: return "The encoder stopped responding."
        case .noVideo: return "No screen video was captured."
        }
    }
}

/// Raw ScreenCaptureKit samples enter a bounded, nonblocking queue. All encoder
/// work is serial, and microphone/system audio remain independent PCM tracks.
/// No capture session or device is created here, so the entire writer can be
/// exercised with synthetic buffers.
/// By default the initial batch gets up to 50ms of reordering before encoding;
/// the origin is its earliest timestamp when the encoder accepts its first sample.
/// After that bounded window, media preceding the committed origin is preroll:
/// AVAssetWriter trims that portion while retaining samples after the origin.
final class ScreenMasterWriter: @unchecked Sendable {
    enum Track: Hashable, Sendable { case video, systemAudio, microphone }
    struct BufferUsage: Sendable { let count: Int; let bytes: Int; let peakCount: Int; let peakBytes: Int }

    private let queue = DispatchQueue(label: "framethrower.master.encoder")
    private let writer: AVAssetWriter
    private let inputs: [Track: AVAssetWriterInput]
    private let budget: MasterSampleBudget
    private let submissionLock = NSLock()
    private let onFirstVideo: @Sendable (Double) -> Void
    private let onFailure: @Sendable (any Error) -> Void
    private let readiness: (@Sendable (Track) -> Bool)?
    private let stallTimeout: Double
    private let frameDuration: CMTime
    private let startupWindow: Double
    // Encoder queue only.
    private var pending: [MasterSample] = []
    private var lastVideo: MasterSample?
    private var lastPTS: [Track: CMTime] = [:]
    private var sessionStart: CMTime?
    private var startupReleased = false
    private var startupTimerScheduled = false
    private var firstVideoHostTime: Double?
    private var requestedEnd: CMTime?
    private var closingFrame: CMSampleBuffer?
    private var waitingSince: DispatchTime?
    private var retryScheduled = false
    private var finishing = false
    private var encoderFinishStarted = false
    private var completions: [@Sendable (Result<Void, any Error>) -> Void] = []
    private var finishedResult: Result<Void, any Error>?

    init(url: URL, width: Int, height: Int, audioTracks: Set<Track>,
         frameDuration: CMTime = CMTime(value: 1, timescale: 60),
         maximumPendingSamples: Int = 32, maximumPendingBytes: Int? = nil,
         startupReorderWindow: Double = 0.05,
         stallTimeout: Double = 2,
         readiness: (@Sendable (Track) -> Bool)? = nil,
         onFirstVideo: @escaping @Sendable (Double) -> Void,
         onFailure: @escaping @Sendable (any Error) -> Void) throws {
        guard width > 0, height > 0, !audioTracks.contains(.video),
              maximumPendingSamples > 0, maximumPendingBytes.map({ $0 > 0 }) ?? true,
              startupReorderWindow.isFinite, startupReorderWindow >= 0 else { throw MasterRecordingError.unsupportedFormat }
        self.onFirstVideo = onFirstVideo
        self.onFailure = onFailure
        self.readiness = readiness
        self.stallTimeout = max(0.01, stallTimeout)
        self.frameDuration = frameDuration.isNumeric && frameDuration.seconds > 0 ? frameDuration : CMTime(value: 1, timescale: 60)
        let byteLimit = try maximumPendingBytes ?? Self.defaultBufferByteLimit(width: width, height: height)
        let bufferedFrames = min(Double(maximumPendingSamples), Double(byteLimit) / (Double(width) * Double(height) * 4))
        let burstDuration = max(0, floor(bufferedFrames) - 1) * self.frameDuration.seconds
        startupWindow = min(startupReorderWindow, burstDuration)
        budget = MasterSampleBudget(maximumCount: maximumPendingSamples, maximumBytes: byteLimit)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var configured: [Track: AVAssetWriterInput] = [:]
        var settings = RecordingQuality.highQuality.videoSettings(width: width, height: height)
        settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw MasterRecordingError.unsupportedFormat }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw MasterRecordingError.unsupportedFormat }
        writer.add(video)
        configured[.video] = video
        for track in [Track.systemAudio, .microphone] where audioTracks.contains(track) {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingQuality.masterAudioSettings)
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw MasterRecordingError.unsupportedFormat }
            writer.add(audio)
            configured[track] = audio
        }
        inputs = configured
        guard writer.startWriting() else { throw writer.error ?? MasterRecordingError.unsupportedFormat }
    }

    var bufferUsage: BufferUsage { budget.usage }

    /// Eight BGRA surfaces cover a brief encoder startup/I/O burst at 60fps,
    /// including the held static-screen frame. This is a limit, not preallocated
    /// memory. At very large resolutions the hard cap takes priority over eight
    /// frames; those formats must still have room for the held and next frame.
    static func defaultBufferByteLimit(width: Int, height: Int) throws -> Int {
        let minimum = 128 * 1024 * 1024
        let maximum = 512 * 1024 * 1024
        let reserve = 1024 * 1024
        let pixels = width.multipliedReportingOverflow(by: height)
        let frame = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !pixels.overflow, !frame.overflow,
              frame.partialValue <= (maximum - reserve) / 2 else { throw MasterRecordingError.unsupportedFormat }
        return min(maximum, max(minimum, frame.partialValue * 8 + reserve))
    }

    /// Returns immediately. A refusal is terminal and reported once; the
    /// accepted queue still drains before the partial movie is finalized.
    @discardableResult
    func append(_ sample: CMSampleBuffer, track: Track, hostTime: Double? = nil) -> Bool {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard inputs[track] != nil, sample.isValid, CMSampleBufferDataIsReady(sample),
              CMSampleBufferGetNumSamples(sample) > 0,
              pts.isNumeric, pts.seconds.isFinite,
              track != .video || (CMSampleBufferGetImageBuffer(sample) != nil && hostTime?.isFinite == true) else {
            fail(MasterRecordingError.invalidSample)
            return false
        }
        let bytes: Int
        if let pixels = CMSampleBufferGetImageBuffer(sample) {
            bytes = max(1, CVPixelBufferGetDataSize(pixels),
                CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels))
        } else {
            let blockBytes = CMSampleBufferGetDataBuffer(sample).map { CMBlockBufferGetDataLength($0) } ?? 0
            bytes = max(1, CMSampleBufferGetTotalSampleSize(sample), blockBytes)
        }
        let admission = submissionLock.withLock {
            let admission = budget.reserve(bytes: bytes)
            if case .accepted = admission {
                let retained = MasterSample(buffer: sample, track: track, hostTime: hostTime, bytes: bytes, budget: budget)
                queue.async {
                    guard !self.encoderFinishStarted else { return }
                    self.pending.append(retained)
                    self.drain()
                }
            }
            return admission
        }
        if case .overloaded = admission { onFailure(MasterRecordingError.encoderOverloaded) }
        if case .accepted = admission { return true }
        return false
    }

    func finish(at end: CMTime? = nil, completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        submissionLock.withLock {
            budget.close()
            queue.async {
                if let result = self.finishedResult { completion(result); return }
                self.completions.append(completion)
                guard !self.finishing else { return }
                self.finishing = true
                if let end, end.isNumeric, end.seconds.isFinite { self.requestedEnd = end }
                self.drain()
            }
        }
    }

    private func drain() {
        guard !encoderFinishStarted else { return }
        // Capture callbacks from independent audio/video outputs need not
        // arrive in timestamp order. Hold a short bounded initial batch, never
        // wait for every enabled track, and let Stop flush it immediately.
        // Later packets before the finalized origin are normal device preroll,
        // not a reason to interrupt an otherwise usable recording.
        if sessionStart == nil, !startupReleased {
            if finishing || startupWindow == 0 { startupReleased = true }
            else {
                if !startupTimerScheduled {
                    startupTimerScheduled = true
                    queue.asyncAfter(deadline: .now() + startupWindow) { [weak self] in
                        guard let self else { return }
                        self.startupReleased = true
                        self.drain()
                    }
                }
                return
            }
        }
        while let sample = pending.first {
            guard let input = inputs[sample.track], writer.status == .writing else {
                abortEncoder(writer.error ?? MasterRecordingError.unsupportedFormat)
                return
            }
            if let previous = lastPTS[sample.track], CMTimeCompare(sample.pts, previous) <= 0 {
                // A .started and .complete notification can describe the same
                // initial screen picture. Keep exactly one encoded copy.
                if sample.track == .video, CMTimeCompare(sample.pts, previous) == 0 { pending.removeFirst(); continue }
                abortEncoder(MasterRecordingError.invalidSample)
                return
            }
            guard input.isReadyForMoreMediaData, readiness?(sample.track) ?? true else { waitForEncoder(); return }
            waitingSince = nil
            if sessionStart == nil {
                let earliest = pending.reduce(sample.pts) { CMTimeMinimum($0, $1.pts) }
                writer.startSession(atSourceTime: earliest)
                sessionStart = earliest
            }
            guard input.append(sample.buffer) else { abortEncoder(writer.error ?? MasterRecordingError.unsupportedFormat); return }
            lastPTS[sample.track] = sample.pts
            if sample.track == .video {
                lastVideo = sample
                if firstVideoHostTime == nil, let hostTime = sample.hostTime {
                    firstVideoHostTime = hostTime
                    onFirstVideo(hostTime)
                }
            }
            pending.removeFirst()
        }
        guard finishing else { return }
        // Static screens may deliver no new pictures for several seconds.
        // Repeat the final source picture at the end instead of shortening the
        // movie to the last content change.
        if let end = requestedEnd, let lastVideo, let input = inputs[.video],
           CMTimeCompare(end, CMTimeAdd(lastVideo.pts, frameDuration)) > 0 {
            if closingFrame == nil {
                var timing = CMSampleTimingInfo(duration: frameDuration,
                    presentationTimeStamp: CMTimeSubtract(end, frameDuration), decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                    sampleBuffer: lastVideo.buffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleBufferOut: &copy) == noErr, let copy else { abortEncoder(MasterRecordingError.invalidSample); return }
                closingFrame = copy
            }
            guard input.isReadyForMoreMediaData, readiness?(.video) ?? true else { waitForEncoder(); return }
            guard let closingFrame, input.append(closingFrame) else {
                abortEncoder(writer.error ?? MasterRecordingError.unsupportedFormat)
                return
            }
            self.closingFrame = nil
        }
        finishEncoder()
    }

    private func waitForEncoder() {
        let now = DispatchTime.now()
        if let waitingSince, Double(now.uptimeNanoseconds - waitingSince.uptimeNanoseconds) / 1_000_000_000 >= stallTimeout {
            abortEncoder(MasterRecordingError.encoderStalled)
            return
        }
        if waitingSince == nil { waitingSince = now }
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(5)) {
            self.retryScheduled = false
            self.drain()
        }
    }

    private func fail(_ error: any Error) {
        if budget.fail(error) { onFailure(error) }
    }

    private func abortEncoder(_ error: any Error) {
        fail(error)
        pending.removeAll()
        finishing = true
        finishEncoder()
    }

    private func finishEncoder() {
        guard !encoderFinishStarted else { return }
        encoderFinishStarted = true
        lastVideo = nil
        closingFrame = nil
        guard sessionStart != nil, writer.status == .writing else {
            writer.cancelWriting()
            complete(.failure(budget.error ?? writer.error ?? MasterRecordingError.noVideo))
            return
        }
        if let requestedEnd, let sessionStart, CMTimeCompare(requestedEnd, sessionStart) > 0 { writer.endSession(atSourceTime: requestedEnd) }
        for input in inputs.values { input.markAsFinished() }
        writer.finishWriting {
            self.queue.async {
                if let error = self.budget.error ?? self.writer.error { self.complete(.failure(error)) }
                else if self.writer.status != .completed || self.firstVideoHostTime == nil { self.complete(.failure(MasterRecordingError.noVideo)) }
                else { self.complete(.success(())) }
            }
        }
    }

    private func complete(_ result: Result<Void, any Error>) {
        finishedResult = result
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(result) }
    }
}

/// Admission is the only shared mutable state. Samples retain their reservation
/// until both the queue and the held final video frame have released them.
private final class MasterSampleBudget: @unchecked Sendable {
    enum Admission { case accepted, closed, overloaded }
    private let lock = NSLock()
    private let maximumCount: Int
    private let maximumBytes: Int
    private var count = 0
    private var bytes = 0
    private var peakCount = 0
    private var peakBytes = 0
    private var accepting = true
    private var failure: (any Error)?
    init(maximumCount: Int, maximumBytes: Int) { self.maximumCount = maximumCount; self.maximumBytes = maximumBytes }
    func reserve(bytes amount: Int) -> Admission {
        lock.withLock {
            guard accepting else { return .closed }
            guard count < maximumCount, amount <= maximumBytes - bytes else {
                accepting = false
                failure = MasterRecordingError.encoderOverloaded
                return .overloaded
            }
            count += 1; bytes += amount
            peakCount = max(peakCount, count); peakBytes = max(peakBytes, bytes)
            return .accepted
        }
    }
    func release(bytes amount: Int) { lock.withLock { count -= 1; bytes -= amount } }
    func close() { lock.withLock { accepting = false } }
    func fail(_ error: any Error) -> Bool {
        lock.withLock {
            accepting = false
            guard failure == nil else { return false }
            failure = error
            return true
        }
    }
    var error: (any Error)? { lock.withLock { failure } }
    var usage: ScreenMasterWriter.BufferUsage { lock.withLock { .init(count: count, bytes: bytes, peakCount: peakCount, peakBytes: peakBytes) } }
}

private final class MasterSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
    let track: ScreenMasterWriter.Track
    let hostTime: Double?
    private let bytes: Int
    private let budget: MasterSampleBudget
    var pts: CMTime { CMSampleBufferGetPresentationTimeStamp(buffer) }
    init(buffer: CMSampleBuffer, track: ScreenMasterWriter.Track, hostTime: Double?, bytes: Int, budget: MasterSampleBudget) {
        self.buffer = buffer; self.track = track; self.hostTime = hostTime; self.bytes = bytes; self.budget = budget
    }
    deinit { budget.release(bytes: bytes) }
}
