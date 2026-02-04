import AVFoundation
import Foundation
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "screencast.recording.queue")

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private var didStartRecording = false

    private var finishContinuation: CheckedContinuation<Void, any Error>?
    private var pendingFinishError: (any Error)?
    private var didFinish = false

    enum RecorderError: LocalizedError {
        case noFramesCaptured
        case writerFailed((any Error)?)

        var errorDescription: String? {
            switch self {
            case .noFramesCaptured:
                return "No frames were captured. Try recording again."
            case let .writerFailed(error):
                return error?.localizedDescription ?? "Recording failed."
            }
        }
    }

    func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        outputURL: URL
    ) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264

        let recordingOutput = SCRecordingOutput(
            configuration: recordingConfiguration,
            delegate: self
        )

        try stream.addRecordingOutput(recordingOutput)

        didStartRecording = false
        self.outputURL = outputURL
        pendingFinishError = nil
        didFinish = false

        try await stream.startCapture()
        self.stream = stream
        self.recordingOutput = recordingOutput
    }

    func stop() async throws {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            print("Stop capture reported error: \(error)")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            callbackQueue.async {
                if self.didFinish {
                    if let error = self.pendingFinishError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                    self.didFinish = false
                    self.pendingFinishError = nil
                    return
                }
                self.finishContinuation = continuation
            }
        }

        self.stream = nil

        if !didStartRecording {
            await cleanupFailedRecording()
            throw RecorderError.noFramesCaptured
        }

        if let outputURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue == 0 {
            await cleanupFailedRecording()
            throw RecorderError.noFramesCaptured
        }

        recordingOutput = nil
        self.outputURL = nil
    }

    private func cleanupFailedRecording() async {
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        didStartRecording = true
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        finishRecording(error: error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finishRecording(error: nil)
    }

    private func finishRecording(error: (any Error)?) {
        callbackQueue.async {
            if let continuation = self.finishContinuation {
                self.finishContinuation = nil
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
                return
            }
            self.pendingFinishError = error
            self.didFinish = true
        }
    }
}
