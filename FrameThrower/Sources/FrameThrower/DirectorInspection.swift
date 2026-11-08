import CoreFoundation
import CryptoKit
import Foundation

struct DirectorInspectionCapabilities: Codable, Equatable, Sendable {
    var scene: Bool
    var frame: Bool
}

struct DirectorSceneInspectionRequest: Sendable {
    enum Detail: String, Sendable { case windows, controls, search }
    enum Kind: String, Sendable { case menu, window, tab, control, any }
    var projectID: UUID
    var revision: String
    var sourceTime: Double
    var detail: Detail
    var windowID: UInt32? = nil
    var limit: Int = 8
    var query: String? = nil
    var kind: Kind? = nil
}

struct DirectorFrameInspectionRequest: Sendable {
    var projectID: UUID
    var revision: String
    var sourceTime: Double
}

enum DirectorObservationTarget: Sendable {
    case recorded(String)
    case imageRect(EditorRegionRect)
}

struct DirectorObservationFramingRequest: Sendable {
    var projectID: UUID
    var revision: String
    var observationID: UUID
    var target: DirectorObservationTarget
    var marginPixels: Double
    /// Arrival time, matching the ordinary frameRegion command.
    var time: Double
    var motion: EditorCommandMotion = EditorCommandMotion()
}

enum DirectorInspectionAction: Sendable {
    case scene(DirectorSceneInspectionRequest)
    case frame(DirectorFrameInspectionRequest)
    case frameObservation(DirectorObservationFramingRequest)

    var projectID: UUID {
        switch self {
        case let .scene(value): value.projectID
        case let .frame(value): value.projectID
        case let .frameObservation(value): value.projectID
        }
    }
    var revision: String {
        switch self {
        case let .scene(value): value.revision
        case let .frame(value): value.revision
        case let .frameObservation(value): value.revision
        }
    }
}

struct DirectorInspectionFrame: Sendable {
    var sourceTime: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var png: Data
}

