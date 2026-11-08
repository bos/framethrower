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

/// Read-only, next-action-first pagination of the normal shared history.
struct EditorHistoryLookupRequest: Codable, Equatable, Sendable {
    var projectID: UUID
    var revision: String
    var stack: EditorHistoryAction
    var offset: Int
    var limit: Int
}

enum EditorHistoryInspector {
    @MainActor
    static func page(_ request: EditorHistoryLookupRequest, to editor: ProjectEditor,
                     projectID: UUID) throws -> [String: Any] {
        guard editor.draftState == nil else { throw EditorCommandError.pendingDraft }
        let project = editor.project
        guard request.projectID == projectID,
              request.revision == (try EditorCommandDispatcher.revision(for: project)) else {
            throw EditorCommandError.stale
        }
        guard request.offset >= 0, (1...8).contains(request.limit) else {
            throw EditorCommandError.invalid("History pages need a nonnegative offset and a limit of 1–8.")
        }
        let snapshots = request.stack == .undo ? project.undoHistory : project.redoHistory
        let total = snapshots.count
        let end = request.offset >= total ? total : request.offset + min(request.limit, total - request.offset)
        var entries: [[String: Any]] = []
        if request.offset < total {
            for index in request.offset..<end {
                let position = total - 1 - index
                let target = snapshots[position]
                let origin = position + 1 < total ? snapshots[position + 1]
                    : NamedEditSnapshot(name: target.name, state: project.state, title: project.title)
                // Undo snapshots contain the state BEFORE their named action;
                // redo snapshots contain the state AFTER it. Report both in
                // original edit direction, independently of traversal direction.
                let before = request.stack == .undo ? target : origin
                let after = request.stack == .undo ? origin : target
                let components = changedComponents(before, after)
                entries.append(["index": index, "name": String(target.name.prefix(140)),
                    "changed_components": components,
                    "before": summary(before, comparedWith: after, components: components, references: project.references),
                    "after": summary(after, comparedWith: before, components: components, references: project.references)])
            }
        }
        return ["project_id": projectID.uuidString, "revision": request.revision,
            "stack": request.stack.rawValue, "total": total, "offset": request.offset,
            "limit": request.limit, "has_more": end < total, "entries": entries]
    }

    private static func changedComponents(_ before: NamedEditSnapshot, _ after: NamedEditSnapshot) -> [String] {
        let a = before.state, b = after.state
        return [("title", before.title != after.title),
            ("screen_framing", a.zoomKeyframes != b.zoomKeyframes),
            ("camera", a.pipKeyframes != b.pipKeyframes),
            ("pointer", a.cursorStyle != b.cursorStyle), ("audio", a.audio != b.audio),
            ("trim", a.trimStart != b.trimStart || a.trimEnd != b.trimEnd),
            ("canvas", a.presentation != b.presentation), ("boxes", a.regions != b.regions),
            ("reference_marks", a.editAnchors != b.editAnchors)].compactMap { $0.1 ? $0.0 : nil }
    }

