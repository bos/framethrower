@preconcurrency import AVFoundation
import Foundation

private enum ExportCheckError: Error { case failed(String) }

@main
@MainActor
struct VideoExportChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("screen.mp4")
        try await EditorMovieFixtures.make(at: source, width: 2560, height: 1440, duration: 2, camera: false)
        let original = try Data(contentsOf: source)
        let project = RecordingProject(screenFilename: source.lastPathComponent, duration: 2)
        do {
            let missingFolder = directory.appendingPathComponent("missing-folder").appendingPathComponent("export.mp4")
            try await ProjectRenderer.export(project: project, directory: directory, to: missingFolder)
            throw ExportCheckError.failed("accepted an unavailable export folder")
        } catch ProjectRenderer.RenderError.destinationNotWritable { }
        do {
            // The volume root is readable but cannot accept an export file.
            try await ProjectRenderer.export(project: project, directory: directory,
                to: URL(fileURLWithPath: "/framethrower-export-check-\(UUID()).mp4"))
            throw ExportCheckError.failed("accepted the read-only volume root")
        } catch ProjectRenderer.RenderError.destinationNotWritable { }
        for (preset, width, height) in [(VideoExportPreset.fullResolution, 2560, 1440), (.hd, 1920, 1080), (.small, 1280, 720)] {
            let url = directory.appendingPathComponent(preset.rawValue + ".mp4")
            var values: [Double] = []
            try await ProjectRenderer.export(project: project, directory: directory, to: url, preset: preset) { values.append($0) }
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportCheckError.failed("missing exported video") }
            let size = try await track.load(.naturalSize)
            try require(Int(size.width) == width && Int(size.height) == height, "export preset dimensions: \(preset)")
            try require(values.last == 1 && values.allSatisfy { $0.isFinite && (0...1).contains($0) }, "bounded completed progress")
            try require(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "monotonic export progress")
        }
        for (aspect, requested, format) in [(CanvasAspect.wide, 1000.0, VideoExportFormat.mp4),
                                            (.portrait, 562.0, .mov), (.square, 734.0, .mov)] {
            var resized = project; resized.state.presentation.aspect = aspect
            let canvas = try await ProjectRenderer.exportCanvasSize(project: resized, directory: directory)
            let size = VideoExportDimensions.size(for: canvas, width: requested)
            let url = directory.appendingPathComponent("custom-\(aspect.rawValue).\(format.rawValue)")
            try await ProjectRenderer.export(project: resized, directory: directory, to: url, customSize: size, format: format)
            try await checkDimensions(url, expected: size, context: "custom \(aspect) \(format)")
            try require(abs(size.width / size.height - canvas.width / canvas.height) < 0.005,
                "Custom dimensions preserve the chosen canvas aspect ratio")
        }
        let portrait = VideoExportDimensions.size(for: CGSize(width: 1080, height: 1920), height: 1000)
        try require(portrait == CGSize(width: 562, height: 1000), "Editing height computes width")
        let bounded = VideoExportDimensions.size(for: CGSize(width: 1920, height: 1080), width: 100000)
        try require(bounded.width == 8192 && bounded.height == 4608, "Custom dimensions bound encoder size")
        do {
            try await ProjectRenderer.export(project: project, directory: directory,
                to: directory.appendingPathComponent("distorted.mp4"), customSize: CGSize(width: 1000, height: 1000))
            throw ExportCheckError.failed("accepted a custom size that distorts the canvas")
        } catch ProjectRenderer.RenderError.invalidExportSize { }
        let camera = directory.appendingPathComponent("camera.mp4")
        try await EditorMovieFixtures.make(at: camera, width: 80, height: 40, duration: 1, camera: true)
        let originalCamera = try Data(contentsOf: camera)
        var framed = RecordingProject(screenFilename: source.lastPathComponent, cameraFilename: camera.lastPathComponent, duration: 2)
        framed.state.pipKeyframes[0].placement = PIPPlacement(x: 0.5, y: 0.5, scale: 0.25)
        for (aspect, hd, small) in [(CanvasAspect.wide, CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720)),
                                   (.portrait, CGSize(width: 1080, height: 1920), CGSize(width: 720, height: 1280)),
                                   (.square, CGSize(width: 1080, height: 1080), CGSize(width: 720, height: 720))] {
            framed.state.presentation.aspect = aspect
            for (preset, expected) in [(VideoExportPreset.hd, hd), (.small, small)] {
                let url = directory.appendingPathComponent("framed-\(aspect.rawValue)-\(preset.rawValue).mp4")
                try await ProjectRenderer.export(project: framed, directory: directory, to: url, preset: preset)
                try await checkDimensions(url, expected: expected, context: "\(aspect) \(preset)")
                try await checkFraming(url, letterboxed: aspect != .wide)
            }
        }
        for (name, sourceWidth, sourceHeight, hd, small) in [
            ("four-three", 1600, 1200, CGSize(width: 1440, height: 1080), CGSize(width: 960, height: 720)),
            ("smaller", 320, 180, CGSize(width: 320, height: 180), CGSize(width: 320, height: 180))
        ] {
            let fixture = directory.appendingPathComponent(name + ".mp4")
            try await EditorMovieFixtures.make(at: fixture, width: sourceWidth, height: sourceHeight, duration: 1, camera: false)
            let bytes = try Data(contentsOf: fixture)
            var shape = RecordingProject(screenFilename: fixture.lastPathComponent, cameraFilename: camera.lastPathComponent, duration: 1)
            shape.state.pipKeyframes[0].placement = PIPPlacement(x: 0.5, y: 0.5, scale: 0.25)
            for (preset, expected) in [(VideoExportPreset.hd, hd), (.small, small)] {
                let url = directory.appendingPathComponent("export-\(name)-\(preset.rawValue).mp4")
                try await ProjectRenderer.export(project: shape, directory: directory, to: url, preset: preset)
                try await checkDimensions(url, expected: expected, context: "\(name) \(preset)")
                try await checkFraming(url, letterboxed: false)
            }
            try require(try Data(contentsOf: fixture) == bytes, "additional aspect exports preserve their source")
        }
        try require(try Data(contentsOf: camera) == originalCamera, "resized exports preserve the original camera track")
        let replacement = directory.appendingPathComponent("replacement.mp4")
        let sentinel = Data("existing exported video".utf8)
        try sentinel.write(to: replacement)
        do {
            try await ProjectRenderer.export(project: project, directory: directory, to: replacement)
            throw ExportCheckError.failed("default export replaced an existing file")
        } catch ProjectRenderer.RenderError.destinationExists { }
        try require(try Data(contentsOf: replacement) == sentinel, "unapproved existing destination preserved")
        try await ProjectRenderer.export(project: project, directory: directory, to: replacement, replaceExisting: true)
        try require(try Data(contentsOf: replacement) != sentinel, "explicit replacement installs a complete video")
        let replacementAsset = AVURLAsset(url: replacement)
        let replacementDuration = try await replacementAsset.load(.duration).seconds
        try require(replacementDuration > 1.9, "replacement is complete and playable")
        do {
            try await ProjectRenderer.export(project: project, directory: directory, to: source, replaceExisting: true)
            throw ExportCheckError.failed("original was accepted as a replacement destination")
        } catch ProjectRenderer.RenderError.destinationExists { }
        try require(try Data(contentsOf: source) == original, "all preset and replacement exports preserve the original")

        let cancelled = directory.appendingPathComponent("cancelled.mp4")
        var work: Task<Void, any Error>?
        var cancelledDuringExport = false
        work = Task { @MainActor in
            try await ProjectRenderer.export(project: project, directory: directory, to: cancelled) { fraction in
                if fraction < 1 {
                    cancelledDuringExport = true
                    work?.cancel()
                }
            }
        }
        do { try await work?.value }
        catch { try require(work?.isCancelled == true, "export failed for an unexpected reason: \(error)") }
        if cancelledDuringExport {
            try require(!FileManager.default.fileExists(atPath: cancelled.path), "cancelled export cannot install a partial video")
        } else {
            // A very fast encoder may finish before its first progress sample.
            // Cancellation before entry still exercises the same cleanup path.
            let early = directory.appendingPathComponent("early-cancel.mp4")
            let task = Task { @MainActor in try await ProjectRenderer.export(project: project, directory: directory, to: early) }
            task.cancel()
            do { try await task.value; throw ExportCheckError.failed("pre-cancelled export succeeded") }
            catch is CancellationError { }
            try require(!FileManager.default.fileExists(atPath: early.path), "pre-cancelled export creates no destination")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try require(!files.contains(where: { $0.hasPrefix(".framethrower-export-") }), "staging files cleaned after success/failure/cancel")
        print("Video export checks passed (landscape/portrait/square/4:3 sizes, no upscaling, source/PIP/letterbox pixels, progress, atomic replacement, original protection, cancellation, and staging cleanup).")
    }

    private static func checkDimensions(_ url: URL, expected: CGSize, context: String) async throws {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first else {
            throw ExportCheckError.failed("missing video for \(context)")
        }
        let size = try await track.load(.naturalSize)
        try require(size == expected, "\(context): exported \(size), expected \(expected)")
        try require(Int(size.width).isMultiple(of: 2) && Int(size.height).isMultiple(of: 2), "export dimensions remain codec-safe even pixels")
    }

    private static func checkFraming(_ url: URL, letterboxed: Bool) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        defer { generator.cancelAllCGImageGeneration() }
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: .zero).image
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExportCheckError.failed("export pixel context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        func pixel(_ u: Double, _ v: Double, expected: [Int], _ label: String) throws {
            let offset = (Int(Double(image.height) * v) * image.width + Int(Double(image.width) * u)) * 4
            let actual = [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
            try require(zip(actual, expected).allSatisfy { abs($0 - $1) <= 40 }, "\(label): \(actual), expected \(expected)")
        }
        try pixel(0.5, 0.5, expected: [230, 0, 51], "centered camera survives resized composition")
        try pixel(0.75, 0.5, expected: [0, 51, 255], "screen source survives resized composition")
        try pixel(0.05, 0.5, expected: [255, 255, 255], "source left edge is retained instead of clipping a native-size frame")
        if letterboxed { try pixel(0.5, 0.1, expected: [0, 0, 0], "presentation margin survives resized composition") }
    }

    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ExportCheckError.failed(message) }
    }
}
