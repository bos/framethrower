import Foundation

// Run with Tests/check-recording-project.sh. No camera, permissions, or account required.
@main
struct RecordingProjectChecks {
    @MainActor static func main() throws {
        try checkPlacementGeometry()
        checkTransitions()
        try checkPersistence()
        print("Recording project checks passed: geometry, jump/smooth timing, validation, durable undo/redo, and immutable originals.")
    }

    static func checkPlacementGeometry() throws {
        let size = CGSize(width: 1920, height: 1080)
        let bottomRight = PIPPlacement(x: 1, y: 1, scale: 0.25).frame(in: size, cameraAspect: 16.0 / 9.0)
        expect(bottomRight, CGRect(x: 1440, y: 810, width: 480, height: 270), "Bottom-right anchor")
        expect(PIPPlacement(x: 0, y: 0, scale: 0.25).frame(in: size, cameraAspect: 16.0 / 9.0),
               CGRect(x: 0, y: 0, width: 480, height: 270), "Top-left anchor")
        let tall = PIPPlacement(x: 1, y: 1, scale: 0.5).frame(in: size, cameraAspect: 0.5)
        expect(tall, CGRect(x: 1488, y: 216, width: 432, height: 864), "Tall camera height cap")
        let clamped = PIPPlacement(x: -1, y: 2, scale: 5).frame(in: size, cameraAspect: 16.0 / 9.0)
        expect(clamped, CGRect(x: 0, y: 540, width: 960, height: 540), "Out-of-bounds geometry stays on screen")
        expect(PIPPlacement().frame(in: .zero, cameraAspect: 1), .zero, "Empty canvas")
        let fallback = PIPPlacement(x: .nan, y: .infinity, scale: .nan).frame(in: size, cameraAspect: .nan)
        precondition(fallback.minX.isFinite && fallback.minY.isFinite && fallback.width.isFinite)
    }

    static func checkTransitions() {
        let first = PIPPlacement(x: 0, y: 0, scale: 0.2)
        let second = PIPPlacement(x: 0.2, y: 0.4, scale: 0.3, visible: false)
        let third = PIPPlacement(x: 1, y: 1, scale: 0.5, visible: true)
        var state = EditState(trimStart: 0, trimEnd: 12, pipKeyframes: [
            PIPKeyframe(time: 0, placement: first),
            PIPKeyframe(time: 2, placement: second),
            PIPKeyframe(time: 8, placement: third, transition: .smooth, duration: 2)
        ])
        precondition(state.placement(at: -1) == first)
        precondition(state.placement(at: 1.999) == first, "Jump must not interpolate")
        precondition(state.placement(at: 2) == second, "Jump happens at its exact timestamp")
        precondition(state.placement(at: 6) == second, "Smooth motion starts at arrival minus duration")
        let midpoint = state.placement(at: 7)
        near(midpoint.x, 0.6, "Smooth midpoint X")
        near(midpoint.y, 0.7, "Smooth midpoint Y")
        near(midpoint.scale, 0.4, "Smooth midpoint size")
        precondition(!midpoint.visible, "Visibility remains discrete until arrival")
        let early = state.placement(at: 6.5)
        near(early.x, 0.2 + 0.8 * 0.15625, "Smoothstep easing, not linear motion")
        precondition(state.placement(at: 8) == third)
        precondition(state.placement(at: 100) == third)

        state.pipKeyframes[2].duration = 100
        precondition(state.placement(at: 2) == second, "Long transition cannot begin before previous point")
        near(state.placement(at: 5).x, 0.6, "Long transition is clamped to previous point")
        let identity = state.pipKeyframes[1].id
        state.upsert(PIPKeyframe(time: 2, placement: third))
        precondition(state.pipKeyframes.count == 3 && state.pipKeyframes[1].id == identity)
        precondition(state.pipKeyframes[1].placement == third)
        state.upsert(PIPKeyframe(time: 0.000_000_5, placement: third))
        precondition(state.pipKeyframes[0].time == 0, "Near-zero replacement preserves the initial timestamp")
        state.upsert(PIPKeyframe(time: 1, placement: first))
        precondition(state.pipKeyframes.map(\.time) == [0, 1, 2, 8])
    }

