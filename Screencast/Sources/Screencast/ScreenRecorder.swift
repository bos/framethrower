import AVFoundation
import Foundation
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let videoQueue = DispatchQueue(label: "screencast.video.queue")

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false

    func start(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        outputURL: URL
    ) async throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw URLError(.cannotCreateFile)
        }

        writer.add(input)
        assetWriter = writer
        videoInput = input
        sessionStarted = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async throws {
        guard let stream else { return }
        try await stream.stopCapture()
        self.stream = nil

        await withCheckedContinuation { continuation in
            videoInput?.markAsFinished()
            assetWriter?.finishWriting {
                continuation.resume()
            }
        }
        assetWriter = nil
        videoInput = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let writer = assetWriter, let input = videoInput else { return }

        if !sessionStarted {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: time)
            sessionStarted = true
        }

        guard input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func stream(
        _ stream: SCStream,
        didStopWithError error: any Error
    ) {
        print("Stream stopped with error: \(error)")
    }
}
