@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

/// ScreenCaptureKit owns encoding; this extra stream output records the first
/// usable frame's host timestamp for alignment with the independent camera.
final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, SCStreamOutput,
    SCStreamDelegate, @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "screencast.recording.queue")
    // All mutable state below is confined to callbackQueue.
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var lifecycle = ScreenRecordingState()
    private var startContinuation: CheckedContinuation<Double, any Error>?
    private var finishContinuation: CheckedContinuation<Void, any Error>?
    private var isStarting = false
    private var isStopping = false

    enum RecorderError: LocalizedError {
        case noFramesCaptured
        case timedOut
        case alreadyRecording
        var errorDescription: String? {
            switch self {
            case .noFramesCaptured: return "No frames were captured. Try recording again."
            case .timedOut: return "Screen capture did not respond. Any captured media has been kept."
            case .alreadyRecording: return "Screen capture is already starting, recording, or stopping."
            }
        }
    }

    @discardableResult
    func start(filter: SCContentFilter, configuration: SCStreamConfiguration,
               outputURL: URL) async throws -> Double {
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try newStream.addRecordingOutput(output)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: callbackQueue)
        try callbackQueue.sync {
            guard stream == nil else { throw RecorderError.alreadyRecording }
            stream = newStream
            recordingOutput = output
            lifecycle = ScreenRecordingState()
            isStarting = true
        }
        let deadline = DispatchTime.now() + 12
        do {
            try await CaptureOperationDeadline.run(seconds: 12, timeoutError: RecorderError.timedOut) { completion in
                newStream.startCapture(completionHandler: completion)
            }
            let firstHostTime: Double = try await withCheckedThrowingContinuation { continuation in
                callbackQueue.async {
                    self.startContinuation = continuation
                    self.resolveStart()
                    self.callbackQueue.asyncAfter(deadline: deadline) {
                        guard self.stream === newStream, let waiting = self.startContinuation else { return }
                        self.startContinuation = nil
                        waiting.resume(throwing: RecorderError.timedOut)
                    }
                }
            }
            callbackQueue.sync { isStarting = false }
            return firstHostTime
        } catch {
            // Cleanup must also be bounded: framework start/stop callbacks can
            // fail to arrive after a device/permission interruption.
            try? await CaptureOperationDeadline.run(seconds: 3, timeoutError: RecorderError.timedOut) { completion in
                newStream.stopCapture(completionHandler: completion)
            }
            callbackQueue.sync {
                if stream === newStream {
                    stream = nil
                    recordingOutput = nil
                    isStarting = false
                }
            }
            throw error
        }
    }

    /// ScreenCaptureKit's movie may contain audio before its first video frame.
    /// Inspect encoded timestamps, without decoding pixels, to map host time to
    /// that movie timeline. H.264 reordering is bounded to sixteen pictures;
    /// inspecting the first thirty-two samples includes the first display frame.
    static func firstVideoPresentationTime(in url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RecorderError.noFramesCaptured
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecorderError.noFramesCaptured }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.noFramesCaptured }
        defer { reader.cancelReading() }
        var first = Double.infinity
        for _ in 0..<32 {
            guard let sample = output.copyNextSampleBuffer() else { break }
            // Empty edit-list markers can carry a valid zero timestamp without
            // containing a picture. They are not the first captured video frame.
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if timestamp.isFinite, timestamp >= 0 { first = min(first, timestamp) }
        }
        guard first.isFinite else { throw reader.error ?? RecorderError.noFramesCaptured }
        // Compressed-reader samples use the media timeline. A movie edit list
        // can place that media later in the movie (for example audio at zero).
        let segments = try await track.load(.segments)
        if let segment = segments.first(where: { !$0.isEmpty }) {
            let mapping = segment.timeMapping
            let source = mapping.source.start.seconds
            let target = mapping.target.start.seconds
            if source.isFinite, target.isFinite {
                first += target - source
            }
        }
        return max(0, first)
    }

    func stop() async throws {
        guard let active = try callbackQueue.sync(execute: { () throws -> SCStream? in
            guard let stream else { return nil }
            guard !isStarting, !isStopping else { throw RecorderError.alreadyRecording }
            isStopping = true
            return stream
        }) else { return }
        let deadline = DispatchTime.now() + 15
        defer {
            callbackQueue.sync {
                stream = nil
                recordingOutput = nil
                isStopping = false
            }
        }
        do {
            try await CaptureOperationDeadline.run(seconds: 15, timeoutError: RecorderError.timedOut) { completion in
                active.stopCapture(completionHandler: completion)
            }
        } catch {
            callbackQueue.async {
                guard self.stream === active else { return }
                self.lifecycle.recordStreamFailure(error)
                // A stream stop error does not mean the recording output has
                // finished flushing its file. Await its delegate or deadline.
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            callbackQueue.async {
                if let result = self.lifecycle.finishResult {
                    continuation.resume(with: result)
                } else {
                    self.finishContinuation = continuation
                    self.callbackQueue.asyncAfter(deadline: deadline) {
                        guard self.stream === active else { return }
                        self.finishRecording(error: RecorderError.timedOut)
                    }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard self.stream === stream, type == .screen, lifecycle.firstFrameTime == nil,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              ScreenRecordingState.acceptsFirstFrame(status: SCFrameStatus(rawValue: status)) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let clock = stream.synchronizationClock else { return }
        let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        guard host.seconds.isFinite else { return }
        lifecycle.firstFrameTime = host.seconds
        resolveStart()
    }

    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        callbackQueue.async {
            guard self.recordingOutput === output else { return }
            self.lifecycle.didStartRecording = true
            self.resolveStart()
        }
    }

    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: any Error) {
        callbackQueue.async {
            guard self.recordingOutput === output else { return }
            self.finishRecording(error: error)
        }
    }

    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        callbackQueue.async {
            guard self.recordingOutput === output else { return }
            self.finishRecording(error: nil)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        callbackQueue.async {
            guard self.stream === stream else { return }
            self.lifecycle.recordStreamFailure(error)
            self.resolveStart()
        }
    }

    private func resolveStart() {
        guard let continuation = startContinuation, let result = lifecycle.startResult else { return }
        startContinuation = nil
        continuation.resume(with: result)
    }

    private func finishRecording(error: (any Error)?) {
        lifecycle.finish(error: error)
        resolveStart()
        if let continuation = finishContinuation, let result = lifecycle.finishResult {
            finishContinuation = nil
            continuation.resume(with: result)
        }
    }
}


/// Hardware-independent event ordering shared by the real recorder and tests.
/// A stream stopping is distinct from the output finishing its encoded file.
struct ScreenRecordingState {
    var didStartRecording = false
    var firstFrameTime: Double?
    private(set) var didFinish = false
    private(set) var error: (any Error)?

    static func acceptsFirstFrame(status: SCFrameStatus?) -> Bool {
        // A data-bearing .started sample can be the initial recorded frame,
        // particularly when an otherwise static display produces only idle updates.
        status == .complete || status == .started
    }

    var startResult: Result<Double, any Error>? {
        if let error { return .failure(error) }
        if didFinish { return .failure(ScreenRecorder.RecorderError.noFramesCaptured) }
        guard didStartRecording, let firstFrameTime, firstFrameTime.isFinite else { return nil }
        return .success(firstFrameTime)
    }

    var finishResult: Result<Void, any Error>? {
        guard didFinish else { return nil }
        if let error { return .failure(error) }
        return .success(())
    }

    mutating func recordStreamFailure(_ error: any Error) {
        self.error = self.error ?? error
    }

    mutating func finish(error: (any Error)?) {
        guard !didFinish else { return }
        didFinish = true
        self.error = error ?? self.error
    }
}


/// Bounds SDK operations whose asynchronous callback may never arrive. The gate
/// owns exactly one continuation, so callbacks racing the deadline (or invoking
/// completion twice) cannot resume a task more than once.
final class CaptureOperationDeadline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "framethrower.capture.deadline")
    private var continuation: CheckedContinuation<Void, any Error>?

    static func run(seconds: Double, timeoutError: any Error,
                    operation: @escaping @Sendable (@escaping @Sendable ((any Error)?) -> Void) -> Void) async throws {
        let gate = CaptureOperationDeadline()
        try await withCheckedThrowingContinuation { continuation in
            gate.queue.async {
                gate.continuation = continuation
                gate.queue.asyncAfter(deadline: .now() + seconds) { gate.finish(timeoutError) }
                operation { error in gate.queue.async { gate.finish(error) } }
            }
        }
    }

    private func finish(_ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}
