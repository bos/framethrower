import Foundation

private enum AbsoluteMoveFailure: Error { case failed(String) }

/// Captured absolute-time routing failure, exercised on metadata only.
@main @MainActor
struct AbsoluteMoveChecks {
    static let instruction = "At 2 seconds, take 3 seconds to zoom and pan from box 9 to box 10."
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AbsoluteMoveFailure.failed(message) }
    }
    struct Fixture {
        let id = UUID()
        let anchor = EditAnchor(time: 10.933333333333334)
        let source = EditorRegion(time: 8.4, rect: .init(x: 0.10949580533516837, y: 0.185546875,
            width: 0.3091806994818653, height: 0.3091806994818653))
        let target = EditorRegion(time: 8.4, rect: .init(x: 0.623246108929728, y: 0.22743280440414507,
            width: 0.2822518620466321, height: 0.2822518620466321))
        var project: RecordingProject
        init() {
            var value = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 14.366666666666667)
            value.state.editAnchors = [anchor]
            value.state.regions = [source, target]
            value.references.edits[anchor.id.uuidString] = 14 // N, matching the captured request.
            value.references.boxes = [source.id.uuidString: 9, target.id.uuidString: 10]
            value.ensureReferences()
            project = value
        }
        func context(selected: Bool = false) throws -> LocalEditContext {
            LocalEditContext(recording: EditorCommandContext(projectID: id,
                revision: try EditorCommandDispatcher.revision(for: project), duration: project.duration,
                state: project.state, references: project.references), playhead: 13.1895691669139,
                selectedRegionID: target.id, selectedEditID: selected ? anchor.id : nil, videoProcessingAvailable: false)
        }
        func scope() throws -> [String: Any] {
            try ["project_id": id.uuidString, "expected_revision": EditorCommandDispatcher.revision(for: project)]
        }
        func args(_ patches: [String: Any] = [:]) throws -> [String: Any] {
            try scope().merging(["start_seconds": 2, "duration_seconds": 3, "from_box_label": "Box 9",
                "to_box_label": "Box 10", "path": "direct"]) { _, new in new }.merging(patches) { _, new in new }
        }
        func capturedArgs() throws -> [String: Any] {
            try scope().merging(["start_edit_label": "Ref N", "duration_seconds": 3, "from_box_label": "Box 9",
                "to_box_label": "Box 10", "path": "direct"]) { _, new in new }
        }
    }
    static func response(_ name: String, _ args: [String: Any], callID: String = UUID().uuidString) throws -> Data {
        let arguments = try JSONSerialization.data(withJSONObject: args, options: .sortedKeys)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "tool_calls": [[
            "id": callID, "type": "function", "function": ["name": name, "arguments": String(decoding: arguments, as: UTF8.self)]
        ]]]]]])
    }
    static func batch(_ response: Data, fixture: Fixture, request: String? = instruction, selected: Bool = false) throws -> EditorCommandBatch {
        guard case let .commands(batch, summary) = try LocalEditPlanner.result(response, context: fixture.context(selected: selected),
            instruction: request, routingRequest: instruction) else { throw AbsoluteMoveFailure.failed("Expected absolute movement commands") }
        try require(summary.contains("2.00 s") && summary.contains("5.00 s") && !summary.contains("Edit N"),
                    "The actual summary must report absolute source times rather than an unrelated edit anchor")
        return batch
    }
    static func properties(_ payload: Data) throws -> ([String], [String: Any]) {
        let root = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let functions = (root["tools"] as! [[String: Any]]).map { $0["function"] as! [String: Any] }
        let names = functions.map { $0["name"] as! String }
        let absolute = functions.first { $0["name"] as? String == "move_at_time" }
        return (names, (absolute?["parameters"] as? [String: Any])?["properties"] as? [String: Any] ?? [:])
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Requires the media interlock")
        try capturedFailureAndCorrectApplication()
        try originSchemasAndContextualReplies()
        try conflictsAndBounds()
        print("Absolute move checks passed (captured unrelated-anchor failure, absolute2→5 source times, spoken timing, independent selected/playhead/box origins, strict scope/path/identity, conflicts and durable Undo/Redo; metadata only).")
        if CommandLine.arguments.contains("--model") { try await nativeModel() }
    }
    static func capturedFailureAndCorrectApplication() throws {
        let fixture = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("absolute-move-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ProjectEditor(project: fixture.project, url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "Save metadata baseline")
        let before = editor.project, bytes = try Data(contentsOf: editor.url)
        for selected in [false, true] {
            guard case .rejectedPlan = try LocalEditPlanner.result(response("move_for_duration", fixture.capturedArgs()),
                context: fixture.context(selected: selected), instruction: instruction, routingRequest: instruction) else {
                throw AbsoluteMoveFailure.failed("The captured RefN proposal must not be rebound or applied")
            }
            for patch: [String: Any] in [["start_seconds": fixture.anchor.time], ["start_seconds": 8.4],
                ["start_seconds": 15.1895691669139], ["duration_seconds": 2], ["path": "via_full_frame"],
                ["from_box_label": "Box 10", "to_box_label": "Box 9"]] {
                guard case .rejectedPlan = try LocalEditPlanner.result(response("move_at_time", fixture.args(patch)),
                    context: fixture.context(selected: selected), instruction: instruction, routingRequest: instruction) else {
                    throw AbsoluteMoveFailure.failed("Wrong timing/path/box identities must be repaired before application")
                }
            }
        }
        try require(editor.project == before && Data(contentsOf: editor.url) == bytes,
                    "Rejected proposals cannot modify state, bytes, or history")
        let plan = try batch(response("move_at_time", fixture.args()), fixture: fixture)
        try require(plan.commands == [
            .frameRegion(regionID: fixture.source.id, time: 2, motion: .init(transition: .jump)),
            .frameRegion(regionID: fixture.target.id, time: 5, motion: .init(transition: .smooth, duration: 3))
        ], "The accepted plan explicitly sets the source at2 and arrives after3 seconds, without an edit-time offset")
        try EditorCommandDispatcher.apply(plan, to: editor, projectID: fixture.id)
        let state = editor.project.state
        try require(state.zoomKeyframes.map(\.time) == [2, 5] && state.zoom(at: 2) == fixture.source.rect.framing() &&
                    state.zoom(at: 5) == fixture.target.rect.framing() && state.zoomKeyframes[1].duration == 3 &&
                    state.editAnchors == before.state.editAnchors && state.regions == before.state.regions &&
                    state.pipKeyframes == before.state.pipKeyframes && state.audio == before.state.audio,
                    "Actual metadata honors2→5 and preserves RefN, source-frame boxes and unrelated tracks")
        try require(editor.project.undoHistory.count == 1 && ProjectEditor.open(url: editor.url).project.state == state &&
                    editor.undo() && editor.project.state == before.state && editor.redo() && editor.project.state == state,
                    "One durable Undo/Redo reverses the entire absolute move")
    }
    static func originSchemasAndContextualReplies() throws {
        let fixture = Fixture()
        for selected in [false, true] {
            let context = try fixture.context(selected: selected)
            for request in [instruction, "At two seconds take three seconds to zoom and pan from Box nine to Box ten."] {
                let (names, fields) = try properties(LocalEditPlanner.payload(request: request, context: context))
                try require(Set(names) == ["move_at_time", "ask_clarification", "inspect_history"] &&
                            (fields["start_seconds"] as! [String: Any])["enum"] as? [Double] == [2] &&
                            (fields["duration_seconds"] as! [String: Any])["enum"] as? [Double] == [3],
                            "Absolute timing must receive its own exact schema even with an unrelated selected edit")
                _ = try batch(response("move_at_time", fixture.args()), fixture: fixture, request: request, selected: selected)
            }
            for request in ["Two seconds from now, take three seconds to zoom and pan from Box 9 to Box 10.",
                            "At two seconds from now, take three seconds to zoom and pan from Box 9 to Box 10."] {
                let (names, _) = try properties(LocalEditPlanner.payload(request: request, context: context))
                try require(names.contains("move_relative") && !names.contains("move_at_time"),
                            "Future-relative instructions must not become absolute timestamps")
            }
            let named = "At Reference N, take three seconds to zoom and pan from Box 9 to Box 10."
            let (names, _) = try properties(LocalEditPlanner.payload(request: named, context: context))
            try require(names.contains("move_for_duration") && !names.contains("move_at_time"), "A named starting edit retains its distinct timing semantics")
            guard case let .commands(namedBatch, _) = try LocalEditPlanner.result(response("move_for_duration", fixture.capturedArgs()), context: context, instruction: named, routingRequest: named),
                  case let .moveForDuration(startID, _, _, _, _) = namedBatch.commands[0], startID == fixture.anchor.id else {
                throw AbsoluteMoveFailure.failed("The same RefN proposal is valid only when the user actually names it")
            }
        }
        let (_, fields) = try properties(LocalEditPlanner.payload(request: "At four seconds instead.", context: fixture.context(), routingRequest: instruction))
        try require((fields["start_seconds"] as! [String: Any])["enum"] == nil,
                    "A contextual reply may change the original time without inheriting its old literal constraint")
        guard case let .commands(followup, _) = try LocalEditPlanner.result(response("move_at_time", fixture.args(["start_seconds": 4])),
            context: fixture.context(), instruction: nil, routingRequest: instruction),
              case let .frameRegion(_, start, _) = followup.commands[0], start == 4 else {
            throw AbsoluteMoveFailure.failed("A real clarification answer may revise the absolute starting timestamp")
        }
    }
    static func conflictsAndBounds() throws {
        var fixture = Fixture()
        fixture.project.state.zoomKeyframes = [ZoomKeyframe(time: 4, scale: 2)]
        fixture.project.ensureReferences()
        guard case let .framingConflict(conflict) = try LocalEditPlanner.result(response("move_at_time", fixture.args()),
            context: fixture.context(), instruction: instruction, routingRequest: instruction) else {
            throw AbsoluteMoveFailure.failed("Intervening real framing requires the existing explicit conflict review")
        }
        try require(conflict.framingIDs == [fixture.project.state.zoomKeyframes[0].id] && fixture.project.state.zoomKeyframes[0].time == 4,
                    "An absolute request cannot silently remove existing animation")
        var stale = try fixture.args(); stale["expected_revision"] = "obsolete"
        do {
            _ = try LocalEditPlanner.result(response("move_at_time", stale), context: fixture.context(), instruction: instruction)
            throw AbsoluteMoveFailure.failed("Absolute routing bypassed revision validation")
        } catch EditorCommandError.stale {}
        do {
            _ = try LocalEditPlanner.result(response("move_at_time", fixture.args(["start_seconds": 12])), context: fixture.context(),
                instruction: "At 12 seconds, take 3 seconds to move from Box 9 to Box 10.")
            throw AbsoluteMoveFailure.failed("An absolute arrival outside the source duration was accepted")
        } catch is EditorCommandError {}
    }
    static func nativeModel() async throws {
        let fixture = Fixture()
        let context = try fixture.context()
        let response = try await LocalModelRuntime.shared.chat(payload: LocalEditPlanner.payload(request: instruction, context: context))
        print("Native absolute response=" + String(decoding: response, as: UTF8.self))
        let plan = try batch(response, fixture: fixture)
        let state = try EditorCommandDispatcher.prepare(plan, for: fixture.project, projectID: fixture.id)
        try require(state.zoomKeyframes.map(\.time) == [2, 5] && state.editAnchors == fixture.project.state.editAnchors,
                    "Actual native Metal output must preserve the literal absolute origin instead of copying RefN")
        print("Native Metal absolute timing passed (captured request, unrelated RefN/playhead/box-source time, exact2→5; no media).")
    }
}
