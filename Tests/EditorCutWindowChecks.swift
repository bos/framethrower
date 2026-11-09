import AppKit
import SwiftUI
@testable import FrameThrower

private enum CutWindowFailure: Error { case failed(String), unexpectedModelCall }

/// Links the already-built Debug module: exercise the actual SwiftUI window
/// without recompiling the app, opening footage, or ordering a window onscreen.
@main @MainActor
struct EditorCutWindowChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw CutWindowFailure.failed(message) }
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func settle(_ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            if ContinuousClock.now > deadline { throw CutWindowFailure.failed("SwiftUI window did not settle") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "video interlock must remain enabled")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-cut-window-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = RecordingProject(screenFilename: "never-open-screen.mov", cameraFilename: "never-open-camera.mov", duration: 14)
        project.state.cuts = [.init(start: 4, end: 6, crossfade: 1)]
        project.state.zoomKeyframes = [.init(time: 3, scale: 2, x: 0.35, y: 0.4, transition: .smooth, duration: 2),
                                     .init(time: 8, scale: 1, transition: .smooth, duration: 3)]
        project.state.pipKeyframes.append(.init(time: 7, placement: .init(x: 0.1, y: 0.1, scale: 0.4), transition: .smooth, duration: 3))
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("window.framethrower"))
        try require(editor.save(), "save fixture metadata")
        let playback = EditorPlayback()
        let assistant = EditorAssistantSession(transport: { _ in throw CutWindowFailure.unexpectedModelCall }, persistsConversation: false)
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, playback: playback, assistant: assistant)
            .preferredColorScheme(.dark))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1100, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close(); playback.close() }
        host.layoutSubtreeIfNeeded()
        try await settle { playback.canPlay && descendants(host).contains { $0 is RecordingTimelineView } }
        playback.seekOutput(3.5)
        try await settle { descendants(host).compactMap { $0 as? EditorCanvasView }.first?.incomingTestPattern?.layer.isHidden == false }
        let timeline = descendants(host).compactMap { $0 as? RecordingTimelineView }.first!
        let canvas = descendants(host).compactMap { $0 as? EditorCanvasView }.first!
        host.layoutSubtreeIfNeeded()
        let frame = canvas.frame, timelineFrame = timeline.frame
        try require(timeline.showsClipLane && !timeline.showsTrimHandles && abs(timeline.duration - 11) < 0.000001,
            "Finished UI must show edited duration and Clips without source trim handles")
        try require(canvas.incomingTestPattern?.layer.opacity == 0.5 && !canvas.hasMediaPlayerLayer && !playback.hasMediaPlayer,
            "Actual editor must blend two vector poses without creating media objects")
        playback.seek(5)
        try await settle { timeline.showsTrimHandles && abs(timeline.duration - 14) < 0.000001 }
        host.layoutSubtreeIfNeeded()
        try require(canvas.frame == frame && timeline.frame == timelineFrame,
            "Source/Finished navigation must not rearrange the preview or timeline")
        playback.seekOutput(3.5)
        try await settle { !timeline.showsTrimHandles && canvas.incomingTestPattern?.layer.isHidden == false }
        try require(editor.project.state == project.state && !editor.canUndo, "Review/navigation must not create edits")
        if let path = ProcessInfo.processInfo.environment["CUT_UI_SNAPSHOT"] {
            host.layoutSubtreeIfNeeded()
            if let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: image)
                try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        print("Actual cut editor window checks passed: Finished/Source binding, two vector branches, fixed geometry, no media/focus/edits.")
    }
}
