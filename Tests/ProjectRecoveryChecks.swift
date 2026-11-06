import Foundation

private enum RecoveryCheckError: Error { case failed(String) }

@main
@MainActor
struct ProjectRecoveryChecks {
    static func main() async throws {
        try await checkCoalescedRecovery()
        try checkJournalProtection()
        try checkRecoveryWriteFailure()
        try checkSourceCollisions()
        try checkHistoryNavigation()
        print("Project recovery checks passed (coalesced journals, crash recovery, bounded/stale/corrupt protection, failure retry, immutable sources, and Undo/Redo navigation).")
    }

    private static func checkCoalescedRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = fixture.editor
        let baseline = editor.project
        let saved = try Data(contentsOf: editor.url)
        var state = edited(baseline.state, at: 2)
        for sample in 0..<200 {
            state.zoomKeyframes[0].scale = 1.5 + Double(sample) / 200
            try require(editor.updateDraft(state, at: 2), "refine recovery draft")
        }
        try require(!FileManager.default.fileExists(atPath: editor.recoveryURL.path),
                    "two hundred immediate samples cannot each write a recovery file")
        try await Task.sleep(for: .milliseconds(100))
        try require(!FileManager.default.fileExists(atPath: editor.recoveryURL.path),
                    "recovery waits for its coalescing interval")
        try await Task.sleep(for: .milliseconds(250))
        let recovered = try ProjectEditor.open(url: editor.url)
        try require(recovered.recoveryRestored && recovered.project == baseline && recovered.references == editor.references && recovered.draftState == state && recovered.draftTime == 2,
                    "reopening restores the latest combined draft without rewriting saved history")
        try require(try Data(contentsOf: editor.url) == saved, "journaling cannot change the saved project")
        let journalData = try Data(contentsOf: editor.recoveryURL)
        let journal = try JSONSerialization.jsonObject(with: journalData) as! [String: Any]
        try require(Set(journal.keys) == Set(["version", "baseSHA256", "state", "time", "references"]) &&
                    (journal["baseSHA256"] as? String)?.count == 64 && journal["undoHistory"] == nil,
                    "recovery stores only a version, base digest, pending state, source time, and stable references")
        try await Task.sleep(for: .milliseconds(300))
        try require(try Data(contentsOf: editor.recoveryURL) == journalData, "an idle draft does not rewrite its journal repeatedly")
        try require(recovered.undo() && recovered.draftState == nil && recovered.canRedo &&
                    recovered.project.undoHistory == baseline.undoHistory && recovered.historyNavigationTime == 2,
                    "recovered draft Undo returns to baseline and can be redone")
        try require(!FileManager.default.fileExists(atPath: recovered.recoveryURL.path),
                    "successful Undo replaces recovery with durable redo history")
        try require(recovered.redo() && recovered.project.state == state && recovered.project.undoHistory.count == 1,
                    "Redo restores the whole recovered draft as one saved edit")
        try fixture.assertSources()

