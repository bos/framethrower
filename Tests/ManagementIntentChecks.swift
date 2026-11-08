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
    static func tool(_ args: [String: Any], name: String = "manage_edits") throws -> Data {
        try json(["choices": [["message": ["role": "assistant", "tool_calls": [["id": UUID().uuidString,
            "type": "function", "function": ["name": name, "arguments": String(decoding: json(args), as: UTF8.self)]]]]]]])
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
        let box4 = EditorRegion(time: 5, rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), note: "Delete")
        let box5 = EditorRegion(time: 6, rect: .init(x: 0.6, y: 0.6, width: 0.2, height: 0.2), note: "Existing Box 5 note")
        let projectID = UUID()
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-management-intent-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "missing-screen.mov", duration: 12)
            project.state.editAnchors = [a, b, c]
            project.state.regions = [box5, box4]
            project.state.regions[1].editID = b.id
            project.references.boxes = [UUID().uuidString: 1, box4.id.uuidString: 4, box5.id.uuidString: 5]
            project.ensureReferences()
            editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
            try require(editor.save(), "save metadata fixture")
        }
        func close() { try? FileManager.default.removeItem(at: directory) }
        func context(_ id: UUID? = nil, selectedBox: UUID? = nil) throws -> LocalEditContext {
            LocalEditContext(recording: try EditorCommandDispatcher.context(editor: editor, projectID: id ?? projectID),
                playhead: 2, selectedRegionID: selectedBox, selectedEditID: nil, videoProcessingAvailable: false)
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
        try boxManagement()
        try await boxSessionRepair()
        try await boxSessionRepair(wrongCorrection: true)
        try await sessionRepair(native: false)
        try await sessionRepair(native: false, wrongCorrection: true)
        FileHandle.standardOutput.write(Data("Deterministic management intent checks passed.\n".utf8))
        if native {
            try await sessionRepair(native: true)
            try await boxSessionRepair(native: true)
        }
        print("Management intent checks passed (literal edit/box operation+identity guards, captured wrong create/box note on deletion, unchanged bytes, stable sparse Box4 vs selectedBox5, durable Undo, contextual/compound compatibility and bounded production corrective retry; metadata only).")
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
    static func boxDelete(_ label: String) -> [String: Any] { ["action": "delete", "box_label": label] }
    static func boxNote(_ label: String, _ note: String) -> [String: Any] { ["action": "note", "box_label": label, "note": note] }
    private static func capturedBoxRename(_ fixture: Fixture, id: UUID) throws -> Data {
        try tool(["project_id": id.uuidString, "expected_revision": EditorCommandDispatcher.revision(for: fixture.editor.project),
                  "region_id": fixture.box4.id.uuidString, "label": "Delete"], name: "label_region")
    }
    static func assertBoxSchema(_ payload: Data, focused: Bool, action: String = "delete") throws {
        let root = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let functions = (root["tools"] as! [[String: Any]]).map { $0["function"] as! [String: Any] }
        try require(!functions.contains { $0["name"] as? String == "label_region" }, "A literal box deletion cannot expose the legacy note tool")
        let management = functions.first { $0["name"] as? String == "manage_boxes" }!
        let properties = (management["parameters"] as! [String: Any])["properties"] as! [String: Any]
        let changes = properties["changes"] as! [String: Any]
        let alternatives = (changes["items"] as! [String: Any])["oneOf"] as! [[String: Any]]
        let fields = alternatives.map { $0["properties"] as! [String: Any] }
        let actions = fields.map { ($0["action"] as! [String: Any])["const"] as! String }
        if focused {
            try require(actions == [action] && changes["maxItems"] as? Int == 1 &&
                        (fields[0]["box_label"] as! [String: Any])["enum"] as? [String] == ["Box 4"],
                        "Literal Box4 management pins opcode, count and stable numbered target")
        } else {
            try require(Set(actions) == ["delete", "note"] && changes["maxItems"] as? Int == 16 &&
                        fields.allSatisfy { ($0["box_label"] as! [String: Any])["enum"] == nil },
                        "A contextual answer or compound request cannot inherit a previous literal deletion target")
        }
    }
    static func boxManagement() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let before = fixture.editor.project, bytes = try Data(contentsOf: fixture.editor.url)
        let context = try fixture.context(selectedBox: fixture.box5.id)
        let request = "Delete box 4."
        for noteRequest in ["Set the note for Box 4 to area.", "Please add a note to Box 4: red and blue.", "Change Box 4's note to area."] {
            for changes in [[boxDelete("Box 4")], [boxNote("Box 5", "area")]] {
                guard case .rejectedPlan = try LocalEditPlanner.result(tool(fixture.args(changes), name: "manage_boxes"),
                    context: context, instruction: noteRequest, routingRequest: noteRequest) else {
                    throw IntentFailure.failed("Explicit note-only intent allowed a deletion or wrong box")
                }
            }
            try assertBoxSchema(LocalEditPlanner.payload(request: noteRequest, context: context), focused: true, action: "note")
            let note = try commands(LocalEditPlanner.result(tool(fixture.args([boxNote("Box 4", "area")]), name: "manage_boxes"),
                context: context, instruction: noteRequest, routingRequest: noteRequest))
            try require(note.commands == [.labelRegion(regionID: fixture.box4.id, note: "area")],
                        "Explicit note requests retain model-proposed content while guarding operation and stable identity")
        }
        let wrong = try capturedBoxRename(fixture, id: fixture.projectID)
        for route in [Optional(request), nil] {
            guard case .rejectedPlan = try LocalEditPlanner.result(wrong, context: context, instruction: request, routingRequest: route) else {
                throw IntentFailure.failed("Captured label_region('Delete') must be rejected before mutation, even without routing validation")
            }
        }
        for changes in [[boxNote("Box 4", "Delete")], [boxNote("Box 4", "wrong actual mutation")], [boxDelete("Box 5")], [boxDelete("Box 4"), boxDelete("Box 5")]] {
            guard case .rejectedPlan = try LocalEditPlanner.result(tool(fixture.args(changes), name: "manage_boxes"), context: context,
                instruction: request, routingRequest: request) else { throw IntentFailure.failed("Wrong box action/identity/count was accepted") }
        }
        try require(fixture.editor.project == before && Data(contentsOf: fixture.editor.url) == bytes,
                    "Rejected notes or wrong-target box requests cannot consume history or alter saved bytes")
        var stale = try fixture.args([boxDelete("Box 4")]); stale["expected_revision"] = "obsolete"
        do {
            _ = try LocalEditPlanner.result(tool(stale, name: "manage_boxes"), context: context, instruction: request)
            throw IntentFailure.failed("The literal box guard bypassed scope validation")
        } catch EditorCommandError.stale {}
        let deletion = try commands(LocalEditPlanner.result(tool(fixture.args([boxDelete("box4")]), name: "manage_boxes"),
            context: context, instruction: request, routingRequest: request))
        try require(deletion.commands == [.removeRegion(regionID: fixture.box4.id)],
                    "Delete Box4 resolves sparse allocation rather than selectedBox5 or array order, even with legacy note='Delete'")
        let encoded = try JSONEncoder().encode(deletion)
        try require(JSONDecoder().decode(EditorCommandBatch.self, from: encoded) == deletion, "The typed box removal survives exact command serialization")
        let compound = try commands(LocalEditPlanner.result(tool(fixture.args([boxDelete("Box 4"), boxNote("Box 5", "keep this")]), name: "manage_boxes"),
            context: context, instruction: "Delete Box 4 and set the note for Box 5 to keep this.", routingRequest: "Delete Box 4 and set the note for Box 5 to keep this."))
        let projected = try EditorCommandDispatcher.prepare(compound, for: before, projectID: fixture.projectID)
        try require(projected.regions.count == 1 && projected.regions[0].id == fixture.box5.id && projected.regions[0].note == "keep this",
                    "A real compound box delete/note stays atomic and is not narrowed to one literal operation")
        let followup = try commands(LocalEditPlanner.result(tool(fixture.args([boxDelete("Box 5")]), name: "manage_boxes"),
            context: context, instruction: nil, routingRequest: request))
        try require(followup.commands == [.removeRegion(regionID: fixture.box5.id)], "A genuine follow-up may select another numbered box")
        guard case let .commands(_, noteSummary) = try LocalEditPlanner.result(tool(fixture.args([boxNote("Box 4", "area")]), name: "manage_boxes"),
            context: context, instruction: "Set the note for Box 4 to area.") else { throw IntentFailure.failed("Valid note unavailable") }
        try require(noteSummary == "Updated Box 4 note.", "Note results must identify the actual target and must not claim a box rename")
        try assertBoxSchema(LocalEditPlanner.payload(request: request, context: context), focused: true)
        try assertBoxSchema(LocalEditPlanner.payload(request: "Box 5 instead.", context: context, routingRequest: request), focused: false)
        try assertBoxSchema(LocalEditPlanner.payload(request: "Delete Box 4 and set the note for Box 5 to area.", context: context), focused: false)
        try assertBoxSchema(LocalEditPlanner.payload(request: "Set the note for Box 4 to area and delete Box 5.", context: context), focused: false)
        try EditorCommandDispatcher.apply(deletion, to: fixture.editor, projectID: fixture.projectID, name: "Director: Removed Box 4.")
        var expected = before.state; expected.regions.removeAll { $0.id == fixture.box4.id }
        try require(fixture.editor.project.state == expected && fixture.editor.project.references == before.references &&
                    fixture.editor.project.undoHistory.count == 1 && fixture.editor.undo() && fixture.editor.project.state == before.state,
                    "A box deletion removes only the named guide, preserving anchors/framing/catalog and one durable Undo")
    }
    static func boxSessionRepair(native: Bool = false, wrongCorrection: Bool = false) async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let transport = ManagementRepairTransport(native: native)
        let assistant = EditorAssistantSession(transport: { try await transport.send($0) },
            diagnostics: DirectorDiagnostics(directory: fixture.directory.appendingPathComponent("box-diagnostics")),
            conversationStorageURL: fixture.directory.appendingPathComponent("box-conversation.json"))
        let before = fixture.editor.project, bytes = try Data(contentsOf: fixture.editor.url)
        await transport.prepare(try capturedBoxRename(fixture, id: assistant.projectID))
        assistant.instruction = "Delete box 4."
        assistant.submit(editor: fixture.editor, playhead: 2, regionID: fixture.box5.id, editID: nil)
        try await wait { await transport.payloads.count == 2 }
        try require(fixture.editor.project == before && Data(contentsOf: fixture.editor.url) == bytes && assistant.isBusy,
                    "A production corrective turn must not publish the captured note mutation")
        let payload = await transport.payloads[1]
        try assertBoxSchema(payload, focused: true)
        let root = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let messages = root["messages"] as! [[String: Any]]
        try require(messages.contains { $0["role"] as? String == "user" && $0["content"] as? String == "Delete box 4." },
                    "Repair retains the literal original user request rather than replacing conversation with a generated command")
        let last = messages.last!
        let outcome = try JSONSerialization.jsonObject(with: Data((last["content"] as! String).utf8)) as! [String: Any]
        let previous = messages[messages.count - 2]
        let call = (previous["tool_calls"] as! [[String: Any]])[0]
        try require((call["function"] as! [String: Any])["name"] as? String == "label_region" &&
                    last["tool_call_id"] as? String == call["id"] as? String && outcome["status"] as? String == "rejected" &&
                    outcome["applied"] as? Bool == false && outcome["retryable"] as? Bool == true,
                    "The repair conversation pairs the actual wrong note tool call with its real non-applied rejection")
        let target = wrongCorrection ? "Box 5" : "Box 4"
        if !native { await transport.respond(try tool(fixture.args([boxDelete(target)], id: assistant.projectID), name: "manage_boxes")) }
        try await wait(seconds: native ? 90 : 3) { !assistant.isBusy }
        if native {
            FileHandle.standardOutput.write(Data(("NATIVE box repair notice=" + (assistant.notice ?? "<none>") + "\nNATIVE box repair error=" + (assistant.errorMessage ?? "<none>") + "\n").utf8))
        }
        let calls = await transport.payloads.count
        try require(calls == 2, "Literal box repair is bounded to one corrective turn")
        if wrongCorrection {
            try require(assistant.errorMessage != nil && fixture.editor.project == before && Data(contentsOf: fixture.editor.url) == bytes,
                        "A second wrong-target proposal stops without altering project/history bytes")
        } else {
            var expected = before.state; expected.regions.removeAll { $0.id == fixture.box4.id }
            try require(assistant.errorMessage == nil && assistant.notice == "Removed Box 4." && fixture.editor.project.state == expected &&
                        fixture.editor.project.undoHistory.count == 1 && fixture.editor.undo() && fixture.editor.project.state == before.state,
                        "A corrected proposal deletes exactly Box4 once and truthful results/Undo reflect the actual mutation")
        }
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
