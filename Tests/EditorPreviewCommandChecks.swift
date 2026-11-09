import Foundation

@main @MainActor
struct EditorPreviewCommandChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Requires the media-driver interlock")
        try codec()
        try await transportAndStepping()
        try await auditions()
        try await cutOutputTransport()
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
        let commands: [EditorPreviewCommand] = [.play, .pause, .seek(1.5), .seekOutput(1.5), .setRate(2), .stepFrames(-3),
            .stepOutputFrames(-3), .playRange(start: 1, end: 2), .playOutputRange(start: 1, end: 2)]
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

    static func cutOutputTransport() async throws {
        var project = RecordingProject(screenFilename: "nonexistent-cut-preview.mov", duration: 14,
            captureFrameDuration: 1.0 / 60)
        project.state.cuts = [RecordingCut(start: 5, end: 8, crossfade: 1)]
        let editor = ProjectEditor(project: project,
            url: FileManager.default.temporaryDirectory.appendingPathComponent("cut-preview-\(UUID()).framethrower"))
        let playback = EditorPlayback()
        await playback.rebuild(editor: editor)
        defer { playback.close() }
        let original = editor.project
        try near(playback.outputDuration, 10, "The finished timeline excludes the cut and one-second overlap")
        let originalFrame = try await playback.applyPreviewCommand(.seek(5.5))
        try require(originalFrame.time == 5.5 && originalFrame.inspectionTimeBase == "source" &&
                    originalFrame.sourceSamples?.isEmpty == true && playback.outputSamples.isEmpty,
                    "Explicit source inspection shows the omitted original frame, not a different kept frame at its output join")
        let originalStep = try await playback.applyPreviewCommand(.stepFrames(1))
        try near(originalStep.time, 5.5 + 1.0 / 60, "Source stepping can inspect a removed original frame")
        try require(originalStep.inspectionTimeBase == "source" && playback.outputSamples.isEmpty,
                    "Source stepping preserves the explicit original inspection mode")
        let crossfade = try await playback.applyPreviewCommand(.seekOutput(4.25))
        try require(crossfade.inspectionTimeBase == "output", "Output seek leaves original inspection and returns to the finished composition")
        try near(crossfade.outputTime!, 4.25, "Output seeking retains its exact position without a dominant-source round trip")
        let samples = crossfade.sourceSamples!
        try require(samples.count == 2, "A crossfade exposes both actual source instants")
        try near(samples[0].sourceTime, 4.25, "Outgoing source clock")
        try near(samples[1].sourceTime, 8.25, "Incoming source clock")
        try near(samples[0].weight, 0.75, "Outgoing alpha")
        try near(samples[1].weight, 0.25, "Incoming alpha")
        _ = try await playback.applyPreviewCommand(.seekOutput(4.6))
        _ = try await playback.applyPreviewCommand(.setRate(5))
        let audition = try await playback.applyPreviewCommand(.playOutputRange(start: 4.2, end: 4.8))
        try near(audition.outputTime!, 4.2, "Starting an output audition always uses its requested start, not an old cursor inside the range")
        try require(audition.range == .init(start: 4.2, end: 4.8) && audition.rangeTimeBase == "output" && audition.isPlaying,
                    "Output audition coordinates are explicit in the actual snapshot")
        try await wait { playback.outputTime > 4.24 }
        _ = try await playback.applyPreviewCommand(.pause)
        let paused = playback.outputTime
        _ = try await playback.applyPreviewCommand(.setRate(2))
        try require(playback.previewSnapshot.rangeTimeBase == "output" && playback.auditionRange != nil && !playback.isPlaying,
                    "Pause/rate changes preserve the output range and its coordinate system")
        _ = try await playback.applyPreviewCommand(.play)
        try require(playback.outputTime >= paused, "Output audition resumes from its paused position")
        try await wait { !playback.isPlaying }
        try near(playback.outputTime, 4.8, "A crossfade audition stops at its output endpoint")
        try require(playback.auditionRange == nil && playback.previewSnapshot.rangeTimeBase == nil,
                    "Reaching a blended endpoint clears the audition independently of the dominant source")

        _ = try await playback.applyPreviewCommand(.setRate(5))
        let source = try await playback.applyPreviewCommand(.playRange(start: 4.8, end: 8.2))
        try require(source.rangeTimeBase == "source" && source.time == 4.8 && playback.outputSamples.isEmpty,
                    "Source audition inspects the original pose rather than reversing mapped crossfade endpoints")
        try await wait { playback.time > 5.2 }
        _ = try await playback.applyPreviewCommand(.pause)
        try require(playback.time > 5 && playback.time < 8 && playback.outputSamples.isEmpty,
                    "A source audition can pause on deliberately omitted footage without showing a retained join instead")
        _ = try await playback.applyPreviewCommand(.play)
        try await wait { !playback.isPlaying }
        try near(playback.time, 8.2, "Original-source audition retains its exact requested source end")
        try require(playback.auditionRange == nil, "A source audition clears at its own clock boundary")
        let stable = playback.previewSnapshot
        for invalid in [EditorPreviewCommand.seekOutput(-1), .seekOutput(10.1), .seekOutput(.nan),
            .playOutputRange(start: 4, end: 4), .playOutputRange(start: 5, end: 4),
            .playOutputRange(start: -1, end: 4), .playOutputRange(start: 1, end: 11)] {
            try await expectFailure { _ = try await playback.applyPreviewCommand(invalid) }
            try require(playback.previewSnapshot == stable, "Invalid output coordinates cannot partially change preview state")
        }

        var hardCut = project; hardCut.state.cuts[0].crossfade = 0
        let hardEditor = ProjectEditor(project: hardCut,
            url: FileManager.default.temporaryDirectory.appendingPathComponent("hard-cut-preview-\(UUID()).framethrower"))
        let hardPlayback = EditorPlayback()
        await hardPlayback.rebuild(editor: hardEditor)
        defer { hardPlayback.close() }
        _ = try await hardPlayback.applyPreviewCommand(.seekOutput(299.0 / 60))
        let forward = try await hardPlayback.applyPreviewCommand(.stepOutputFrames(1))
        try near(forward.outputTime!, 5, "Output frame stepping advances over a cut without moving backward to its join")
        try near(forward.time, 8, "The next output frame uses the next retained source section")
        let backward = try await hardPlayback.applyPreviewCommand(.stepOutputFrames(-1))
        try near(backward.outputTime!, 299.0 / 60, "Backward output stepping crosses the join using output cadence")
        try near(backward.time, 299.0 / 60, "Backward stepping selects the outgoing retained source frame")
        try require(editor.project == original && !editor.canUndo && !hardEditor.canUndo &&
                    !FileManager.default.fileExists(atPath: editor.url.path) && !playback.hasMediaPlayer && !hardPlayback.hasMediaPlayer,
                    "All cut preview operations remain transient and construct no AV/media objects")
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
