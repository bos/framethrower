import Combine
import Foundation

private enum AssistantCheckError: Error { case failed(String) }
private enum FixtureTransportError: LocalizedError {
    case failed
    var errorDescription: String? { "Fixture transport failed." }
}

/// Deliberately ignores cancellation until the test releases a reply. This
/// exercises generation boundaries even with an uncooperative transport.
private actor AssistantTransport {
    private(set) var payloads: [Data] = []
    private var continuations: [Int: CheckedContinuation<Data, any Error>] = [:]

    func send(_ payload: Data) async throws -> Data {
        let index = payloads.count
        payloads.append(payload)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func succeed(_ index: Int, data: Data) { continuations.removeValue(forKey: index)?.resume(returning: data) }
    func fail(_ index: Int) { continuations.removeValue(forKey: index)?.resume(throwing: FixtureTransportError.failed) }
}

@MainActor
private final class AssistantAutomationEndpoint: EditorAutomationEndpoint {
    let documentID = UUID().uuidString
    let editor: ProjectEditor
    var preview = EditorPreviewSnapshot(time: 0, frameTime: 0, isPlaying: false, rate: 1,
        canPlay: true, kind: .testPattern)
    var calls: [String] = []
    var oversizedRead = false
    var rejectNext = false
    private let events = PassthroughSubject<EditorAutomationEvent, Never>()
    init(editor: ProjectEditor) { self.editor = editor }
    var automationContext: EditorAutomationContext {
        get throws {
            .init(documentID: documentID, name: editor.displayName,
                revision: try EditorCommandDispatcher.revision(for: editor.project),
                hasDraft: editor.draftState != nil, preview: preview, inspector: "Zoom")
        }
    }
    var automationEvents: AnyPublisher<EditorAutomationEvent, Never> { events.eraseToAnyPublisher() }
    func performAutomation(_ name: String, arguments: Data) async throws -> Data {
        let args = try JSONSerialization.jsonObject(with: arguments) as! [String: Any]
        guard args["document_id"] as? String == documentID else { throw EditorAutomationError.wrongDocument }
        calls.append(name)
        if rejectNext {
            rejectNext = false
            return try JSONSerialization.data(withJSONObject: ["ok": false, "error": [
                "code": "animation_conflict", "message": "The screen movement overlaps an existing movement.", "conflicts": []] as [String: Any]])
        }
        let value: Any
        switch name {
        case "inspect_editor", "describe_editor_actions", "inspect_recording":
            if oversizedRead { value = ["oversized": String(repeating: "Z", count: 40_000)] }
            else { value = ["context": try EditorAutomationAPI.object(automationContext), "actions": ["play", "pause", "seek", "set_rate"]] as [String: Any] }
        case "control_preview":
            switch args["operation"] as? String {
            case "play": preview.isPlaying = true
            case "pause": preview.isPlaying = false
            case "seek":
                preview.time = try EditorAutomationAPI.number(args["time"])
                preview.frameTime = preview.time; preview.isPlaying = false
            case "set_rate": preview.rate = try EditorAutomationAPI.number(args["rate"])
            default: throw EditorAutomationError.invalid("Unknown fixture operation")
            }
            events.send(.init(actor: "automation", kind: "preview_changed", context: try automationContext))
            value = try EditorAutomationAPI.object(preview)
        default: throw EditorAutomationError.invalid("Unexpected fixture action")
        }
        return try JSONSerialization.data(withJSONObject: ["ok": true, "result": value])
    }
    func manualSeek(_ time: Double, kind: String = "preview_seek") throws {
        preview.time = time; preview.frameTime = time
        events.send(.init(actor: "manual", kind: kind, context: try automationContext))
    }
}

@main
@MainActor
struct EditorAssistantSessionChecks {
    static func main() async throws {
        try checkDictationPreservesDraft()
        try await checkMalformedTimingPreservesDraft()
        try await checkAtomicSubmissionAndBusy()
        try await checkFailurePreservesInstruction()
        try await checkStaleProjectRejection()
        try await checkCancelledLateReply()
        try await checkClarificationFollowup()
        try await checkDismissedClarificationStartsFresh()
        try await checkImmediateHistoryPreservesRedo()
        try await checkEditorAutomationControls()
        try await checkEditorAutomationReadAndReport()
        try await checkAutomationDraftReplan()
        try await checkAutomationManualEventsAndFailure()
        print("Editor assistant session checks passed (dictation/drafts, atomic Undo, busy/stale/cancel boundaries, clarification, actual editor controls/read/report, bounded draft replan, and manual navigation context).")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AssistantCheckError.failed(message) }
    }
    private static func waitUntil(function: String = #function, line: Int = #line,
                                  _ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AssistantCheckError.failed("asynchronous assistant operation timed out at \(function):\(line)")
    }

    private static func checkDictationPreservesDraft() throws {
        let session = EditorAssistantSession(transport: { _ in throw FixtureTransportError.failed })
        session.appendDictation("  Zoom into Box 1.\n")
        try require(session.instruction == "Zoom into Box 1.",
                    "dictation fills an empty draft and trims transcript edges")

        session.appendDictation("Then pan to Box 2.")
        try require(session.instruction == "Zoom into Box 1. Then pan to Box 2.",
                    "dictation appends to typed or previously dictated instructions")

        session.instruction = "At Edit A, "
        session.appendDictation("zoom into Box 1.")
        try require(session.instruction == "At Edit A, zoom into Box 1.",
                    "dictation respects an existing separating space")

        session.instruction = "At Edit A:\n"
        session.appendDictation("zoom into Box 1.")
        try require(session.instruction == "At Edit A:\nzoom into Box 1.",
                    "dictation preserves a deliberately typed line break")

        session.instruction = "First zoom into Box 1."
        // Simulate typing while recognition is underway, before completion.
        session.instruction += " Hold for five seconds."
        session.appendDictation(" Then zoom out. ")
        try require(session.instruction == "First zoom into Box 1. Hold for five seconds. Then zoom out.",
                    "completion appends to the latest draft rather than a listening-start snapshot")

        let existing = session.instruction
        session.appendDictation("")
        session.appendDictation(" \n\t ")
        try require(session.instruction == existing,
                    "empty recognition cannot clear or alter the current instruction")

        session.instruction = " \n\t "
        session.appendDictation(" Zoom out. ")
        try require(session.instruction == "Zoom out.",
                    "a whitespace-only draft is treated as empty")
    }

    private static func checkMalformedTimingPreservesDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var draft = fixture.editor.project.state
        draft.cursorStyle.size = 2
        try require(fixture.editor.updateDraft(draft, at: 0), "begin manual draft before dictation correction")
        let saved = fixture.editor.project
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        let instruction = "12nd from now, pan from Box one into Box 2 after 3 seconds."
        session.instruction = instruction
        session.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
        let requests = await transport.payloads.count
        try require(requests == 0 && !session.isBusy && session.instruction == instruction,
                    "unreadable timing retains editable transcript and never invokes a planner")
        try require(fixture.editor.project == saved && fixture.editor.draftState == draft,
                    "bad speech timing cannot commit or erase the current draft")
        try require(session.errorMessage?.contains("12nd from now") == true,
                    "error identifies the unreadable interval rather than blaming clip length")
    }

    private static func checkAtomicSubmissionAndBusy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        let baseline = fixture.editor.project.state
        let revision = try EditorCommandDispatcher.revision(for: fixture.editor.project)
        session.instruction = "At one second, zoom into this area and hold for a second."
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try require(session.isBusy, "submission immediately owns its busy state")
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 1 }
        try require(fixture.editor.project.state == baseline && !fixture.editor.canUndo,
                    "waiting for a plan cannot change the project")
        let response = try sequence(session: session, revision: revision, region: fixture.region.id)
        await transport.succeed(0, data: response)
        try await waitUntil { !session.isBusy }
        let requestCount = await transport.payloads.count
        try require(requestCount == 1, "repeat submission cannot start a second request")
        try require(session.errorMessage == nil && session.instruction.isEmpty && session.notice != nil,
                    "successful submission reports completion and clears the submitted instruction")
        try require(fixture.editor.project.undoHistory.count == 1 && fixture.editor.project.state.zoomKeyframes.count == 3,
                    "a multi-anchor sequence has one normal history entry")
        let finished = fixture.editor.project.state
        try require(fixture.editor.undo() && fixture.editor.project.state == baseline,
                    "one Undo restores the complete previous state")
        try require(fixture.editor.redo() && fixture.editor.project.state == finished,
                    "one Redo restores the complete planned sequence")
    }

    private static func checkFailurePreservesInstruction() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        let instruction = "Zoom into this area."
        session.instruction = instruction
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 1 }
        await transport.fail(0)
        try await waitUntil { !session.isBusy }
        try require(session.instruction == instruction && session.errorMessage == "Fixture transport failed." && session.notice == nil,
                    "transport failure retains the user's request for correction or retry")
        try require(!fixture.editor.canUndo, "transport failure cannot add history")
    }

    private static func checkDismissedClarificationStartsFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        session.instruction = "Undo your last change."
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 1 }
        let question = try tool("ask_clarification", ["question": "Which change should be undone?"])
        await transport.succeed(0, data: question)
        try await waitUntil { !session.isBusy }
        try require(session.awaitsClarification, "question stays visible while awaiting an answer")
        session.cancel()
        try require(!session.awaitsClarification && session.notice == nil, "dismissing a question clears its pending context")
        session.instruction = "At one second, zoom into this area."
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 2 }
        let data = await transport.payloads[1]
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let messages = payload["messages"] as! [[String: Any]]
        try require((messages.last?["content"] as? String)?.contains("Undo your last change") == false,
                    "fresh framing request cannot be trapped inside an older history clarification")
        await transport.fail(1)
        try await waitUntil { !session.isBusy }
    }

    private static func checkImmediateHistoryPreservesRedo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        var edited = fixture.editor.project.state
        edited.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2)]
        try require(fixture.editor.commit(edited, name: "Director: Change framing"), "prepare history shortcut")
        session.instruction = "Undo."
        session.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
        try require(fixture.editor.project.state.zoomKeyframes.isEmpty && fixture.editor.canRedo && !session.isBusy,
                    "plain Undo is the immediate normal stack action")
        var draft = fixture.editor.project.state
        draft.zoomKeyframes = [ZoomKeyframe(time: 3, scale: 1.5)]
        try require(fixture.editor.updateDraft(draft, at: 3), "make unfinished manual adjustment")
        let saved = fixture.editor.project
        session.instruction = "Redo"
        session.submit(editor: fixture.editor, playhead: 3, regionID: nil, editID: nil)
        try require(fixture.editor.project == saved && fixture.editor.draftState == draft && !fixture.editor.project.redoHistory.isEmpty,
                    "Redo never commits an unfinished edit and erases the requested redo branch")
        try require(fixture.editor.cancelDraft(), "discard test draft")
        session.instruction = "Redo that"
        session.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
        try require(fixture.editor.project.state == edited && session.errorMessage == nil,
                    "Redo restores normal history after the draft is cancelled")
        let requests = await transport.payloads.count
        try require(requests == 0, "canonical Undo and Redo do not require model inference")
    }

    private static func checkStaleProjectRejection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        let revision = try EditorCommandDispatcher.revision(for: fixture.editor.project)
        let instruction = "At one second, zoom into this area."
        session.instruction = instruction
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 1 }
        try require(fixture.editor.rename(to: "Changed during planning"), "make a user change while waiting")
        await transport.succeed(0, data: try sequence(session: session, revision: revision, region: fixture.region.id))
        try await waitUntil { !session.isBusy }
        try require(session.errorMessage == EditorCommandError.stale.localizedDescription && session.instruction == instruction,
                    "stale replies preserve the request and report the actual conflict")
        try require(fixture.editor.displayName == "Changed during planning" && fixture.editor.project.state.zoomKeyframes.isEmpty &&
                    fixture.editor.project.undoHistory.count == 1, "stale reply cannot overwrite independent edits or add history")
    }

    private static func checkCancelledLateReply() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        let revision = try EditorCommandDispatcher.revision(for: fixture.editor.project)
        session.instruction = "At one second, zoom into this area."
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 1 }
        session.cancel()
        try require(!session.isBusy && session.notice == nil, "cancellation immediately releases the panel state")
        session.instruction = "Describe this area as search results."
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 2 }
        await transport.succeed(0, data: try sequence(session: session, revision: revision, region: fixture.region.id))
        // The cancelled task resumes before this check; it must not steal the
        // new task's ownership or erase the newer instruction.
        for _ in 0..<20 { await Task.yield() }
        try require(session.isBusy && session.instruction == "Describe this area as search results." && !fixture.editor.canUndo,
                    "late cancelled reply cannot apply edits, clear newer input, or end a newer request")
        let response = try tool("label_region", ["project_id": session.projectID.uuidString, "expected_revision": revision,
            "region_id": fixture.region.id.uuidString, "label": "Search results"])
        await transport.succeed(1, data: response)
        try await waitUntil { !session.isBusy }
        try require(fixture.editor.project.state.regions[0].note == "Search results" &&
                    fixture.editor.project.state.zoomKeyframes.isEmpty && fixture.editor.project.undoHistory.count == 1,
                    "only the newer request may commit")
    }

    private static func checkClarificationFollowup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        let revision = try EditorCommandDispatcher.revision(for: fixture.editor.project)
        let original = "Zoom into this area."
        session.instruction = original
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 1 }
        let question = "When should the movement start?"
        await transport.succeed(0, data: try tool("ask_clarification", ["question": question]))
        try await waitUntil { !session.isBusy }
        try require(session.notice == question && session.instruction.isEmpty && !fixture.editor.canUndo,
                    "clarification is a question, not a successful edit")
        session.instruction = "At one second."
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 2 }
        let payload = await transport.payloads[1]
        let object = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]]
        let hasOriginal = messages.contains { $0["role"] as? String == "user" && $0["content"] as? String == original }
        let hasActualQuestion = messages.contains { message in
            guard message["role"] as? String == "tool", let text = message["content"] as? String else { return false }
            return text.contains(question) && text.contains("needs_answer")
        }
        try require(hasOriginal && hasActualQuestion && messages.last?["content"] as? String == "At one second.",
                    "followup receives actual prior user/tool-result turns and the current answer")
        await transport.succeed(1, data: try sequence(session: session, revision: revision, region: fixture.region.id))
        try await waitUntil { !session.isBusy }
        try require(fixture.editor.project.undoHistory.count == 1 && session.errorMessage == nil,
                    "clarification followed by an answer still creates one edit")
    }

    private static func editorAction(_ endpoint: AssistantAutomationEndpoint, _ name: String,
                                     _ parameters: [String: Any]) throws -> Data {
        let context = try endpoint.automationContext
        return try tool("editor_action", ["document_id": context.documentID, "expected_revision": context.revision,
            "tool": name, "parameters_json": String(decoding: JSONSerialization.data(withJSONObject: parameters), as: UTF8.self)])
    }

    private static func editorReport(_ endpoint: AssistantAutomationEndpoint, _ summary: String) throws -> Data {
        let context = try endpoint.automationContext
        return try tool("report_editor", ["document_id": context.documentID,
            "expected_revision": context.revision, "summary": summary])
    }

    private static func checkEditorAutomationControls() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let endpoint = AssistantAutomationEndpoint(editor: fixture.editor)
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        session.attachAutomation(endpoint)
        let original = fixture.editor.project
        for (index, parameters) in [["operation": "play"] as [String: Any],
            ["operation": "seek", "time": 1.5], ["operation": "set_rate", "rate": 2], ["operation": "pause"]].enumerated() {
            session.instruction = ["Play the preview", "Seek to 1.5 seconds", "Use 2× preview speed", "Pause the preview"][index]
            session.submit(editor: fixture.editor, playhead: endpoint.preview.time, regionID: nil, editID: nil)
            try await waitUntil { await transport.payloads.count == index + 1 }
            await transport.succeed(index, data: try editorAction(endpoint, "control_preview", parameters))
            try await waitUntil { !session.isBusy }
            try require(session.errorMessage == nil && session.instruction.isEmpty,
                        "Editor control requests must finish from the actual endpoint result")
        }
        try require(endpoint.calls == Array(repeating: "control_preview", count: 4) &&
                    endpoint.preview.time == 1.5 && endpoint.preview.rate == 2 && !endpoint.preview.isPlaying &&
                    fixture.editor.project == original && !fixture.editor.canUndo,
                    "Play/seek/rate/pause use the existing host without creating an edit or silently changing timing")
        let actualResults = session.conversation.messages().compactMap { $0["content"] as? String }.joined()
        try require(actualResults.contains("editor_result") && actualResults.contains("1.5") && actualResults.contains("rate"),
                    "The conversation must receive actual transport outcomes, not only the user's instructions")

        var draft = original.state
        draft.cursorStyle.size = 2
        try require(fixture.editor.updateDraft(draft, at: 1.5), "Begin a real unfinished manual adjustment")
        let saved = fixture.editor.project
        for (offset, parameters) in [["operation": "pause"] as [String: Any], ["operation": "set_rate", "rate": 0.5]].enumerated() {
            let index = offset + 4
            session.instruction = offset == 0 ? "Pause the preview" : "Set preview speed to half"
            session.submit(editor: fixture.editor, playhead: 1.5, regionID: nil, editID: nil)
            try await waitUntil { await transport.payloads.count == index + 1 }
            await transport.succeed(index, data: try editorAction(endpoint, "control_preview", parameters))
            try await waitUntil { !session.isBusy }
            try require(fixture.editor.project == saved && fixture.editor.draftState == draft,
                        "Pause and rate instructions cannot save or discard the unfinished manual edit")
        }
        _ = fixture.editor.cancelDraft()
    }

    private static func checkEditorAutomationReadAndReport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let endpoint = AssistantAutomationEndpoint(editor: fixture.editor)
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        session.attachAutomation(endpoint)
        session.instruction = "Zoom into this area."
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 1 }
        let question = "When should the movement start?"
        await transport.succeed(0, data: try tool("ask_clarification", ["question": question]))
        try await waitUntil { !session.isBusy }
        session.instruction = "Seek to 1.5 seconds."
        session.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
        try await waitUntil { await transport.payloads.count == 2 }
        await transport.succeed(1, data: try editorAction(endpoint, "control_preview", ["operation": "seek", "time": 1.5]))
        try await waitUntil { !session.isBusy }
        try require(session.awaitsClarification && session.notice == question &&
                    session.conversation.question?.context.playhead == 0 && endpoint.preview.time == 1.5,
                    "A navigation interlude must preserve the original pending question and its instruction anchor")
        session.instruction = "Which preview controls are available?"
        session.submit(editor: fixture.editor, playhead: 1.5, regionID: nil, editID: nil)
        try await waitUntil { await transport.payloads.count == 3 }
        await transport.succeed(2, data: try editorAction(endpoint, "describe_editor_actions", ["category": "preview"]))
        try await waitUntil { await transport.payloads.count == 4 }
        let continuation = await transport.payloads[3]
        try require(String(decoding: continuation, as: UTF8.self).contains("report_editor") && continuation.count <= 20_000,
                    "A real bounded editor read must enable scoped reporting in the next model turn")
        await transport.succeed(3, data: try editorReport(endpoint, "The preview can play, pause, seek and change speed."))
        try await waitUntil { !session.isBusy }
        try require(session.awaitsClarification && session.notice == question && !fixture.editor.canUndo,
                    "Read-and-report cannot resolve an unrelated pending question or create history")

        endpoint.oversizedRead = true
        session.instruction = "Read the editor state."
        session.submit(editor: fixture.editor, playhead: 1.5, regionID: nil, editID: nil)
        try await waitUntil { await transport.payloads.count == 5 }
        await transport.succeed(4, data: try editorAction(endpoint, "inspect_editor", ["section": "state"]))
        try await waitUntil { await transport.payloads.count == 6 }
        let bounded = await transport.payloads[5]
        let text = String(decoding: bounded, as: UTF8.self)
        try require(bounded.count <= 20_000 && text.contains("too_large") && !text.contains(String(repeating: "Z", count: 1000)),
                    "Oversized endpoint reads must become an explicit bounded projection failure, never a full context dump")
        await transport.succeed(5, data: try editorReport(endpoint, "The full state is too large; a smaller page is needed."))
        try await waitUntil { !session.isBusy }
    }

    private static func checkAutomationDraftReplan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let endpoint = AssistantAutomationEndpoint(editor: fixture.editor)
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        session.attachAutomation(endpoint)
        var draft = fixture.editor.project.state
        draft.cursorStyle.size = 2
        try require(fixture.editor.updateDraft(draft, at: 0), "Begin unfinished state before planning a framing edit")
        let oldRevision = try EditorCommandDispatcher.revision(for: fixture.editor.project)
        session.instruction = "At one second, zoom into this area and hold for a second."
        session.submit(editor: fixture.editor, playhead: 0, regionID: fixture.region.id, editID: nil)
        try await waitUntil { await transport.payloads.count == 1 }
        try require(fixture.editor.draftState == draft, "Merely asking the endpoint-capable model cannot prematurely save the draft")
        await transport.succeed(0, data: try sequence(session: session, revision: oldRevision, region: fixture.region.id))
        try await waitUntil { await transport.payloads.count == 2 }
        let freshRevision = try EditorCommandDispatcher.revision(for: fixture.editor.project)
        let replanned = String(decoding: await transport.payloads[1], as: UTF8.self)
        try require(freshRevision != oldRevision && fixture.editor.draftState == nil &&
                    fixture.editor.project.state == draft && replanned.contains("replan_required") && replanned.contains(freshRevision),
                    "A persistent plan must save the manual draft once and ask for a new plan against actual current state/revision")
        await transport.succeed(1, data: try sequence(session: session, revision: freshRevision, region: fixture.region.id))
        try await waitUntil { !session.isBusy }
        try require(session.errorMessage == nil && fixture.editor.project.undoHistory.count == 2 &&
                    fixture.editor.project.state.cursorStyle.size == 2 && fixture.editor.project.state.zoomKeyframes.count == 3,
                    "The actual agent edit is one Undo after the separately saved manual edit")
        try require(fixture.editor.undo() && fixture.editor.project.state == draft,
                    "One Undo of the agent plan preserves the earlier manual adjustment")
    }

    private static func checkAutomationManualEventsAndFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let endpoint = AssistantAutomationEndpoint(editor: fixture.editor)
        let transport = AssistantTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        session.attachAutomation(endpoint)
        session.instruction = "Seek to 1.5 seconds."
        session.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
        try await waitUntil { await transport.payloads.count == 1 }
        try endpoint.manualSeek(4.5, kind: "clock_tick")
        try require(session.isBusy, "A benign clock callback cannot cancel inference or enter conversation")
        try endpoint.manualSeek(4.75)
        try require(!session.isBusy && session.notice == nil, "A later manual navigation must take precedence over old inference")
        await transport.succeed(0, data: try editorAction(endpoint, "control_preview", ["operation": "seek", "time": 1.5]))
        for _ in 0..<20 { await Task.yield() }
        let events = session.conversation.messages().compactMap { $0["content"] as? String }.joined()
        try require(endpoint.calls.isEmpty && endpoint.preview.time == 4.75 &&
                    events.contains("editor_navigation") && events.contains("4.75") && !events.contains("clock_tick"),
                    "Conversation must retain actual manual state while ignoring stale replies and playback ticks")
        endpoint.rejectNext = true
        session.instruction = "Play the preview."
        session.submit(editor: fixture.editor, playhead: 4.75, regionID: nil, editID: nil)
        try await waitUntil { await transport.payloads.count == 2 }
        await transport.succeed(1, data: try editorAction(endpoint, "control_preview", ["operation": "play"]))
        try await waitUntil { !session.isBusy }
        try require(session.errorMessage?.contains("overlaps") == true && session.instruction == "Play the preview." &&
                    !endpoint.preview.isPlaying && !fixture.editor.canUndo,
                    "A structured okfalse editor result is an actual rejection, never a successful notice or applied edit")
    }

    private static func sequence(session: EditorAssistantSession, revision: String, region: UUID) throws -> Data {
        try tool("plan_sequence", ["project_id": session.projectID.uuidString, "expected_revision": revision,
            "start_seconds": 1, "steps": [["region_id": region.uuidString, "move_seconds": 0.4, "hold_seconds": 1]]])
    }
    private static func tool(_ name: String, _ arguments: [String: Any]) throws -> Data {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [["type": "function",
            "function": ["name": name, "arguments": arguments]]]]]]])
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let editor: ProjectEditor
        let region = EditorRegion(time: 0, rect: EditorRegionRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "original.mov", duration: 12)
            project.state.regions = [region]
            let url = directory.appendingPathComponent("recording.framethrower")
            try JSONEncoder().encode(project).write(to: url)
            editor = try ProjectEditor.open(url: url)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
