@preconcurrency import AVFoundation
import AppKit
import SwiftUI

private enum LiveLayoutError: Error { case failed(String) }

/// Uses a resizable NSHostingController window and actual decoded 1080p media.
/// Placeholder media cannot expose frame-publication/autosizing regressions.
@main
@MainActor
struct LiveEditorLayoutChecks {
    struct Layout: CustomStringConvertible {
        var window: CGRect
        var host: CGRect
        var fitting: CGSize
        var player: CGRect
        var timeline: CGRect
        var description: String {
            "window=\(window), host=\(host), fitting=\(fitting), player=\(player), timeline=\(timeline)"
        }
    }

    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = directory.appendingPathComponent("screen.mp4")
        let camera = directory.appendingPathComponent("camera.mp4")
        try await EditorMovieFixtures.make(at: screen, width: 1920, height: 1080, duration: 10, camera: false)
        try await EditorMovieFixtures.make(at: camera, width: 640, height: 360, duration: 10, camera: true)
        var project = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mp4", duration: 10)
        project.state.pipKeyframes[0].placement = PIPPlacement(x: 0.2, y: 0.2, scale: 0.25,
                                                              shape: .rectangle, aspectRatio: 2)
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("test.framethrower"))
        guard editor.save() else { throw LiveLayoutError.failed("save fixture project") }
        let controller = NSHostingController(rootView: ProjectEditorView(editor: editor))
        controller.sizingOptions = [.minSize, .preferredContentSize]
        let host = controller.view
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 940, height: 780))
        window.setFrameOrigin(CGPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(10)
        while findPlayer(in: host)?.playerLayer.player?.currentItem?.status != .readyToPlay {
            guard Date() < deadline else { throw LiveLayoutError.failed("valid source never reached ready-to-play") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        let baseline = try layout(host: host, window: window)
        FileHandle.standardError.write(Data("Live editor baseline: \(baseline)\n".utf8))
        guard let timeline: RecordingTimelineView = find(in: host) else {
            throw LiveLayoutError.failed("missing timeline")
        }
        var samples = 0
        var hashes = Set<UInt64>()
        for seconds in [0.15, 1.25, 2.5, 3.75, 4.5, 5.25, 6.5, 7.75, 8.25, 9.4] {
            let point = CGPoint(x: timeline.x(for: seconds), y: 6)
            timeline.mouseDown(with: mouse(.leftMouseDown, at: point, in: timeline, window: window))
            timeline.mouseUp(with: mouse(.leftMouseUp, at: point, in: timeline, window: window))
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(40))
                let current = try layout(host: host, window: window)
                try stable(current, baseline: baseline, context: "scrub \(seconds)s sample \(samples)")
                guard let preview = findPlayer(in: host),
                      preview.stillLayer.contents != nil || preview.playerLayer.isReadyForDisplay else {
                    throw LiveLayoutError.failed("scrubbing exposed an empty preview with no still image or ready player frame")
                }
                if let contents = preview.stillLayer.contents {
                    hashes.insert(pixels(contents as! CGImage))
                }
                samples += 1
            }
        }
        guard hashes.count > 1 else { throw LiveLayoutError.failed("real source frames never changed visible pixels") }

        // Return to the beginning and sample native layout throughout a live
        // PIP draft, rather than checking only after mouse-up/rebuild.
        let startTime = CGPoint(x: timeline.x(for: 0), y: 6)
        timeline.mouseDown(with: mouse(.leftMouseDown, at: startTime, in: timeline, window: window))
        timeline.mouseUp(with: mouse(.leftMouseUp, at: startTime, in: timeline, window: window))
        try await Task.sleep(for: .milliseconds(200))
        let canvas = try layout(host: host, window: window).player
        let pip = project.state.placement(at: 0).frame(in: canvas.size, cameraAspect: 16.0 / 9.0)
        let start = CGPoint(x: canvas.minX + pip.midX, y: canvas.minY + pip.midY)
        guard let native = findPlayer(in: host) else { throw LiveLayoutError.failed("missing native editor canvas") }
        var draftHashes = Set<UInt64>()
        native.mouseDown(with: mouse(.leftMouseDown, at: start, in: host, window: window))
        for step in 1...20 {
            let point = CGPoint(x: start.x + Double(step) * 3, y: start.y + Double(step))
            native.mouseDragged(with: mouse(.leftMouseDragged, at: point, in: host, window: window))
            try await Task.sleep(for: .milliseconds(30))
            let current = try layout(host: host, window: window)
            try stable(current, baseline: baseline, context: "live PIP drag sample \(step)")
            if let contents = native.stillLayer.contents { draftHashes.insert(pixels(contents as! CGImage)) }
            samples += 1
        }
        native.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: start.x + 60, y: start.y + 20), in: host, window: window))
        try await Task.sleep(for: .milliseconds(300))
        try stable(try layout(host: host, window: window), baseline: baseline, context: "committed PIP drag")
        guard editor.project.undoHistory.count == 1 else {
            throw LiveLayoutError.failed("live drag did not create exactly one committed edit: \(editor.project.undoHistory.map(\.name)), timeline=\(timeline.playhead)")
        }
        guard draftHashes.count > 1 else {
            throw LiveLayoutError.failed("dragging changed only the outline; composed camera pixels did not update live")
        }
        print("Live editor layout checks passed (\(samples) frame-update samples, \(hashes.count) decoded scrub frames, \(draftHashes.count) live composed drag frames, real 1080p sources, resizable hosting window).")
    }

    private static func layout(host: NSView, window: NSWindow) throws -> Layout {
        host.layoutSubtreeIfNeeded()
        guard let player = findPlayer(in: host), let timeline: RecordingTimelineView = find(in: host) else {
            throw LiveLayoutError.failed("missing player or timeline")
        }
        return Layout(window: window.frame, host: host.frame, fitting: host.fittingSize,
                      player: host.convert(player.canvasRect, from: player),
                      timeline: host.convert(timeline.bounds, from: timeline))
    }

    private static func stable(_ current: Layout, baseline: Layout, context: String) throws {
        let values = [(current.window, baseline.window), (current.host, baseline.host),
                      (current.player, baseline.player), (current.timeline, baseline.timeline),
                      (CGRect(origin: .zero, size: current.fitting), CGRect(origin: .zero, size: baseline.fitting))]
        for (actual, expected) in values {
            guard abs(actual.minX - expected.minX) < 0.5, abs(actual.minY - expected.minY) < 0.5,
                  abs(actual.width - expected.width) < 0.5, abs(actual.height - expected.height) < 0.5 else {
                throw LiveLayoutError.failed("\(context) changed native layout. Before: \(baseline). After: \(current)")
            }
        }
    }

    private static func pixels(_ image: CGImage) -> UInt64 {
        guard let buffer = image.dataProvider?.data else { return 0 }
        let data = CFDataGetBytePtr(buffer)!
        var hash: UInt64 = 1469598103934665603
        for index in stride(from: 0, to: CFDataGetLength(buffer), by: 257) {
            hash = (hash ^ UInt64(data[index])) &* 1099511628211
        }
        return hash
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private static func findPlayer(in view: NSView) -> EditorCanvasView? { find(in: view) }

    private static func find<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(in: $0) as T? }.first
    }
}
