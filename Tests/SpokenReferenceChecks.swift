import Foundation

private enum SpokenCheckError: Error { case failed(String) }

@main
private struct SpokenReferenceChecks {
    @MainActor
    static func main() async throws {
        try checkNamedPlan()
        try checkMissingAndConflictingReferences()
        try checkBoundedContext()
        try checkOutsideWork()
        try checkAnchorOnlyPlan()
        try checkInstructionCoverage()
        if let index = CommandLine.arguments.firstIndex(of: "--dump-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            try dumpFixtures(to: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--verify-fixtures"), CommandLine.arguments.indices.contains(index + 1) {
            try verifyFixtures(in: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
        }
        if CommandLine.arguments.contains("--model") { try await checkModel() }
        if CommandLine.arguments.contains("--model") || CommandLine.arguments.contains("--anchor-model") {
            try await checkAnchorModel()
        }
        print("Spoken reference checks passed (stable edit/box names, cross-frame associations, named movements, missing references, collisions, durable atomic Undo/Redo; no video).")
    }

    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw SpokenCheckError.failed(message) }
    }

    private static func reply(_ fixture: Fixture, changes: [[String: String]]) throws -> Data {
        let arguments = try JSONSerialization.data(withJSONObject: ["project_id": fixture.id.uuidString,
            "expected_revision": fixture.context.recording.revision, "changes": changes])
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [
            ["type": "function", "function": ["name": "frame_edits", "arguments": String(decoding: arguments, as: UTF8.self)]]
        ]]]]])
    }

    private static func changes() -> [[String: String]] {
        [["edit_label": "Edit A", "box_label": "Box 1", "from_edit_label": ""],
         ["edit_label": "Edit B", "box_label": "Box 2", "from_edit_label": "Edit A"]]
    }

    private static let namedInstruction = "At Edit A, frame Box 1. Between Edit A and Edit B, gracefully zoom out to full frame, then smoothly into Box 2, arriving at Edit B."

    private static func commands(_ result: LocalEditResult) throws -> EditorCommandBatch {
        guard case let .commands(batch, _) = result else { throw SpokenCheckError.failed("expected named commands") }
        return batch
    }

    @MainActor
    private static func checkNamedPlan() throws {
        let fixture = try Fixture()
        let result = try LocalEditPlanner.result(reply(fixture, changes: changes()), context: fixture.context)
        let plan = try commands(result)
        try require(plan.commands == [.reviseFraming(editID: fixture.a.id, regionID: fixture.box1.id),
            .moveBetweenEdits(fromEditID: fixture.a.id, toEditID: fixture.b.id, regionID: fixture.box2.id)],
            "spoken labels resolve to exact existing edit and box identities")
        if case let .commands(_, summary) = result {
            try require(summary.contains("Edit A") && summary.contains("Edit B") && summary.contains("Box 2"),
                        "result uses visible names instead of fractional seconds")
        }
        let next = try EditorCommandDispatcher.prepare(plan, for: fixture.project, projectID: fixture.id)
        try require(next.zoomKeyframes.count == 3 && next.zoomKeyframes[0].id == fixture.a.id &&
                    next.zoomKeyframes[2].id == fixture.b.id, "path preserves endpoints and adds one intermediate view")
        try require(next.zoom(at: 1) == fixture.box1.rect.framing() && next.zoom(at: 4).scale == 1 &&
                    next.zoom(at: 7) == fixture.box2.rect.framing(), "path goes from first box through full frame to second box at named destination")
        try require(next.zoom(at: 2).scale > 1 && next.zoom(at: 6).scale > 1,
                    "both legs use the shared smooth movement algorithm")
        let out = next.zoomKeyframes[1], arrival = next.zoomKeyframes[2]
        try require(out.transition == .smooth && arrival.transition == .smooth && out.duration == 3 && arrival.duration == 3,
                    "midpoint path allocates complete smooth legs without spoken timestamps")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("named.framethrower")
        try JSONEncoder().encode(fixture.project).write(to: url)
        let editor = try ProjectEditor.open(url: url)
        try EditorCommandDispatcher.apply(plan, to: editor, projectID: fixture.id)
        let edited = editor.project.state
        try require(editor.project.undoHistory.count == 1 && (try ProjectEditor.open(url: url).project.state) == edited,
                    "entire named request saves as one normal edit")
        try require(editor.undo() && editor.project.state == fixture.project.state, "one Undo restores all named operations")
        try require(editor.redo() && editor.project.state == edited, "one Redo restores named operations")
        let full = try commands(LocalEditPlanner.result(reply(fixture, changes: [
            ["edit_label": "Edit B", "box_label": "full_frame", "from_edit_label": ""]
        ]), context: fixture.context))
        let fullState = try EditorCommandDispatcher.prepare(full, for: fixture.project, projectID: fixture.id)
        try require(fullState.zoomKeyframes[1].id == fixture.b.id && fullState.zoomKeyframes[1].scale == 1 &&
                    fullState.zoomKeyframes[1].duration == fixture.b.duration, "full-frame target at named edit preserves identity and movement")
    }

    private static func checkMissingAndConflictingReferences() throws {
        let fixture = try Fixture()
        for change in [
            ["edit_label": "Edit Z", "box_label": "Box 1", "from_edit_label": ""],
            ["edit_label": "Edit B", "box_label": "Box 99", "from_edit_label": ""],
            ["edit_label": "Edit B", "box_label": "Box 2", "from_edit_label": "Edit Z"],
            ["edit_label": "Edit A", "box_label": "Box 2", "from_edit_label": "Edit B"]
        ] {
            guard case .clarification = try LocalEditPlanner.result(reply(fixture, changes: [change]), context: fixture.context) else {
                throw SpokenCheckError.failed("unknown or reversed references must ask without edits")
            }
        }
        var deleted = fixture
        deleted.context.recording.state.regions.removeFirst()
        guard case .clarification = try LocalEditPlanner.result(reply(deleted, changes: changes()), context: deleted.context) else {
            throw SpokenCheckError.failed("deleted box label cannot redirect to another box")
        }
        var intervening = fixture
        intervening.context.recording.state.zoomKeyframes.insert(ZoomKeyframe(time: 3, scale: 1.5), at: 1)
        guard case .clarification = try LocalEditPlanner.result(reply(intervening, changes: changes()), context: intervening.context) else {
            throw SpokenCheckError.failed("intervening screen edits are not silently overwritten")
        }
    }

    private static func checkBoundedContext() throws {
        var fixture = try Fixture()
        // A late insertion gets a new label; A and B remain addressable by name
        // even after they fall outside the default context window.
        for index in 0..<30 {
            fixture.context.recording.state.zoomKeyframes.append(ZoomKeyframe(time: 7.1 + Double(index) * 0.1, scale: 1.2))
            fixture.context.recording.state.regions.append(EditorRegion(time: 8,
                rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), note: String(repeating: "x", count: 4_000)))
        }
        fixture.context.recording.references.register(state: fixture.context.recording.state)
        let payload = try LocalEditPlanner.payload(request: "Between A and B, zoom out and into Box 2.", context: fixture.context)
        let decoded = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let messages = decoded["messages"] as! [[String: String]]
        let user = messages[1]["content"]!
        try require(user.contains("Edit A") && user.contains("Edit B") && user.contains("Box 2"), "explicitly referenced old labels remain in bounded context")
        try require(!user.contains(String(repeating: "x", count: 121)), "notes are bounded separately from project metadata")
        try require(user.contains("edit_label") && user.contains("source_rect"), "model sees box-to-edit association and exact original geometry")
        let tools = decoded["tools"] as! [[String: Any]]
        try require(tools.count == 2 && tools.allSatisfy { ($0["function"] as? [String: Any])?["name"] as? String != "plan_sequence" },
                    "named references offer identity-preserving tools instead of reconstructing numeric timelines")
    }

    private static func checkOutsideWork() throws {
        let fixture = try Fixture()
        let batch = EditorCommandBatch(projectID: fixture.id, revision: fixture.context.recording.revision,
            commands: [.moveBetweenEdits(fromEditID: fixture.a.id, toEditID: fixture.b.id, regionID: fixture.box2.id)])
        let next = try EditorCommandDispatcher.prepare(batch, for: fixture.project, projectID: fixture.id)
        try require(next.zoom(at: 0.5) == fixture.project.state.zoom(at: 0.5) && next.zoomKeyframes[0] == fixture.a,
                    "adding a path between named endpoints leaves incoming start movement untouched")
        let encoded = try JSONEncoder().encode(batch)
        try require(try JSONDecoder().decode(EditorCommandBatch.self, from: encoded) == batch, "named path is a normal provider-independent command")
        var occupied = fixture.project
        occupied.state.zoomKeyframes.insert(ZoomKeyframe(time: 3, scale: 2), at: 1)
        let conflict = EditorCommandBatch(projectID: fixture.id,
            revision: try EditorCommandDispatcher.revision(for: occupied), commands: batch.commands)
        do {
            _ = try EditorCommandDispatcher.prepare(conflict, for: occupied, projectID: fixture.id)
            throw SpokenCheckError.failed("typed API must independently protect intervening edits")
        } catch EditorCommandError.invalid(let message) {
            try require(message.contains("between"), "conflict rejects for the intervening framing edit")
        }
        var crossing = fixture.project
        crossing.cameraFilename = "unopened-camera.mov"
        let camera = PIPKeyframe(time: 2, placement: PIPPlacement())
        crossing.state.pipKeyframes.append(camera)
        crossing.state.zoomKeyframes[1].duration = 6
        let crossingBatch = EditorCommandBatch(projectID: fixture.id,
            revision: try EditorCommandDispatcher.revision(for: crossing),
            commands: [.moveBetweenEdits(fromEditID: camera.id, toEditID: fixture.b.id, regionID: fixture.box2.id)])
        do {
            _ = try EditorCommandDispatcher.prepare(crossingBatch, for: crossing, projectID: fixture.id)
            throw SpokenCheckError.failed("path cannot flatten existing movement before a camera-only starting edit")
        } catch EditorCommandError.invalid(let message) {
            try require(message.contains("crosses"), "existing incoming movement outside the chosen interval stays untouched")
        }
        var destinationCrossing = fixture.project
        destinationCrossing.cameraFilename = "unopened-camera.mov"
        let destination = PIPKeyframe(time: 7, placement: PIPPlacement())
        destinationCrossing.state.pipKeyframes.append(destination)
        destinationCrossing.state.zoomKeyframes[1] = ZoomKeyframe(time: 10, scale: 2, transition: .smooth, duration: 5)
        let destinationBatch = EditorCommandBatch(projectID: fixture.id,
            revision: try EditorCommandDispatcher.revision(for: destinationCrossing),
            commands: [.moveBetweenEdits(fromEditID: fixture.a.id, toEditID: destination.id, regionID: fixture.box2.id)])
        do {
            _ = try EditorCommandDispatcher.prepare(destinationBatch, for: destinationCrossing, projectID: fixture.id)
            throw SpokenCheckError.failed("path cannot rewrite a later movement already crossing a camera-only destination")
        } catch EditorCommandError.invalid(let message) {
            try require(message.contains("crosses the destination"), "destination conflict is rejected before rewriting later motion")
        }
        var accepted = fixture.project
        accepted.state.zoomKeyframes[1].scale = fixture.box2.rect.framing().scale
        accepted.state.zoomKeyframes[1].x = fixture.box2.rect.framing().x
        accepted.state.zoomKeyframes[1].y = fixture.box2.rect.framing().y
        accepted.state.zoomKeyframes.append(ZoomKeyframe(time: 10, scale: 1.2, x: 0.4, y: 0.4,
                                                        transition: .smooth, duration: 0.6))
        let acceptedBatch = EditorCommandBatch(projectID: fixture.id,
            revision: try EditorCommandDispatcher.revision(for: accepted), commands: batch.commands)
        let acceptedPath = try EditorCommandDispatcher.prepare(acceptedBatch, for: accepted, projectID: fixture.id)
        for time in [0.0, 0.4, 0.9, 7.0, 7.1, 8.0, 9.7, 10.0, 11.0] {
            try require(acceptedPath.zoom(at: time) == accepted.state.zoom(at: time),
                        "accepted path leaves source samples before its start and following its unchanged target untouched")
        }
    }

    @MainActor
    private static func checkModel() async throws {
        let fixture = try Fixture()
        let payload = try LocalEditPlanner.payload(request: namedInstruction, context: fixture.context)
        let started = Date()
        let response = try await LocalModelRuntime.shared.chat(payload: payload)
        let proposed = try commands(LocalEditPlanner.result(response, context: fixture.context, instruction: namedInstruction))
        let expected = try commands(LocalEditPlanner.result(reply(fixture, changes: changes()), context: fixture.context))
        try require(proposed.commands == expected.commands, "native model resolves named edits and boxes into complete ordered path")
        let next = try EditorCommandDispatcher.prepare(proposed, for: fixture.project, projectID: fixture.id)
        try require(next.zoomKeyframes.count == 3 && next.zoom(at: 4).scale == 1 && next.zoom(at: 7) == fixture.box2.rect.framing(),
                    "actual native model plan follows both named source frames and correct destination timing")
        let spokenInstruction = "At edit A, frame box one. Then, between A and B, zoom out smoothly and back into box two, arriving at B."
        let spokenPayload = try LocalEditPlanner.payload(request: spokenInstruction, context: fixture.context)
        let spokenResponse = try await LocalModelRuntime.shared.chat(payload: spokenPayload)
        let spoken = try commands(LocalEditPlanner.result(spokenResponse, context: fixture.context, instruction: spokenInstruction))
        try require(spoken.commands == expected.commands, "native model resolves spoken number words to the same stable box identities")
        let unknownPayload = try LocalEditPlanner.payload(request: "At Edit Z, zoom into Box 1.", context: fixture.context)
        let unknownResponse = try await LocalModelRuntime.shared.chat(payload: unknownPayload)
        guard case .clarification = try LocalEditPlanner.result(unknownResponse, context: fixture.context) else {
            throw SpokenCheckError.failed("native model must clarify an unknown named edit rather than edit a different point")
        }
        print(String(format: "Native Metal spoken-reference integration passed (named edits, cross-frame boxes, spoken number words, complete smooth path, unknown-edit clarification; %.2f seconds).", Date().timeIntervalSince(started)))
    }

    @MainActor
    private static func checkAnchorOnlyPlan() throws {
        let fixture = try Fixture(anchorsOnly: true)
        try require(fixture.project.state.zoomKeyframes.isEmpty && fixture.project.state.editAnchors.count == 2,
                    "drawing boxes at fresh times creates reference-only edits without changing screen framing")
        try require(fixture.box1.editID == fixture.a.id && fixture.box2.editID == fixture.b.id &&
                    fixture.context.recording.references.editLabel(for: fixture.a.id) == "Edit A" &&
                    fixture.context.recording.references.boxLabel(for: fixture.box2.id) == "Box 2",
                    "production drawing helper links both boxes to stable named anchors")
        let plan = try commands(LocalEditPlanner.result(reply(fixture, changes: changes()), context: fixture.context))
        try checkAppliedAnchorPlan(plan, fixture: fixture)
    }

    private static func checkInstructionCoverage() throws {
        let fixture = try Fixture(anchorsOnly: true)
        let complete = try LocalEditPlanner.result(reply(fixture, changes: changes()), context: fixture.context, instruction: namedInstruction)
        _ = try commands(complete)
        let incomplete: [[[String: String]]] = [
            [changes()[1]],
            [changes()[0]],
            [changes()[0], ["edit_label": "Edit B", "box_label": "Box 2", "from_edit_label": ""]]
        ]
        for changes in incomplete {
            guard case .clarification = try LocalEditPlanner.result(reply(fixture, changes: changes),
                context: fixture.context, instruction: namedInstruction) else {
                throw SpokenCheckError.failed("partial named plans must not apply after omitting a requested box, edit or outward leg")
            }
        }
        var extra = fixture
        extra.project.state.editAnchors.append(EditAnchor(time: 10))
        extra.project.references.register(state: extra.project.state)
        extra.context.recording.state = extra.project.state
        extra.context.recording.references = extra.project.references
        extra.context.recording.revision = try EditorCommandDispatcher.revision(for: extra.project)
        let extraChanges = changes() + [["edit_label": "Edit C", "box_label": "Box 1", "from_edit_label": ""]]
        guard case .clarification = try LocalEditPlanner.result(reply(extra, changes: extraChanges),
            context: extra.context, instruction: namedInstruction) else {
            throw SpokenCheckError.failed("extra unrequested edit targets must not apply alongside otherwise complete requested edits")
        }
        let resolvedChoice = try LocalEditPlanner.result(reply(fixture, changes: [
            ["edit_label": "Edit B", "box_label": "Box 2", "from_edit_label": ""]
        ]), context: fixture.context, instruction: "Use Box 2.")
        try require(try commands(resolvedChoice).commands == [.reviseFraming(editID: fixture.b.id, regionID: fixture.box2.id)],
                    "coverage of a clarification answer checks the resolved choice, without demanding old alternatives")
        let numericArguments: [String: Any] = ["project_id": fixture.id.uuidString,
            "expected_revision": fixture.context.recording.revision, "start_seconds": 1,
            "steps": [["region_id": fixture.box1.id.uuidString, "move_seconds": 0.5, "hold_seconds": 0]]]
        let encoded = try JSONSerialization.data(withJSONObject: numericArguments)
        let numericReply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [
            ["type": "function", "function": ["name": "plan_sequence", "arguments": String(decoding: encoded, as: UTF8.self)]]
        ]]]]])
        let numeric = try LocalEditPlanner.result(numericReply, context: fixture.context,
            instruction: "At one second, zoom into Box 1 over half a second.")
        try require(try commands(numeric).commands.contains(.frameRegion(regionID: fixture.box1.id, time: 1.5,
            motion: EditorCommandMotion(transition: .smooth, duration: 0.5))),
            "explicit numeric box framing remains valid with production instruction checking enabled")
    }

    @MainActor
    private static func dumpFixtures(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var numeric = try Fixture()
        numeric.project.state.zoomKeyframes = []
        numeric.context.recording.state = numeric.project.state
        numeric.context.recording.revision = try EditorCommandDispatcher.revision(for: numeric.project)
        numeric.context.selectedEditID = nil
        numeric.context.selectedRegionID = numeric.box1.id
        let numericInstruction = "At 1 second, zoom into the selected scribble over 0.5 seconds, hold that framing for 4 seconds, then zoom back out to full frame over 1 second."
        let numericPlan = EditorCommandBatch(projectID: numeric.id, revision: numeric.context.recording.revision,
            commands: [.holdFraming(time: 1), .frameRegion(regionID: numeric.box1.id, time: 1.5,
                motion: EditorCommandMotion(transition: .smooth, duration: 0.5)),
                .frameRegion(regionID: numeric.box1.id, time: 5.5, motion: EditorCommandMotion(transition: .jump)),
                .fullFrame(time: 6.5, motion: EditorCommandMotion(transition: .smooth, duration: 1))])
        for (name, fixture, instruction, expected) in [
            ("anchors", try Fixture(anchorsOnly: true), namedInstruction, Optional<EditorCommandBatch>.none),
            ("named", try Fixture(), namedInstruction, Optional<EditorCommandBatch>.none),
            ("numeric", numeric, numericInstruction, Optional(numericPlan))
        ] {
            let plan = try expected ?? commands(LocalEditPlanner.result(reply(fixture, changes: changes()),
                context: fixture.context, instruction: instruction))
            let files: [(String, Data)] = [
                ("payload", try LocalEditPlanner.payload(request: instruction, context: fixture.context)),
                ("context", try encoder.encode(fixture.context)), ("project", try encoder.encode(fixture.project)),
                ("expected", try encoder.encode(plan)), ("instruction", Data(instruction.utf8))
            ]
            for (kind, data) in files {
                let url = directory.appendingPathComponent(name + "." + kind + (kind == "instruction" ? ".txt" : ".json"))
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        print("Dumped three synthetic production planner fixtures to the private local directory.")
    }

    @MainActor
    private static func verifyFixtures(in directory: URL) throws {
        let decoder = JSONDecoder()
        for name in ["anchors", "named", "numeric"] {
            let context = try decoder.decode(LocalEditContext.self, from: Data(contentsOf: directory.appendingPathComponent(name + ".context.json")))
            let project = try decoder.decode(RecordingProject.self, from: Data(contentsOf: directory.appendingPathComponent(name + ".project.json")))
            let expected = try decoder.decode(EditorCommandBatch.self, from: Data(contentsOf: directory.appendingPathComponent(name + ".expected.json")))
            let instruction = try String(contentsOf: directory.appendingPathComponent(name + ".instruction.txt"), encoding: .utf8)
            let response = try Data(contentsOf: directory.appendingPathComponent(name + ".response.json"))
            let actual = try commands(LocalEditPlanner.result(response, context: context, instruction: instruction))
            try require(actual.commands == expected.commands, "production response omitted or changed a required action in " + name)
            _ = try EditorCommandDispatcher.prepare(actual, for: project, projectID: context.recording.projectID)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let url = temporary.appendingPathComponent("fixture.framethrower")
            try JSONEncoder().encode(project).write(to: url)
            let editor = try ProjectEditor.open(url: url)
            try EditorCommandDispatcher.apply(actual, to: editor, projectID: context.recording.projectID)
            let changed = editor.project.state
            try require(editor.project.undoHistory.count == 1 && editor.undo() && editor.project.state == project.state &&
                        editor.redo() && editor.project.state == changed, "external model fixture must preserve atomic durable Undo/Redo")
            print("Verified external local model fixture: " + name)
        }
    }

    @MainActor
    private static func checkAppliedAnchorPlan(_ plan: EditorCommandBatch, fixture: Fixture) throws {
        let original = fixture.project
        let prepared = try EditorCommandDispatcher.prepare(plan, for: original, projectID: fixture.id)
        try require(prepared.zoomKeyframes.count == 3 && prepared.zoomKeyframes.first?.id == fixture.a.id &&
                    prepared.zoomKeyframes.last?.id == fixture.b.id,
                    "first real framing operations reuse the reference-only endpoint identities")
        try require(prepared.editAnchors == original.state.editAnchors && prepared.regions == original.state.regions &&
                    prepared.pipKeyframes == original.state.pipKeyframes && prepared.presentation == original.state.presentation,
                    "framing an anchor-only request preserves source boxes, anchors, camera placement and canvas")
        try require(prepared.timedEdits(includeCamera: true).count == 3,
                    "materialized zooms and reference anchors remain one logical edit at each endpoint")
        try require(prepared.zoom(at: 1) == fixture.box1.rect.framing() && prepared.zoom(at: 4).scale == 1 &&
                    prepared.zoom(at: 7) == fixture.box2.rect.framing(),
                    "reference-only workflow produces the complete two-box path with correct arrival times")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("anchors.framethrower")
        try JSONEncoder().encode(original).write(to: url)
        let editor = try ProjectEditor.open(url: url)
        try EditorCommandDispatcher.apply(plan, to: editor, projectID: fixture.id)
        let edited = editor.project.state
        try require(editor.project.undoHistory.count == 1 && editor.project.screenFilename == original.screenFilename &&
                    editor.project.cameraFilename == original.cameraFilename && editor.project.cursorFilename == original.cursorFilename &&
                    editor.project.cameraOffset == original.cameraOffset,
                    "anchor-first instruction is one transaction and preserves all original source references")
        try require(try ProjectEditor.open(url: url).project.state == edited, "anchor-first instruction saves ordinary project metadata")
        try require(editor.undo() && editor.project.state == original.state,
                    "one Undo restores reference-only boxes without removing their names or source-frame associations")
        try require(editor.redo() && editor.project.state == edited, "one Redo restores the complete anchor-first request")
    }

    @MainActor
    private static func checkAnchorModel() async throws {
        let fixture = try Fixture(anchorsOnly: true)
        let payload = try LocalEditPlanner.payload(request: namedInstruction, context: fixture.context)
        let response = try await LocalModelRuntime.shared.chat(payload: payload)
        let proposed = try commands(LocalEditPlanner.result(response, context: fixture.context, instruction: namedInstruction))
        let expected = try commands(LocalEditPlanner.result(reply(fixture, changes: changes()), context: fixture.context))
        if proposed.commands != expected.commands {
            for command in proposed.commands {
                switch command {
                case let .reviseFraming(editID, regionID):
                    print("Anchor mismatch metadata: revise start=\(editID == fixture.a.id), destination=\(editID == fixture.b.id), firstBox=\(regionID == fixture.box1.id), secondBox=\(regionID == fixture.box2.id)")
                case let .moveBetweenEdits(from, to, regionID):
                    print("Anchor mismatch metadata: path start=\(from == fixture.a.id), destination=\(to == fixture.b.id), secondBox=\(regionID == fixture.box2.id)")
                default: print("Anchor mismatch metadata: other supported action")
                }
            }
            fflush(nil)
        }
        try require(proposed.commands == expected.commands, "native model uses named boxes and reference-only edits before any zoom exists")
        try checkAppliedAnchorPlan(proposed, fixture: fixture)
        print("Native Metal anchor-first workflow passed (production box drawing, named references, complete framing path, saved source references, atomic Undo/Redo; no media).")
    }

    private struct Fixture {
        let id = UUID(uuidString: "331EE7A8-FEA2-445B-9C4B-7A410D036DFC")!
        var a = ZoomKeyframe(time: 1, scale: 1.4, x: 0.3, y: 0.4, transition: .smooth, duration: 0.5)
        var b = ZoomKeyframe(time: 7, scale: 1.6, x: 0.6, y: 0.6, transition: .smooth, duration: 0.8)
        var box1: EditorRegion
        var box2: EditorRegion
        var project: RecordingProject
        var context: LocalEditContext
        init(anchorsOnly: Bool = false) throws {
            project = RecordingProject(screenFilename: "unopened-original.mov", duration: 12)
            if anchorsOnly {
                box1 = project.state.addRegion(rect: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.3), at: 1)
                box2 = project.state.addRegion(rect: .init(x: 0.6, y: 0.1, width: 0.3, height: 0.2), at: 7)
                a.id = box1.editID!
                b.id = box2.editID!
                project.cameraFilename = "unopened-camera.mov"
                project.cursorFilename = "unopened-pointer.json"
                project.cameraOffset = 0.2
            } else {
                box1 = EditorRegion(time: 1, rect: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.3), editID: a.id)
                box2 = EditorRegion(time: 7, rect: .init(x: 0.6, y: 0.1, width: 0.3, height: 0.2), editID: b.id)
                project.state.zoomKeyframes = [a, b]
                project.state.regions = [box1, box2]
            }
            project.references.register(state: project.state)
            context = LocalEditContext(recording: EditorCommandContext(projectID: id,
                revision: try EditorCommandDispatcher.revision(for: project), duration: 12, state: project.state,
                references: project.references), playhead: 7, selectedRegionID: box2.id, selectedEditID: b.id,
                videoProcessingAvailable: false)
        }
    }
}
