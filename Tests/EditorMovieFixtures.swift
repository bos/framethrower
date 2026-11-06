@preconcurrency import AVFoundation
import AppKit

@MainActor
enum EditorMovieFixtures {
    enum FixtureError: Error { case failed(String) }

    static func make(at url: URL, width: Int, height: Int, duration: Int, camera: Bool) async throws {
        try MediaProcessing.requireEnabled()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.failed("start movie fixture") }
        writer.startSession(atSourceTime: .zero)
        let frameCount = duration * 10
        for index in 0..<frameCount {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else {
                    throw writer.error ?? FixtureError.failed("movie fixture encoder stalled")
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            var optional: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                      nil, &optional) == kCVReturnSuccess, let buffer = optional else {
                throw FixtureError.failed("fixture pixel buffer")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let progress = Double(index) / Double(frameCount)
            context.setFillColor(CGColor(red: camera ? 0.9 : progress, green: camera ? progress : 0.2,
                                         blue: camera ? 0.2 : 1 - progress, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: Double(width) * progress, y: Double(height) * 0.25,
                                width: Double(width) * 0.12, height: Double(height) * 0.5))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
                throw writer.error ?? FixtureError.failed("append movie fixture")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(duration), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.failed("finish movie fixture") }
    }
}
