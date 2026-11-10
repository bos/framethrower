import CryptoKit
import Combine
import Foundation

struct DirectorPendingQuestion: Codable {
    var request: String
    var question: String
    var context: LocalEditContext
    var revision: String { context.recording.revision }
}

struct DirectorPendingConflict: Codable {
    var proposal: EditorFramingConflict
    var context: LocalEditContext
    var followup: String?
}

/// Persistence needs the last visible state, not every full Undo snapshot.
struct DirectorProjectSnapshot: Codable, Equatable {
    var state: EditState
    var title: String?
    var undoNames: [String]
    var redoNames: [String]
    var revision: String

    init(_ project: RecordingProject) {
        state = project.state; title = project.title
        undoNames = project.undoHistory.suffix(32).map(\.name)
        redoNames = project.redoHistory.suffix(32).map(\.name)
        revision = (try? EditorCommandDispatcher.revision(for: project)) ?? ""
    }

    enum CodingKeys: String, CodingKey { case state, title, undoNames, redoNames, revision }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.revision) {
            state = try values.decode(EditState.self, forKey: .state)
            title = try values.decodeIfPresent(String.self, forKey: .title)
            undoNames = try values.decode([String].self, forKey: .undoNames)
            redoNames = try values.decode([String].self, forKey: .redoNames)
            revision = try values.decode(String.self, forKey: .revision)
        } else {
            self = DirectorProjectSnapshot(try RecordingProject(from: decoder))
        }
    }
}

