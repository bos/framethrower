import Foundation

private enum HistoryCheckError: Error { case failed(String) }

@main @MainActor
struct HistoryStackChecks {
    static func main() throws {
        try checkChronology()
        try checkDraftAndFailure()
        print("History stack checks passed (shared chronological order, named entries, grouped multi-step Undo/Redo, draft boundaries, branch reset, durable names and failed-write atomicity; no media).")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw HistoryCheckError.failed(message) }
    }

    static func fixture() throws -> ProjectEditor {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "untouched.mov", duration: 12),
                                   url: directory.appendingPathComponent("history.framethrower"))
        try require(editor.save(), "save metadata fixture")
        return editor
    }

    static func checkChronology() throws {
        let editor = try fixture()
        defer { try? FileManager.default.removeItem(at: editor.url.deletingLastPathComponent()) }
        let initial = editor.project.state
        var first = initial
        first.zoomKeyframes = [ZoomKeyframe(time: 1, scale: 2)]
        try require(editor.commit(first, name: "Director: Frame Box 1"), "commit agent request")
        try require(editor.rename(to: "Manual title"), "manual change after agent")
        var third = editor.project.state
        third.cursorStyle.size = 2
        try require(editor.commit(third, name: "Resize pointer"), "independent pointer edit")
        try require(editor.historyState.undo == ["Resize pointer", "Rename recording", "Director: Frame Box 1"], "same ordered named stack for humans and models")
        let finished = editor.project
        try require(editor.undo(count: 2) && editor.project.state == first && editor.project.title == nil,
                    "Undo two entries includes the two newest actions, never skips manual work")
        try require(editor.historyState.redo == ["Rename recording", "Resize pointer"] && editor.project.undoHistory.count == 1,
                    "Redo describes next action first")
        try require(editor.redo(count: 2) && editor.project == finished, "Redo reconstructs exact chronology, name and history")
        try require(try ProjectEditor.open(url: editor.url).project == finished, "stack and names survive reopen")
        try require(editor.undo(count: 3) && editor.project.state == initial && editor.project.title == nil, "full rollback")
        try require(editor.redo(count: 3) && editor.project == finished, "full forward replay")
        try require(editor.undo(), "undo latest pointer edit")
        var replacement = editor.project.state
        replacement.cursorStyle.size = 3
        try require(editor.commit(replacement, name: "New pointer size") && editor.historyState.redo.isEmpty,
                    "a fresh edit clears the redo branch")
        let current = editor.project
        for count in [0, -1, 1000] {
            try require(!editor.undo(count: count) && !editor.redo(count: count) && editor.project == current,
                        "invalid stack jumps do not mutate anything")
        }
    }

    static func checkDraftAndFailure() throws {
        let editor = try fixture()
        defer { try? FileManager.default.removeItem(at: editor.url.deletingLastPathComponent()) }
        var saved = editor.project.state
        saved.zoomKeyframes = [ZoomKeyframe(time: 1, scale: 2)]
        try require(editor.commit(saved, name: "Saved framing"), "save framing")
        var draft = saved
        draft.zoomKeyframes[0].scale = 2.5
        try require(editor.updateDraft(draft, at: 1), "start draft")
        try require(editor.historyState.undo == ["Edit", "Saved framing"] && editor.historyState.redo.isEmpty,
                    "current gesture is the next undo entry")
        let before = editor.project
        let bytes = try Data(contentsOf: editor.url)
        try FileManager.default.removeItem(at: editor.url)
        try FileManager.default.createDirectory(at: editor.url, withIntermediateDirectories: false)
        try require(!editor.undo(count: 2) && editor.project == before && editor.draftState == draft,
                    "failed multi-step save retains draft and both branches")
        try FileManager.default.removeItem(at: editor.url)
        try bytes.write(to: editor.url)
        try require(editor.undo(count: 2) && editor.draftState == nil && editor.project.state.zoomKeyframes.isEmpty,
                    "retry undoes draft then saved edit")
        try require(editor.historyState.redo == ["Saved framing", "Edit"], "redo saved state before unfinished refinement")
        try require(editor.redo(count: 2) && editor.project.state == draft && editor.project.undoHistory.count == 2,
                    "redo brings the combined refinement back as a normal entry")
    }
}
