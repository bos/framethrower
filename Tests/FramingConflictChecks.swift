import Foundation

private enum ConflictCheckError: Error { case failed(String) }

private actor ConflictTransport {
    private(set) var payloads: [Data] = []
    private var replies: [Int: CheckedContinuation<Data, any Error>] = [:]
    func send(_ data: Data) async throws -> Data {
        let index = payloads.count
        payloads.append(data)
        return try await withCheckedThrowingContinuation { replies[index] = $0 }
    }
    func reply(_ index: Int, _ data: Data) { replies.removeValue(forKey: index)?.resume(returning: data) }
}

/// Exercises real proposal/clarification/session/command code with metadata
/// only. The optional native run uses Metal text inference; never media or mic.
@main @MainActor
struct FramingConflictChecks {
    static let instruction = "Pan from Box 1 to Box 2 over the next three seconds."
    static let answer = "Let's have the new movement replace it."

    static func main() async throws {
        guard MediaProcessing.isSuspended else { throw ConflictCheckError.failed("Requires suspended media") }
        try checkTypedReplacementAndValidation()
        try checkWholeMovementDisclosure()
        try await checkSessionReplacementAndFrozenContext()
        try await checkResolutionFollowup()
        try await checkKeepAndStaleAnswers()
        if CommandLine.arguments.contains("--model") { try await checkNativeAnswers() }
        print("Framing conflict checks passed (exact frozen proposal, replacement/keep answers, camera/pointer/reference preservation, one durable Undo/Redo, stale replies and strict scope; no media).")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ConflictCheckError.failed(message) }
    }
    static func wait(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw ConflictCheckError.failed("Assistant request timed out")
    }
    static func tool(_ name: String, _ args: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: args)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [[
            "type": "function", "function": ["name": name, "arguments": String(decoding: data, as: UTF8.self)]
        ]]]]]])
    }
    static func choice(_ conflict: EditorFramingConflict, _ value: Any, patch: [String: Any] = [:]) throws -> Data {
        try tool("resolve_framing_conflict", ["project_id": conflict.proposal.projectID.uuidString,
            "expected_revision": conflict.proposal.revision, "choice": value].merging(patch) { _, b in b })
    }
    static func commands(_ result: LocalEditResult) throws -> EditorCommandBatch {
        guard case let .commands(batch, _) = result else { throw ConflictCheckError.failed("Expected applied replacement commands") }
        return batch
    }

    @MainActor
    struct Fixture {
        let directory: URL
        let editor: ProjectEditor
        let sourceID = UUID()
        let outsideID = UUID()
        let box1: EditorRegion
        let box2: EditorRegion
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-framing-conflict-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "missing-original.mov", cameraFilename: "missing-camera.mov", duration: 14.37)
            project.title = "Named recording"
            project.state.zoomKeyframes = [ZoomKeyframe(id: sourceID, time: 1, scale: 2, transition: .smooth, duration: 1),
                ZoomKeyframe(id: outsideID, time: 8, scale: 1.5, transition: .jump)]
            box1 = EditorRegion(time: 1, rect: .init(x: 0.1, y: 0.15, width: 0.25, height: 0.3), editID: sourceID)
            box2 = EditorRegion(time: 1, rect: .init(x: 0.6, y: 0.45, width: 0.3, height: 0.3), editID: sourceID)
            project.state.regions = [box1, box2]
            project.state.pipKeyframes.append(PIPKeyframe(time: 1, placement: PIPPlacement(x: 0.1, y: 0.2, scale: 0.2), transition: .smooth, duration: 1))
            project.state.cursorStyle.size = 2.5
            project.ensureReferences()
            editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
            guard editor.save() else { throw ConflictCheckError.failed("Save metadata fixture") }
        }
        func close() { try? FileManager.default.removeItem(at: directory) }
        func context(_ projectID: UUID) throws -> LocalEditContext {
            LocalEditContext(recording: try EditorCommandDispatcher.context(editor: editor, projectID: projectID),
                playhead: 0, selectedRegionID: nil, selectedEditID: nil, videoProcessingAvailable: false)
        }
        func initialResponse(_ projectID: UUID) throws -> Data {
            try tool("move_relative", ["project_id": projectID.uuidString,
                "expected_revision": try EditorCommandDispatcher.revision(for: editor.project),
                "from_box_label": "Box 1", "to_box_label": "Box 2", "start_delay_seconds": 0,
                "arrival_seconds": 3, "arrival_origin": "playhead", "path": "direct"])
        }
        func conflict(_ projectID: UUID) throws -> EditorFramingConflict {
            guard case let .framingConflict(conflict) = try LocalEditPlanner.result(initialResponse(projectID), context: context(projectID), instruction: instruction) else {
                throw ConflictCheckError.failed("Overlapping move must return a retained framing proposal")
            }
            return conflict
        }
    }

    static func checkTypedReplacementAndValidation() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let id = UUID()
        let before = fixture.editor.project
        let conflict = try fixture.conflict(id)
        try require(conflict.framingIDs == [fixture.sourceID] && conflict.question.contains("0.00 s") && conflict.question.contains("1.00 s"),
                    "Question identifies the complete conflicting movement and leaves later framing alone")
        try require(fixture.editor.project == before && !fixture.editor.canUndo, "Asking cannot mutate recording")
        let replacement = try commands(LocalEditPlanner.conflictResult(choice(conflict, "replace"), conflict: conflict))
        try require(replacement == conflict.replacement && replacement.commands.first == .removeScreenFraming(editID: fixture.sourceID),
                    "Answer resolves the retained exact proposal, without replanning")
        try EditorCommandDispatcher.apply(replacement, to: fixture.editor, projectID: id)
        let after = fixture.editor.project
        try require(after.state.pipKeyframes == before.state.pipKeyframes && after.state.cursorStyle == before.state.cursorStyle &&
                    after.state.regions == before.state.regions && after.title == before.title &&
                    after.state.trimStart == before.state.trimStart && after.state.trimEnd == before.state.trimEnd,
                    "Replacing screen movement preserves camera, pointer, boxes, title and trim")
        try require(after.state.editAnchors.contains { $0.id == fixture.sourceID && $0.time == 1 } &&
                    after.state.timedEdits(includeCamera: true).contains { $0.id == fixture.sourceID },
                    "Removed framing retains the named source moment even with a co-timed camera")
        try require(after.state.zoomKeyframes.first { $0.id == fixture.outsideID } == before.state.zoomKeyframes.first { $0.id == fixture.outsideID },
                    "Nonconflicting later framing stays intact")
        try require(after.state.zoom(at: 0) == fixture.box1.rect.framing() && after.state.zoom(at: 3) == fixture.box2.rect.framing(),
                    "Replacement applies original zero-to-three-second motion")
        try require(after.undoHistory.count == 1 && (try ProjectEditor.open(url: fixture.editor.url).project.state) == after.state &&
                    fixture.editor.undo() && fixture.editor.project.state == before.state &&
                    fixture.editor.redo() && fixture.editor.project.state == after.state,
                    "Replacement persists as one ordinary Undo/Redo entry")
        guard case .noChanges = try LocalEditPlanner.conflictResult(choice(conflict, "keep"), conflict: conflict) else {
            throw ConflictCheckError.failed("Keep must explicitly finish without a change")
        }
        for patch: [String: Any] in [["choice": true], ["choice": "delete_all"], ["extra": true],
                                    ["project_id": UUID().uuidString], ["expected_revision": "stale"]] {
            do {
                _ = try LocalEditPlanner.conflictResult(choice(conflict, "replace", patch: patch), conflict: conflict)
                throw ConflictCheckError.failed("Invalid conflict resolution accepted: \(patch.keys)")
            } catch is EditorCommandError { }
        }
        guard case .clarification = try LocalEditPlanner.conflictResult(tool("ask_clarification", ["question": "Replace it or keep it?"]), conflict: conflict) else {
            throw ConflictCheckError.failed("Unclear answers may clarify without dropping the proposal")
        }
        var foreign = try fixture.context(id)
        foreign.recording.projectID = UUID()
        do {
            _ = try LocalEditPlanner.conflictPayload(answer: answer, conflict: conflict, context: foreign)
            throw ConflictCheckError.failed("Conflict payload accepted foreign project context")
        } catch is EditorCommandError { }
    }

    private static func begin(_ fixture: Fixture, session: EditorAssistantSession, transport: ConflictTransport) async throws -> EditorFramingConflict {
        session.instruction = instruction
        session.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 1 }
        await transport.reply(0, try fixture.initialResponse(session.projectID))
        try await wait { !session.isBusy }
        try require(session.awaitsClarification && session.errorMessage == nil && session.instruction.isEmpty && !fixture.editor.canUndo,
                    "First response asks exactly once without applying any work")
        let reviewID = session.conflictReviewID
        try require(reviewID != nil && session.conflictReview != nil &&
                    session.conflictReview?.previewState.zoomKeyframes.isEmpty == true,
                    "A pending conflict exposes a cached full-source comparison without applying it")
        _ = session.conflictReview?.outlines(at: 0.5)
        try require(session.conflictReviewID == reviewID && !fixture.editor.canUndo,
                    "Reading comparison samples cannot regenerate proposal identities or create Undo")
        return try fixture.conflict(session.projectID)
    }

    static func checkWholeMovementDisclosure() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var state = fixture.editor.project.state
        state.zoomKeyframes[1].transition = .smooth
        state.zoomKeyframes[1].duration = 7
        try require(fixture.editor.commit(state, name: "Fixture crossing movement"), "Create later movement crossing requested span")
        let conflict = try fixture.conflict(UUID())
        try require(Set(conflict.framingIDs) == [fixture.sourceID, fixture.outsideID] &&
                    conflict.question.contains("1.00 s–8.00 s") &&
                    conflict.question.contains("Replace all these framing movements"),
                    "Question includes the full later 1–8-second movement, not just the new 0–3-second span")
        _ = try EditorCommandDispatcher.prepare(conflict.replacement, for: fixture.editor.project, projectID: conflict.proposal.projectID)
    }

    static func checkSessionReplacementAndFrozenContext() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let transport = ConflictTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        let before = fixture.editor.project.state
        let conflict = try await begin(fixture, session: session, transport: transport)
        session.appendDictation(answer)
        session.submit(editor: fixture.editor, playhead: 9.6, regionID: fixture.box2.id, editID: fixture.sourceID)
        try await wait { await transport.payloads.count == 2 }
        let payloads = await transport.payloads
        let payload = try JSONSerialization.jsonObject(with: payloads[1]) as! [String: Any]
        let tools = (payload["tools"] as! [[String: Any]]).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        let messages = payload["messages"] as! [[String: Any]]
        try require(Set(tools) == ["resolve_framing_conflict", "ask_clarification"] && (messages.last?["content"] as? String)?.contains(answer) == true,
                    "Dictated answer receives only resolution tools, never a fresh movement plan")
        await transport.reply(1, try choice(conflict, "replace"))
        try await wait { !session.isBusy }
        try require(!session.awaitsClarification && session.errorMessage == nil && session.instruction.isEmpty &&
                    session.notice?.contains("Replaced") == true && fixture.editor.project.undoHistory.count == 1,
                    "Exact replace answer completes instead of asking the same question again")
        try require(session.conflictReview == nil && session.conflictReviewID == nil,
                    "Accepting a proposal clears its transient comparison")
        try require(fixture.editor.project.state.zoom(at: 0) == fixture.box1.rect.framing() &&
                    fixture.editor.project.state.zoom(at: 3) == fixture.box2.rect.framing() &&
                    !fixture.editor.project.state.zoomKeyframes.contains { abs($0.time - 12.6) < 0.000001 },
                    "Answering after moving the playhead preserves the original proposed movement")
        let replaced = fixture.editor.project.state
        try require(fixture.editor.undo() && fixture.editor.project.state == before && fixture.editor.redo() && fixture.editor.project.state == replaced,
                    "Session applies replacement as one reversible operation")
    }

    static func checkKeepAndStaleAnswers() async throws {
        for stale in [false, true] {
            let fixture = try Fixture()
            defer { fixture.close() }
            let transport = ConflictTransport()
            let session = EditorAssistantSession(transport: { try await transport.send($0) })
            let conflict = try await begin(fixture, session: session, transport: transport)
            let before = fixture.editor.project
            session.instruction = stale ? answer : "Keep the existing movement."
            session.submit(editor: fixture.editor, playhead: 9.6, regionID: nil, editID: nil)
            try await wait { await transport.payloads.count == 2 }
            if stale {
                try require(fixture.editor.rename(to: "Changed while answering"), "Change project while resolution is in flight")
                try require(session.conflictReview == nil && session.conflictReviewID == nil,
                            "A manual revision immediately hides the obsolete comparison")
            }
            let current = fixture.editor.project
            await transport.reply(1, try choice(conflict, stale ? "replace" : "keep"))
            try await wait { !session.isBusy }
            if stale {
                try require(fixture.editor.project == current && session.errorMessage == EditorCommandError.stale.localizedDescription && !session.awaitsClarification,
                            "Late resolution cannot modify a different revision or leave a stale question active")
            } else {
                try require(fixture.editor.project == before && !session.awaitsClarification && session.errorMessage == nil && session.notice == "Kept the existing framing.",
                            "Keep ends the question without writing history or changing the recording")
                try require(session.conflictReview == nil && session.conflictReviewID == nil,
                            "Keeping existing framing clears the proposal comparison")
            }
        }
        let fixture = try Fixture()
        defer { fixture.close() }
        let transport = ConflictTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        _ = try await begin(fixture, session: session, transport: transport)
        try require(fixture.editor.rename(to: "Changed before answering"), "Change revision before answer")
        let changed = fixture.editor.project
        session.instruction = answer
        session.submit(editor: fixture.editor, playhead: 0, regionID: nil, editID: nil)
        let requests = await transport.payloads.count
        try require(requests == 1 && fixture.editor.project == changed && session.errorMessage == EditorCommandError.stale.localizedDescription && !session.awaitsClarification,
                    "An already-stale question is rejected before inference")
    }

    static func checkResolutionFollowup() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let transport = ConflictTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) })
        let before = fixture.editor.project.state
        let conflict = try await begin(fixture, session: session, transport: transport)
        session.instruction = "I'm not sure."
        session.submit(editor: fixture.editor, playhead: 9.6, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 2 }
        let question = "Replace new or keep old?"
        await transport.reply(1, try tool("ask_clarification", ["question": question]))
        try await wait { !session.isBusy }
        try require(session.notice == question && session.awaitsClarification && fixture.editor.project.state == before && !fixture.editor.canUndo,
                    "An unclear resolution retains the frozen proposal without an edit")
        session.appendDictation(answer)
        session.submit(editor: fixture.editor, playhead: 11, regionID: fixture.box2.id, editID: fixture.sourceID)
        try await wait { await transport.payloads.count == 3 }
        let payloads = await transport.payloads
        let payload = try JSONSerialization.jsonObject(with: payloads[2]) as! [String: Any]
        let messages = payload["messages"] as! [[String: Any]]
        let context = (messages[1]["content"] as! String).components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        let details = try JSONSerialization.jsonObject(with: Data(context.utf8)) as! [String: Any]
        try require(details["question"] as? String == question && messages.last?["content"] as? String == answer,
                    "Follow-up answers see the latest question, not the original replacement question again")
        await transport.reply(2, try choice(conflict, "replace"))
        try await wait { !session.isBusy }
        try require(!session.awaitsClarification && session.errorMessage == nil && fixture.editor.project.undoHistory.count == 1 &&
                    fixture.editor.project.state.zoom(at: 0) == fixture.box1.rect.framing() &&
                    fixture.editor.project.state.zoom(at: 3) == fixture.box2.rect.framing(),
                    "Follow-up resolution applies the same original movement exactly once")
        try require(fixture.editor.undo() && fixture.editor.project.state == before, "One Undo restores the complete pre-question state")
    }

    static func checkNativeAnswers() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let id = UUID()
        let conflict = try fixture.conflict(id)
        let context = try fixture.context(id)
        for (text, replace) in [(answer, true), ("Use the new pan instead.", true), ("Keep the existing movement.", false)] {
            let response = try await LocalModelRuntime.shared.chat(payload: LocalEditPlanner.conflictPayload(answer: text, conflict: conflict, context: context))
            let result = try LocalEditPlanner.conflictResult(response, conflict: conflict)
            if replace {
                try require(try commands(result) == conflict.replacement, "Native model resolves exact dictated replacement answer")
            } else {
                guard case .noChanges = result else { throw ConflictCheckError.failed("Native model failed to keep old movement") }
            }
            print("Native Metal conflict answer passed: \(replace ? "replace" : "keep") (no media).")
        }
    }
}
