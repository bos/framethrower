import Darwin
import Foundation

private enum IntentFailure: Error { case failed(String) }
private actor ManagementRepairTransport {
    private var initial: Data?
    let native: Bool
    private(set) var payloads = [Data]()
    private var reply: CheckedContinuation<Data, any Error>?
    init(native: Bool) { self.native = native }
    func prepare(_ data: Data) { initial = data }
    func send(_ payload: Data) async throws -> Data {
        payloads.append(payload)
        if payloads.count == 1, let initial { return initial }
        if native {
            let response = try await LocalModelRuntime.shared.chat(payload: payload)
            FileHandle.standardOutput.write(Data(("NATIVE management repair response=" + String(decoding: response, as: UTF8.self) + "\n").utf8))
            return response
        }
        return try await withCheckedThrowingContinuation { reply = $0 }
    }
    func respond(_ response: Data) { reply?.resume(returning: response); reply = nil }
}

/// Captured management intent failures through the real planner and session.
/// Only temporary metadata; optional --model uses native Metal text inference.
@main @MainActor
struct ManagementIntentChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw IntentFailure.failed(message) }
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: .sortedKeys) }
    static func tool(_ args: [String: Any]) throws -> Data {
        try json(["choices": [["message": ["role": "assistant", "tool_calls": [["id": UUID().uuidString,
            "type": "function", "function": ["name": "manage_edits", "arguments": String(decoding: json(args), as: UTF8.self)]]]]]]])
    }
    static func wait(seconds: Double = 3, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw IntentFailure.failed("management repair timed out")
    }
    @MainActor private struct Fixture {
        let directory: URL
        let editor: ProjectEditor
        let a = EditAnchor(time: 1), b = EditAnchor(time: 5), c = EditAnchor(time: 6)
        let projectID = UUID()
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-management-intent-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "missing-screen.mov", duration: 12)
            project.state.editAnchors = [a, b, c]
            project.ensureReferences()
            editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
            try require(editor.save(), "save metadata fixture")
        }
        func close() { try? FileManager.default.removeItem(at: directory) }
        func context(_ id: UUID? = nil) throws -> LocalEditContext {
            LocalEditContext(recording: try EditorCommandDispatcher.context(editor: editor, projectID: id ?? projectID),
                playhead: 2, selectedRegionID: nil, selectedEditID: nil, videoProcessingAvailable: false)
        }
        func args(_ changes: [[String: Any]], id: UUID? = nil) throws -> [String: Any] {
            try ["version": 1, "project_id": (id ?? projectID).uuidString,
                "expected_revision": EditorCommandDispatcher.revision(for: editor.project), "changes": changes]
        }
        func result(_ changes: [[String: Any]], instruction: String?) throws -> LocalEditResult {
            try LocalEditPlanner.result(tool(args(changes)), context: context(), instruction: instruction,
                routingRequest: instruction)
        }
    }
    static func create(_ offset: Double, base: String = "start") -> [String: Any] {
        ["action": "create", "at_edit_label": base, "offset_seconds": offset]
    }
    static func delete(_ label: String) -> [String: Any] { ["action": "delete", "edit_label": label] }
    static func move(_ label: String) -> [String: Any] {
        ["action": "move", "edit_label": label, "at_edit_label": "Ref A", "offset_seconds": 2]
    }
    static func commands(_ value: LocalEditResult) throws -> EditorCommandBatch {
        guard case let .commands(batch, _) = value else { throw IntentFailure.failed("expected valid management commands") }
        return batch
    }
    static func main() async throws {
        let native = CommandLine.arguments.contains("--model")
        DispatchQueue.global().asyncAfter(deadline: .now() + (native ? 120 : 30)) { Darwin.exit(2) }
        try require(MediaProcessing.isSuspended, "requires suspended media")
        try rejectedIntents()
        try validAndUnconstrainedRequests()
        try focusedSchemas()
        try await sessionRepair(native: false)
        try await sessionRepair(native: false, wrongCorrection: true)
        FileHandle.standardOutput.write(Data("Deterministic management intent checks passed.\n".utf8))
        if native { try await sessionRepair(native: true) }
        print("Management intent checks passed (literal operation/identity guards, captured wrong create on delete, unchanged bytes, valid aliases, compound/follow-up compatibility, production corrective retry; metadata only).")
    }
    static func rejectedIntents() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
        let cases: [(String, [[String: Any]])] = [
            ("Delete Edit C.", [create(12)]), // Actual captured model failure, before outside-time handling.
            ("Delete Edit C.", [create(8)]), // Valid position must not turn the wrong action into an edit.
            ("Please remove Ref C!", [delete("Edit B")]),
            ("Move Edit B to two seconds after Edit A.", [move("Ref C")]),
            ("Can you move Ref B to three seconds?", [create(8)]),
            ("Create a new edit mark seven seconds after Edit A.", [delete("Ref C")]),
            ("Delete Edit C", [delete("Edit C"), delete("Edit B")]),
            ("Delete Edit Z", [create(8)]),
            ("Delete Edit Z", [delete("Ref B")]),
            ("Move Edit B two seconds after Edit A.", [move("Ref C")])]
        for (instruction, changes) in cases {
            guard case let .rejectedPlan(reason) = try fixture.result(changes, instruction: instruction), !reason.isEmpty else {
                throw IntentFailure.failed("wrong operation/identity was accepted: \(instruction)")
            }
            try require(fixture.editor.project == before && Data(contentsOf: fixture.editor.url) == bytes,
                        "rejecting an intent mismatch changed project/history bytes")
        }
        var stale = try fixture.args([create(8)]); stale["expected_revision"] = "stale"
        do {
            _ = try LocalEditPlanner.result(tool(stale), context: fixture.context(), instruction: "Delete Edit C.")
            throw IntentFailure.failed("intent rejection bypassed scope validation")
        } catch EditorCommandError.stale {}
    }
    static func validAndUnconstrainedRequests() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let addition = try commands(fixture.result([create(7, base: "Ref A")], instruction: "Please create a new edit mark seven seconds after Edit A."))
        try require(addition.commands == [.createEdit(time: 8)], "valid create changed timing")
        let moving = try commands(fixture.result([move("Ref B")], instruction: "Move Edit B two seconds after Edit A."))
        try require(moving.commands == [.moveEdit(editID: fixture.b.id, time: 3)], "move alias did not preserve the requested identity")
        let removal = try commands(fixture.result([delete("Ref C")], instruction: "Could you delete Edit C?"))
        try require(removal.commands == [.removeEdit(editID: fixture.c.id)], "delete alias did not preserve requested identity")
        let compound = try commands(fixture.result([delete("Ref C"), move("Ref B")], instruction: "Delete Edit C and move Edit B to two seconds after Edit A."))
        try require(compound.commands.count == 2, "literal guard blocked a compound request")
        let plural = try commands(fixture.result([create(8), create(9)], instruction: "Create edit marks at eight and nine seconds."))
        try require(plural.commands.count == 2, "guard constrained a plural creation request")
        let followup = try commands(fixture.result([delete("Ref B")], instruction: nil))
        try require(followup.commands == [.removeEdit(editID: fixture.b.id)], "literal guard interfered with a contextual clarification answer")
        let conditional = try commands(fixture.result([create(8)], instruction: "If needed, remove Edit C; otherwise create a mark at eight seconds."))
        try require(conditional.commands == [.createEdit(time: 8)], "guard inferred a literal action from an involved request")
        try EditorCommandDispatcher.apply(removal, to: fixture.editor, projectID: fixture.projectID)
        try require(!fixture.editor.project.state.editAnchors.contains { $0.id == fixture.c.id } && fixture.editor.project.undoHistory.count == 1 && fixture.editor.undo() && fixture.editor.project.state.editAnchors.contains { $0.id == fixture.c.id }, "valid removal lost ordinary durable Undo")
    }
    static func assertSchema(_ payload: Data, action: String?, target: String?) throws {
        let root = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let functions = (root["tools"] as! [[String: Any]]).map { $0["function"] as! [String: Any] }
        try require(functions.contains { $0["name"] as? String == "ask_clarification" }, "focused schema removed safe clarification")
        guard let management = functions.first(where: { $0["name"] as? String == "manage_edits" }) else { throw IntentFailure.failed("management route lost its tool") }
        let parameters = management["parameters"] as! [String: Any]
        let properties = parameters["properties"] as! [String: Any]
        let changes = properties["changes"] as! [String: Any]
        let items = changes["items"] as! [String: Any]
        let alternatives = items["oneOf"] as! [[String: Any]]
        let fields = alternatives.map { $0["properties"] as! [String: Any] }
        let actions = fields.map { ($0["action"] as! [String: Any])["const"] as! String }
        if let action {
            try require(actions == [action] && changes["maxItems"] as? Int == 1, "literal intent did not constrain opcode/count")
            try require((fields[0]["edit_label"] as? [String: Any])?["enum"] as? [String] == target.map { [$0] }, "focused target did not match the known canonical identity")
        } else {
            try require(Set(actions) == ["create", "move", "delete"] && changes["maxItems"] as? Int == 16 && fields.allSatisfy { ($0["edit_label"] as? [String: Any])?["enum"] == nil }, "contextual/compound request inherited an old literal restriction")
        }
    }
    static func focusedSchemas() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let context = try fixture.context()
        for (request, action, target): (String, String, String?) in [
            ("Delete Edit C.", "delete", "Edit C"),
            ("Move Edit B two seconds after Edit A.", "move", "Edit B"),
            ("Create a new edit mark seven seconds after Edit A.", "create", nil),
            ("Delete Edit Z.", "delete", nil)] {
            try assertSchema(LocalEditPlanner.payload(request: request, context: context), action: action, target: target)
        }
        try assertSchema(LocalEditPlanner.payload(request: "B instead.", context: context, routingRequest: "Delete Edit C."), action: nil, target: nil)
        try assertSchema(LocalEditPlanner.payload(request: "Delete Edit C and move Edit B to three seconds.", context: context), action: nil, target: nil)
    }
    static func sessionRepair(native: Bool, wrongCorrection: Bool = false) async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let transport = ManagementRepairTransport(native: native)
        let assistant = EditorAssistantSession(transport: { try await transport.send($0) },
            diagnostics: DirectorDiagnostics(directory: fixture.directory.appendingPathComponent("repair-diagnostics")),
            conversationStorageURL: fixture.directory.appendingPathComponent("repair-conversation.json"))
        await transport.prepare(try tool(fixture.args([create(8)], id: assistant.projectID)))
        defer { assistant.cancel() }
        let before = fixture.editor.project; let bytes = try Data(contentsOf: fixture.editor.url)
        assistant.instruction = "Delete Edit C."
        assistant.submit(editor: fixture.editor, playhead: 2, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 2 }
        try require(fixture.editor.project == before && Data(contentsOf: fixture.editor.url) == bytes, "bad initial operation was applied before corrective retry")
        let initialPayload = await transport.payloads[0]
        try assertSchema(initialPayload, action: "delete", target: "Edit C")
        let payload = await transport.payloads[1]
        try assertSchema(payload, action: "delete", target: "Edit C")
        let root = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        try require(root["tool_choice"] as? String == "required", "corrective continuation permitted an untyped prose response")
        let messages = root["messages"] as! [[String: Any]]
        let last = messages.last!
        let outcome = try JSONSerialization.jsonObject(with: Data((last["content"] as! String).utf8)) as! [String: Any]
        try require(last["role"] as? String == "tool" && outcome["status"] as? String == "rejected" && outcome["applied"] as? Bool == false && outcome["retryable"] as? Bool == true, "session did not pair the bad response with a corrective rejected outcome")
        if !native { await transport.respond(try tool(fixture.args([wrongCorrection ? create(9) : delete("Ref C")], id: assistant.projectID))) }
        try await wait(seconds: native ? 90 : 3) { !assistant.isBusy }
        if native {
            FileHandle.standardOutput.write(Data(("NATIVE management repair notice=" + (assistant.notice ?? "<none>") + "\nNATIVE management repair error=" + (assistant.errorMessage ?? "<none>") + "\n").utf8))
            if assistant.errorMessage != nil, let data = try? Data(contentsOf: fixture.directory.appendingPathComponent("repair-diagnostics/interactions.jsonl")) { FileHandle.standardOutput.write(data) }
        }
        if native, assistant.errorMessage != nil {
            try require(fixture.editor.project == before && Data(contentsOf: fixture.editor.url) == bytes,
                        "native failed correction changed project/history bytes")
        }
        if wrongCorrection {
            let calls = await transport.payloads.count
            try require(calls == 2 && assistant.errorMessage?.hasPrefix("Director’s proposed changes didn’t match your instruction. No changes were applied.") == true && fixture.editor.project == before && Data(contentsOf: fixture.editor.url) == bytes, "repeated mismatch mutated metadata, retried indefinitely, or reported a movement-only failure")
            return
        }
        try require(assistant.errorMessage == nil && !assistant.awaitsClarification && fixture.editor.project.state.editAnchors == before.state.editAnchors.filter { $0.id != fixture.c.id } && fixture.editor.project.undoHistory.count == 1, "corrective turn failed to remove exactly Edit C once")
        let calls = await transport.payloads.count
        try require(calls == 2 && fixture.editor.undo() && fixture.editor.project.state == before.state, "corrective retry was unbounded or broke shared Undo")
    }
}