struct DirectorInspectionObservation: Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let revision: String
    let sourceTime: Double
    let pixelWidth: Int
    let pixelHeight: Int
    /// Bounded model-facing projection, never a raw AX snapshot or media path.
    let result: Data
    let imagePNG: Data?
    let imageSHA256: String?

    func imageMessage(toolCallID: String) -> [String: Any]? {
        guard let imagePNG, let imageSHA256, !toolCallID.isEmpty else { return nil }
        let metadata: [String: Any] = ["frame_id": id.uuidString, "project_id": projectID.uuidString,
            "expected_revision": revision, "source_time": sourceTime,
            "source_width": pixelWidth, "source_height": pixelHeight,
            "sha256": imageSHA256, "originating_tool_call_id": toolCallID,
            "evidence": "synthetic_fixture"]
        guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return ["role": "user", "content": [["type": "text", "text": text],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64," + imagePNG.base64EncodedString(), "detail": "high"]]]]
    }
}

enum DirectorInspectionOutcome: Sendable {
    case observation(DirectorInspectionObservation)
    case proposal(EditorCommandBatch, summary: String)
}

enum DirectorInspectionError: LocalizedError {
    case sceneUnavailable, frameUnavailable, imagesUnsupported, expiredObservation, unknownTarget, invalid(String)
    var errorDescription: String? {
        switch self {
        case .sceneUnavailable: "Recorded scene metadata is unavailable at that source time. Identify an existing box instead."
        case .frameUnavailable: "Recorded source frames are unavailable while video processing is suspended. No frame was opened."
        case .imagesUnsupported: "This model accepts text only. Choose an image-capable model to inspect a source frame."
        case .expiredObservation: "That observation expired or belongs to another recording revision. Inspect the recording again."
        case .unknownTarget: "The target was not included in that recorded observation. Inspect it again before framing it."
        case let .invalid(message): message
        }
    }
}

/// Pure schemas/parser/geometry. No live desktop, image decoder or media API.
enum DirectorInspection {
    static let maximumResultBytes = 6 * 1024

    static func tools(capabilities: DirectorInspectionCapabilities) -> [[String: Any]] {
        let number: [String: Any] = ["type": "number", "minimum": 0]
        var result: [[String: Any]] = []
        if capabilities.scene {
            result.append(function("find_scene_targets", "Look up a named target in recorded visible labels at a source time. Prefer this for requests such as File menu or a named tab. Returns compact candidates with exact IDs, geometry, recorded application/window/role and observation age, including visible menus without window IDs. Exact case-folded labels match first, then substring matches; ambiguous candidates are not selected automatically. No live desktop queries or guessed bounds.", [
                "time_seconds": number, "query": ["type": "string", "minLength": 1, "maxLength": 160],
                "kind": ["type": "string", "enum": ["menu", "window", "tab", "control", "any"]],
                "limit": ["type": "integer", "minimum": 1, "maximum": 8]]))
            result.append(function("inspect_scene", "Read recorded windows at a source time on demand. Start with windows; request controls only for a returned window_id. Reports observation age and omitted counts. Never queries the current desktop.", [
                "time_seconds": number, "detail": ["type": "string", "enum": ["windows", "controls"]],
                "window_id": ["type": "integer", "minimum": 1, "maximum": UInt32.max],
                "limit": ["type": "integer", "minimum": 1, "maximum": 16]], optional: ["window_id"]))
        }
        if capabilities.frame {
            result.append(function("inspect_frame", "Request the original recorded source frame at a source time. Returns immutable frame metadata and an image attachment, never the current desktop or an edited preview.", ["time_seconds": number]))
        }
        if capabilities.scene || capabilities.frame {
            let rect: [String: Any] = ["type": "object", "properties": Dictionary(uniqueKeysWithValues:
                ["x", "y", "width", "height"].map { ($0, ["type": "number", "minimum": 0, "maximum": 1] as [String: Any]) }),
                "required": ["x", "y", "width", "height"], "additionalProperties": false]
            let target: [String: Any] = ["anyOf": [
                ["type": "object", "properties": ["kind": ["type": "string", "enum": ["recorded"]], "id": ["type": "string"]],
                 "required": ["kind", "id"], "additionalProperties": false],
                ["type": "object", "properties": ["kind": ["type": "string", "enum": ["image_rect"]], "rect": rect],
                 "required": ["kind", "rect"], "additionalProperties": false]]]
            result.append(function("frame_observation", "Propose a Box and ordinary screen framing from an earlier observation. Use an exact returned recorded target ID, or normalized image bounds from a frame image. margin_pixels is measured in ORIGINAL source pixels; the host fits video aspect and clamps at source edges. time_seconds is arrival; duration_seconds is movement duration. Does not apply anything until the normal command boundary.", [
                "observation_id": ["type": "string"], "target": target,
                "margin_pixels": ["type": "number", "minimum": 0, "maximum": 2048], "time_seconds": number,
                "duration_seconds": ["type": "number", "exclusiveMinimum": 0, "maximum": 60]]))
        }
        return result
    }

    static func parse(name: String, args: [String: Any], context: EditorCommandContext) throws -> DirectorInspectionAction? {
        guard ["find_scene_targets", "inspect_scene", "inspect_frame", "frame_observation"].contains(name) else { return nil }
        guard try integer(args["version"]) == 1,
              let project = args["project_id"] as? String, UUID(uuidString: project) == context.projectID,
              let revision = args["expected_revision"] as? String, revision == context.revision else { throw EditorCommandError.stale }
        let common: Set<String> = ["version", "project_id", "expected_revision"]
        func time(_ key: String) throws -> Double {
            let value = try number(args[key])
            guard context.duration.isFinite, context.duration > 0, (0...context.duration).contains(value) else { throw DirectorInspectionError.invalid("Use a source time inside the recording.") }
            return value
        }
        switch name {
        case "find_scene_targets":
            guard Set(args.keys) == common.union(["time_seconds", "query", "kind", "limit"]),
                  let rawQuery = args["query"] as? String,
                  let kind = (args["kind"] as? String).flatMap(DirectorSceneInspectionRequest.Kind.init(rawValue:)) else {
                throw DirectorInspectionError.invalid("Target lookup requires a visible label, target kind, and bounded limit.")
            }
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines), limit = try integer(args["limit"])
            guard !query.isEmpty, query.count <= 160, (1...8).contains(limit) else {
                throw DirectorInspectionError.invalid("Look up a visible label of at most 160 characters and request one to eight candidates.")
            }
            return .scene(.init(projectID: context.projectID, revision: context.revision, sourceTime: try time("time_seconds"),
                detail: .search, limit: limit, query: query, kind: kind))
        case "inspect_scene":
            guard Set(args.keys).isSubset(of: common.union(["time_seconds", "detail", "window_id", "limit"])),
                  let detail = (args["detail"] as? String).flatMap(DirectorSceneInspectionRequest.Detail.init(rawValue:)), detail != .search else {
                throw DirectorInspectionError.invalid("Use windows or controls for a recorded scene inspection.")
            }
            let limit = try integer(args["limit"])
            guard (1...16).contains(limit) else { throw DirectorInspectionError.invalid("Inspect between one and 16 entries at a time.") }
            let rawWindow = try args["window_id"].map { try integer($0) }
            guard rawWindow.map({ $0 > 0 && $0 <= Int(UInt32.max) }) ?? true,
                  detail != .controls || rawWindow != nil else {
                throw DirectorInspectionError.invalid("Controls inspection requires a recorded window_id.")
            }
            return .scene(.init(projectID: context.projectID, revision: context.revision, sourceTime: try time("time_seconds"),
                detail: detail, windowID: rawWindow.map(UInt32.init), limit: limit))
        case "inspect_frame":
            guard Set(args.keys) == common.union(["time_seconds"]) else { throw DirectorInspectionError.invalid("Frame inspection contains unsupported fields.") }
            return .frame(.init(projectID: context.projectID, revision: context.revision, sourceTime: try time("time_seconds")))
        default:
            guard Set(args.keys) == common.union(["observation_id", "target", "margin_pixels", "time_seconds", "duration_seconds"]),
                  let rawID = args["observation_id"] as? String, let id = UUID(uuidString: rawID),
                  let target = args["target"] as? [String: Any], let kind = target["kind"] as? String else {
                throw DirectorInspectionError.invalid("Framing requires an existing observation and a recorded or image target.")
            }
            let selected: DirectorObservationTarget
            if kind == "recorded", Set(target.keys) == ["kind", "id"], let id = target["id"] as? String, !id.isEmpty, id.count <= 160 {
                selected = .recorded(id)
            } else if kind == "image_rect", Set(target.keys) == ["kind", "rect"], let rect = target["rect"] as? [String: Any], Set(rect.keys) == ["x", "y", "width", "height"] {
                let value = EditorRegionRect(x: try number(rect["x"]), y: try number(rect["y"]), width: try number(rect["width"]), height: try number(rect["height"]))
                guard value.isValid else { throw DirectorInspectionError.invalid("Use normalized image bounds inside the complete source frame.") }
                selected = .imageRect(value)
            } else { throw DirectorInspectionError.unknownTarget }
            let margin = try number(args["margin_pixels"])
            guard (0...2048).contains(margin) else { throw DirectorInspectionError.invalid("Use a source-pixel margin between zero and 2,048.") }
            let motion = EditorCommandMotion(duration: try number(args["duration_seconds"]))
            try motion.validate()
            return .frameObservation(.init(projectID: context.projectID, revision: context.revision, observationID: id,
                target: selected, marginPixels: margin, time: try time("time_seconds"), motion: motion))
        }
    }

    /// A uniform source zoom has a square normalized viewport regardless of
    /// source aspect. Grow both axes to fit; never shrink/crop the chosen target.
    static func fittedRect(_ rect: EditorRegionRect, pixelWidth: Int, pixelHeight: Int, marginPixels: Double) throws -> EditorRegionRect {
        guard rect.isValid, pixelWidth > 0, pixelHeight > 0, pixelWidth <= 32768, pixelHeight <= 32768,
              marginPixels.isFinite, (0...2048).contains(marginPixels) else {
            throw DirectorInspectionError.invalid("Use valid original-pixel dimensions, normalized bounds, and a bounded margin.")
        }
        let dx = marginPixels / Double(pixelWidth), dy = marginPixels / Double(pixelHeight)
        let left = max(0, rect.x - dx), top = max(0, rect.y - dy)
        let right = min(1, rect.x + rect.width + dx), bottom = min(1, rect.y + rect.height + dy)
        let side = min(1, max(1 / 3.0, right - left, bottom - top))
        return EditorRegionRect(x: min(1 - side, max(0, (left + right - side) / 2)),
            y: min(1 - side, max(0, (top + bottom - side) / 2)), width: side, height: side)
    }

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], optional: Set<String> = []) -> [String: Any] {
        var fields: [String: Any] = ["version": ["type": "integer", "const": 1], "project_id": ["type": "string"], "expected_revision": ["type": "string"]]
        fields.merge(properties) { _, new in new }
        return ["type": "function", "function": ["name": name, "description": description, "parameters": [
            "type": "object", "properties": fields, "required": fields.keys.filter { !optional.contains($0) }.sorted(), "additionalProperties": false]]]
    }

    private static func number(_ value: Any?) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw DirectorInspectionError.invalid("Inspection requires finite numeric values.")
        }
        return value.doubleValue
    }
    private static func integer(_ value: Any?) throws -> Int {
        let value = try number(value)
        guard value.rounded() == value, value >= Double(Int32.min), value <= Double(UInt32.max) else {
            throw DirectorInspectionError.invalid("Inspection requires bounded whole-number values.")
        }
        return Int(value)
    }
}

