import Combine
import Foundation

/// One open document endpoint. Transports never select a window by focus or
/// reach into UI widgets: they use explicit identities and this shared host.
@MainActor
final class EditorAutomationHost: ObservableObject, EditorAutomationEndpoint {
    private weak var editor: ProjectEditor?
    private weak var playback: EditorPlayback?
    let documentID: String
    private let projectID: UUID
    private let inspections: DirectorInspectionCache
    private let events = PassthroughSubject<EditorAutomationEvent, Never>()
    private var recentEvents: [[String: Any]] = []
    private var eventSequence = 0
    private var subscriptions: Set<AnyCancellable> = []
    private var actor = "manual"
    private var executing = false
    private var lastSelection: String?
    private var lastTransport: String?
    private var preparedVisual: EditState?
    private var rebuildingVisual: EditState?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildID: UUID?
    private let rebuildOperation: @MainActor (ProjectEditor, EditorPlayback) async -> Void
    private var previewIntent = UUID()
    private var pendingPlaybackIntent: UUID?
    @Published private(set) var errorMessage: String?
    var isPlaybackPending: Bool { pendingPlaybackIntent != nil }

    /// Both SwiftUI publication and automation await the same rebuild. A late
    /// observer must not cancel a newly started range audition a second time.
    func rebuildPreview() async {
        guard let editor, let playback else { return }
        let visual = visualState(editor.project.state)
        if let task = rebuildTask, rebuildingVisual == visual { await task.value; return }
        if preparedVisual == visual, playback.canPlay { return }
        rebuildTask?.cancel()
        rebuildingVisual = visual
        let id = UUID(); rebuildID = id
        let operation = rebuildOperation
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            await operation(editor, playback)
        }
        rebuildTask = task
        await task.value
        if rebuildID == id {
            if !task.isCancelled { preparedVisual = visual }
            rebuildTask = nil; rebuildingVisual = nil; rebuildID = nil
        }
    }

    var selection: () -> (UUID?, UUID?, String?, String?) = { (nil, nil, nil, nil) }
    var navigate: ((String, UUID?, String?) throws -> Void)?

    init(editor: ProjectEditor, playback: EditorPlayback,
         rebuild: @escaping @MainActor (ProjectEditor, EditorPlayback) async -> Void = { editor, playback in
             await playback.rebuild(editor: editor)
         }) {
        self.editor = editor
        self.playback = playback
        rebuildOperation = rebuild
        inspections = DirectorInspectionCache(recordedSceneURL: editor.project.sceneFilename.map {
            editor.url.deletingLastPathComponent().appendingPathComponent($0)
        })
        projectID = editor.automationID
        documentID = UUID().uuidString
        editor.$project.dropFirst().sink { [weak self] _ in
            // @Published delivers before storage changes. Sample after it has
            // completed, once per actual document operation, not render frame.
            let actor = self?.actor ?? "manual"
            Task { @MainActor [weak self] in self?.recordEvent("document_changed", actorOverride: actor) }
        }.store(in: &subscriptions)
    }

    var automationContext: EditorAutomationContext {
        get throws {
            guard let editor else { throw EditorAutomationError.unavailable }
            let selected = selection()
            return EditorAutomationContext(documentID: documentID, name: editor.displayName,
                revision: try EditorCommandDispatcher.revision(for: editor.project), hasDraft: editor.draftState != nil,
                preview: playback?.previewSnapshot, selectedEditID: selected.0, selectedBoxID: selected.1,
                selectedAnimationID: selected.2, inspector: selected.3, recordingID: editor.automationID)
        }
    }
    var automationEvents: AnyPublisher<EditorAutomationEvent, Never> { events.eraseToAnyPublisher() }

    func recordEvent(_ kind: String, actorOverride: String? = nil) {
        let actor = actorOverride ?? self.actor
        guard let context = try? automationContext else { return }
        let transport = context.preview.map { "\($0.isPlaying):\($0.rate):\(String(describing: $0.range))" }
        if kind == "preview_transport", lastTransport == transport { return }
        if kind.hasPrefix("preview_") { lastTransport = transport }
        if kind == "selection_changed" {
            let signature = "\(String(describing: context.selectedEditID)):\(String(describing: context.selectedBoxID)):\(context.selectedAnimationID ?? ""):\(context.inspector ?? "")"
            if signature == lastSelection { return }
            lastSelection = signature
        }
        eventSequence += 1
        var item: [String: Any] = ["sequence": eventSequence, "actor": actor, "kind": kind,
                                  "revision": context.revision]
        if let view = context.preview, let value = try? EditorAutomationAPI.object(view) { item["preview"] = value }
        recentEvents.append(item)
        if recentEvents.count > 128 { recentEvents.removeFirst(recentEvents.count - 128) }
        events.send(.init(actor: actor, kind: kind, context: context))
    }

    func performAutomation(_ name: String, arguments: Data) async throws -> Data {
        try await perform(name, arguments: arguments, origin: "automation")
    }

    private func perform(_ name: String, arguments: Data, origin: String, expectedPreviewIntent: UUID? = nil) async throws -> Data {
        guard arguments.count <= EditorAutomationAPI.maximumRequestBytes,
              let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] else {
            throw EditorAutomationError.invalid("Use a bounded JSON object for editor arguments.")
        }
        guard args["document_id"] as? String == documentID else { throw EditorAutomationError.wrongDocument }
        guard let editor, let playback else { throw EditorAutomationError.unavailable }
        try Task.checkCancellation()
        guard !executing else { throw EditorAutomationError.invalid("Another automation action is still running in this editor. Retry after it completes.") }
        executing = true
        defer { executing = false }
        let value: Any
        switch name {
        case "inspect_editor":
            try EditorAutomationAPI.keys(args, allowed: ["document_id", "section", "offset", "limit"])
            value = try inspect(args, editor: editor)
        case "inspect_recording":
            try EditorAutomationAPI.keys(args, allowed: ["document_id", "detail", "time", "query", "window_id", "kind", "limit"])
            let time = try EditorAutomationAPI.number(args["time"])
            guard time >= 0, time <= editor.project.duration else { throw EditorPreviewError.invalidTime }
            guard args["detail"] as? String != "frame" else { throw DirectorInspectionError.frameUnavailable }
            guard let raw = args["detail"] as? String, let detail = DirectorSceneInspectionRequest.Detail(rawValue: raw) else { throw EditorAutomationError.invalid("Choose windows, controls, search or frame.") }
            let limit = try args["limit"].map { try EditorAutomationAPI.integer($0) } ?? 8
            let windowID: UInt32?
            if let value = args["window_id"] {
                let number = try EditorAutomationAPI.number(value)
                guard number.rounded() == number, number > 0, number <= Double(UInt32.max) else { throw EditorAutomationError.invalid("Use a returned recorded window identity.") }
                windowID = UInt32(number)
            } else { windowID = nil }
            let kind = (args["kind"] as? String).flatMap(DirectorSceneInspectionRequest.Kind.init(rawValue:))
            if args["kind"] != nil && kind == nil { throw EditorAutomationError.invalid("Unknown recorded target kind.") }
            let request = DirectorSceneInspectionRequest(projectID: projectID,
                revision: try EditorCommandDispatcher.revision(for: editor.project), sourceTime: time, detail: detail,
                windowID: windowID, limit: limit, query: args["query"] as? String, kind: kind)
            let outcome = try await inspections.perform(.scene(request), project: editor.project, projectID: projectID, supportsImages: false)
            guard request.revision == (try EditorCommandDispatcher.revision(for: editor.project)) else { throw EditorCommandError.stale }
            guard case let .observation(observation) = outcome else { throw EditorAutomationError.invalid("The recording inspection returned no observation.") }
            value = try JSONSerialization.jsonObject(with: observation.result)
        case "describe_editor_actions":
            try EditorAutomationAPI.keys(args, allowed: ["document_id", "category", "operation"])
            if args["operation"] != nil && !(args["operation"] is String) { throw EditorAutomationError.invalid("Name one operation as text.") }
            value = try actionDescription(args["category"] as? String ?? "", operation: args["operation"] as? String)
        case "control_preview":
            let command = try previewCommand(args, editor: editor)
            // Validate before finishing a draft: malformed requests cannot
            // accidentally save an unfinished manual gesture.
            let intent: UUID
            var ownsPlaybackIntent = false
            switch command {
            case .pause:
                previewIntent = UUID(); pendingPlaybackIntent = nil; intent = previewIntent
            case .setRate:
                intent = previewIntent
            default:
                if let expectedPreviewIntent {
                    guard previewIntent == expectedPreviewIntent else { throw CancellationError() }
                } else { previewIntent = UUID() }
                intent = previewIntent
                if pendingPlaybackIntent != intent { pendingPlaybackIntent = nil }
                switch command {
                case .play, .playRange: pendingPlaybackIntent = intent; ownsPlaybackIntent = true
                default: break
                }
            }
            defer { if ownsPlaybackIntent && pendingPlaybackIntent == intent { pendingPlaybackIntent = nil } }
            switch command {
            case .pause, .setRate: break
            default:
                guard withAutomationChange(origin: origin, { editor.finishDraft() }) else { throw EditorCommandError.saveFailed(editor.errorMessage ?? "Couldn't save the current edit.") }
                await rebuildPreview()
                guard previewIntent == intent else { throw CancellationError() }
            }
            try Task.checkCancellation()
            value = try EditorAutomationAPI.object(await playback.applyPreviewCommand(command))
            recordEvent("preview_changed", actorOverride: origin)
        case "navigate_editor":
            try EditorAutomationAPI.keys(args, allowed: ["document_id", "operation", "target_id", "inspector"])
            guard let operation = args["operation"] as? String,
                  ["select_edit", "select_box", "clear_selection", "show_inspector", "go_to_edit", "go_to_box"].contains(operation),
                  let navigate else { throw EditorAutomationError.invalid("Choose an available editor navigation action.") }
            let id = try args["target_id"].map { try EditorAutomationAPI.uuid($0) }
            switch operation {
            case "select_edit", "go_to_edit":
                guard let id, editor.references.edit(in: editor.editingState, id: id, includeCamera: editor.project.cameraFilename != nil) != nil else { throw EditorAutomationError.invalid("That edit is no longer present.") }
            case "select_box", "go_to_box":
                guard let id, editor.editingState.regions.contains(where: { $0.id == id }) else { throw EditorAutomationError.invalid("That box is no longer present.") }
            case "show_inspector":
                guard let inspector = args["inspector"] as? String, ["Zoom", "Camera", "Pointer", "Canvas", "Audio"].contains(inspector) else { throw EditorAutomationError.invalid("Choose an available inspector.") }
            default: break
            }
            try Task.checkCancellation()
            try withAutomationChange(origin: origin) { try navigate(operation, id, args["inspector"] as? String) }
            recordEvent("selection_changed", actorOverride: origin)
            value = try EditorAutomationAPI.object(automationContext)
        case "control_document":
            try EditorAutomationAPI.keys(args, allowed: ["document_id", "operation", "name", "count", "expected_revision"])
            try checkRevision(args, editor: editor, required: args["operation"] as? String != "save")
            try Task.checkCancellation()
            let success: Bool
            switch args["operation"] as? String {
            case "save": success = withAutomationChange(origin: origin) { editor.save() }
            case "rename":
                guard let name = args["name"] as? String else { throw EditorAutomationError.invalid("Provide the recording's new name.") }
                success = withAutomationChange(origin: origin) { editor.rename(to: name) }
            case "undo", "redo":
                let count = try args["count"].map { try EditorAutomationAPI.integer($0) } ?? 1
                guard (1...128).contains(count) else { throw EditorAutomationError.invalid("Undo or Redo between 1 and 128 entries, newest first.") }
                let available = args["operation"] as? String == "undo" ? editor.historyState.undo.count : editor.historyState.redo.count
                guard count <= available else { throw EditorAutomationError.invalid("There are only \(available) available entries on that history stack.") }
                success = withAutomationChange(origin: origin) { args["operation"] as? String == "undo" ? editor.undo(count: count) : editor.redo(count: count) }
            default: throw EditorAutomationError.invalid("Choose save, rename, undo or redo.")
            }
            guard success else { throw EditorCommandError.saveFailed(editor.errorMessage ?? "The recording could not be saved.") }
            value = try EditorAutomationAPI.object(automationContext)
        case "apply_edits":
            try EditorAutomationAPI.keys(args, allowed: ["document_id", "expected_revision", "commands", "name", "title"])
            try checkRevision(args, editor: editor, required: true)
            guard let raw = args["commands"] as? [[String: Any]], !raw.isEmpty, raw.count <= 128 else { throw EditorAutomationError.invalid("Provide between 1 and 128 typed edit commands.") }
            for key in ["name", "title"] where args[key] != nil && !(args[key] is String) {
                throw EditorAutomationError.invalid("Use text for the action name and recording title.")
            }
            let commands = try JSONDecoder().decode([EditorCommand].self, from: JSONSerialization.data(withJSONObject: raw))
            let batch = EditorCommandBatch(projectID: projectID, revision: try EditorCommandDispatcher.revision(for: editor.project),
                                            commands: commands, title: args["title"] as? String)
            let name = args["name"] as? String ?? "Edit with automation"
            guard !name.isEmpty, name.count <= 256 else { throw EditorAutomationError.invalid("Use a short history action name.") }
            try Task.checkCancellation()
            do {
                _ = try withAutomationChange(origin: origin) { try EditorCommandDispatcher.apply(batch, to: editor, projectID: projectID, name: name) }
            } catch let error as EditorMutationError {
                guard case let .conflicts(items) = error else { throw error }
                return try JSONSerialization.data(withJSONObject: ["ok": false, "error": [
                    "code": "animation_conflict", "message": error.localizedDescription,
                    "conflicts": items.map { ["lane": $0.lane.rawValue,
                        "animation_id": "\($0.lane.rawValue):\($0.componentID.uuidString)",
                        "start": $0.start, "end": $0.end] as [String: Any] }]])
            }
            value = try inspect(["section": "summary"], editor: editor)
        default: throw EditorAutomationError.invalid("Unknown editor action.")
        }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": value], options: [.sortedKeys])
        guard data.count <= 131_072 else { throw EditorAutomationError.invalid("This result is too large. Request paginated edits, boxes, history or events instead.") }
        return data
    }

    /// Native Pause always wins over an awaited automation request. Queued or
    /// rebuilding Play/range requests cannot reassert playback afterward.
    func togglePlayback() {
        guard let playback else { return }
        errorMessage = nil
        if playback.isPlaying || pendingPlaybackIntent != nil {
            previewIntent = UUID(); pendingPlaybackIntent = nil
            playback.pause()
            recordEvent("preview_changed", actorOverride: "manual")
            return
        }
        let intent = UUID(); previewIntent = intent; pendingPlaybackIntent = intent
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if pendingPlaybackIntent == intent { pendingPlaybackIntent = nil } }
            do {
                guard previewIntent == intent else { return }
                let data = try JSONSerialization.data(withJSONObject: ["document_id": documentID, "operation": "play"])
                _ = try await perform("control_preview", arguments: data, origin: "manual", expectedPreviewIntent: intent)
            } catch is CancellationError {
                // A later Pause deliberately superseded this intent.
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func withAutomationChange<T>(origin: String, _ action: () throws -> T) rethrows -> T {
        let previous = actor; actor = origin; defer { actor = previous }
        return try action()
    }

    private func visualState(_ state: EditState) -> EditState {
        var result = state; result.regions = []; result.editAnchors = []; return result
    }
    private func checkRevision(_ args: [String: Any], editor: ProjectEditor, required: Bool) throws {
        let value = args["expected_revision"] as? String
        if required && value == nil { throw EditorCommandError.stale }
        if let value, value != (try EditorCommandDispatcher.revision(for: editor.project)) { throw EditorCommandError.stale }
    }

    private func previewCommand(_ args: [String: Any], editor: ProjectEditor) throws -> EditorPreviewCommand {
        guard let playback, let operation = args["operation"] as? String else { throw EditorPreviewError.unavailable }
        let fields: Set<String>
        let command: EditorPreviewCommand
        func time(_ name: String) throws -> Double {
            let time = try EditorAutomationAPI.number(args[name])
            guard playback.previewSourceBounds.contains(time) else { throw EditorPreviewError.invalidTime }
            return time
        }
        switch operation {
        case "play":
            guard playback.canPlay else { throw EditorPreviewError.unavailable }
            fields = []; command = .play
        case "pause": fields = []; command = .pause
        case "seek": fields = ["time"]; command = .seek(try time("time"))
        case "set_rate":
            fields = ["rate"]; let rate = try EditorAutomationAPI.number(args["rate"])
            guard [0.5, 1.0, 2.0, 5.0].contains(rate) else { throw EditorPreviewError.unsupportedRate }
            command = .setRate(rate)
        case "step_frames":
            guard playback.canPlay else { throw EditorPreviewError.unavailable }
            fields = ["frames"]; command = .stepFrames(try EditorAutomationAPI.integer(args["frames"]))
        case "play_range":
            fields = ["start", "end"]; let start = try time("start"), end = try time("end")
            guard start < end else { throw EditorPreviewError.invalidRange }
            command = .playRange(start: start, end: end)
        case "play_animation":
            fields = ["animation_id", "edit_id"]
            let animations = EditorAnimationEditing.animations(in: editor.editingState, references: editor.references,
                duration: editor.project.duration, includeCamera: editor.project.cameraFilename != nil)
                .filter { $0.lane != .pointer && !$0.isReference && !$0.isInstant }
            let matches: [TimelineAnimation]
            if let id = args["animation_id"] as? String, args["edit_id"] == nil {
                matches = animations.filter { "\($0.lane.rawValue):\($0.componentID.uuidString)" == id }
            } else if args["animation_id"] == nil, let id = args["edit_id"] {
                let uuid = try EditorAutomationAPI.uuid(id)
                matches = animations.filter { $0.editID == uuid || $0.componentID == uuid }
            } else { throw EditorAutomationError.invalid("Identify one animation, including its lane when an edit changes more than one lane.") }
            guard matches.count == 1, let animation = matches.first else { throw EditorAutomationError.invalid("Choose one nonempty animation range from inspect_editor edits.") }
            command = .playRange(start: animation.start, end: animation.end)
        default: throw EditorAutomationError.invalid("Unknown playback action.")
        }
        try EditorAutomationAPI.keys(args, allowed: fields.union(["document_id", "operation"]))
        return command
    }

    private func inspect(_ args: [String: Any], editor: ProjectEditor) throws -> Any {
        let offset = try args["offset"].map { try EditorAutomationAPI.integer($0) } ?? 0
        let limit = try args["limit"].map { try EditorAutomationAPI.integer($0) } ?? 8
        guard offset >= 0, (1...16).contains(limit) else { throw EditorAutomationError.invalid("Use an offset of zero or greater and a limit of 1–16.") }
        func page(_ items: [Any]) -> [String: Any] {
            ["items": Array(items.dropFirst(offset).prefix(limit)), "offset": offset, "total": items.count,
             "omitted": max(0, items.count - offset - limit)]
        }
        let state = editor.editingState
        switch args["section"] as? String {
        case "summary", "view":
            return ["context": try EditorAutomationAPI.object(automationContext), "duration": editor.project.duration,
                "trim": ["start": state.trimStart, "end": state.trimEnd], "edit_count": state.timedEdits(includeCamera: editor.project.cameraFilename != nil).count,
                "box_count": state.regions.count, "undo_count": editor.historyState.undo.count,
                "redo_count": editor.historyState.redo.count, "media_processing_suspended": MediaProcessing.isSuspended]
        case "state": return try EditorAutomationAPI.object(state)
        case "boxes": return page(try state.regions.map { region -> Any in
            ["id": region.id.uuidString, "label": editor.references.boxLabel(for: region.id) ?? "Box",
             "box": try EditorAutomationAPI.object(region)]
        })
        case "edits":
            let animations = EditorAnimationEditing.animations(in: state, references: editor.references,
                duration: editor.project.duration, includeCamera: editor.project.cameraFilename != nil)
            return page(animations.map { animation in
                ["animation_id": "\(animation.lane.rawValue):\(animation.componentID.uuidString)",
                 "edit_id": animation.editID.uuidString, "lane": animation.lane.rawValue,
                 "label": animation.label, "description": animation.help, "start": animation.start, "end": animation.end,
                 "ease_in": animation.easeIn, "ease_out": animation.easeOut, "reference": animation.isReference] as [String: Any]
            })
        case "history":
            return ["undo": page(editor.historyState.undo), "redo": page(editor.historyState.redo),
                "has_draft": editor.draftState != nil,
                "details": ["undo": try historyDetails(.undo, offset: offset, limit: limit, editor: editor),
                            "redo": try historyDetails(.redo, offset: offset, limit: limit, editor: editor)]]
        case "events": return ["page": page(recentEvents), "first_retained_sequence": recentEvents.first?["sequence"] ?? eventSequence,
                                "last_sequence": eventSequence, "retained_limit": 128]
        default: throw EditorAutomationError.invalid("Choose summary, view, edits, boxes, history, state or events.")
        }
    }

    /// Shared history inspector owns snapshot direction and bounded diffs. The
    /// ordinary names remain available while a manual draft makes those saved
    /// snapshot comparisons unavailable; the draft is still the next Undo name.
    private func historyDetails(_ stack: EditorHistoryAction, offset: Int, limit: Int,
                                editor: ProjectEditor) throws -> [String: Any] {
        let limit = min(8, limit)
        if editor.draftState != nil {
            let total = stack == .undo ? editor.historyState.undo.count : editor.historyState.redo.count
            return ["status": "pending_draft", "entries": [], "offset": offset, "limit": limit,
                    "total": total, "has_more": offset < max(0, total - limit)]
        }
        let request = EditorHistoryLookupRequest(projectID: projectID,
            revision: try EditorCommandDispatcher.revision(for: editor.project), stack: stack, offset: offset, limit: limit)
        return try EditorHistoryInspector.page(request, to: editor, projectID: projectID)
    }

    private func actionDescription(_ category: String, operation: String?) throws -> Any {
        switch category {
        case "preview", "navigation", "document":
            let name = ["preview": "control_preview", "navigation": "navigate_editor", "document": "control_document"][category]!
            return EditorAutomationAPI.tools.first { $0["name"] as? String == name }!
        case "editing":
            return try EditorMutation.describe(operation: operation)
        default: throw EditorAutomationError.invalid("Choose preview, navigation, document or editing.")
        }
    }
}

