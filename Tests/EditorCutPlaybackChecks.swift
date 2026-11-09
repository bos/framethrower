import Foundation

private enum CutPlaybackFailure: Error { case failed(String) }

@main @MainActor
struct EditorCutPlaybackChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw CutPlaybackFailure.failed(message) }
    }
    static func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try require(abs(actual - expected) < 0.000001, "\(message): \(actual) != \(expected)")
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "keep the media interlock enabled")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-cut-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = RecordingProject(screenFilename: "never-open-screen.mov", cameraFilename: "never-open-camera.mov", duration: 14)
        project.state.zoomKeyframes = [.init(time: 9, scale: 2, transition: .smooth, duration: 2)]
        let original = project.state
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("cuts.framethrower"))
        try require(editor.save(), "save metadata fixture")
        let playback = EditorPlayback()
        let endpoint = EditorAutomationHost(editor: editor, playback: playback)
        defer { playback.close() }
        await endpoint.rebuildPreview()
        func call(_ name: String, _ fields: [String: Any]) async throws -> [String: Any] {
            var args = fields; args["document_id"] = endpoint.documentID
            let data = try await endpoint.performAutomation(name, arguments: JSONSerialization.data(withJSONObject: args))
            let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try require(result["ok"] as? Bool == true, "actual endpoint operation succeeds")
            return result["result"] as! [String: Any]
        }
        let result = try await call("apply_edits", [
            "expected_revision": try EditorCommandDispatcher.revision(for: editor.project),
            "name": "Cut pause", "commands": [["action": "mutate", "mutation": [
                "operation": "cutSection", "start": 3, "end": 7, "timeBase": "source", "crossfade": 1]]]])
        try near(result["output_duration"] as! Double, 9, "receipt reports the actual shortened output")
        try require(editor.project.state.zoomKeyframes == original.zoomKeyframes && editor.project.undoHistory.count == 1,
            "cut preserves source-anchored animation and adds one Undo")
        let timing = try await call("inspect_editor", ["section": "timing"])
        try near(timing["source_duration"] as! Double, 14, "original duration remains available")
        try near(timing["output_duration"] as! Double, 9, "timing query reports output duration")
        let preview = try await call("control_preview", ["operation": "seek", "time_base": "output", "time": 2.5])
        try near(preview["outputTime"] as! Double, 2.5, "explicit output seek preserves its exact coordinate")
        let samples = preview["sourceSamples"] as! [[String: Any]]
        try require(samples.count == 2, "crossfade inspection exposes both original-source moments")
        try near(samples[0]["sourceTime"] as! Double, 2.5, "outgoing source time")
        try near(samples[1]["sourceTime"] as! Double, 7.5, "incoming source time")
        try near(samples[0]["weight"] as! Double, 0.5, "outgoing alpha")
        try near(samples[1]["weight"] as! Double, 0.5, "incoming alpha")
        playback.seek(4)
        playback.pause(); _ = playback.setPlaybackRate(2)
        try near(playback.time, 4, "paused source inspection inside a removed section survives pause and rate controls")
        try require(playback.outputSamples.isEmpty && playback.previewSnapshot.inspectionTimeBase == "source",
            "Original-source inspection must not report a different edited crossfade as its picture")
        playback.seekOutput(8.97)
        playback.play()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while playback.isPlaying {
            if ContinuousClock.now > deadline { throw CutPlaybackFailure.failed("output playback did not finish") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try near(playback.outputTime, 9, "playback ends at finished-video duration")
        try near(playback.time, 14, "final output endpoint maps to the original source endpoint")
        try require(!playback.hasMediaPlayer && playback.canvasPlayer == nil, "no media player, decoder or source file was opened")
        endpoint.timelineTimeBase = "source"
        playback.seek(4)
        endpoint.togglePlayback()
        let sourceDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !playback.isPlaying {
            if ContinuousClock.now > sourceDeadline { throw CutPlaybackFailure.failed("Source Play never started") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(playback.isInspectingSource && playback.previewSnapshot.rangeTimeBase == "source" && playback.time >= 4,
            "Play in Source must inspect original footage without silently switching to Finished")
        endpoint.togglePlayback()
        playback.seek(14)
        endpoint.togglePlayback()
        let restartDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !playback.isPlaying {
            if ContinuousClock.now > restartDeadline { throw CutPlaybackFailure.failed("Source replay never started") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(playback.isInspectingSource && playback.time < 1, "Source Play at the end restarts the original recording")
        endpoint.togglePlayback()
        endpoint.timelineTimeBase = "output"
        _ = try await call("control_document", ["operation": "undo",
            "expected_revision": try EditorCommandDispatcher.revision(for: editor.project)])
        try require(editor.project.state == original, "one ordinary Undo restores all source state")
        try near(playback.outputDuration, 14, "Undo rebuilds the shared playback timing map")
        _ = try await call("control_document", ["operation": "redo",
            "expected_revision": try EditorCommandDispatcher.revision(for: editor.project)])
        try near(playback.outputDuration, 9, "Redo restores the cut and requested transition")
        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.project.state == editor.project.state, "cuts and crossfade survive reopening metadata")
        print("Cut playback checks passed: actual Director tools, explicit output/source coordinates, two-branch alpha, output clock, source inspection, synchronized Undo/Redo and save/reopen; no media.")
    }
}
