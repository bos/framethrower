import AppKit
import SwiftUI
@testable import FrameThrower

/// Uses the production editor with metadata only. No source files, device
/// discovery, image buffers, capture, or video decoder are constructed.
@main
@MainActor
struct EditorInspectorLayoutChecks {
    enum Failure: Error { case failed(String) }

    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Editor inspector layout failed: \(error)\n".utf8)); Darwin.exit(1) }
    }
    private static func run() async throws {
        guard MediaProcessing.isSuspended else { throw Failure.failed("This check requires the media interlock") }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        Task {
            do { try await SuspendingClock().sleep(for: .seconds(120)) } catch { return }
            FileHandle.standardError.write(Data("Inspector layout check exceeded 120 awake seconds\n".utf8)); Darwin.exit(1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try cancelledSliderGesture(in: directory)

        for size in [CGSize(width: 720, height: 540), CGSize(width: 1024, height: 760), CGSize(width: 1280, height: 900)] {
            var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 12)
            let zoom = ZoomKeyframe(time: 3, scale: 2, transition: .smooth, duration: 1)
            project.state.zoomKeyframes = [zoom]
            project.state.pipKeyframes.append(PIPKeyframe(time: 3, placement: PIPPlacement(), transition: .smooth, duration: 1))
            let editor = ProjectEditor(project: project, url: directory.appendingPathComponent(UUID().uuidString + ".framethrower"))
            guard editor.save() else { throw Failure.failed("Save metadata-only fixture") }
            let playback = EditorPlayback()
            let host = NSHostingView(rootView: ProjectEditorView(editor: editor, playback: playback,
                assistant: EditorAssistantSession(transport: { _ in throw CancellationError() }, persistsConversation: false)))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0
            window.contentView = host; window.orderBack(nil)
            try await settle(host)
            guard let canvas: EditorCanvasView = find(in: host), let timeline: RecordingTimelineView = find(in: host) else { throw Failure.failed("Production editor views missing") }
            _ = try EditorUIProbe.propertyTarget(in: host)
            let targets = [("Zoom", "Main video"), ("Camera", "PIP camera"), ("Pointer", "Mouse pointer"), ("Speed", "Playback speed"), ("Canvas", "Project canvas"), ("Audio", "Audio mix"), ("Videos", "Video clips"), ("Layers", "Graphics & text")]
            let baseline = frames(window, host, canvas, timeline)
            let unchanged = editor.project
            for (raw, target) in targets + [("Camera", "PIP camera"), ("Zoom", "Main video")] {
                try await EditorUIProbe.selectInspector(raw, editor: editor)
                try await settle(host)
                _ = try EditorUIProbe.propertyTarget(in: host)
                try same(frames(window, host, canvas, timeline), baseline, "Target \(target), size \(size)")
                try controlsFit(host)
                try EditorUIProbe.checkSliderWidths(in: host)
                if size.width == 720 { try await checkPropertyScrollWidths(host) }
                guard let tools = all(NSSegmentedControl.self, in: host).first(where: { labels($0).contains("Draw box") }) else { throw Failure.failed("Discoverable preview tools missing") }
                guard tools.isEnabled == (target != "Video clips") else { throw Failure.failed("Preview tool availability does not match its actual target") }
                guard !playback.isInspectingSource && editor.project == unchanged else {
                    throw Failure.failed("Target \(target) changed recording (state=\(editor.project.state != unchanged.state), history=\(editor.project.undoHistory.count)) or clock (source=\(playback.isInspectingSource))")
                }
                if target == "PIP camera", let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: "/tmp/framethrower-pip-properties-\(Int(size.width))x\(Int(size.height)).png"))
                    }
                }
            }
            for (layout, title) in [(VideoClipLayout.screen, "Main video"), (.camera, "PIP camera")] {
                try await EditorUIProbe.selectInspector("Pointer", editor: editor)
                try await settle(host)
                guard let layer = editor.project.effectiveVideoLayers().first(where: { $0.clips.contains(where: { $0.layout == layout }) }),
                      let clip = layer.clips.first(where: { $0.layout == layout }) else { throw Failure.failed("Native clip fixture missing") }
                timeline.onSelectVideo?(layer.id, clip.id, nil); try await settle(host)
                let raw = layout == .screen ? "Zoom" : "Camera"
                guard try await EditorUIProbe.context(editor: editor)["inspector"] as? String == raw,
                      timeline.selectedVideoClipID == clip.id,
                      playback.outputTime == 0 && !playback.isInspectingSource else {
                    throw Failure.failed("Selecting \(title) footage lost its clip highlight or moved the playhead")
                }
                try await EditorUIProbe.selectInspector("Pointer", editor: editor)
                try await settle(host)
                guard timeline.selectedVideoClipID == nil else { throw Failure.failed("Unrelated target kept a stale destructive clip selection") }
            }
            timeline.onSelectEdit?(zoom.id)
            try await settle(host)
            guard playback.outputTime == 0 && !playback.isInspectingSource else { throw Failure.failed("Selecting an edit warped the playhead or changed clock") }
            timeline.onDeselectEdit?(); try await settle(host)
            guard !playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer else { throw Failure.failed("Vector view allocated media") }
            playback.close(); window.close()
        }
        FileHandle.standardOutput.write(Data("Editor inspector layout checks passed (contextual targets, contained controls, stable preview/timeline/window allocation, project clock and selection, one-step slider rollback/Undo; vector-only and no app focus).\n".utf8))
    }

    private static func controlsFit(_ host: NSView) throws {
        for control in all(NSControl.self, in: host) where !control.isHiddenOrHasHiddenAncestor && control.alphaValue > 0 && control.bounds.width > 1 && control.bounds.height > 1 {
            let rect = control.convert(control.bounds, to: host)
            var parent = control.superview
            var clips: [NSClipView] = []
            while let view = parent { if let clip = view as? NSClipView { clips.append(clip) }; parent = view.superview }
            guard rect.intersects(host.bounds), clips.allSatisfy({ clip in
                let viewport = clip.convert(clip.bounds, to: host)
                return rect.maxY > viewport.minY && rect.minY < viewport.maxY
            }) else { continue }
            let constraints = [host.bounds] + clips.filter { $0.enclosingScrollView?.hasHorizontalScroller != true }.map { $0.convert($0.bounds, to: host) }
            for available in constraints {
                guard rect.minX >= available.minX - 2 && rect.maxX <= available.maxX + 2 else { throw Failure.failed("Visible \(type(of: control)) escapes inspector/viewport width: \(rect), viewport \(available)") }
            }
        }
    }

    private static func checkPropertyScrollWidths(_ host: NSView) async throws {
        // Test the controls below the initial fold too. They become visible
        // through local scrolling, rather than by growing the whole window.
        let targetFrame = try EditorUIProbe.propertyTarget(in: host).accessibilityFrame()
        let scrollers = all(NSScrollView.self, in: host).filter { scroll in
            let rect = scroll.convert(scroll.bounds, to: host)
            return rect.width <= 340 && rect.minX >= host.bounds.maxX - 360
                && (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height + 2
        }
        for scroll in scrollers {
            guard let document = scroll.documentView else { continue }
            let clip = scroll.contentView, original = clip.bounds.origin
            let maximum = max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
            var position = document.bounds.minY
            while position < maximum {
                clip.scroll(to: CGPoint(x: original.x, y: position)); scroll.reflectScrolledClipView(clip)
                try await settle(host); try controlsFit(host)
                try EditorUIProbe.checkSliderWidths(in: host)
                guard try EditorUIProbe.propertyTarget(in: host).accessibilityFrame() == targetFrame else { throw Failure.failed("Property target scrolled out of its persistent header") }
                position += max(40, clip.bounds.height * 0.7)
            }
            clip.scroll(to: CGPoint(x: original.x, y: maximum)); scroll.reflectScrolledClipView(clip)
            try await settle(host); try controlsFit(host)
            try EditorUIProbe.checkSliderWidths(in: host)
            guard try EditorUIProbe.propertyTarget(in: host).accessibilityFrame() == targetFrame else { throw Failure.failed("Property target moved when its controls scrolled") }
            clip.scroll(to: original); scroll.reflectScrolledClipView(clip)
            try await settle(host)
        }
    }

    private static func cancelledSliderGesture(in directory: URL) throws {
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "missing.mov", duration: 12),
            url: directory.appendingPathComponent("slider.framethrower"))
        guard editor.save() else { throw Failure.failed("Save slider metadata") }
        let original = editor.project
        let originalBytes = try Data(contentsOf: editor.url)
        let range = 0.0...100.0
        var slider = CommitSliderGesture()
        slider.synchronize(editor.editingState.audio.volume * 100, in: range)
        slider.begin()
        slider.draft = 35
        var draft = editor.editingState
        draft.audio.volume = slider.draft / 100
        guard editor.updateDraft(draft, at: 0), editor.cancelDraft() else { throw Failure.failed("Cancel volume while tracking") }
        slider.synchronize(editor.editingState.audio.volume * 100, in: range)
        // Escape cleared the owner's gesture token, so mouse-up has no commit.
        _ = slider.finish(restoring: editor.editingState.audio.volume * 100, in: range)
        guard slider.draft == 100, !slider.isEditing,
              editor.project == original, try Data(contentsOf: editor.url) == originalBytes else {
            throw Failure.failed("Escape then release must restore the thumb without saving a discarded volume")
        }
        slider.begin()
        guard slider.draft == 100 else { throw Failure.failed("Next drag began from the discarded volume") }
        slider.draft -= 5
        draft = editor.editingState
        draft.audio.volume = slider.draft / 100
        guard editor.updateDraft(draft, at: 0) else { throw Failure.failed("Preview next volume gesture") }
        let proposed = slider.finish(restoring: editor.editingState.audio.volume * 100, in: range)
        guard proposed == 95, editor.finishDraft(name: "Change recording volume"),
              editor.project.state.audio.volume == 0.95, editor.project.undoHistory.count == 1,
              editor.undo(), editor.project.state == original.state else {
            throw Failure.failed("Next drag must edit from the restored volume with one correct Undo step")
        }

        // Controls without live previews still commit the final dragged value;
        // the subsequent owner notification supplies their displayed value.
        var committedOnly = CommitSliderGesture()
        committedOnly.synchronize(20, in: range)
        committedOnly.begin()
        committedOnly.draft = 60
        let accepted = committedOnly.finish(restoring: 20, in: range)
        committedOnly.synchronize(accepted, in: range)
        guard accepted == 60, committedOnly.draft == 60 else { throw Failure.failed("Committed-only slider lost its final value") }
        committedOnly.draft = 90
        committedOnly.begin()
        guard committedOnly.finish(restoring: 60, in: range) == 90 else {
            throw Failure.failed("Starting tracking must preserve an initial click sample supplied by the native slider")
        }
    }

    private static func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
    }

    private static func labels(_ picker: NSSegmentedControl) -> [String] {
        (0..<picker.segmentCount).compactMap { picker.label(forSegment: $0) }
    }

    private static func frames(_ window: NSWindow, _ host: NSView, _ canvas: EditorCanvasView,
                               _ timeline: RecordingTimelineView) -> [CGRect] {
        [window.frame, host.frame, CGRect(origin: .zero, size: host.fittingSize),
         host.convert(canvas.bounds, from: canvas), host.convert(canvas.canvasRect, from: canvas),
         host.convert(timeline.bounds, from: timeline)]
    }

    private static func same(_ actual: [CGRect], _ expected: [CGRect], _ context: String) throws {
        for (value, baseline) in zip(actual, expected) {
            guard abs(value.minX - baseline.minX) < 0.5, abs(value.minY - baseline.minY) < 0.5,
                  abs(value.width - baseline.width) < 0.5, abs(value.height - baseline.height) < 0.5 else {
                throw Failure.failed("\(context) reflowed: \(baseline) -> \(value)")
            }
        }
    }

    private static func find<T: NSView>(in view: NSView) -> T? {
        if let value = view as? T { return value }
        for child in view.subviews { if let value: T = find(in: child) { return value } }
        return nil
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
}
