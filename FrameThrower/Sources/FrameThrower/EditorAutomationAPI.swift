import Combine
import CoreFoundation
import Foundation

/// Domain identities and units are independent of MCP, App Intents or an LLM.
/// Adapters translate requests; the same endpoint validates and executes them.
struct EditorAutomationContext: Codable, Equatable, Sendable {
    var documentID: String
    var name: String
    var revision: String
    var hasDraft: Bool
    var preview: EditorPreviewSnapshot?
    var selectedEditID: UUID?
    var selectedBoxID: UUID?
    var selectedAnimationID: String?
    var inspector: String?
    /// Persistent recording identity; documentID is an open endpoint handle.
    var recordingID: UUID? = nil
}

struct EditorAutomationEvent: Sendable {
    var actor: String
    var kind: String
    var context: EditorAutomationContext
}

@MainActor
protocol EditorAutomationEndpoint: AnyObject {
    var automationContext: EditorAutomationContext { get throws }
    var automationEvents: AnyPublisher<EditorAutomationEvent, Never> { get }
    func performAutomation(_ name: String, arguments: Data) async throws -> Data
}

struct EditorAutomationCall: Sendable {
    var name: String
    var arguments: Data
}

enum EditorAutomationError: LocalizedError {
    case unavailable, wrongDocument, invalid(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "That recording's editor is not open or ready."
        case .wrongDocument: "The request belongs to a different recording."
        case let .invalid(message): message
        }
    }
}

enum EditorAutomationAPI {
    static let maximumRequestBytes = 262_144
    static let toolNames = ["list_recordings", "inspect_editor", "inspect_recording", "describe_editor_actions", "control_preview",
                            "navigate_editor", "control_document", "apply_edits"]

