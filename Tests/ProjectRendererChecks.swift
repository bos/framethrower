@preconcurrency import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation

@main
@MainActor
struct ProjectRendererChecks {
    enum CheckError: Error { case failed(String) }

    @MainActor
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = directory.appendingPathComponent("screen.mov")
        let camera = directory.appendingPathComponent("camera.mov")
        try await movie(to: screen, width: 160, height: 120, duration: 5, camera: false)
        try await movie(to: camera, width: 80, height: 40, duration: 5, camera: true)
        let originalScreen = try Data(contentsOf: screen)
        let originalCamera = try Data(contentsOf: camera)
        var project = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", duration: 5)
        project.state.pipKeyframes = [
            PIPKeyframe(time: 0, placement: PIPPlacement(x: 0, y: 0, scale: 0.25)),
            PIPKeyframe(time: 1, placement: PIPPlacement(x: 1, y: 0, scale: 0.25), transition: .jump),
            PIPKeyframe(time: 3, placement: PIPPlacement(x: 0, y: 1, scale: 0.5), transition: .smooth, duration: 1),
            PIPKeyframe(time: 4, placement: PIPPlacement(x: 0, y: 1, scale: 0.5, visible: false))
        ]
        let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
        try require(rendered.screenSize == CGSize(width: 160, height: 120), "native screen dimensions")
        let sourceAudio = try await AVURLAsset(url: screen).loadTracks(withMediaType: .audio)
        let compositionAudio = try await rendered.asset.loadTracks(withMediaType: .audio)
        try require(sourceAudio.count == 2 && compositionAudio.count == 2, "both independent source audio tracks retained")
        try require(abs(rendered.cameraAspect - 2) < 0.0001, "native camera aspect")
        try await frame(rendered, at: 0.5, expected: CGRect(x: 0, y: 0, width: 40, height: 20))
        try await frame(rendered, at: 29.0 / 30, expected: CGRect(x: 0, y: 0, width: 40, height: 20))
        try await frame(rendered, at: 1, expected: CGRect(x: 120, y: 0, width: 40, height: 20))
        try await frame(rendered, at: 1.5, expected: CGRect(x: 120, y: 0, width: 40, height: 20))
        try await frame(rendered, at: 2.25, expected: CGRect(x: 96, y: 15, width: 46, height: 23), yellow: true)
        try await frame(rendered, at: 2.75, expected: CGRect(x: 13.5, y: 70, width: 74, height: 37), yellow: true)
        try await frame(rendered, at: 2.5, expected: CGRect(x: 50, y: 45, width: 60, height: 30), yellow: true)
        try await frame(rendered, at: 3, expected: CGRect(x: 0, y: 80, width: 80, height: 40), yellow: true)
        try await frame(rendered, at: 4, expected: nil)

        // Camera begins later than the screen: no held first frame before it exists.
        var delayed = project
        delayed.cameraOffset = 1
        let delayedRender = try await ProjectRenderer.makePreview(project: delayed, directory: directory)
        try await frame(delayedRender, at: 0.5, expected: nil)
        try await frame(delayedRender, at: 1, expected: CGRect(x: 120, y: 0, width: 40, height: 20))

        // Camera began before the screen: use its later source frames at source time zero.
        var early = project
        early.cameraOffset = -2
        early.state.pipKeyframes = [PIPKeyframe(time: 0, placement: PIPPlacement(x: 0, y: 0, scale: 0.25))]
        let earlyRender = try await ProjectRenderer.makePreview(project: early, directory: directory)
        try await frame(earlyRender, at: 0, expected: CGRect(x: 0, y: 0, width: 40, height: 20), yellow: true)
        try await frame(earlyRender, at: 3.5, expected: nil)

        let plain = RecordingProject(screenFilename: "screen.mov", duration: 5)
        let plainRender = try await ProjectRenderer.makePreview(project: plain, directory: directory)
        try await frame(plainRender, at: 0.5, expected: nil)
        let plainAudio = try await plainRender.asset.loadTracks(withMediaType: .audio)
        try require(plainAudio.count == 2, "screen-only composition retains all audio")

