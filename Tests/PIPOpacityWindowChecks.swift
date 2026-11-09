import AppKit
import SwiftUI
@testable import FrameThrower

private struct OpacityWindowFailure: Error { let message: String }

/// Exercise actual editor controls in an offscreen window. No real
/// input, screenshots, model calls, source files, players, or media processing.
@main @MainActor
struct PIPOpacityWindowChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw OpacityWindowFailure(message: message) }
    }
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
    static func settle(_ host: NSView, _ condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            if ContinuousClock.now > deadline { throw OpacityWindowFailure(message: "Editor controls did not settle") }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        host.layoutSubtreeIfNeeded()
    }
    struct OpacityControl { let frame: CGRect }
    /// SwiftUI on macOS 27 supplies neither NSSlider views nor accessibility
    /// children in an inactive window. Use the actual native tab row and preview
    /// bounds to locate the right-aligned header slider, then require a mutation.
    static func opacityControl(picker: NSSegmentedControl, canvas: EditorCanvasView) -> OpacityControl {
        let row = picker.convert(picker.bounds, to: nil)
        let innerRight = canvas.convert(canvas.bounds, to: nil).maxX - 14
        let groupLeft = innerRight - 13 - 8 - 215 // eye, spacing, CommitSlider
        let titleWidth = ("Opacity" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width
        return OpacityControl(frame: CGRect(x: groupLeft + titleWidth + 8, y: row.midY - 8,
            width: 215 - titleWidth - 8 - 45 - 8, height: 16))
    }
    static func dragToZero(_ control: OpacityControl, window: NSWindow, host: NSView,
                           editor: ProjectEditor) async throws -> Bool {
        let start = CGPoint(x: control.frame.midX, y: control.frame.midY)
        // Continue beyond the estimated track end so zero is independent of
        // native knob inset. Events remain local to this offscreen test window.
        let end = CGPoint(x: control.frame.minX - 12, y: control.frame.midY)
        func event(_ kind: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw OpacityWindowFailure(message: "Local opacity mouse event")
            }
            return value
        }
        window.sendEvent(try event(.leftMouseDown, at: start))
        window.sendEvent(try event(.leftMouseDragged, at: end))
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let previewed = editor.draftState != nil
        window.sendEvent(try event(.leftMouseUp, at: end))
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        return previewed
    }
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("Opacity window check exceeded 45 seconds\n".utf8)); Darwin.exit(1)
        }
        try require(MediaProcessing.isSuspended, "media interlock must remain enabled")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-opacity-window-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = RecordingProject(screenFilename: "never-open-screen.mov", cameraFilename: "never-open-camera.mov", duration: 14)
        project.state.cuts = [.init(start: 4, end: 6, crossfade: 1)]
        let geometry = PIPKeyframe(time: 10, placement: .init(x: 0.2, y: 0.8, scale: 0.3, shape: .circle,
            crop: .init(x: 0.3, y: 0.6), sourceZoom: 1.5, fullscreen: 0.4, opacity: 1), transition: .smooth, duration: 10)
        project.state.pipKeyframes.append(geometry)
        let target = CameraOpacityKeyframe(time: 5, opacity: 0.4, transition: .smooth, duration: 2)
        project.state.cameraOpacityKeyframes = [target]
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("Opacity.framethrower"))
        try require(editor.save(), "save synthetic metadata")
        let playback = EditorPlayback()
        let assistant = EditorAssistantSession(transport: { _ in throw OpacityWindowFailure(message: "Unexpected model call") }, persistsConversation: false)
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, playback: playback, assistant: assistant))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1100, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close(); playback.close() }
        try await settle(host) { playback.canPlay && !all(RecordingTimelineView.self, in: host).isEmpty }
        guard let picker = all(NSSegmentedControl.self, in: host).first(where: { control in
            let labels = (0..<control.segmentCount).compactMap { control.label(forSegment: $0) }
            return labels.contains("Zoom") && labels.contains("Camera")
        }), let action = picker.action,
        let index = (0..<picker.segmentCount).first(where: { picker.label(forSegment: $0) == "Camera" }) else {
            throw OpacityWindowFailure(message: "Camera inspector picker missing")
        }
        picker.selectedSegment = index
        try require(picker.sendAction(action, to: picker.target), "switch Camera inspector")
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        let canvas = all(EditorCanvasView.self, in: host).first!, timeline = all(RecordingTimelineView.self, in: host).first!
        let frames = [window.frame, canvas.frame, timeline.frame]
        playback.seekOutput(3.5)
        try await settle(host) { canvas.incomingTestPattern?.layer.isHidden == false }
        let beforeDisabledDrag = editor.project
        let disabledPreview = try await dragToZero(opacityControl(picker: picker, canvas: canvas),
            window: window, host: host, editor: editor)
        try require(!disabledPreview && editor.draftState == nil && editor.project == beforeDisabledDrag,
            "Dragging opacity during an ambiguous blend must not change either source branch")
        try require(!editor.canUndo && !playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer,
            "Inspecting opacity allocated media or changed history")
        timeline.onSelectAnimation?(.init(lane: .cameraOpacity, componentID: target.id))
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        try require(playback.outputTime == 3.5, "Selecting a source camera edit implicitly sought a fade branch")
        let selectedPreview = try await dragToZero(opacityControl(picker: picker, canvas: canvas),
            window: window, host: host, editor: editor)
        try require(selectedPreview, "Selected opacity slider did not preview a real document edit")
        try await settle(host) { editor.project.state.cameraOpacityKeyframes.first(where: { $0.id == target.id })?.opacity == 0 && editor.draftState == nil }
        let result = editor.project.state.cameraOpacityKeyframes.first { $0.id == target.id }!
        try require(result.opacity == 0 && editor.project.state.pipKeyframes == project.state.pipKeyframes && result.transition == target.transition && result.duration == target.duration,
            "Opacity slider discarded geometry, identity or Camera timing")
        try require(editor.project.undoHistory.count == 1 && timeline.animationSpans.contains { $0.label.hasPrefix("Fade camera out") }, "Opacity drag must finish one labeled Undo step")
        host.layoutSubtreeIfNeeded()
        try require([window.frame, canvas.frame, timeline.frame] == frames, "opacity controls/selection reflowed editor geometry")
        try require(editor.undo() && editor.project.state == project.state && !editor.canUndo, "one Undo did not restore selected source camera opacity")
        try require(editor.redo() && editor.project.state.cameraOpacityKeyframes.first(where: { $0.id == target.id })?.opacity == 0, "Redo did not restore camera fade")
        let prior = editor.project.state, historyCount = editor.project.undoHistory.count
        timeline.onDeselectEdit?(); playback.seek(3)
        try await settle(host) { timeline.showsTrimHandles }
        let playheadPreview = try await dragToZero(opacityControl(picker: picker, canvas: canvas),
            window: window, host: host, editor: editor)
        try require(playheadPreview, "Arbitrary-playhead opacity slider did not preview a real edit")
        try await settle(host) { editor.project.state.cameraOpacityKeyframes.contains { $0.time == 3 && $0.opacity == 0 } && editor.draftState == nil }
        try require(editor.project.state.pipKeyframes == prior.pipKeyframes && editor.project.undoHistory.count == historyCount + 1,
            "arbitrary-playhead opacity control inserted a placement point or multiple Undo steps")
        for time in stride(from: 0.0, through: 14.0, by: 0.25) {
            try require(editor.project.state.cameraGeometry(at: time) == prior.cameraGeometry(at: time),
                "Arbitrary-playhead fade changed camera geometry at \(time)")
        }
        try require(editor.undo() && editor.project.state == prior, "arbitrary-playhead fade Undo changed the original camera motion")
        print("Actual opacity mouse interactions passed: ambiguous blend refuses edits, explicit alpha target revises identity/timing-preserving opacity, arbitrary-playhead fade preserves geometry, one Undo/Redo, fixed vector layout.")
    }
}
