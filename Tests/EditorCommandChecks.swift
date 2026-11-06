import Foundation

private enum CheckError: Error { case failed(String) }

@main
@MainActor
struct EditorCommandChecks {
    static func main() throws {
        try checkGeometry()
        try checkCodable()
        try checkAtomicHistory()
        try checkValidation()
        print("Editor command checks passed (region geometry, strict commands, atomic batches, same-time coalescing, preserved edit identity, stale/draft rejection, and Undo/Redo).")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckError.failed(message) }
    }

    private static func rejects(_ body: () throws -> Void, _ message: String) throws {
        do { try body() } catch is EditorCommandError { return } catch is ProjectError { return }
        throw CheckError.failed(message)
    }

    private static func checkGeometry() throws {
        for rect in [EditorRegionRect(x: 0, y: 0, width: 0.15, height: 0.1),
                     EditorRegionRect(x: 0.8, y: 0.7, width: 0.2, height: 0.3),
                     EditorRegionRect(x: 0.1, y: 0.2, width: 0.8, height: 0.4),
                     EditorRegionRect(x: 0, y: 0, width: 1, height: 1)] {
            let placement = rect.framing()
            let viewport = placement.viewport(in: CGSize(width: 1, height: 1))
            try require(viewport.minX <= rect.x + 1e-9 && viewport.minY <= rect.y + 1e-9 &&
                        viewport.maxX + 1e-9 >= rect.x + rect.width && viewport.maxY + 1e-9 >= rect.y + rect.height,
                        "region fitting must preserve the entire region at edges and aspect extremes")
        }
        try rejects({ try EditorRegion(time: 0, rect: EditorRegionRect(x: .nan, y: 0, width: 1, height: 1)).validate(duration: 2) },
                    "nonfinite coordinates must fail")
        try rejects({ try EditorRegion(time: 0, rect: EditorRegionRect(x: 0, y: 0, width: 2, height: 1)).validate(duration: 2) },
                    "out of frame coordinates must fail")
    }

    private static func checkCodable() throws {
        let commands: [EditorCommand] = [.frameRegion(regionID: UUID(), time: 1), .holdFraming(time: 4),
            .fullFrame(time: 5), .reviseFraming(editID: UUID(), regionID: UUID()), .labelRegion(regionID: UUID(), note: "Title")]
        let data = try JSONEncoder().encode(commands)
        try require(try JSONDecoder().decode([EditorCommand].self, from: data) == commands, "every command round trips")
        for json in ["{\"action\":\"runShell\",\"path\":\"/tmp\"}",
                     "{\"action\":\"fullFrame\",\"time\":1,\"path\":\"/tmp\"}",
                     "{\"action\":\"fullFrame\",\"time\":1,\"regionID\":\"irrelevant\"}"] {
            try rejects({ _ = try JSONDecoder().decode(EditorCommand.self, from: Data(json.utf8)) }, "unknown actions and fields must fail")
        }
    }

    private static func checkAtomicHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = fixture.editor
        let original = editor.project
        let context = try EditorCommandDispatcher.context(editor: editor, projectID: fixture.projectID)
        let batch = EditorCommandBatch(projectID: fixture.projectID, revision: context.revision,
            commands: [.frameRegion(regionID: fixture.region.id, time: 1), .holdFraming(time: 4),
                       .fullFrame(time: 5), .labelRegion(regionID: fixture.region.id, note: "Search results")])
        try EditorCommandDispatcher.apply(batch, to: editor, projectID: fixture.projectID)
        try require(editor.project.undoHistory.count == 1 && editor.project.state.zoomKeyframes.count == 3,
                    "sequence plus label is one durable edit")
        try require(editor.project.state.zoom(at: 3) == editor.project.state.zoom(at: 1),
                    "hold anchor prevents movement before the requested zoom-out interval")
        try require(editor.project.state.zoom(at: 5).scale == 1 && editor.project.state.regions[0].note == "Search results",
                    "framing and descriptive notes are independent editable values")
        let finished = editor.project.state
        try require(editor.undo() && editor.project.state == original.state, "one Undo restores whole request")
        try require(editor.redo() && editor.project.state == finished, "one Redo restores whole request")
        try require(try ProjectEditor.open(url: editor.url).project.state == finished, "commands save normal projects")

        let point = editor.project.state.zoomKeyframes[0]
        let revised = EditorCommandBatch(projectID: fixture.projectID,
            revision: try EditorCommandDispatcher.revision(for: editor.project),
            commands: [.reviseFraming(editID: point.id, regionID: fixture.other.id)])
        try EditorCommandDispatcher.apply(revised, to: editor, projectID: fixture.projectID)
        let changed = editor.project.state.zoomKeyframes[0]
        try require(changed.id == point.id && changed.time == point.time && changed.transition == point.transition &&
                    changed.duration == point.duration && changed.placement != point.placement,
                    "revising keeps timing, transition, and identity")
        let sameTime = EditorCommandBatch(projectID: fixture.projectID,
            revision: try EditorCommandDispatcher.revision(for: editor.project),
            commands: [.frameRegion(regionID: fixture.region.id, time: 1), .frameRegion(regionID: fixture.other.id, time: 1)])
        try EditorCommandDispatcher.apply(sameTime, to: editor, projectID: fixture.projectID)
        try require(editor.project.state.zoomKeyframes.count == 3 && editor.project.state.zoomKeyframes[0].id == point.id &&
                    editor.project.state.zoomKeyframes[0].placement == fixture.other.rect.framing(),
                    "same-time refinements replace one edit")
    }

    private static func checkValidation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = fixture.editor
        let context = try EditorCommandDispatcher.context(editor: editor, projectID: fixture.projectID)
        let saved = try Data(contentsOf: editor.url)
        let invalidSequences: [[EditorCommand]] = [
            [.frameRegion(regionID: fixture.region.id, time: 1), .frameRegion(regionID: UUID(), time: 2)],
            [.frameRegion(regionID: fixture.region.id, time: 3), .fullFrame(time: 2)],
            [.fullFrame(time: 12)], [.fullFrame(time: .infinity)],
            [.fullFrame(time: 1, motion: EditorCommandMotion(duration: -1))],
            [.labelRegion(regionID: fixture.region.id, note: String(repeating: "x", count: 4_097))],
            [.reviseFraming(editID: UUID(), regionID: fixture.region.id)], []
        ]
        for commands in invalidSequences {
            let batch = EditorCommandBatch(projectID: fixture.projectID, revision: context.revision, commands: commands)
            try rejects({ try EditorCommandDispatcher.apply(batch, to: editor, projectID: fixture.projectID) },
                        "invalid request must reject")
            try require(editor.project.undoHistory.isEmpty && (try Data(contentsOf: editor.url)) == saved,
                        "a later invalid action must leave both memory and disk untouched")
        }
        var pending = editor.project.state
        pending.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2)]
        try require(editor.updateDraft(pending, at: 2), "create pending manual edit")
        let valid = EditorCommandBatch(projectID: fixture.projectID, revision: context.revision, commands: [.fullFrame(time: 4)])
        try rejects({ try EditorCommandDispatcher.apply(valid, to: editor, projectID: fixture.projectID) }, "pending manual edits must not be silently committed")
        try require(editor.draftState == pending && editor.project.undoHistory.isEmpty, "draft rejection preserves manual work")
        try require(editor.finishDraft(), "finish manual edit")
        try rejects({ try EditorCommandDispatcher.apply(valid, to: editor, projectID: fixture.projectID) }, "stale request must reject")
        let current = EditorCommandBatch(projectID: UUID(), revision: try EditorCommandDispatcher.revision(for: editor.project),
                                         commands: [.fullFrame(time: 4)])
        try rejects({ try EditorCommandDispatcher.apply(current, to: editor, projectID: fixture.projectID) }, "cross-window project mismatch must reject")
        try require(editor.project.undoHistory.count == 1, "rejected requests never add history")
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let editor: ProjectEditor
        let projectID = UUID()
        let region = EditorRegion(time: 1, rect: EditorRegionRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3))
        let other = EditorRegion(time: 2, rect: EditorRegionRect(x: 0.6, y: 0.1, width: 0.3, height: 0.2))
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "original.mov", duration: 12)
            project.state.regions = [region, other]
            let url = directory.appendingPathComponent("recording.framethrower")
            try JSONEncoder().encode(project).write(to: url)
            editor = try ProjectEditor.open(url: url)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
