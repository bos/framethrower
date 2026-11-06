import Foundation
import Combine

private enum HistoryCheckError: Error { case failed(String) }

@main @MainActor
struct HistoryStackChecks {
    static func main() throws {
        try checkChronology()
        try checkDraftAndFailure()
        try checkOperationPublication()
        print("History stack checks passed (shared chronological order, named entries, grouped multi-step Undo/Redo, draft boundaries, branch reset, durable names, precise publication metadata and failed-write atomicity; no media).")
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

    static func checkOperationPublication() throws {
        let editor = try fixture()
        defer { try? FileManager.default.removeItem(at: editor.url.deletingLastPathComponent()) }
        var operations: [ProjectHistoryOperation?] = []
        let subscription = editor.$project.dropFirst().sink { _ in
            operations.append(editor.publishingHistoryOperation)
        }
        defer { subscription.cancel() }
        func expect(_ kind: ProjectHistoryOperation.Kind, _ names: [String], _ message: String) throws {
            try require(operations.last == ProjectHistoryOperation(kind: kind, names: names), message)
            try require(editor.publishingHistoryOperation == nil, "operation exists only during synchronous publication")
        }

        var saved = editor.project.state
        saved.cursorStyle.size = 2
        try require(editor.commit(saved, name: "Resize pointer"), "commit named metadata action")
        try expect(.edit, ["Resize pointer"], "publish actual committed action")
        var draft = saved
        draft.cursorStyle.size = 3
        try require(editor.updateDraft(draft, at: 1), "start metadata draft")
        let committedUndoCount = editor.project.undoHistory.count
        try require(editor.undo(), "undo unfinished draft")
        try require(editor.project.undoHistory.count == committedUndoCount, "draft Undo leaves committed Undo count unchanged")
        try expect(.undo, ["Edit"], "draft Undo must not be reported as an edit or the preceding committed action")
        try require(editor.redo(), "redo unfinished draft")
        try expect(.redo, ["Edit"], "publish draft Redo")
        try require(editor.undo(count: 2), "undo draft refinement and pointer edit")
        try expect(.undo, ["Edit", "Resize pointer"], "publish multi-step Undo names in execution order")
        try require(editor.redo(count: 2), "redo grouped actions")
        try expect(.redo, ["Resize pointer", "Edit"], "publish multi-step Redo names in execution order")

        try require(editor.undo(), "open a Redo branch")
        var replacement = editor.project.state
        replacement.cursorStyle.size = 4
        try require(editor.commit(replacement, name: "New pointer size"), "commit new manual branch")
        try require(editor.project.redoHistory.isEmpty, "new manual edit clears Redo")
        try expect(.edit, ["New pointer size"], "new manual edit after Undo must not be reported as Redo")
        try require(editor.rename(to: "Renamed"), "rename metadata action")
        try expect(.edit, ["Rename recording"], "publish rename action")
        var nextDraft = editor.project.state
        nextDraft.cursorStyle.size = 3.5
        try require(editor.updateDraft(nextDraft, at: 2) && editor.finishDraft(name: "Adjust pointer"), "finish named draft")
        try expect(.edit, ["Adjust pointer"], "publish actual draft action name")

        let beforeNoChange = operations.count
        try require(editor.commit(editor.project.state, name: "No change"), "accept unchanged state")
        try require(operations.count == beforeNoChange && editor.publishingHistoryOperation == nil,
                    "no-change commit publishes no history operation")
        try require(editor.save(), "plain save")
        try require(operations.count == beforeNoChange + 1 && operations.last! == nil && editor.publishingHistoryOperation == nil,
                    "plain save publishes no attributed history operation")

        let beforeFailure = operations.count
        let bytes = try Data(contentsOf: editor.url)
        try FileManager.default.removeItem(at: editor.url)
        try FileManager.default.createDirectory(at: editor.url, withIntermediateDirectories: false)
        try require(!editor.undo(), "force failed history write")
        try require(operations.count == beforeFailure && editor.publishingHistoryOperation == nil,
                    "failed save emits no project or operation metadata")
        try FileManager.default.removeItem(at: editor.url)
        try bytes.write(to: editor.url)
        try require(editor.undo(), "retry after failed write")
        try expect(.undo, ["Adjust pointer"], "retry publishes only the successful operation")
    }
}