        let rotatedURL = directory.appendingPathComponent("rotated.mov")
        try await movie(to: rotatedURL, width: 80, height: 40, duration: 5, camera: true,
                        transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 40, ty: 0))
        var rotated = RecordingProject(screenFilename: "screen.mov", cameraFilename: "rotated.mov", duration: 5)
        rotated.state.pipKeyframes = [PIPKeyframe(time: 0, placement: PIPPlacement(x: 1, y: 1, scale: 0.25))]
        let rotatedRender = try await ProjectRenderer.makePreview(project: rotated, directory: directory)
        try require(abs(rotatedRender.cameraAspect - 0.5) < 0.0001, "camera preferred transform determines aspect")
        try await frame(rotatedRender, at: 0.5, expected: CGRect(x: 120, y: 40, width: 40, height: 80))

        var tinyOverlap = project
        tinyOverlap.cameraOffset = 4.999999
        _ = try await ProjectRenderer.makePreview(project: tinyOverlap, directory: directory)

        project.state.trimStart = 1
        project.state.trimEnd = 3.5
        let destination = directory.appendingPathComponent("export.mp4")
        try await ProjectRenderer.export(project: project, directory: directory, to: destination)
        let exported = AVURLAsset(url: destination)
        let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
        try require(!exportedAudio.isEmpty, "export retains recorded audio")
        let exportedDuration = try await exported.load(.duration).seconds
        try require(abs(exportedDuration - 2.5) < 1.0 / 30, "trim export duration")
        let generator = AVAssetImageGenerator(asset: exported)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (firstImage, _) = try await generator.image(at: .zero)
        try checkBounds(firstImage, expected: CGRect(x: 120, y: 0, width: 40, height: 20))
        let (middleImage, _) = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600))
        try checkBounds(middleImage, expected: CGRect(x: 50, y: 45, width: 60, height: 30), yellow: true)
        do {
            try await ProjectRenderer.export(project: project, directory: directory, to: screen)
            throw CheckError.failed("renderer overwrote an original")
        } catch ProjectRenderer.RenderError.destinationExists { }
        do {
            try await ProjectRenderer.export(project: project, directory: directory, to: destination)
            throw CheckError.failed("renderer overwrote an existing export")
        } catch ProjectRenderer.RenderError.destinationExists { }
        try require(try Data(contentsOf: screen) == originalScreen, "screen source remains byte-identical")
        try require(try Data(contentsOf: camera) == originalCamera, "camera source remains byte-identical")
        print("Project renderer checks passed (jump, easing, visibility, sync offsets, camera orientation, independent audio tracks, screen-only, trim, export parity, source preservation).")
    }

    @MainActor
    private static func frame(_ rendered: RenderedProject, at seconds: Double, expected: CGRect?, yellow: Bool = false) async throws {
        let generator = AVAssetImageGenerator(asset: rendered.asset)
        generator.videoComposition = rendered.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        try checkBounds(image, expected: expected, yellow: yellow)
    }

    private static func checkBounds(_ image: CGImage, expected: CGRect?, yellow: Bool = false) throws {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CheckError.failed("image context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let matches = rgba[offset + 1] > 150 && rgba[offset + 2] < 100 &&
                    (yellow ? rgba[offset] > 150 : rgba[offset] < 100)
                if matches {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        if let expected {
            let actual = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            try require(maxX >= 0 && abs(actual.minX - expected.minX) <= 2 && abs(actual.minY - expected.minY) <= 2 &&
                abs(actual.width - expected.width) <= 3 && abs(actual.height - expected.height) <= 3,
                "camera bounds \(actual), expected \(expected), yellow=\(yellow)")
        } else {
            try require(maxX < 0, "hidden/missing camera must not appear")
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckError.failed(message) }
    }

    private static func ready(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw writer.error ?? CheckError.failed("synthetic writer stopped")
            }
            guard Date() < deadline else { throw CheckError.failed("synthetic writer stalled on \(input.mediaType)") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func audioSamples(frame: Int, frequency: Double) throws -> CMSampleBuffer {
        let count = 1_600
        let samples = (0..<count).map { index in
            Float(sin(Double(frame * count + index) * frequency * 2 * .pi / 48_000) * 0.15)
        }
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        ) == noErr, let description else { throw CheckError.failed("audio description") }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { throw CheckError.failed("audio data buffer") }
        let copyStatus = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copyStatus == noErr else { throw CheckError.failed("audio samples copy") }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(frame * count), timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var size = 4
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer
        ) == noErr, let buffer else { throw CheckError.failed("audio sample buffer") }
        return buffer
    }

    private static func movie(to url: URL, width: Int, height: Int, duration: Int, camera: Bool, transform: CGAffineTransform = .identity) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        input.transform = transform
        writer.add(input)
        var audioInputs: [AVAssetWriterInput] = []
        if !camera {
            for _ in 0..<2 {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000
                ])
                writer.add(audio)
                audioInputs.append(audio)
            }
        }
        guard writer.startWriting() else { throw writer.error ?? CheckError.failed("start synthetic writer") }
        writer.startSession(atSourceTime: .zero)
        let video = Task { @MainActor in
            try await fillVideo(input, adaptor: adaptor, writer: writer, width: width, height: height, duration: duration, camera: camera)
        }
        var audioTasks: [Task<Void, any Error>] = []
        for (track, audio) in audioInputs.enumerated() {
            audioTasks.append(Task { @MainActor in
                    for index in 0..<(duration * 30) {
                        try await ready(audio, writer: writer)
                        guard audio.append(try audioSamples(frame: index, frequency: Double(440 * (track + 1)))) else {
                            throw writer.error ?? CheckError.failed("append synthetic audio")
                        }
                    }
                    audio.markAsFinished()
            })
        }
        for task in audioTasks { try await task.value }
        try await video.value
        writer.endSession(atSourceTime: CMTime(value: Int64(duration), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CheckError.failed("finish synthetic writer") }
    }
    private static func fillVideo(_ input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter,
                                  width: Int, height: Int, duration: Int, camera: Bool) async throws {
        for index in 0..<(duration * 30) {
            try await ready(input, writer: writer)
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw CheckError.failed("synthetic pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    base[offset] = camera ? 0 : 255
                    base[offset + 1] = camera ? 255 : 0
                    base[offset + 2] = camera && index >= 60 ? 255 : 0
                    base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? CheckError.failed("append synthetic frame")
            }
        }
        input.markAsFinished()
    }

}
