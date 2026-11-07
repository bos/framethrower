import Foundation

private enum DirectChoiceFailure: Error { case failed(String) }
actor DirectChoiceTransport {
    private(set) var payloads = [Data]()
    private var replies = [Int: CheckedContinuation<Data, any Error>]()
    func send(_ data: Data) async throws -> Data {
        let index = payloads.count; payloads.append(data)
        return try await withCheckedThrowingContinuation { replies[index] = $0 }
    }
    func reply(_ index: Int, _ data: Data) { replies.removeValue(forKey: index)?.resume(returning: data) }
}

/// Production session/dispatcher/persistence using project JSON and a controlled
/// initial model reply only. No windows, microphone, model runtime or media.
@main @MainActor
struct DirectConflictChoiceChecks {
    static let instruction = "Pan from Box 1 to Box 2 over the next three seconds."
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw DirectChoiceFailure.failed(message) }
    }
    static func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw DirectChoiceFailure.failed("controlled session operation timed out")
    }
    static func requireCalls(_ fixture: Fixture, _ expected: Int, _ message: String) async throws {
        let count = await fixture.transport.payloads.count
        try require(count == expected, message)
    }
    static func tool(_ name: String, _ arguments: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [[
            "id": UUID().uuidString, "type": "function", "function": ["name": name, "arguments": String(decoding: body, as: UTF8.self)]
        ]]]]]])
    }
    @MainActor
    struct Fixture {
        let directory: URL
        let editor: ProjectEditor
        let session: EditorAssistantSession
        let transport = DirectChoiceTransport()
        let diagnostics: DirectorDiagnostics
        let archive: URL
        let sourceID = UUID(), laterID = UUID()
        let from: EditorRegion, to: EditorRegion
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-direct-choice-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 14.37)
            project.title = "Direct choice fixture"
            project.state.zoomKeyframes = [ZoomKeyframe(id: sourceID, time: 1, scale: 2, transition: .smooth, duration: 1), ZoomKeyframe(id: laterID, time: 8, scale: 1.5, transition: .jump)]
            from = EditorRegion(time: 1, rect: .init(x: 0.1, y: 0.15, width: 0.25, height: 0.3), editID: sourceID)
            to = EditorRegion(time: 1, rect: .init(x: 0.6, y: 0.45, width: 0.3, height: 0.3), editID: sourceID)
            project.state.regions = [from, to]
            project.state.pipKeyframes.append(PIPKeyframe(time: 1, placement: PIPPlacement(x: 0.1, y: 0.2, scale: 0.2), transition: .smooth, duration: 1))
            project.state.cursorStyle.size = 2.5; project.state.audio.volume = 0.7; project.ensureReferences()
            editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
            try require(editor.save(), "save metadata fixture")
            archive = directory.appendingPathComponent("conversation.json")
            diagnostics = DirectorDiagnostics(directory: directory.appendingPathComponent("diagnostics"))
            let transport = self.transport
            session = EditorAssistantSession(transport: { try await transport.send($0) }, diagnostics: diagnostics, conversationStorageURL: archive)
        }
        func close() { session.cancel(); try? FileManager.default.removeItem(at: directory) }
        func response() throws -> Data {
            try tool("move_relative", ["project_id": session.projectID.uuidString, "expected_revision": try EditorCommandDispatcher.revision(for: editor.project), "from_box_label": "Box 1", "to_box_label": "Box 2", "start_delay_seconds": 0, "arrival_seconds": 3, "arrival_origin": "playhead", "path": "direct"])
        }
        func pending() async throws -> (UUID, EditorFramingConflict) {
            let index = await transport.payloads.count
            let context = LocalEditContext(recording: try EditorCommandDispatcher.context(editor: editor, projectID: session.projectID), playhead: 0, selectedRegionID: nil, selectedEditID: nil, videoProcessingAvailable: false)
            let response = try response()
            guard case let .framingConflict(conflict) = try LocalEditPlanner.result(response, context: context, instruction: instruction) else { throw DirectChoiceFailure.failed("fixture did not construct a frozen conflict") }
            session.instruction = instruction; session.submit(editor: editor, playhead: 0, regionID: nil, editID: nil)
            try await wait { await transport.payloads.count == index + 1 }
            await transport.reply(index, response)
            try await wait { !session.isBusy }
            guard let id = session.conflictReviewID else { throw DirectChoiceFailure.failed("real pending conflict exposed no review identity") }
            try require(session.awaitsClarification && session.conflictReview != nil && !editor.canUndo && session.errorMessage == nil, "initial conflict changed project/history or failed")
            return (id, conflict)
        }
        func buttonOutcomes() -> [[String: Any]] {
            session.conversation.exchanges.flatMap(\.messages).compactMap { message in
                guard let text = message.content, let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
                let value = (object["app_event"] as? [String: Any]) ?? object
                return value["interaction"] as? String == "conflict_button" ? value : nil
            }
        }
        func log() throws -> [[String: Any]] {
            try String(contentsOf: diagnostics.logURL, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        }
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "requires suspended media")
        try await keepExisting()
        try await applyProposedAndContext()
        try await staleAndForeignGuards()
        try await draftAndBusyGuards()
        try await saveFailureAndRetry()
        print("Direct conflict choice checks passed (keep/no Undo, exact frozen replacement, durable one-step Undo/Redo, persisted/logged context, stale/foreign/draft/busy/double-click guards and failed-save retry; fake transport/project JSON only, no app/model/media).")
    }
    static func assertChoice(_ fixture: Fixture, choice: String, commands: [EditorCommand]) throws {
        guard let outcome = fixture.buttonOutcomes().last else { throw DirectChoiceFailure.failed("missing host choice outcome") }
        try require(outcome["choice"] as? String == choice && outcome["summary"] as? String == fixture.session.notice && outcome["revision"] as? String == (try EditorCommandDispatcher.revision(for: fixture.editor.project)), "choice outcome does not describe the actual result/revision")
        try require(outcome["status"] as? String == (commands.isEmpty ? "unchanged" : "applied"), "choice status claims a different application result")
        let rawCommands = outcome["commands"] ?? []
        let data = try JSONSerialization.data(withJSONObject: rawCommands)
        try require(try JSONDecoder().decode([EditorCommand].self, from: data) == commands, "button result was replanned or logged different commands")
        let steps = try JSONDecoder().decode([DirectorTranscriptStep].self, from: JSONSerialization.data(withJSONObject: outcome["edit_steps"] ?? []))
        try require(commands.isEmpty ? steps.isEmpty : !steps.isEmpty, "actual changed steps were omitted or invented")
        let events = try fixture.log()
        try require(events.contains { ($0["event"] as? String) == "conflict_choice" && ($0["details"] as? [String: Any])?["choice"] as? String == choice }, "explicit user choice was not diagnosed")
        try require(events.contains { ($0["event"] as? String) == "tool_result" && ($0["details"] as? [String: Any])?["interaction"] as? String == "conflict_button" }, "actual host result was not diagnosed")
        let restored = DirectorConversation(storageURL: fixture.archive)
        try require(restored.question == nil && restored.conflict == nil && !restored.exchanges.isEmpty, "resolved comparison was not durably cleared")
        let userChoice = choice == "keep" ? "Keep the existing framing." : "Use the proposed framing."
        try require(restored.exchanges.flatMap(\.messages).contains { $0.role == "user" && $0.content == userChoice }, "persisted context omitted the user's explicit button choice")
        let expectedHistory = try JSONSerialization.data(withJSONObject: DirectorConversation.object(fixture.editor.historyState), options: .sortedKeys)
        let actualHistory = try JSONSerialization.data(withJSONObject: outcome["history"] ?? [:], options: .sortedKeys)
        try require(expectedHistory == actualHistory, "host outcome did not preserve actual Undo/Redo context")
    }
    static func keepExisting() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let (id, _) = try await fixture.pending(); let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
        try require(fixture.session.resolveConflict(.existing, editor: fixture.editor, reviewID: id), "Existing did not resolve the displayed proposal")
        try require(fixture.editor.project == before && !fixture.editor.canUndo && (try Data(contentsOf: fixture.editor.url)) == bytes, "Existing wrote a project change or Undo entry")
        try require(!fixture.session.awaitsClarification && fixture.session.conflictReview == nil && fixture.session.conflictReviewID == nil && fixture.session.errorMessage == nil, "Existing left a pending comparison")
        try assertChoice(fixture, choice: "keep", commands: [])
        let count = fixture.session.conversation.exchanges.count
        try require(!fixture.session.resolveConflict(.existing, editor: fixture.editor, reviewID: id) && fixture.session.conversation.exchanges.count == count, "repeated Existing generated another choice/result")
        try await requireCalls(fixture, 1, "Existing requested another model turn")
    }
    static func applyProposedAndContext() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let (id, conflict) = try await fixture.pending(); let before = fixture.editor.project
        // Inspect elsewhere; choice must still resolve the original 0–3s plan.
        _ = fixture.session.conflictReview?.outlines(at: 9.6)
        try require(fixture.session.resolveConflict(.proposed, editor: fixture.editor, reviewID: id), "Proposed did not apply the displayed frozen replacement")
        let after = fixture.editor.project
        try require(after.state.zoom(at: 0) == fixture.from.rect.framing() && after.state.zoom(at: 3) == fixture.to.rect.framing() && !after.state.zoomKeyframes.contains { abs($0.time - 12.6) < 0.000001 }, "reviewing elsewhere retimed the frozen proposal")
        try require(after.state.pipKeyframes == before.state.pipKeyframes && after.state.cursorStyle == before.state.cursorStyle && after.state.audio == before.state.audio && after.state.regions == before.state.regions && after.state.presentation == before.state.presentation && after.title == before.title && after.state.trimStart == before.state.trimStart && after.state.trimEnd == before.state.trimEnd, "button replacement changed unrelated recording state")
        try require(after.state.zoomKeyframes.first { $0.id == fixture.laterID } == before.state.zoomKeyframes.first { $0.id == fixture.laterID } && after.undoHistory.count == 1 && (try ProjectEditor.open(url: fixture.editor.url).project) == after, "replacement lost outside framing or failed one-step durable history")
        try assertChoice(fixture, choice: "replace", commands: conflict.replacement.commands)
        let messages = fixture.session.conversation.exchanges.count
        try require(!fixture.session.resolveConflict(.proposed, editor: fixture.editor, reviewID: id) && fixture.session.conversation.exchanges.count == messages && fixture.editor.project == after, "double click applied or logged a second replacement")
        try await requireCalls(fixture, 1, "direct replacement invoked transport")
        try require(fixture.editor.undo() && fixture.editor.project.state == before.state && (try ProjectEditor.open(url: fixture.editor.url).project.state) == before.state && fixture.editor.redo() && fixture.editor.project == after && (try ProjectEditor.open(url: fixture.editor.url).project) == after, "button result is not one durable ordinary Undo/Redo")
        fixture.session.instruction = "What is the current framing?"
        fixture.session.submit(editor: fixture.editor, playhead: 9.6, regionID: nil, editID: nil)
        try await wait { await fixture.transport.payloads.count == 2 }
        let payload = await fixture.transport.payloads[1]
        let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let messagesText = String(decoding: try JSONSerialization.data(withJSONObject: object["messages"]!), as: UTF8.self)
        try require(messagesText.contains("Use the proposed framing.") && messagesText.contains("conflict_button") && messagesText.contains("edit_steps") && messagesText.contains("commands"), "the next LLM request lost the explicit choice or actual result")
        await fixture.transport.reply(1, try tool("ask_clarification", ["question": "What would you like to change?"]))
        try await wait { !fixture.session.isBusy }
    }
    static func staleAndForeignGuards() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let (oldID, _) = try await fixture.pending()
        try require(fixture.session.resolveConflict(.existing, editor: fixture.editor, reviewID: oldID), "finish first proposal")
        let (currentID, _) = try await fixture.pending(); let baseline = fixture.editor.project
        try require(currentID != oldID && !fixture.session.resolveConflict(.proposed, editor: fixture.editor, reviewID: oldID) && fixture.session.conflictReviewID == currentID && fixture.editor.project == baseline, "a delayed old button resolved or dismissed a newer proposal")
        let foreign = ProjectEditor(project: baseline, url: fixture.directory.appendingPathComponent("foreign.framethrower"))
        try require(foreign.save() && !fixture.session.resolveConflict(.proposed, editor: foreign, reviewID: currentID) && foreign.project == baseline && fixture.session.conflictReviewID == currentID, "matching bytes in a different editor bypassed project ownership")
        try require(fixture.editor.rename(to: "Changed manually"), "manual revision fixture")
        let changed = fixture.editor.project
        try require(fixture.session.conflictReviewID == nil && !fixture.session.resolveConflict(.proposed, editor: fixture.editor, reviewID: currentID) && fixture.editor.project == changed, "stale project choice mutated the new revision")
        try await requireCalls(fixture, 2, "stale/foreign clicks invoked transport")
    }
    static func draftAndBusyGuards() async throws {
        do {
            let fixture = try Fixture(); defer { fixture.close() }
            let (id, _) = try await fixture.pending(); let before = fixture.editor.project
            var draft = before.state; draft.cursorStyle.size = 3
            try require(fixture.editor.updateDraft(draft, at: 2), "draft fixture")
            try require(!fixture.session.resolveConflict(.proposed, editor: fixture.editor, reviewID: id) && fixture.editor.project == before && fixture.editor.draftState == draft && !fixture.editor.canRedo && fixture.editor.project.undoHistory.isEmpty, "choice committed/discarded a pending manual draft")
            try require(fixture.session.conflictReview == nil && fixture.session.errorMessage == EditorCommandError.pendingDraft.localizedDescription, "draft rejection left a usable obsolete comparison or hid the reason")
            try await requireCalls(fixture, 1, "draft choice invoked transport")
        }
        do {
            let fixture = try Fixture(); defer { fixture.close() }
            let (id, conflict) = try await fixture.pending(); let before = fixture.editor.project
            fixture.session.instruction = "Keep the existing movement."
            fixture.session.submit(editor: fixture.editor, playhead: 9.6, regionID: nil, editID: nil)
            try await wait { await fixture.transport.payloads.count == 2 }
            let count = fixture.session.conversation.exchanges.count
            try require(fixture.session.isBusy && !fixture.session.resolveConflict(.proposed, editor: fixture.editor, reviewID: id) && fixture.editor.project == before && fixture.session.conversation.exchanges.count == count, "button raced an in-flight answer")
            await fixture.transport.reply(1, try tool("resolve_framing_conflict", ["project_id": conflict.proposal.projectID.uuidString, "expected_revision": conflict.proposal.revision, "choice": "keep"]))
            try await wait { !fixture.session.isBusy }
            try await requireCalls(fixture, 2, "busy choice invoked another transport")
            try require(fixture.editor.project == before, "busy choice applied a change")
        }
    }
    static func saveFailureAndRetry() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let (id, _) = try await fixture.pending(); let before = fixture.editor.project; let saved = try Data(contentsOf: fixture.editor.url)
        var outside = before; outside.state.trimStart = 2
        let bytes = try JSONEncoder().encode(outside); try bytes.write(to: fixture.editor.url, options: .atomic)
        try require(!fixture.session.resolveConflict(.proposed, editor: fixture.editor, reviewID: id) && fixture.editor.project == before && (try Data(contentsOf: fixture.editor.url)) == bytes && fixture.session.errorMessage != nil, "failed write consumed history or overwrote the external project")
        try require(fixture.session.conflictReviewID == id && fixture.session.awaitsClarification && !fixture.editor.canUndo, "failed save discarded the retryable frozen proposal")
        try saved.write(to: fixture.editor.url, options: .atomic)
        try require(fixture.session.resolveConflict(.proposed, editor: fixture.editor, reviewID: id) && fixture.editor.project.undoHistory.count == 1 && fixture.session.conflictReview == nil, "restoring the saved baseline could not retry the exact proposal")
        try await requireCalls(fixture, 1, "failed-save retry invoked transport")
    }
}
