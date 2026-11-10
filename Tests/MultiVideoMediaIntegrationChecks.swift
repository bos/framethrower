@preconcurrency import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreImage
import Foundation

/// Prerecorded files only. This executable has no capture/device code in its
/// compilation graph. Fixture encoding is bounded to one software worker.
@main @MainActor
struct MultiVideoMediaIntegrationChecks {
    enum Failure: Error { case failed(String) }
    static var phase = "import"
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.failed(message) }
    }
    static func main() async {
        do { try await checks() }
        catch {
            FileHandle.standardError.write(Data("Recorded multi-video integration failed during \(phase): \(error)\n".utf8))
            exit(1)
        }
    }
    static func checks() async throws {
        try require(!MediaProcessing.isSuspended, "recorded media must be explicitly enabled")
        try require(MediaProcessing.isCaptureSuspended, "live capture must remain suspended")
        guard CommandLine.arguments.count == 2 else { throw Failure.failed("fixture directory argument") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let originals = ["primary.mov", "A.mov", "B.mov", "portrait.mov"]
        let before = try Dictionary(uniqueKeysWithValues: originals.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) })
        let editor = try await VideoImporter.importVideo(at: directory.appendingPathComponent("primary.mov"))
        _ = try await ProjectVideoImport.addSources(["A.mov", "B.mov", "portrait.mov"].map { directory.appendingPathComponent($0) }, to: editor, at: 0)
        try require(editor.project.videoAssets.count == 3, "actual managed import registers three immutable sources")
        let a = editor.project.videoAssets.first { $0.name == "A" }!
        let b = editor.project.videoAssets.first { $0.name == "B" }!
        let portrait = editor.project.videoAssets.first { $0.name == "portrait" }!
        try require(portrait.pixelWidth == 48 && portrait.pixelHeight == 96, "preferred rotation is reflected in imported portrait dimensions: \(String(describing: portrait.pixelSize))")
        var copied: [URL: Data] = [:]
        for source in editor.project.videoAssets {
            let url = try source.resolvedURL(in: directory)
            let data = try Data(contentsOf: url)
            copied[url] = data
            try require(data == before[source.name + ".mov"], "managed import preserves original encoded bytes")
        }
        var project = editor.project
        project.state.videoLayers = [VideoLayer(name: "Sequence", clips: [
            VideoClip(sourceID: a.id, start: 0, end: 2, rate: 2, volume: 0.8,
                volumeKeyframes: [.init(time: 2, gain: 0.5, transition: .jump)]),
            VideoClip(sourceID: b.id, start: 1, end: 2.75, volume: 0.5),
            VideoClip(sourceID: a.id, start: 2.75, end: 3, isMuted: true, transition: .cut)
        ]), VideoLayer(name: "Portrait", clips: [VideoClip(sourceID: portrait.id, start: 0, end: 3,
            geometry: VideoGeometry(rect: .init(x: 0.75, y: 0, width: 0.25, height: 0.5),
                crop: .init(x: 0, y: 0, width: 1, height: 0.5), fit: .fill), opacity: 0.5, isMuted: true)])]
        try project.validate()
        try require(project.videoAssets.count == 3 && project.state.videoLayers![0].clips[0].sourceID == project.state.videoLayers![0].clips[2].sourceID,
            "two occurrences reuse the same registered bytes")
        print("Managed imports and source reuse passed; preparing actual composition.")
        phase = "composition preparation"
        let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
        try require(rendered.screenSize == CGSize(width: 96, height: 64), "project canvas retains primary native dimensions")
        let preview = NativePreview(rendered: rendered)
        defer { preview.close() }
        phase = "native preview"
        let previewImage = try await preview.image(at: 0.75)
        try yellow(pixel(previewImage, x: 20, y: 40), "native preview uses 2× clip source clock")
        try await preview.playForReview()
        preview.close()
        let exportedURL = directory.appendingPathComponent("layered-\(UUID().uuidString).mp4")
        phase = "layered export"
        try await ProjectRenderer.export(project: project, directory: directory, to: exportedURL)
        let exported = AVURLAsset(url: exportedURL)
        phase = "export frame decoding"
        let exportedDuration = try await exported.load(.duration).seconds
        try require(abs(exportedDuration - 3) < 0.09, "actual export duration")
        let generator = AVAssetImageGenerator(asset: exported)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        defer { generator.cancelAllCGImageGeneration() }
        let early = try await frame(generator, at: 0.25)
        let fast = try await frame(generator, at: 0.75)
        let midpoint = try await frame(generator, at: 1.5)
        let reused = try await frame(generator, at: 2.9)
        try red(pixel(early, x: 20, y: 40), "early source frame")
        try yellow(pixel(fast, x: 20, y: 40), "export uses same 2× source clock as preview")
        try red(pixel(reused, x: 20, y: 40), "reused occurrence begins at original source zero")
        let gray = try pixel(midpoint, x: 20, y: 40)
        try require((gray.max()! - gray.min()!) < 18 && gray.min()! > 105,
            "same-layer complementary-color crossdissolve stays neutral and bright: \(gray)")
        let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: try portrait.resolvedURL(in: directory)))
        sourceGenerator.appliesPreferredTrackTransform = true
        defer { sourceGenerator.cancelAllCGImageGeneration() }
        let oriented = try await frame(sourceGenerator, at: 0.75)
        try require(oriented.width == 48 && oriented.height == 96, "native portrait decoder orientation")
        // The explicit top-half crop and fill viewport resolve to x6…42,y0…48
        // in the oriented source, mapped into x72…96,y0…32 on the canvas.
        for (x, y) in [(76, 5), (91, 25)] {
            let sx = 6 + Double(x - 72) / 24 * 36, sy = Double(y) / 32 * 48
            let original = try pixel(oriented, x: Int(sx), y: Int(sy))
            let composed = try pixel(fast, x: x, y: y)
            for channel in 0..<3 {
                let background = [255, 255, 0][channel]
                if abs(original[channel] - background) < 35 {
                    try require(abs(composed[channel] - background) < 40, "oriented crop maps correct source quadrant: \(original) → \(composed)")
                } else {
                    try require(composed[channel] > 90 && composed[channel] < 235, "portrait layer blends the exact cropped source quadrant: \(original) → \(composed)")
                }
            }
            try require(zip(composed, original).contains { abs($0 - $1) > 12 }, "portrait opacity remains independent of source alpha")
            try require(composed != (try pixel(fast, x: 20, y: 40)), "portrait second layer is visible in its own rectangle")
        }
        phase = "exported PCM audio"
        let audio = try await pcm(exported)
        let aBefore = amplitude(audio, at: 0.5, frequency: 440)
        let aDuring = amplitude(audio, at: 1.5, frequency: 440)
        let bDuring = amplitude(audio, at: 1.5, frequency: 880)
        let bAfter = amplitude(audio, at: 2.5, frequency: 880)
        try require(aBefore > 0.03 && bAfter > 0.02, "both original audio tones survive actual export: \(aBefore),\(bAfter)")
        try require(abs(aDuring / aBefore - 0.25) < 0.09,
            "source-time envelope × outgoing dissolve baked into exported PCM: ratio \(aDuring / aBefore)")
        try require(abs(bDuring / bAfter - 0.5) < 0.12,
            "incoming audio follows visual dissolve: ratio \(bDuring / bAfter)")
        var cut = project
        cut.state.cuts = [.init(start: 1, end: 2, crossfade: 0.5)]
        let cutURL = directory.appendingPathComponent("cut-layered-\(UUID().uuidString).mp4")
        phase = "global cut export"
        try await ProjectRenderer.export(project: cut, directory: directory, to: cutURL)
        let cutAsset = AVURLAsset(url: cutURL)
        let cutDuration = try await cutAsset.load(.duration).seconds
        try require(abs(cutDuration - 1.5) < 0.09, "global cut retimes the complete stack")
        let cutGenerator = AVAssetImageGenerator(asset: cutAsset)
        cutGenerator.requestedTimeToleranceBefore = .zero; cutGenerator.requestedTimeToleranceAfter = .zero
        defer { cutGenerator.cancelAllCGImageGeneration() }
        let cutImage = try await frame(cutGenerator, at: 0.75)
        let cutGray = try pixel(cutImage, x: 20, y: 40)
        try require(cutGray.max()! - cutGray.min()! < 25 && cutGray.min()! > 100,
            "global cut dissolves complete source-project compositions: \(cutGray)")
        phase = "legacy cut camera composition"
        var legacy = RecordingProject(screenFilename: "primary.mov", cameraFilename: "portrait.mov", duration: 3,
            captureFrameDuration: 1.0 / 12)
        legacy.state.cuts = [.init(start: 1, end: 2, crossfade: 0.5)]
        let legacyRender = try await ProjectRenderer.makePreview(project: legacy, directory: directory)
        try require(abs(legacyRender.cameraAspect - 0.5) < 1e-6, "legacy cut camera retains its source asset and portrait geometry")
        let legacyPreview = NativePreview(rendered: legacyRender)
        defer { legacyPreview.close() }
        let legacyImage = try await legacyPreview.image(at: 0.25)
        try require(try pixel(legacyImage, x: 84, y: 40).max()! > 100, "actual legacy cut preview includes recorded camera file")
        legacyPreview.close()
        for name in originals { try require(try Data(contentsOf: directory.appendingPathComponent(name)) == before[name], "original remains byte-identical") }
        for (url, bytes) in copied { try require(try Data(contentsOf: url) == bytes, "managed source remains byte-identical") }
        do {
            try await ProjectRenderer.export(project: project, directory: directory, to: try a.resolvedURL(in: directory), replaceExisting: true)
            throw Failure.failed("export replaced a registered original")
        } catch ProjectRenderer.RenderError.destinationExists { }
        print("Recorded multi-video integration passed: actual managed import, rotated portrait/crop, source reuse/2× rate, native preview, layer/global crossfades, exported PCM gains, source preservation. Live capture stayed disabled.")
    }

    static func frame(_ generator: AVAssetImageGenerator, at seconds: Double) async throws -> CGImage {
        try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 60_000)).image
    }
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [Int] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure.failed("pixel context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        return (0..<3).map { Int(data[offset + $0]) }
    }
    static func red(_ color: [Int], _ message: String) throws { try require(color[0] > 210 && color[1] < 45 && color[2] < 45, message + ": \(color)") }
    static func yellow(_ color: [Int], _ message: String) throws { try require(color[0] > 210 && color[1] > 210 && color[2] < 45, message + ": \(color)") }
    static func pcm(_ asset: AVAsset) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        try require(!tracks.isEmpty, "export contains audio")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        try require(reader.startReading(), "start exported PCM reader")
        var samples = [Float](repeating: 0, count: Int(ceil(try await asset.load(.duration).seconds * 48_000)) + 4_800)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure.failed("PCM block") }
            let count = CMSampleBufferGetNumSamples(sample)
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }
            try require(status == noErr, "copy actual exported PCM")
            let start = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 48_000).rounded())
            for index in values.indices where start + index >= 0 && start + index < samples.count { samples[start + index] = values[index] }
        }
        try require(reader.status == .completed, "exported PCM decoding completed: \(String(describing: reader.error))")
        return samples
    }
    static func amplitude(_ samples: [Float], at time: Double, frequency: Double) -> Double {
        let first = Int((time - 0.05) * 48_000), count = 4_800
        var real = 0.0, imaginary = 0.0
        for index in 0..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            real += Double(samples[first + index]) * cos(phase)
            imaginary += Double(samples[first + index]) * sin(phase)
        }
        return hypot(real, imaginary) * 2 / Double(count)
    }

    @MainActor final class NativePreview {
        let item: AVPlayerItem
        let output: AVPlayerItemVideoOutput
        let player: AVPlayer
        private var isClosed = false
        init(rendered: RenderedProject) {
            item = AVPlayerItem(asset: rendered.asset); item.videoComposition = rendered.videoComposition; item.audioMix = rendered.audioMix
            item.seekingWaitsForVideoCompositionRendering = true
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.suppressesPlayerRendering = true; item.add(output)
            player = AVPlayer(playerItem: item); player.isMuted = true
        }
        func close() {
            guard !isClosed else { return }; isClosed = true
            player.pause(); item.remove(output); player.replaceCurrentItem(with: nil)
        }
        func image(at seconds: Double) async throws -> CGImage {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while item.status == .unknown, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try require(item.status == .readyToPlay, "native preview item readiness: \(String(describing: item.error))")
            let time = CMTime(seconds: seconds, preferredTimescale: 60_000)
            let seekCompleted = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            try require(seekCompleted, "native preview seek")
            let context = CIContext(options: [.cacheIntermediates: false])
            while ContinuousClock.now < deadline {
                if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
                   let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: 96, height: 64)) { return image }
                if item.status == .failed { throw item.error ?? Failure.failed("native preview failed") }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Failure.failed("native multi-video preview timeout")
        }
        func playForReview() async throws {
            try require(player.isMuted, "native review must never play test tones through speakers")
            let start = player.currentTime().seconds
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var receivedMovingFrame = false
            player.playImmediately(atRate: 2)
            defer { player.pause() }
            while ContinuousClock.now < deadline {
                if item.status == .failed { throw item.error ?? Failure.failed("native review failed") }
                let time = player.currentTime()
                if time.seconds > start + 0.1, output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                    receivedMovingFrame = true
                }
                if time.seconds >= start + 0.3, receivedMovingFrame { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Failure.failed("muted 2× native review did not advance and deliver video frames")
        }
    }
}
