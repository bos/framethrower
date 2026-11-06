@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

/// ScreenCaptureKit owns encoding; this extra stream output records the first
/// complete frame's host timestamp for alignment with the independent camera.
final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, SCStreamOutput,
    SCStreamDelegate, @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "screencast.recording.queue")
    // All mutable state below is confined to callbackQueue.
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var didStartRecording = false
    private var firstFrameTime: Double?
    private var startContinuation: CheckedContinuation<Double, any Error>?
    private var finishContinuation: CheckedContinuation<Void, any Error>?
    private var pendingFinishError: (any Error)?
    private var didFinish = false

    enum RecorderError: LocalizedError {
        case noFramesCaptured
        case timedOut
        var errorDescription: String? {
            switch self {
            case .noFramesCaptured: return "No frames were captured. Try recording again."
            case .timedOut: return "Screen capture did not respond. Any captured media has been kept."
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
        callbackQueue.sync {
            stream = newStream
            recordingOutput = output
            didStartRecording = false
            firstFrameTime = nil
            pendingFinishError = nil
            didFinish = false
        }
        do {
            try await newStream.startCapture()
            return try await withCheckedThrowingContinuation { continuation in
                callbackQueue.async {
                    self.startContinuation = continuation
                    self.resolveStart()
                    self.callbackQueue.asyncAfter(deadline: .now() + 12) {
                        guard self.stream === newStream, let waiting = self.startContinuation else { return }
                        self.startContinuation = nil
                        waiting.resume(throwing: RecorderError.timedOut)
                    }
                }
            }
        } catch {
            try? await newStream.stopCapture()
            callbackQueue.sync {
                stream = nil
                recordingOutput = nil
            }
            throw error
        }
    }

    func stop() async throws {
        guard let active = callbackQueue.sync(execute: { stream }) else { return }
        defer {
            callbackQueue.sync {
                stream = nil
                recordingOutput = nil
            }
        }
        do {
            try await active.stopCapture()
        } catch {
            callbackQueue.async { self.finishRecording(error: error) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            callbackQueue.async {
                if self.didFinish {
                    if let error = self.pendingFinishError { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                } else {
                    self.finishContinuation = continuation
                    self.callbackQueue.asyncAfter(deadline: .now() + 15) {
                        guard self.stream === active else { return }
                        self.finishRecording(error: RecorderError.timedOut)
                    }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard self.stream === stream, type == .screen, firstFrameTime == nil,
              sampleBuffer.isValid, CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = stream.synchronizationClock.map {
            CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock())
        } ?? pts
        guard host.seconds.isFinite else { return }
        firstFrameTime = host.seconds
        resolveStart()
    }

    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        callbackQueue.async {
            guard self.recordingOutput === output else { return }
            self.didStartRecording = true
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
            self.finishRecording(error: error)
        }
    }

    private func resolveStart() {
        guard let continuation = startContinuation else { return }
        if let error = pendingFinishError {
            startContinuation = nil
            continuation.resume(throwing: error)
        } else if didStartRecording, let firstFrameTime {
            startContinuation = nil
            continuation.resume(returning: firstFrameTime)
        } else if didFinish {
            startContinuation = nil
            continuation.resume(throwing: RecorderError.noFramesCaptured)
        }
    }

    private func finishRecording(error: (any Error)?) {
        guard !didFinish else { return }
        didFinish = true
        pendingFinishError = error
        resolveStart()
        if let continuation = finishContinuation {
            finishContinuation = nil
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}