        var second = recovered.project.state
        second.zoomKeyframes[0].scale = 2.8
        try require(recovered.updateDraft(second, at: 2) && recovered.flushRecovery(), "flush latest pending edit explicitly")
        let savedDraft = try ProjectEditor.open(url: recovered.url)
        try require(savedDraft.recoveryRestored && savedDraft.save() && savedDraft.draftState == nil &&
                    !savedDraft.recoveryRestored && !FileManager.default.fileExists(atPath: savedDraft.recoveryURL.path),
                    "Save commits recovery once and removes the owned journal")
        let afterSave = try ProjectEditor.open(url: savedDraft.url)
        try require(afterSave.draftState == nil && !afterSave.recoveryRestored && afterSave.project.state == second,
                    "a completed recovery does not resurrect on the next open")
        var cancel = second
        cancel.zoomKeyframes[0].scale = 2.6
        try require(afterSave.updateDraft(cancel, at: 2) && afterSave.flushRecovery() && afterSave.cancelDraft(),
                    "Escape discards an owned recovery draft")
        try require(!FileManager.default.fileExists(atPath: afterSave.recoveryURL.path), "cancel removes its recovery journal")
    }

    private static func checkJournalProtection() throws {
        for invalid in ["mismatched base", "corrupt JSON", "invalid time", "invalid state", "unsupported version", "oversized"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let editor = fixture.editor
            let draft = edited(editor.project.state, at: 2)
            try require(editor.updateDraft(draft, at: 2) && editor.flushRecovery(), "prepare invalid-journal fixture")
            var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: editor.recoveryURL)) as! [String: Any]
            switch invalid {
            case "mismatched base":
                var outside = editor.project
                outside.title = "External name change"
                try JSONEncoder().encode(outside).write(to: editor.url, options: .atomic)
            case "corrupt JSON": try Data("not a recovery file".utf8).write(to: editor.recoveryURL)
            case "invalid time":
                journal["time"] = -1
                try JSONSerialization.data(withJSONObject: journal).write(to: editor.recoveryURL)
            case "invalid state":
                var state = journal["state"] as! [String: Any]
                var zooms = state["zoomKeyframes"] as! [[String: Any]]
                zooms[0]["scale"] = 9
                state["zoomKeyframes"] = zooms
                journal["state"] = state
                try JSONSerialization.data(withJSONObject: journal).write(to: editor.recoveryURL)
            case "unsupported version":
                journal["version"] = 2
                try JSONSerialization.data(withJSONObject: journal).write(to: editor.recoveryURL)
            default: try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: editor.recoveryURL)
            }
            let journalBefore = try Data(contentsOf: editor.recoveryURL)
            let projectBefore = try Data(contentsOf: editor.url)
            let reopened = try ProjectEditor.open(url: editor.url)
            try require(reopened.draftState == nil && !reopened.recoveryRestored && reopened.errorMessage != nil,
                        "\(invalid) must leave the saved recording usable and report failed recovery")
            try require(try Data(contentsOf: editor.recoveryURL) == journalBefore &&
                        Data(contentsOf: editor.url) == projectBefore,
                        "failed recovery never discards the journal or replaces the saved project")
            try require(reopened.save(), "saved recording remains writable after failed recovery")
            let newDraft = edited(reopened.project.state, at: 2)
            try require(reopened.updateDraft(newDraft, at: 2) && !reopened.flushRecovery() && reopened.cancelDraft(),
                        "new editing cannot silently replace a protected recovery journal")
            try require(try Data(contentsOf: editor.recoveryURL) == journalBefore,
                        "save, new editing, and cancel preserve the protected journal")
            try fixture.assertSources()
        }
    }

    private static func checkRecoveryWriteFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = fixture.editor
        let baseline = editor.project
        let saved = try Data(contentsOf: editor.url)
        let state = edited(baseline.state, at: 2)
        try require(editor.updateDraft(state, at: 2) && editor.flushRecovery(), "prepare recoverable draft before failed project save")
        try FileManager.default.removeItem(at: editor.url)
        try FileManager.default.createDirectory(at: editor.url, withIntermediateDirectories: false)
        try require(!editor.finishDraft() && editor.project == baseline && editor.draftState == state,
                    "failed project save retains draft and history")
        try require(FileManager.default.fileExists(atPath: editor.recoveryURL.path),
                    "failed project save keeps the journal available")
        try FileManager.default.removeItem(at: editor.url)
        try saved.write(to: editor.url)
        let restored = try ProjectEditor.open(url: editor.url)
        try require(restored.recoveryRestored && restored.draftState == state && restored.save(),
                    "recovery survives a failed project write and can be retried")
        try fixture.assertSources()

        let second = try Fixture()
        defer { second.remove() }
        let other = second.editor
        let moved = second.directory.appendingPathExtension("moved")
        try require(other.updateDraft(edited(other.project.state, at: 2), at: 2), "prepare failed journal write")
        try FileManager.default.moveItem(at: second.directory, to: moved)
        try require(!other.flushRecovery() && other.draftState != nil && other.errorMessage != nil,
                    "journal IO failure reports an error without losing the live draft")
        try FileManager.default.moveItem(at: moved, to: second.directory)
        try require(other.flushRecovery(), "journal write can be retried after storage recovers")
    }

    private static func checkSourceCollisions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.framethrower")
        let original = Data("original source at a recovery-like filename".utf8)
        try original.write(to: url.appendingPathExtension("recovery"))
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "recording.framethrower.recovery", duration: 4), url: url)
        try require(editor.save() && editor.updateDraft(edited(editor.project.state, at: 2), at: 2) && !editor.flushRecovery(),
                    "a recovery filename colliding with source media must be rejected")
        try require(try Data(contentsOf: editor.recoveryURL) == original, "source filename collision preserves original bytes")
        try require(editor.cancelDraft() && Data(contentsOf: editor.recoveryURL) == original,
                    "cancel cannot delete a recovery-like source filename")

        let symlink = try Fixture()
        defer { symlink.remove() }
        try FileManager.default.createSymbolicLink(at: symlink.editor.recoveryURL, withDestinationURL: symlink.source)
        let sourceBytes = try Data(contentsOf: symlink.source)
        try require(symlink.editor.updateDraft(edited(symlink.editor.project.state, at: 2), at: 2) && !symlink.editor.flushRecovery(),
                    "a recovery symlink resolving to source media must be rejected")
        try require(try Data(contentsOf: symlink.source) == sourceBytes, "recovery cannot overwrite a symlinked source")
        let projectLink = try Fixture()
        defer { projectLink.remove() }
        try FileManager.default.createSymbolicLink(at: projectLink.editor.recoveryURL, withDestinationURL: projectLink.editor.url)
        let projectBytes = try Data(contentsOf: projectLink.editor.url)
        try require(projectLink.editor.updateDraft(edited(projectLink.editor.project.state, at: 2), at: 2) && !projectLink.editor.flushRecovery(),
                    "a recovery symlink resolving to the saved project must be rejected")
        try require(try Data(contentsOf: projectLink.editor.url) == projectBytes,
                    "recovery cannot replace the saved project via a symlink")
    }

    private static func checkHistoryNavigation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = fixture.editor
        var first = editor.project.state
        first.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2), ZoomKeyframe(time: 3, scale: 1.5)]
        first.pipKeyframes.append(PIPKeyframe(time: 2, placement: PIPPlacement(x: 0.2, y: 0.7)))
        try require(editor.commit(first, name: "Combined edit") && editor.undo() && editor.historyNavigationTime == 2,
                    "Undo reveals the earliest changed zoom/camera time without selecting unchanged baseline zero")
        let token = editor.historyNavigationToken
        try require(token != nil && editor.redo() && editor.historyNavigationTime == 2 && editor.historyNavigationToken != token,
                    "Redo gets a fresh reveal token even when its affected time matches the preceding Undo")
        var moved = first
        moved.zoomKeyframes[0].time = 1
        moved.pipKeyframes[1].time = 1
        try require(editor.commit(moved, name: "Move edit") && editor.undo() && editor.historyNavigationTime == 1,
                    "timing Undo reveals the earliest old/new affected time")
        let beforeNameToken = editor.historyNavigationToken
        try require(editor.rename(to: "Renamed") && editor.undo() && editor.historyNavigationTime == nil &&
                    editor.historyNavigationToken == beforeNameToken,
                    "title-only Undo does not warp the playhead")
        var canvas = editor.project.state
        canvas.presentation.padding = 0.1
        try require(editor.commit(canvas, name: "Canvas") && editor.undo() && editor.historyNavigationTime == nil &&
                    editor.historyNavigationToken == beforeNameToken,
                    "whole-recording presentation Undo does not seek")
        var pointer = editor.project.state
        pointer.cursorStyle.size = 2
        try require(editor.commit(pointer, name: "Pointer") && editor.undo() && editor.historyNavigationTime == nil,
                    "whole-recording pointer Undo does not seek")
        var initialCamera = editor.project.state
        initialCamera.pipKeyframes[0].placement.x = 0.2
        try require(editor.commit(initialCamera, name: "Initial camera") && editor.undo() && editor.historyNavigationTime == 0,
                    "a changed baseline camera genuinely belongs at time zero")
    }

    private static func edited(_ state: EditState, at time: Double) -> EditState {
        var next = state
        next.zoomKeyframes = [ZoomKeyframe(time: time, scale: 2, x: 0.4, y: 0.6)]
        next.pipKeyframes.append(PIPKeyframe(time: time, placement: PIPPlacement(x: 0.3, y: 0.6)))
        return next
    }

    @MainActor private struct Fixture {
        let directory: URL
        let source: URL
        let editor: ProjectEditor
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            source = directory.appendingPathComponent("screen.mp4")
            try Data("immutable recovery fixture source".utf8).write(to: source)
            editor = ProjectEditor(project: RecordingProject(screenFilename: source.lastPathComponent, duration: 4),
                                   url: directory.appendingPathComponent("recording.framethrower"))
            guard editor.save() else { throw RecoveryCheckError.failed("save fixture") }
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func assertSources() throws {
            try require(try Data(contentsOf: source) == Data("immutable recovery fixture source".utf8),
                        "recovery and history operations must preserve original source bytes")
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw RecoveryCheckError.failed(message) }
    }
}
