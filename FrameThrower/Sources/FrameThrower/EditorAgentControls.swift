import CoreFoundation
import Foundation

enum EditorHistoryAction: String, Codable, Sendable {
    case undo, redo
}

/// History is the same ordered stack used by the editor's normal controls.
/// Requests cannot select an older entry while leaving newer entries applied.
struct EditorHistoryRequest: Codable, Equatable, Sendable {
    var version = 1
    var projectID: UUID
    var revision: String
    var action: EditorHistoryAction
    var count: Int
}

enum EditorHistoryDispatcher {
    @MainActor
    static func apply(_ request: EditorHistoryRequest, to editor: ProjectEditor,
                      projectID: UUID) throws {
        guard request.version == 1 else { throw EditorCommandError.invalid("This history request uses an unsupported version.") }
        guard editor.draftState == nil else { throw EditorCommandError.pendingDraft }
        guard request.projectID == projectID,
              request.revision == (try EditorCommandDispatcher.revision(for: editor.project)) else {
            throw EditorCommandError.stale
        }
        let available = request.action == .undo ? editor.project.undoHistory.count : editor.project.redoHistory.count
        guard request.count >= 1, request.count <= available else {
            throw EditorCommandError.invalid("There are \(available) changes available to \(request.action.rawValue).")
        }
        let succeeded = request.action == .undo ? editor.undo(count: request.count) : editor.redo(count: request.count)
        guard succeeded else {
            throw EditorCommandError.saveFailed(editor.errorMessage ?? "The history change could not be saved.")
        }
    }
}

/// Tools for managing reference marks and traversing shared edit history.
/// They contain no media, file, executable, network, or selective-undo actions.
enum EditorAgentControls {
    static func tools(for request: String) -> [[String: Any]]? {
        if request.range(of: "\\b(?:undo|redo)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            return [historyTool, clarificationTool]
        }
        let hasOperation = request.range(of: "\\b(?:create|add|insert|move|retime|delete|remove)\\b",
                                         options: [.regularExpression, .caseInsensitive]) != nil
        let hasMark = request.range(of: "\\b(?:edit|edits|mark|marks|step|steps)\\b",
                                    options: [.regularExpression, .caseInsensitive]) != nil
        let hasFramingTarget = request.range(of: "\\b(?:box|boxes|zoom|crop|camera|pointer|pan)\\b",
                                             options: [.regularExpression, .caseInsensitive]) != nil
        guard hasOperation && hasMark && !hasFramingTarget else { return nil }
        return [managementTool, clarificationTool]
    }

