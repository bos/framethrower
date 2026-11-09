import Foundation

private enum ComponentCheckFailure: Error { case failed(String) }
@main @MainActor
struct EditorComponentInspectionChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ComponentCheckFailure.failed(message) }
    }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
    @MainActor final class Fixture {
        let directory: URL
        let editor: ProjectEditor
        let playback = EditorPlayback()
        let host: EditorAutomationHost
        init(dense: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-component-inspection-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let normal = PIPPlacement(x: 0.8, y: 0.7, scale: 0.25, shape: .circle, crop: .init(x: 0.3, y: 0.4), sourceZoom: 1.3)
            var project = RecordingProject(screenFilename: "unopened-screen.mov", cameraFilename: "unopened-camera.mov", duration: dense ? 200 : 20)
            project.state.trimStart = 2; project.state.trimEnd = project.duration - 2
            project.state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 1),
                ZoomKeyframe(time: 10, scale: 2.5, x: 0.4, y: 0.6, transition: .smooth, duration: 4, easeIn: 0.7, easeOut: 1.3)]
            var full = normal; full.fullscreen = 1
            project.state.pipKeyframes = [PIPKeyframe(time: 0, placement: normal),
                PIPKeyframe(time: 10, placement: full, duration: 4, easeIn: 0.7, easeOut: 1.3)]
            project.state.cursorStyle = CursorStyle(visible: false, size: 2.2, smoothing: 0.8, clickHighlight: false)
            project.state.audio.volume = 0.4; project.state.audio.fadeOut = 4
            project.state.presentation = CanvasPresentation(aspect: .square, padding: 0.1, cornerRadius: 0.06,
                background: .init(red: 0.1, green: 0.2, blue: 0.3))
            if dense {
                project.state.zoomKeyframes = (0..<160).map { i in
                    ZoomKeyframe(time: Double(i), scale: 1 + Double(i % 6) / 3, x: 0.5, y: 0.5,
                        transition: i == 0 ? .jump : .smooth, duration: 0.8, easeIn: 0.2, easeOut: 0.3)
                }
                project.state.pipKeyframes = (0..<160).map { i in
                    let fraction: Double? = i % 10 == 5 ? 1 : nil
                    let placement = PIPPlacement(x: Double(i % 9) / 10, y: 0.7,
                        scale: 0.25, shape: .circle, sourceZoom: 1.2, fullscreen: fraction)
                    let transition: PIPTransition = i == 0 ? .jump : .smooth
                    return PIPKeyframe(time: Double(i), placement: placement,
                        transition: transition, duration: 0.8, easeIn: 0.2, easeOut: 0.3)
                }
            }
            project.ensureReferences()
            editor = ProjectEditor(project: project, url: directory.appendingPathComponent("query.framethrower"))
            try require(editor.save(), "save metadata fixture")
            host = EditorAutomationHost(editor: editor, playback: playback)
        }
        func ready() async { await host.rebuildPreview(); playback.seek(3) }
        func close() { playback.close(); try? FileManager.default.removeItem(at: directory) }
        func query(_ fields: [String: Any]) async throws -> Data {
            var args = fields; args["document_id"] = host.documentID
            return try await host.performAutomation("inspect_editor", arguments: json(args))
        }
        func component(_ name: String, time: Double? = nil) async throws -> [String: Any] {
            var args: [String: Any] = ["section": "state", "component": name]
            if let time { args["time"] = time }
            return try Self.result(await query(args))
        }
        static func result(_ data: Data) throws -> [String: Any] {
            guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any], body["ok"] as? Bool == true,
                  let result = body["result"] as? [String: Any] else { throw ComponentCheckFailure.failed("query response") }
            return result
        }
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        guard let value else { throw ComponentCheckFailure.failed("missing component value") }
        return try JSONDecoder().decode(type, from: json(value))
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "metadata-only suspension")
        try await evaluatedValuesAndDefaultTime()
        try await draftAndInvalidQueries()
        try await denseResponseMeasurements()
        try catalogSubjectDescriptions()
        print("Component inspection checks passed: exact shared screen/camera evaluation, current style/draft values, authoritative scope, full-state compatibility, strict combinations/times and zero seek/save/Undo/media effects.")
    }
    static func evaluatedValuesAndDefaultTime() async throws {
        let f = try Fixture(); defer { f.close() }; await f.ready()
        let original = f.editor.project, bytes = try Data(contentsOf: f.editor.url), time = f.playback.time
        let revision = try EditorCommandDispatcher.revision(for: original)
        for sourceTime in [0.0, 1, 6, 8.125, 10, 20] {
            let screen = try await f.component("screen", time: sourceTime)
            try require(try decode(ZoomPlacement.self, screen["value"]) == original.state.zoom(at: sourceTime), "screen shared interpolation")
            let camera = try await f.component("camera", time: sourceTime)
            try require(try decode(PIPPlacement.self, camera["value"]) == original.state.placement(at: sourceTime), "camera shared fullscreen/crop interpolation")
            try require(camera["camera_recorded"] as? Bool == true && camera["source_time"] as? Double == sourceTime, "camera source time and availability")
            let scope = camera["context"] as! [String: Any]
            try require(scope["documentID"] as? String == f.host.documentID && scope["revision"] as? String == revision && scope["hasDraft"] as? Bool == false,
                "current authoritative document/revision scope")
        }
        let current = try await f.component("camera")
        try require(current["source_time"] as? Double == time, "omitted time uses preview source playhead")
        let pointer = try await f.component("pointer", time: 8)
        try require(try decode(CursorStyle.self, pointer["value"]) == original.state.cursorStyle && pointer["scope"] as? String == "recording", "global pointer fields")
        let audio = try await f.component("audio")
        try require(try decode(RecordingAudio.self, audio["value"]) == original.state.audio, "actual requested audio/fade fields")
        let canvas = try await f.component("canvas")
        try require(try decode(CanvasPresentation.self, canvas["value"]) == original.state.presentation, "actual canvas fields")
        let trim = try await f.component("trim")
        let value = trim["value"] as! [String: Any]
        try require(value["start"] as? Double == original.state.trimStart && value["end"] as? Double == original.state.trimEnd, "actual trim")
        let full = try await f.query(["section": "state"])
        let restored = try decode(EditState.self, Fixture.result(full))
        try require(restored == original.state, "omitting component preserves original full-state schema")
        try require(f.editor.project == original && !f.editor.canUndo && f.editor.draftState == nil && f.playback.time == time,
            "queries leave project, history, draft and playhead untouched")
        try require(try Data(contentsOf: f.editor.url) == bytes && !f.playback.hasMediaPlayer, "no save or media objects")
    }
    static func draftAndInvalidQueries() async throws {
        let f = try Fixture(); defer { f.close() }; await f.ready()
        let original = f.editor.project, bytes = try Data(contentsOf: f.editor.url), time = f.playback.time
        var draft = original.state; draft.cursorStyle.size = 3.1; draft.pipKeyframes[1].placement.fullscreen = 0.75
        try require(f.editor.updateDraft(draft, at: 8), "prepare manual draft")
        let pointer = try await f.component("pointer")
        try require(try decode(CursorStyle.self, pointer["value"]) == draft.cursorStyle, "visible draft style queried")
        let scope = pointer["context"] as! [String: Any]
        let revision = try EditorCommandDispatcher.revision(for: original)
        try require(scope["hasDraft"] as? Bool == true && scope["revision"] as? String == revision, "draft is explicitly identified on saved revision")
        let camera = try await f.component("camera", time: 8)
        try require(try decode(PIPPlacement.self, camera["value"]) == draft.placement(at: 8), "visible draft curve evaluated")
        let invalid: [[String: Any]] = [
            ["section": "state", "component": "unknown"], ["section": "state", "component": NSNull()],
            ["section": "state", "component": "camera", "time": -1], ["section": "state", "component": "camera", "time": 21],
            ["section": "state", "component": "camera", "time": true], ["section": "state", "component": "camera", "time": "8"],
            ["section": "state", "time": 8], ["section": "history", "component": "camera"], ["section": "summary", "time": 8],
            ["section": "boxes", "component": "pointer", "time": 8]]
        for args in invalid {
            do { _ = try await f.query(args); throw ComponentCheckFailure.failed("invalid query accepted") }
            catch is EditorAutomationError {} catch is EditorPreviewError {}
        }
        try require(f.editor.project == original && f.editor.draftState == draft && f.playback.time == time,
            "valid and rejected queries preserve the unfinished draft")
        try require(try Data(contentsOf: f.editor.url) == bytes, "queries never save a draft")
        _ = f.editor.cancelDraft()
    }
    static func catalogSubjectDescriptions() throws {
        let catalog = try EditorMutation.describe(operation: nil)
        guard let subjects = catalog["subjects"] as? [String: String] else { throw ComponentCheckFailure.failed("subject capability descriptions") }
        try require(Set(subjects.keys) == ["screen", "cameraOverlay", "cameraSource"], "all framing subjects distinguished")
        try require(subjects["screen"]?.contains("zoomScreen") == true && subjects["screen"]?.contains("screen magnification") == true,
            "screen zoom is explicitly main-screen framing")
        try require(subjects["cameraOverlay"]?.contains("fullscreen=1") == true && subjects["cameraOverlay"]?.contains("PIP") == true,
            "catalog exposes which operation fills the PIP to canvas")
        try require(subjects["cameraSource"]?.contains("inside") == true && subjects["cameraSource"]?.contains("sourceZoom") == true,
            "source image crop is distinct from overlay resizing")
        let groups = catalog["operations"] as! [String: [String]]
        try require(groups["camera"] == ["cameraOverlay", "alignCameraOverlay", "cameraSource"] && groups["screen"]?.contains("zoomScreen") == true,
            "existing operation groups remain compatible")
        try require(catalog["command_schema"] == nil && catalog["mutation_schema"] == nil, "exact schemas remain on demand")
        var previous = catalog; previous.removeValue(forKey: "subjects")
        let before = try json(previous).count, after = try json(catalog).count
        try require(after < 2048 && after - before < 800, "subject catalog stays compact")
        print("Editing catalog bytes: before subjects=\(before), after subjects=\(after), delta=\(after - before).")
    }

    static func denseResponseMeasurements() async throws {
        let f = try Fixture(dense: true); defer { f.close() }; await f.ready()
        let original = f.editor.project
        let full = try await f.query(["section": "state"])
        var sizes: [String: Int] = ["full_state": full.count]
        for component in ["screen", "camera", "pointer", "audio", "canvas", "trim"] {
            let data = try await f.query(["section": "state", "component": component, "time": 87.125])
            sizes[component] = data.count
            try require(data.count < 2048 && data.count * 20 < full.count, "component response remains independent of keyframe count")
        }
        try require(f.editor.project == original && !f.editor.canUndo && !f.playback.hasMediaPlayer, "dense reads have no document/media effects")
        print("Dense metadata response bytes (160 screen +160 camera keyframes): \(sizes)")
    }
}
