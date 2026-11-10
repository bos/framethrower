import AppKit
import SwiftUI
@testable import FrameThrower

private final class VideoGestureEvent: NSEvent {
    var amount = 0.0, dx = 0.0, dy = 0.0
    var eventPhase: NSEvent.Phase = []
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { [] }
}
private struct MultiVideoWindowFailure: Error { let message: String }
@main @MainActor
struct MultiVideoWindowChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw MultiVideoWindowFailure(message: message) }
    }
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
    static func settle(_ view: NSView, _ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw MultiVideoWindowFailure(message: "UI did not settle") }
            view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
        }
        view.layoutSubtreeIfNeeded()
    }
    static func event(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        guard let window = view.window,
              let value = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw MultiVideoWindowFailure(message: "Local event") }
        return value
    }
    static func drag(_ view: NSView, from start: CGPoint, to end: CGPoint, cancel: Bool = false) throws {
        view.mouseDown(with: try event(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: try event(.leftMouseDragged, at: end, in: view))
        if cancel { view.cancelOperation(nil) }
        view.mouseUp(with: try event(.leftMouseUp, at: end, in: view))
    }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Multi-video window check failed: \(error)\n".utf8)); Darwin.exit(1) }
    }
    static func run() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 55) { Darwin.exit(1) }
        try require(MediaProcessing.isSuspended, "media must stay suspended")
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multi-video-window-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = RecordingProject(screenFilename: "unopened-screen.mov", duration: 12)
        let portrait = VideoSource(name: "Phone", kind: .testPattern, duration: 12, pixelWidth: 1080, pixelHeight: 1920, hasAudio: false, patternSeed: 1)
        let audio = VideoSource(name: "Footage with sound", kind: .file, relativePath: "unopened-audio-video.mov", duration: 20, pixelWidth: 1920, pixelHeight: 1080, hasAudio: true)
        let point = VideoVolumeKeyframe(time: 3, gain: 0.3)
        let later = VideoVolumeKeyframe(time: 7, gain: 0.8)
        let clip = VideoClip(sourceID: audio.id, start: 1, end: 5, sourceStart: 1, rate: 2,
            geometry: .init(rect: .init(x: 0, y: 0, width: 0.5, height: 1)), volumeKeyframes: [point, later])
        let phoneClip = VideoClip(sourceID: portrait.id, start: 0, end: 12,
            geometry: .init(rect: .init(x: 0.5, y: 0, width: 0.5, height: 1)))
        let audioLayer = VideoLayer(name: "Left", clips: [clip])
        let phoneLayer = VideoLayer(name: "Right", clips: [phoneClip])
        project.videoAssets = [portrait, audio]
        project.state.videoLayers = project.effectiveVideoLayers() + [audioLayer, phoneLayer]
        try project.validate()
        var animated = clip
        let zero = VideoGeometryKeyframe(time: 0, geometry: clip.geometry, transition: .jump)
        animated.geometryKeyframes = [zero]
        let target = VideoGeometry(rect: .init(x: 0.1, y: 0.1, width: 0.4, height: 0.6))
        let reframed = VideoClipEditing.framing(animated, target: target, at: 0)
        try require(reframed.geometry(atSourceTime: 0) == target && reframed.geometryKeyframes[0].id == zero.id,
            "zero-time animated baseline hides inspector geometry edit")
        var split = project.state; split.cuts = [.init(start: 2, end: 3)]
        let map = try RecordingTimeMap(duration: project.duration, trimStart: split.trimStart, trimEnd: split.trimEnd, cuts: split.cuts, speedKeyframes: split.speedKeyframes)
        let splitRow = TimelineVideoRow.make(project: project, state: split, map: map).first { $0.clip.id == clip.id }!
        try require(splitRow.parts.count == 2 && !splitRow.editable, "cut fragments must not retime hidden source intervals")

        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("Multi.framethrower"))
        try require(editor.save(), "metadata save")
        let playback = EditorPlayback()
        let assistant = EditorAssistantSession(transport: { _ in throw MultiVideoWindowFailure(message: "Unexpected model call") }, persistsConversation: false)
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, playback: playback, assistant: assistant))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1140, height: 1050), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close(); playback.close() }
        try await settle(host) { playback.canPlay && !all(RecordingTimelineView.self, in: host).isEmpty }
        let timeline = all(RecordingTimelineView.self, in: host).first!
        let canvas = all(EditorCanvasView.self, in: host).first!
        try require(timeline.videoRows.count == 3, "each clip must have a timeline row")
        try require(!playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer, "UI allocated media")
        playback.seekOutput(2)
        try await settle(host) { canvas.testPattern?.videoSnapshots.count == 3 }
        let frames = [window.frame, canvas.frame, timeline.frame]
        let playhead = playback.time
        guard let strip = timeline.videoClipFrames().first(where: { $0.1 == clip.id })?.2 else { throw MultiVideoWindowFailure(message: "clip strip") }
        let click = CGPoint(x: strip.midX, y: strip.midY)
        timeline.mouseDown(with: try event(.leftMouseDown, at: click, in: timeline))
        timeline.mouseUp(with: try event(.leftMouseUp, at: click, in: timeline))
        try await settle(host) { timeline.selectedVideoClipID == clip.id }
        try require(playback.time == playhead && editor.project.undoHistory.isEmpty, "selecting clip moved playhead or saved")
        host.layoutSubtreeIfNeeded()
        try require([window.frame, canvas.frame, timeline.frame] == frames, "Videos inspector resized timeline or canvas")
        let spanPixels = timeline.x(for: 2) - timeline.x(for: 1)
        try drag(timeline, from: click, to: CGPoint(x: click.x + spanPixels, y: click.y))
        try await settle(host) { editor.project.state.videoLayers?.first(where: { $0.id == audioLayer.id })?.clips.first?.start == 2 }
        let moved = editor.project.state.videoLayers!.first { $0.id == audioLayer.id }!.clips[0]
        try require(moved.end == 6 && moved.sourceStart == 1 && moved.volumeKeyframes == clip.volumeKeyframes, "movement rewrote source automation")
        try require(editor.project.undoHistory.count == 1 && editor.draftState == nil, "clip movement must be one Undo")
        try require(editor.undo(), "Undo clip movement")
        try await settle(host) { timeline.videoRows.first(where: { $0.clip.id == clip.id })?.clip.start == 1 }
        let row = timeline.videoRows.firstIndex { $0.clip.id == clip.id }!
        let originalStrip = timeline.videoClipFrames().first { $0.1 == clip.id }!.2
        let end = CGPoint(x: originalStrip.maxX, y: originalStrip.midY)
        try drag(timeline, from: end, to: CGPoint(x: end.x - spanPixels / 2, y: end.y), cancel: true)
        try await settle(host) { editor.draftState == nil }
        try require(editor.project.state.videoLayers!.first { $0.id == audioLayer.id }!.clips[0] == clip, "Escape + late mouse-up saved trim")
        // Click an empty part of the volume curve, then edit a real point.
        let volume = timeline.videoVolumePoints().first { $0.2 == point.id }!.3
        try drag(timeline, from: CGPoint(x: volume.midX, y: volume.midY), to: CGPoint(x: volume.midX + spanPixels / 4, y: volume.midY - 3))
        try await settle(host) { editor.draftState == nil && editor.project.undoHistory.count == 1 }
        let changed = editor.project.state.videoLayers!.first { $0.id == audioLayer.id }!.clips[0]
        try require(changed.volumeKeyframes.first { $0.id == point.id }!.time > 3, "volume point did not move in original source clock")
        try require(changed.volumeKeyframes.first { $0.id == later.id } == later, "another clip volume point changed")
        try require(editor.project.state.videoLayers!.first { $0.id == phoneLayer.id }!.clips[0] == phoneClip, "volume changed other footage")
        try require(timeline.playheadLine().bounds.maxY >= timeline.videoRowFrame(row).maxY, "playhead does not span clip volume lanes")
        try require(editor.undo(), "Undo volume change")
        try await settle(host) { editor.draftState == nil }
        // Inspectors keep the preview/timeline fixed while switching tools.
        let tabs = all(NSSegmentedControl.self, in: host).first { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Videos" }
        }!
        for label in ["Zoom", "Pointer", "Videos", "Layers"] {
            let index = (0..<tabs.segmentCount).first { tabs.label(forSegment: $0) == label }!
            tabs.selectedSegment = index; _ = tabs.sendAction(tabs.action!, to: tabs.target)
            try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
            try require([window.frame, canvas.frame, timeline.frame] == frames, "tab \(label) resized preview")
            if label == "Videos", let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: "/tmp/framethrower-multi-video-ui.png")) }
            }
        }
        let videoTab = (0..<tabs.segmentCount).first { tabs.label(forSegment: $0) == "Videos" }!
        tabs.selectedSegment = videoTab; _ = tabs.sendAction(tabs.action!, to: tabs.target)
        playback.seekOutput(2)
        timeline.onSelectVideo?(audioLayer.id, clip.id, nil)
        try await settle(host) { all(VideoClipOverlayView.self, in: host).first?.selection == clip.id && all(VideoClipOverlayView.self, in: host).first?.time == 2 }
        let overlay = all(VideoClipOverlayView.self, in: host).first!
        let noOp = CGPoint(x: overlay.frame(clip).midX, y: overlay.frame(clip).midY)
        try drag(overlay, from: noOp, to: noOp)
        try require(editor.draftState == nil && editor.project.undoHistory.isEmpty, "plain clip click left a draft")
        let touch = VideoGestureEvent()
        touch.amount = 0.25; touch.eventPhase = .began; overlay.magnify(with: touch)
        try await settle(host) { editor.draftState != nil }
        // Pausing with fingers down must not turn the gesture into history.
        try await Task.sleep(for: .milliseconds(400))
        try require(editor.project.undoHistory.isEmpty && editor.draftState != nil, "finger pause prematurely committed framing")
        touch.amount = 0; touch.eventPhase = .ended; overlay.magnify(with: touch)
        try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        touch.amount = 0.2; touch.eventPhase = .began; overlay.magnify(with: touch)
        touch.amount = 0; touch.eventPhase = .ended; overlay.magnify(with: touch)
        try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        touch.dx = 15; touch.eventPhase = .began; overlay.scrollWheel(with: touch)
        touch.dx = 0; touch.eventPhase = .ended; overlay.scrollWheel(with: touch)
        try await Task.sleep(for: .milliseconds(60)); host.layoutSubtreeIfNeeded()
        try require(editor.project.undoHistory.isEmpty && editor.draftState != nil, "pinch/pan at one instant split history")
        timeline.onScrubBegan?(); timeline.onScrubEnded?()
        try await settle(host) { editor.draftState == nil && editor.project.undoHistory.count == 1 }
        try require(editor.project.state.videoLayers!.first { $0.id == audioLayer.id }!.clips[0].geometryKeyframes.count == 1,
            "same instant accumulated duplicate framing points")
        try require(editor.undo(), "Undo combined framing")
        try await settle(host) { editor.draftState == nil }
        try require(editor.project.state.videoLayers!.first { $0.id == audioLayer.id }!.clips[0] == clip, "combined framing Undo lost original clip")
        print("Multi-video window checks passed (offscreen vectors; no app focus or media)")
    }
}