/// This cache holds immutable, explicitly requested observations. Production has
/// no frame extractor while the media interlock is active. Its only injectable
/// image path is named syntheticFrameProvider and marked as synthetic in output.
@MainActor
final class DirectorInspectionCache {
    typealias FrameProvider = @Sendable (Double) async throws -> DirectorInspectionFrame
    private var scene: RecordedScene?
    private let sceneURL: URL?
    private let syntheticFrameProvider: FrameProvider?
    private var sceneTask: Task<RecordedScene, any Error>?
    private var sceneValidated = false
    private struct Stored {
        var observation: DirectorInspectionObservation
        var targets: [String: EditorRegionRect]
    }
    private var observations: [UUID: Stored] = [:]
    private var order: [UUID] = []
    private var scope: String?

    init(scene: RecordedScene? = nil) {
        self.scene = scene; sceneURL = nil; syntheticFrameProvider = nil
    }
    init(scene: RecordedScene? = nil, syntheticFrameProvider: @escaping FrameProvider) {
        self.scene = scene; sceneURL = nil; self.syntheticFrameProvider = syntheticFrameProvider
    }
    init(recordedSceneURL: URL?, syntheticFrameProvider: FrameProvider? = nil) {
        scene = nil; sceneURL = recordedSceneURL; self.syntheticFrameProvider = syntheticFrameProvider
    }