    static func result(name: String, args: [String: Any], context: LocalEditContext,
                       instruction: String? = nil) throws -> LocalEditResult? {
        switch name {
        case "change_history":
            try keys(args, ["version", "project_id", "expected_revision", "action", "count"])
            try scope(args, context: context)
            guard let actionValue = args["action"] as? String,
                  let action = EditorHistoryAction(rawValue: actionValue) else { throw invalidResponse }
            let count = try integer(args["count"])
            guard count >= 1 else { throw invalidResponse }
            let history = context.recording.history
            let stack = action == .undo ? history.undo : history.redo
            let available = stack.count
            guard available > 0 else {
                throw EditorCommandError.invalid("There are no changes to \(action.rawValue).")
            }
            guard count <= available else {
                return .clarification("There are \(available) changes available to \(action.rawValue). How many should I \(action.rawValue)?")
            }
            if let instruction,
               instruction.range(of: "\\b\(action.rawValue)\\b.*\\b(?:your|director|agent|assistant)(?:[’']s)?\\b",
                                 options: [.regularExpression, .caseInsensitive]) != nil,
               stack.prefix(count).contains(where: { !isDirectorChange($0) }) {
                let ownedIndices = stack.indices.filter { isDirectorChange(stack[$0]) }
                guard ownedIndices.count >= count else {
                    return .clarification("There are only \(ownedIndices.count) Director changes in this \(action.rawValue) history, alongside manual changes. Which shared history changes should I \(action.rawValue)?")
                }
                let span = ownedIndices[count - 1] + 1
                let manual = stack.prefix(span).filter { !isDirectorChange($0) }
                let verb = action.rawValue.capitalized
                let directorChanges = count == 1 ? "the last Director change" : "the last \(count) Director changes"
                let manualChanges = manual.count == 1 ? "1 manual change" : "\(manual.count) manual changes"
                return .clarification("\(verb)ing \(directorChanges) would also \(action.rawValue) \(manualChanges), including “\(manual[0])”. \(verb) the last \(span) entries in order?")
            }
            return .history(EditorHistoryRequest(projectID: context.recording.projectID,
                revision: context.recording.revision, action: action, count: count))
        case "manage_edits":
            try keys(args, ["version", "project_id", "expected_revision", "changes"])
            try scope(args, context: context)
            guard let changes = args["changes"] as? [[String: Any]], (1...16).contains(changes.count) else { throw invalidResponse }
            let active = context.recording.state.timedEdits(includeCamera: true)
            var times: [UUID: Double] = [:]
            for edit in active {
                guard times[edit.id] == nil else {
                    throw EditorCommandError.invalid("The recording contains ambiguous edit identities. No edit-control changes were applied.")
                }
                times[edit.id] = edit.time
            }
            var commands: [EditorCommand] = []
            var summaries: [String] = []
            func resolve(_ label: String) -> TimedEdit? {
                let matches = active.filter { edit in
                    times[edit.id] != nil && context.recording.references.editLabel(for: edit.id)
                        .map { normalized($0) == normalized(label) } == true
                }
                return matches.count == 1 ? matches[0] : nil
            }
            for change in changes {
                guard let action = change["action"] as? String else { throw invalidResponse }
                if action == "delete" {
                    try keys(change, ["action", "edit_label"])
                    guard let label = change["edit_label"] as? String, label.count <= 40 else { throw invalidResponse }
                    guard let edit = resolve(label) else { return missing(label) }
                    commands.append(.removeEdit(editID: edit.id))
                    times.removeValue(forKey: edit.id)
                    summaries.append("Removed \(context.recording.references.editLabel(for: edit.id) ?? label).")
                    continue
                }
                guard action == "create" || action == "move" else { throw invalidResponse }
                try keys(change, action == "create" ? ["action", "at_edit_label", "offset_seconds"]
                    : ["action", "edit_label", "at_edit_label", "offset_seconds"])
                guard let baseLabel = change["at_edit_label"] as? String, baseLabel.count <= 40 else { throw invalidResponse }
                let offset = try number(change["offset_seconds"])
                let moving: TimedEdit?
                if action == "move" {
                    guard let label = change["edit_label"] as? String, label.count <= 40 else { throw invalidResponse }
                    guard let edit = resolve(label) else { return missing(label) }
                    moving = edit
                } else {
                    moving = nil
                }
                let base: Double
                switch normalized(baseLabel) {
                case "", "playhead": base = context.playhead
                case "start": base = 0
                default:
                    guard let edit = resolve(baseLabel), let time = times[edit.id] else { return missing(baseLabel) }
                    base = time
                }
                let time = base + offset
                guard time.isFinite, time >= 0, time < context.recording.duration else {
                    return .clarification("That position falls outside the recording. Where should the edit go?")
                }
                if let collision = times.first(where: { $0.key != moving?.id && abs($0.value - time) < 0.000_001 }) {
                    let existing = context.recording.references.editLabel(for: collision.key) ?? "An edit"
                    return .clarification("\(existing) already marks that position. Should I use that edit or choose another position?")
                }
                if let moving {
                    commands.append(.moveEdit(editID: moving.id, time: time))
                    times[moving.id] = time
                    summaries.append("Moved \(context.recording.references.editLabel(for: moving.id) ?? "the edit").")
                } else {
                    commands.append(.createEdit(time: time))
                    times[UUID()] = time
                    summaries.append("Added an edit mark.")
                }
            }
            return .commands(EditorCommandBatch(projectID: context.recording.projectID,
                revision: context.recording.revision, commands: commands), summary: summaries.joined(separator: "\n"))
        default: return nil
        }
    }

