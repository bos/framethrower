import AppKit
import SwiftUI
@testable import FrameThrower

@main @MainActor
struct MultiVideoRecordedWindowChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }
    static func all<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, $0) }
    }
    static func settle(_ host: NSView, _ predicate: @escaping () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(25))
        while !predicate() {
            if ContinuousClock.now > end { throw Failure.failed("Recorded editor did not settle") }
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
        }
        host.layoutSubtreeIfNeeded()
    }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Recorded window check failed: \(error)\n".utf8)); Darwin.exit(1) }
    }
    static func run() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 100) { Darwin.exit(1) }
        try require(!MediaProcessing.isSuspended && MediaProcessing.isCaptureSuspended, "Recorded only, capture remains blocked")
        guard CommandLine.arguments.count == 2 else { throw Failure.failed("Generated fixture directory required") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let original = try ProjectEditor.open(url: directory.appendingPathComponent("primary.framethrower")).project
        var project = original
        let a = project.videoAssets.first { $0.name == "A" }!, b = project.videoAssets.first { $0.name == "B" }!
        let point = VideoVolumeKeyframe(time: 1, gain: 0.8)
        let left = VideoClip(sourceID: a.id, start: 0, end: 3, rate: 1,
            geometry: .init(rect: .init(x: 0, y: 0, width: 0.5, height: 1)), volumeKeyframes: [point])
        let right = VideoClip(sourceID: b.id, start: 0, end: 3,
            geometry: .init(rect: .init(x: 0.5, y: 0, width: 0.5, height: 1)))
        let first = VideoLayer(name: "Left", clips: [left]), second = VideoLayer(name: "Right", clips: [right])
        project.state.videoLayers = [first, second]; project.state.audio.isMuted = true
        project.undoHistory = []; project.redoHistory = []
        let url = directory.appendingPathComponent("Recorded-window-\(UUID()).framethrower")
        let editor = ProjectEditor(project: project, url: url)
        try require(editor.save(), "Save isolated recorded UI fixture")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("recovery")) }
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let playback = EditorPlayback(); playback.player.isMuted = true
        let assistant = EditorAssistantSession(transport: { _ in throw Failure.failed("No model calls") }, persistsConversation: false)
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, playback: playback, assistant: assistant))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1140, height: 950), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close(); playback.close() }
        try await settle(host) { playback.canPlay && !playback.isLoading && !all(EditorCanvasView.self, host).isEmpty }
        let canvas = all(EditorCanvasView.self, host).first!, timeline = all(RecordingTimelineView.self, host).first!
        try require(canvas.hasMediaPlayerLayer && playback.hasMediaPlayer, "Recorded editor must use actual player")
        let frames = [window.frame, canvas.frame, timeline.frame]
        playback.seekOutput(0.75)
        try await settle(host) { playback.outputTime >= 0.74 && !playback.isLoading }
        let before = playback.outputTime
        _ = playback.setPlaybackRate(2); playback.play()
        try await settle(host) { playback.outputTime > before + 0.05 }; playback.pause()
        try require(playback.outputTime > before, "Real preview Play did not advance")
        host.layoutSubtreeIfNeeded()
        try require([window.frame, canvas.frame, timeline.frame] == frames, "Actual Play resized editor")
        playback.beginScrubbing(); playback.scrubOutput(to: 1.5); playback.endScrubbing()
        try await settle(host) { !playback.isScrubbing }
        try require([window.frame, canvas.frame, timeline.frame] == frames, "Actual video scrub resized editor")
        timeline.onSelectVideo?(first.id, left.id, point.id)
        try await settle(host) { timeline.selectedVideoVolumeID == point.id }
        guard let dot = timeline.videoVolumePoints().first(where: { $0.2 == point.id })?.3 else { throw Failure.failed("Real clip volume point") }
        func event(_ kind: NSEvent.EventType, _ position: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: timeline.convert(position, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let start = CGPoint(x: dot.midX, y: dot.midY), end = CGPoint(x: dot.midX + 10, y: dot.midY + 4)
        timeline.mouseDown(with: event(.leftMouseDown, start)); timeline.mouseDragged(with: event(.leftMouseDragged, end)); timeline.mouseUp(with: event(.leftMouseUp, end))
        try await settle(host) { editor.project.undoHistory.count == 1 && !playback.isLoading && editor.draftState == nil }
        try require(editor.project.state.videoLayers![1].clips[0] == right, "Volume edit changed another real clip")
        try require([window.frame, canvas.frame, timeline.frame] == frames, "Volume edit resized actual player/editor")
        timeline.onTrim?(0.2, 2.8)
        try await settle(host) { !playback.isLoading && playback.outputDuration < 3 }
        try require([window.frame, canvas.frame, timeline.frame] == frames, "Recorded trim resized editor")
        try require(editor.undo() && editor.undo(), "Real clip/trim edits must support Undo")
        print("Actual recorded editor window checks passed: muted2× Play, decoded scrubbing, independent clip-volume drag, trim, fixed layout and Undo; no capture or focus")
    }
}
