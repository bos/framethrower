import Foundation

/// Saved descriptions describe the actual result at the time of the action.
/// Later Undo or manual changes do not rewrite what the conversation said.
struct DirectorTranscriptStep: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var time: Double
    var label: String
    var detail: String
    var tooltip: String

    static func changes(from before: EditState, to after: EditState, references: EditorReferences) -> [Self] {
        let old = before.timedEdits(includeCamera: true)
        let new = after.timedEdits(includeCamera: true)
        var result: [Self] = []
        for edit in new {
            let previous = references.edit(in: before, id: edit.id)
            let changed = previous == nil || previous?.time != edit.time ||
                before.zoomKeyframes.first(where: { $0.id == previous?.zoomID }) != after.zoomKeyframes.first(where: { $0.id == edit.zoomID }) ||
                before.pipKeyframes.first(where: { $0.id == previous?.cameraID }) != after.pipKeyframes.first(where: { $0.id == edit.cameraID })
            if changed {
                let description = EditorActionDescription.describe(edit, in: after, references: references)
                result.append(Self(id: edit.id, time: edit.time, label: description.shortLabel,
                    detail: description.detail, tooltip: description.tooltip))
            }
        }
        for edit in old where references.edit(in: after, id: edit.id) == nil {
            let description = EditorActionDescription.describe(edit, in: before, references: references)
            result.append(Self(id: edit.id, time: edit.time, label: "Removed " + description.shortLabel,
                detail: "Removed this change.", tooltip: "Removed " + description.tooltip))
        }
        return result.sorted { $0.time < $1.time }
    }
}

struct DirectorTranscriptEntry: Identifiable, Equatable {
    enum Kind { case user, assistant, event }
    var id: String
    var kind: Kind
    var text: String
    var steps: [DirectorTranscriptStep] = []
    var isQuestion = false
    var isError = false
    var adjustmentTarget: String? = nil
    var adjustmentEventID: String? = nil
    var earlierAdjustments: [DirectorTranscriptEntry] = []
    var inspectedFrameID: UUID? = nil
}

@MainActor
enum DirectorTranscript {
    static func entries(in conversation: DirectorConversation, references: EditorReferences) -> [DirectorTranscriptEntry] {
        var result: [DirectorTranscriptEntry] = []
        var segments: [UUID: Int] = [:]
        for exchange in conversation.exchanges {
            let segment = segments[exchange.id, default: 0]
            segments[exchange.id] = segment + 1
            for (index, message) in exchange.messages.enumerated() {
                let id = "\(exchange.id):\(segment):\(index)"
                let text = message.content ?? ""
                if message.role == "user", index == 0, exchange.origin == "request" {
                    result.append(.init(id: id, kind: .user, text: text))
                    continue
                }
                if message.role == "user", let event = object(text)?["app_event"] as? [String: Any] {
                    if let status = event["status"] as? String {
                        if let entry = outcome(event, status: status, id: id, conversation: conversation, references: references) { result.append(entry) }
                    } else if let body = eventText(event) {
                        let edits = steps(event)
                        result.append(.init(id: id, kind: .event, text: body, steps: edits,
                            adjustmentTarget: adjustmentTarget(event, steps: edits), adjustmentEventID: id))
                    }
                } else if message.role == "tool", let value = object(text), let status = value["status"] as? String {
                    if let entry = outcome(value, status: status, id: id, conversation: conversation, references: references) { result.append(entry) }
                } else if message.role == "user", !text.isEmpty {
                    result.append(.init(id: id, kind: .user, text: text))
                } else if message.role == "assistant", message.toolCalls == nil, !text.isEmpty {
                    result.append(.init(id: id, kind: .assistant, text: text))
                }
            }
        }
        var grouped: [DirectorTranscriptEntry] = []
        for var entry in result {
            if let target = entry.adjustmentTarget, let previous = grouped.last, previous.adjustmentTarget == target {
                entry.id = previous.id
                var earlier = previous
                earlier.id = previous.adjustmentEventID ?? previous.id
                earlier.earlierAdjustments = []
                entry.earlierAdjustments = previous.earlierAdjustments + [earlier]
                grouped[grouped.count - 1] = entry
            } else { grouped.append(entry) }
        }
        return grouped
    }