    /// Bounded human-readable projection, never raw snapshots or media paths.
    /// Two short descriptions per entry keep eight-entry tool results compact.
    private static func summary(_ snapshot: NamedEditSnapshot, comparedWith other: NamedEditSnapshot, components: [String],
                                references: EditorReferences) -> [String: Any] {
        let state = snapshot.state
        var details: [String] = []
        for component in components {
            switch component {
            case "screen_framing":
                let changed = state.zoomKeyframes.filter { point in
                    !other.state.zoomKeyframes.contains(point)
                }
                let samples = changed.prefix(2).map { point in
                    let edit = state.timedEdits(includeCamera: true).first { $0.zoomID == point.id }
                    let label = edit.map { EditorActionDescription.describe($0, in: state, references: references).shortLabel } ?? "Screen"
                    let prior = other.state.zoomKeyframes.first { $0.id == point.id }
                    return "\(label) \(seconds(point.time))s: \(changedPointFields(point, comparedWith: prior))"
                }.joined(separator: ", ")
                details.append("Screen: \(state.zoomKeyframes.count) points, \(changed.count) differing (\(samples)).")
            case "camera":
                let changed = state.pipKeyframes.filter { !other.state.pipKeyframes.contains($0) }
                let samples = changed.prefix(2).map { point in
                    let prior = other.state.pipKeyframes.first { $0.id == point.id }
                    return "\(seconds(point.time))s: \(changedPointFields(point, comparedWith: prior))"
                }.joined(separator: "; ")
                details.append("Camera: \(state.pipKeyframes.count) points, \(changed.count) differing (\(samples)).")
            case "pointer":
                details.append("Pointer: \(state.cursorStyle.visible ? "visible" : "hidden"), size \(seconds(state.cursorStyle.size)), smoothing \(seconds(state.cursorStyle.smoothing)), clicks \(state.cursorStyle.clickHighlight ? "on" : "off").")
            case "audio":
                details.append("Audio: \(state.audio.isMuted ? "muted" : "unmuted"), volume \(seconds(state.audio.volume)), fades \(seconds(state.audio.fadeIn))/\(seconds(state.audio.fadeOut))s.")
            case "trim": details.append("Trim: \(seconds(state.trimStart))–\(seconds(state.trimEnd))s.")
            case "canvas":
                let canvas = state.presentation
                details.append("Canvas: \(canvas.aspect.rawValue), padding \(seconds(canvas.padding)), corners \(seconds(canvas.cornerRadius)), RGB \(seconds(canvas.background.red))/\(seconds(canvas.background.green))/\(seconds(canvas.background.blue)).")
            case "boxes":
                let changed = state.regions.filter { !other.state.regions.contains($0) }
                let boxes = changed.prefix(2).map {
                    "\(references.boxLabel(for: $0.id) ?? "Box") \(seconds($0.time))s rect \(seconds($0.rect.x))/\(seconds($0.rect.y))/\(seconds($0.rect.width))/\(seconds($0.rect.height)) note=\(String($0.note.prefix(24)))"
                }.joined(separator: "; ")
                details.append("Boxes: \(state.regions.count), \(changed.count) differing (\(boxes)).")
            case "reference_marks":
                let changed = state.editAnchors.filter { !other.state.editAnchors.contains($0) }
                let times = changed.prefix(2).map { seconds($0.time) }.joined(separator: ", ")
                details.append("Reference marks: \(state.editAnchors.count), \(changed.count) differing (\(times)s).")
            default: break
            }
        }
        let text = details.joined(separator: " ")
        return ["title": snapshot.title.map { String($0.prefix(140)) } as Any? ?? NSNull(),
            "description": String(text.prefix(160)), "description_truncated": text.count > 160]
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.2f", value) }

    /// Only these framing-point values reach this helper, never a project or
    /// snapshot. Flattening retains exact changed crop, aspect and ramp fields
    /// without spending the bounded description on identical placement values.
    private static func changedPointFields<T: Encodable>(_ point: T, comparedWith previous: T?) -> String {
        func fields(_ value: T) -> [String: String] {
            guard let data = try? JSONEncoder().encode(value),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            var result: [String: String] = [:]
            func flatten(_ object: [String: Any], prefix: String = "") {
                for (key, value) in object where key != "id" {
                    let path = prefix + key
                    if let nested = value as? [String: Any] { flatten(nested, prefix: path + ".") }
                    else if let number = value as? NSNumber { result[path] = number.stringValue }
                    else if let text = value as? String { result[path] = text }
                }
            }
            flatten(object)
            return result
        }
        let current = fields(point), prior = previous.map(fields) ?? [:]
        return Set(current.keys).union(prior.keys).sorted().filter { current[$0] != prior[$0] }.map {
            "\($0)=\(current[$0] ?? "default")"
        }.joined(separator: ", ")
    }

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
    /// A history command starts with the requested action. Mentioning history
    /// inside a framing instruction must not hide all framing tools. Follow-up
    /// clarification payloads retain the original command on their first line.
    static func historyAction(in request: String) -> EditorHistoryAction? {
        let prefix = "Earlier instruction: "
        let command = request.hasPrefix(prefix) ? String(request.dropFirst(prefix.count)) : request
        let pattern = "^\\s*(?:(?:please|can you|could you|would you|will you|i want you to|i would like you to|i'd like you to)\\s+)*(undo|redo)\\b"
        guard let range = command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let start = command[range].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return start.hasSuffix("undo") ? .undo : .redo
    }

    static func tools(for request: String) -> [[String: Any]]? {
        if literalBoxIntent(in: request) != nil { return [boxManagementTool, clarificationTool] }
        if request.range(of: "\\b(?:delete|remove|note|label|rename)\\b", options: [.regularExpression, .caseInsensitive]) != nil,
           request.range(of: "\\bbox(?:es)?\\b", options: [.regularExpression, .caseInsensitive]) != nil,
           request.range(of: "\\b(?:zoom|pan|frame|camera|pointer)\\b", options: [.regularExpression, .caseInsensitive]) == nil {
            return [boxManagementTool, clarificationTool]
        }
        if historyAction(in: request) != nil {
            return [historyTool, historyLookupTool, clarificationTool]
        }
        let hasOperation = request.range(of: "\\b(?:create|add|insert|move|retime|delete|remove)\\b",
                                         options: [.regularExpression, .caseInsensitive]) != nil
        let actionLabel = "\\b(?i:zoom|pan|full[ -]?frame|hold|ref(?:erence)?|camera)\\s+(?!(?:to|from|out|in|at|for|over|and|the|into|is|left|right|up|down)\\b)[A-Za-z]{1,6}\\b(?!\\s+(?i:bit|little|lot|touch|tiny|small|slight)\\b)"
        let hasLabel = request.range(of: actionLabel, options: .regularExpression) != nil
        let bareLabel = request.range(of: "\\b(?i:move|retime|delete|remove)\\s+(?:[A-Za-z]|[A-Z]{2,6})\\b",
                                      options: .regularExpression) != nil
        let hasMark = hasLabel || bareLabel || request.range(of: "\\b(?:edit|edits|mark|marks|step|steps)\\b",
                                    options: [.regularExpression, .caseInsensitive]) != nil
        let action = request.replacingOccurrences(of: actionLabel, with: "", options: .regularExpression)
        let hasFramingTarget = action.range(of: "\\b(?:box|boxes|zoom|crop|camera|pointer|pan)\\b",
                                             options: [.regularExpression, .caseInsensitive]) != nil
        guard hasOperation && hasMark && !hasFramingTarget else { return nil }
        return [managementTool, historyLookupTool, clarificationTool]
    }

    static func result(name: String, args: [String: Any], context: LocalEditContext,
                       instruction: String? = nil, historyInspected: Bool = false) throws -> LocalEditResult? {
        switch name {
        case "manage_boxes":
            try keys(args, ["version", "project_id", "expected_revision", "changes"])
            try scope(args, context: context)
            if let instruction, let rejection = boxIntentMismatch(instruction, toolName: name, args: args, context: context) {
                return .rejectedPlan(rejection)
            }
            guard let changes = args["changes"] as? [[String: Any]], (1...16).contains(changes.count) else { throw invalidResponse }
            var commands: [EditorCommand] = []
            var summaries: [String] = []
            for change in changes {
                guard let action = change["action"] as? String, ["delete", "note"].contains(action),
                      let label = change["box_label"] as? String, label.count <= 40 else { throw invalidResponse }
                try keys(change, action == "delete" ? ["action", "box_label"] : ["action", "box_label", "note"])
                guard let box = resolveBox(label, context: context) else {
                    return .clarification("I can’t find \(label). Which numbered box do you mean?")
                }
                let canonicalLabel = context.recording.references.boxLabel(for: box.id) ?? label
                if action == "delete" {
                    commands.append(.removeRegion(regionID: box.id))
                    let linked = context.recording.state.zoomKeyframes.filter { $0.sourceRegionID == box.id }.count
                    summaries.append(linked == 0 ? "Removed \(canonicalLabel)."
                        : "Removed \(canonicalLabel) and \(linked) linked screen \(linked == 1 ? "target" : "targets").")
                } else {
                    guard let note = change["note"] as? String else { throw invalidResponse }
                    commands.append(.labelRegion(regionID: box.id, note: note))
                    summaries.append(note.isEmpty ? "Cleared \(canonicalLabel) note." : "Updated \(canonicalLabel) note.")
                }
            }
            return .commands(EditorCommandBatch(projectID: context.recording.projectID,
                revision: context.recording.revision, commands: commands), summary: summaries.joined(separator: "\n"))
        case "report_history":
            try keys(args, ["version", "project_id", "expected_revision", "summary"])
            try scope(args, context: context)
            guard historyInspected, let summary = args["summary"] as? String,
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  summary.count <= 600 else { throw invalidResponse }
            return .noChanges(summary)
        case "inspect_history":
            try keys(args, ["version", "project_id", "expected_revision", "stack", "offset", "limit"])
            try scope(args, context: context)
            guard let value = args["stack"] as? String,
                  let stack = EditorHistoryAction(rawValue: value) else { throw invalidResponse }
            let offset = try integer(args["offset"]), limit = try integer(args["limit"])
            guard offset >= 0, (1...8).contains(limit) else { throw invalidResponse }
            return .historyLookup(EditorHistoryLookupRequest(projectID: context.recording.projectID,
                revision: context.recording.revision, stack: stack, offset: offset, limit: limit))
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
            if let instruction, let rejection = managementIntentMismatch(instruction, changes: changes, context: context) {
                return .rejectedPlan(rejection)
            }
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
                guard let edit = EditorActionDescription.resolve(label, in: context.recording.state,
                    references: context.recording.references), times[edit.id] != nil else { return nil }
                return edit
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
                    let existing = active.first(where: { $0.id == collision.key }).map {
                        EditorActionDescription.describe($0, in: context.recording.state, references: context.recording.references).shortLabel
                    } ?? "An edit"
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
                revision: context.recording.revision, commands: commands),
                summary: LocalEditPlanner.descriptiveSummary(summaries.joined(separator: "\n"), commands: commands, context: context))
        default: return nil
        }
    }

    private struct ManagementIntent {
        let action: String
        let targetLabel: String?
    }

    /// Only literal single-operation requests are narrowed. Compound requests
    /// and contextual answers keep the full management schema and validation.
    private static func literalManagementIntent(in instruction: String) -> ManagementIntent? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
            .replacingOccurrences(of: "^(?:(?:please|can you|could you|would you|will you)\\s+)+", with: "",
                                  options: [.regularExpression, .caseInsensitive])
        guard text.range(of: "[;\\n]|\\b(?:and|then|but|or|also|not|don't|except|unless|if|edits|marks|steps)\\b",
                         options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        let label = "((?:(?:edit|ref(?:erence)?|zoom|pan|full[ -]?frame|hold|camera)\\s+[A-Za-z]{1,6}|(?-i:[A-Z]{1,6})))"
        func target(_ pattern: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        let expectedAction: String
        let targetLabel: String?
        if let label = target("^(?:delete|remove)\\s+(?:the\\s+)?" + label + "$") {
            expectedAction = "delete"; targetLabel = label
        } else if let label = target("^(?:move|retime)\\s+(?:the\\s+)?" + label + "\\s+.+$") {
            expectedAction = "move"; targetLabel = label
        } else if text.range(of: "^(?:create|add|insert)\\s+(?:(?:a|an|one)\\s+)?(?:new\\s+)?(?:edit(?:\\s+mark)?|reference\\s+mark|mark|step)(?:\\s+.+)?$",
                             options: [.regularExpression, .caseInsensitive]) != nil {
            expectedAction = "create"; targetLabel = nil
        } else { return nil }
        return ManagementIntent(action: expectedAction, targetLabel: targetLabel)
    }

    /// Focus the current request, not the earlier routing instruction. A reply
    /// such as "B instead" must remain free to change the prior target.
    static func focusedManagementTool(_ tool: [String: Any], instruction: String,
                                      context: LocalEditContext) -> [String: Any] {
        if let intent = literalBoxIntent(in: instruction) {
            return focusedBoxManagementTool(tool, intent: intent, context: context)
        }
        guard let intent = literalManagementIntent(in: instruction),
              var function = tool["function"] as? [String: Any], function["name"] as? String == "manage_edits",
              var parameters = function["parameters"] as? [String: Any],
              var properties = parameters["properties"] as? [String: Any],
              var changes = properties["changes"] as? [String: Any],
              var items = changes["items"] as? [String: Any],
              let alternatives = items["oneOf"] as? [[String: Any]] else { return tool }
        var focused = alternatives.filter {
            let fields = $0["properties"] as? [String: Any]
            return (fields?["action"] as? [String: Any])?["const"] as? String == intent.action
        }
        guard focused.count == 1 else { return tool }
        if let label = intent.targetLabel,
           let edit = EditorActionDescription.resolve(label, in: context.recording.state, references: context.recording.references),
           var fields = focused[0]["properties"] as? [String: Any],
           var target = fields["edit_label"] as? [String: Any] {
            let canonical = EditorActionDescription.unambiguousLabel(for: edit, in: context.recording.state,
                references: context.recording.references)
            target["enum"] = [canonical]
            fields["edit_label"] = target
            focused[0]["properties"] = fields
        }
        items["oneOf"] = focused
        changes["items"] = items
        changes["maxItems"] = 1
        properties["changes"] = changes
        parameters["properties"] = properties
        function["parameters"] = parameters
        var result = tool
        result["function"] = function
        return result
    }

    private struct BoxManagementIntent {
        let action: String
        let label: String
    }

    /// Narrow only a literal single operation. The model still proposes the
    /// command; contextual replies and compounds retain their complete schema.
    private static func literalBoxIntent(in instruction: String) -> BoxManagementIntent? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
            .replacingOccurrences(of: "^(?:(?:please|can you|could you|would you|will you)\\s+)+", with: "",
                                  options: [.regularExpression, .caseInsensitive])
        func target(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), let number = Int(text[range]), number > 0 else { return nil }
            return "Box \(number)"
        }
        if let label = target("^(?:delete|remove)\\s+(?:the\\s+)?box\\s*([0-9]{1,7})$") {
            return BoxManagementIntent(action: "delete", label: label)
        }
        // Notes can contain ordinary conjunctions. Only an additional command
        // or another numbered target makes this a compound management request.
        guard text.range(of: "[;\\n]|\\b(?:and|then|also|but|or)\\s+(?:(?:please|then)\\s+)?(?:delete|remove|set|update|edit|change|add|attach|note|label|rename|frame|zoom|pan|move|create|box\\s*[0-9]+)\\b",
                         options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        let notePatterns = [
            "^(?:set|update|edit|change|add|attach|clear|remove|delete)\\s+(?:(?:a|an|the)\\s+)?note\\s+(?:for|to|on|of)\\s+(?:the\\s+)?box\\s*([0-9]{1,7})(?:\\s*[:=].*|\\s+.*)?$",
            "^(?:set|update|edit|change|clear|remove|delete)\\s+(?:the\\s+)?box\\s*([0-9]{1,7})(?:[’']s)?\\s+note(?:\\s*[:=].*|\\s+.*)?$",
            "^(?:note|label|name|rename)\\s+(?:the\\s+)?box\\s*([0-9]{1,7})(?:\\s*[:=].+|\\s+.+)$"
        ]
        for pattern in notePatterns {
            if let label = target(pattern) { return BoxManagementIntent(action: "note", label: label) }
        }
        return nil
    }

    private static func resolveBox(_ label: String, context: LocalEditContext) -> EditorRegion? {
        let matches = context.recording.state.regions.filter {
            context.recording.references.boxLabel(for: $0.id).map { normalized($0) == normalized(label) } ?? false
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func boxIntentMismatch(_ instruction: String, toolName: String, args: [String: Any],
                                  context: LocalEditContext) -> String? {
        guard let intent = literalBoxIntent(in: instruction) else { return nil }
        let label = intent.label
        guard let expected = resolveBox(label, context: context) else {
            return "The instruction names \(label), which is not an existing box. Ask which visible box is intended; do not substitute another target."
        }
        guard toolName == "manage_boxes", let changes = args["changes"] as? [[String: Any]],
              changes.count == 1, changes[0]["action"] as? String == intent.action else {
            return "The instruction requests one \(intent.action) operation for \(label). Use manage_boxes with exactly that operation; do not substitute a deletion, note edit, or framing action. No changes were applied."
        }
        guard let actual = changes[0]["box_label"] as? String,
              resolveBox(actual, context: context)?.id == expected.id else {
            return "The instruction targets \(label). Apply the requested operation to that same stable box identity, not the selected box or another numbered box."
        }
        return nil
    }

    private static func focusedBoxManagementTool(_ tool: [String: Any], intent: BoxManagementIntent,
                                               context: LocalEditContext) -> [String: Any] {
        guard var function = tool["function"] as? [String: Any], function["name"] as? String == "manage_boxes",
              var parameters = function["parameters"] as? [String: Any], var properties = parameters["properties"] as? [String: Any],
              var changes = properties["changes"] as? [String: Any], var items = changes["items"] as? [String: Any],
              let options = items["oneOf"] as? [[String: Any]],
              var operation = options.first(where: { (($0["properties"] as? [String: Any])?["action"] as? [String: Any])?["const"] as? String == intent.action }),
              var fields = operation["properties"] as? [String: Any], var target = fields["box_label"] as? [String: Any] else { return tool }
        if let box = resolveBox(intent.label, context: context) { target["enum"] = [context.recording.references.boxLabel(for: box.id) ?? intent.label] }
        fields["box_label"] = target
        operation["properties"] = fields
        items["oneOf"] = [operation]
        changes["items"] = items
        changes["maxItems"] = 1
        properties["changes"] = changes
        parameters["properties"] = properties
        function["parameters"] = parameters
        var result = tool; result["function"] = function
        return result
    }

    /// Labels are checked by identity as a second defense against responses
    /// that do not follow the focused schema; aliases still identify one edit.
    private static func managementIntentMismatch(_ instruction: String, changes: [[String: Any]],
                                                 context: LocalEditContext) -> String? {
        guard let intent = literalManagementIntent(in: instruction) else { return nil }
        let expectedAction = intent.action, targetLabel = intent.targetLabel
        let expectedTarget: TimedEdit?
        if let targetLabel {
            guard let edit = EditorActionDescription.resolve(targetLabel, in: context.recording.state,
                references: context.recording.references) else {
                return "The instruction names \(targetLabel), which is not an existing edit. Ask which visible edit is intended; do not substitute another target."
            }
            expectedTarget = edit
        } else { expectedTarget = nil }
        guard changes.count == 1, changes[0]["action"] as? String == expectedAction else {
            return "The instruction requests one \(expectedAction) operation. Return only that operation; do not substitute another edit-management action."
        }
        if let expectedTarget, let actualLabel = changes[0]["edit_label"] as? String {
            let actual = EditorActionDescription.resolve(actualLabel, in: context.recording.state,
                references: context.recording.references)
            guard actual?.id == expectedTarget.id else {
                let expectedLabel = context.recording.references.editLabel(for: expectedTarget.id) ?? targetLabel ?? "the named edit"
                return "The instruction targets \(expectedLabel). Return the requested operation for that same edit identity, not another edit."
            }
        }
        return nil
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
    static var historyLookupTool: [String: Any] {
        function("inspect_history", "Read a page of the shared Undo or Redo history without changing anything. Offset 0 is the next action; limit is 1–8. Inspect older entries on demand before discussing them. Results describe original edits before/after, not selective undo. Never invent omitted entries or skip intervening changes.", scopeProperties.merging([
            "stack": ["type": "string", "enum": ["undo", "redo"]],
            "offset": ["type": "integer", "minimum": 0],
            "limit": ["type": "integer", "minimum": 1, "maximum": 8]
        ]) { _, b in b })
    }
    static var historyReportTool: [String: Any] {
        function("report_history", "Answer the user's history question using the inspected entries, without changing anything. Do not claim selective Undo, describe unavailable older entries, or imply an abandoned Redo branch is retained.", scopeProperties.merging([
            "summary": ["type": "string", "minLength": 1, "maxLength": 600]
        ]) { _, b in b })
    }
    static var boxManagementTool: [String: Any] {
        function("manage_boxes", "Delete numbered reference boxes or update their optional notes. Use stable Box labels from context, never array order or the selected box when another is named. Deleting a box also removes screen-framing targets explicitly linked to it and joins the neighboring route; independent camera changes, other edit marks and other boxes remain. A note describes a box; it never renames its stable Box number or deletes it. Changes execute atomically in order.", scopeProperties.merging([
            "changes": ["type": "array", "minItems": 1, "maxItems": 16, "items": ["oneOf": [
                actionSchema("delete", properties: ["box_label": ["type": "string"]]),
                actionSchema("note", properties: ["box_label": ["type": "string"], "note": ["type": "string", "maxLength": 4096]])
            ]]]
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
