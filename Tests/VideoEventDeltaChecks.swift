import Foundation

private enum VideoEventDeltaFailure: Error { case failed(String) }

/// Exercises only saved JSON, exact event projection and replay. No renderer,
/// source file, image, video, model process, microphone or app window is used.
@main @MainActor
struct VideoEventDeltaChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VideoEventDeltaFailure.failed(message) }
    }
    static func bytes(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Media interlock remains enabled")
        let before = fixture()
        try before.validate()
        var after = before
        after.state.videoLayers![0].clips[17].volumeKeyframes[7].gain = 0.4
        let delta = notification(before, after)
        let encoded = try bytes(delta)
        let whole = try bytes(DirectorConversation.object(after.state))
        try require(encoded.count < 5_000 && encoded.count < whole.count / 40,
            "One volume-point change must not repeat a large layer's clips or automation")
        let text = String(decoding: encoded, as: UTF8.self)
        let clip = before.state.videoLayers![0].clips[17]
        try require(text.contains(clip.id.uuidString) && text.contains(clip.volumeKeyframes[7].id.uuidString),
            "The event identifies its layer, clip and changed point")
        for index in [0, 16, 18, 49] {
            try require(!text.contains(before.state.videoLayers![0].clips[index].id.uuidString), "Unchanged sibling clips stay out of the event")
        }
        try require(!text.contains(clip.geometryKeyframes[0].id.uuidString) && !text.contains(clip.opacityKeyframes[0].id.uuidString) && !text.contains(clip.volumeKeyframes[0].id.uuidString),
            "Unchanged same-clip automation stays out of the event")
        try require(try replay(delta, onto: before.state) == after.state, "Changed gain replays exactly")
        try require(try replay(notification(after, before), onto: after.state) == before.state, "Undo direction replays exactly")

        var renamed = before
        renamed.state.videoLayers![0].name = "Retitled footage"
        let renameEvent = notification(before, renamed)
        try require(try bytes(renameEvent).count < 2_000 && replay(renameEvent, onto: before.state) == renamed.state,
            "Renaming a populated layer carries its name, not its clips")

        var reordered = before
        reordered.state.videoLayers!.append(VideoLayer(name: "Empty overlay"))
        var reversed = reordered
        reversed.state.videoLayers!.reverse()
        let orderEvent = notification(reordered, reversed)
        try require(try bytes(orderEvent).count < 2_000 && replay(orderEvent, onto: reordered.state) == reversed.state,
            "Layer reorder carries identities/order without large values")

        var changed = before
        changed.state.videoLayers![0].clips[17].geometryKeyframes.remove(at: 1)
        changed.state.videoLayers![0].clips[17].opacityKeyframes[0].easeOut = 0.2
        changed.state.videoLayers![0].clips[17].volumeKeyframes[7].time = 8.25
        changed.state.videoLayers![0].clips[17].volumeKeyframes[7].easeIn = 0.3
        changed.state.videoLayers![0].clips[17].volumeKeyframes.insert(.init(time: 0.25, gain: 0.6, transition: .jump), at: 0)
        changed.state.videoLayers![0].clips[17].volumeKeyframes.swapAt(2, 3)
        changed.state.videoLayers![0].clips.remove(at: 9)
        changed.state.videoLayers![0].clips.append(VideoClip(sourceID: before.videoAssets[0].id, start: 1_500, end: 1_530))
        try require(try replay(notification(before, changed), onto: before.state) == changed.state,
            "Nested insertions, removals, optional fields and order replay without losing facts")
        try require(try replay(notification(changed, before), onto: changed.state) == before.state,
            "Reverse nested changes remove optional fields and restore removed points/clips")

        var implicit = before; implicit.state.videoLayers = nil
        let explicit = before
        try require(try replay(notification(implicit, explicit), onto: implicit.state) == explicit.state,
            "Implicit legacy to explicit composition is a lossless replacement")
        try require(try replay(notification(explicit, implicit), onto: explicit.state) == implicit.state,
            "Undo to implicit legacy is distinct from an empty composition")
        var empty = before; empty.state.videoLayers = []
        try require(try replay(notification(implicit, empty), onto: implicit.state).videoLayers == [],
            "Explicit empty layers do not reactivate implicit legacy video")
        try archiveAndInspection()
        print("Video event delta checks passed (exact nested values, source automation, Undo/Redo direction, nil/empty legacy states, insert/remove/order, and bounded single-point/rename/reorder notifications; no media/model).")
    }
    static func archiveAndInspection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-event-archive-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ProjectEditor(project: fixture(), url: directory.appendingPathComponent("metadata.framethrower"))
        try require(editor.save(), "Save metadata-only archive fixture")
        let archive = directory.appendingPathComponent("conversation.json")
        let session = EditorAssistantSession(transport: { _ in throw VideoEventDeltaFailure.failed("No model request expected") },
            persistsConversation: true, conversationStorageURL: archive)
        session.attach(to: editor)
        session.conversation.begin("Keep this original instruction.", requestID: UUID())
        let original = editor.project.state
        for n in 0..<12 {
            var next = editor.project.state
            next.videoLayers![0].clips[17].volumeKeyframes[7].gain = 0.4 + Double(n) / 100
            try require(editor.commit(next, name: "Adjust clip volume"), "Commit actual observed metadata edit")
        }
        try require(session.conversation.exchanges.count == 13, "Manual changes do not prune the original instruction")
        let saved = try Data(contentsOf: archive)
        try require(saved.count < 700_000, "Archive stores one project snapshot plus compact exact changes, not twelve repeated layers")
        let reopened = DirectorConversation(storageURL: archive, recordingID: editor.automationID)
        try require(reopened.exchanges.count == 13 && reopened.exchanges[0].messages[0].content == "Keep this original instruction.",
            "Conversation archive round-trip retains all user and app exchanges")
        let page = try session.conversationPage(offset: 0, limit: 16)
        try require(try bytes(page).count < 131_072, "Paginated conversation inspection remains within the public response limit")
        var reconstructed = original
        for exchange in reopened.exchanges where exchange.origin == "app" {
            let data = Data(exchange.messages[0].content!.utf8)
            let event = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["app_event"] as! [String: Any]
            reconstructed = try replay(event, onto: reconstructed)
        }
        try require(reconstructed == editor.project.state, "Archived/inspected exact events replay actual manual changes")

        // Reattach from an older saved session: the restored event must use the
        // same compact projection rather than archiving an entire state again.
        let restoredArchive = directory.appendingPathComponent("restored.json")
        let prior = DirectorConversation(storageURL: restoredArchive, recordingID: editor.automationID)
        let priorState = editor.project.state
        prior.lastProject = DirectorProjectSnapshot(editor.project)
        try require(prior.save(), "Save closed-session snapshot")
        var next = editor.project.state
        next.videoLayers![0].clips[17].volumeKeyframes[7].gain = 0.2
        try require(editor.commit(next, name: "Change while closed"), "Change metadata while the second session is closed")
        let restored = EditorAssistantSession(transport: { _ in throw VideoEventDeltaFailure.failed("No model request expected") },
            persistsConversation: true, conversationStorageURL: restoredArchive)
        restored.attach(to: editor)
        try require(restored.conversation.exchanges.count == 1, "Reattachment records one actual outside-session change")
        let restoredPage = try restored.conversationPage(offset: 0, limit: 1)
        try require(try bytes(restoredPage).count < 5_000, "Reattached event omits unchanged clips/automation")
        let content = restored.conversation.exchanges[0].messages[0].content!
        let event = (try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any])["app_event"] as! [String: Any]
        try require(try replay(event, onto: priorState) == editor.project.state, "Reattached compact change replays exactly")
    }
    static func fixture() -> RecordingProject {
        var project = RecordingProject(screenFilename: "unopened.mov", duration: 2_000)
        let source = VideoSource(name: "Vector footage", kind: .testPattern, duration: 30,
            pixelWidth: 1600, pixelHeight: 900, hasAudio: false)
        project.videoAssets = [source]
        let clips: [VideoClip] = (0..<50).map { n in
            var clip = VideoClip(sourceID: source.id, start: Double(n) * 30, end: Double(n + 1) * 30)
            clip.geometryKeyframes = (0..<10).map { .init(time: Double($0 + 1), geometry: VideoGeometry()) }
            clip.opacityKeyframes = (0..<5).map { .init(time: Double($0 + 1), opacity: 1) }
            clip.volumeKeyframes = (0..<20).map { .init(time: Double($0 + 1), gain: 1) }
            return clip
        }
        project.state.videoLayers = [VideoLayer(name: "Footage", clips: clips)]
        return project
    }
    static func notification(_ before: RecordingProject, _ after: RecordingProject) -> [String: Any] {
        DirectorConversation.nativeEvent(DirectorConversation.projectEvent(from: before, to: after), from: before.state, to: after.state)
    }
    static func replay(_ notification: [String: Any], onto state: EditState) throws -> EditState {
        var object = DirectorConversation.object(state) as! [String: Any]
        let changes = notification["changes"] as! [String: Any]
        if let value = changes["videoLayers"] {
            if value is NSNull { object.removeValue(forKey: "videoLayers") }
            else {
                let delta = value as! [String: Any]
                let previous = (object["videoLayers"] as? [[String: Any]]) ?? []
                object["videoLayers"] = try collection(delta, onto: previous)
            }
        }
        return try JSONDecoder().decode(EditState.self, from: bytes(object))
    }
    static func collection(_ delta: [String: Any], onto previous: [[String: Any]]) throws -> [[String: Any]] {
        if delta["encoding"] as? String == "replacement" { return delta["value"] as! [[String: Any]] }
        try require(delta["encoding"] as? String == "nested_collection_delta", "Versioned nested collection encoding")
        var rows = delta["replace"] as? Bool == true ? [] : previous
        let removed = Set(delta["removed_ids"] as! [String])
        rows.removeAll { removed.contains($0["id"] as! String) }
        for patch in delta["updated"] as! [[String: Any]] {
            let id = patch["id"] as! String
            guard let index = rows.firstIndex(where: { $0["id"] as? String == id }) else { throw VideoEventDeltaFailure.failed("Patch references an unknown row") }
            for key in patch["removed_fields"] as? [String] ?? [] { rows[index].removeValue(forKey: key) }
            for (key, value) in patch["set"] as? [String: Any] ?? [:] { rows[index][key] = value }
            for (key, value) in patch["collections"] as? [String: Any] ?? [:] {
                rows[index][key] = try collection(value as! [String: Any], onto: rows[index][key] as? [[String: Any]] ?? [])
            }
        }
        for value in (delta["added"] as! [[String: Any]]).sorted(by: { ($0["index"] as! Int) < ($1["index"] as! Int) }) {
            rows.insert(value["value"] as! [String: Any], at: value["index"] as! Int)
        }
        if let order = delta["order"] as? [String] {
            let lookup = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as! String, $0) })
            rows = try order.map { id in guard let row = lookup[id] else { throw VideoEventDeltaFailure.failed("Order references an unknown row") }; return row }
        }
        try require(rows.count == delta["count"] as? Int, "Exact resulting collection count")
        return rows
    }
}
