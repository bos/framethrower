import Foundation

@main
@MainActor
struct EditAnchorChecks {
    enum Failure: Error { case failed(String) }

    static func main() throws {
        try checkBoxFirstHistory()
        try checkVisualInvariance()
        try checkTransformCoalescing()
        try checkMigrationAndValidation()
        print("Edit anchor checks passed (box-first named marks, same-frame reuse, unchanged motion/sources, stable identities, retime/removal, persistence and atomic Undo/Redo, migration and validation).")
    }

    private static let rect = EditorRegionRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure.failed(message) }
    }

    private static func checkBoxFirstHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("untouched-original.mov")
        let sentinel = Data("source bytes are never opened as video in this check".utf8)
        try sentinel.write(to: source)
        let initial = RecordingProject(screenFilename: source.lastPathComponent, duration: 12)
        let editor = ProjectEditor(project: initial, url: directory.appendingPathComponent("project.framethrower"))
        try require(editor.save(), "save metadata fixture")

        var next = editor.project.state
        let first = next.addRegion(rect: rect, at: 2)
        try require(editor.commit(next, name: "Draw box"), "draw first box")
        try require(editor.project.undoHistory.count == 1 && editor.project.state.editAnchors.count == 1 &&
                    editor.project.state.regions.count == 1, "box and reference mark form one undoable change")
        try require(editor.references.editLabel(for: first.editID!) == "Edit A" &&
                    editor.references.boxLabel(for: first.id) == "Box 1", "first drawing is speakable without an existing transform")
        next = editor.project.state
        let second = next.addRegion(rect: rect, at: 6)
        try require(editor.commit(next, name: "Draw box"), "draw second box")
        try require(editor.references.editLabel(for: second.editID!) == "Edit B" &&
                    editor.references.boxLabel(for: second.id) == "Box 2", "a second source frame gains its own edit and box references")
        try require(editor.project.state.zoomKeyframes == initial.state.zoomKeyframes &&
                    editor.project.state.pipKeyframes == initial.state.pipKeyframes, "drawing marks must not add visual edits")

        let finished = editor.project.state
        try require(editor.undo() && editor.project.state.regions == [first] && editor.project.state.editAnchors.count == 1,
                    "one Undo removes the second box and its mark together")
        try require(editor.references.editLabel(for: second.editID!) == "Edit B" &&
                    editor.references.boxLabel(for: second.id) == "Box 2", "Undo reserves spoken references")
        try require(editor.redo() && editor.project.state == finished, "one Redo restores both objects with their identities")

        next = editor.project.state
        let another = next.addRegion(rect: rect, at: 2)
        try require(next.editAnchors.count == 2 && another.editID == first.editID,
                    "additional boxes on one frame reuse the reference mark")

        let firstEdit = editor.project.state.timedEdits(includeCamera: true).first { $0.id == first.editID }!
        next = editor.project.state
        next.move(firstEdit, to: 3)
        try require(editor.commit(next, name: "Move edit"), "retime reference mark")
        try require(editor.project.state.editAnchors.first?.time == 3 && editor.project.state.regions[0].time == 2,
                    "retiming changes the mark, while the drawn source frame stays fixed")
        try require(editor.references.editLabel(for: firstEdit.id) == "Edit A", "retiming preserves the spoken reference")
        try require(editor.undo() && editor.project.state == finished, "Undo restores original anchor timing")

        next = editor.project.state
        next.remove(firstEdit)
        try require(editor.commit(next, name: "Remove edit"), "remove reference mark")
        try require(editor.project.state.editAnchors.count == 1 && editor.project.state.regions[0] == first,
                    "removing a mark retains the original box reference and source frame")
        try require(editor.references.edit(in: editor.project.state, id: firstEdit.id) == nil &&
                    editor.references.editLabel(for: firstEdit.id) == "Edit A", "removed mark is identifiable but no longer an active target")
        try require(editor.undo() && editor.project.state == finished, "Undo restores the original association")

        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.project.state == finished && reopened.references.editLabel(for: firstEdit.id) == "Edit A" &&
                    reopened.references.boxLabel(for: second.id) == "Box 2", "save/reopen preserves anchors and spoken names")
        try require(try Data(contentsOf: source) == sentinel, "anchor operations never change original source bytes")
    }

    private static func checkVisualInvariance() throws {
        var state = RecordingProject(screenFilename: "missing.mov", duration: 12).state
        state.zoomKeyframes = [ZoomKeyframe(time: 10, scale: 2.5, x: 0.6, y: 0.4, transition: .smooth, duration: 10)]
        let initial = state
        _ = state.addRegion(rect: rect, at: 0)
        _ = state.addRegion(rect: rect, at: 2)
        _ = state.addRegion(rect: rect, at: 6)
        for index in 0...120 {
            let time = Double(index) / 10
            try require(state.zoom(at: time) == initial.zoom(at: time) && state.placement(at: time) == initial.placement(at: time),
                        "reference-only anchors cannot alter incoming interpolation or any footage framing")
        }
        try require(state.zoomKeyframes == initial.zoomKeyframes && state.pipKeyframes == initial.pipKeyframes,
                    "guides cannot materialize holds or transformation keyframes")
    }

    private static func checkTransformCoalescing() throws {
        var project = RecordingProject(screenFilename: "missing.mov", cameraFilename: "missing-camera.mov", duration: 12)
        let box = project.state.addRegion(rect: rect, at: 2)
        let anchorID = box.editID!
        let zoom = ZoomKeyframe(time: 2, scale: 2)
        let camera = PIPKeyframe(time: 2, placement: PIPPlacement(x: 0.1, y: 0.1))
        project.state.zoomKeyframes = [zoom]
        project.state.pipKeyframes.append(camera)
        try project.validate()
        let edits = project.state.timedEdits(includeCamera: true)
        try require(edits.count == 1 && edits[0].id == anchorID && edits[0].anchorID == anchorID &&
                    edits[0].zoomID == zoom.id && edits[0].cameraID == camera.id,
                    "a later visual edit coalesces into the already named reference moment")
        let nextBox = project.state.addRegion(rect: rect, at: 2)
        try require(project.state.editAnchors.count == 1 && nextBox.editID == anchorID,
                    "a box at a combined edit must not create another mark")
        project.state.move(edits[0], to: 4)
        try project.validate()
        try require(project.state.editAnchors[0].time == 4 && project.state.zoomKeyframes[0].time == 4 &&
                    project.state.pipKeyframes[1].time == 4 && project.state.regions.allSatisfy { $0.time == 2 },
                    "moving a combined edit moves all components, leaving source-frame boxes intact")
        project.state.remove(project.state.timedEdits(includeCamera: true)[0])
        try require(project.state.editAnchors.isEmpty && project.state.zoomKeyframes.isEmpty &&
                    project.state.pipKeyframes.count == 1 && project.state.regions.count == 2,
                    "removing a combined edit removes its components but preserves box metadata")

        var existing = RecordingProject(screenFilename: "missing.mov", duration: 12).state
        existing.zoomKeyframes = [zoom]
        let existingBox = existing.addRegion(rect: rect, at: 2)
        try require(existing.editAnchors.isEmpty && existingBox.editID == zoom.id,
                    "existing edits are reused instead of creating redundant anchors")
        var noCamera = RecordingProject(screenFilename: "missing.mov", duration: 12).state
        noCamera.pipKeyframes.append(camera)
        let visibleBox = noCamera.addRegion(rect: rect, at: 2, includeCamera: false)
        try require(noCamera.editAnchors.count == 1 && visibleBox.editID != camera.id &&
                    noCamera.timedEdits(includeCamera: false).first?.id == visibleBox.editID,
                    "unused camera metadata cannot attach a box to an invisible timeline edit")
    }

    private static func checkMigrationAndValidation() throws {
        let project = RecordingProject(screenFilename: "missing.mov", duration: 12)
        let encoded = try JSONEncoder().encode(project.state)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "editAnchors")
        let decoded = try JSONDecoder().decode(EditState.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(decoded.editAnchors.isEmpty && decoded == project.state, "older projects and undo snapshots gain empty anchors")
        let id = UUID()
        for anchors in [[EditAnchor(id: id, time: 1), EditAnchor(id: id, time: 2)],
                        [EditAnchor(time: 2), EditAnchor(time: 1)], [EditAnchor(time: 13)],
                        [EditAnchor(time: .nan)], [EditAnchor(time: 1), EditAnchor(time: 1.0000001)]] {
            var invalid = project
            invalid.state.editAnchors = anchors
            do { try invalid.validate(); throw Failure.failed("invalid reference marks accepted") }
            catch is ProjectError { }
        }
        var mismatch = project
        mismatch.state.editAnchors = [EditAnchor(id: id, time: 2)]
        mismatch.state.zoomKeyframes = [ZoomKeyframe(id: id, time: 3, scale: 2)]
        do { try mismatch.validate(); throw Failure.failed("same identity at different times accepted") }
        catch is ProjectError { }
    }
}