    private static func scope(_ args: [String: Any], context: LocalEditContext) throws {
        guard try integer(args["version"]) == 1 else { throw invalidResponse }
        guard let id = args["project_id"] as? String, UUID(uuidString: id) == context.recording.projectID,
              args["expected_revision"] as? String == context.recording.revision else { throw EditorCommandError.stale }
    }
    private static func keys(_ value: [String: Any], _ expected: Set<String>) throws {
        guard Set(value.keys) == expected else { throw invalidResponse }
    }
    private static func number(_ value: Any?) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw invalidResponse
        }
        return value.doubleValue
    }
    private static func integer(_ value: Any?) throws -> Int {
        let number = try number(value)
        guard number.rounded() == number, number >= Double(Int.min), number < Double(Int.max) else { throw invalidResponse }
        return Int(number)
    }
    private static func normalized(_ label: String) -> String { label.lowercased().filter { !$0.isWhitespace } }
    private static func isDirectorChange(_ name: String) -> Bool {
        name.hasPrefix("Director:") || name == "Edit with assistant"
    }
    private static func missing(_ label: String) -> LocalEditResult {
        .clarification("I can’t find \(label). Which visible edit do you mean?")
    }
    private static var invalidResponse: EditorCommandError {
        .invalid("The local model returned an invalid edit-control request. No changes were applied.")
    }
    private static func function(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
            "parameters": ["type": "object", "properties": properties,
                "required": properties.keys.sorted(), "additionalProperties": false]]]
    }
    private static var scopeProperties: [String: Any] {
        ["version": ["type": "integer", "const": 1], "project_id": ["type": "string"], "expected_revision": ["type": "string"]]
    }
    private static var clarificationTool: [String: Any] {
        function("ask_clarification", "Ask one concise question when a target, time, or requested history change is unclear.", ["question": ["type": "string"]])
    }
    private static var historyTool: [String: Any] {
        function("change_history", "Undo or redo the normal shared edit stack, latest first. Default count is 1. Never skip newer manual changes to undo only an agent change. If the requested older change is below intervening changes, explain the latest entries and ask before undoing the whole span.", scopeProperties.merging([
            "action": ["type": "string", "enum": ["undo", "redo"]],
            "count": ["type": "integer", "minimum": 1]
        ]) { _, b in b })
    }
    private static var managementTool: [String: Any] {
        function("manage_edits", "Create, move, or remove named timeline edit marks. Changes run in order. Each action includes only its own fields: create has a base and offset; move also has an existing edit_label; delete has only action and edit_label, with no timing fields. Resolve relative positions using an existing Edit label plus offset_seconds; use at_edit_label=playhead for current time or start for recording time zero. Ask if the desired position is unclear. A new mark receives its visible letter automatically after creation; it cannot be referenced by a guessed new letter within this request. Moving or removing an edit includes its current framing/camera changes; boxes retain their original source frame.", scopeProperties.merging([
            "changes": ["type": "array", "minItems": 1, "maxItems": 16, "items": ["oneOf": [
                actionSchema("create", properties: [
                    "at_edit_label": ["type": "string", "description": "Base Edit label, playhead, or start."],
                    "offset_seconds": ["type": "number", "description": "Signed offset from the base."]]),
                actionSchema("move", properties: [
                    "edit_label": ["type": "string", "description": "Existing edit to move."],
                    "at_edit_label": ["type": "string", "description": "Base Edit label, playhead, or start."],
                    "offset_seconds": ["type": "number", "description": "Signed offset from the base."]]),
                actionSchema("delete", properties: ["edit_label": ["type": "string", "description": "Existing edit to remove."]])
            ]]]
        ]) { _, b in b })
    }
    private static func actionSchema(_ action: String, properties: [String: Any]) -> [String: Any] {
        let properties = properties.merging(["action": ["type": "string", "const": action]]) { _, b in b }
        return ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
    }
}
