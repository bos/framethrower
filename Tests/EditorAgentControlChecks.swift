import Foundation

private enum ControlFailure: Error { case failed(String) }

@main @MainActor
struct EditorAgentControlChecks {
    static func main() async throws {
        try checkTools()
        try checkManagement()
        try checkHistory()
        try checkValidation()
        if CommandLine.arguments.contains("--model") { try await checkNativeModel() }
        print("Editor agent control checks passed (named create/move/remove, relative positions, collision clarification, strict scope, shared multi-step Undo/Redo, stale/draft rejection; no model or media).")
    }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ControlFailure.failed(message) }
    }
    static func names(_ request: String) -> [String] {
        EditorAgentControls.tools(for: request)?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } ?? []
    }
    static func checkTools() throws {
        try require(names("Undo that").contains("change_history") && names("Redo the last two changes").contains("change_history"), "ordinary history requests have one dedicated tool")
        try require(names("Create an edit five seconds after Edit A").contains("manage_edits"), "named mark request routed to mark tools")
        try require(names("Move Edit B two seconds after Edit A").contains("manage_edits"), "retiming uses mark management")
        try require(names("Zoom into Box 1 at Edit A").isEmpty && names("Move camera at Edit B").isEmpty, "framing requests retain their normal tool route")
    }

    private static func management(_ fixture: Fixture, _ changes: [[String: Any]]) throws -> [String: Any] {
        try ["version": 1, "project_id": fixture.projectID.uuidString, "expected_revision": fixture.context.recording.revision, "changes": changes]
    }
    static func change(_ action: String, _ label: String = "", base: String = "", offset: Double = 0) -> [String: Any] {
        if action == "delete" { return ["action": action, "edit_label": label] }
        if action == "create" { return ["action": action, "at_edit_label": base, "offset_seconds": offset] }
        return ["action": action, "edit_label": label, "at_edit_label": base, "offset_seconds": offset]
    }
    private static func history(_ fixture: Fixture, action: String, count: Any) throws -> [String: Any] {
        try ["version": 1, "project_id": fixture.projectID.uuidString, "expected_revision": fixture.context.recording.revision, "action": action, "count": count]
    }
    static func batch(_ result: LocalEditResult?) throws -> EditorCommandBatch {
        guard case let .commands(batch, _) = result else { throw ControlFailure.failed("expected ordinary command batch") }
        return batch
    }
    static func request(_ result: LocalEditResult?) throws -> EditorHistoryRequest {
        guard case let .history(request) = result else { throw ControlFailure.failed("expected shared history request") }
        return request
    }

    static func checkManagement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.editor.project.state
        let create = try batch(EditorAgentControls.result(name: "manage_edits", args: management(fixture, [change("create", base: "Edit A", offset: 5)]), context: fixture.context))
        try require(create.commands == [.createEdit(time: 6)], "relative mark resolves through named edit, not a spoken fractional timestamp")
        try EditorCommandDispatcher.apply(create, to: fixture.editor, projectID: fixture.projectID)
        let c = fixture.editor.project.state.timedEdits(includeCamera: true).first { abs($0.time - 6) < 0.000_001 }!
        try require(fixture.editor.references.editLabel(for: c.id) == "Edit C", "new mark gets normal durable visible reference")
        let changes = [change("move", "Edit B", base: "Edit A", offset: 2), change("delete", "Edit C")]
        let plan = try batch(EditorAgentControls.result(name: "manage_edits", args: management(fixture, changes), context: fixture.context))
        try EditorCommandDispatcher.apply(plan, to: fixture.editor, projectID: fixture.projectID)
        try require(fixture.editor.project.state.timedEdits(includeCamera: true).first { $0.id == fixture.b.id }?.time == 3,
                    "mark retiming preserves its identity")
        try require(!fixture.editor.project.state.timedEdits(includeCamera: true).contains { $0.id == c.id }, "remove uses stable mark identity")
        try require(fixture.editor.project.state.regions[0].time == original.regions[0].time && fixture.editor.project.state.regions[0].editID == fixture.b.id,
                    "retiming/removal never moves source box frames")
        try require(fixture.editor.undo(), "management batch is undoable")
        try require(fixture.editor.project.state.timedEdits(includeCamera: true).contains { $0.id == c.id } &&
                    fixture.editor.project.state.timedEdits(includeCamera: true).first { $0.id == fixture.b.id }?.time == 5,
                    "one Undo restores the entire multi-action request")
        for changes in [[change("move", "Edit B", base: "Edit A")], [change("delete", "Edit Z")],
                        [change("create", base: "start", offset: 12)], [change("create", base: "start", offset: -1)]] {
            let result = try EditorAgentControls.result(name: "manage_edits", args: management(fixture, changes), context: fixture.context)
            guard case .clarification = result else { throw ControlFailure.failed("missing/colliding/outside mark should ask a named clarification") }
        }
        let sequential = [change("move", "Edit B", base: "Edit A", offset: 2), change("create", base: "Edit B", offset: 1)]
        let virtual = try batch(EditorAgentControls.result(name: "manage_edits", args: management(fixture, sequential), context: fixture.context))
        try require(virtual.commands == [.moveEdit(editID: fixture.b.id, time: 3), .createEdit(time: 4)], "later relative actions use prior retiming in the same request")
    }

    static func checkHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var next = fixture.editor.project.state
        next.cursorStyle.size = 2
        try require(fixture.editor.commit(next, name: "Resize pointer"), "manual edit fixture")
        next.presentation.padding = 0.1
        try require(fixture.editor.commit(next, name: "Add padding"), "second manual edit fixture")
        let finished = fixture.editor.project.state
        let context = try fixture.context
        try require(context.recording.history.undo.prefix(2).elementsEqual(["Add padding", "Resize pointer"]), "context exposes actual shared latest-first history")
        let undo = try request(EditorAgentControls.result(name: "change_history", args: history(fixture, action: "undo", count: 2), context: context))
        try EditorHistoryDispatcher.apply(undo, to: fixture.editor, projectID: fixture.projectID)
        try require(fixture.editor.project.undoHistory.isEmpty && fixture.editor.project.redoHistory.count == 2, "multi-step Undo traverses whole normal stack")
        let redo = try request(EditorAgentControls.result(name: "change_history", args: history(fixture, action: "redo", count: 2), context: fixture.context))
        try EditorHistoryDispatcher.apply(redo, to: fixture.editor, projectID: fixture.projectID)
        try require(fixture.editor.project.state == finished && (try ProjectEditor.open(url: fixture.editor.url).project.state) == finished, "Redo restores state durably through the same stack")
        let allCurrent = try fixture.context
        var ownedContext = allCurrent
        ownedContext.recording.history.undo = ["Move camera", "Director: Frame Box 1", "Rename recording"]
        let ownershipArguments = try history(fixture, action: "undo", count: 1)
        let ownership = try EditorAgentControls.result(name: "change_history", args: ownershipArguments,
            context: ownedContext, instruction: "Undo your last change")
        guard case let .clarification(question) = ownership else { throw ControlFailure.failed("manual changes must never be silently skipped to undo only an agent change") }
        try require(question.contains("Move camera") && question.contains("2 entries in order"), "ownership question names actual latest manual change and contiguous stack depth")
        let ordinary = try request(EditorAgentControls.result(name: "change_history", args: ownershipArguments,
            context: ownedContext, instruction: "Undo"))
        try require(ordinary.count == 1, "ordinary Undo still traverses the latest shared entry regardless of author")
        ownedContext.recording.history.undo = ["Director: Frame Box 1", "Move camera"]
        _ = try request(EditorAgentControls.result(name: "change_history", args: ownershipArguments,
            context: ownedContext, instruction: "Undo your last change"))
        ownedContext.recording.history.undo = ["Edit with assistant", "Move camera"]
        _ = try request(EditorAgentControls.result(name: "change_history", args: ownershipArguments,
            context: ownedContext, instruction: "Undo your last change"))
        ownedContext.recording.history.undo = ["Director: Frame Box 1", "Rename recording", "Director: Move Edit B"]
        let twoArguments = try history(fixture, action: "undo", count: 2)
        let mixedTwo = try EditorAgentControls.result(name: "change_history", args: twoArguments,
            context: ownedContext, instruction: "Undo your last two changes")
        guard case let .clarification(mixedQuestion) = mixedTwo else { throw ControlFailure.failed("owned multi-Undo must not cross a manual entry silently") }
        try require(mixedQuestion.contains("Rename recording") && mixedQuestion.contains("3 entries in order"),
                    "owned multi-Undo reports the intervening manual entry and full contiguous span")
        let plainTwo = try request(EditorAgentControls.result(name: "change_history", args: twoArguments,
            context: ownedContext, instruction: "Undo two changes"))
        try require(plainTwo.count == 2, "ordinary multi-Undo keeps its explicit shared stack depth")
        ownedContext.recording.history.redo = ["Director: Frame Box 1", "Rename recording", "Director: Move Edit B"]
        let redoArguments = try history(fixture, action: "redo", count: 2)
        let mixedRedo = try EditorAgentControls.result(name: "change_history", args: redoArguments,
            context: ownedContext, instruction: "Redo your last two changes")
        guard case let .clarification(redoQuestion) = mixedRedo else { throw ControlFailure.failed("owned multi-Redo must not cross manual entries silently") }
        try require(redoQuestion.contains("Rename recording") && redoQuestion.contains("3 entries in order"), "owned Redo uses the same contiguous stack rule")
        try require(fixture.editor.rename(to: "Changed while planning"), "change revision after history request")
        do { try EditorHistoryDispatcher.apply(undo, to: fixture.editor, projectID: fixture.projectID); throw ControlFailure.failed("stale history accepted") }
        catch EditorCommandError.stale { }
        let tooMany = try EditorAgentControls.result(name: "change_history", args: history(fixture, action: "undo", count: 99), context: fixture.context)
        guard case .clarification = tooMany else { throw ControlFailure.failed("history depth must not silently clamp") }
        let current = try EditorHistoryRequest(projectID: fixture.projectID, revision: fixture.context.recording.revision, action: .undo, count: 1)
        var draft = fixture.editor.project.state
        draft.zoomKeyframes = [ZoomKeyframe(time: 3, scale: 2)]
        try require(fixture.editor.updateDraft(draft, at: 3), "pending manual draft fixture")
        do { try EditorHistoryDispatcher.apply(current, to: fixture.editor, projectID: fixture.projectID); throw ControlFailure.failed("pending draft silently traversed") }
        catch EditorCommandError.pendingDraft { }
    }

    static func checkValidation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let valid = try history(fixture, action: "undo", count: 1)
        for patch: [String: Any] in [["count": true], ["count": 0], ["count": -1], ["count": 1.5], ["count": Double.infinity], ["version": 2], ["action": "undo_agent"], ["skip_manual": true]] {
            do {
                _ = try EditorAgentControls.result(name: "change_history", args: valid.merging(patch) { _, b in b }, context: fixture.context)
                throw ControlFailure.failed("invalid history arguments accepted")
            } catch is EditorCommandError { }
        }
        do {
            _ = try EditorAgentControls.result(name: "change_history", args: valid.merging(["project_id": UUID().uuidString]) { _, b in b }, context: fixture.context)
            throw ControlFailure.failed("cross-project request accepted")
        } catch EditorCommandError.stale { }
        for malformed: [String: Any] in [
            ["action": "delete", "edit_label": "Edit B", "offset_seconds": 0],
            ["action": "create", "edit_label": "Edit Z", "at_edit_label": "Edit A", "offset_seconds": 2],
            ["action": "move", "edit_label": "Edit B"]
        ] {
            do {
                _ = try EditorAgentControls.result(name: "manage_edits", args: management(fixture, [malformed]), context: fixture.context)
                throw ControlFailure.failed("action-specific fields must remain strict")
            } catch is EditorCommandError { }
        }
    }

    static func checkNativeModel() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var requestIndex = 0
        func run(_ instruction: String) async throws -> LocalEditResult {
            requestIndex += 1
            let context = try fixture.context
            let payload = try LocalEditPlanner.payload(request: instruction, context: context)
            let response = try await LocalModelRuntime.shared.chat(payload: payload)
            do { return try LocalEditPlanner.result(response, context: context, instruction: instruction) }
            catch {
                if let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let message = choices.first?["message"] as? [String: Any],
                   let calls = message["tool_calls"] as? [[String: Any]],
                   let fn = calls.first?["function"] as? [String: Any],
                   let encoded = fn["arguments"] as? String,
                   let arguments = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] {
                    print("Native control mismatch metadata: case=\(requestIndex), tool=\(fn["name"] as? String ?? "none"), fields=\(arguments.keys.sorted())")
                    print("Argument types: \(arguments.mapValues { String(describing: type(of: $0)) })")
                    if let changes = arguments["changes"] as? [[String: Any]] {
                        for change in changes {
                            print("Change fields/types: \(change.mapValues { String(describing: type(of: $0)) })")
                            let knownAction = ["create", "move", "delete"].contains(change["action"] as? String ?? "") ? change["action"] as? String ?? "" : "unknown"
                            print("Change semantics: action=\(knownAction), baseEmpty=\((change["at_edit_label"] as? String)?.isEmpty ?? false), baseEqualsTarget=\((change["at_edit_label"] as? String) == (change["edit_label"] as? String)), offset=\((change["offset_seconds"] as? NSNumber)?.doubleValue ?? .nan)")
                        }
                    }
                    fflush(nil)
                }
                throw error
            }
        }
        let create = try batch(try await run("Create a new edit mark five seconds after Edit A."))
        try require(create.commands == [.createEdit(time: 6)], "native create resolves the relative source time")
        try EditorCommandDispatcher.apply(create, to: fixture.editor, projectID: fixture.projectID, name: "Director: Create edit mark")
        guard let c = fixture.editor.project.state.timedEdits(includeCamera: true).first(where: { abs($0.time - 6) < 0.000_001 }) else {
            throw ControlFailure.failed("native create did not create its mark")
        }
        try require(fixture.editor.references.editLabel(for: c.id) == "Edit C", "native create receives a real stable visible label")
        let move = try batch(try await run("Move Edit B to two seconds after Edit A."))
        try require(move.commands == [.moveEdit(editID: fixture.b.id, time: 3)], "native move resolves the existing identity and relative source time")
        try EditorCommandDispatcher.apply(move, to: fixture.editor, projectID: fixture.projectID, name: "Director: Move Edit B")
        let remove = try batch(try await run("Delete Edit C."))
        try require(remove.commands == [.removeEdit(editID: c.id)], "native remove uses the actual generated label in updated context")
        try EditorCommandDispatcher.apply(remove, to: fixture.editor, projectID: fixture.projectID, name: "Director: Remove Edit C")
        let afterRemoval = fixture.editor.project.state
        try require(!afterRemoval.timedEdits(includeCamera: true).contains { $0.id == c.id }, "native remove changes normal saved state")
        let undo = try request(try await run("Undo the last change."))
        try require(undo.action == .undo && undo.count == 1, "native model requests ordinary latest Undo")
        try EditorHistoryDispatcher.apply(undo, to: fixture.editor, projectID: fixture.projectID)
        try require(fixture.editor.project.state.timedEdits(includeCamera: true).contains { $0.id == c.id }, "native Undo restores removed Edit C from shared history")
        let redo = try request(try await run("Redo that change."))
        try require(redo.action == .redo && redo.count == 1, "native model requests ordinary latest Redo")
        try EditorHistoryDispatcher.apply(redo, to: fixture.editor, projectID: fixture.projectID)
        try require(fixture.editor.project.state == afterRemoval && (try ProjectEditor.open(url: fixture.editor.url).project.state) == afterRemoval,
                    "native Redo restores actual saved shared history state")
        print("Native Metal agent control checks passed (create/move/remove named marks, generated label receipts, relative times, actual shared Undo/Redo; no media).")
    }

    @MainActor private final class Fixture {
        let directory: URL
        let editor: ProjectEditor
        let projectID = UUID()
        let a = EditAnchor(time: 1), b = EditAnchor(time: 5)
        var context: LocalEditContext {
            get throws {
                LocalEditContext(recording: try EditorCommandDispatcher.context(editor: editor, projectID: projectID),
                                 playhead: 2, selectedRegionID: nil, selectedEditID: nil, videoProcessingAvailable: false)
            }
        }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "untouched.mov", duration: 12)
            project.state.editAnchors = [a, b]
            project.state.regions = [EditorRegion(time: 5, rect: EditorRegionRect(x: 0, y: 0, width: 0.3, height: 0.3), editID: b.id)]
            editor = ProjectEditor(project: project, url: directory.appendingPathComponent("test.framethrower"))
            guard editor.save() else { throw ControlFailure.failed("save fixture") }
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
