import Foundation

private enum ReferenceCheckError: Error { case failed(String) }

@main @MainActor
struct EditorReferencesChecks {
    static func main() throws {
        try checkHistory()
        try checkMigrationAndGroups()
        try checkRecovery()
        try checkValidation()
        print("Editor reference checks passed (stable letters/numbers, insertion/removal/retiming, Undo/Redo/reopen, legacy migration, combined edits, recovery, and validation; no media).")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ReferenceCheckError.failed(message) }
    }

    static func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("test.framethrower")
    }

    static func checkHistory() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let a = ZoomKeyframe(time: 1, scale: 2), b = ZoomKeyframe(time: 5, scale: 1)
        let box1 = EditorRegion(time: 1, rect: EditorRegionRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), editID: a.id)
        let box2 = EditorRegion(time: 5, rect: EditorRegionRect(x: 0.6, y: 0.4, width: 0.3, height: 0.2), editID: b.id)
        var original = RecordingProject(screenFilename: "untouched.mov", duration: 12)
        original.state.zoomKeyframes = [a, b]
        original.state.regions = [box1, box2]
        let editor = ProjectEditor(project: original, url: url)
        try require(editor.save(), "save fixture")
        try require(editor.project.references.editLabel(for: a.id) == "Edit A" && editor.project.references.editLabel(for: b.id) == "Edit B", "initial chronological labels")
        try require(editor.project.references.boxLabel(for: box2.id) == "Box 2", "initial box numbers")
        var changed = editor.project.state
        changed.zoomKeyframes[0].time = 8
        changed.zoomKeyframes.sort { $0.time < $1.time }
        let inserted = ZoomKeyframe(time: 3, scale: 1.5)
        changed.zoomKeyframes.insert(inserted, at: 0)
        changed.zoomKeyframes.sort { $0.time < $1.time }
        changed.regions.removeFirst()
        try require(editor.commit(changed, name: "Move and insert"), "commit moved edits")
        try require(editor.project.references.editLabel(for: a.id) == "Edit A" && editor.project.references.editLabel(for: b.id) == "Edit B" && editor.project.references.editLabel(for: inserted.id) == "Edit C", "retime and insertion preserve existing names")
        try require(editor.project.state.regions[0].time == 5 && editor.project.state.regions[0].editID == b.id && editor.project.references.boxLabel(for: box2.id) == "Box 2", "boxes retain source frame and association")
        let catalog = editor.project.references
        try require(editor.undo() && editor.project.references == catalog && editor.project.state == original.state, "Undo restores state without recycling identifiers")
        try require(editor.redo() && editor.project.references == catalog, "Redo preserves catalog")
        let reopened = try ProjectEditor.open(url: url)
        try require(reopened.project.references == catalog, "references persist on reopen")
        try require(reopened.undo(), "undo inserted edit before branching")
        var branch = reopened.project.state
        let next = ZoomKeyframe(time: 9, scale: 2)
        branch.zoomKeyframes.append(next)
        let third = EditorRegion(time: 9, rect: box1.rect, editID: next.id)
        branch.regions.append(third)
        try require(reopened.commit(branch, name: "New branch"), "commit new branch")
        try require(reopened.project.references.editLabel(for: next.id) == "Edit D" && reopened.project.references.boxLabel(for: third.id) == "Box 3", "discarded redo/deleted names are never reused")
        var letters = EditorReferences()
        for value in 1...28 { letters.edits[UUID().uuidString] = value }
        let z = UUID(), aa = UUID(), ab = UUID()
        letters.edits[z.uuidString] = 26; letters.edits[aa.uuidString] = 27; letters.edits[ab.uuidString] = 28
        try require(letters.editLabel(for: z) == "Edit Z" && letters.editLabel(for: aa) == "Edit AA" && letters.editLabel(for: ab) == "Edit AB", "letters continue after Z")
    }

    static func checkMigrationAndGroups() throws {
        let zoom = ZoomKeyframe(time: 2, scale: 2)
        let camera = PIPKeyframe(time: 2, placement: PIPPlacement())
        var project = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", duration: 10)
        project.state.zoomKeyframes = [zoom]
        project.state.pipKeyframes.append(camera)
        project.state.regions = [EditorRegion(time: 2, rect: EditorRegionRect(x: 0, y: 0, width: 1, height: 1))]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        json.removeValue(forKey: "references")
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: json))
        try decoded.validate()
        try require(decoded.references.editLabel(for: zoom.id) == "Edit A" && decoded.references.editLabel(for: camera.id) == "Edit A", "one combined edit has one spoken reference")
        try require(decoded.references.boxLabel(for: decoded.state.regions[0].id) == "Box 1" && decoded.state.regions[0].editID == nil, "legacy boxes gain references without invented edit associations")
        var cameraOnly = decoded
        cameraOnly.state.zoomKeyframes = []
        cameraOnly.ensureReferences()
        try require(cameraOnly.references.editLabel(for: camera.id) == "Edit A", "removing one component keeps the combined edit name")
        try require(cameraOnly.references.edit(in: cameraOnly.state, id: zoom.id)?.id == camera.id,
                    "a box linked through the removed zoom component still resolves the surviving camera edit")
    }

    static func checkRecovery() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "screen.mov", duration: 12), url: url)
        try require(editor.save(), "save recovery fixture")
        var draft = editor.project.state
        let point = ZoomKeyframe(time: 3, scale: 2)
        draft.zoomKeyframes.append(point)
        draft.regions.append(EditorRegion(time: 3, rect: EditorRegionRect(x: 0, y: 0, width: 0.3, height: 0.3), editID: point.id))
        try require(editor.updateDraft(draft, at: 3) && editor.flushRecovery(), "journal references with draft")
        let catalog = editor.references
        let restored = try ProjectEditor.open(url: url)
        try require(restored.recoveryRestored && restored.references == catalog && restored.draftState == draft, "crash recovery restores the names shown before crash")
        try require(restored.finishDraft(), "save restored draft")
        try require(try ProjectEditor.open(url: url).project.references == catalog, "recovered names durable")
    }

    static func checkValidation() throws {
        for references in [EditorReferences(edits: ["invalid": 1]),
                           EditorReferences(boxes: [UUID().uuidString: -1]),
                           EditorReferences(boxes: [UUID().uuidString: 1, UUID().uuidString: 1])] {
            do { try references.validate(); throw ReferenceCheckError.failed("invalid catalog accepted") }
            catch is ProjectError { }
        }
        let id = UUID()
        var original = EditorReferences(edits: [id.uuidString: 1])
        do {
            try original.merge(EditorReferences(edits: [id.uuidString: 2]))
            throw ReferenceCheckError.failed("conflicting names accepted")
        } catch is ProjectError { }
        try require(original.editLabel(for: id) == "Edit A", "failed merge is atomic")
    }
}