@MainActor
final class EditorAutomationRegistry {
    static let shared = EditorAutomationRegistry()
    private final class WeakHost { weak var value: EditorAutomationHost?; init(_ value: EditorAutomationHost) { self.value = value } }
    private var hosts: [String: WeakHost] = [:]
    func register(_ host: EditorAutomationHost) { hosts[host.documentID] = WeakHost(host) }
    func unregister(_ host: EditorAutomationHost) {
        if hosts[host.documentID]?.value === host { hosts.removeValue(forKey: host.documentID) }
    }
    private var openHosts: [EditorAutomationHost] { hosts.values.compactMap(\.value).sorted { $0.documentID < $1.documentID } }

    func call(_ name: String, arguments: Data) async throws -> Data {
        guard arguments.count <= EditorAutomationAPI.maximumRequestBytes else { throw EditorAutomationError.invalid("This editor request is too large.") }
        if name == "list_recordings" {
            guard let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any], args.isEmpty else {
                throw EditorAutomationError.invalid("list_recordings takes no arguments.")
            }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "recordings": try openHosts.prefix(64).map { try EditorAutomationAPI.object($0.automationContext) }, "omitted": max(0, openHosts.count - 64)])
        }
        guard let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let id = args["document_id"] as? String, let host = hosts[id]?.value else { throw EditorAutomationError.unavailable }
        return try await host.performAutomation(name, arguments: arguments)
    }
    func resourceList() throws -> Data {
        let resources = openHosts.prefix(64).flatMap { host in
            ["view", "edits", "boxes", "history", "events"].map { section in
                ["uri": "framethrower://recordings/\(host.documentID)/\(section)",
                 "name": "\((try? host.automationContext.name) ?? "Recording") · \(section)", "mimeType": "application/json"]
            }
        }
        return try JSONSerialization.data(withJSONObject: resources)
    }
    func read(_ uri: String) async throws -> Data {
        guard let url = URL(string: uri), url.scheme == "framethrower", url.host == "recordings",
              url.query == nil, url.fragment == nil else { throw EditorAutomationError.invalid("Unknown recording resource.") }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, ["view", "edits", "boxes", "history", "events"].contains(parts[1]) else { throw EditorAutomationError.invalid("Unknown recording resource.") }
        return try await call("inspect_editor", arguments: JSONSerialization.data(withJSONObject: ["document_id": parts[0], "section": parts[1]]))
    }
    func startServer() async {
        let backend = FrameThrowerMCPBackend(
            listTools: { try JSONSerialization.data(withJSONObject: EditorAutomationAPI.tools) },
            callTool: { name, arguments in try await EditorAutomationRegistry.shared.call(name, arguments: arguments) },
            listResources: { try await EditorAutomationRegistry.shared.resourceList() },
            readResource: { uri in try await EditorAutomationRegistry.shared.read(uri) })
        do { try await FrameThrowerMCPServer.shared.start(backend: backend) }
        catch { NSLog("FrameThrower automation unavailable: %@", error.localizedDescription) }
    }
}
