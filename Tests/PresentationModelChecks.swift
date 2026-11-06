import CoreGraphics
import Foundation

@main
@MainActor
struct PresentationModelChecks {
    enum Failure: Error { case failed(String) }

    static func main() throws {
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

    private static func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try require(abs(actual - expected) < 0.000001, message)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
}