    func capabilities(supportsImages: Bool) -> DirectorInspectionCapabilities {
        .init(scene: scene != nil || sceneURL != nil, frame: supportsImages && syntheticFrameProvider != nil)
    }

    var hasObservations: Bool { !observations.isEmpty }

    func validatedObservation(id: UUID, project: RecordingProject, projectID: UUID) throws -> DirectorInspectionObservation {
        guard let value = observations[id]?.observation, value.projectID == projectID,
              value.revision == (try EditorCommandDispatcher.revision(for: project)) else { throw DirectorInspectionError.expiredObservation }
        return value
    }

    func close() {
        sceneTask?.cancel(); sceneTask = nil
        observations.removeAll(); order.removeAll(); scope = nil
    }

    func perform(_ action: DirectorInspectionAction, project: RecordingProject, projectID: UUID, supportsImages: Bool,
                 maximumResultBytes: Int = DirectorInspection.maximumResultBytes) async throws -> DirectorInspectionOutcome {
        try Task.checkCancellation()
        guard (1536...DirectorInspection.maximumResultBytes).contains(maximumResultBytes) else {
            throw DirectorInspectionError.invalid("The inspection metadata budget must be between 1,536 and 6,144 bytes.")
        }
        let revision = try EditorCommandDispatcher.revision(for: project)
        guard action.projectID == projectID, action.revision == revision else { throw EditorCommandError.stale }
        let nextScope = projectID.uuidString + ":" + revision
        if scope != nextScope { observations.removeAll(); order.removeAll(); scope = nextScope }
        switch action {
        case let .scene(request):
            try validate(time: request.sourceTime, duration: project.duration)
            guard (1...16).contains(request.limit), request.detail != .controls || request.windowID != nil else {
                throw DirectorInspectionError.invalid("Controls require a recorded window ID and a limit of one to 16 entries.")
            }
            if request.detail == .search {
                guard let query = request.query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      query.count <= 160, request.limit <= 8 else {
                    throw DirectorInspectionError.invalid("Target lookup requires a visible label and a limit of one to eight candidates.")
                }
            }
            let scene = try await recordedScene()
            try Task.checkCancellation()
            let durationTolerance = min(1.0 / 30, project.captureFrameDuration ?? 1.0 / 30) + 0.000_001
            guard abs(scene.duration - project.duration) <= durationTolerance else { throw DirectorInspectionError.sceneUnavailable }
            guard let snapshot = scene.snapshot(at: request.sourceTime) else { throw DirectorInspectionError.sceneUnavailable }
            return .observation(try sceneObservation(request, snapshot: snapshot, scene: scene, maximumResultBytes: maximumResultBytes))
        case let .frame(request):
            try validate(time: request.sourceTime, duration: project.duration)
            guard supportsImages else { throw DirectorInspectionError.imagesUnsupported }
            guard let syntheticFrameProvider else { throw DirectorInspectionError.frameUnavailable }
            let frame: DirectorInspectionFrame
            do { frame = try await syntheticFrameProvider(request.sourceTime) }
            catch is CancellationError { throw CancellationError() }
            catch { throw DirectorInspectionError.frameUnavailable }
            try Task.checkCancellation()
            try validate(time: frame.sourceTime, duration: project.duration)
            guard frame.sourceTime < project.duration else { throw DirectorInspectionError.invalid("An inspected frame must precede the recording's exclusive end.") }
            try validatePNG(frame)
            let id = UUID(), hash = SHA256.hash(data: frame.png).map { String(format: "%02x", $0) }.joined()
            let result: [String: Any] = ["ok": true, "observation_id": id.uuidString, "frame_id": id.uuidString,
                "project_id": projectID.uuidString, "expected_revision": revision, "kind": "frame",
                "requested_time": request.sourceTime, "source_time": frame.sourceTime,
                "pixel_width": frame.pixelWidth, "pixel_height": frame.pixelHeight, "sha256": hash,
                "evidence": "synthetic_fixture", "image_attached": true]
            let observation = DirectorInspectionObservation(id: id, projectID: projectID, revision: revision,
                sourceTime: frame.sourceTime, pixelWidth: frame.pixelWidth, pixelHeight: frame.pixelHeight,
                result: try json(result), imagePNG: frame.png, imageSHA256: hash)
            store(observation, targets: [:])
            return .observation(observation)
        case let .frameObservation(request):
            try validate(time: request.time, duration: project.duration)
            try request.motion.validate()
            guard let stored = observations[request.observationID], stored.observation.projectID == projectID,
                  stored.observation.revision == revision else { throw DirectorInspectionError.expiredObservation }
            let rect: EditorRegionRect
            switch request.target {
            case let .recorded(id):
                guard let target = stored.targets[id] else { throw DirectorInspectionError.unknownTarget }
                rect = target
            case let .imageRect(value):
                guard stored.observation.imagePNG != nil, supportsImages else { throw DirectorInspectionError.unknownTarget }
                rect = value
            }
            let observation = stored.observation
            guard request.time < project.duration, observation.sourceTime < project.duration else {
                throw DirectorInspectionError.invalid("Framing and its observed source moment must precede the recording's exclusive end.")
            }
            let fitted = try DirectorInspection.fittedRect(rect, pixelWidth: observation.pixelWidth,
                pixelHeight: observation.pixelHeight, marginPixels: request.marginPixels)
            let region = EditorRegion(time: observation.sourceTime, rect: fitted, framingPadding: 0)
            let batch = EditorCommandBatch(projectID: projectID, revision: revision, commands: [
                .addRegion(region: region), .frameRegion(regionID: region.id, time: request.time, motion: request.motion)])
            // Same validation and conflict behavior as every other typed plan.
            _ = try EditorCommandDispatcher.prepare(batch, for: project, projectID: projectID)
            let margin = request.marginPixels.formatted(.number.precision(.fractionLength(0...2)))
            let clipped = rect.x * Double(observation.pixelWidth) < request.marginPixels ||
                rect.y * Double(observation.pixelHeight) < request.marginPixels ||
                (1 - rect.x - rect.width) * Double(observation.pixelWidth) < request.marginPixels ||
                (1 - rect.y - rect.height) * Double(observation.pixelHeight) < request.marginPixels
            return .proposal(batch, summary: clipped
                ? "Framed the observed target; the recording edge limits its \(margin)-pixel margin."
                : "Framed the observed target, fitting the requested \(margin)-pixel border to the video.")
        }
    }