/// Complete exchanges stay together: an assistant tool call is never detached
/// from its actual result when the model's recent-conversation window is built.
@MainActor
final class DirectorConversation: ObservableObject {
    struct Function: Codable { var name: String; var arguments: String }
    struct Call: Codable { var id: String; var type = "function"; var function: Function }
    struct Message: Codable {
        var role: String
        var content: String?
        var toolCalls: [Call]?
        var toolCallID: String?
        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }
    }
    struct Exchange: Codable {
        var id: UUID
        var messages: [Message]
        var summary: String
        var origin: String? = nil
    }
    private struct Archive: Codable {
        var version = 1
        var recordingID: UUID? = nil
        var exchanges: [Exchange]
        var question: DirectorPendingQuestion?
        var conflict: DirectorPendingConflict?
        var lastProject: DirectorProjectSnapshot?
        var draftInstruction: String?
        var earlierSummaries: [String]?
    }

    @Published private(set) var exchanges: [Exchange] = []
    var question: DirectorPendingQuestion?
    var conflict: DirectorPendingConflict?
    var lastProject: DirectorProjectSnapshot?
    var draftInstruction = ""
    private var earlierSummaries: [String] = []
    let storageURL: URL?
    private let recordingID: UUID?

    init(storageURL: URL? = nil, recordingID: UUID? = nil) {
        self.storageURL = storageURL
        self.recordingID = recordingID
        if let storageURL, let data = try? Data(contentsOf: storageURL), data.count <= 2_000_000,
           let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1,
           archive.recordingID == nil || recordingID == nil || archive.recordingID == recordingID {
            exchanges = archive.exchanges
            question = archive.question
            conflict = archive.conflict
            lastProject = archive.lastProject
            draftInstruction = archive.draftInstruction ?? ""
            earlierSummaries = archive.earlierSummaries ?? []
        }
    }

    static func storageURL(for projectURL: URL) -> URL {
        let identity = SHA256.hash(data: Data(projectURL.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FrameThrower/Director", isDirectory: true)
            .appendingPathComponent(identity + ".json")
    }

    static func object<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return object
    }

    /// Older complete exchanges become compact event summaries; current state
    /// is supplied separately on every request and is never inferred from them.
    func messages(byteBudget: Int = 12_000, continuing requestID: UUID? = nil) -> [[String: Any]] {
        var recent: [Exchange] = []
        var bytes = 0
        for exchange in exchanges.reversed() {
            let size = (try? JSONEncoder().encode(exchange.messages).count) ?? byteBudget
            if bytes + size > byteBudget { break }
            recent.insert(exchange, at: 0)
            bytes += size
        }
        let omitted = exchanges.count - recent.count
        var result: [[String: Any]] = []
        if omitted > 0 || !earlierSummaries.isEmpty {
            let summaries = (earlierSummaries + exchanges.prefix(omitted).map(\.summary)).suffix(12)
            result.append(["role": "user", "content": Self.eventText([
                "kind": "earlier_activity", "omitted_recent_exchanges": omitted,
                "retained_older_summaries": earlierSummaries.count, "recent_summaries": Array(summaries),
                "note": "Historical activity; the separately supplied current editor state is authoritative."
            ])])
        }
        result += recent.flatMap(\.messages).compactMap { Self.object($0) as? [String: Any] }
        if let requestID {
            // Multiple lookup pages can outgrow one complete exchange. Keep
            // the archive intact, but always deliver the literal request and
            // latest real call/result pair to a continuation. Older pages are
            // explicitly omitted, never replaced with invented tool results.
            let active = exchanges.filter { $0.id == requestID }.flatMap(\.messages)
            if let original = active.first(where: { $0.role == "user" }),
               active.count >= 2, let last = active.last, last.role == "tool",
               let callID = last.toolCallID,
               let preceding = active.dropLast().last,
               preceding.role == "assistant", preceding.toolCalls?.contains(where: { $0.id == callID }) == true,
               !result.contains(where: { $0["role"] as? String == "user" && $0["content"] as? String == original.content }) ||
                result.last?["tool_call_id"] as? String != callID {
                let pages = active.dropLast().compactMap { message -> [String: Any]? in
                    guard message.role == "tool", let content = message.content,
                          let value = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                          let page = value["history_page"] as? [String: Any] else { return nil }
                    return ["stack": page["stack"] ?? NSNull(), "offset": page["offset"] ?? NSNull(),
                            "limit": page["limit"] ?? NSNull()]
                }
                let note = Message(role: "user", content: Self.eventText([
                    "kind": "continuation_compacted", "omitted_lookup_pages": pages,
                    "note": "Earlier conversation and lookup pages were omitted to fit context. Only the latest actual tool result follows; inspect again if you need omitted details."
                ]))
                result = [original, note, preceding, last].compactMap { Self.object($0) as? [String: Any] }
            }
        }
        return result
    }

    func begin(_ text: String, requestID: UUID) {
        exchanges.append(Exchange(id: requestID, messages: [Message(role: "user", content: text)], summary: String(text.prefix(200)), origin: "request"))
        pruneCount()
    }

    func finish(requestID: UUID, response: Data?, outcome: [String: Any]) {
        guard exchanges.contains(where: { $0.id == requestID }) else { return }
        // A manual change may arrive while inference is running. Keep it before
        // the later model response rather than moving that result back in time.
        if exchanges.last?.id != requestID {
            exchanges.append(Exchange(id: requestID, messages: [], summary: "", origin: "response"))
        }
        let index = exchanges.count - 1
        let result = Self.jsonText(outcome)
        if let response,
           let root = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           let choices = root["choices"] as? [[String: Any]], let raw = choices.first?["message"] as? [String: Any],
           let calls = raw["tool_calls"] as? [[String: Any]], calls.count == 1,
           let function = calls[0]["function"] as? [String: Any],
           let name = function["name"] as? String, let arguments = function["arguments"] as? String {
            let originalID = calls[0]["id"] as? String
            let used = Set(exchanges.flatMap(\.messages).flatMap { $0.toolCalls?.map(\.id) ?? [] })
            let callID = originalID.flatMap { !$0.isEmpty && !used.contains($0) ? $0 : nil }
                ?? "director_" + requestID.uuidString + "_" + String(used.count)
            exchanges[index].messages.append(Message(role: "assistant", content: raw["content"] as? String,
                toolCalls: [Call(id: callID, function: Function(name: name, arguments: arguments))]))
            exchanges[index].messages.append(Message(role: "tool", content: result, toolCallID: callID))
        } else {
            exchanges[index].messages.append(Message(role: "user", content: Self.eventText(outcome)))
        }
        let status = outcome["status"] as? String ?? "completed"
        let summary = outcome["summary"] as? String ?? outcome["question"] as? String ?? outcome["error"] as? String ?? status
        exchanges[index].summary = status + ": " + String(summary.prefix(240))
    }

    func event(_ details: [String: Any]) {
        let kind = details["kind"] as? String ?? "editor_changed"
        let names = details["names"] as? [String] ?? []
        exchanges.append(Exchange(id: UUID(), messages: [Message(role: "user", content: Self.eventText(details))],
            summary: kind + (names.isEmpty ? "" : ": " + names.joined(separator: ", ")), origin: "app"))
        pruneCount()
    }

    static func projectEvent(from before: RecordingProject, to after: RecordingProject,
                             operation: ProjectHistoryOperation? = nil) -> [String: Any] {
        let kind = operation?.kind.rawValue ?? "state_changed"
        let names = operation?.names ?? []
        let old = Self.object(before.state) as? [String: Any] ?? [:]
        let new = Self.object(after.state) as? [String: Any] ?? [:]
        var changes: [String: Any] = [:]
        for key in Set(old.keys).union(new.keys) {
            if Self.jsonText(["value": old[key] ?? NSNull()]) != Self.jsonText(["value": new[key] ?? NSNull()]) {
                changes[key] = new[key] ?? NSNull()
            }
        }
        if before.title != after.title { changes["title"] = after.title.map { $0 as Any } ?? NSNull() }
        if before.videoAssets != after.videoAssets {
            let previous = Set(before.videoAssets.map(\.id)), current = Set(after.videoAssets.map(\.id))
            changes["video_sources"] = ["upsert": after.videoAssets.filter { !before.videoAssets.contains($0) }.map { source in
                var value: [String: Any] = ["id": source.id.uuidString, "name": source.name, "kind": source.kind.rawValue, "role": source.role.rawValue]
                if let duration = source.duration { value["source_duration"] = duration }
                if let width = source.pixelWidth { value["pixel_width"] = width }
                if let height = source.pixelHeight { value["pixel_height"] = height }
                if let audio = source.hasAudio { value["has_audio"] = audio }
                return value
            }, "removed_ids": previous.subtracting(current).map(\.uuidString).sorted(), "count": after.videoSources.count] as [String: Any]
        }
        return ["kind": kind, "actor": "user", "names": names, "changes": changes,
                "edit_steps": object(DirectorTranscriptStep.changes(from: before.state, to: after.state, references: after.references)),
                "revision": (try? EditorCommandDispatcher.revision(for: after)) ?? "",
                "undo_count": after.undoHistory.count, "redo_count": after.redoHistory.count]
    }

    static func restoredProjectEvent(from before: DirectorProjectSnapshot, to after: RecordingProject) -> [String: Any] {
        ["kind": "recording_changed_outside_session", "actor": "user",
         "previous_revision": before.revision, "revision": (try? EditorCommandDispatcher.revision(for: after)) ?? "",
         "state": object(after.state), "title": after.title.map { $0 as Any } ?? NSNull()]
    }

    /// Machine notifications carry the exact changed collection entries, not
    /// another copy of every unchanged keyframe. No events or values are
    /// dropped and no model history is summarized. To replay a delta: remove
    /// removed_ids and the upsert IDs, then insert upserts in ascending index.
    static func nativeEvent(_ event: [String: Any], from before: EditState, to after: EditState) -> [String: Any] {
        let old = object(before) as? [String: Any] ?? [:]
        let new = object(after) as? [String: Any] ?? [:]
        var notification = event
        var changes = event["changes"] as? [String: Any] ?? [:]
        if event["state"] != nil {
            notification.removeValue(forKey: "state")
            for key in Set(old.keys).union(new.keys) where jsonText(["value": old[key] ?? NSNull()]) != jsonText(["value": new[key] ?? NSNull()]) {
                changes[key] = new[key] ?? NSNull()
            }
        }
        for key in ["zoomKeyframes", "pipKeyframes", "cameraOpacityKeyframes", "regions", "editAnchors", "cuts", "speedKeyframes"] where changes[key] != nil {
            guard let previous = old[key] as? [[String: Any]], let next = new[key] as? [[String: Any]] else { continue }
            let oldIDs = previous.compactMap { $0["id"] as? String }, newIDs = next.compactMap { $0["id"] as? String }
            guard oldIDs.count == previous.count, newIDs.count == next.count,
                  Set(oldIDs).count == oldIDs.count, Set(newIDs).count == newIDs.count else { continue }
            let oldRows = Dictionary(uniqueKeysWithValues: zip(oldIDs, previous))
            let nextIDs = Set(newIDs)
            let removed = oldIDs.filter { !nextIDs.contains($0) }
            var changed = Set(zip(newIDs, next).compactMap { id, row in
                oldRows[id].map { jsonText($0) == jsonText(row) } == true ? nil : id
            })
            // A pure order change is still factual state. If unaffected rows
            // also moved, include them rather than losing their ordering.
            if oldIDs.filter({ nextIDs.contains($0) && !changed.contains($0) }) != newIDs.filter({ !changed.contains($0) }) {
                changed = Set(newIDs)
            }
            let upsert: [[String: Any]] = next.enumerated().compactMap { index, row in
                guard let id = row["id"] as? String, changed.contains(id) else { return nil }
                return ["index": index, "value": row]
            }
            changes[key] = ["encoding": "indexed_collection_delta", "removed_ids": removed,
                            "upsert": upsert, "count": next.count]
        }
        if changes["videoLayers"] != nil {
            if let next = new["videoLayers"] as? [[String: Any]] {
                let previous = old["videoLayers"] as? [[String: Any]]
                var delta = videoCollectionDelta(from: previous ?? [], to: next)
                // nil means implicit legacy screen/camera, whereas [] is an
                // explicitly empty video composition. Never merge the two.
                if previous == nil { delta["replace"] = true }
                changes["videoLayers"] = delta
            } else { changes["videoLayers"] = NSNull() }
        }
        notification["changes"] = changes
        return notification
    }

    /// Exact video-only nested patches. A changed gain must not resend sibling
    /// clips or their geometry/opacity/volume arrays. Existing rows carry only
    /// changed fields; new rows carry their actual values. Pure reordering uses
    /// identities only. This changes the representation, never the facts or the
    /// provider's conversation/compaction policy.
    private static func videoCollectionDelta(from previous: [[String: Any]], to next: [[String: Any]]) -> [String: Any] {
        let oldIDs = previous.compactMap { $0["id"] as? String }, newIDs = next.compactMap { $0["id"] as? String }
        guard oldIDs.count == previous.count, newIDs.count == next.count,
              Set(oldIDs).count == oldIDs.count, Set(newIDs).count == newIDs.count else {
            return ["encoding": "replacement", "value": next]
        }
        let oldRows = Dictionary(uniqueKeysWithValues: zip(oldIDs, previous)), nextIDs = Set(newIDs)
        let collectionFields: Set<String> = ["clips", "geometryKeyframes", "opacityKeyframes", "volumeKeyframes"]
        var added: [[String: Any]] = [], updated: [[String: Any]] = []
        for (index, row) in next.enumerated() {
            let id = newIDs[index]
            guard let before = oldRows[id] else { added.append(["index": index, "value": row]); continue }
            guard jsonText(before) != jsonText(row) else { continue }
            var fields: [String: Any] = [:], collections: [String: Any] = [:], removedFields: [String] = []
            for key in Set(before.keys).union(row.keys).sorted() where key != "id" {
                guard jsonText(["value": before[key] ?? NSNull()]) != jsonText(["value": row[key] ?? NSNull()]) else { continue }
                guard let value = row[key] else { removedFields.append(key); continue }
                if collectionFields.contains(key), let newRows = value as? [[String: Any]],
                   let priorRows = before[key] as? [[String: Any]] {
                    collections[key] = videoCollectionDelta(from: priorRows, to: newRows)
                } else { fields[key] = value }
            }
            var patch: [String: Any] = ["id": id]
            if !fields.isEmpty { patch["set"] = fields }
            if !removedFields.isEmpty { patch["removed_fields"] = removedFields }
            if !collections.isEmpty { patch["collections"] = collections }
            updated.append(patch)
        }
        var delta: [String: Any] = ["encoding": "nested_collection_delta", "removed_ids": oldIDs.filter { !nextIDs.contains($0) },
            "added": added, "updated": updated, "count": next.count]
        if oldIDs != newIDs { delta["order"] = newIDs }
        return delta
    }

    @discardableResult
    func save() -> Bool {
        guard let storageURL else { return true }
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            func encoded() throws -> Data {
                try JSONEncoder().encode(Archive(recordingID: recordingID, exchanges: exchanges, question: question, conflict: conflict,
                    lastProject: lastProject, draftInstruction: draftInstruction, earlierSummaries: earlierSummaries))
            }
            var data = try encoded()
            while data.count > 2_000_000, exchanges.count > 1 {
                remember(exchanges.removeFirst().summary)
                data = try encoded()
            }
            guard data.count <= 2_000_000 else { return false }
            // A pending conversation must remain readable after the Mac locks.
            // Directory/file permissions keep this local text private without
            // coupling project recovery to the current screen-lock state.
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            return true
        } catch { return false }
    }

    private static func eventText(_ details: [String: Any]) -> String { jsonText(["app_event": details]) }
    private func remember(_ summary: String) {
        earlierSummaries.append(summary)
        if earlierSummaries.count > 32 { earlierSummaries.removeFirst(earlierSummaries.count - 32) }
    }
    private func pruneCount() {
        while exchanges.count > 200 { remember(exchanges.removeFirst().summary) }
    }
    private static func jsonText(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
