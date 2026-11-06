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
        print("Editor assistant session checks passed (dictation draft preservation, atomic Undo, busy gating, failure preservation, stale revisions, cancelled late replies, and clarification context).")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AssistantCheckError.failed(message) }
    }
    private static func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw AssistantCheckError.failed("asynchronous assistant operation timed out")
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
        let messages = payload["messages"] as! [[String: String]]
        try require(messages.last?["content"]?.contains("Undo your last change") == false,
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
        let content = messages.last?["content"] as? String ?? ""
        try require(content.contains("Earlier instruction: " + original) && content.contains("Question: " + question) &&
                    content.contains("Answer: At one second."), "followup retains the original request and its question")
        await transport.succeed(1, data: try sequence(session: session, revision: revision, region: fixture.region.id))
        try await waitUntil { !session.isBusy }
        try require(fixture.editor.project.undoHistory.count == 1 && session.errorMessage == nil,
                    "clarification followed by an answer still creates one edit")
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
