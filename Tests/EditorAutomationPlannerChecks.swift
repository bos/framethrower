import Foundation

private enum CheckFailure: Error { case failed(String) }
@main @MainActor
struct EditorAutomationPlannerChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw CheckFailure.failed(message) }
    }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
    static func reply(_ name: String, _ arguments: [String: Any]) throws -> Data {
        try json(["choices": [["message": ["tool_calls": [["type": "function", "function": ["name": name,
            "arguments": String(decoding: json(arguments), as: UTF8.self)]]]]]]])
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "metadata-only interlock")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-automation-planner-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = RecordingProject(screenFilename: "never-open.mov", duration: 12)
        let box4 = EditorRegion(time: 1, rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), note: "Delete")
        let box5 = EditorRegion(time: 2, rect: .init(x: 0.6, y: 0.6, width: 0.2, height: 0.2), note: "keep")
        let marker = EditAnchor(time: 6)
        project.state.regions = [box4, box5]
        project.state.editAnchors = [marker]
        project.references.boxes = [box4.id.uuidString: 4, box5.id.uuidString: 5]
        project.ensureReferences()
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("test.framethrower"))
        try require(editor.save(), "save fixture")
        let initialBytes = try Data(contentsOf: editor.url)
        let recordingID = UUID()
        let recording = try EditorCommandDispatcher.context(editor: editor, projectID: recordingID)
        var context = LocalEditContext(recording: recording, playhead: 1, selectedRegionID: box5.id, selectedEditID: nil, videoProcessingAvailable: false)
        context.automation = EditorAutomationContext(documentID: "opaque-editor", name: "Test", revision: recording.revision, hasDraft: false)
        func arguments(_ tool: String, _ parameters: [String: Any]) throws -> [String: Any] {
            try ["document_id": "opaque-editor", "expected_revision": recording.revision, "tool": tool,
                 "parameters_json": String(decoding: json(parameters), as: UTF8.self)]
        }
        func result(_ commands: [EditorCommand], _ request: String, title: String? = nil) throws -> LocalEditResult {
            var parameters: [String: Any] = ["commands": try JSONSerialization.jsonObject(with: JSONEncoder().encode(commands))]
            if let title { parameters["title"] = title }
            return try LocalEditPlanner.result(reply("editor_action", arguments("apply_edits", parameters)), context: context, instruction: request)
        }
        func rejected(_ commands: [EditorCommand], _ request: String, title: String? = nil) throws {
            guard case .rejectedPlan = try result(commands, request, title: title) else { throw CheckFailure.failed("must reject: " + request) }
            try require(try Data(contentsOf: editor.url) == initialBytes && !editor.canUndo && editor.draftState == nil,
                        "rejected wrapper preserves original bytes, history and draft")
        }
        try rejected([.labelRegion(regionID: box4.id, note: "Delete")], "Delete Box 4.")
        try rejected([.removeRegion(regionID: box5.id)], "Delete Box 4.")
        try rejected([.removeRegion(regionID: box4.id)], "Add a note to Box 4.")
        try rejected([.removeRegion(regionID: box4.id)], "Delete Box 4.", title: "unrequested rename")
        guard case .editorAction = try result([.labelRegion(regionID: box4.id, note: "area")], "Add a note to Box 4.") else { throw CheckFailure.failed("valid note") }
        guard case .editorAction = try result([.removeRegion(regionID: box4.id), .labelRegion(regionID: box5.id, note: "keep")], "Delete Box 4 and add a note to Box 5.") else { throw CheckFailure.failed("compound allowed") }
        try rejected([.createEdit(time: 7)], "Delete Edit A.")
        guard case .editorAction = try result([.removeEdit(editID: marker.id)], "Delete Edit A.") else { throw CheckFailure.failed("matching edit deletion") }
        guard case .rejectedPlan = try LocalEditPlanner.result(reply("editor_action", arguments("control_document", ["operation": "redo"])), context: context, instruction: "Undo the last change.") else { throw CheckFailure.failed("history direction cannot be substituted") }
        let timing = EditorMutationTiming(start: 2, end: 5)
        let badFit = EditorCommand.frameRegion(regionID: box4.id, time: 5)
        try rejected([badFit], "From seconds 2 to 5 pan the screen so its top-left matches Box 4.")
        try rejected([.mutate(.zoomScreen(scale: 2, center: nil, timing: timing))], "Pan the screen without zoom.")
        let exact = EditorCommand.mutate(.alignScreen(regionID: box4.id, subjectAnchor: .topLeft,
            targetAnchor: .topLeft, axes: .both, scalePolicy: .preserve, timing: timing))
        guard case .editorAction = try result([exact], "From seconds 2 to 5 pan the screen so its top-left matches Box 4.") else { throw CheckFailure.failed("typed exact align accepted; geometry engine validates reachability") }
        guard case .editorAction = try result([.mutate(.zoomScreen(scale: 2, center: nil, timing: timing))], "Pan and zoom the screen.") else { throw CheckFailure.failed("explicit combined zoom accepted") }
        let read = try reply("editor_action", arguments("describe_editor_actions", ["category": "editing", "operation": "alignScreen"]))
        guard case .editorAction = try LocalEditPlanner.result(read, context: context, instruction: "Delete Box 4.") else { throw CheckFailure.failed("read may precede literal action") }
        let report: [String: Any] = ["document_id": "opaque-editor", "expected_revision": recording.revision, "summary": "The screen is at 1×."]
        do { _ = try LocalEditPlanner.result(reply("report_editor", report), context: context); throw CheckFailure.failed("report requires actual read") }
        catch is EditorCommandError {}
        context.automationInspected = true
        guard case .editorReport = try LocalEditPlanner.result(reply("report_editor", report), context: context) else { throw CheckFailure.failed("read-only report") }
        var stale = try arguments("control_preview", ["operation": "pause"])
        stale["expected_revision"] = "old"
        do { _ = try LocalEditPlanner.result(reply("editor_action", stale), context: context); throw CheckFailure.failed("stale wrapper must fail") }
        catch is EditorCommandError {}
        func toolNames(_ data: Data) throws -> [String] {
            let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return (root["tools"] as! [[String: Any]]).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }
        try require(try toolNames(LocalEditPlanner.payload(request: "Undo the last change.", context: context)).contains("editor_action"), "automation offered even on strict history route")
        let conflict = EditorFramingConflict(proposal: .init(projectID: recordingID, revision: recording.revision, commands: []), summary: "A proposal", framingIDs: [], question: "Replace it?")
        try require(try toolNames(LocalEditPlanner.conflictPayload(answer: "Pause", conflict: conflict, context: context)).contains("editor_action"), "pending conflict offers independent controls")
        guard case .editorAction = try LocalEditPlanner.conflictResult(reply("editor_action", arguments("control_preview", ["operation": "pause"])), conflict: conflict, context: context, instruction: "Pause") else { throw CheckFailure.failed("pending conflict preview route") }
        var legacy = context
        legacy.automation = nil
        try require(try !toolNames(LocalEditPlanner.payload(request: "Show the whole frame.", context: legacy)).contains("editor_action"), "absent capability exposes no automation tool")
        let callResult = try result([.removeRegion(regionID: box4.id)], "Delete Box 4.")
        guard case let .editorAction(call) = callResult,
              let params = try JSONSerialization.jsonObject(with: call.arguments) as? [String: Any],
              let raw = params["commands"] else { throw CheckFailure.failed("valid delete action") }
        let commands = try JSONDecoder().decode([EditorCommand].self, from: json(raw))
        try require(EditorCommandDispatcher.apply(.init(projectID: recordingID, revision: recording.revision, commands: commands), to: editor, projectID: recordingID), "apply exact deletion")
        try require(editor.editingState.regions == [box5] && editor.canUndo, "only requested Box4 removed")
        try require(editor.undo() && editor.editingState.regions == project.state.regions && !editor.canUndo, "one normal Undo restores exact original")
        let sizes = try ["catalog": json(EditorMutation.describe(operation: nil)).count,
            "alignScreen": json(EditorMutation.describe(operation: "alignScreen")).count,
            "removeRegion": json(EditorMutation.describe(operation: "removeRegion")).count]
        try require(sizes["alignScreen", default: 0] < 4096 && sizes["removeRegion", default: 0] < 4096, "narrow schemas bounded")
        print("Automation planner checks passed: literal management, exact alignment/pan, scope, read-report gating, atomic single Undo; schema bytes \(sizes).")
    }
}
