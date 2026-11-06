@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// A real SwiftUI scene is required here: NSHostingController does not exercise
/// WindowGroup's content-minimum sizing negotiation and restoration behavior.
@main
struct WindowGroupLayoutChecks: App {
    @StateObject private var probe = WindowGroupLayoutProbe()

    var body: some Scene {
        WindowGroup("WindowGroup layout regression") {
            Group {
                if let editor = probe.editor { ProjectEditorView(editor: editor) }
                else { ProgressView("Preparing synthetic recording…").frame(width: 940, height: 780) }
            }
            .task { await probe.run() }
        }
        .defaultSize(width: 940, height: 780)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private final class WindowGroupLayoutProbe: ObservableObject {
    enum ProbeError: Error { case failed(String) }
    @Published var editor: ProjectEditor?
    private var started = false

    func run() async {
        guard !started else { return }
        started = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await EditorMovieFixtures.make(at: directory.appendingPathComponent("screen.mp4"),
                width: 1920, height: 1080, duration: 4, camera: false)
            try await EditorMovieFixtures.make(at: directory.appendingPathComponent("camera.mp4"),
                width: 640, height: 360, duration: 4, camera: true)
            let screenBytes = try Data(contentsOf: directory.appendingPathComponent("screen.mp4"))
            let cameraBytes = try Data(contentsOf: directory.appendingPathComponent("camera.mp4"))
            var project = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mp4", duration: 4)
            project.state.trimStart = 1.733333333
            project.state.trimEnd = 3.2
            let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("test.framethrower"))
            guard editor.save() else { throw ProbeError.failed("save synthetic project") }
            self.editor = editor
            try await inspectWindow()
            let finalScreenBytes = try Data(contentsOf: directory.appendingPathComponent("screen.mp4"))
            let finalCameraBytes = try Data(contentsOf: directory.appendingPathComponent("camera.mp4"))
            guard editor.project == project, finalScreenBytes == screenBytes, finalCameraBytes == cameraBytes else {
                throw ProbeError.failed("Play, trim-handle grab, or scrubbing mutated project/history/source media")
            }
            try? FileManager.default.removeItem(at: directory)
            output("WindowGroup layout checks passed (real SwiftUI scene, Play, paused trim grab, and source scrubbing).")
            Darwin.exit(0)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            output("WINDOWGROUP LAYOUT FAILURE: \(error)")
            Darwin.exit(1)
        }
    }