    /// Group only adjacent manual adjustments to the same identities or
    /// whole-clip component. Captions and rounded descriptions are not identity.
    /// The saved conversation, model context and Undo stack remain untouched.
    private static func adjustmentTarget(_ event: [String: Any], steps: [DirectorTranscriptStep]) -> String? {
        guard event["kind"] as? String == "edit", !["director", "automation"].contains(event["actor"] as? String ?? "") else { return nil }
        if !steps.isEmpty { return "edits:" + Set(steps.map { $0.id.uuidString }).sorted().joined(separator: ",") }
        guard let changes = event["changes"] as? [String: Any], !changes.isEmpty else { return nil }
        let components = Set(changes.keys.map { ["trimStart", "trimEnd"].contains($0) ? "trim" : $0 })
        return "components:" + components.sorted().joined(separator: ",")
    }

    private static func outcome(_ value: [String: Any], status: String, id: String,
                                conversation: DirectorConversation, references: EditorReferences) -> DirectorTranscriptEntry? {
        let question = value["question"] as? String
        let error = value["error"] as? String
        let summary = value["summary"] as? String
        let text: String
        let kind: DirectorTranscriptEntry.Kind
        if value["retryable"] as? Bool == true {
            text = "Plan correction: " + (error?.components(separatedBy: ". ").first ?? "The first plan needed revision.")
            kind = .event
        } else {
            guard let body = question ?? summary ?? error, !body.isEmpty else { return nil }
            // Older builds appended a bare list of letters. The step list
            // below replaces it with useful action descriptions.
            text = body.components(separatedBy: "\nCreated ").first ?? body
            kind = status == "inspected" ? .event : .assistant
        }
        var edits = steps(value)
        if edits.isEmpty { edits = legacySteps(value, conversation: conversation, references: references) }
        let inspection = value["inspection"] as? [String: Any]
        let frameID = inspection?["kind"] as? String == "frame"
            ? (inspection?["frame_id"] as? String).flatMap(UUID.init(uuidString:)) : nil
        return DirectorTranscriptEntry(id: id, kind: kind, text: text, steps: edits,
            isQuestion: status == "needs_answer" || status == "conflict",
            isError: status == "rejected" && value["retryable"] as? Bool != true,
            inspectedFrameID: frameID)
    }

    private static func steps(_ value: [String: Any]) -> [DirectorTranscriptStep] {
        guard let value = value["edit_steps"], let data = try? JSONSerialization.data(withJSONObject: value),
              let steps = try? JSONDecoder().decode([DirectorTranscriptStep].self, from: data) else { return [] }
        return steps
    }

    private static func legacySteps(_ value: [String: Any], conversation: DirectorConversation,
                                    references: EditorReferences) -> [DirectorTranscriptStep] {
        guard let created = value["created_edits"] as? [[String: Any]] else { return [] }
        let snapshot = conversation.lastProject
        return created.compactMap { item in
            guard let rawID = item["id"] as? String, let id = UUID(uuidString: rawID), let time = item["time"] as? Double else { return nil }
            if let snapshot, value["revision"] as? String == snapshot.revision,
               let edit = references.edit(in: snapshot.state, id: id) {
                let description = EditorActionDescription.describe(edit, in: snapshot.state, references: references)
                return DirectorTranscriptStep(id: id, time: time, label: description.shortLabel, detail: description.detail, tooltip: description.tooltip)
            }
            let name = item["label"] as? String ?? "Edit"
            return DirectorTranscriptStep(id: id, time: time, label: name, detail: "Framing change.",
                tooltip: String(format: "%@ at %.2f s.", name, time))
        }
    }

    private static func eventText(_ value: [String: Any]) -> String? {
        let names = (value["names"] as? [String] ?? []).joined(separator: ", ")
        switch value["kind"] as? String {
        case "edit":
            if ["director", "automation"].contains(value["actor"] as? String ?? "") {
                return names.isEmpty ? "Applied an edit." : "Applied: " + names
            }
            return names.isEmpty ? "Recording changed manually." : "Manual change: " + names
        case "undo": return names.isEmpty ? "Undid a change." : "Undid " + names
        case "redo": return names.isEmpty ? "Redid a change." : "Redid " + names
        case "question_dismissed": return "Question dismissed."
        case "recording_changed_outside_session": return "Recording changed outside this conversation."
        case "state_changed": return "Recording settings changed."
        default: return nil
        }
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
