import Foundation

private enum SpeedPlaybackFailure: Error { case failed(String) }
@main @MainActor
struct EditorSpeedPlaybackChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SpeedPlaybackFailure.failed(message) }
    }
    static func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try require(abs(actual - expected) < 0.000001, "\(message): \(actual) != \(expected)")
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Video interlock must remain enabled")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-speed-playback-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = RecordingProject(screenFilename: "never-open-screen.mov", cameraFilename: "never-open-camera.mov", duration: 10)
        project.state.zoomKeyframes = [.init(time: 6, scale: 2, transition: .smooth, duration: 2)]
        project.state.pipKeyframes.append(.init(time: 7, placement: .init(x: 0.1, y: 0.1, scale: 0.4), transition: .smooth, duration: 3))
        let original = project.state
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("speed.framethrower"))
        try require(editor.save(), "Save metadata fixture")
        let playback = EditorPlayback()
        defer { playback.close() }
        await playback.rebuild(editor: editor)
        playback.seekOutput(2)
        var speed = original
        speed.speedKeyframes = [.init(time: 0, rate: 2, transition: .jump)]
        speed.preservesAudioPitch = false
        try require(editor.commit(speed, name: "Double speed"), "Commit final-recording speed")
        await playback.rebuild(editor: editor)
        try near(playback.outputDuration, 5, "Speed changes final duration without any cuts")
        try near(playback.time, 2, "Rebuild retains original source position")
        try near(playback.outputTime, 1, "Rebuild updates its output position")
        playback.seekOutput(3)
        try near(playback.time, 6, "Output seeks retime original-source animation")
        try require(playback.outputSamples.count == 1, "Speed-only playback has one source branch")
        try near(editor.project.state.zoom(at: playback.time).scale, 2, "Zoom arrival follows source clock")
        try require(editor.project.state.pipKeyframes == original.pipKeyframes && editor.project.state.zoomKeyframes == original.zoomKeyframes,
            "Speed does not rewrite visual edits")
        playback.seek(7)
        try require(playback.isInspectingSource && playback.outputSamples.isEmpty, "Original-source inspection remains available")
        try near(playback.outputTime, 3.5, "Original inspection also reports finished position")
        _ = playback.setPlaybackRate(5)
        try near(playback.outputDuration, 5, "Review rate never changes exported duration")
        try require(editor.project.state == speed && editor.project.undoHistory.count == 1, "Review controls do not create edits")
        playback.seekOutput(4.95)
        playback.play()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while playback.isPlaying {
            if ContinuousClock.now > deadline { throw SpeedPlaybackFailure.failed("Speed-only output playback did not finish") }
            try await Task.sleep(for: .milliseconds(5))
        }
        try near(playback.outputTime, 5, "Final clock ends at edited duration")
        try near(playback.time, 10, "Output ending maps to original ending")
        try require(editor.undo(), "Undo exported speed")
        await playback.rebuild(editor: editor)
        try near(playback.outputDuration, 10, "Undo restores original clock")
        try require(editor.redo(), "Redo exported speed")
        await playback.rebuild(editor: editor)
        try near(playback.outputDuration, 5, "Redo restores final clock")
        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.project.state == speed, "Speed and pitch preference survive reopen")
        try require(!playback.hasMediaPlayer && playback.canvasPlayer == nil, "No player, media file, decoder or compositor was opened")
        print("Speed playback checks passed: final-duration retiming, synchronized visual source clocks, review-rate independence, source inspection, Undo/Redo and reopen; no media.")
    }
}
