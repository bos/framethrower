import Foundation

private enum OutputClockFailure: Error { case failed(String) }

/// Metadata-only actual transport. Sources deliberately do not exist.
@main @MainActor
struct ProjectOutputClockChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw OutputClockFailure.failed(message) }
    }
    static func near(_ value: Double, _ expected: Double, _ message: String) throws {
        try require(abs(value - expected) < 0.0000001, "\(message): \(value) != \(expected)")
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended && MediaProcessing.isCaptureSuspended, "Metadata fixture only; live capture remains off")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ft-output-clock-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = RecordingProject(screenFilename: "absent-screen.mov", cameraFilename: "absent-camera.mov", duration: 14)
        project.state.cuts = [.init(start: 3, end: 7, crossfade: 1)]
        project.state.zoomKeyframes = [.init(time: 9, scale: 2, transition: .smooth, duration: 8)]
        let source = VideoSource(name: "Phone", kind: .testPattern, duration: 40,
                                 pixelWidth: 1080, pixelHeight: 1920, hasAudio: false)
        project.videoAssets = [source]
        var clip = VideoClip(sourceID: source.id, start: 0, end: 14, sourceStart: 2, rate: 2)
        clip.volumeKeyframes = [.init(time: 20, gain: 0.5)]
        project.state.videoLayers = [VideoLayer(name: "Phone", clips: [clip])]
        let originalLayers = project.state.videoLayers
        let originalCuts = project.state.cuts
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("project.framethrower"))
        try require(editor.save(), "Save metadata")
        let playback = EditorPlayback()
        defer { playback.close() }
        await playback.rebuild(editor: editor)
        playback.seekOutput(2.25)
        playback.selectEditingBranch(nearProjectTime: 7.5)
        try near(playback.time, 7.25, "Selection chooses incoming authoring branch")
        try near(playback.outputTime, 2.25, "Selection does not move ruler")
        try require(playback.outputSamples.count == 2 && !playback.isInspectingSource, "Both rendered branches survive selection")
        let incoming = playback.videoSamples(at: playback.time)
        try require(incoming.count == 1, "Selected project branch resolves visible video occurrence")
        try near(incoming[0].sourceTime, 16.5, "Selected branch maps through clip source offset and rate")
        playback.selectEditingBranch(nearProjectTime: 2.5)
        try near(playback.time, 2.25, "Selection can choose outgoing branch")
        try near(playback.outputTime, 2.25, "Switching selection still does not seek")
        var state = editor.project.state
        state.zoomKeyframes[0].scale = 2.5
        try require(editor.updateDraft(state, at: 9), "Preview manual framing edit")
        playback.preview(state)
        try near(playback.outputTime, 2.25, "Draft preserves exact output cursor")
        try require(editor.finishDraft(name: "Framing"), "One ordinary history entry")
        await playback.rebuild(editor: editor)
        try near(playback.outputTime, 2.25, "Framing rebuild preserves exact output cursor")
        try require(editor.project.undoHistory.count == 1, "One gesture is one Undo")
        try require(editor.undo(), "Undo framing")
        await playback.rebuild(editor: editor)
        try near(playback.outputTime, 2.25, "Undo preserves exact output cursor")
        try require(editor.redo(), "Redo framing")
        await playback.rebuild(editor: editor)
        try near(playback.outputTime, 2.25, "Redo preserves exact output cursor")
        playback.selectEditingBranch(nearProjectTime: nil)
        playback.seekProjectTime(4)
        try near(playback.outputTime, 3, "Removed source mark navigates nearest retained boundary")
        try require(!playback.isInspectingSource, "Navigation never changes ruler to original source")
        playback.scrubOutput(to: 2.4)
        try near(playback.outputTime, 2.4, "Scrubbing is output time")
        try require(!playback.isInspectingSource, "Scrubbing leaves output mode intact")
        playback.endScrubbing()
        state = editor.project.state
        state.speedKeyframes = [.init(time: 0, rate: 2)]
        try require(editor.updateDraft(state, at: 0) && editor.finishDraft(name: "Speed"), "Save retimed state")
        await playback.rebuild(editor: editor)
        try near(playback.outputTime, 2.4, "Speed rebuild keeps same ruler coordinate")
        playback.seekProjectTime(8)
        let map = try playback.timingMap(for: state, duration: 14)
        try near(playback.outputTime, map.outputTime(for: 8)!, "Source edit navigation respects speed and crossfade")
        try require(editor.project.state.cuts == originalCuts && editor.project.state.videoLayers == originalLayers, "Clock navigation does not mutate cuts")
        let saved = try ProjectEditor.open(url: editor.url)
        try require(saved.project.state == editor.project.state && !playback.hasMediaPlayer,
                    "Metadata/history survive reopening; no source, decoder, or player access")
        print("Project output clock checks passed: branch selection, crossfade ruler preservation, manual draft/Undo/Redo, removed-source navigation and speed mapping; no media or capture.")
    }
}
