import AppKit
import SwiftUI
@testable import FrameThrower

private struct AudioInterfaceFailure: Error { var message: String }
@main @MainActor
struct IndependentAudioInterfaceChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AudioInterfaceFailure(message: message) }
    }
    static func all<T: NSView>(_ type: T.Type, _ root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { all(type, $0) }
    }
    static func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    }
    struct VolumeControl { let frame: CGRect }
    static func volumeControl(_ label: String, in host: NSView) -> VolumeControl? {
        guard let tabs = all(NSSegmentedControl.self, host).first(where: { picker in
            (0..<picker.segmentCount).contains { picker.label(forSegment: $0) == "Audio" }
        }), tabs.label(forSegment: tabs.selectedSegment) == "Audio",
        let movement = all(MotionDurationTextField.self, host).first else { return nil }
        let row = movement.convert(movement.bounds, to: nil)
        let origin = tabs.convert(tabs.bounds, to: nil).minX
        let titleWidth = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]).width
        return VolumeControl(frame: CGRect(x: origin + titleWidth + 8, y: row.midY - 8,
            width: 310 - titleWidth - 8 - 45 - 8, height: 16))
    }
    /// macOS27 draws SwiftUI sliders without NSSlider/AX children in an
    /// offscreen window. Anchor to the actual adjacent native controls, then
    /// verify the resulting document mutation rather than assuming a click worked.
    static func drag(_ slider: VolumeControl, fraction: Double, host: NSView, editor: ProjectEditor, cancel: (() -> Void)? = nil) async throws -> Bool {
        guard let window = host.window else { throw AudioInterfaceFailure(message: "Native volume window") }
        let frame = slider.frame
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let finish = CGPoint(x: frame.minX + 8 + (frame.width - 16) * fraction, y: frame.midY)
        func event(_ kind: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw AudioInterfaceFailure(message: "Local slider event") }
            return event
        }
        window.sendEvent(try event(.leftMouseDown, start))
        window.sendEvent(try event(.leftMouseDragged, finish))
        try await settle(host)
        let previewed = editor.draftState != nil
        if let cancel {
            // An inactive, unordered NSHostingView cannot route real keyboard
            // commands. Invoke the actual editor cancel action also wired to
            // Escape, then verify that native mouse-up cannot publish it.
            cancel()
            try await settle(host)
        }
        window.sendEvent(try event(.leftMouseUp, finish))
        try await settle(host)
        return previewed
    }
    static func directVolumeEditing(editor: ProjectEditor, playback: EditorPlayback, host: NSView,
                                    timeline: RecordingTimelineView, window: NSWindow) async throws {
        timeline.onDeselectEdit?(); playback.seek(8); try await settle(host)
        guard let slider = volumeControl("Volume at playhead", in: host) else {
            let popups = all(MotionDurationTextField.self, host).map(\.stringValue)
            throw AudioInterfaceFailure(message: "Playhead volume control; popup titles=\(popups)")
        }
        try require(abs(editor.editingState.audio.channel(.microphone).envelopeGain(at: playback.editingTime) - 0.2) < 0.001,
            "Playhead control starts on current source curve")
        try require(!all(NSButton.self, host).contains { $0.title == "Add change" }, "No separate Add change action")
        let before = editor.project
        _ = try await drag(slider, fraction: 0.65, host: host, editor: editor)
        try await settle(host)
        let edited = editor.project.state.audio.channel(.microphone)
        try require(edited.points.count == before.state.audio.channel(.microphone).points.count + 1 &&
            edited.points.contains(where: { abs($0.time - 8) < 0.000001 && $0.gain > 0.3 }) &&
            editor.project.undoHistory.count == before.undoHistory.count + 1 && playback.time == 8,
            "Adjusting volume with no selection directly creates one source-anchored change and one Undo without seeking")
        try require(editor.undo() && editor.project.state == before.state, "One Undo restores automatic playhead volume creation")
        timeline.onDeselectEdit?(); playback.seek(9); try await settle(host)
        let beforeCancel = editor.project
        guard let cancelSlider = volumeControl("Volume at playhead", in: host) else { throw AudioInterfaceFailure(message: "Canceled playhead control") }
        let previewed = try await drag(cancelSlider, fraction: 0.75, host: host, editor: editor, cancel: { timeline.onCancelEdit?() })
        try await settle(host)
        try require(previewed && editor.draftState == nil && editor.project == beforeCancel && playback.time == 9,
            "Escape during native volume tracking: previewed=\(previewed), draft=\(editor.draftState != nil), unchanged=\(editor.project == beforeCancel), source=\(playback.time), undo=\(editor.historyState.undo)")
        let id = before.state.audio.channel(.microphone).points[0].id
        timeline.onSelectAnimation?(.init(lane: .audioMicrophone, componentID: id)); try await settle(host)
        guard let selected = volumeControl("Volume at selection", in: host) else { throw AudioInterfaceFailure(message: "Selected volume control") }
        _ = try await drag(selected, fraction: 0.5, host: host, editor: editor); try await settle(host)
        try require(editor.project.state.audio.channel(.microphone).points.count == before.state.audio.channel(.microphone).points.count &&
            editor.project.state.audio.channel(.microphone).points[0].id == id &&
            editor.project.state.audio.channel(.microphone).points[0].gain > 0.3 &&
            editor.project.state.audio.channel(.systemAudio) == before.state.audio.channel(.systemAudio) &&
            editor.project.undoHistory.count == beforeCancel.undoHistory.count + 1 && playback.time == 9,
            "Selected audio point revises gain with one Undo, preserving identity/other role/playhead")
    }
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("Audio interface check exceeded 45 seconds\n".utf8)); Darwin.exit(1)
        }
        try require(MediaProcessing.isSuspended, "Vector-only UI requires suspension")
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-interface-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for size in [CGSize(width: 820, height: 760), CGSize(width: 1100, height: 900)] {
            var project = RecordingProject(screenFilename: "unopened.data", cameraFilename: "unopened-camera.data", duration: 12,
                audioSources: [.init(role: .microphone), .init(role: .systemAudio)])
            project.state.audio.updateChannel(.microphone) { $0.points = [.init(time: 5, gain: 0.2, duration: 3)] }
            project.state.audio.updateChannel(.systemAudio) { $0.points = [.init(time: 5, gain: 0.8, duration: 3)] }
            let editor = ProjectEditor(project: project, url: directory.appendingPathComponent(UUID().uuidString + ".framethrower"))
            try require(editor.save(), "Save metadata fixture")
            let playback = EditorPlayback()
            let view = NSHostingView(rootView: ProjectEditorView(editor: editor, playback: playback, assistant: EditorAssistantSession(transport: { _ in throw CancellationError() })))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
            try await settle(view)
            guard let canvas = all(EditorCanvasView.self, view).first, let timeline = all(RecordingTimelineView.self, view).first,
                  let picker = all(NSSegmentedControl.self, view).first(where: { picker in
                      (0..<picker.segmentCount).compactMap { picker.label(forSegment: $0) }.contains("Audio")
                  }), let action = picker.action else { throw AudioInterfaceFailure(message: "Actual inspector/timeline controls") }
            let canvasFrame = view.convert(canvas.bounds, from: canvas), timelineFrame = view.convert(timeline.bounds, from: timeline)
            for label in ["Audio", "Camera", "Canvas", "Audio", "Zoom"] {
                guard let segment = (0..<picker.segmentCount).first(where: { picker.label(forSegment: $0) == label }) else { throw AudioInterfaceFailure(message: "Inspector tab") }
                picker.selectedSegment = segment; _ = picker.sendAction(action, to: picker.target)
                try await settle(view)
                try require(view.convert(canvas.bounds, from: canvas) == canvasFrame && view.convert(timeline.bounds, from: timeline) == timelineFrame,
                    "Audio inspector preserves preview/timeline geometry across tabs")
                try require(!canvas.hasMediaPlayerLayer, "No AVPlayerLayer allocated")
                if label == "Audio", let location = ProcessInfo.processInfo.environment["FRAMETHROWER_AUDIO_PREVIEW_DIR"] {
                    let folder = URL(fileURLWithPath: location)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let bytes = bitmap.representation(using: .png, properties: [:]) {
                            try bytes.write(to: folder.appendingPathComponent("audio-\(Int(size.width)).png"))
                        }
                    }
                }
            }
            let roles = timeline.animationLanes().map(\.lane)
            try require(roles.contains(.audioMicrophone) && roles.contains(.audioSystem), "Persistent independent audio lanes")
            let id = TimelineAnimationID(lane: .audioMicrophone, componentID: project.state.audio.channel(.microphone).points[0].id)
            timeline.onSelectAnimation?(id); try await settle(view)
            try require(picker.label(forSegment: picker.selectedSegment) == "Audio", "Audio lane selects ordinary Audio inspector")
            timeline.onAnimationEdit?(AnimationDrag(id: id, handle: .move, deltaSeconds: 1), false)
            try await settle(view)
            try require(editor.draftState?.audio.channel(.microphone).points[0].time == 6, "Native callback previews source-time audio movement")
            timeline.onAnimationCancel?(); try await settle(view)
            try require(editor.draftState == nil && editor.project.state == project.state, "Escape restores full audio gesture")
            timeline.onAnimationEdit?(AnimationDrag(id: id, handle: .move, deltaSeconds: 1), true)
            try await settle(view)
            try require(editor.project.state.audio.channel(.microphone).points[0].time == 6 && editor.project.undoHistory.count == 1 &&
                editor.project.state.audio.channel(.systemAudio) == project.state.audio.channel(.systemAudio), "One independent saved audio gesture")
            try require(editor.undo() && editor.project.state == project.state && editor.redo(), "Shared Undo/Redo")
            try await directVolumeEditing(editor: editor, playback: playback, host: view, timeline: timeline, window: window)
            try require(!canvas.hasMediaPlayerLayer && MediaProcessing.isSuspended, "No AV media objects")
            playback.close(); window.close()
        }
        print("Independent audio interface checks passed: actual Audio inspector/lane selection, stable minimum/default geometry, source-time drag/cancel, one Undo/Redo and zero AVPlayerLayer; metadata/vector only.")
    }
}
