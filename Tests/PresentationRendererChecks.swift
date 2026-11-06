@preconcurrency import AVFoundation
import CoreImage
import Foundation

@main
@MainActor
struct PresentationRendererChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = directory.appendingPathComponent("screen.mov")
        let camera = directory.appendingPathComponent("camera.mov")
        try await movie(at: screen, width: 320, height: 180, camera: false)
        try await movie(at: camera, width: 80, height: 40, camera: true)
        let screenBytes = try Data(contentsOf: screen), cameraBytes = try Data(contentsOf: camera)
        var project = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", duration: 2)
        project.state.pipKeyframes[0].placement = PIPPlacement(x: 1, y: 0, scale: 0.25)
        let base = try await ProjectRenderer.makePreview(project: project, directory: directory)
        try require(base.sourceSize == CGSize(width: 320, height: 180) && base.screenSize == base.sourceSize,
                    "legacy/default preview keeps native capture dimensions")
        let baseConsumer = Consumer(base)
        _ = try await baseConsumer.image(at: 0.5)
        let sources = try await ProjectRenderer.prepareLiveSources(base, at: CMTime(seconds: 0.5, preferredTimescale: 600))
        baseConsumer.close()

        project.state.presentation = CanvasPresentation(aspect: .portrait, padding: 0.1, cornerRadius: 0.2,
            background: CanvasColor(red: 0.1, green: 0.2, blue: 0.3))
        let geometry = PresentationGeometry(sourceSize: base.sourceSize, presentation: project.state.presentation)
        let draft = ProjectRenderer.preview(base, applying: project.state)
        try require(draft.asset === base.asset && draft.sourceSize == base.sourceSize &&
                    draft.screenSize == geometry.outputSize && draft.videoComposition.renderSize == geometry.outputSize,
                    "presentation draft reuses original media and updates output dimensions")
        let live = try await ProjectRenderer.renderLivePreview(sources, applying: project.state,
            maximumSize: CGSize(width: 1000, height: 1000))
        try require(live.width == 180 && live.height == 320, "retained raw-source draft adopts the new output aspect")
        let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
        let consumer = Consumer(rendered)
        let preview = try await consumer.image(at: 0.5)
        consumer.close()
        try require(try maximumDifference(live, preview) <= 2, "live presentation drafts and saved preview render the same pixels")
        let content = geometry.contentRect
        try pixel(preview, x: 5, y: 250, equals: [26, 51, 77], context: "solid background")
        try pixel(preview, x: Int(content.minX + 1), y: Int(content.minY + 1), equals: [26, 51, 77], context: "rounded source corner exposes background")
        for (u, v, color) in [(0.25, 0.25, [255, 0, 0]), (0.75, 0.25, [0, 255, 0]),
                               (0.25, 0.75, [0, 0, 255]), (0.75, 0.75, [255, 255, 0])] {
            try pixel(preview, x: Int(content.minX + content.width * u), y: Int(content.minY + content.height * v),
                      equals: color, context: "full source quadrant")
        }
        try pixel(preview, x: Int(content.minX + 1), y: Int(content.midY), equals: [255, 255, 255], context: "left source edge is retained")
        try pixel(preview, x: Int(content.midX), y: Int(content.minY + 1), equals: [255, 255, 255], context: "top source edge is retained")
        try pixel(preview, x: 155, y: 10, equals: [255, 0, 255], context: "PIP stays in full output canvas, including its margin")

        var zoomed = project.state
        zoomed.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 2, x: 0.75, y: 0.25)]
        let zoomLive = try await ProjectRenderer.renderLivePreview(sources, applying: zoomed,
            maximumSize: CGSize(width: 1000, height: 1000))
        try pixel(zoomLive, x: Int(content.midX), y: Int(content.midY), equals: [0, 255, 0], context: "zoom/pan acts inside the source surface")
        try pixel(zoomLive, x: 5, y: 250, equals: [26, 51, 77], context: "zoom does not magnify the background")
        try pixel(zoomLive, x: 155, y: 10, equals: [255, 0, 255], context: "zoom does not move PIP")
        let smaller = try await ProjectRenderer.renderLivePreview(sources, applying: project.state,
            maximumSize: CGSize(width: 90, height: 160))
        try require(smaller.width == 90 && smaller.height == 160, "bounded live preview preserves presentation aspect")

        let destination = directory.appendingPathComponent("presentation.mp4")
        try await ProjectRenderer.export(project: project, directory: directory, to: destination)
        let asset = AVURLAsset(url: destination)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.failed("export video") }
        let exportSize = try await track.load(.naturalSize)
        try require(exportSize == geometry.outputSize, "export uses the same output dimensions")
        let generator = AVAssetImageGenerator(asset: asset)
        defer { generator.cancelAllCGImageGeneration() }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let exported = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let differences = zip(try rgba(preview), try rgba(exported)).map { abs(Int($0) - Int($1)) }
        let average = Double(differences.reduce(0, +)) / Double(differences.count)
        try require(average < 6, "compressed export matches preview framing, background, corners, and PIP (mean pixel difference \(average))")
        try require(try Data(contentsOf: screen) == screenBytes && Data(contentsOf: camera) == cameraBytes,
                    "presentation edits and export preserve original video bytes")
        print("Presentation renderer checks passed (source fit, rounded corners, background, PIP output coordinates, source zoom/pan, live/saved/export parity, native resolution, and original preservation).")
    }

    private static func movie(at url: URL, width: Int, height: Int, camera: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.failed("start fixture") }
        writer.startSession(atSourceTime: .zero)
        var optional: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &optional) == kCVReturnSuccess,
              let buffer = optional else { throw Failure.failed("fixture buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let rgb: [UInt8]
                if camera { rgb = [255, 0, 255] }
                else if x < 8 || x >= width - 8 || y < 8 || y >= height - 8 { rgb = [255, 255, 255] }
                else if y < height / 2 { rgb = x < width / 2 ? [255, 0, 0] : [0, 255, 0] }
                else { rgb = x < width / 2 ? [0, 0, 255] : [255, 255, 0] }
                let index = y * row + x * 4
                bytes[index] = rgb[2]; bytes[index + 1] = rgb[1]; bytes[index + 2] = rgb[0]; bytes[index + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for index in 0..<20 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData {
                guard ContinuousClock.now < deadline else { throw Failure.failed("fixture encoder stalled") }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)) else {
                throw writer.error ?? Failure.failed("append fixture")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.failed("finish fixture") }
    }

    @MainActor private final class Consumer {
        let rendered: RenderedProject
        let item: AVPlayerItem
        let output: AVPlayerItemVideoOutput
        let player: AVPlayer
        let context = CIContext(options: [.cacheIntermediates: false])
        init(_ rendered: RenderedProject) {
            self.rendered = rendered
            rendered.previewFrames.request(at: CMTime(seconds: 0.5, preferredTimescale: 600))
            item = AVPlayerItem(asset: rendered.asset)
            item.videoComposition = rendered.videoComposition
            item.seekingWaitsForVideoCompositionRendering = true
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.suppressesPlayerRendering = true
            item.add(output)
            player = AVPlayer(playerItem: item)
            player.isMuted = true
        }
        func close() { player.pause(); item.remove(output); player.replaceCurrentItem(with: nil) }
        func image(at seconds: Double) async throws -> CGImage {
            let target = CMTime(seconds: seconds, preferredTimescale: 600)
            let ready = ContinuousClock.now.advanced(by: .seconds(5))
            while item.status == .unknown && ContinuousClock.now < ready { try await Task.sleep(for: .milliseconds(5)) }
            guard item.status == .readyToPlay else { throw item.error ?? Failure.failed("preview ready") }
            rendered.previewFrames.request(at: target)
            guard await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) else { throw Failure.failed("preview seek") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if let buffer = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) {
                    let image = CIImage(cvPixelBuffer: buffer)
                    if let result = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { return result }
                }
                if item.status == .failed { throw item.error ?? Failure.failed("preview failed") }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw Failure.failed("preview frame timed out")
        }
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.failed("pixel context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
    private static func pixel(_ image: CGImage, x: Int, y: Int, equals expected: [Int], context: String) throws {
        let bytes = try rgba(image), index = (y * image.width + x) * 4
        let actual = [Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])]
        try require(zip(actual, expected).allSatisfy { abs($0 - $1) <= 25 }, "\(context): \(actual), expected \(expected)")
    }
    private static func maximumDifference(_ first: CGImage, _ second: CGImage) throws -> Int {
        try require(first.width == second.width && first.height == second.height, "matching preview sizes")
        return zip(try rgba(first), try rgba(second)).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
}
