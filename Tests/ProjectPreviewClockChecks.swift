import Foundation
@testable import FrameThrower

/// Actual Host parsing and transport, with nonexistent media and vector mode.
@main @MainActor
struct ProjectPreviewClockChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.failed(message) }
    }
    static func near(_ value: Double, _ expected: Double, _ message: String) throws {
        try require(abs(value - expected) < 0.000001, "\(message): \(value) != \(expected)")
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended && MediaProcessing.isCaptureSuspended, "Vector metadata only; capture stays off")
        let tool = EditorAutomationAPI.tools.first { $0["name"] as? String == "control_preview" }!
        let schema = tool["inputSchema"] as! [String: Any]
        let fields = schema["properties"] as! [String: Any]
        try require((fields["time_base"] as! [String: Any])["default"] as? String == "output",
                    "Published schema advertises the executable default")
        for mode in ["identity", "trim", "cut", "speed", "layers"] { try await scenario(mode) }
        print("Project preview clock checks passed: actual Host defaults to output for seek/step/range/animation across identity, trim, cut/crossfade, speed and video layers; explicit source audition and component-inspection clocks preserved; no media.")
    }
    static func scenario(_ mode: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ft-preview-clock-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = RecordingProject(screenFilename: "absent-screen.mov", duration: 12, captureFrameDuration: 1.0 / 30)
        project.state.zoomKeyframes = [.init(time: 7, scale: 2, transition: .smooth, duration: 4)]
        if mode != "identity" && mode != "layers" { project.state.trimStart = 2 }
        if mode == "cut" { project.state.cuts = [.init(start: 4, end: 6, crossfade: 0.5)] }
        if mode == "speed" { project.state.speedKeyframes = [.init(time: 0, rate: 2)] }
        if mode == "layers" { project.state.videoLayers = project.effectiveVideoLayers() }
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("preview.framethrower"))
        try require(editor.save(), "Save metadata")
        let playback = EditorPlayback(), host = EditorAutomationHost(editor: editor, playback: playback)
        defer { playback.close() }
        await host.rebuildPreview()
        let original = editor.project
        let map = playback.timingMap!
        func call(_ values: [String: Any], tool: String = "control_preview") async throws -> [String: Any] {
            var args = values; args["document_id"] = host.documentID
            let data = try await host.performAutomation(tool, arguments: JSONSerialization.data(withJSONObject: args))
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try require(object["ok"] as? Bool == true, "Actual scoped tool call succeeds")
            return object["result"] as! [String: Any]
        }
        _ = try await call(["operation": "seek", "time": 1.75])
        try near(playback.outputTime, 1.75, "\(mode): omitted base seeks ruler")
        try require(!playback.isInspectingSource, "\(mode): default seek never activates source inspection")
        if mode == "cut" { try require(playback.outputSamples.count == 2, "Default seek preserves both crossfade branches") }
        if mode == "speed" { try near(playback.time, 5.5, "Output seek maps through trim and rate") }
        _ = try await call(["operation": "step_frames", "frames": 2])
        try near(playback.outputTime, (1.75 * 30).rounded() / 30 + 2.0 / 30,
                 "\(mode): default step advances output frames")
        _ = try await call(["operation": "play_range", "start": 0.5, "end": 1.25])
        try require(playback.previewSnapshot.rangeTimeBase == "output" && playback.auditionRange == .init(start: 0.5, end: 1.25),
                    "\(mode): default range auditions output clock")
        _ = try await call(["operation": "pause"])
        _ = try await call(["operation": "play_animation", "animation_id": "screen:\(project.state.zoomKeyframes[0].id.uuidString)"])
        let ranges = map.clips.compactMap { clip -> ClosedRange<Double>? in
            let start = max(3, clip.sourceStart), end = min(7, clip.sourceEnd)
            return start < end ? clip.outputTime(for: start)...clip.outputTime(for: end) : nil
        }
        try require(playback.previewSnapshot.rangeTimeBase == "output", "\(mode): animation audition always uses finished composition")
        try near(playback.auditionRange!.start, ranges.map(\.lowerBound).min()!, "\(mode): animation starts at retained output interval")
        try near(playback.auditionRange!.end, ranges.map(\.upperBound).max()!, "\(mode): animation ends at retained output interval")
        _ = try await call(["operation": "pause"])
        if map.outputDuration + 0.25 <= project.duration {
            let before = playback.previewSnapshot
            var rejected = false
            do { _ = try await call(["operation": "seek", "time": map.outputDuration + 0.25]) }
            catch { rejected = true }
            try require(rejected && playback.previewSnapshot == before,
                        "\(mode): default bounds are finished duration, with no failed-seek side effects")
        }
        _ = try await call(["operation": "seek", "time_base": "source", "time": 1])
        try require(playback.isInspectingSource && playback.time == 1, "\(mode): explicit advanced source contract retained")
        let component = try await call(["section": "state", "component": "screen", "time": 1], tool: "inspect_editor")
        try require(component["source_time"] as? Double == 1, "Component query still defaults to source; unrelated contract unchanged")
        try require(editor.project == original && !playback.hasMediaPlayer, "Transient review preserves edits/history and opens no media")
    }
}
