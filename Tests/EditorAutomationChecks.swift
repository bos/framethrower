import Darwin
import Foundation

private struct AutomationCheckFailure: Error { let message: String }
@MainActor
private final class AutomationFixture {
    let directory: URL
    let editor: ProjectEditor
    let playback = EditorPlayback()
    let host: EditorAutomationHost
    let box = EditorRegion(time: 1, rect: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.3), note: "Synthetic guide")
    let anchor = EditAnchor(time: 5)
    var editID: UUID?, boxID: UUID?, inspector: String?
    var navigation = [String]()
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var project = RecordingProject(screenFilename: "absent-source.mov", cameraFilename: "absent-camera.mov", sceneFilename: "scene.json", duration: 12, captureFrameDuration: 1.0 / 60)
        project.state.trimStart = 2; project.state.trimEnd = 8
        project.state.regions = [box]; project.state.editAnchors = [anchor]
        project.state.zoomKeyframes = [.init(id: anchor.id, time: 5, scale: 2, transition: .smooth, duration: 2)]
        let source = RecordedSceneSource(kind: .display, globalBounds: CGRect(x: 0, y: 0, width: 800, height: 600), pixelWidth: 1600, pixelHeight: 1200)
        let window = RecordedSceneWindow(id: 17, processID: 111, application: "Synthetic", title: "Fixture window", frame: CGRect(x: 10, y: 20, width: 500, height: 400), zOrder: 0, isFocused: true, isRecorderApplication: false, occlusionEstimate: 0)
        let scene = RecordedScene(duration: 12, source: source, snapshots: [.init(time: 0, accessibilityAge: nil, observationDuration: 0, sourceBounds: source.globalBounds,
            availability: .init(windows: true, accessibilityTrusted: false, accessibilityCollected: false), windows: [window], elements: [])])
        try JSONEncoder().encode(scene).write(to: directory.appendingPathComponent("scene.json"))
        editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
        guard editor.save() else { throw AutomationCheckFailure(message: "Save fixture") }
        host = EditorAutomationHost(editor: editor, playback: playback)
        host.selection = { [weak self] in (self?.editID, self?.boxID, nil, self?.inspector) }
        host.navigate = { [weak self] operation, id, inspector in
            guard let self else { return }; navigation.append(operation)
            switch operation {
            case "select_edit", "go_to_edit": editID = id
            case "select_box", "go_to_box": boxID = id
            case "clear_selection": editID = nil; boxID = nil
            case "show_inspector": self.inspector = inspector
            default: break
            }
            if operation == "go_to_edit", id == anchor.id { playback.seek(anchor.time) }
            if operation == "go_to_box", id == box.id { playback.seek(box.time) }
        }
        EditorAutomationRegistry.shared.register(host)
    }
    func ready() async { await host.rebuildPreview() }
    func close() { EditorAutomationRegistry.shared.unregister(host); playback.close(); try? FileManager.default.removeItem(at: directory) }
    var revision: String { get throws { try EditorCommandDispatcher.revision(for: editor.project) } }
    func call(_ name: String, _ fields: [String: Any]) async throws -> [String: Any] {
        var args = fields; args["document_id"] = host.documentID
        return try EditorAutomationChecks.object(await host.performAutomation(name, arguments: EditorAutomationChecks.json(args)))
    }
    func commands(_ values: [EditorCommand]) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) }
}

/// Deliberately ignores cancellation while an operation is outstanding, as an
/// underlying renderer can. Every wait is explicitly released by its test.
@MainActor
private final class AutomationRebuildGate {
    private(set) var count = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    func run(_ editor: ProjectEditor, _ playback: EditorPlayback) async {
        count += 1; let index = count
        await withCheckedContinuation { continuations[index] = $0 }
        if !Task.isCancelled { await playback.rebuild(editor: editor) }
    }
    func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }
    func releaseAll() { let current = Array(continuations.values); continuations.removeAll(); current.forEach { $0.resume() } }
}

