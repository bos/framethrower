import Foundation

private enum ConversationCheckFailure: Error { case failed(String) }

private actor ConversationTransport {
    private(set) var payloads: [Data] = []
    private var replies: [Int: CheckedContinuation<Data, any Error>] = [:]
    func send(_ payload: Data) async throws -> Data {
        let index = payloads.count
        payloads.append(payload)
        return try await withCheckedThrowingContinuation { replies[index] = $0 }
    }
    func reply(_ index: Int, _ data: Data) { replies.removeValue(forKey: index)?.resume(returning: data) }
}

/// Production conversation/session/editor state, with explicit fake model
/// replies. No microphone, model process, app window, source movie or media IO.
@main @MainActor
struct DirectorConversationChecks {
    static func main() async throws {
        guard MediaProcessing.isSuspended else { throw ConversationCheckFailure.failed("Requires media interlock") }
        try checkConversationProtocolAndChronology()
        try await checkManualEventsAndCurrentState()
        try await checkManualChangeDuringInference()
        try await checkQuestionPersistence()
        try await checkConflictPersistenceAndStaleInvalidation()
        try checkDraftUndoRedoAndNewBranch()
        try await checkCompactProjectSnapshot()
        try await checkLiveUIAlongsideInstructionAnchor()
        print("Director conversation checks passed (ordered user/tool/result turns, real manual changes and Undo/Redo, authoritative current state, interleaved failures, bounded complete tool groups, persisted questions/conflicts and fresh-session scope; no model, mic, app, or media).")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ConversationCheckFailure.failed(message) }
    }
    static func wait(function: String = #function, line: Int = #line,
                     _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw ConversationCheckFailure.failed("Timed out waiting for fake model exchange at \(function):\(line)")
    }
    static func tool(_ name: String, _ args: [String: Any], id: String = "fixture_call") throws -> Data {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args, options: .sortedKeys), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "tool_calls": [[
            "id": id, "type": "function", "function": ["name": name, "arguments": arguments]
        ]]]]]])
    }
    static func payloadMessages(_ payload: Data) throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        return root["messages"] as! [[String: Any]]
    }
    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
    static func events(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.compactMap { ($0["content"] as? String).flatMap(object)?["app_event"] as? [String: Any] }
    }
    static func outcomes(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.filter { $0["role"] as? String == "tool" }.compactMap { ($0["content"] as? String).flatMap(object) }
    }
    static func checkToolPairs(_ messages: [[String: Any]]) throws {
        var ids = Set<String>()
        for (index, message) in messages.enumerated() {
            if let calls = message["tool_calls"] as? [[String: Any]] {
                try require(message["role"] as? String == "assistant" && calls.count == 1, "Actual tool calls use assistant role")
                let id = calls[0]["id"] as! String
                try require(ids.insert(id).inserted, "Repeated server IDs are normalized without breaking correlation")
                try require(index + 1 < messages.count && messages[index + 1]["role"] as? String == "tool" &&
                            messages[index + 1]["tool_call_id"] as? String == id, "Every call stays paired with its actual tool result")
            }
            if message["role"] as? String == "tool" {
                try require(index > 0 && (messages[index - 1]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == message["tool_call_id"] as? String,
                            "Compaction must never leave an orphan tool result")
            }
        }
    }

    static func checkConversationProtocolAndChronology() throws {
        let conversation = DirectorConversation()
        let first = UUID()
        conversation.begin("Pan from Box 1 to Box 2", requestID: first)
        conversation.event(["kind": "edit", "actor": "user", "names": ["Move camera"], "changes": ["camera": "moved"]])
        let response = try tool("move_relative", ["start_delay_seconds": 0], id: "same_server_id")
        conversation.finish(requestID: first, response: response, outcome: ["status": "rejected", "error": "Project revision changed."])
        var messages = conversation.messages()
        try require(messages.count == 4 && messages[0]["content"] as? String == "Pan from Box 1 to Box 2" &&
                    events([messages[1]]).first?["kind"] as? String == "edit" &&
                    outcomes([messages[3]]).first?["status"] as? String == "rejected",
                    "A manual edit remains chronologically between the request and the later rejected tool response")
        try checkToolPairs(messages)
        let second = UUID()
        conversation.begin("Which box did you mean?", requestID: second)
        conversation.finish(requestID: second, response: try tool("ask_clarification", ["question": "Box 1 or Box 2?"], id: "same_server_id"),
                            outcome: ["status": "needs_answer", "question": "Box 1 or Box 2?", "applied": false])
        let third = UUID()
        conversation.begin("Box 2", requestID: third)
        conversation.finish(requestID: third, response: try tool("label_region", ["label": "Results"], id: "same_server_id"),
                            outcome: ["status": "applied", "summary": "Named Box 2 Results.", "created_edits": [["id": "real_created_id", "label": "Edit C"]]])
        messages = conversation.messages()
        try checkToolPairs(messages)
        try require(outcomes(messages).compactMap { $0["status"] as? String } == ["rejected", "needs_answer", "applied"],
                    "Conversation preserves actual failure, question, and applied outcomes")
        let compact = conversation.messages(byteBudget: 600)
        try checkToolPairs(compact)
        try require(events(compact).contains { $0["kind"] as? String == "earlier_activity" }, "Older activity remains summarized when full exchanges exceed the window")
    }

    @MainActor private struct Fixture {
        let directory: URL
        let editor: ProjectEditor
        let box1: EditorRegion
        let box2: EditorRegion
        var storage: URL { directory.appendingPathComponent("conversation.json") }
        var logger: DirectorDiagnostics { DirectorDiagnostics(directory: directory.appendingPathComponent("logs")) }
        init(conflict: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-conversation-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 14.37)
            let mark = UUID()
            if conflict { project.state.zoomKeyframes = [ZoomKeyframe(id: mark, time: 1, scale: 2)] }
            box1 = EditorRegion(time: 1, rect: .init(x: 0.1, y: 0.15, width: 0.2, height: 0.25), editID: conflict ? mark : nil)
            box2 = EditorRegion(time: 1, rect: .init(x: 0.6, y: 0.4, width: 0.3, height: 0.25), editID: conflict ? mark : nil)
            project.state.regions = [box1, box2]
            project.ensureReferences()
            editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
            guard editor.save() else { throw ConversationCheckFailure.failed("Save metadata fixture") }
        }
        func close() { try? FileManager.default.removeItem(at: directory) }
        func session(_ transport: ConversationTransport) -> EditorAssistantSession {
            EditorAssistantSession(transport: { try await transport.send($0) }, diagnostics: logger, conversationStorageURL: storage)
        }
        func scope(_ session: EditorAssistantSession) throws -> [String: Any] {
            try ["project_id": session.projectID.uuidString, "expected_revision": EditorCommandDispatcher.revision(for: editor.project)]
        }
        func movement(_ session: EditorAssistantSession, delay: Double = 0, seconds: Double = 3) throws -> Data {
            try tool("move_relative", scope(session).merging(["from_box_label": "Box 1", "to_box_label": "Box 2",
                "start_delay_seconds": delay, "arrival_seconds": seconds, "arrival_origin": "movement_start", "path": "direct"]) { _, b in b })
        }
    }

    static func checkManualEventsAndCurrentState() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let transport = ConversationTransport(), session = fixture.session(transport)
        session.instruction = "Name Box 1 Search results."
        session.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 1 }
        await transport.reply(0, try tool("label_region", fixture.scope(session).merging(["region_id": fixture.box1.id.uuidString, "label": "Search results"]) { _, b in b }))
        try await wait { !session.isBusy }
        try require(session.errorMessage == nil && fixture.editor.project.state.regions[0].note == "Search results", "First model action actually applies")
        var state = fixture.editor.project.state
        state.pipKeyframes[0].placement = PIPPlacement(x: 0.1, y: 0.2, scale: 0.3)
        try require(fixture.editor.commit(state, name: "Move camera"), "Manual camera edit")
        state = fixture.editor.project.state; state.cursorStyle.size = 3
        try require(fixture.editor.commit(state, name: "Resize pointer"), "Manual pointer edit")
        state = fixture.editor.project.state; state.trimStart = 0.5; state.trimEnd = 13
        try require(fixture.editor.commit(state, name: "Trim"), "Manual trim edit")
        try require(fixture.editor.rename(to: "Manual title"), "Manual recording rename")
        try require(fixture.editor.undo() && fixture.editor.redo(), "Manual Undo/Redo")
        let expected = fixture.editor.project
        session.instruction = "What should change next?"
        session.submit(editor: fixture.editor, playhead: 4, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 2 }
        let payload = await transport.payloads[1]
        let messages = try payloadMessages(payload)
        try checkToolPairs(messages)
        let applicationEvents = events(messages).filter { $0["kind"] as? String != "earlier_activity" }
        try require(applicationEvents.count == 6 && applicationEvents.compactMap { $0["kind"] as? String } == ["edit", "edit", "edit", "edit", "undo", "redo"],
                    "The next model request receives every actual manual edit and Undo/Redo in order")
        let changedKeys = Set(applicationEvents.flatMap { event in
            Array((event["changes"] as? [String: Any] ?? [:]).keys)
        })
        try require(changedKeys.isSuperset(of: ["pipKeyframes", "cursorStyle", "trimStart", "trimEnd", "title"]),
                    "Events include real changed camera/pointer/trim/title values")
        try require(outcomes(messages).first?["status"] as? String == "applied" &&
                    (outcomes(messages).first?["commands"] as? [[String: Any]])?.first?["action"] as? String == "labelRegion",
                    "Model sees the applied result of its earlier call, not only its own proposal")
        let prefix = "Current editor context (authoritative for this request):\n"
        guard let contextText = messages.compactMap({ $0["content"] as? String }).first(where: { $0.hasPrefix(prefix) }),
              let context = object(String(contextText.dropFirst(prefix.count))),
              let currentState = context["current_state"] as? [String: Any],
              let recording = context["recording"] as? [String: Any] else { throw ConversationCheckFailure.failed("Current authoritative context missing") }
        let decoded = try JSONDecoder().decode(EditState.self, from: JSONSerialization.data(withJSONObject: currentState))
        try require(decoded == expected.state && recording["revision"] as? String == (try EditorCommandDispatcher.revision(for: expected)),
                    "Complete present state and revision override stale historical proposals")
        await transport.reply(1, try tool("ask_clarification", ["question": "Which setting would you like to change?"]))
        try await wait { !session.isBusy }
        session.suspend()
        let trace = try String(contentsOf: fixture.logger.logURL, encoding: .utf8)
        try require(trace.contains("model_request") && trace.contains("model_response") && trace.contains("tool_result") && trace.contains("editor_changed"),
                    "Local trace connects user requests, model calls/results, and manual changes")
    }

    static func checkManualChangeDuringInference() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let transport = ConversationTransport(), session = fixture.session(transport)
        session.instruction = "Name Box 1 Results."
        session.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 1 }
        let oldScope = try fixture.scope(session)
        try require(fixture.editor.rename(to: "While inference was running"), "Manual edit during inference")
        await transport.reply(0, try tool("label_region", oldScope.merging(["region_id": fixture.box1.id.uuidString, "label": "Results"]) { _, b in b }))
        try await wait { !session.isBusy }
        try require(session.errorMessage == EditorCommandError.stale.localizedDescription && fixture.editor.project.state.regions[0].note.isEmpty,
                    "Stale proposals cannot overwrite newer manual work")
        let messages = session.conversation.messages()
        try checkToolPairs(messages)
        guard let eventIndex = messages.firstIndex(where: { events([$0]).first?["kind"] as? String == "edit" }),
              let resultIndex = messages.firstIndex(where: { $0["role"] as? String == "tool" }) else { throw ConversationCheckFailure.failed("Interleaved event or result missing") }
        try require(eventIndex < resultIndex && outcomes(messages).last?["status"] as? String == "rejected", "Manual event precedes the actual later failure")
        session.suspend()
    }

    static func checkQuestionPersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let firstTransport = ConversationTransport()
        var first: EditorAssistantSession? = fixture.session(firstTransport)
        let oldID = first!.projectID
        first!.instruction = "One second from now, pan from Box 1 to Box 2."
        first!.submit(editor: fixture.editor, playhead: 2, regionID: nil, editID: nil)
        try await wait { await firstTransport.payloads.count == 1 }
        await firstTransport.reply(0, try tool("ask_clarification", ["question": "How long should that movement take?"]))
        try await wait { !first!.isBusy }
        first!.instruction = "Unfinished answer"
        first!.suspend(); first = nil
        let rawArchive = try Data(contentsOf: fixture.storage)
        let archiveObject = try JSONSerialization.jsonObject(with: rawArchive) as! [String: Any]
        if let snapshot = archiveObject["lastProject"] {
            do { _ = try JSONDecoder().decode(DirectorProjectSnapshot.self, from: JSONSerialization.data(withJSONObject: snapshot)) }
            catch { throw ConversationCheckFailure.failed("Snapshot archive cannot decode: \(error)") }
        }
        let secondTransport = ConversationTransport(), second = fixture.session(secondTransport)
        second.attach(to: fixture.editor)
        try require(second.projectID != oldID && second.awaitsClarification && second.notice == "How long should that movement take?" &&
                    second.instruction == "Unfinished answer" && second.conversation.question?.context.recording.projectID == second.projectID,
                    "Reopening restores question/draft/history under a fresh session scope (pending=\(second.awaitsClarification), notice=\(second.notice ?? "nil"), draft=\(second.instruction), storedScope=\(second.conversation.question?.context.recording.projectID.uuidString ?? "nil"), liveScope=\(second.projectID))")
        second.instruction = "Three seconds."
        second.submit(editor: fixture.editor, playhead: 9.6, regionID: nil, editID: nil)
        try await wait { await secondTransport.payloads.count == 1 }
        let messages = try payloadMessages(await secondTransport.payloads[0])
        try checkToolPairs(messages)
        try require(messages.contains { $0["content"] as? String == "One second from now, pan from Box 1 to Box 2." } && outcomes(messages).contains { $0["question"] as? String == "How long should that movement take?" },
                    "The model receives the earlier user request and actual question as separate conversation turns")
        await secondTransport.reply(0, try fixture.movement(second, delay: 1))
        try await wait { !second.isBusy }
        try require(second.errorMessage == nil && !second.awaitsClarification && fixture.editor.project.state.zoom(at: 3) == fixture.box1.rect.framing() &&
                    fixture.editor.project.state.zoom(at: 6) == fixture.box2.rect.framing(), "Answer uses the retained playhead instead of the newly displayed one")
        let reopened = DirectorConversation(storageURL: fixture.storage)
        try require(reopened.draftInstruction.isEmpty && reopened.question == nil && reopened.conflict == nil,
                    "A completed request cannot reopen as an unfinished instruction or question")
        second.suspend()
    }

    static func checkConflictPersistenceAndStaleInvalidation() async throws {
        for stale in [false, true] {
            let fixture = try Fixture(conflict: true)
            defer { fixture.close() }
            let transport = ConversationTransport()
            var first: EditorAssistantSession? = fixture.session(transport)
            let oldID = first!.projectID
            first!.instruction = "Pan from Box 1 to Box 2 over the next three seconds."
            first!.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
            try await wait { await transport.payloads.count == 1 }
            await transport.reply(0, try fixture.movement(first!))
            try await wait { !first!.isBusy }
            try require(first!.awaitsClarification, "Conflicting proposal becomes a pending question")
            first!.suspend(); first = nil
            if stale { try require(fixture.editor.rename(to: "Changed while closed"), "Change project before reopening") }
            let nextTransport = ConversationTransport(), next = fixture.session(nextTransport)
            next.attach(to: fixture.editor)
            if stale {
                try require(!next.awaitsClarification && next.conversation.conflict == nil &&
                            events(next.conversation.messages()).contains { $0["kind"] as? String == "recording_changed_outside_session" && $0["state"] as? [String: Any] != nil },
                            "Changed projects invalidate pending conflict and record intervening real changes")
            } else {
                try require(next.projectID != oldID && next.awaitsClarification &&
                            next.conversation.conflict?.proposal.proposal.projectID == next.projectID &&
                            next.conversation.conflict?.context.recording.projectID == next.projectID,
                            "Restored conflict proposal and context use the new session's scope")
                next.instruction = "Let's have the new movement replace it."
                next.submit(editor: fixture.editor, playhead: 9.6, regionID: nil, editID: nil)
                try await wait { await nextTransport.payloads.count == 1 }
                await nextTransport.reply(0, try tool("resolve_framing_conflict", fixture.scope(next).merging(["choice": "replace"]) { _, b in b }))
                try await wait { !next.isBusy }
                try require(next.errorMessage == nil && !next.awaitsClarification && fixture.editor.project.undoHistory.count == 1 &&
                            fixture.editor.project.state.zoom(at: 0) == fixture.box1.rect.framing() && fixture.editor.project.state.zoom(at: 3) == fixture.box2.rect.framing(),
                            "A restored replacement applies the original proposal once, without reinterpreting timing")
            }
            next.suspend()
        }
    }

    static func checkDraftUndoRedoAndNewBranch() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let session = fixture.session(ConversationTransport())
        session.attach(to: fixture.editor)
        var draft = fixture.editor.project.state
        draft.cursorStyle.size = 2
        try require(fixture.editor.updateDraft(draft, at: 1), "Create unfinished manual pointer adjustment")
        try require(fixture.editor.undo(), "Undo unfinished adjustment")
        try require(fixture.editor.redo() && fixture.editor.project.state.cursorStyle.size == 2, "Redo unfinished adjustment as a saved change")
        try require(fixture.editor.undo(), "Undo again before a new branch")
        var branch = fixture.editor.project.state
        branch.cursorStyle.size = 3
        try require(fixture.editor.commit(branch, name: "New pointer size"), "Make a different manual change after Undo")
        let changes = events(session.conversation.messages())
        try require(changes.compactMap { $0["kind"] as? String } == ["undo", "redo", "undo", "edit"],
                    "Actual operation identity distinguishes draft Undo/Redo and a new branch from history-count guesses")
        try require(changes.compactMap { ($0["names"] as? [String])?.first } == ["Edit", "Edit", "Edit", "New pointer size"] &&
                    fixture.editor.project.redoHistory.isEmpty && fixture.editor.project.state.cursorStyle.size == 3,
                    "Conversation records named stack actions and the real surviving branch")
        try require(fixture.editor.publishingHistoryOperation == nil, "Publication-only operation metadata is cleared after notification")
        session.suspend()
    }

    static func checkCompactProjectSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var project = fixture.editor.project
        var oldState = project.state
        for index in 0..<16 {
            oldState.regions.append(EditorRegion(time: Double(index % 10),
                rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), note: String(repeating: "h", count: 4096)))
        }
        project.undoHistory = (0..<40).map { NamedEditSnapshot(name: "Manual step \($0)", state: oldState) }
        project.ensureReferences()
        try require(try JSONEncoder().encode(project).count > 2_000_000, "Fixture has a real multi-megabyte Undo stack and small current state")
        let editor = ProjectEditor(project: project, url: fixture.directory.appendingPathComponent("large-history.framethrower"))
        try require(editor.save(), "Save metadata-only large-history fixture")
        let transport = ConversationTransport()
        var session: EditorAssistantSession? = fixture.session(transport)
        session!.instruction = "One second from now, pan from Box 1 to Box 2."
        session!.submit(editor: editor, playhead: 2, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 1 }
        await transport.reply(0, try tool("ask_clarification", ["question": "How long should the movement take?"]))
        try await wait { !session!.isBusy }
        session!.instruction = "Pending answer draft"
        session!.suspend(); session = nil
        let archive = try Data(contentsOf: fixture.storage)
        let restored = DirectorConversation(storageURL: fixture.storage)
        try require(archive.count < 2_000_000 && restored.draftInstruction == "Pending answer draft" &&
                    restored.question?.question == "How long should the movement take?",
                    "Large Undo stacks cannot make the conversation archive unreadable or drop the latest question/draft")
        try require(restored.lastProject?.state == editor.project.state && restored.lastProject?.undoNames == Array(project.undoHistory.suffix(32).map(\.name)) &&
                    restored.lastProject?.redoNames.isEmpty == true,
                    "Conversation persistence stores the current state and bounded history names, not full Undo snapshots")
        try require(restored.messages().contains { $0["content"] as? String == "One second from now, pan from Box 1 to Box 2." } &&
                    outcomes(restored.messages()).last?["status"] as? String == "needs_answer", "Latest ordered dialogue survives compact snapshot persistence")
    }

    static func checkLiveUIAlongsideInstructionAnchor() async throws {
        for useCurrentPlayhead in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            var state = fixture.editor.project.state
            let mark = EditAnchor(time: 8)
            state.editAnchors.append(mark)
            try require(fixture.editor.commit(state, name: "Add reference mark"), "Create a real current UI edit selection")
            let transport = ConversationTransport(), session = fixture.session(transport)
            session.instruction = "One second from now, pan from Box 1 to Box 2."
            session.submit(editor: fixture.editor, playhead: 2, regionID: fixture.box1.id, editID: nil)
            try await wait { await transport.payloads.count == 1 }
            await transport.reply(0, try tool("ask_clarification", ["question": "How long should the movement take?"]))
            try await wait { !session.isBusy }
            session.instruction = useCurrentPlayhead ? "Start at the current playhead instead and take three seconds." : "Three seconds."
            session.submit(editor: fixture.editor, playhead: 8, regionID: fixture.box2.id, editID: mark.id)
            try await wait { await transport.payloads.count == 2 }
            let messages = try payloadMessages(await transport.payloads[1])
            let prefix = "Current editor context (authoritative for this request):\n"
            guard let text = messages.compactMap({ $0["content"] as? String }).first(where: { $0.hasPrefix(prefix) }),
                  let context = object(String(text.dropFirst(prefix.count))),
                  let anchor = context["instruction_anchor"] as? [String: Any],
                  let live = context["live_ui"] as? [String: Any] else { throw ConversationCheckFailure.failed("Live/anchored UI context missing") }
            try require((anchor["playhead"] as? NSNumber)?.doubleValue == 2 && anchor["selectedRegionID"] as? String == fixture.box1.id.uuidString &&
                        (live["playhead"] as? NSNumber)?.doubleValue == 8 && live["selectedRegionID"] as? String == fixture.box2.id.uuidString &&
                        live["selectedEditID"] as? String == mark.id.uuidString,
                        "Followup sends fresh UI selection/time separately from the original instruction anchor")
            let args = try fixture.scope(session).merging(["from_box_label": "Box 1", "to_box_label": "Box 2",
                "start_delay_seconds": useCurrentPlayhead ? 0 : 1, "arrival_seconds": 3,
                "arrival_origin": "movement_start", "path": "direct",
                "time_origin": useCurrentPlayhead ? "current_playhead" : "instruction"]) { _, b in b }
            await transport.reply(1, try tool("move_relative", args))
            try await wait { !session.isBusy }
            let start = useCurrentPlayhead ? 8.0 : 3.0
            try require(session.errorMessage == nil && fixture.editor.project.state.zoom(at: start) == fixture.box1.rect.framing() &&
                        fixture.editor.project.state.zoom(at: start + 3) == fixture.box2.rect.framing(),
                        "Original timing stays frozen unless the latest answer explicitly selects the live playhead")
            session.suspend()
        }
    }
}