    @MainActor static func checkPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = Data("immutable original screen".utf8)
        let camera = Data("immutable original camera".utf8)
        try screen.write(to: directory.appendingPathComponent("screen.mp4"))
        try camera.write(to: directory.appendingPathComponent("camera.mov"))
        let projectURL = directory.appendingPathComponent("recording.framethrower")
        let original = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mov",
                                        cameraOffset: -0.25, duration: 10)
        let editor = ProjectEditor(project: original, url: projectURL)
        precondition(editor.save(), editor.errorMessage ?? "Save failed")
        var trimmed = original.state
        trimmed.trimStart = 1
        trimmed.trimEnd = 9
        precondition(editor.commit(trimmed, name: "Trim"))
        var moved = trimmed
        moved.upsert(PIPKeyframe(time: 4, placement: PIPPlacement(x: 0, y: 0), transition: .smooth))
        precondition(editor.commit(moved, name: "Move camera"))
        precondition(editor.canUndo && !editor.canRedo && editor.undoName == "Move camera")

        let reopened = try ProjectEditor.open(url: projectURL)
        precondition(reopened.project == editor.project, "Full history must survive reopening")
        precondition(reopened.undo() && reopened.project.state == trimmed && reopened.redoName == "Move camera")
        let reopenedAgain = try ProjectEditor.open(url: projectURL)
        precondition(reopenedAgain.canRedo && reopenedAgain.redo())
        precondition(reopenedAgain.project.state == moved)
        precondition(reopenedAgain.undo() && reopenedAgain.undo())
        precondition(reopenedAgain.project.state == original.state && !reopenedAgain.canUndo)
        precondition(reopenedAgain.redo() && reopenedAgain.project.state == trimmed)

        var branch = trimmed
        branch.trimEnd = 8
        precondition(reopenedAgain.commit(branch, name: "New trim"))
        precondition(!reopenedAgain.canRedo, "New edit invalidates the redo branch")
        let unchangedHistory = reopenedAgain.project
        precondition(reopenedAgain.commit(branch, name: "No-op") && reopenedAgain.project == unchangedHistory)

        var invalid = branch
        invalid.trimStart = 9
        let bytesBefore = try Data(contentsOf: projectURL)
        precondition(!reopenedAgain.commit(invalid, name: "Invalid trim"))
        precondition(reopenedAgain.errorMessage != nil && reopenedAgain.project == unchangedHistory)
        let bytesAfter = try Data(contentsOf: projectURL)
        precondition(bytesAfter == bytesBefore, "Invalid edit cannot alter durable history")

        // Force an actual persistence failure. The editor must retain its undo
        // entry and current edit when the project directory becomes unavailable.
        let movedDirectory = directory.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: directory, to: movedDirectory)
        precondition(!reopenedAgain.undo() && reopenedAgain.project == unchangedHistory)
        try FileManager.default.moveItem(at: movedDirectory, to: directory)
        precondition(reopenedAgain.undo(), "A failed undo must remain retryable")
        precondition(reopenedAgain.errorMessage == nil)

        var dangerous = original
        dangerous.screenFilename = "../screen.mp4"
        expectInvalid(dangerous, "Path traversal")
        dangerous = original
        dangerous.cameraFilename = dangerous.screenFilename
        expectInvalid(dangerous, "Shared screen/camera source")
        dangerous = original
        dangerous.version = 99
        expectInvalid(dangerous, "Unknown version")
        dangerous = original
        dangerous.state.pipKeyframes.append(dangerous.state.pipKeyframes[0])
        expectInvalid(dangerous, "Duplicate placement timestamp")
        dangerous = original
        dangerous.state.pipKeyframes[0].time = 1
        expectInvalid(dangerous, "Missing initial placement")
        dangerous = original
        dangerous.undoHistory.append(NamedEditSnapshot(name: "Corrupt history", state: invalid))
        expectInvalid(dangerous, "Invalid undo snapshot")

        let overwrite = ProjectEditor(project: original, url: directory.appendingPathComponent("screen.mp4"))
        precondition(!overwrite.save(), "Project must never overwrite source media")
        let screenAfter = try Data(contentsOf: directory.appendingPathComponent("screen.mp4"))
        let cameraAfter = try Data(contentsOf: directory.appendingPathComponent("camera.mov"))
        precondition(screenAfter == screen)
        precondition(cameraAfter == camera)
    }

    static func expectInvalid(_ project: RecordingProject, _ message: String) {
        do {
            try project.validate()
            preconditionFailure("Expected invalid project: \(message)")
        } catch {}
    }

    static func near(_ actual: Double, _ expected: Double, _ message: String) {
        precondition(abs(actual - expected) < 0.000_001, "\(message): \(actual) != \(expected)")
    }

    static func expect(_ actual: CGRect, _ expected: CGRect, _ message: String) {
        near(actual.minX, expected.minX, message)
        near(actual.minY, expected.minY, message)
        near(actual.width, expected.width, message)
        near(actual.height, expected.height, message)
    }
}