@main @MainActor
struct EditorAutomationChecks {
    static func require(_ value: Bool, _ message: String) throws { if !value { throw AutomationCheckFailure(message: message) } }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func object(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
    static func result(_ value: [String: Any]) -> [String: Any] { value["result"] as! [String: Any] }
    static func reject(_ body: () async throws -> Void) async throws {
        do { try await body() } catch { return }; throw AutomationCheckFailure(message: "Invalid automation call was accepted")
    }
    static func discoveryAndScope() async throws {
        let a = try AutomationFixture(), b = try AutomationFixture(); defer { a.close(); b.close() }
        await a.ready(); await b.ready()
        let before = a.editor.project, bytes = try Data(contentsOf: a.editor.url)
        let listed = try object(await EditorAutomationRegistry.shared.call("list_recordings", arguments: json([:])))
        let recordings = listed["recordings"] as! [[String: Any]]
        try require(recordings.count == 2 && Set(recordings.compactMap { $0["documentID"] as? String }) == [a.host.documentID, b.host.documentID], "Opaque distinct document scopes listed as object result")
        let summary = try result(await a.call("inspect_editor", ["section": "summary"]))
        try require(summary["media_processing_suspended"] as? Bool == true && summary["box_count"] as? Int == 1, "Authoritative metadata summary")
        let edits = try result(await a.call("inspect_editor", ["section": "edits", "limit": 1]))
        try require((edits["items"] as? [[String: Any]])?.count == 1 && (edits["total"] as? Int ?? 0) >= 1, "Bounded edit pagination")
        let resources = try JSONSerialization.jsonObject(with: EditorAutomationRegistry.shared.resourceList()) as! [[String: Any]]
        let uri = "framethrower://recordings/\(a.host.documentID)/view"
        try require(resources.contains { $0["uri"] as? String == uri }, "Actual document resource discovery")
        try require(try object(await EditorAutomationRegistry.shared.read(uri))["ok"] as? Bool == true, "Resource read reaches same host")
        let actions = try result(await a.call("describe_editor_actions", ["category": "editing"]))
        try require(actions["operations"] is [String: Any] && actions["mutation_schema"] == nil, "Discovery returns compact operation catalog")
        let exact = try result(await a.call("describe_editor_actions", ["category": "editing", "operation": "frameRegion"]))
        let schema = exact["command_schema"] as! [String: Any]
        try require(((schema["properties"] as! [String: Any])["action"] as! [String: Any])["const"] as? String == "frameRegion", "Exact legacy action introspection exposes its executable schema")
        try await reject { _ = try await a.call("describe_editor_actions", ["category": "editing", "operation": "unknown"]) }
        let inspected = try result(await a.call("inspect_recording", ["detail": "windows", "time": 1]))
        try require((inspected["windows"] as? [[String: Any]])?.first?["window_id"] as? Int == 17, "Recorded metadata inspection never reads current desktop")
        try await reject { _ = try await a.call("inspect_recording", ["detail": "frame", "time": 1]) }
        for request in [["section": "boxes", "limit": true], ["section": "boxes", "limit": 17], ["section": "boxes", "offset": -1]] as [[String: Any]] {
            try await reject { _ = try await a.call("inspect_editor", request) }
        }
        try await reject { _ = try await a.host.performAutomation("inspect_editor", arguments: json(["document_id": b.host.documentID, "section": "summary"])) }
        try await reject { _ = try await EditorAutomationRegistry.shared.read(uri + "?path=/private") }
        try require(a.editor.project == before && Data(contentsOf: a.editor.url) == bytes && !a.playback.hasMediaPlayer && a.playback.canvasPlayer == nil,
                    "Discovery/inspection/rejections do not mutate metadata/history or create AV objects")
        let context = try a.host.automationContext
        let call = try EditorAutomationAPI.parseDirector(["document_id": context.documentID, "expected_revision": context.revision,
            "tool": "control_preview", "parameters_json": "{\"operation\":\"seek\",\"time\":1.5}"], context: context)
        try require(call.name == "control_preview" && object(call.arguments)["document_id"] as? String == context.documentID, "Voice adapter retains domain scope")
        do { _ = try EditorAutomationAPI.parseDirector(["document_id": context.documentID, "expected_revision": context.revision,
            "tool": "control_preview", "parameters_json": "{\"document_id\":\"other\",\"operation\":\"pause\"}"], context: context)
            throw AutomationCheckFailure(message: "Embedded scope override accepted")
        } catch is EditorAutomationError {}
    }
    static func copiedDocumentScopes() async throws {
        let f = try AutomationFixture(); defer { f.close() }; await f.ready()
        let before = f.editor.project, bytes = try Data(contentsOf: f.editor.url)
        let copiedURL = f.directory.appendingPathComponent("external-copy.framethrower")
        try bytes.write(to: copiedURL)
        let copied = try ProjectEditor.open(url: copiedURL), playback = EditorPlayback()
        let host = EditorAutomationHost(editor: copied, playback: playback)
        EditorAutomationRegistry.shared.register(host)
        defer { EditorAutomationRegistry.shared.unregister(host); playback.close() }
        await host.rebuildPreview()
        try require(host.documentID != f.host.documentID && host.automationContext.recordingID == f.host.automationContext.recordingID,
                    "External copies retain recording identity but receive separate opaque live endpoints")
        let request: [String: Any] = try ["document_id": host.documentID, "expected_revision": EditorCommandDispatcher.revision(for: copied.project),
                                    "commands": f.commands([.createEdit(time: 9)])]
        _ = try await EditorAutomationRegistry.shared.call("apply_edits", arguments: json(request))
        try require(copied.project.undoHistory.count == 1 && f.editor.project == before && Data(contentsOf: f.editor.url) == bytes,
                    "Copied-file routing never overwrites or mutates the first endpoint")
        try await reject { _ = try await host.performAutomation("inspect_editor", arguments: json(["document_id": f.host.documentID, "section": "summary"])) }
    }
    static func mutationHistoryAndEvents() async throws {
        let f = try AutomationFixture(); defer { f.close() }; await f.ready()
        let original = f.editor.project, bytes = try Data(contentsOf: f.editor.url), revision = try f.revision
        let commands = try f.commands([.labelRegion(regionID: f.box.id, note: "Updated guide"), .createEdit(time: 7)])
        try await reject { _ = try await f.call("apply_edits", ["expected_revision": "obsolete", "commands": commands]) }
        try await reject { _ = try await f.call("apply_edits", ["expected_revision": revision, "commands": commands, "recording_title": 5]) }
        let invalid = try f.commands([.labelRegion(regionID: f.box.id, note: "Must roll back"), .createEdit(time: 99)])
        try await reject { _ = try await f.call("apply_edits", ["expected_revision": revision, "commands": invalid]) }
        try require(f.editor.project == original && Data(contentsOf: f.editor.url) == bytes, "Stale/type/batch failure is atomic in memory and on disk")
        _ = try await f.call("apply_edits", ["expected_revision": revision, "commands": commands, "recording_title": "Batch title", "name": "Automation combined edit"])
        let edited = f.editor.project
        try require(edited.title == "Batch title" && edited.state.regions[0].note == "Updated guide" && edited.undoHistory.count == 1,
                    "Typed batch and title make one durable ordinary transaction")
        try require(try ProjectEditor.open(url: f.editor.url).project == edited, "Batch saved durably")
        _ = try await f.call("control_document", ["operation": "undo", "count": 1, "expected_revision": f.revision])
        try require(f.editor.project.state == original.state && f.editor.project.title == original.title && f.editor.project.redoHistory.count == 1, "MCP supersets Undo uses normal shared stack")
        _ = try await f.call("control_document", ["operation": "redo", "count": 1, "expected_revision": f.revision])
        try require(f.editor.project.state == edited.state && f.editor.project.title == edited.title, "MCP Redo restores same metadata/title")
        try await reject { _ = try await f.call("control_document", ["operation": "undo", "count": true, "expected_revision": f.revision]) }
        let undoCount = f.editor.project.undoHistory.count
        _ = try await f.call("control_document", ["operation": "save"])
        try require(f.editor.project.undoHistory.count == undoCount, "Save without draft adds no history")
        let renameReceipt = try await f.call("control_document", ["operation": "rename", "name": "  New   recording name ", "expected_revision": f.revision])
        try require(result(renameReceipt)["project_metadata_saved"] as? Bool == true,
            "Rename tells the agent its metadata was saved, rather than implying a separate Save is required")
        try require(f.editor.displayName == "New recording name" && f.editor.project.undoHistory.count == undoCount + 1 && f.editor.project.screenFilename == original.screenFilename,
                    "Rename normalizes title, retains source filenames, adds one Undo")
        _ = try await f.call("control_document", ["operation": "undo", "expected_revision": f.revision])
        try require(f.editor.project.title == edited.title, "Rename Undo restores prior title")
        try await Task.sleep(for: .milliseconds(15))
        let events = try result(await f.call("inspect_editor", ["section": "events", "limit": 16]))
        let items = ((events["page"] as! [String: Any])["items"] as! [[String: Any]])
        try require(items.contains { $0["kind"] as? String == "document_changed" && $0["actor"] as? String == "automation" }, "Deferred publication attributes actual automated document event")
        // External on-disk replacement is a real save failure, without touching
        // permissions or any user files. No optimistic mutation may leak.
        let beforeFailure = f.editor.project
        try Data("external replacement".utf8).write(to: f.editor.url)
        try await reject { _ = try await f.call("apply_edits", ["expected_revision": f.revision, "commands": f.commands([.createEdit(time: 9)])]) }
        try require(f.editor.project == beforeFailure && Data(contentsOf: f.editor.url) == Data("external replacement".utf8), "Save collision leaves document/history and external bytes intact")
    }
    static func explicitRecordingRenameArgument() async throws {
        let f = try AutomationFixture(); defer { f.close() }; await f.ready()
        let original = f.editor.project
        let commands = try f.commands([.labelRegion(regionID: f.box.id, note: "Note change")])
        _ = try await f.call("apply_edits", ["expected_revision": f.revision, "commands": commands,
            "name": "Zoom camera to full screen over 2 seconds"])
        try require(f.editor.project.title == original.title && f.editor.displayName == original.displayName(projectURL: f.editor.url) &&
            f.editor.undoName == "Zoom camera to full screen over 2 seconds", "History label never renames the recording")
        let before = f.editor.project, bytes = try Data(contentsOf: f.editor.url)
        let changed = try f.commands([.labelRegion(regionID: f.box.id, note: "Must not leak")])
        for extra in [["title": "Accidental recording rename"], ["recording_title": "Intended", "title": "Unadvertised"]] {
            var args: [String: Any] = ["expected_revision": try f.revision, "commands": changed]
            for (key, value) in extra { args[key] = value }
            try await reject { _ = try await f.call("apply_edits", args) }
            try require(f.editor.project == before && Data(contentsOf: f.editor.url) == bytes && f.editor.draftState == nil,
                "Unadvertised title rejects the entire batch without edits, rename or history")
        }
        _ = try await f.call("apply_edits", ["expected_revision": f.revision, "commands": changed,
            "name": "Edit note and rename", "recording_title": "Requested recording name"])
        try require(f.editor.project.title == "Requested recording name" && f.editor.project.state.regions[0].note == "Must not leak" &&
            f.editor.project.undoHistory.count == before.undoHistory.count + 1, "Explicit recording_title joins one atomic transaction")
        try require(f.editor.undo() && f.editor.project.state == before.state && f.editor.project.title == before.title,
            "One Undo restores both requested rename and edit")
        let tool = EditorAutomationAPI.tools.first { $0["name"] as? String == "apply_edits" }!
        let properties = (tool["inputSchema"] as! [String: Any])["properties"] as! [String: Any]
        try require(properties["title"] == nil && properties["recording_title"] != nil &&
            ((properties["name"] as! [String: Any])["description"] as! String).contains("does not rename"),
            "Public schema distinguishes history label from actual recording rename")
    }
    static func previewDraftAndNavigation() async throws {
        let f = try AutomationFixture(); defer { f.close() }; await f.ready()
        let original = f.editor.project
        _ = try await f.call("control_preview", ["operation": "seek", "time": 1.5])
        _ = try await f.call("control_preview", ["operation": "set_rate", "rate": 2])
        _ = try await f.call("navigate_editor", ["operation": "select_box", "target_id": f.box.id.uuidString])
        try require(f.boxID == f.box.id && f.playback.time == 1.5, "Selection does not seek")
        _ = try await f.call("navigate_editor", ["operation": "go_to_edit", "target_id": f.anchor.id.uuidString])
        try require(f.editID == f.anchor.id && f.playback.time == 5, "Explicit navigation uses separate go-to callback")
        _ = try await f.call("navigate_editor", ["operation": "show_inspector", "inspector": "Pointer"])
        try require(f.inspector == "Pointer" && f.editor.project == original, "View/transport preferences add no edits or Undo")
        var draft = f.editor.project.state; draft.cursorStyle.size = 2
        try require(f.editor.updateDraft(draft, at: 5), "Prepare synthetic manual draft")
        _ = try await f.call("control_preview", ["operation": "pause"])
        _ = try await f.call("control_preview", ["operation": "set_rate", "rate": 5])
        try await reject { _ = try await f.call("control_preview", ["operation": "seek", "time": true]) }
        try await reject { _ = try await f.call("control_preview", ["operation": "play_range", "start": 4, "end": 3]) }
        try require(f.editor.draftState == draft && f.editor.project == original, "Pause/rate and malformed navigation preserve unfinished draft")
        _ = try await f.call("control_preview", ["operation": "seek", "time": 1])
        try require(f.editor.draftState == nil && f.editor.project.state == draft && f.editor.project.undoHistory.count == 1 && f.playback.time == 1,
                    "Valid source seek finishes manual draft once, not a separate transport edit")
        _ = try await f.call("control_preview", ["operation": "play_animation", "animation_id": "screen:\(f.anchor.id.uuidString)"])
        try require(f.playback.auditionRange == .init(start: 3, end: 5) && f.playback.isPlaying, "Audition uses effective animation start/end, not its target endpoint")
        await f.host.rebuildPreview()
        try require(f.playback.isPlaying && f.playback.auditionRange == .init(start: 3, end: 5), "Late same-visual rebuild does not cancel requested autoplay")
        _ = try await f.call("control_preview", ["operation": "pause"])
        try require(f.editor.project.undoHistory.count == 1 && !f.playback.hasMediaPlayer && f.playback.canvasPlayer == nil,
                    "Transient navigation/audition never creates AV objects or another Undo entry")
        let beforeCancel = f.playback.previewSnapshot
        let canceled = Task { @MainActor in _ = try await f.call("control_preview", ["operation": "seek", "time": 9]) }; canceled.cancel()
        try await reject { _ = try await canceled.value }
        try require(f.playback.previewSnapshot == beforeCancel, "Canceled host call cannot seek")
    }
    static func richHistory() async throws {
        let f = try AutomationFixture(); defer { f.close() }; await f.ready()
        var zoomed = f.editor.project.state; zoomed.zoomKeyframes[0].scale = 2.4
        try require(f.editor.commitDocument(state: zoomed, title: "Zoom and title", name: "Framing and title"), "Prepare actual combined history")
        let before = f.editor.project, bytes = try Data(contentsOf: f.editor.url)
        let history = try result(await f.call("inspect_editor", ["section": "history", "limit": 16]))
        let details = (history["details"] as! [String: Any])["undo"] as! [String: Any]
        let entry = (details["entries"] as! [[String: Any]])[0]
        let earlier = entry["before"] as! [String: Any], later = entry["after"] as! [String: Any]
        try require(details["limit"] as? Int == 8 && entry["changed_components"] as? [String] == ["title", "screen_framing"] &&
                    earlier["title"] is NSNull && later["title"] as? String == "Zoom and title" &&
                    (earlier["description"] as? String)?.contains("scale=2") == true &&
                    (earlier["description"] as? String)?.contains("scale=2.4") == false &&
                    (later["description"] as? String)?.contains("scale=2.4") == true,
                    "History reports actual Zoom and title snapshots, not names alone")
        try require(f.editor.project == before && Data(contentsOf: f.editor.url) == bytes, "History detail inspection is read-only")
        try require(f.editor.undo(), "Prepare redo direction")
        let redo = try result(await f.call("inspect_editor", ["section": "history"]))
        let redoPage = (redo["details"] as! [String: Any])["redo"] as! [String: Any]
        let redoEntry = (redoPage["entries"] as! [[String: Any]])[0]
        try require((redoEntry["before"] as! [String: Any])["title"] is NSNull &&
                    (redoEntry["after"] as! [String: Any])["title"] as? String == "Zoom and title", "Redo preserves original chronological edit direction")
        try require(f.editor.redo(), "Restore history")
        for index in 0..<9 {
            var state = f.editor.project.state; state.cursorStyle.size = 1 + Double(index) / 10
            try require(f.editor.commit(state, name: "Pointer adjustment \(index)"), "Build bounded history pagination")
        }
        let paged = try result(await f.call("inspect_editor", ["section": "history", "limit": 16]))
        let page = (paged["details"] as! [String: Any])["undo"] as! [String: Any]
        try require((page["entries"] as? [Any])?.count == 8 && page["has_more"] as? Bool == true, "Rich history caps details at eight even when names request sixteen")
        var draft = f.editor.project.state; draft.cursorStyle.size = 2.9
        try require(f.editor.updateDraft(draft, at: 4), "Prepare pending history draft")
        let committed = f.editor.project, saved = try Data(contentsOf: f.editor.url)
        let pending = try result(await f.call("inspect_editor", ["section": "history"]))
        let pendingNames = pending["undo"] as! [String: Any], pendingDetails = (pending["details"] as! [String: Any])["undo"] as! [String: Any]
        try require(pending["has_draft"] as? Bool == true && (pendingNames["items"] as? [String])?.first == "Edit" &&
                    pendingDetails["status"] as? String == "pending_draft" && (pendingDetails["entries"] as? [Any])?.isEmpty == true &&
                    f.editor.draftState == draft && f.editor.project == committed && Data(contentsOf: f.editor.url) == saved,
                    "Pending draft history remains queryable with its real next Undo name, without inventing saved diffs or committing")
    }
    static func visualMutationThenPlayback() async throws {
        let f = try AutomationFixture(); defer { f.close() }; await f.ready()
        let originalSize = f.playback.screenSize
        _ = try await f.call("apply_edits", ["expected_revision": f.revision,
            "commands": f.commands([.mutate(.canvas(.init(aspect: .square)))])])
        _ = try await f.call("control_preview", ["operation": "play"])
        try require(f.playback.screenSize.width == f.playback.screenSize.height && f.playback.isPlaying,
                    "Immediate play after a visual API edit prepares actual new geometry without waiting for SwiftUI")
        _ = try await f.call("control_preview", ["operation": "pause"])
        _ = try await f.call("control_document", ["operation": "undo", "expected_revision": f.revision])
        _ = try await f.call("control_preview", ["operation": "play"])
        try require(f.playback.screenSize == originalSize && f.playback.isPlaying && f.editor.project.undoHistory.isEmpty && f.editor.project.redoHistory.count == 1,
                    "Immediate play after API Undo prepares restored geometry without a transport Undo entry")
        _ = try await f.call("control_preview", ["operation": "pause"])
    }
    private static func wait(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < end { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        throw AutomationCheckFailure(message: "Controlled host operation timed out")
    }
    static func rebuildIdentityAndNativePause() async throws {
        let f = try AutomationFixture(); defer { f.close() }; await f.ready()
        let gate = AutomationRebuildGate(); defer { gate.releaseAll() }
        let host = EditorAutomationHost(editor: f.editor, playback: f.playback, rebuild: { await gate.run($0, $1) })
        let first = Task { @MainActor in await host.rebuildPreview() }
        try await wait { gate.count == 1 }
        var changed = f.editor.project.state; changed.presentation.aspect = .square
        try require(f.editor.commit(changed, name: "Square"), "Prepare different rebuild")
        let second = Task { @MainActor in await host.rebuildPreview() }
        try await wait { gate.count == 2 }
        changed.presentation.aspect = .source
        try require(f.editor.commit(changed, name: "Source aspect"), "Prepare same visual A again")
        let third = Task { @MainActor in await host.rebuildPreview() }
        try await wait { gate.count == 3 }
        gate.release(1); await first.value
        gate.release(2); await second.value
        var followupStarted = false
        let followup = Task { @MainActor in followupStarted = true; await host.rebuildPreview() }
        try await wait { followupStarted }
        try await Task.sleep(for: .milliseconds(10))
        try require(gate.count == 3, "Canceled first-A completion must not erase newer A rebuild identity")
        gate.release(3); await third.value; await followup.value
        await host.rebuildPreview()
        try require(gate.count == 3, "Completed newest visual is cached, with no duplicate rebuild")

        let playbackGate = AutomationRebuildGate(); defer { playbackGate.releaseAll() }
        let control = EditorAutomationHost(editor: f.editor, playback: f.playback, rebuild: { await playbackGate.run($0, $1) })
        _ = try await f.playback.applyPreviewCommand(.play)
        let original = f.editor.project
        let request = try json(["document_id": control.documentID, "operation": "play_range", "start": 3, "end": 6])
        let pending = Task { @MainActor in
            do { _ = try await control.performAutomation("control_preview", arguments: request); return false }
            catch is CancellationError { return true }
        }
        try await wait { playbackGate.count == 1 }
        var draft = f.editor.project.state; draft.cursorStyle.size = 2.7
        try require(f.editor.updateDraft(draft, at: 3), "Prepare manual draft while async automation is pending")
        control.togglePlayback()
        try require(!f.playback.isPlaying && f.editor.draftState == draft && f.editor.project == original,
                    "Native Pause is immediate during automation, preserving draft and history")
        // A later native Play during serialized work reports an actionable error
        // rather than swallowing the busy failure or starting the old request.
        control.togglePlayback()
        try await wait { control.errorMessage != nil }
        playbackGate.release(1)
        try require(try await pending.value, "Pending automation Play/range is invalidated by native Pause")
        try require(!f.playback.isPlaying && f.playback.auditionRange == nil && f.editor.draftState == draft,
                    "Delayed rebuild completion cannot restart the canceled transport intent")
        let events = try result(object(await control.performAutomation("inspect_editor", arguments: json(["document_id": control.documentID, "section": "events"]))))
        let items = (events["page"] as! [String: Any])["items"] as! [[String: Any]]
        try require(items.contains { $0["actor"] as? String == "manual" && $0["kind"] as? String == "preview_changed" }, "Priority native Pause publishes actual manual result")

        let queuedGate = AutomationRebuildGate(); defer { queuedGate.releaseAll() }
        let queued = EditorAutomationHost(editor: f.editor, playback: f.playback, rebuild: { await queuedGate.run($0, $1) })
        queued.togglePlayback(); queued.togglePlayback()
        try await Task.sleep(for: .milliseconds(15))
        try require(queuedGate.count == 0 && !f.playback.isPlaying && f.editor.draftState == draft,
                    "Pause before queued native Play starts prevents rebuild and implicit draft save")
    }
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { Darwin.exit(2) }
        try require(MediaProcessing.isSuspended, "Media interlock must remain enabled")
        try await discoveryAndScope(); try await copiedDocumentScopes(); try await explicitRecordingRenameArgument(); try await mutationHistoryAndEvents(); try await previewDraftAndNavigation(); try await visualMutationThenPlayback(); try await richHistory(); try await rebuildIdentityAndNativePause()
        print("Editor automation checks passed (production host/API/registry, synthetic recorded metadata, scope/revision/type guards, atomic save and shared Undo/Redo, selection versus seek, suspended preview draft/lifecycle semantics; no media/UI/model calls).")
    }
}
