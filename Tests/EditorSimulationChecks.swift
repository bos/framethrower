import AppKit

private enum SimulationFailure: Error { case failed(String) }

/// Actual suspended transport and vector canvas. The compiled renderer types
/// are never called: no AV player/layer/item/asset, image or media file exists.
@main @MainActor
struct EditorSimulationChecks {
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Requires the media-driver interlock")
        try await transport()
        try await playbackRates()
        try await cursorMetadata()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try vectorCanvas()
        print("Editor simulation checks passed (actual suspended clock lifecycle, preview rates, cursor JSON cache/clicks, trim/seek/end/restart, preview preservation, vector screen/PIP interpolation and stable geometry; no AV objects or media).")
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SimulationFailure.failed(message) }
    }
    static func near(_ a: Double, _ b: Double, _ message: String) throws {
        try require(abs(a - b) < 0.000001, "\(message): \(a) != \(b)")
    }
    static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SimulationFailure.failed("Timed out waiting for the source-free transport")
    }
    static func transport() async throws {
        var project = RecordingProject(screenFilename: "no-simulation-source.mov", cameraFilename: "no-camera-source.mov", duration: 0.4,
            captureFrameDuration: 1.0 / 60)
        project.state.trimStart = 0.05; project.state.trimEnd = 0.3
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-simulation-file-\(UUID()).framethrower")
        let editor = ProjectEditor(project: project, url: url)
        let playback = EditorPlayback()
        try require(!playback.hasMediaPlayer && playback.canvasPlayer == nil, "Constructing the suspended transport cannot create an AVPlayer")
        await playback.rebuild(editor: editor)
        try require(playback.canPlay && !playback.isLoading && playback.errorMessage == nil && !playback.hasMediaPlayer,
                    "Suspended metadata must become playable without opening the nonexistent sources")
        try near(playback.frameDuration, 1.0 / 60, "Simulation retains the recording's edit cadence")
        playback.seek(-1)
        try near(playback.time, 0, "Source inspection clamps to the full recording")
        playback.togglePlayback()
        try await wait { playback.time > 0.08 }
        playback.pause()
        let paused = playback.time
        try await Task.sleep(for: .milliseconds(60))
        try near(playback.time, paused, "A canceled timer cannot update the paused playhead")
        playback.seek(0.29)
        playback.togglePlayback()
        try await wait { !playback.isPlaying }
        try near(playback.time, 0.3, "Playback stops at the kept end")
        playback.togglePlayback()
        try require(playback.isPlaying && playback.time >= 0.05 && playback.time < 0.1,
                    "Playing an ended preview restarts from the kept beginning")
        playback.beginScrubbing()
        playback.scrub(to: 9)
        try near(playback.time, 0.3, "User scrubbing stays inside the trim")
        playback.endScrubbing()
        try require(!playback.isPlaying && !playback.isScrubbing, "A scrub ends with a stable paused frame")
        playback.seek(0.1)
        var comparison = project.state
        comparison.presentation = CanvasPresentation(aspect: .square, padding: 0.1)
        playback.preview(comparison)
        playback.togglePlayback()
        try await wait { playback.time > 0.13 }
        try require(playback.isPreviewing && playback.isPlaying,
                    "Playing a source-free conflict preview must preserve its transient full-frame state")
        playback.pause()
        playback.cancelPreview()
        try require(!playback.isPreviewing && playback.screenSize == CGSize(width: 1920, height: 1080),
                    "Dismissing the transient preview restores committed canvas geometry")
        playback.togglePlayback()
        playback.close()
        let closed = playback.time
        try await Task.sleep(for: .milliseconds(60))
        playback.seek(0.2); playback.togglePlayback()
        try require(!playback.canPlay && !playback.isPlaying && !playback.hasMediaPlayer && playback.canvasPlayer == nil,
                    "Closed simulation cannot restart or instantiate a media player")
        try near(playback.time, closed, "Canceled clock callbacks and new actions cannot alter a closed preview")
        try require(!FileManager.default.fileExists(atPath: url.path) && editor.project == project && !editor.canUndo,
                    "Source-free playback does not save metadata, mutate history or produce any media")
    }
    static func vectorCanvas() throws {
        let window = NSWindow(contentRect: CGRect(x: -12000, y: -12000, width: 640, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvasView(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
        window.contentView = canvas
        defer { window.close() }
        var state = RecordingProject(screenFilename: "unused.mov", duration: 2).state
        state.zoomKeyframes = [ZoomKeyframe(time: 1, scale: 2, x: 0.65, y: 0.55, transition: .smooth, duration: 1)]
        state.pipKeyframes.append(PIPKeyframe(time: 1, placement: PIPPlacement(x: 0.15, y: 0.25, scale: 0.4), transition: .smooth, duration: 1))
        let fixedFrame = canvas.frame
        var sourceWindows: [CGRect] = [], cameraFrames: [CGRect] = []
        for time in [0.0, 0.5, 1.0] {
            let placement = state.placement(at: time), zoom = state.zoom(at: time)
            canvas.configure(player: nil, image: nil, sourceSize: EditorTestPattern.sourceSize,
                cameraAspect: 16.0 / 9.0, placement: placement, cameraEnabled: false, showsCameraPattern: true, zoom: zoom)
            canvas.layoutSubtreeIfNeeded()
            guard let pattern = canvas.testPattern else { throw SimulationFailure.failed("Vector pattern missing") }
            sourceWindows.append(pattern.screenViewport); cameraFrames.append(pattern.cameraFrame)
            try require(pattern.screenViewport == zoom.viewport(in: EditorTestPattern.sourceSize) &&
                        pattern.screenFrame == canvas.contentRect && canvas.frame == fixedFrame,
                        "The vector chart must use actual interpolated source framing without resizing its containing view")
            let expectedCamera = placement.frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9.0)
                .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
            try require(pattern.cameraFrame == expectedCamera && !canvas.hasMediaPlayerLayer && canvas.stillLayer.contents == nil,
                        "The visible PIP pattern follows real placement geometry while video layers stay absent")
            let layers = allLayers(pattern.layer)
            try require(layers.count > 100 && layers.allSatisfy { $0.contents == nil },
                        "Both visible charts must consist of native vector/text layers rather than raster or video contents")
        }
        try require(sourceWindows[0] != sourceWindows[1] && sourceWindows[1] != sourceWindows[2] &&
                    cameraFrames[0] != cameraFrames[1] && cameraFrames[1] != cameraFrames[2],
                    "Intermediate playback samples must visibly change both main framing and PIP position/size")
        canvas.configure(player: nil, image: nil, sourceSize: EditorTestPattern.sourceSize,
            cameraAspect: 16.0 / 9.0, placement: PIPPlacement(), cameraEnabled: false, showsCameraPattern: true,
            presentation: CanvasPresentation(aspect: .square, padding: 0.1))
        canvas.layoutSubtreeIfNeeded()
        try require(canvas.frame == fixedFrame && canvas.testPattern?.screenFrame == canvas.contentRect && !canvas.hasMediaPlayerLayer,
                    "Changing the output aspect updates internal presentation geometry without reallocating the view")
    }
    static func playbackRates() async throws {
        let project = RecordingProject(screenFilename: "no-rate-source.mov", duration: 20,
            state: EditState(trimStart: 2, trimEnd: 15, pipKeyframes: []))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-rate-file-\(UUID()).framethrower")
        let editor = ProjectEditor(project: project, url: url)
        let playback = EditorPlayback()
        try require(playback.playbackRate == 1 && playback.setPlaybackRate(2), "Preview defaults to 1× and accepts a rate before metadata loads")
        await playback.rebuild(editor: editor)
        try require(playback.playbackRate == 2 && !playback.isPlaying && !playback.hasMediaPlayer,
                    "Rebuild retains the speed without starting or creating a media player")
        playback.seek(3)
        playback.togglePlayback()
        try await wait { playback.time > 3.04 }
        let beforeChange = playback.time
        try require(playback.setPlaybackRate(5) && playback.isPlaying, "An active supported rate change keeps transport playing")
        try require(playback.time >= beforeChange && playback.time - beforeChange < 0.08,
                    "Changing rate rebases the current clock rather than scaling all elapsed playback")
        try await wait { playback.time > beforeChange + 0.3 }
        playback.pause()
        let pausedTime = playback.time
        var preview = project.state
        preview.zoomKeyframes = [ZoomKeyframe(time: 4, scale: 2)]
        playback.preview(preview)
        for rate in EditorPlayback.supportedPlaybackRates {
            try require(playback.setPlaybackRate(rate) && playback.playbackRate == rate && !playback.isPlaying,
                        "Each supported paused rate change leaves transport paused")
            try near(playback.time, pausedTime, "Paused speed changes preserve the source playhead")
            try require(playback.isPreviewing, "Speed changes preserve transient editing state")
        }
        for rate in [0.0, -1, 1.5, Double.nan, .infinity, -.infinity] {
            try require(!playback.setPlaybackRate(rate) && playback.playbackRate == 5 && !playback.isPlaying,
                        "Invalid preview speed cannot change the last supported setting")
        }
        await playback.rebuild(editor: editor)
        try require(playback.playbackRate == 5, "Metadata rebuild retains preview speed independently of project data")
        playback.seek(14.99)
        playback.togglePlayback()
        try await wait { !playback.isPlaying }
        try near(playback.time, 15, "Fast playback still stops at the exact trim end")
        playback.togglePlayback()
        try require(playback.playbackRate == 5 && playback.isPlaying && playback.time >= 2 && playback.time < 2.1,
                    "Replaying an ended preview retains speed and restarts at the kept beginning")
        playback.close()
        try require(!playback.setPlaybackRate(0.5) && !playback.hasMediaPlayer && playback.canvasPlayer == nil,
                    "Closed or suspended rate actions never allocate AV objects")
        try require(editor.project == project && !editor.canUndo && !FileManager.default.fileExists(atPath: url.path),
                    "Preview rates never write project bytes, edit history, or exported media")
    }
    static func cursorMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = CursorRecording(duration: 4, logicalWidth: 1920, logicalHeight: 1080,
            samples: [CursorSample(time: 0, x: 0.2, y: 0.3), CursorSample(time: 4, x: 0.7, y: 0.8)],
            clicks: [CursorClick(time: 0.5, x: 0.3, y: 0.4, button: 0), CursorClick(time: 3.5, x: 0.6, y: 0.7, button: 1)])
        let cursorURL = directory.appendingPathComponent("pointer.json")
        let bytes = try JSONEncoder().encode(source)
        try bytes.write(to: cursorURL)
        let project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov",
            cursorFilename: cursorURL.lastPathComponent, duration: 4)
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("metadata.framethrower"))
        let playback = EditorPlayback()
        await playback.rebuild(editor: editor)
        try require(playback.cursorRecording == source && playback.cursorRecording?.clicks.map(\.time) == [0.5, 3.5],
                    "Suspended playback exposes validated pointer JSON and real click times without a renderer")
        try require(!playback.hasMediaPlayer && playback.canvasPlayer == nil && playback.canPlay,
                    "Loading pointer metadata cannot create media objects or disable the source-free transport")
        let afterRead = try Data(contentsOf: cursorURL)
        try require(afterRead == bytes, "The pointer metadata cache is read-only")
        try Data("corrupt JSON".utf8).write(to: cursorURL)
        try require(playback.cursorRecording == source, "The getter uses its cache instead of rereading on every UI update")
        await playback.rebuild(editor: editor)
        try require(playback.cursorRecording == nil && playback.errorMessage == nil,
                    "A corrupt JSON rebuild clears stale pointer data without reporting a video failure")
        try FileManager.default.removeItem(at: cursorURL)
        await playback.rebuild(editor: editor)
        try require(playback.cursorRecording == nil, "Missing cursor JSON yields an empty pointer lane")
        try bytes.write(to: cursorURL)
        await playback.rebuild(editor: editor)
        try require(playback.cursorRecording == source, "A subsequent valid JSON rebuild refreshes the cache")
        var noPointer = project
        noPointer.cursorFilename = nil
        let noPointerEditor = ProjectEditor(project: noPointer, url: editor.url)
        await playback.rebuild(editor: noPointerEditor)
        try require(playback.cursorRecording == nil, "A project without cursorFilename cannot reuse another project's cached ticks")
        await playback.rebuild(editor: editor)
        playback.close()
        try require(playback.cursorRecording == nil && !playback.hasMediaPlayer && editor.project == project && !editor.canUndo,
                    "Closing clears cursor metadata without saving, editing history, or opening source movies")
        try require(!FileManager.default.fileExists(atPath: editor.url.path), "The metadata-only fixture never writes a recording project or media")
    }
    static func allLayers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(allLayers) }
}
