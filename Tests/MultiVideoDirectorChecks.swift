import Foundation

private enum MultiVideoDirectorFailure: Error { case failed(String) }

/// Typed metadata edits, persisted history and the real automation host only.
/// Sources are declared vector patterns; no media is created, opened or decoded.
@main @MainActor
struct MultiVideoDirectorChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw MultiVideoDirectorFailure.failed(message) }
    }
    static func reject(_ action: () throws -> Void, _ message: String) throws {
        do { try action() } catch { return }; throw MultiVideoDirectorFailure.failed(message)
    }
    static func rejectAsync(_ action: () async throws -> Void, _ message: String) async throws {
        do { try await action() } catch { return }; throw MultiVideoDirectorFailure.failed(message)
    }
    static func object(_ value: Any) throws -> [String: Any] {
        if let data = value as? Data { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
        return value as! [String: Any]
    }
    static func result(_ data: Data) throws -> [String: Any] { try object(try object(data)["result"]!) }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Driver interlock remains enabled")
        try strictSchemas()
        try longSourceClockRamp()
        try await automationAndHistory()
        print("Multi-video Director checks passed (strict schemas, bounded source/layer/clip/automation inspection, footage/project clocks, independent properties, legacy materialization, atomic batches, overlap validation, save collisions, revision conflicts and ordinary Undo/Redo; no media/model).")
    }
    static func strictSchemas() throws {
        let id = UUID().uuidString, layer = UUID().uuidString
        let valid = #"{"operation":"addVideoClip","layerID":"LAYER","patch":{"sourceID":"SOURCE","start":1,"end":4}}"#
            .replacingOccurrences(of: "LAYER", with: layer).replacingOccurrences(of: "SOURCE", with: id)
        let mutation = try JSONDecoder().decode(EditorMutation.self, from: Data(valid.utf8))
        try require(try JSONDecoder().decode(EditorMutation.self, from: JSONEncoder().encode(mutation)) == mutation,
            "Sparse clip command allocates a stable host ID and round-trips")
        for invalid in [
            valid.replacingOccurrences(of: "\"start\":1", with: "\"start\":null"),
            valid.replacingOccurrences(of: "\"start\":1", with: "\"path\":\"/private/movie.mov\",\"start\":1"),
            valid.replacingOccurrences(of: "\"operation\":", with: "\"file\":\"https://example.com/movie.mov\",\"operation\":"),
            #"{"operation":"updateVideoClip","layerID":"LAYER","clipID":"SOURCE","patch":{"geometry":{"rect":{"x":0,"y":0,"width":1,"height":1,"url":"/private"},"crop":{"x":0,"y":0,"width":1,"height":1},"fit":"fit"}}}"#
                .replacingOccurrences(of: "LAYER", with: layer).replacingOccurrences(of: "SOURCE", with: id)
        ] {
            try reject({ _ = try JSONDecoder().decode(EditorMutation.self, from: Data(invalid.utf8)) }, "Unknown/null/path fields must reject")
        }
        let names = ["addVideoLayer", "renameVideoLayer", "removeVideoLayer", "reorderVideoLayer", "addVideoClip", "updateVideoClip", "removeVideoClip", "videoGeometry", "videoOpacity", "videoVolume", "removeVideoAnimation"]
        for name in names {
            let description = try EditorMutation.describe(operation: name)
            let command = description["command_schema"] as! [String: Any]
            let mutation = ((command["properties"] as! [String: Any])["mutation"] as! [String: Any])
            try require(mutation["additionalProperties"] as? Bool == false && description["units"] as? String != nil,
                "Each exact typed video operation has a closed executable schema and clock units")
        }
    }
    static func longSourceClockRamp() throws {
        var project = RecordingProject(screenFilename: "unopened.mov", duration: 120)
        let source = VideoSource(name: "Long take", kind: .testPattern, duration: 1000, pixelWidth: 1600, pixelHeight: 900, hasAudio: false)
        project.videoAssets = [source]
        var state = project.state
        let layer = UUID(), clip = UUID()
        try EditorMutation.addVideoLayer(id: layer, name: "Footage").apply(to: &state, project: project)
        try EditorMutation.addVideoClip(layerID: layer, clipID: clip,
            patch: .init(sourceID: source.id, start: 0, end: 100, rate: 8)).apply(to: &state, project: project)
        try EditorMutation.videoVolume(layerID: layer, clipID: clip, gain: 0.5,
            timing: .init(start: 0, end: 10, easeIn: 2, easeOut: 2), timeBase: .project).apply(to: &state, project: project)
        let point = state.videoLayers!.last!.clips[0].volumeKeyframes.last!
        try require(point.time == 80 && point.duration == 80 && point.easeIn == 16 && point.easeOut == 16,
            "Rate conversion does not impose an unrelated 60-second cap on footage automation")
    }
    static func automationAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multi-video-director-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = VideoSource(name: "Phone portrait", kind: .testPattern, duration: 30, pixelWidth: 1080, pixelHeight: 1920, hasAudio: false)
        var project = RecordingProject(screenFilename: "unopened.mov", cameraFilename: "unopened-camera.mov", duration: 20)
        project.videoAssets = [source]
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "Save pure metadata fixture")
        let playback = EditorPlayback(), host = EditorAutomationHost(editor: editor, playback: playback)
        defer { playback.close() }
        func revision() throws -> String { try EditorCommandDispatcher.revision(for: editor.project) }
        func call(_ name: String, _ fields: [String: Any]) async throws -> Data {
            var args = fields; args["document_id"] = host.documentID
            return try await host.performAutomation(name, arguments: JSONSerialization.data(withJSONObject: args))
        }
        func apply(_ operations: [EditorMutation], name: String = "Compose footage", expected: String? = nil) async throws -> Data {
            let commands = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operations.map(EditorCommand.mutate)))
            return try await call("apply_edits", ["expected_revision": expected ?? revision(), "commands": commands, "name": name])
        }
        var shownInspector: String?
        host.navigate = { operation, _, inspector in if operation == "show_inspector" { shownInspector = inspector } }
        for inspector in ["Videos", "Speed"] {
            _ = try await call("navigate_editor", ["operation": "show_inspector", "inspector": inspector])
            try require(shownInspector == inspector, "Every public inspector schema value reaches the native navigation callback")
        }
        let before = editor.project, layer = UUID(), clip = UUID(), geometryPoint = UUID(), alphaPoint = UUID(), volumePoint = UUID()
        let geometry = VideoGeometry(rect: .init(x: 0.1, y: 0.1, width: 0.6, height: 0.8), crop: .init(x: 0, y: 0, width: 1, height: 1), fit: .fit)
        let receipt = try object(await apply([
            .addVideoLayer(id: layer, name: "Phone"),
            .addVideoClip(layerID: layer, clipID: clip, patch: .init(sourceID: source.id, start: 3, end: 10, sourceStart: 2, rate: 1.5)),
            .videoGeometry(layerID: layer, clipID: clip, target: geometry, timing: .init(start: 4, end: 7), id: geometryPoint),
            .videoOpacity(layerID: layer, clipID: clip, opacity: 0.5, timing: .init(start: 4, end: 7), id: alphaPoint),
            .videoVolume(layerID: layer, clipID: clip, gain: 0.25, timing: .init(start: 4, end: 7), id: volumePoint)
        ]))
        try require(receipt["ok"] as? Bool == true, "Actual MCP host applies typed footage batch")
        let composed = editor.project
        let layers = composed.state.videoLayers!
        try require(layers.count == 3 && layers[0].clips[0].layout == .screen && layers[1].clips[0].layout == .camera,
            "First explicit edit materializes original screen/camera adapters")
        try require(composed.state.zoomKeyframes == before.state.zoomKeyframes && composed.state.pipKeyframes == before.state.pipKeyframes,
            "Legacy camera and screen animation survive materialization")
        let authored = layers[2].clips[0]
        try require(authored.geometry(atSourceTime: 7) == geometry && authored.opacity(atSourceTime: 7) == 0.5 && authored.envelopeGain(atSourceTime: 7) == 0.25,
            "Independent geometry, opacity and volume share source-time animation without conflicts")
        try require(editor.project.undoHistory.count == 1 && ProjectEditor.open(url: editor.url).project == composed,
            "One transaction persists all new layers, clips and independent automation as one Undo")
        _ = try await call("control_document", ["operation": "undo", "expected_revision": revision()])
        try require(editor.project.state == before.state && editor.project.videoAssets == before.videoAssets,
            "Undo returns to nil legacy layout while retaining registered immutable footage")
        _ = try await call("control_document", ["operation": "redo", "expected_revision": revision()])
        try require(editor.project.state == composed.state, "Ordinary Redo restores the complete composition")
        _ = try await apply([.cutSection(start: 4, end: 6, timeBase: .source, crossfade: 1)])
        let joined = try result(await call("inspect_editor", ["section": "state", "component": "videos", "time_base": "output", "time": 3.5]))
        let branches = joined["samples"] as! [[String: Any]]
        let phoneTimes = branches.compactMap { branch -> Double? in
            let rows = (branch["value"] as! [String: Any])["items"] as! [[String: Any]]
            return rows.first { $0["clip_id"] as? String == clip.uuidString }?["source_time"] as? Double
        }
        try require(branches.count == 2 && phoneTimes == [2.75, 7.25],
            "Finished crossfade exposes two authoring branches with distinct footage-source times")
        _ = try await call("control_document", ["operation": "undo", "expected_revision": revision()])
        try require(editor.project.state == composed.state, "Global cut Undo preserves the composed footage")
        let restored = editor.project
        _ = try await apply([.updateVideoClip(layerID: layer, clipID: clip, patch: .init(start: 1, end: 3, sourceStart: 8, rate: 2))])
        let trimmed = editor.project.state.videoLayers!.last!.clips[0]
        try require(trimmed.geometryKeyframes == authored.geometryKeyframes && trimmed.opacityKeyframes == authored.opacityKeyframes && trimmed.volumeKeyframes == authored.volumeKeyframes,
            "Move/trim/rate changes preserve hidden source automation byte-for-byte")
        let points = try result(await call("inspect_editor", ["section": "video_animations", "layer_id": layer.uuidString, "clip_id": clip.uuidString, "limit": 16]))
        let pointRows = (points["points"] as! [String: Any])["items"] as! [[String: Any]]
        try require(pointRows.count == 6 && pointRows.allSatisfy { $0["inside_clip"] as? Bool == false },
            "Source automation outside a trim remains inspectable and is labeled hidden")
        _ = try await call("control_document", ["operation": "undo", "expected_revision": revision()])
        try require(editor.project.state == restored.state, "Undo restores trim and the exact source-driven animation")
        _ = try await apply([.renameVideoLayer(layerID: layer, name: "Phone take"), .reorderVideoLayer(layerID: layer, index: 1)])
        try require(editor.project.state.videoLayers![1].name == "Phone take" && editor.project.state.videoLayers![1].clips[0].id == clip,
            "Layer rename/reorder preserve stable clip identities")

        let sourcePage = try result(await call("inspect_editor", ["section": "video_sources", "offset": 2, "limit": 1]))
        let sourceRows = sourcePage["items"] as! [[String: Any]]
        try require(sourcePage["total"] as? Int == 3 && sourceRows.count == 1 && sourceRows[0]["name"] as? String == source.name,
            "Sources are paginated with meaningful names")
        try require(!String(data: JSONSerialization.data(withJSONObject: sourcePage), encoding: .utf8)!.contains("relativePath"), "Source catalog does not disclose managed paths")
        let clipPage = try result(await call("inspect_editor", ["section": "video_clips", "layer_id": layer.uuidString]))
        let clipRow = ((clipPage["clips"] as! [String: Any])["items"] as! [[String: Any]])[0]
        try require(clipRow["project_start"] as? Double == 3 && clipRow["source_start"] as? Double == 2 && clipRow["geometryKeyframes"] == nil,
            "Clip inspection names clocks and keeps automation on demand")
        let evaluated = try result(await call("inspect_editor", ["section": "state", "component": "videos", "time": 5]))
        let samples = ((evaluated["value"] as! [String: Any])["items"] as! [[String: Any]])
        try require(samples.contains { $0["clip_id"] as? String == clip.uuidString && $0["source_time"] as? Double == 5 },
            "Video component inspection maps project time to each footage source clock")
        try await rejectAsync({ _ = try await call("inspect_editor", ["section": "video_clips"]) }, "Clip list requires explicit layer scope")
        try await rejectAsync({ _ = try await call("inspect_editor", ["section": "summary", "clip_id": clip.uuidString]) }, "Inspection rejects unrelated scope fields")

        // A project-clock envelope converts its endpoints and ease durations.
        _ = try await apply([.videoVolume(layerID: layer, clipID: clip, gain: 0.8,
            timing: .init(start: 8, end: 9, easeIn: 0.2, easeOut: 0.3), timeBase: .project)])
        let arrival = editor.project.state.videoLayers![1].clips[0].volumeKeyframes.last!
        try require(arrival.time == 11 && arrival.duration == 1.5 && abs(arrival.easeIn! - 0.3) < 1e-9 && abs(arrival.easeOut! - 0.45) < 1e-9,
            "Project-clock motion/eases convert at the clip rate without rewriting prior source keys")
        let conflictBefore = editor.project, conflictBytes = try Data(contentsOf: editor.url)
        let conflict = try object(await apply([.videoVolume(layerID: layer, clipID: clip, gain: 0,
            timing: .init(start: 5, end: 6))]))
        let errors = (conflict["error"] as! [String: Any])["conflicts"] as! [[String: Any]]
        try require(conflict["ok"] as? Bool == false && errors.first?["clip_id"] as? String == clip.uuidString && errors.first?["property"] as? String == "volume" && errors.first?["time_base"] as? String == "footage_source",
            "Conflicts identify the exact clip/property/source interval rather than another layer")
        try require(editor.project == conflictBefore && Data(contentsOf: editor.url) == conflictBytes, "Rejected animation conflict saves nothing")
        let stale = try revision()
        _ = try await apply([.removeVideoAnimation(layerID: layer, clipID: clip, property: .volume, pointID: arrival.id)])
        try await rejectAsync({ _ = try await apply([.renameVideoLayer(layerID: layer, name: "Stale")], expected: stale) }, "Stale revision cannot change composition")
        let stable = editor.project, stableBytes = try Data(contentsOf: editor.url)
        try await rejectAsync({
            _ = try await apply([.renameVideoLayer(layerID: layer, name: "Must roll back"),
                .addVideoClip(layerID: layer, clipID: UUID(), patch: .init(sourceID: UUID(), start: 1, end: 3))])
        }, "Unknown source rolls back the complete batch")
        try require(editor.project == stable && Data(contentsOf: editor.url) == stableBytes, "Failed batch leaks no rename/history/file mutation")
        // Construct a same-layer crossfade, then reject a triple overlap.
        let second = UUID()
        _ = try await apply([.addVideoClip(layerID: layer, clipID: second, patch: .init(sourceID: source.id, start: 9, end: 13))])
        let crossfade = editor.project.videoSamples(at: 9.5).filter { $0.layerID == layer }
        try require(crossfade.count == 2 && abs(crossfade.reduce(0) { $0 + $1.weight } - 1) < 1e-9, "Same-layer overlap expresses a bounded crossfade")
        let overlapBefore = editor.project
        try await rejectAsync({ _ = try await apply([.addVideoClip(layerID: layer, clipID: UUID(), patch: .init(sourceID: source.id, start: 9.25, end: 14))]) }, "Triple overlap rejects")
        try require(editor.project == overlapBefore, "Overlap rejection is atomic")
        _ = try await apply([.removeVideoClip(layerID: layer, clipID: second), .removeVideoLayer(layerID: layer)])
        try require(editor.project.videoAssets == before.videoAssets && editor.project.state.videoLayers!.count == 2,
            "Clip/layer removal retains source assets for historical references")
        _ = try await call("control_document", ["operation": "undo", "expected_revision": revision()])
        try require(editor.project.state == overlapBefore.state, "One Undo restores removed layer and both clip references")
        let history = try result(await call("inspect_editor", ["section": "history", "limit": 16]))
        let detailRows = ((history["details"] as! [String: Any])["undo"] as! [String: Any])["entries"] as! [[String: Any]]
        try require(detailRows.contains { ($0["changed_components"] as? [String])?.contains("video_layers") == true }, "History exposes video composition changes")
        let beforeCollision = editor.project
        try Data("external replacement".utf8).write(to: editor.url)
        try await rejectAsync({ _ = try await apply([.renameVideoLayer(layerID: layer, name: "Cannot save")]) }, "Save collision rejects composition mutation")
        try require(editor.project == beforeCollision && Data(contentsOf: editor.url) == Data("external replacement".utf8), "Save failure preserves project/history and external bytes")
        try require(!playback.hasMediaPlayer && playback.canvasPlayer == nil, "All inspection and mutations keep video decoding disabled")
    }
}
