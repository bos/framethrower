import Foundation

private enum DurationMoveFailure: Error { case failed(String) }

@main @MainActor
struct DurationMoveChecks {
    static func main() async throws {
        try checkDirectMove()
        try checkArrivalCoalescingAndPullback()
        try checkInvalidMovesAreAtomic()
        try checkPlanner()
        if CommandLine.arguments.contains("--model") { try await checkNativeModel() }
        print("Duration move checks passed (direct smooth pan/zoom, generated arrival, independent camera/pointer edits, conflicts, strict scope, and atomic Undo/Redo; no video).")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw DurationMoveFailure.failed(message) }
    }

    struct Fixture {
        var project: RecordingProject
        let id = UUID()
        let startID: UUID
        let source: EditorRegion
        let target: EditorRegion
        var context: LocalEditContext {
            LocalEditContext(recording: EditorCommandContext(projectID: id,
                revision: try! EditorCommandDispatcher.revision(for: project), duration: project.duration,
                state: project.state, references: project.references), playhead: 1,
                selectedRegionID: target.id, selectedEditID: startID, videoProcessingAvailable: false)
        }
        init() {
            var value = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", duration: 12)
            source = value.state.addRegion(rect: EditorRegionRect(x: 0.1, y: 0.2, width: 0.22, height: 0.2), at: 1)
            target = value.state.addRegion(rect: EditorRegionRect(x: 0.6, y: 0.4, width: 0.3, height: 0.3), at: 1)
            startID = source.editID!
            value.state.pipKeyframes.append(PIPKeyframe(time: 3,
                placement: PIPPlacement(x: 0.1, y: 0.1, scale: 0.25), transition: .smooth, duration: 1))
            value.state.cursorStyle.size = 2.5
            value.ensureReferences()
            project = value
        }
        func batch(duration: Double = 5, viaFullFrame: Bool = false) throws -> EditorCommandBatch {
            EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: project),
                commands: [.moveForDuration(startEditID: startID, fromRegionID: source.id,
                    toRegionID: target.id, duration: duration, viaFullFrame: viaFullFrame)])
        }
    }

    static func checkDirectMove() throws {
        let fixture = Fixture()
        let next = try EditorCommandDispatcher.prepare(fixture.batch(), for: fixture.project, projectID: fixture.id)
        try require(next.zoomKeyframes.count == 2 && next.editAnchors.count == 2,
                    "direct move creates only start and arrival framing with a reference for each")
        let start = next.zoomKeyframes[0], end = next.zoomKeyframes[1]
        try require(start.id == fixture.startID && start.time == 1 && end.time == 6,
                    "named start retains identity and arrival is exactly five seconds later")
        try require(end.transition == .smooth && end.duration == 5,
                    "one shared smooth movement spans the complete requested duration")
        try require(next.zoom(at: 1) == fixture.source.rect.framing() && next.zoom(at: 6) == fixture.target.rect.framing(),
                    "both numbered boxes determine complete source and destination framings")
        let middle = next.zoom(at: 3.5), from = fixture.source.rect.framing(), to = fixture.target.rect.framing()
        try require(abs(middle.scale - (from.scale + to.scale) / 2) < 1e-9 &&
                    abs(middle.x - (from.x + to.x) / 2) < 1e-9 && abs(middle.y - (from.y + to.y) / 2) < 1e-9,
                    "pan and zoom interpolate together instead of introducing a full-frame waypoint")
        try require((0...50).allSatisfy { next.zoom(at: 1 + Double($0) / 10).scale > 2 }, "direct path never pulls out to full frame")
        try require(next.zoom(at: 0.5) == fixture.project.state.zoom(at: 0.5), "unrelated footage before the named start is unchanged")
        try require(next.pipKeyframes == fixture.project.state.pipKeyframes && next.cursorStyle == fixture.project.state.cursorStyle,
                    "overlapping camera movement and pointer styling remain independent")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("duration.framethrower")
        let editor = ProjectEditor(project: fixture.project, url: url)
        try require(editor.save(), "save metadata fixture")
        try EditorCommandDispatcher.apply(fixture.batch(), to: editor, projectID: fixture.id)
        let edited = editor.project.state
        let arrival = edited.timedEdits(includeCamera: true).first { abs($0.time - 6) < 1e-9 }!
        try require(editor.project.references.editLabel(for: arrival.id) == "Edit C", "arrival receives next stable letter without renumbering the camera edit")
        try require(editor.project.undoHistory.count == 1 && (try ProjectEditor.open(url: url).project.state) == edited,
                    "duration request is one durable ordinary edit")
        try require(editor.undo() && editor.project.state == fixture.project.state, "one Undo reverses complete move")
        try require(editor.redo() && editor.project.state == edited, "one Redo restores the same arrival identity")
    }

    static func checkArrivalCoalescingAndPullback() throws {
        var fixture = Fixture()
        let endpoint = ZoomKeyframe(time: 6, scale: fixture.target.rect.framing().scale,
            x: fixture.target.rect.framing().x, y: fixture.target.rect.framing().y)
        fixture.project.state.zoomKeyframes = [endpoint]
        fixture.project.ensureReferences()
        let next = try EditorCommandDispatcher.prepare(fixture.batch(), for: fixture.project, projectID: fixture.id)
        try require(next.zoomKeyframes.last?.id == endpoint.id && next.editAnchors.count == 1,
                    "compatible existing arrival coalesces without another mark")
        let plain = Fixture()
        let pullback = try EditorCommandDispatcher.prepare(plain.batch(viaFullFrame: true), for: plain.project, projectID: plain.id)
        try require(pullback.zoomKeyframes.count == 3 && pullback.zoom(at: 3.5).scale == 1 &&
                    pullback.zoomKeyframes[1].duration == 2.5 && pullback.zoomKeyframes[2].duration == 2.5,
                    "only explicit full-frame path inserts the halfway pullback")
        let encoded = try JSONEncoder().encode(try plain.batch())
        try require(try JSONDecoder().decode(EditorCommandBatch.self, from: encoded) == plain.batch(), "typed duration command round trips")
    }

    static func checkInvalidMovesAreAtomic() throws {
        let original = Fixture()
        for duration in [0.0, -1, .infinity, .nan, 61, 11] {
            do {
                _ = try EditorCommandDispatcher.prepare(original.batch(duration: duration), for: original.project, projectID: original.id)
                throw DurationMoveFailure.failed("invalid duration accepted")
            } catch is EditorCommandError { }
        }
        for point in [ZoomKeyframe(time: 3, scale: 2), ZoomKeyframe(time: 6, scale: 1),
                      ZoomKeyframe(time: 8, scale: 2, transition: .smooth, duration: 4)] {
            var fixture = original
            fixture.project.state.zoomKeyframes = [point]
            fixture.project.ensureReferences()
            do {
                _ = try EditorCommandDispatcher.prepare(fixture.batch(), for: fixture.project, projectID: fixture.id)
                throw DurationMoveFailure.failed("conflicting screen movement accepted")
            } catch is EditorCommandError { }
        }
        var overlapping = try original.batch()
        overlapping.commands.append(.moveForDuration(startEditID: original.startID, fromRegionID: original.source.id,
                                                     toRegionID: original.target.id, duration: 2))
        do {
            _ = try EditorCommandDispatcher.prepare(overlapping, for: original.project, projectID: original.id)
            throw DurationMoveFailure.failed("two competing same-target movements accepted")
        } catch is EditorCommandError { }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ProjectEditor(project: original.project, url: directory.appendingPathComponent("atomic.framethrower"))
        try require(editor.save(), "save failure fixture")
        let saved = try Data(contentsOf: editor.url), baseline = editor.project
        var invalid = try original.batch()
        invalid.commands.append(.reviseFraming(editID: UUID(), regionID: original.target.id))
        do {
            try EditorCommandDispatcher.apply(invalid, to: editor, projectID: original.id)
            throw DurationMoveFailure.failed("partial batch applied")
        } catch is EditorCommandError { }
        try require(editor.project == baseline && (try Data(contentsOf: editor.url)) == saved, "later failure leaves history, memory, and disk untouched")
    }

    static let instruction = "At Edit A, pan and zoom from Box 1 to Box 2 over five seconds."
    static func reply(_ fixture: Fixture, patches: [String: Any] = [:]) throws -> Data {
        let args: [String: Any] = ["project_id": fixture.id.uuidString, "expected_revision": fixture.context.recording.revision,
            "start_edit_label": "Edit A", "from_box_label": "Box 1", "to_box_label": "Box 2", "duration_seconds": 5, "path": "direct"]
        let arguments = try JSONSerialization.data(withJSONObject: args.merging(patches) { _, value in value })
        let call: [String: Any] = ["type": "function", "function": ["name": "move_for_duration",
            "arguments": String(decoding: arguments, as: UTF8.self)]]
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [call]]]]])
    }
    static func plan(_ data: Data, fixture: Fixture, request: String = instruction) throws -> EditorCommandBatch {
        guard case let .commands(batch, summary) = try LocalEditPlanner.result(data, context: fixture.context, instruction: request) else {
            throw DurationMoveFailure.failed("expected complete duration plan")
        }
        try require(summary.contains("5-second") && summary.contains("Box 1") && summary.contains("Box 2") && summary.contains("Edit A"),
                    "summary uses spoken references and requested duration")
        return batch
    }
    static func checkPlanner() throws {
        let fixture = Fixture()
        let batch = try plan(reply(fixture), fixture: fixture)
        try require(batch.commands == [.moveForDuration(startEditID: fixture.startID, fromRegionID: fixture.source.id,
            toRegionID: fixture.target.id, duration: 5)], "named boxes and duration resolve to one complete typed command")
        _ = try plan(reply(fixture, patches: ["start_edit_label": ""]), fixture: fixture,
                     request: "Pan and zoom from Box 1 to Box 2 over five seconds at this edit.")
        _ = try plan(reply(fixture), fixture: fixture,
                     request: "At Edit A, pan and zoom from Box 1 to Box 2 over5 seconds.")
        for patch: [String: Any] in [["start_edit_label": "Edit Z"], ["from_box_label": "Box 99"],
                                     ["to_box_label": "Box 99"]] {
            guard case .clarification = try LocalEditPlanner.result(reply(fixture, patches: patch), context: fixture.context, instruction: instruction) else {
                throw DurationMoveFailure.failed("missing reference must clarify: \(patch.keys.sorted())")
            }
        }
        for duration in [3, 60] {
            guard case .rejectedPlan = try LocalEditPlanner.result(reply(fixture, patches: ["duration_seconds": duration]),
                context: fixture.context, instruction: instruction) else {
                throw DurationMoveFailure.failed("wrong duration must be repaired without asking the user to repeat the stated duration")
            }
        }
        for patch: [String: Any] in [["duration_seconds": true], ["path": "execute"], ["extra": "unsupported"]] {
            do {
                _ = try LocalEditPlanner.result(reply(fixture, patches: patch), context: fixture.context, instruction: instruction)
                throw DurationMoveFailure.failed("invalid model arguments accepted")
            } catch is EditorCommandError { }
        }
        let data = try LocalEditPlanner.payload(request: instruction, context: fixture.context)
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tools = payload["tools"] as! [[String: Any]]
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        try require(Set(names) == ["move_for_duration", "ask_clarification"], "duration language receives the focused duration contract")
        let selected = try LocalEditPlanner.payload(request: "At this edit, pan from box one to box two over a period of five seconds.", context: fixture.context)
        let selectedPayload = try JSONSerialization.jsonObject(with: selected) as! [String: Any]
        try require((selectedPayload["tools"] as! [[String: Any]]).count == 2, "natural spoken number words select duration tool")
        var conflict = fixture
        conflict.project.state.zoomKeyframes = [ZoomKeyframe(time: 3, scale: 2)]
        conflict.project.ensureReferences()
        guard case let .framingConflict(pending) = try LocalEditPlanner.result(reply(conflict), context: conflict.context, instruction: instruction) else {
            throw DurationMoveFailure.failed("intervening screen edit must clarify before applying")
        }
        try require(pending.question.contains("screen framing"), "conflict identifies the affected property")
    }

    static func checkNativeModel() async throws {
        let fixture = Fixture()
        let requests: [(String, Bool)] = [
            (instruction, false),
            ("Pan and zoom from box one to box two over a period of five seconds at this edit.", false),
            ("At Edit A, move from Box 1 to Box 2 over five seconds, returning to full frame halfway before moving into Box 2.", true)
        ]
        for (index, item) in requests.enumerated() {
            let payload = try LocalEditPlanner.payload(request: item.0, context: fixture.context)
            let response = try await LocalModelRuntime.shared.chat(payload: payload)
            let proposed = try plan(response, fixture: fixture, request: item.0)
            try require(proposed.commands == fixture.batch(viaFullFrame: item.1).commands,
                        "native model resolves complete duration request \(index + 1)")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let editor = ProjectEditor(project: fixture.project, url: directory.appendingPathComponent("native.framethrower"))
            try require(editor.save(), "save native metadata fixture")
            try EditorCommandDispatcher.apply(proposed, to: editor, projectID: fixture.id)
            let next = editor.project.state
            try require(next.zoomKeyframes.count == (item.1 ? 3 : 2) && next.zoomKeyframes.last?.time == 6 &&
                        (item.1 ? next.zoom(at: 3.5).scale == 1 : next.zoom(at: 3.5).scale > 2),
                        "native plan honors direct/pullback path and exact five-second arrival")
            try require(editor.project.undoHistory.count == 1 && editor.undo() && editor.project.state == fixture.project.state,
                        "native duration request saves and reverses as one ordinary Undo")
            try require(editor.redo() && editor.project.state == next, "native duration Redo preserves result and generated identity")
            print("Native Metal duration case \(index + 1) passed (complete path, generated arrival, durable Undo/Redo; no media).")
        }
    }
}
