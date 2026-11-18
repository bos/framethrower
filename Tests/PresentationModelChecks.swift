import CoreGraphics
import Foundation

@main
@MainActor
struct PresentationModelChecks {
    enum Failure: Error { case failed(String) }

    static func main() throws {
        try checkCrops()
        let source = CGSize(width: 1920, height: 1080)
        let identity = PresentationGeometry(sourceSize: source, presentation: CanvasPresentation())
        try require(identity.outputSize == source && identity.contentRect == CGRect(origin: .zero, size: source),
                    "default presentation keeps existing recordings exactly full frame")
        for aspect in CanvasAspect.allCases {
            let presentation = CanvasPresentation(aspect: aspect, padding: 0.1, cornerRadius: 0.12,
                                                   background: CanvasColor(red: 0.1, green: 0.2, blue: 0.3))
            let geometry = PresentationGeometry(sourceSize: source, presentation: presentation)
            let output = CGRect(origin: .zero, size: geometry.outputSize)
            let content = geometry.contentRect
            try require(output.contains(content) && content.width > 0 && content.height > 0,
                        "the complete source stays within every supported canvas")
            try near(content.width / content.height, source.width / source.height, "presentation never stretches the source")
            try near(content.midX, output.midX, "source remains horizontally centered")
            try near(content.midY, output.midY, "source remains vertically centered")
            let bounds = CGRect(x: 13, y: 27, width: 803, height: 487)
            let viewOutput = geometry.outputRect(in: bounds)
            let viewContent = geometry.contentRect(in: bounds)
            try require(bounds.contains(viewOutput) && viewOutput.contains(viewContent), "native preview bounds contain the full output and source")
            try near(viewContent.width / viewContent.height, source.width / source.height, "preview mapping uses uniform scale")
            for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.27, y: 0.63), CGPoint(x: 1, y: 1)] {
                let viewPoint = CGPoint(x: viewContent.minX + point.x * viewContent.width,
                                        y: viewContent.minY + point.y * viewContent.height)
                try near((viewPoint.x - viewContent.minX) / viewContent.width, point.x, "screen zoom anchor maps through source bounds")
                try near((viewPoint.y - viewContent.minY) / viewContent.height, point.y, "screen pan anchor maps through source bounds")
            }
            let pip = PIPPlacement(x: 0.3, y: 0.4, scale: 0.25)
            let pipFrame = pip.frame(in: viewOutput.size, cameraAspect: 16.0 / 9)
            let translation = CGSize(width: 14, height: -9)
            var moved = pip
            moved.x += translation.width / (viewOutput.width - pipFrame.width)
            moved.y += translation.height / (viewOutput.height - pipFrame.height)
            let translated = moved.frame(in: viewOutput.size, cameraAspect: 16.0 / 9)
            try near(translated.minX - pipFrame.minX, translation.width, "PIP drag uses full output width at every aspect")
            try near(translated.minY - pipFrame.minY, translation.height, "PIP drag uses full output height at every aspect")
        }
        let portrait = PresentationGeometry(sourceSize: source, presentation: CanvasPresentation(aspect: .portrait))
        try require(portrait.outputSize == CGSize(width: 1080, height: 1920), "portrait output preserves the native long-edge resolution")
        let square = PresentationGeometry(sourceSize: source, presentation: CanvasPresentation(aspect: .square))
        try require(square.outputSize == CGSize(width: 1920, height: 1920), "square output keeps the native long edge")

        var project = RecordingProject(screenFilename: "screen.mov", duration: 3)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        var legacyState = legacy["state"] as! [String: Any]
        legacyState.removeValue(forKey: "presentation")
        legacy["state"] = legacyState
        legacy["undoHistory"] = [["name": "Legacy edit", "state": legacyState]]
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(decoded.state.presentation == CanvasPresentation() &&
                    decoded.undoHistory[0].state.presentation == CanvasPresentation(), "legacy projects and undo snapshots default to unchanged presentation")
        project.state.presentation = CanvasPresentation(aspect: .square, padding: 0.08, cornerRadius: 0.1,
                                                        background: CanvasColor(red: 0.1, green: 0.2, blue: 0.3))
        try project.validate()
        try require(try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(project)) == project,
                    "presentation settings round-trip with edit history")
        for invalid in [Double.nan, -.infinity, -0.01, 0.21] {
            var candidate = project
            candidate.state.presentation.padding = invalid
            do { try candidate.validate(); throw Failure.failed("invalid padding accepted") }
            catch is ProjectError { }
        }
        var invalidColor = project
        invalidColor.state.presentation.background.green = .infinity
        do { try invalidColor.validate(); throw Failure.failed("invalid background accepted") }
        catch is ProjectError { }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("presentation-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("immutable original".utf8)
        try original.write(to: directory.appendingPathComponent("screen.mov"))
        let initial = RecordingProject(screenFilename: "screen.mov", duration: 3)
        let editor = ProjectEditor(project: initial, url: directory.appendingPathComponent("test.framethrower"))
        var presented = initial.state
        presented.presentation = project.state.presentation
        try require(editor.save() && editor.commit(presented, name: "Change canvas"), "save whole-recording presentation")
        try require(editor.project.undoHistory.count == 1 && editor.project.state.timedEdits(includeCamera: false).isEmpty,
                    "a canvas choice is one whole-recording undo step without adding a timed diamond")
        try require(editor.undo() && editor.project.state.presentation == CanvasPresentation(), "Undo restores original presentation")
        try require(editor.redo() && editor.project.state.presentation == project.state.presentation, "Redo restores all presentation properties")
        try require(try ProjectEditor.open(url: editor.url).project.state.presentation == project.state.presentation &&
                    Data(contentsOf: directory.appendingPathComponent("screen.mov")) == original,
                    "saved presentation survives reopening and never rewrites original media")
        print("Presentation model checks passed (legacy identity, source fit, output aspects, preview/PIP mapping, persistence, and validation).")
    }

    private static func checkCrops() throws {
        let size = CGSize(width: 1920, height: 1080)
        for ratio in [nil, 9.0 / 16, 16.0 / 9, 1, 23.0 / 10] as [Double?] {
            for end in [CGPoint(x: 1800, y: 1000), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1080), CGPoint(x: 1920, y: 0)] {
                guard let crop = CropGeometry.drawn(from: CGPoint(x: 800, y: 500), to: end, source: size, ratio: ratio) else { throw Failure.failed("draw crop") }
                try require(crop.isValid, "drawing in every direction remains inside the source")
                let pixels = CropGeometry.pixels(crop, in: size)
                if let ratio { try near(pixels.width / pixels.height, ratio, "drawing locks the pixel aspect, including arbitrary ratios") }
            }
        }
        let crop = CropGeometry.normalized(CGRect(x: 200, y: 40, width: 540, height: 960), in: size)
        let presentation = CanvasPresentation(sourceCrop: crop)
        let output = PresentationGeometry(sourceSize: size, presentation: presentation)
        try require(output.outputSize == CGSize(width: 540, height: 960), "the selected rectangle becomes the native output frame")
        try require(output.contentRect == CGRect(origin: .zero, size: output.outputSize), "the crop fills its output without letterboxing")
        try require(presentation.viewport(in: size) == CropGeometry.pixels(crop, in: size), "full-frame crop uses the original source coordinates")
        let zoom = presentation.viewport(in: size, zoom: ZoomPlacement(scale: 2, x: 0.25, y: 0.75))
        try near(zoom.minX, 200, "zoom remains inside the main crop")
        try near(zoom.maxY, 1000, "zoom reaches the crop bottom")
        let resolutionCases: [(Double, CGSize)] = [(9.0 / 16, CGSize(width: 1080, height: 1920)), (16.0 / 9, CGSize(width: 1920, height: 1080)),
                                   (1, CGSize(width: 1080, height: 1080)), (4.0 / 5, CGSize(width: 1080, height: 1350)),
                                   (4.0 / 3, CGSize(width: 1440, height: 1080)), (3.0 / 2, CGSize(width: 1620, height: 1080))]
        for (aspect, expected) in resolutionCases {
            try require(CanvasResolution.matching(aspect: aspect, shortEdge: 1080).size == expected, "1080p defaults follow the selected aspect")
        }
        try require(CanvasResolution.matching(aspect: 9.0 / 16, shortEdge: 720).size == CGSize(width: 720, height: 1280), "portrait 720p default")
        var sized = presentation; sized.outputResolution = CanvasResolution(width: 1080, height: 1920)
        try require(PresentationGeometry(sourceSize: size, presentation: sized).outputSize == CGSize(width: 1080, height: 1920), "output resolution scales independently of the source crop")
        sized.aspect = .square
        try require(PresentationGeometry(sourceSize: size, presentation: sized).outputSize == CGSize(width: 1080, height: 1080), "canvas shape changes retain the selected resolution level")
        let moved = CropGeometry.moved(crop, by: CGSize(width: 10, height: -10))
        try require(moved.isValid && moved.y == 0 && moved.x == 1 - crop.width, "crop movement clamps without changing size")
        let square = CropGeometry.normalized(CGRect(x: 400, y: 300, width: 200, height: 200), in: size)
        for handle in 0..<8 {
            let target = CGPoint(x: [420.0, 500, 580, 580, 580, 500, 420, 420][handle],
                                 y: [320.0, 320, 320, 400, 480, 480, 480, 400][handle])
            guard let resized = CropGeometry.resized(square, handle: handle, to: target, source: size, ratio: 1) else { throw Failure.failed("resize crop") }
            let pixels = CropGeometry.pixels(resized, in: size)
            try near(pixels.width / pixels.height, 1, "all eight handles preserve a locked aspect")
            try require(pixels.width < 200, "each handle can shrink a locked rectangle")
        }
        var project = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", duration: 3)
        project.state.presentation = presentation
        project.state.presentation.outputResolution = CanvasResolution(width: 1080, height: 1920)
        let cameraCrop = EditorRegionRect(x: 0.1, y: 0.2, width: 0.8, height: 0.1)
        let camera = PIPPlacement(shape: .rectangle, aspectRatio: 128.0 / 9, sourceCrop: cameraCrop)
        project.state.pipKeyframes[0].placement = camera
        try project.validate()
        try require(camera.sourceViewport(in: size, canvas: size) == CropGeometry.pixels(cameraCrop, in: size), "camera uses the exact arbitrary source rectangle")
        let cameraFrame = camera.frame(in: size, cameraAspect: 16.0 / 9)
        try near(cameraFrame.width / cameraFrame.height, 128.0 / 9, "camera crop ratios are not limited by legacy shape bounds")
        let encoded = try JSONEncoder().encode(project)
        try require(try JSONDecoder().decode(RecordingProject.self, from: encoded) == project, "main and camera rectangles round-trip")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crop-history-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", duration: 3)
        let editor = ProjectEditor(project: initial, url: directory.appendingPathComponent("Crop.framethrower"))
        try require(editor.save() && editor.commit(project.state, name: "Crop video"), "crop metadata saves")
        try require(editor.project.undoHistory.count == 1, "one applied crop makes one Undo step")
        try require(editor.undo() && editor.project.state == initial.state, "Undo restores full-frame main and camera")
        try require(editor.redo() && editor.project.state == project.state, "Redo restores both exact crop rectangles")
        try require(try ProjectEditor.open(url: editor.url).project.state == project.state, "crops survive reopening")
        for resolution in [CanvasResolution(width: 1, height: 1080), .init(width: 1081, height: 1920), .init(width: 8194, height: 2)] {
            var invalid = project; invalid.state.presentation.outputResolution = resolution
            do { try invalid.validate(); throw Failure.failed("invalid output resolution accepted") } catch is ProjectError { }
        }
        for bad in [EditorRegionRect(x: -0.1, y: 0, width: 1, height: 1), .init(x: 0.5, y: 0, width: 1, height: 1), .init(x: 0, y: 0, width: 0, height: 1)] {
            var invalid = project; invalid.state.presentation.sourceCrop = bad
            do { try invalid.validate(); throw Failure.failed("invalid main crop accepted") } catch is ProjectError { }
            invalid = project; invalid.state.pipKeyframes[0].placement.sourceCrop = bad
            do { try invalid.validate(); throw Failure.failed("invalid camera crop accepted") } catch is ProjectError { }
        }
    }

    private static func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try require(abs(actual - expected) < 0.000001, message)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
}
