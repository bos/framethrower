import Darwin
import Foundation

private struct LiveFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private final class BrokerExit: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var status: Int32? { lock.withLock { value } }
    func finish(_ status: Int32) { lock.withLock { value = status } }
}
private struct BrokerResult: Sendable { let data: Data; let elapsed: Double }
private struct NativeTurnSettings: Sendable {
    let provider: String
    let model: String
    let effort: String
    let cli: String
    let python: String
    let lease: LocalModelEndpointLease?
}


@MainActor
private final class LiveFixture {
    let directory: URL
    let editor: ProjectEditor
    let playback = EditorPlayback()
    let host: EditorAutomationHost
    let server: FrameThrowerMCPServer
    let initial: RecordingProject
    var calls: [[String: Any]] = []
    var selectedEditID: UUID?
    var selectedBoxID: UUID?
    var selectedAnimationID: String?
    var inspector = "Zoom"
    init(withGuide: Bool = false) throws {
        directory = URL(fileURLWithPath: "/tmp/ft-native-live-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var project = RecordingProject(screenFilename: "absent-synthetic-screen.mov", cameraFilename: "absent-synthetic-camera.mov", duration: 14)
        project.title = "Synthetic native Director check"
        if withGuide { project.state.regions = [.init(time: 4, rect: .init(x: 0.2, y: 0.2, width: 0.3, height: 0.3))] }
        project.state.zoomKeyframes = [.init(time: 0, scale: 1.7, x: 0.4, y: 0.45)]
        project.state.pipKeyframes = [.init(time: 0, placement: .init(x: 0.8, y: 0.85, scale: 0.25, visible: true, shape: .circle))]
        editor = ProjectEditor(project: project, url: directory.appendingPathComponent("synthetic.framethrower"))
        guard editor.save() else { throw LiveFailure(message: "Could not save synthetic fixture.") }
        initial = editor.project
        host = EditorAutomationHost(editor: editor, playback: playback)
        server = FrameThrowerMCPServer(directory: directory.appendingPathComponent("control"))
        host.selection = { [weak self] in (self?.selectedEditID, self?.selectedBoxID, self?.selectedAnimationID, self?.inspector) }
        host.navigate = { [weak self] operation, id, name in
            guard let self else { throw EditorAutomationError.unavailable }
            try self.navigate(operation, id: id, inspector: name)
        }
        EditorAutomationRegistry.shared.register(host)
    }
    private func navigate(_ operation: String, id: UUID?, inspector name: String?) throws {
        let sameEdit = operation == "select_edit" && id.flatMap {
            editor.references.edit(in: editor.editingState, id: $0, includeCamera: true)?.id
        } == selectedEditID
        if ["clear_selection", "select_edit", "go_to_edit", "go_to_box"].contains(operation) && !sameEdit {
            guard editor.finishDraft() else { throw LiveFailure(message: "Cannot finish fixture draft.") }
        }
        switch operation {
        case "clear_selection": selectedEditID = nil; selectedBoxID = nil; selectedAnimationID = nil
        case "show_inspector": inspector = name ?? inspector
        case "select_edit", "go_to_edit":
            guard let id, let target = editor.references.edit(in: editor.editingState, id: id, includeCamera: true) else {
                throw EditorAutomationError.invalid("That edit is no longer present.")
            }
            playback.pause()
            if sameEdit { return }
            selectedEditID = target.id; selectedAnimationID = nil
            if target.cameraID != nil && target.zoomID == nil { inspector = "Camera" }
            else if target.zoomID != nil && target.cameraID == nil { inspector = "Zoom" }
            let lane: TimelineAnimationLane = inspector == "Camera" ? .camera : inspector == "Pointer" ? .pointer : .screen
            if let animation = EditorAnimationEditing.animations(in: editor.editingState, references: editor.references,
                duration: editor.project.duration, includeCamera: true).first(where: { $0.lane == lane && (lane == .pointer || $0.editID == target.id) }) {
                selectedAnimationID = "\(animation.lane.rawValue):\(animation.componentID.uuidString)"
            }
            if operation == "go_to_edit" { playback.seek(target.time) }
        case "select_box", "go_to_box":
            guard let target = editor.editingState.regions.first(where: { $0.id == id }) else { throw EditorAutomationError.invalid("That box is no longer present.") }
            playback.pause(); selectedBoxID = target.id
            if operation == "go_to_box" {
                let associated = target.editID.flatMap { editor.references.edit(in: editor.editingState, id: $0, includeCamera: true) }
                selectedEditID = associated.flatMap { abs($0.time - target.time) < 0.000001 ? $0.id : nil }
                selectedAnimationID = nil; playback.seek(target.time)
            }
        default: throw EditorAutomationError.invalid("Unknown navigation action.")
        }
    }
    func start() async throws {
        guard MediaProcessing.isSuspended else { throw LiveFailure(message: "Media interlock must remain enabled.") }
        await host.rebuildPreview(); playback.seek(9)
        guard !playback.hasMediaPlayer, playback.canvasPlayer == nil else { throw LiveFailure(message: "Suspended fixture created a media player.") }
        try await server.start(backend: .init(
            listTools: { try JSONSerialization.data(withJSONObject: EditorAutomationAPI.tools) },
            callTool: { [self] name, arguments in try await call(name, arguments: arguments) },
            listResources: { try await EditorAutomationRegistry.shared.resourceList() },
            readResource: { uri in try await EditorAutomationRegistry.shared.read(uri) }))
    }
    func call(_ name: String, arguments: Data) async throws -> Data {
        let started = Date()
        do {
            let data = try await EditorAutomationRegistry.shared.call(name, arguments: arguments)
            calls.append(["tool": name, "arguments": try JSONSerialization.jsonObject(with: arguments),
                          "result": try JSONSerialization.jsonObject(with: data), "elapsed_seconds": Date().timeIntervalSince(started)])
            return data
        } catch {
            calls.append(["tool": name, "arguments": (try? JSONSerialization.jsonObject(with: arguments)) ?? NSNull(),
                          "error": error.localizedDescription, "elapsed_seconds": Date().timeIntervalSince(started)])
            throw error
        }
    }
    func close() {
        server.stop(); EditorAutomationRegistry.shared.unregister(host); playback.close()
        try? FileManager.default.removeItem(at: directory)
    }
    func assertOutcome(checkHistoryRoundtrip: Bool = true) throws {
        let state = editor.project.state
        try NativeDirectorLiveChecks.require(state.zoomKeyframes == initial.state.zoomKeyframes, "Camera instruction changed main-screen framing.")
        var actualRest = state, originalRest = initial.state
        actualRest.pipKeyframes = []; originalRest.pipKeyframes = []
        try NativeDirectorLiveChecks.require(actualRest == originalRest && editor.project.title == initial.title, "Camera instruction changed unrelated metadata.")
        try NativeDirectorLiveChecks.require(state.pipKeyframes.first == initial.state.pipKeyframes.first, "Initial camera placement was overwritten.")
        let targets = state.pipKeyframes.filter { $0.time > 0 }
        let arrivals = targets.filter { $0.transition == .smooth }
        try NativeDirectorLiveChecks.require(arrivals.count == 1, "Expected one smooth camera arrival.")
        let target = arrivals[0]
        let baseline = targets.filter { $0.id != target.id }
        try NativeDirectorLiveChecks.require(baseline.count <= 1 && baseline.allSatisfy { abs($0.time - 9) < 1e-7 && $0.transition == .jump && $0.placement == initial.state.placement(at: 9) },
                                            "Only an unchanged camera baseline at9 may accompany the requested arrival.")
        try NativeDirectorLiveChecks.require(abs(target.time - 11) < 1e-7 && abs(target.duration - 2) < 1e-7 && target.transition == .smooth,
                                            "Camera movement must start at playhead9 and arrive at11 over2seconds.")
        try NativeDirectorLiveChecks.require(target.placement.fullscreenFraction == 1 && state.placement(at: 9).fullscreenFraction == 0 && state.placement(at: 11).fullscreenFraction == 1,
                                            "Camera did not become exactly full canvas over the requested interval.")
        try NativeDirectorLiveChecks.require(state.placement(at: 10).fullscreenFraction > 0 && state.placement(at: 10).fullscreenFraction < 1, "Camera transition was an instantaneous jump.")
        try NativeDirectorLiveChecks.require(editor.project.undoHistory.count == 1 && editor.project.redoHistory.isEmpty && editor.draftState == nil,
                                            "Expected one durable ordinary Undo entry and no pending draft.")
        try NativeDirectorLiveChecks.require(try ProjectEditor.open(url: editor.url).project == editor.project, "Native edit was not saved durably.")
        if checkHistoryRoundtrip {
            let edited = editor.project.state
            try NativeDirectorLiveChecks.require(editor.undo() && editor.project.state == initial.state, "Ordinary Undo did not restore exact initial state.")
            try NativeDirectorLiveChecks.require(editor.redo() && editor.project.state == edited, "Ordinary Redo did not restore native edit.")
        }
        try NativeDirectorLiveChecks.require(MediaProcessing.isSuspended && !playback.hasMediaPlayer && playback.canvasPlayer == nil, "Media interlock/player invariant changed.")
    }
}

@main @MainActor
struct NativeDirectorLiveChecks {
    nonisolated static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw LiveFailure(message: message) }
    }
    nonisolated static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) }
    nonisolated static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LiveFailure(message: "Expected JSON object.") }
        return value
    }
    static func option(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("Native Director check failed: " + error.localizedDescription + "\n").utf8))
            Darwin.exit(1)
        }
    }
    private static func run() async throws {
        if CommandLine.arguments.contains("--help") {
            print("Native Director live fixture: --provider claude|codex|qwen --model MODEL --cli ABSOLUTE_PATH --effort off|on --artifacts DIRECTORY. Defaults: Claude claude-sonnet-5-5 and Codex gpt-6.1-sol at medium effort; verified local Qwen at effort off. RUN_NATIVE_DIRECTOR_LIVE=1 required; --capabilities adds pointer/rename/preview/Undo/Redo; --self-test uses no provider.")
            return
        }
        let selfTest = CommandLine.arguments.contains("--self-test")
        guard selfTest || ProcessInfo.processInfo.environment["RUN_NATIVE_DIRECTOR_LIVE"] == "1" else {
            throw LiveFailure(message: "Opt in with RUN_NATIVE_DIRECTOR_LIVE=1; this test uses the selected signed-in native agent account.")
        }
        guard let root = option("--repo") else { throw LiveFailure(message: "Pass --repo with the repository path.") }
        let repo = URL(fileURLWithPath: root)
        let artifacts = option("--artifacts").map { URL(fileURLWithPath: $0) } ?? repo.appendingPathComponent("build/NativeDirectorLive/run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fixture = try LiveFixture(); defer { fixture.close() }
        do {
            try await fixture.start()
            if selfTest {
                let context = try fixture.host.automationContext
                let commands = [EditorCommand.mutate(.cameraOverlay(.init(fullscreen: 1), timing: .init(start: 9, end: 11)))]
                let arguments: [String: Any] = ["document_id": context.documentID, "expected_revision": context.revision,
                    "commands": try JSONSerialization.jsonObject(with: JSONEncoder().encode(commands))]
                let socket = fixture.server.socketPath
                let argumentData = try json(arguments)
                let response = try await Task.detached(priority: .utility) { try probe(socket: socket, arguments: argumentData) }.value
                let result = try object(response)
                try require((result["result"] as? [String: Any])?["isError"] as? Bool == false, "Private MCP self-test tool call failed.")
                try fixture.assertOutcome()
                if CommandLine.arguments.contains("--capabilities") {
                    try await capabilityChecks(fixture) { _, offset in
                        let current = try fixture.host.automationContext
                        var fields: [String: Any] = ["document_id": current.documentID, "expected_revision": current.revision]
                        let tool: String
                        switch offset {
                        case 0:
                            tool = "apply_edits"
                            fields["commands"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([EditorCommand.mutate(.pointer(.init(size: 3)))]))
                        case 1: tool = "control_document"; fields["operation"] = "rename"; fields["name"] = "Native review"
                        case 2:
                            tool = "control_preview"; fields.removeValue(forKey: "expected_revision")
                            fields["operation"] = "set_rate"; fields["rate"] = 2
                        case 3: tool = "control_document"; fields["operation"] = "undo"
                        default: tool = "control_document"; fields["operation"] = "redo"
                        }
                        _ = try await fixture.call(tool, arguments: json(fields))
                    }
                }
                try await navigationCheck()
                try await secretIOCheck(artifacts: artifacts)
                print("Native Director fixture self-test passed: actual private MCP→Host→durable camera edit, exact9→11, main framing preserved, oneUndo/Redo; no provider/media.")
            } else {
                try await live(fixture, repo: repo, artifacts: artifacts)
            }
            try json(fixture.calls).write(to: artifacts.appendingPathComponent("mcp-calls.json"))
            try JSONEncoder().encode(fixture.editor.project).write(to: artifacts.appendingPathComponent("final-metadata.json"))
            print("Native Director artifacts: \(artifacts.path)")
        } catch {
            try? json(fixture.calls).write(to: artifacts.appendingPathComponent("mcp-calls.json"))
            try? JSONEncoder().encode(fixture.editor.project).write(to: artifacts.appendingPathComponent("failed-metadata.json"))
            try? json(["error": error.localizedDescription]).write(to: artifacts.appendingPathComponent("failure.json"))
            print("Native Director failed; artifacts: \(artifacts.path)")
            throw error
        }
    }
    private static func live(_ fixture: LiveFixture, repo: URL, artifacts: URL) async throws {
        let python = option("--python") ?? "/opt/homebrew/bin/python3"
        let provider = option("--provider") ?? "claude"
        try require(["claude", "codex", "qwen"].contains(provider), "Choose claude, codex or the explicitly opted-in local qwen runtime.")
        let defaultModel = provider == "claude" ? "claude-sonnet-5-5" : provider == "codex" ? "gpt-6.1-sol" : "framethrower-local"
        let model = option("--model") ?? defaultModel
        let qwenCLI = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/FrameThrower/DirectorAgents/QwenCode/0.27.0/node_modules/.bin/qwen").path
        let cli = option("--cli") ?? option("--" + provider) ?? (provider == "qwen" ? qwenCLI : "/opt/homebrew/bin/" + provider)
        if provider == "qwen" {
            try require(model == "framethrower-local" && URL(fileURLWithPath: cli).resolvingSymlinksInPath() == URL(fileURLWithPath: qwenCLI).resolvingSymlinksInPath(),
                        "Qwen must use the verified installed model and pinned Qwen Code0.27.0 runtime.")
        }
        let effort = option("--effort") ?? (provider == "qwen" ? "off" : "medium")
        if provider == "qwen" { try require(["on", "off"].contains(effort), "Qwen reasoning is an on/off toggle, not a medium tier.") }
        try require(!model.isEmpty && !model.hasPrefix("-"), "Provide a native model identifier.")
        try require(FileManager.default.isExecutableFile(atPath: python) && FileManager.default.isExecutableFile(atPath: cli), "Official selected provider CLI/Python3 must already be installed and signed in.")
        let prepareStart = Date()
        try await withEndpoint(enabled: provider == "qwen") { lease in
            let preparationSeconds = Date().timeIntervalSince(prepareStart)
            if let lease {
                try json(["base_url": lease.baseURL.absoluteString, "model": lease.model, "context_window_size": lease.contextWindowSize,
                          "preparation_seconds": preparationSeconds, "lease_id": lease.id.uuidString, "device": "Metal (MTL0)"])
                    .write(to: artifacts.appendingPathComponent("local-runtime.json"))
            }
            let nativeDirectory = artifacts.appendingPathComponent("native-session")
            try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let settings = NativeTurnSettings(provider: provider, model: model, effort: effort, cli: cli, python: python, lease: lease)
            var expectedSession: String?
            let recall = "What did I ask you to change, and over what duration? Do not change anything."
            var turns = ["Zoom the camera to full screen over two seconds."]
            var index = 0
            while index < turns.count {
                let text = turns[index]
                let beforeTurn = fixture.editor.project
                let result = try await sendTurn(text, number: index + 1, settings: settings, fixture: fixture,
                                                repo: repo, artifacts: artifacts, expectedSession: &expectedSession)
                if text == recall {
                    try require(fixture.editor.project == beforeTurn && fixture.editor.draftState == nil, "Native recall turn made an unwanted edit/history change.")
                    try require(!(result["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Native recall did not return a natural response.")
                } else if fixture.editor.project.state != fixture.initial.state || !fixture.editor.project.undoHistory.isEmpty {
                    try fixture.assertOutcome(checkHistoryRoundtrip: false)
                    turns.append(recall)
                } else if index == 0 {
                    turns.append("Yes, picture in picture.")
                } else {
                    throw LiveFailure(message: "Native clarification follow-up still made no requested camera edit.")
                }
                index += 1
            }
            try require(fixture.calls.contains { $0["tool"] as? String == "apply_edits" && $0["error"] == nil }, "Native agent never made a real apply_edits call.")
            try fixture.assertOutcome()
            if CommandLine.arguments.contains("--capabilities") {
                try await capabilityChecks(fixture) { text, offset in
                    _ = try await sendTurn(text, number: index + offset + 1, settings: settings, fixture: fixture,
                                           repo: repo, artifacts: artifacts, expectedSession: &expectedSession)
                }
            }
            let scope = CommandLine.arguments.contains("--capabilities") ? "camera/recall plus pointer, rename, preview and history" : "camera/recall and one ordinary Undo/Redo"
            print("Native \(provider)/\(model) Director live check passed: \(scope); suspended metadata only.")
        }
    }

    private static func sendTurn(_ text: String, number: Int, settings: NativeTurnSettings, fixture: LiveFixture,
                                 repo: URL, artifacts: URL, expectedSession: inout String?) async throws -> [String: Any] {
        let provider = settings.provider, model = settings.model, effort = settings.effort
        let cli = settings.cli, python = settings.python, lease = settings.lease
        let context = try fixture.host.automationContext
        let request: [String: Any] = ["text": text, "document_id": context.documentID,
            "recording_id": fixture.editor.automationID.uuidString,
            "editor_events": [["kind": "current_editor", "context": try EditorAutomationAPI.object(context), "playhead": fixture.playback.time]],
            "bootstrap_context": ["document_id": context.documentID, "recording_name": fixture.editor.displayName, "duration": 14]]
        var configuration: [String: Any] = ["provider": provider, "cli": cli, "model": model, "effort": effort,
            "cwd": artifacts.appendingPathComponent("native-session").path, "mcp_proxy": repo.appendingPathComponent("Tools/framethrower-mcp.py").path,
            "mcp_socket": fixture.server.socketPath, "document_id": context.documentID,
            "recording_id": fixture.editor.automationID.uuidString, "timeout": 180]
        if let lease {
            let probe = try await LocalModelRuntime.shared.acquireEndpoint()
            let same = probe.baseURL == lease.baseURL && probe.token == lease.token && probe.model == lease.model && probe.contextWindowSize == lease.contextWindowSize
            await LocalModelRuntime.shared.releaseEndpoint(probe)
            try require(same, "Local runtime changed the authenticated server between native turns.")
            configuration["base_url"] = lease.baseURL.absoluteString
            configuration["model"] = lease.model
            configuration["local_token"] = lease.token
            configuration["context_window_size"] = lease.contextWindowSize
        }
        let payload = try json(["request": request, "configuration": configuration])
        var retainedConfiguration = configuration
        if lease != nil { retainedConfiguration["local_token"] = "[redacted local endpoint token]" }
        try json(["request": request, "configuration": retainedConfiguration])
            .write(to: artifacts.appendingPathComponent("turn-\(number)-request.json"))
        let helper = repo.appendingPathComponent("Tools/director-agent-client.py").path
        let turnDirectory = artifacts.appendingPathComponent("turn-\(number)")
        print("Native \(provider)/\(model) turn\(number): \(text)"); fflush(stdout)
        let outcome = try await Task.detached(priority: .utility) {
            try broker(payload: payload, python: python, helper: helper, directory: turnDirectory, timeout: 190, secret: lease?.token)
        }.value
        let result = try object(outcome.data)
        try outcome.data.write(to: artifacts.appendingPathComponent("turn-\(number)-result.json"))
        try require(result["ok"] as? Bool == true, "Native broker failed: \(result["error"] ?? "missing result")")
        guard let native = result["native_session_id"] as? String, UUID(uuidString: native) != nil else { throw LiveFailure(message: "Native session identity missing.") }
        if let expectedSession { try require(native == expectedSession, "Follow-up changed native conversation identity.") }
        else { expectedSession = native }
        print("Native \(provider)/\(model) session=\(native) elapsed=\(outcome.elapsed)s usage=\(result["usage"] ?? [:]) answer=\(result["text"] ?? "")"); fflush(stdout)
        let resolved = (result["events"] as? [[String: Any]])?.first(where: { $0["subtype"] as? String == "init" })?["model"] as? String
        try json(["native_session_id": native, "elapsed_seconds": outcome.elapsed, "usage": result["usage"] ?? [:],
                  "provider": provider, "requested_model": model, "resolved_model": resolved as Any? ?? NSNull(), "effort": effort,
                  "local_endpoint": lease?.baseURL.absoluteString as Any? ?? NSNull(), "same_authenticated_endpoint": lease != nil])
            .write(to: artifacts.appendingPathComponent("turn-\(number)-metrics.json"))
        try JSONEncoder().encode(fixture.editor.project).write(to: artifacts.appendingPathComponent("turn-\(number)-state.json"))
        return result
    }

    private static func navigationCheck() async throws {
        let fixture = try LiveFixture(withGuide: true); defer { fixture.close() }
        await fixture.host.rebuildPreview(); fixture.playback.seek(9)
        let project = fixture.editor.project
        @MainActor func send(_ operation: String, id: UUID? = nil, inspector: String? = nil) async throws -> EditorAutomationContext {
            var fields: [String: Any] = ["document_id": fixture.host.documentID, "operation": operation]
            if let id { fields["target_id"] = id.uuidString }
            if let inspector { fields["inspector"] = inspector }
            let data = try await fixture.call("navigate_editor", arguments: json(fields))
            guard let result = try object(data)["result"] else { throw LiveFailure(message: "Navigation returned no observable context.") }
            return try JSONDecoder().decode(EditorAutomationContext.self, from: json(result))
        }
        let shown = try await send("show_inspector", inspector: "Camera")
        try require(shown.inspector == "Camera" && fixture.playback.time == 9, "Inspector change was not observable or moved source time.")
        let box = project.state.regions[0], edit = project.state.zoomKeyframes[0]
        let selectedBox = try await send("select_box", id: box.id)
        try require(selectedBox.selectedBoxID == box.id && fixture.playback.time == 9, "Select box must be observable without seeking.")
        let selectedEdit = try await send("select_edit", id: edit.id)
        try require(selectedEdit.selectedEditID == edit.id && selectedEdit.inspector == "Zoom" && selectedEdit.selectedAnimationID != nil && fixture.playback.time == 9,
                    "Select edit must expose its inspector/component without seeking.")
        _ = try await send("go_to_box", id: box.id)
        try require(fixture.playback.time == box.time, "Explicit go-to box did not seek.")
        _ = try await send("go_to_edit", id: edit.id)
        try require(fixture.playback.time == edit.time, "Explicit go-to edit did not seek.")
        let cleared = try await send("clear_selection")
        try require(cleared.selectedEditID == nil && cleared.selectedBoxID == nil && cleared.selectedAnimationID == nil && fixture.playback.time == edit.time,
                    "Clear selection must be observable without seeking.")
        try require(fixture.editor.project == project, "Headless navigation changed document/history.")
        print("Native fixture navigation checks passed: observable inspector/selection, explicit go-to seeks, select-only preserves time/history.")
    }

    private static func capabilityChecks(_ fixture: LiveFixture,
                                         send: @MainActor (String, Int) async throws -> Void) async throws {
        let cameraProject = fixture.editor.project
        var pointerState = cameraProject.state; pointerState.cursorStyle.size = 3
        let baselineUndo = cameraProject.undoHistory.count
        let originalTitle = cameraProject.title
        let turns = ["Make the mouse pointer twice as large.", "Call this recording Native review.",
                     "Review this at double speed.", "Undo that rename.", "Redo that."]
        for (offset, text) in turns.enumerated() {
            let before = fixture.editor.project
            try await send(text, offset)
            let project = fixture.editor.project
            try require(project.state == pointerState && fixture.editor.draftState == nil,
                        "Capability turn changed unrelated camera/screen/audio state or lost the pointer edit.")
            switch offset {
            case 0:
                try require(project.title == originalTitle && project.undoHistory.count == baselineUndo + 1 && project.redoHistory.isEmpty,
                            "Pointer-size change must make exactly one ordinary Undo entry.")
            case 1:
                try require(project.title == "Native review" && project.undoHistory.count == baselineUndo + 2 && project.redoHistory.isEmpty,
                            "Rename must change only title and add one ordinary Undo entry.")
            case 2:
                try require(project == before && fixture.playback.playbackRate == 2,
                            "Preview speed must become 2x without document/history changes.")
            case 3:
                try require(project.title == originalTitle && project.undoHistory.count == baselineUndo + 1 && project.redoHistory.count == 1,
                            "Undo must revert the rename while preserving pointer/camera edits.")
            case 4:
                try require(project.title == "Native review" && project.undoHistory.count == baselineUndo + 2 && project.redoHistory.isEmpty,
                            "Redo must restore the rename while preserving pointer/camera edits.")
            default: break
            }
            try require(try ProjectEditor.open(url: fixture.editor.url).project == project, "Capability change was not durably saved.")
        }
        print("Native capability checks passed: pointer size, title-only rename, transient preview rate, ordinary Undo/Redo.")
    }

    private static func withEndpoint(enabled: Bool, operation: @MainActor (LocalModelEndpointLease?) async throws -> Void) async throws {
        guard enabled else { try await operation(nil); return }
        // This executable's registry contains only its own headless test child,
        // never the GUI's server. Terminate even if preparation is cancelled.
        defer { LocalModelRuntime.terminateOwnedProcess() }
        let lease = try await LocalModelRuntime.shared.acquireEndpoint()
        do { try await operation(lease); await LocalModelRuntime.shared.releaseEndpoint(lease) }
        catch { await LocalModelRuntime.shared.releaseEndpoint(lease); throw error }
    }

    private static func secretIOCheck(artifacts: URL) async throws {
        let helper = artifacts.appendingPathComponent("synthetic-io.py")
        try Data("""
        import fcntl,json,sys
        value=json.load(sys.stdin)
        path=fcntl.fcntl(0,50,bytes(1024)).split(bytes([0]))[0].decode()
        print(json.dumps({'input_path':path,'text':value['token'] if value['echo'] else 'synthetic'}))
        """.utf8).write(to: helper)
        let token = "synthetic-bearer-" + UUID().uuidString
        for echo in [false, true] {
            let directory = artifacts.appendingPathComponent(echo ? "io-redaction" : "io-cleanup")
            let payload = try json(["token": token, "echo": echo])
            var refused = false
            do {
                _ = try await Task.detached(priority: .utility) {
                    try broker(payload: payload, python: "/opt/homebrew/bin/python3", helper: helper.path,
                               directory: directory, timeout: 5, secret: token)
                }.value
            } catch { refused = true }
            try require(refused == echo, "Secret I/O echo must fail, ordinary output must succeed.")
            let saved = try Data(contentsOf: directory.appendingPathComponent("output.json"))
            try require(!String(decoding: saved, as: UTF8.self).contains(token), "Retained broker output leaked a token.")
            let path = try object(saved)["input_path"] as? String ?? ""
            try require(!path.isEmpty && !FileManager.default.fileExists(atPath: path) && !FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path),
                        "Ephemeral bearer input or its directory survived the call.")
            try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("input.json").path), "Secret stdin was retained in artifacts.")
        }
    }

    // Runs off MainActor, allowing actual MCP backend calls to service the child.
    nonisolated private static func broker(payload: Data, python: String, helper: String, directory: URL, timeout: Double, secret: String? = nil) throws -> BrokerResult {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let ioDirectory: URL
        if secret != nil {
            ioDirectory = files.temporaryDirectory.appendingPathComponent("ft-native-secret-" + UUID().uuidString)
            try files.createDirectory(at: ioDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } else { ioDirectory = directory }
        defer { if secret != nil { try? files.removeItem(at: ioDirectory) } }
        let input = ioDirectory.appendingPathComponent("input.json"), output = ioDirectory.appendingPathComponent("output.json"), errors = ioDirectory.appendingPathComponent("stderr.txt")
        for (url, data) in [(input, payload), (output, Data()), (errors, Data())] {
            guard files.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw LiveFailure(message: "Cannot create private broker files.") }
        }
        let stdin = try FileHandle(forReadingFrom: input), stdout = try FileHandle(forWritingTo: output), stderr = try FileHandle(forWritingTo: errors)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let process = Process(), exit = BrokerExit()
        process.executableURL = URL(fileURLWithPath: python); process.arguments = [helper]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + ":/usr/bin:/bin"
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        process.terminationHandler = { exit.finish($0.terminationStatus) }
        let started = Date(); try process.run()
        // The production Python broker creates this exact process group. Signal
        // only it/its descendants, never GUI/default socket or unrelated agents.
        defer { _ = Darwin.kill(-process.processIdentifier, SIGTERM) }
        while exit.status == nil, Date().timeIntervalSince(started) < timeout { Thread.sleep(forTimeInterval: 0.02) }
        guard let status = exit.status else {
            _ = Darwin.kill(-process.processIdentifier, SIGKILL); _ = Darwin.kill(process.processIdentifier, SIGKILL)
            throw LiveFailure(message: "Owned native broker exceeded its bounded deadline.")
        }
        let data = try Data(contentsOf: output)
        try require(data.count <= 32 * 1024 * 1024, "Native broker output exceeded test I/O limit.")
        if let secret {
            let text = String(decoding: data, as: UTF8.self)
            let diagnostics = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
            try Data(text.replacingOccurrences(of: secret, with: "[redacted local token]").utf8)
                .write(to: directory.appendingPathComponent("output.json"))
            try Data(diagnostics.replacingOccurrences(of: secret, with: "[redacted local token]").utf8)
                .write(to: directory.appendingPathComponent("stderr.txt"))
            try require(!text.contains(secret) && !diagnostics.contains(secret), "Local native output contained a credential; retained output was redacted.")
        }
        try require(status == 0, "Owned native broker exited\(status); inspect its private stderr artifact.")
        return BrokerResult(data: data, elapsed: Date().timeIntervalSince(started))
    }

    nonisolated static func probe(socket path: String, arguments: Data) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LiveFailure(message: "Cannot create self-test Unix client.") }
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LiveFailure(message: "Test socket path too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw LiveFailure(message: "Cannot connect private test socket.") }
        func send(_ value: Any) throws {
            let data = try JSONSerialization.data(withJSONObject: value) + Data([10])
            var sent = 0
            try data.withUnsafeBytes { bytes in
                while sent < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                    guard count > 0 else { throw LiveFailure(message: "Self-test socket write failed.") }; sent += count
                }
            }
        }
        func receive() throws -> Data {
            var data = Data(), byte: UInt8 = 0
            while data.count <= 1_048_576 {
                guard Darwin.read(descriptor, &byte, 1) == 1 else { throw LiveFailure(message: "Self-test socket read timed out.") }
                if byte == 10 { return data }; data.append(byte)
            }
            throw LiveFailure(message: "Self-test response exceeded line limit.")
        }
        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "native-fixture-self-test", "version": "1"]]])
        _ = try receive()
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "apply_edits", "arguments": try JSONSerialization.jsonObject(with: arguments)]])
        return try receive()
    }
}
