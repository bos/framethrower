import AppKit
import SwiftUI

/// Uses the production editor with metadata only. No source files, device
/// discovery, image buffers, capture, or video decoder are constructed.
@main
@MainActor
struct EditorInspectorLayoutChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        guard MediaProcessing.isSuspended else { throw Failure.failed("This check requires the media interlock") }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("Inspector layout check exceeded 45 seconds\n".utf8))
            Darwin.exit(1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for size in [CGSize(width: 820, height: 760), CGSize(width: 1100, height: 900)] {
            var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 12)
            let zoom = ZoomKeyframe(time: 3, scale: 2, transition: .smooth, duration: 1)
            project.state.zoomKeyframes = [zoom]
            project.state.pipKeyframes.append(PIPKeyframe(time: 3, placement: PIPPlacement(), transition: .smooth, duration: 1))
            // Exercise the extra effective-fade state row inside the same fixed
            // inspector allocation used by ordinary recording controls.
            project.state.trimStart = 2
            project.state.trimEnd = 2.5
            project.state.audio = RecordingAudio(volume: 0.7, fadeIn: 1, fadeOut: 3)
            let editor = ProjectEditor(project: project, url: directory.appendingPathComponent(UUID().uuidString + ".framethrower"))
            guard editor.save() else { throw Failure.failed("Save metadata-only fixture") }
            let host = NSHostingView(rootView: ProjectEditorView(editor: editor))
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            try await settle(host)
            guard let canvas: EditorCanvasView = find(in: host), let timeline: RecordingTimelineView = find(in: host),
                  let picker = all(NSSegmentedControl.self, in: host).first(where: {
                      labels($0) == ["Zoom", "Pointer", "Camera", "Canvas", "Audio"]
                  }), let action = picker.action else { throw Failure.failed("Production editor controls missing") }

            let baseline = frames(window, host, canvas, timeline)
            for selected in [false, true, false] {
                if selected { timeline.onSelectEdit?(zoom.id) }
                else { timeline.onDeselectEdit?() }
                try await settle(host)
                for segment in [2, 1, 4, 3, 4, 0, 2, 0] {
                    picker.selectedSegment = segment
                    guard picker.sendAction(action, to: picker.target) else { throw Failure.failed("Tool selection failed") }
                    try await settle(host)
                    let cameraVisible = all(NSSegmentedControl.self, in: host).contains { labels($0).contains("Original") && labels($0).contains("Circle") }
                    guard cameraVisible == (segment == 2) else { throw Failure.failed("Tool controls did not switch") }
                    try same(frames(window, host, canvas, timeline), baseline,
                             "tab \(segment), selected edit \(selected), size \(size)")
                    guard canvas.playerLayer.player == nil, canvas.stillLayer.contents == nil else {
                        throw Failure.failed("Suspended view accessed video")
                    }
                }
            }
            guard editor.project.state == project.state else { throw Failure.failed("Tool switching changed project edits") }
            window.close()
        }
        print("Editor inspector layout checks passed (all five tabs, selected/deselected edits, minimum/default widths, fixed preview/timeline/window geometry, metadata-only media interlock).")
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