    private func recordedScene() async throws -> RecordedScene {
        if let scene, sceneValidated { return scene }
        guard scene != nil || sceneURL != nil else { throw DirectorInspectionError.sceneUnavailable }
        let task: Task<RecordedScene, any Error>
        if let sceneTask { task = sceneTask }
        else {
            let injected = scene, url = sceneURL
            task = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let scene: RecordedScene
                if let injected { try injected.validate(); scene = injected }
                else if let url { scene = try RecordedScene.load(from: url) }
                else { throw DirectorInspectionError.sceneUnavailable }
                try Task.checkCancellation()
                return scene
            }
            sceneTask = task
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            scene = value; sceneTask = nil; sceneValidated = true
            return value
        } catch is CancellationError { sceneTask = nil; throw CancellationError() }
        catch { sceneTask = nil; throw DirectorInspectionError.sceneUnavailable }
    }

    private func sceneObservation(_ request: DirectorSceneInspectionRequest, snapshot: RecordedSceneSnapshot, scene: RecordedScene, maximumResultBytes: Int) throws -> DirectorInspectionObservation {
        let id = UUID(), width = scene.source.pixelWidth, height = scene.source.pixelHeight
        if let windowID = request.windowID, !snapshot.windows.contains(where: { $0.id == windowID }) {
            throw DirectorInspectionError.unknownTarget
        }
        var targets: [String: EditorRegionRect] = [:]
        var rows: [[String: Any]] = []
        var match: String? = nil
        if request.detail == .search {
            let search = searchRows(request, snapshot: snapshot, width: width, height: height)
            rows = search.rows; targets = search.targets; match = search.match
        } else if request.detail == .windows {
            for window in snapshot.windows.sorted(by: { $0.zOrder < $1.zOrder }) where request.windowID == nil || request.windowID == window.id {
                let targetID = "window:\(window.id)"
                let rect = normalized(window.frame, width: width, height: height)
                if let rect { targets[targetID] = rect }
                var row: [String: Any] = ["target_id": targetID, "window_id": Int(window.id), "z": window.zOrder,
                    "target_available": rect != nil, "recorder_application": window.isRecorderApplication]
                if let rect { row["rect"] = rectangle(rect) }
                if let value = window.application { row["application"] = String(value.prefix(80)) }
                if let value = window.bundleID { row["bundle_id"] = String(value.prefix(120)) }
                if let value = window.title { row["title"] = String(value.prefix(160)) }
                if let value = window.documentURL { row["document_url"] = String(value.prefix(240)) }
                if let value = window.isFocused { row["focused"] = value }
                if let value = window.occlusionEstimate { row["occlusion_estimate"] = value; row["occlusion_inferred"] = window.occlusionIsInferred }
                if (window.application?.count ?? 0) > 80 || (window.bundleID?.count ?? 0) > 120 ||
                    (window.title?.count ?? 0) > 160 || (window.documentURL?.count ?? 0) > 240 { row["text_truncated"] = true }
                rows.append(row)
            }
        } else {
            for element in snapshot.elements where element.windowID == request.windowID {
                let targetID = "element:" + element.id
                let rect = normalized(element.frame, width: width, height: height)
                if let rect { targets[targetID] = rect }
                var row: [String: Any] = ["target_id": targetID, "role": String(element.role.prefix(80)),
                    "text_redacted": element.textRedacted, "target_available": rect != nil]
                if let rect { row["rect"] = rectangle(rect) }
                if let value = element.label { row["label"] = String(value.prefix(160)) }
                if let value = element.parentID { row["parent_id"] = "element:" + value }
                if let value = element.isSelected { row["selected"] = value }
                if let value = element.isExpanded { row["expanded"] = value }
                if let value = element.isEnabled { row["enabled"] = value }
                row["is_tab"] = element.isTab; row["is_menu"] = isMenu(element)
                if let value = element.subrole { row["subrole"] = String(value.prefix(80)) }
                if let value = element.documentURL { row["document_url"] = String(value.prefix(240)) }
                if element.role.count > 80 || (element.label?.count ?? 0) > 160 ||
                    (element.subrole?.count ?? 0) > 80 || (element.documentURL?.count ?? 0) > 240 { row["text_truncated"] = true }
                rows.append(row)
            }
        }
        let total = rows.count
        rows = Array(rows.prefix(request.limit))
        func result() -> [String: Any] {
            var value: [String: Any] = ["ok": true, "observation_id": id.uuidString,
                "project_id": request.projectID.uuidString, "expected_revision": request.revision, "kind": "scene",
                "requested_time": request.sourceTime, "source_time": snapshot.time, "age_seconds": max(0, request.sourceTime - snapshot.time) + (snapshot.observationAgeOffset ?? 0),
                "pixel_width": width, "pixel_height": height, "detail": request.detail.rawValue,
                "total": total, "returned": rows.count, "omitted": total - rows.count,
                "truncated": snapshot.availability.truncated || total > rows.count,
                "archive_truncated": snapshot.availability.truncated,
                "windows_available": snapshot.availability.windows,
                "accessibility_trusted": snapshot.availability.accessibilityTrusted,
                "controls_collected": snapshot.availability.accessibilityCollected,
                "observation_duration": snapshot.observationDuration,
                request.detail == .windows ? "windows" : (request.detail == .search ? "candidates" : "controls"): rows]
            if let age = snapshot.accessibilityAge { value["accessibility_age_seconds"] = age + (snapshot.observationAgeOffset ?? 0) }
            if let windowID = request.windowID { value["window_id"] = Int(windowID) }
            if request.detail == .search {
                value["query"] = request.query; value["target_kind"] = (request.kind ?? .any).rawValue; value["match"] = match
            }
            return value
        }
        var data = try json(result())
        while data.count > maximumResultBytes, !rows.isEmpty {
            rows.removeLast(); data = try json(result())
        }
        guard data.count <= maximumResultBytes else { throw DirectorInspectionError.invalid("The scene response exceeds its metadata budget.") }
        let returnedIDs = Set(rows.compactMap { $0["target_id"] as? String })
        targets = targets.filter { returnedIDs.contains($0.key) }
        let observation = DirectorInspectionObservation(id: id, projectID: request.projectID, revision: request.revision,
            sourceTime: snapshot.time, pixelWidth: width, pixelHeight: height, result: data, imagePNG: nil, imageSHA256: nil)
        store(observation, targets: targets)
        return observation
    }

    private func isMenu(_ element: RecordedSceneElement) -> Bool {
        element.isMenu || ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"].contains(element.role)
    }

    private func searchRows(_ request: DirectorSceneInspectionRequest, snapshot: RecordedSceneSnapshot,
                            width: Int, height: Int) -> (rows: [[String: Any]], targets: [String: EditorRegionRect], match: String) {
        struct Candidate {
            var row: [String: Any]
            var labels: [String]
            var target: EditorRegionRect?
        }
        func folded(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let kind = request.kind ?? .any, query = folded(request.query ?? "")
        var candidates: [Candidate] = []
        if kind == .window || kind == .any {
            for window in snapshot.windows.sorted(by: { $0.zOrder < $1.zOrder }) {
                let target = normalized(window.frame, width: width, height: height)
                var row: [String: Any] = ["target_id": "window:\(window.id)", "kind": "window", "role": "CGWindow",
                    "window_id": Int(window.id), "target_available": target != nil,
                    "label": String((window.title ?? window.application ?? "").prefix(160)), "recorder_application": window.isRecorderApplication]
                if let target { row["rect"] = rectangle(target) }
                if let value = window.application { row["application"] = String(value.prefix(80)) }
                if let value = window.bundleID { row["bundle_id"] = String(value.prefix(120)) }
                if let value = window.isFocused { row["focused"] = value }
                if (window.title?.count ?? 0) > 160 || (window.application?.count ?? 0) > 80 || (window.bundleID?.count ?? 0) > 120 { row["text_truncated"] = true }
                candidates.append(Candidate(row: row, labels: [window.title, window.application].compactMap { $0 }, target: target))
            }
        }
        for element in snapshot.elements {
            let menu = isMenu(element)
            let category: DirectorSceneInspectionRequest.Kind = menu ? .menu : (element.isTab ? .tab : .control)
            guard kind == .any || kind == category, let label = element.label, !element.textRedacted else { continue }
            let target = normalized(element.frame, width: width, height: height)
            var row: [String: Any] = ["target_id": "element:" + element.id, "kind": category.rawValue,
                "role": String(element.role.prefix(80)), "label": String(label.prefix(160)),
                "is_menu": menu, "is_tab": element.isTab, "target_available": target != nil]
            if let target { row["rect"] = rectangle(target) }
            if let value = element.windowID { row["window_id"] = Int(value) }
            let window = element.windowID.flatMap { id in snapshot.windows.first { $0.id == id } }
            let application = (window ?? snapshot.windows.first { $0.processID == element.processID })?.application
            if let application { row["application"] = String(application.prefix(80)) }
            if let title = window?.title { row["window_title"] = String(title.prefix(120)) }
            if let value = element.subrole { row["subrole"] = String(value.prefix(80)) }
            if let value = element.isSelected { row["selected"] = value }
            if let value = element.isExpanded { row["expanded"] = value }
            if let value = element.documentURL { row["document_url"] = String(value.prefix(240)) }
            if label.count > 160 || element.role.count > 80 || (element.subrole?.count ?? 0) > 80 ||
                (element.documentURL?.count ?? 0) > 240 || (application?.count ?? 0) > 80 || (window?.title?.count ?? 0) > 120 { row["text_truncated"] = true }
            candidates.append(Candidate(row: row, labels: [label], target: target))
        }
        let exact = candidates.filter { $0.labels.contains { folded($0) == query } }
        let selected = exact.isEmpty ? candidates.filter { $0.labels.contains { folded($0).contains(query) } } : exact
        var targets: [String: EditorRegionRect] = [:]
        for candidate in selected {
            if let id = candidate.row["target_id"] as? String, let target = candidate.target { targets[id] = target }
        }
        return (selected.map(\.row), targets, selected.isEmpty ? "none" : (exact.isEmpty ? "contains" : "exact"))
    }

    private func normalized(_ frame: CGRect, width: Int, height: Int) -> EditorRegionRect? {
        let clipped = frame.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard RecordedSceneSource.valid(clipped) else { return nil }
        let x = clipped.minX / Double(width), y = clipped.minY / Double(height)
        let result = EditorRegionRect(x: x, y: y,
            width: min(1 - x, clipped.width / Double(width)), height: min(1 - y, clipped.height / Double(height)))
        return result.isValid ? result : nil
    }
    private func rectangle(_ rect: EditorRegionRect) -> [String: Double] {
        ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height]
    }
    private func validate(time: Double, duration: Double) throws {
        guard time.isFinite, duration.isFinite, duration > 0, (0...duration).contains(time) else {
            throw DirectorInspectionError.invalid("Use a source time inside the recording.")
        }
    }
    private func validatePNG(_ frame: DirectorInspectionFrame) throws {
        let bytes = [UInt8](frame.png.prefix(33))
        guard frame.png.count >= 45, frame.png.count <= 7 * 1024 * 1024, bytes.count == 33,
              Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              Array(bytes[8..<16]) == [0, 0, 0, 13, 73, 72, 68, 82],
              frame.pixelWidth > 0, frame.pixelWidth <= 8000, frame.pixelHeight > 0, frame.pixelHeight <= 8000,
              frame.pixelWidth * frame.pixelHeight <= 32_000_000 else {
            throw DirectorInspectionError.invalid("The synthetic fixture must be a bounded, original-size PNG.")
        }
        func integer(_ offset: Int) -> Int { bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) } }
        guard integer(16) == frame.pixelWidth, integer(20) == frame.pixelHeight else {
            throw DirectorInspectionError.invalid("The PNG dimensions do not match the frame's original-pixel metadata.")
        }
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func store(_ observation: DirectorInspectionObservation, targets: [String: EditorRegionRect]) {
        observations[observation.id] = Stored(observation: observation, targets: targets); order.append(observation.id)
        while order.count > 8 || observations.values.reduce(0, { $0 + ($1.observation.imagePNG?.count ?? 0) }) > 16 * 1024 * 1024 {
            observations.removeValue(forKey: order.removeFirst())
        }
    }
    deinit { sceneTask?.cancel() }
}