    private func inspectWindow() async throws {
        let deadline = Date().addingTimeInterval(10)
        var resolved: (NSWindow, NSView, EditorCanvasView, RecordingTimelineView)?
        while Date() < deadline {
            for window in NSApplication.shared.windows {
                guard let host = window.contentView, let canvas: EditorCanvasView = find(in: host),
                      let timeline: RecordingTimelineView = find(in: host),
                      canvas.playerLayer.player?.currentItem?.status == .readyToPlay else { continue }
                resolved = (window, host, canvas, timeline)
                break
            }
            if resolved != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let (window, host, canvas, timeline) = resolved else { throw ProbeError.failed("real editor scene never became ready") }
        try await Task.sleep(for: .milliseconds(300))
        for width in [940.0, 820.0] {
            window.setContentSize(CGSize(width: width, height: 780))
            try await Task.sleep(for: .milliseconds(150))
            let baseline = measure(window: window, host: host, canvas: canvas, timeline: timeline)
            output("WindowGroup baseline at width \(width): \(baseline)")
            guard let inspector = findAll(NSSegmentedControl.self, in: host).first(where: { $0.segmentCount == 3 }),
                  let action = inspector.action else {
                throw ProbeError.failed("missing native Zoom/Pointer/Camera inspector control")
            }
            for segment in [1, 2, 0] {
                inspector.selectedSegment = segment
                guard inspector.sendAction(action, to: inspector.target) else {
                    throw ProbeError.failed("inspector segment action was not delivered")
                }
                try await Task.sleep(for: .milliseconds(80))
                let cameraShapeVisible = findAll(NSSegmentedControl.self, in: host).contains { $0.segmentCount == 4 }
                guard cameraShapeVisible == (segment == 2) else {
                    throw ProbeError.failed("inspector selection did not change the production controls")
                }
                try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                                 baseline: baseline, context: "width \(width), inspector segment \(segment)", compareScrolls: false)
            }
            for cycle in 0..<3 {
                let timelineRect = host.convert(timeline.bounds, from: timeline)
                let play = CGPoint(x: timelineRect.minX - 35, y: timelineRect.midY)
                window.sendEvent(mouse(.leftMouseDown, at: play, in: host, window: window))
                window.sendEvent(mouse(.leftMouseUp, at: play, in: host, window: window))
                for index in 0..<40 {
                    try await Task.sleep(for: .milliseconds(10))
                    try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                                     baseline: baseline, context: "width \(width), cycle \(cycle), Play tick \(index)")
                }
                guard (canvas.playerLayer.player?.rate ?? 0) > 0 else { throw ProbeError.failed("native Play click did not start playback") }

                let handle = CGPoint(x: timeline.x(for: timeline.trimStart) + 4, y: 24)
                timeline.mouseDown(with: mouse(.leftMouseDown, at: handle, in: timeline, window: window))
                for index in 0..<20 {
                    try await Task.sleep(for: .milliseconds(10))
                    try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                                     baseline: baseline, context: "width \(width), cycle \(cycle), trim handle mouse-down tick \(index)")
                }
                timeline.mouseUp(with: mouse(.leftMouseUp, at: handle, in: timeline, window: window))
                for seconds in [1.8, 2.1, 2.6, 3.1, 2.3, 1.9] {
                    let location = CGPoint(x: timeline.x(for: seconds), y: 6)
                    timeline.mouseDown(with: mouse(.leftMouseDown, at: location, in: timeline, window: window))
                    timeline.mouseUp(with: mouse(.leftMouseUp, at: location, in: timeline, window: window))
                    for index in 0..<10 {
                        try await Task.sleep(for: .milliseconds(10))
                        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                                         baseline: baseline, context: "width \(width), cycle \(cycle), scrub \(seconds) tick \(index)")
                    }
                }
            }
        }
    }

    private struct Measurements: CustomStringConvertible {
        var window: CGRect
        var host: CGRect
        var fitting: CGSize
        var canvas: CGRect
        var player: CGRect
        var timeline: CGRect
        var scrolls: [CGRect]
        var description: String {
            "window=\(window), host=\(host), fitting=\(fitting), canvas=\(canvas), player=\(player), timeline=\(timeline), scrolls=\(scrolls)"
        }
        var rectangles: [CGRect] { [window, host, CGRect(origin: .zero, size: fitting), canvas, player, timeline] + scrolls }
    }

    private func measure(window: NSWindow, host: NSView, canvas: EditorCanvasView,
                         timeline: RecordingTimelineView) -> Measurements {
        host.layoutSubtreeIfNeeded()
        return Measurements(window: window.frame, host: host.frame, fitting: host.fittingSize,
            canvas: host.convert(canvas.bounds, from: canvas), player: host.convert(canvas.canvasRect, from: canvas),
            timeline: host.convert(timeline.bounds, from: timeline),
            scrolls: findAll(NSScrollView.self, in: host).map { host.convert($0.bounds, from: $0) })
    }

    private func assertStable(_ value: Measurements, baseline: Measurements, context: String,
                              compareScrolls: Bool = true) throws {
        let actualRects = compareScrolls ? value.rectangles : Array(value.rectangles.prefix(6))
        let expectedRects = compareScrolls ? baseline.rectangles : Array(baseline.rectangles.prefix(6))
        for (actual, expected) in zip(actualRects, expectedRects) {
            guard abs(actual.minX - expected.minX) < 0.5, abs(actual.minY - expected.minY) < 0.5,
                  abs(actual.width - expected.width) < 0.5, abs(actual.height - expected.height) < 0.5 else {
                throw ProbeError.failed("\(context) resized/reflowed. Before: \(baseline). After: \(value)")
            }
        }
    }

    private func find<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(in: $0) as T? }.first
    }

    private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { self.findAll(type, in: $0) }
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private func output(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}