    static var tools: [[String: Any]] {
        let text: [String: Any] = ["type": "string"]
        let number: [String: Any] = ["type": "number"]
        let doc = ["document_id": text]
        func object(_ properties: [String: Any], required: [String]? = nil) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required ?? properties.keys.sorted(), "additionalProperties": false]
        }
        func tool(_ name: String, _ description: String, _ schema: [String: Any], readOnly: Bool) -> [String: Any] {
            ["name": name, "description": description, "inputSchema": schema,
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": ["apply_edits", "control_document"].contains(name), "openWorldHint": false]]
        }
        return [
            tool("list_recordings", "List open recording editors with opaque document identities. Does not inspect source media.", object([:]), readOnly: true),
            tool("inspect_editor", "Read a bounded section of current state, including manual changes. Seconds are original recording source time. Selection and playhead are separate.", object(doc.merging([
                "section": ["type": "string", "enum": ["summary", "view", "edits", "boxes", "history", "state", "events", "conversation", "pending"]],
                "offset": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 16]
            ]) { _, b in b }, required: ["document_id", "section"]), readOnly: true),
            tool("inspect_recording", "Query bounded recorded semantic metadata on demand, never the live desktop. Search a visible label before asking for all controls. Real source frames remain unavailable while video processing is suspended.", object(doc.merging([
                "detail": ["type": "string", "enum": ["windows", "controls", "search", "frame"]],
                "time": number, "query": text, "window_id": ["type": "integer", "minimum": 1, "maximum": UInt32.max],
                "kind": ["type": "string", "enum": ["menu", "window", "tab", "control", "any"]],
                "limit": ["type": "integer", "minimum": 1, "maximum": 16]
            ]) { _, b in b }, required: ["document_id", "detail", "time"]), readOnly: true),
            tool("describe_editor_actions", "Read units and schemas for a category. Editing returns a compact operation catalog; name one operation for its exact schema, or explicitly request * for all schemas. The domain API is richer than any voice adapter.", object(doc.merging([
                "category": ["type": "string", "enum": ["preview", "navigation", "document", "editing"]], "operation": text
            ]) { _, b in b }, required: ["document_id", "category"]), readOnly: true),
            tool("control_preview", "Transient play/pause/source seek/frame stepping/rate or audition. Never changes edits, export timing or Undo. Play/seek finish a manual draft; pause/rate preserve it. play_animation uses a lane-qualified component identity; not an edit's endpoint.", object(doc.merging([
                "operation": ["type": "string", "enum": ["play", "pause", "seek", "set_rate", "step_frames", "play_range", "play_animation"]],
                "time": number, "rate": ["type": "number", "enum": [0.5, 1, 2, 5]],
                "frames": ["type": "integer"], "start": number, "end": number,
                "animation_id": text, "edit_id": text
            ]) { _, b in b }, required: ["document_id", "operation"]), readOnly: false),
            tool("navigate_editor", "Select without seeking, or explicitly go to a box/edit. Select operations preserve the playhead. Target IDs are the actual UUIDs from inspect_editor, not list positions. No Undo entry.", object(doc.merging([
                "operation": ["type": "string", "enum": ["select_edit", "select_box", "clear_selection", "show_inspector", "go_to_edit", "go_to_box"]],
                "target_id": text, "inspector": ["type": "string", "enum": ["Zoom", "Camera", "Pointer", "Canvas", "Audio"]]
            ]) { _, b in b }, required: ["document_id", "operation"]), readOnly: false),
            tool("control_document", "Save, rename, Undo or Redo this recording using ordinary document behavior. Rename is undoable and keeps source filenames; Save adds no edit of its own. Return actual state and failures.", object(doc.merging([
                "operation": ["type": "string", "enum": ["save", "rename", "undo", "redo"]], "name": text, "count": ["type": "integer", "minimum": 1, "maximum": 128], "expected_revision": text
            ]) { _, b in b }, required: ["document_id", "operation"]), readOnly: false),
            tool("apply_edits", "Validate and apply a typed command batch atomically with one ordinary Undo entry. Optional title joins that same transaction. Get exact mutation schemas from describe_editor_actions first. Screen movement conflicts freeze a proposal for Existing/Proposed review; do not bypass by removing movements. Resolve the returned proposal_id with review_choice keep or replace and commands:[] after the user's choice. Failed validation/save applies nothing; no arbitrary file paths or executables are accepted.", object(doc.merging([
                "expected_revision": text, "name": text, "title": text,
                "proposal_id": text, "review_choice": ["type": "string", "enum": ["keep", "replace"]],
                "commands": ["type": "array", "minItems": 0, "maxItems": 128, "items": ["type": "object"]]
            ]) { _, b in b }, required: ["document_id", "expected_revision", "commands"]), readOnly: false)
        ]
    }

    /// A compact adapter for strict-output CLI backends. MCP retains rich JSON
    /// arguments; only this adapter transports the nested parameters as text.
    static func directorTool(context: EditorAutomationContext) -> [String: Any] {
        ["type": "function", "function": ["name": "editor_action",
          "description": "Use ordinary editor capabilities beyond framing. tools: control_preview (operation play/pause/seek time/set_rate rate/step_frames frames/play_range start,end/play_animation animation_id or edit_id); control_document (save/rename name/undo count/redo count); navigate_editor (select_edit/select_box/go_to_edit/go_to_box target_id/clear_selection/show_inspector inspector); inspect_editor section; inspect_recording detail,time,query; describe_editor_actions category,operation (for editing request one named operation schema); apply_edits commands,name (a brief descriptive history label; optional title joins the transaction). parameters_json is a JSON OBJECT of only the named operation's fields. Preview/navigation are transient, never framing edits. Ask when camera/main-view intent is ambiguous; exact alignment requires a typed mutation, never center-fit.",
          "parameters": ["type": "object", "properties": [
            "document_id": ["type": "string", "enum": [context.documentID]],
            "expected_revision": ["type": "string", "enum": [context.revision]],
            "tool": ["type": "string", "enum": toolNames.filter { $0 != "list_recordings" }],
            "parameters_json": ["type": "string", "maxLength": 65536]
          ], "required": ["document_id", "expected_revision", "tool", "parameters_json"], "additionalProperties": false]]]
    }

    static func parseDirector(_ args: [String: Any], context: EditorAutomationContext) throws -> EditorAutomationCall {
        try keys(args, allowed: ["document_id", "expected_revision", "tool", "parameters_json"])
        guard args["document_id"] as? String == context.documentID,
              args["expected_revision"] as? String == context.revision else { throw EditorCommandError.stale }
        guard let name = args["tool"] as? String, toolNames.contains(name), name != "list_recordings",
              let text = args["parameters_json"] as? String, text.utf8.count <= 65536,
              var params = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              params["document_id"] == nil, params["expected_revision"] == nil else {
            throw EditorAutomationError.invalid("Use a known editor action and a JSON object without embedded scope overrides.")
        }
        params["document_id"] = context.documentID
        if name == "apply_edits" {
            guard params["name"] == nil || params["name"] is String else { throw EditorAutomationError.invalid("Use text for the history action name.") }
            let label = params["name"] as? String ?? "Edit"
            params["name"] = label.hasPrefix("Director:") ? label : "Director: " + label
        }
        if name == "apply_edits" || name == "control_document" { params["expected_revision"] = context.revision }
        return EditorAutomationCall(name: name, arguments: try JSONSerialization.data(withJSONObject: params))
    }

    static func keys(_ args: [String: Any], allowed: Set<String>) throws {
        guard Set(args.keys).isSubset(of: allowed) else { throw EditorAutomationError.invalid("The editor action contains unsupported fields.") }
    }
    static func number(_ value: Any?) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw EditorAutomationError.invalid("Use a finite numeric value.")
        }
        return value.doubleValue
    }
    static func integer(_ value: Any?) throws -> Int {
        let number = try number(value)
        guard number.rounded() == number, abs(number) <= 1_000_000 else { throw EditorAutomationError.invalid("Use a bounded whole number.") }
        return Int(number)
    }
    static func uuid(_ value: Any?) throws -> UUID {
        guard let text = value as? String, let id = UUID(uuidString: text) else { throw EditorAutomationError.invalid("Use an existing entity identity.") }
        return id
    }
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
