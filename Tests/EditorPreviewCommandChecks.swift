import Foundation

@main @MainActor
struct EditorPreviewCommandChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Requires the media-driver interlock")
        try codec()
        try await transportAndStepping()
        try await auditions()
        try await cancellationAndLifecycle()
        print("Editor preview command checks passed (typed snapshots, idempotent transport, frame stepping, rates, source-range audition outside trim, pause/resume/end/seek/rebuild/close lifecycle and untouched projects/history; no AV objects/media).")
    }

    static func fixture() async -> (ProjectEditor, EditorPlayback) {
        var project = RecordingProject(screenFilename: "nonexistent-preview-source.mov", duration: 12,
            captureFrameDuration: 1.0 / 60)
        project.state.trimStart = 2
        project.state.trimEnd = 8
        let editor = ProjectEditor(project: project,
            url: FileManager.default.temporaryDirectory.appendingPathComponent("preview-command-\(UUID()).framethrower"))
        let playback = EditorPlayback()
        await playback.rebuild(editor: editor)
        return (editor, playback)
    }

    static func codec() throws {
        let commands: [EditorPreviewCommand] = [.play, .pause, .seek(1.5), .setRate(2), .stepFrames(-3), .playRange(start: 1, end: 2)]
        for command in commands {
            try require(try JSONDecoder().decode(EditorPreviewCommand.self, from: JSONEncoder().encode(command)) == command,
                        "Typed preview requests must retain their exact action and numeric values")
        }
    }

    static func transportAndStepping() async throws {
        let (editor, playback) = await fixture()
        defer { playback.close() }
        let original = editor.project
        try require(playback.previewSourceBounds == 0...12 && playback.keptPreviewRange == .init(start: 2, end: 8) &&
                    playback.previewSnapshot.kind == .testPattern && !playback.hasMediaPlayer && playback.canvasPlayer == nil,
                    "Suspended navigation must expose source/trim bounds without constructing any AV object")
        let sought = try await playback.applyPreviewCommand(.seek(1.5))
        try near(sought.time, 1.5, "Explicit seek can inspect original source outside trim")
        try require(!sought.isPlaying && sought.range == nil, "Seek produces a paused source inspection")
        let stepped = try await playback.applyPreviewCommand(.stepFrames(3))
        try near(stepped.time, 1.55, "Step advances exactly three original60fps frames")
        try near(stepped.frameTime, 1.55, "Reported frame timestamp follows the recording cadence")
        _ = try await playback.applyPreviewCommand(.stepFrames(-2))
        try near(playback.time, 91.0 / 60, "Backward stepping uses frame count rather than preview speed")
        _ = try await playback.applyPreviewCommand(.seek(0))
        for frame in 1...120 {
            let next = try await playback.applyPreviewCommand(.stepFrames(1))
            try near(next.time, Double(frame) / 60, "Repeated stepping must not stick at floating-point frame boundaries")
            try near(next.frameTime, Double(frame) / 60, "Each reported source frame must match the actual step count")
        }
        _ = try await playback.applyPreviewCommand(.seek(0))
        _ = try await playback.applyPreviewCommand(.stepFrames(Int.min))
        try near(playback.time, 0, "A large negative frame step clamps at the original source start")
        _ = try await playback.applyPreviewCommand(.seek(12))
        _ = try await playback.applyPreviewCommand(.stepFrames(Int.max))
        try near(playback.time, 719.0 / 60, "A large positive frame step stops at the last original frame, not its exclusive end")
        var transient = original.state
        transient.zoomKeyframes = [.init(time: 3, scale: 2)]
        playback.preview(transient)
        let pausedTime = playback.time
        for rate in EditorPlayback.supportedPlaybackRates {
            let snapshot = try await playback.applyPreviewCommand(.setRate(rate))
            try require(snapshot.rate == rate && !snapshot.isPlaying && playback.isPreviewing,
                        "A paused rate command must preserve the transient framing and pause state")
            try near(snapshot.time, pausedTime, "Changing preview speed cannot move a paused playhead")
        }
        let unchanged = playback.previewSnapshot
        for command in [EditorPreviewCommand.seek(.nan), .seek(-1), .seek(13), .setRate(3), .setRate(.infinity)] {
            try await expectFailure { _ = try await playback.applyPreviewCommand(command) }
            try require(playback.previewSnapshot == unchanged, "Invalid preview requests cannot partially change the transport")
        }
        _ = try await playback.applyPreviewCommand(.setRate(1))
        _ = try await playback.applyPreviewCommand(.play)
        try require(playback.isPlaying && playback.time == 2, "Normal play outside the retained interval starts at the trim beginning")
        try await wait { playback.time > 2.04 }
        let before = playback.time
        _ = try await playback.applyPreviewCommand(.play)
        try require(playback.isPlaying && playback.time >= before, "Repeated Play must not toggle or restart a running preview")
        let paused = try await playback.applyPreviewCommand(.pause)
        _ = try await playback.applyPreviewCommand(.pause)
        try await Task.sleep(for: .milliseconds(50))
        try require(playback.previewSnapshot == paused, "Repeated Pause and obsolete timer callbacks cannot move the source position")
        try require(editor.project == original && !editor.canUndo && !editor.canRedo &&
                    !FileManager.default.fileExists(atPath: editor.url.path) && !playback.hasMediaPlayer,
                    "Transport preferences/inspection cannot write a project, create history or open media")
        let roundTrip = try JSONDecoder().decode(EditorPreviewSnapshot.self, from: JSONEncoder().encode(paused))
        try require(roundTrip == paused, "Actual preview state must be serializable as the tool result")
    }

    static func auditions() async throws {
        let (editor, playback) = await fixture()
        defer { playback.close() }
        let original = editor.project
        _ = try await playback.applyPreviewCommand(.playRange(start: 1, end: 1.8))
        try require(playback.isPlaying && playback.auditionRange == .init(start: 1, end: 1.8) && playback.time == 1,
                    "Explicit audition can start outside retained trim without changing trim")
        try await wait { playback.time > 1.04 }
        _ = try await playback.applyPreviewCommand(.pause)
        let pausedAt = playback.time
        _ = try await playback.applyPreviewCommand(.setRate(5))
        try require(playback.auditionRange == .init(start: 1, end: 1.8) && !playback.isPlaying,
                    "Pause and rate changes retain a paused audition range")
        _ = try await playback.applyPreviewCommand(.play)
        try require(playback.time >= pausedAt && playback.time > 1, "Resuming an audition continues rather than restarting its beginning")
        try await wait { !playback.isPlaying }
        try near(playback.time, 1.8, "Audition stops at its requested source end")
        try require(playback.auditionRange == nil, "Reaching the end clears the transient audition")
        _ = try await playback.applyPreviewCommand(.play)
        try require(playback.time == 2, "Normal Play after an out-of-trim audition returns to ordinary trim policy")
        _ = try await playback.applyPreviewCommand(.playRange(start: 3, end: 3.1))
        try await wait { !playback.isPlaying }
        _ = try await playback.applyPreviewCommand(.play)
        try require(playback.time == 3.1, "Normal Play after an in-trim audition continues from its end")
        _ = try await playback.applyPreviewCommand(.playRange(start: 0.5, end: 7))
        _ = try await playback.applyPreviewCommand(.seek(2.25))
        try require(playback.auditionRange == nil && !playback.isPlaying && !playback.isScrubbing,
                    "Explicit source seek cancels range playback")
        try await Task.sleep(for: .milliseconds(50))
        try near(playback.time, 2.25, "An obsolete audition timer must not resume after an explicit seek")
        playback.beginScrubbing()
        _ = try await playback.applyPreviewCommand(.seek(2.5))
        try require(!playback.isScrubbing, "Explicit source navigation finishes any older scrub interaction")
        playback.beginScrubbing()
        playback.scrub(to: 9)
        playback.endScrubbing()
        try near(playback.time, 8, "Ordinary scrubbing still respects trim after range inspection")
        let stable = playback.previewSnapshot
        for command in [EditorPreviewCommand.playRange(start: 4, end: 4), .playRange(start: 5, end: 4),
                        .playRange(start: -1, end: 3), .playRange(start: 3, end: 13), .playRange(start: 0, end: .nan)] {
            try await expectFailure { _ = try await playback.applyPreviewCommand(command) }
            try require(playback.previewSnapshot == stable, "Invalid ranges cannot alter source position or playback policy")
        }
        try require(editor.project == original && !editor.canUndo && !playback.hasMediaPlayer,
                    "Audition must not become a trim edit or an Undo entry")
    }

    static func cancellationAndLifecycle() async throws {
        let (editor, playback) = await fixture()
        let original = editor.project
        _ = try await playback.applyPreviewCommand(.seek(4))
        let stable = playback.previewSnapshot
        let cancelled = Task { @MainActor in try await playback.applyPreviewCommand(.seek(7)) }
        cancelled.cancel()
        try await expectFailure { _ = try await cancelled.value }
        try require(playback.previewSnapshot == stable, "A cancelled command must not navigate before checking cancellation")
        _ = try await playback.applyPreviewCommand(.playRange(start: 1, end: 2))
        await playback.rebuild(editor: editor)
        let rebuilt = playback.previewSnapshot
        try await Task.sleep(for: .milliseconds(40))
        try require(rebuilt.range == nil && !rebuilt.isPlaying && playback.previewSnapshot == rebuilt,
                    "Rebuild cancels temporary range/timer state without changing the source project")
        _ = try await playback.applyPreviewCommand(.playRange(start: 1, end: 2))
        playback.close()
        let closed = playback.previewSnapshot
        try await Task.sleep(for: .milliseconds(40))
        try await expectFailure { _ = try await playback.applyPreviewCommand(.play) }
        try require(playback.previewSnapshot == closed && !closed.canPlay && closed.range == nil &&
                    !playback.hasMediaPlayer && editor.project == original,
                    "Closing invalidates audition callbacks and rejects further commands without touching source/history")
    }

    static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try require(condition(), "Preview transport did not reach the expected source state")
    }
    static func expectFailure(_ action: () async throws -> Void) async throws {
        do { try await action() } catch { return }
        throw Failure.failed("Expected the preview action to be rejected")
    }
    static func near(_ lhs: Double, _ rhs: Double, _ message: String) throws {
        try require(abs(lhs - rhs) < 0.000001, "\(message): \(lhs) != \(rhs)")
    }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
}
