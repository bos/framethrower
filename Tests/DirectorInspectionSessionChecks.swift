import Foundation
import Darwin

private actor InspectionTransport {
    private(set) var payloads: [Data] = []
    private var waiting: [Int: CheckedContinuation<Data, any Error>] = [:]
    func send(_ payload: Data) async throws -> Data {
        let index = payloads.count; payloads.append(payload)
        return try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }
    func reply(_ index: Int, data: Data) {
        waiting.removeValue(forKey: index)?.resume(returning: data)
    }
}

@main @MainActor
struct DirectorInspectionSessionChecks {
    enum Failure: Error { case failed(String) }
    static func response(_ index: Int, name: String, args: [String: Any], callID: String? = nil) throws -> Data {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "tool_calls": [
            ["id": callID ?? "inspection-call-\(index)", "type": "function", "function": ["name": name, "arguments": arguments]]
        ]]]]])
    }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
    static func wait(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw Failure.failed("Timed out waiting for fixture transport")
    }
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Inspection session check failed: \(error)\n".utf8))
            exit(1)
        }
    }
    static func progress(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    static func run() async throws {
        progress("Checking observed framing")
        try await checkRoute(conflicting: false)
        progress("Checking shared conflict review")
        try await checkRoute(conflicting: true)
        progress("Checking lookup bounds")
        try await checkBoundedLookups()
        progress("Checking read-only answer")
        try await checkReadOnlyAnswer()
        progress("Checking dense context budget")
        try await checkDenseContinuationBudget()
        progress("Checking image/tool identity")
        try await checkImagePairIdentity()
        try checkManagementCannotBecomeObservedFraming()
        print("Director inspection session checks passed (on-demand context, real call/result continuation, linked source-pixel framing, shared conflict review and one Undo, bounded lookup loop; synthetic metadata only).")
    }
    static func checkImagePairIdentity() async throws {
        let (editor, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aO1sAAAAASUVORK5CYII=")!
        let cache = DirectorInspectionCache(syntheticFrameProvider: { time in
            DirectorInspectionFrame(sourceTime: time, pixelWidth: 1, pixelHeight: 1, png: png)
        })
        let transport = InspectionTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) }, provider: .claudeSonnet, inspectionCache: cache)
        session.instruction = "Inspect the source frame at one second."
        session.submit(editor: editor, playhead: 1, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 1 }
        var args = try base(session, editor); args["time_seconds"] = 1
        await transport.reply(0, data: try response(0, name: "inspect_frame", args: args, callID: ""))
        try await wait { await transport.payloads.count == 2 || !session.isBusy }
        try require(session.errorMessage == nil && session.isBusy, "An explicitly injected static frame can continue without media processing: \(session.errorMessage ?? "")")
        let root = try JSONSerialization.jsonObject(with: await transport.payloads[1]) as! [String: Any]
        let messages = root["messages"] as! [[String: Any]]
        let actualID = messages.last { $0["role"] as? String == "tool" }?["tool_call_id"] as! String
        let attachment = messages.last { $0["content"] is [[String: Any]] }?["content"] as! [[String: Any]]
        let metadata = try JSONSerialization.jsonObject(with: Data((attachment.first?["text"] as! String).utf8)) as! [String: Any]
        try require(!actualID.isEmpty && metadata["originating_tool_call_id"] as? String == actualID,
                    "Image attachment identity follows the actual normalized stored tool pair")
        try require(session.inspectedFrames.count == 1 && !editor.canUndo,
                    "The inspected static image is available to conversation UI without creating an edit")
        let content = messages.last { $0["role"] as? String == "tool" }?["content"] as! String
        let outcome = try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
        let observation = outcome["inspection"] as! [String: Any]
        var report = try base(session, editor)
        report["observation_id"] = observation["observation_id"]; report["summary"] = "Inspected the synthetic source frame."
        await transport.reply(1, data: try response(1, name: "report_observation", args: report))
        try await wait { !session.isBusy }
        try require(session.errorMessage == nil && !editor.canUndo, "A frame inspection can finish as a read-only answer")
    }
    static func checkDenseContinuationBudget() async throws {
        let (editor, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var metadata = scene()
        metadata.snapshots[0].availability = .init(windows: true, accessibilityTrusted: true, accessibilityCollected: true)
        metadata.snapshots[0].elements = (0..<128).map { index in
            RecordedSceneElement(id: "control-\(index)", processID: 123, windowID: 42,
                role: "AXStaticText", label: String(repeating: "界", count: 512),
                frame: CGRect(x: 250, y: 150, width: 100, height: 20), isMenu: false, textRedacted: false)
        }
        var state = editor.project.state
        state.zoomKeyframes = (1...6).map { ZoomKeyframe(time: Double($0), scale: 1.5, x: 0.5, y: 0.5) }
        try require(editor.commit(state, name: "Fixture timeline"), "Set up ordinary current editing state")
        let historyCount = editor.project.undoHistory.count
        let transport = InspectionTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) }, inspectionCache: DirectorInspectionCache(scene: metadata))
        session.instruction = "Which controls are recorded in this window?"
        session.submit(editor: editor, playhead: 1, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 1 || !session.isBusy }
        try require(session.isBusy, "The initial lookup request fits with realistic current edit state")
        var args = try base(session, editor)
        args["time_seconds"] = 1; args["detail"] = "controls"; args["window_id"] = 42; args["limit"] = 16
        await transport.reply(0, data: try response(0, name: "inspect_scene", args: args))
        try await wait { await transport.payloads.count == 2 || !session.isBusy }
        try require(session.isBusy && session.errorMessage == nil,
                    "A dense bounded scene result retains its actual call/result within the continuation budget")
        let next = await transport.payloads[1]
        try require(next.count <= 20_000, "The complete continuation remains in the text budget")
        let root = try JSONSerialization.jsonObject(with: next) as! [String: Any]
        let messages = root["messages"] as! [[String: Any]]
        let text = messages.last { $0["role"] as? String == "tool" }?["content"] as! String
        let outcome = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let observation = outcome["inspection"] as! [String: Any]
        try require((observation["omitted"] as? Int ?? 0) > 0 && (observation["returned"] as? Int ?? 0) > 0,
                    "Dense results report omissions while retaining a usable requested subset")
        var report = try base(session, editor)
        report["observation_id"] = observation["observation_id"]
        report["summary"] = "Only a bounded subset of the recorded controls was inspected."
        await transport.reply(1, data: try response(1, name: "report_observation", args: report))
        try await wait { !session.isBusy }
        try require(session.errorMessage == nil && editor.project.undoHistory.count == historyCount,
                    "A dense read-only conversation adds no Undo entry")
    }
    static func checkReadOnlyAnswer() async throws {
        let (editor, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = InspectionTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) }, inspectionCache: DirectorInspectionCache(scene: scene()))
        session.instruction = "Which browser is visible?"
        session.submit(editor: editor, playhead: 1, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 1 }
        var args = try base(session, editor)
        args["time_seconds"] = 1; args["detail"] = "windows"; args["limit"] = 8
        await transport.reply(0, data: try response(0, name: "inspect_scene", args: args))
        try await wait { await transport.payloads.count == 2 }
        let root = try JSONSerialization.jsonObject(with: await transport.payloads[1]) as! [String: Any]
        let messages = root["messages"] as! [[String: Any]]
        let content = messages.last { $0["role"] as? String == "tool" }?["content"] as! String
        let outcome = try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
        let observation = outcome["inspection"] as! [String: Any]
        var report = try base(session, editor)
        report["observation_id"] = observation["observation_id"]
        report["summary"] = "The recorded window belongs to Fixture Browser."
        await transport.reply(1, data: try response(1, name: "report_observation", args: report))
        try await wait { !session.isBusy }
        try require(session.errorMessage == nil && !session.awaitsClarification && !editor.canUndo &&
                    session.notice == "The recorded window belongs to Fixture Browser.",
                    "An observation can answer a question without inventing an edit or asking an unnecessary clarification")
    }
    static func checkManagementCannotBecomeObservedFraming() throws {
        let (editor, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectID = UUID()
        let recording = try EditorCommandDispatcher.context(editor: editor, projectID: projectID)
        let context = LocalEditContext(recording: recording, playhead: 0, videoProcessingAvailable: false,
            inspectionCapabilities: .init(scene: true, frame: false))
        let args: [String: Any] = ["version": 1, "project_id": projectID.uuidString,
            "expected_revision": recording.revision, "observation_id": UUID().uuidString,
            "target": ["kind": "recorded", "id": "window:42"],
            "margin_pixels": 30, "time_seconds": 2, "duration_seconds": 1]
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [[
            "type": "function", "function": ["name": "frame_observation", "arguments": arguments]
        ]]]]]])
        for instruction in ["Delete Box 4", "Give Box 1 the note Search results", "Undo my last change", "Move Ref B to two seconds"] {
            let payload = try LocalEditPlanner.payload(request: instruction, context: context)
            let root = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            let names = (root["tools"] as! [[String: Any]]).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            try require(!names.contains("frame_observation") && names.contains("inspect_scene"),
                        "Management instructions may inspect but cannot substitute an observed framing mutation")
            guard case .rejectedPlan = try LocalEditPlanner.result(response, context: context,
                instruction: instruction, routingRequest: instruction) else {
                throw Failure.failed("An observed framing action bypassed the literal management intent")
            }
        }
    }
    static func scene() -> RecordedScene {
        let source = RecordedSceneSource(kind: .display, displayID: 1,
            globalBounds: CGRect(x: 0, y: 0, width: 1000, height: 600), pixelWidth: 1000, pixelHeight: 600)
        let window = RecordedSceneWindow(id: 42, processID: 123, application: "Fixture Browser",
            title: "SYNTHETIC_BROWSER_TITLE", frame: CGRect(x: 250, y: 150, width: 400, height: 240),
            zOrder: 0, isFocused: true, isRecorderApplication: false, occlusionEstimate: 0)
        let snapshot = RecordedSceneSnapshot(time: 0, sourceBounds: source.globalBounds,
            availability: .init(windows: true, accessibilityTrusted: false, accessibilityCollected: false),
            windows: [window], elements: [])
        return RecordedScene(duration: 10, source: source, snapshots: [snapshot])
    }
    static func fixture(conflicting: Bool = false) throws -> (ProjectEditor, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inspection-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var project = RecordingProject(screenFilename: "never-opened.mov", duration: 10)
        if conflicting { project.state.zoomKeyframes = [ZoomKeyframe(time: 1.5, scale: 1.5, x: 0.5, y: 0.5, duration: 0.8)] }
        return (ProjectEditor(project: project, url: dir.appendingPathComponent("fixture.framethrower")), dir)
    }
    static func base(_ session: EditorAssistantSession, _ editor: ProjectEditor) throws -> [String: Any] {
        ["version": 1, "project_id": session.projectID.uuidString,
         "expected_revision": try EditorCommandDispatcher.revision(for: editor.project)]
    }
    static func checkRoute(conflicting: Bool) async throws {
        let (editor, directory) = try fixture(conflicting: conflicting)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = editor.project.state
        let transport = InspectionTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) },
            inspectionCache: DirectorInspectionCache(scene: scene()))
        session.instruction = "Frame the browser with a 30 pixel border, arriving at two seconds."
        session.submit(editor: editor, playhead: 0, regionID: nil, editID: nil)
        try await wait { await transport.payloads.count == 1 || !session.isBusy }
        try require(session.isBusy, "Initial observed target request failed: \(session.errorMessage ?? "unknown error")")
        let initial = await transport.payloads[0]
        progress("Initial payload bytes: \(initial.count)")
        try require(!String(decoding: initial, as: UTF8.self).contains("SYNTHETIC_BROWSER_TITLE"), "No scene is inserted before the model requests it")
        var inspect = try base(session, editor)
        inspect["time_seconds"] = 1.0; inspect["detail"] = "windows"; inspect["limit"] = 8
        await transport.reply(0, data: try response(0, name: "inspect_scene", args: inspect))
        try await wait { await transport.payloads.count == 2 || !session.isBusy }
        try require(session.isBusy, "Observation continuation failed: \(session.errorMessage ?? "unknown error")")
        try require(editor.project.state == before && !editor.canUndo, "Read-only inspection creates no project changes or Undo entries")
        let payload = try JSONSerialization.jsonObject(with: await transport.payloads[1]) as! [String: Any]
        let messages = payload["messages"] as! [[String: Any]]
        let result = messages.last { $0["role"] as? String == "tool" }
        let outcome = try JSONSerialization.jsonObject(with: Data((result?["content"] as! String).utf8)) as! [String: Any]
        let observation = outcome["inspection"] as! [String: Any]
        try require(result?["tool_call_id"] as? String == "inspection-call-0" &&
                    (observation["windows"] as? [[String: Any]])?.first?["title"] as? String == "SYNTHETIC_BROWSER_TITLE",
                    "The next model request sees the actual paired result and bounded recorded window metadata")
        var frame = try base(session, editor)
        frame["observation_id"] = observation["observation_id"]
        frame["target"] = ["kind": "recorded", "id": "window:42"]
        frame["margin_pixels"] = 30; frame["time_seconds"] = 2; frame["duration_seconds"] = 1
        await transport.reply(1, data: try response(1, name: "frame_observation", args: frame))
        try await wait { !session.isBusy }
        if conflicting {
            try require(session.awaitsClarification && session.conflictReview != nil && editor.project.state == before,
                        "Observed framing uses the existing conflict visualization without changing the project")
            guard let id = session.conflictReviewID else { throw Failure.failed("No shared conflict review identity") }
            try require(session.resolveConflict(.proposed, editor: editor, reviewID: id), "The standard Proposed button resolves observed framing")
        }
        try require(session.errorMessage == nil && editor.project.state.regions.count == 1 && editor.project.undoHistory.count == 1,
                    "The automatic guide and target apply atomically in one ordinary Undo step")
        let box = editor.project.state.regions[0]
        let zoom = editor.project.state.zoomKeyframes.first { $0.time == 2 }
        try require(box.framingPadding == 0 && zoom?.sourceRegionID == box.id && zoom?.placement.clamped == box.framing,
                    "The pixel-fitted guide remains linked to its resulting zoom without implicit extra padding")
        try require(editor.undo() && editor.project.state == before, "One Undo restores guide, framing and any replaced movement")
    }
    static func checkBoundedLookups() async throws {
        let (editor, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = InspectionTransport()
        let session = EditorAssistantSession(transport: { try await transport.send($0) }, inspectionCache: DirectorInspectionCache(scene: scene()))
        session.instruction = "Inspect the browser."
        session.submit(editor: editor, playhead: 0, regionID: nil, editID: nil)
        var args = try base(session, editor)
        args["time_seconds"] = 1; args["detail"] = "windows"; args["limit"] = 8
        for index in 0..<5 {
            try await wait { await transport.payloads.count == index + 1 }
            await transport.reply(index, data: try response(index, name: "inspect_scene", args: args))
        }
        try await wait { !session.isBusy }
        try require(session.errorMessage?.contains("inspection limit") == true && !editor.canUndo,
                    "Repeated lookups terminate after four observations without mutating history")
        let payloads = await transport.payloads
        try require(payloads.allSatisfy { $0.count <= 20_000 }, "Repeated observations stay within the separate bounded text context")
    }
}
