@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// Events target only this test's own native preview, never system input.
private final class IntegratedTrackpadEvent: NSEvent {
    var amount = 0.0
    var dx = 0.0
    var dy = 0.0
    var position = CGPoint.zero
    var eventPhase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var locationInWindow: NSPoint { position }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
}

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
            guard let window = NSApplication.shared.windows.first(where: { window in
                guard let host = window.contentView else { return false }
                return find(in: host) as EditorCanvasView? != nil
            }), let host = window.contentView, let canvas: EditorCanvasView = find(in: host),
                  let timeline: RecordingTimelineView = find(in: host) else {
                throw ProbeError.failed("editor window for title synchronization")
            }
            let beforeRename = measure(window: window, host: host, canvas: canvas, timeline: timeline)
            guard editor.rename(to: "Renamed recording " + String(repeating: "long name ", count: 12)) else {
                throw ProbeError.failed("rename the recording")
            }
            try await titleMatches(editor, window: window)
            try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                             baseline: beforeRename, context: "renamed recording", compareScrolls: false)
            guard editor.undo(), editor.project.state == project.state else {
                throw ProbeError.failed("undo rename without changing video edits")
            }
            try await titleMatches(editor, window: window)
            try await inspectCombinedEditing(editor, window: window, host: host, canvas: canvas, timeline: timeline)
            guard try Data(contentsOf: directory.appendingPathComponent("screen.mp4")) == screenBytes,
                  try Data(contentsOf: directory.appendingPathComponent("camera.mp4")) == cameraBytes else {
                throw ProbeError.failed("combined edits changed original media")
            }
            try? FileManager.default.removeItem(at: directory)
            output("WindowGroup layout checks passed (real scene, stable Play/trim/scrub, shared names, combined drafts, diamond moves/X deletion, numeric duration, blank-lane deselection, Escape cancellation, and fixed transition geometry).")
            Darwin.exit(0)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            output("WINDOWGROUP LAYOUT FAILURE: \(error)")
            Darwin.exit(1)
        }
    }

    private func titleMatches(_ editor: ProjectEditor, window: NSWindow) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while window.title != editor.displayName {
            guard ContinuousClock.now < deadline else {
                throw ProbeError.failed("window title '\(window.title)' does not match '\(editor.displayName)'")
            }
            try await Task.sleep(for: .milliseconds(10))
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
        if ProcessInfo.processInfo.environment["FRAMETHROWER_EDIT_CHECKS_ONLY"] == "1" { return }
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

    private func inspectCombinedEditing(_ editor: ProjectEditor, window: NSWindow, host: NSView,
                                        canvas: EditorCanvasView, timeline: RecordingTimelineView) async throws {
        let zoomID = UUID(), cameraID = UUID()
        var initial = editor.project.state
        initial.trimStart = 0
        initial.trimEnd = 4
        initial.zoomKeyframes = [ZoomKeyframe(id: zoomID, time: 1, scale: 1.4)]
        var camera = PIPPlacement()
        camera.x = 0.6; camera.y = 0.6; camera.scale = 0.25
        initial.pipKeyframes.append(PIPKeyframe(id: cameraID, time: 1, placement: camera))
        guard editor.commit(initial, name: "Prepare combined-edit fixture") else {
            throw ProbeError.failed("prepare combined-edit fixture")
        }
        try await waitUntil("combined editor becomes ready") {
            canvas.allowsZoomEditing && timeline.edits.contains { $0.id == zoomID }
        }
        let before = editor.project
        let savedBytes = try Data(contentsOf: editor.url)
        let diamond = CGPoint(x: timeline.x(for: 1), y: 47)
        timeline.mouseDown(with: mouse(.leftMouseDown, at: diamond, in: timeline, window: window))
        timeline.mouseUp(with: mouse(.leftMouseUp, at: diamond, in: timeline, window: window))
        try await waitUntil("diamond selection seeks and highlights the existing edit") {
            timeline.selectedEditID == zoomID && abs(timeline.playhead - 1) < 0.001 &&
                abs(canvas.zoom.scale - 1.4) < 0.001 && canvas.allowsZoomEditing
        }
        let baseline = measure(window: window, host: host, canvas: canvas, timeline: timeline)
        let touch = IntegratedTrackpadEvent()
        touch.position = canvas.convert(CGPoint(x: canvas.canvasRect.minX + canvas.canvasRect.width * 0.4,
            y: canvas.canvasRect.minY + canvas.canvasRect.height * 0.4), to: nil)
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            touch.amount = phase == .ended ? 0 : 0.1
            touch.eventPhase = phase
            canvas.magnify(with: touch)
            try await Task.sleep(for: .milliseconds(30))
        }
        guard editor.draftState != nil, editor.project == before else {
            throw ProbeError.failed("pinch must create a draft without persisting its finger samples")
        }
        let cameraRect = canvas.placement.frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9)
            .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let cameraCenter = CGPoint(x: cameraRect.midX, y: cameraRect.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: cameraCenter, in: canvas, window: window))
        for delta in [10.0, 20, 30] {
            canvas.mouseDragged(with: mouse(.leftMouseDragged,
                at: CGPoint(x: cameraCenter.x + delta, y: cameraCenter.y - delta / 2), in: canvas, window: window))
            try await Task.sleep(for: .milliseconds(30))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp,
            at: CGPoint(x: cameraCenter.x + 30, y: cameraCenter.y - 15), in: canvas, window: window))
        try await Task.sleep(for: .milliseconds(30))
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            touch.eventPhase = phase
            touch.dx = phase == .ended ? 0 : 8
            touch.dy = phase == .ended ? 0 : 6
            canvas.scrollWheel(with: touch)
            try await Task.sleep(for: .milliseconds(30))
        }
        guard let draft = editor.draftState,
              editor.project == before, try Data(contentsOf: editor.url) == savedBytes,
              editor.draftTime == 1,
              draft.zoomKeyframes.count == initial.zoomKeyframes.count,
              draft.pipKeyframes.count == initial.pipKeyframes.count,
              draft.zoomKeyframes.first?.id == zoomID,
              draft.pipKeyframes.last?.id == cameraID,
              draft.zoomKeyframes.first?.scale != initial.zoomKeyframes.first?.scale,
              draft.pipKeyframes.last?.placement != initial.pipKeyframes.last?.placement,
              draft.timedEdits(includeCamera: true).filter({ $0.time == 1 }).count == 1 else {
            throw ProbeError.failed("zoom, pan, and camera samples must revise the selected IDs in one shared unsaved edit")
        }
        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
            baseline: baseline, context: "combined draft", compareScrolls: false)
        let leave = CGPoint(x: timeline.x(for: 2.4), y: 6)
        timeline.mouseDown(with: mouse(.leftMouseDown, at: leave, in: timeline, window: window))
        timeline.mouseUp(with: mouse(.leftMouseUp, at: leave, in: timeline, window: window))
        try await waitUntil("leaving edit time finalizes one combined edit") {
            editor.draftState == nil && editor.project.state == draft &&
                editor.project.undoHistory.count == before.undoHistory.count + 1 && timeline.selectedEditID == nil
        }
        guard let title: RecordingTitleField = find(in: host) else { throw ProbeError.failed("native title anchor for Undo") }
        let titleRect = host.convert(title.bounds, from: title)
        let undoCenter = CGPoint(x: titleRect.maxX + 32, y: titleRect.midY)
        window.sendEvent(mouse(.leftMouseDown, at: undoCenter, in: host, window: window))
        window.sendEvent(mouse(.leftMouseUp, at: undoCenter, in: host, window: window))
        try await waitUntil("Undo restores both zoom and camera together") {
            editor.project.state == initial && editor.project.undoHistory.count == before.undoHistory.count &&
                canvas.allowsZoomEditing
        }
        guard editor.redo() else { throw ProbeError.failed("redo combined edit") }
        try await waitUntil("redo rebuilds the combined edit") {
            editor.project.state == draft && canvas.allowsZoomEditing && timeline.edits.contains { $0.id == zoomID }
        }
        let beforeMove = editor.project
        let from = CGPoint(x: timeline.x(for: 1), y: 47)
        let to = CGPoint(x: timeline.x(for: 1.5), y: 47)
        timeline.mouseDown(with: mouse(.leftMouseDown, at: from, in: timeline, window: window))
        timeline.mouseDragged(with: mouse(.leftMouseDragged, at: to, in: timeline, window: window))
        try await Task.sleep(for: .milliseconds(30))
        guard editor.project == beforeMove, editor.draftState != nil else {
            throw ProbeError.failed("diamond movement must preview without intermediate persistence")
        }
        timeline.mouseUp(with: mouse(.leftMouseUp, at: to, in: timeline, window: window))
        try await waitUntil("diamond move commits both tracks once") {
            editor.draftState == nil && editor.project.undoHistory.count == beforeMove.undoHistory.count + 1 &&
                editor.project.state.zoomKeyframes.first?.time == 1.5 &&
                editor.project.state.pipKeyframes.last?.time == 1.5 && canvas.allowsZoomEditing
        }
        let moved = editor.project
        guard let strip = findAll(NSScrollView.self, in: host).first,
              let document = strip.documentView, document.bounds.width > 28 else {
            throw ProbeError.failed("native edit-strip anchor for inline X")
        }
        // This fixture has exactly one edit chip. Its trailing padding is 4pt
        // and its X target is 20pt wide, so the center is 14pt from its end.
        let removeCenter = host.convert(CGPoint(x: document.bounds.maxX - 14,
            y: document.bounds.midY), from: document)
        window.sendEvent(mouse(.leftMouseDown, at: removeCenter, in: host, window: window))
        window.sendEvent(mouse(.leftMouseUp, at: removeCenter, in: host, window: window))
        try await waitUntil("inline X removes both tracks as one edit") {
            editor.project.undoHistory.count == moved.undoHistory.count + 1 &&
                editor.project.state.zoomKeyframes.isEmpty && editor.project.state.pipKeyframes.count == 1
        }
        guard editor.undo(), editor.project.state == moved.state else {
            throw ProbeError.failed("Undo must restore the whole removed edit")
        }
        try await waitUntil("undo deletion rebuilds editor") { canvas.allowsZoomEditing }
        try await inspectSelectionLifecycle(editor, window: window, host: host, canvas: canvas, timeline: timeline)
    }

    private func inspectSelectionLifecycle(_ editor: ProjectEditor, window: NSWindow, host: NSView,
                                           canvas: EditorCanvasView, timeline: RecordingTimelineView) async throws {
        guard let edit = editor.project.state.timedEdits(includeCamera: true).first else {
            throw ProbeError.failed("missing edit for selection lifecycle fixture")
        }
        var smooth = editor.project.state
        if let index = smooth.zoomKeyframes.firstIndex(where: { $0.id == edit.zoomID }) {
            smooth.zoomKeyframes[index].transition = .smooth
            smooth.zoomKeyframes[index].duration = 0.8
        }
        guard editor.commit(smooth, name: "Prepare smooth selection fixture") else {
            throw ProbeError.failed("prepare smooth selection fixture")
        }
        try await waitUntil("selection fixture becomes ready") { canvas.allowsZoomEditing }
        guard let inspector = findAll(NSSegmentedControl.self, in: host).first(where: { $0.segmentCount == 3 }),
              let action = inspector.action else {
            throw ProbeError.failed("missing native inspector for smooth selection")
        }
        inspector.selectedSegment = 0
        guard inspector.sendAction(action, to: inspector.target) else {
            throw ProbeError.failed("could not select zoom inspector")
        }
        try await Task.sleep(for: .milliseconds(50))
        let baseline = measure(window: window, host: host, canvas: canvas, timeline: timeline)

        func select() async throws {
            let diamond = CGPoint(x: timeline.x(for: edit.time), y: 47)
            timeline.mouseDown(with: mouse(.leftMouseDown, at: diamond, in: timeline, window: window))
            timeline.mouseUp(with: mouse(.leftMouseUp, at: diamond, in: timeline, window: window))
            try await waitUntil("selected edit exposes its native transition duration") {
                timeline.selectedEditID == edit.id && abs(timeline.playhead - edit.time) < 0.000001 &&
                    canvas.allowsZoomEditing && canvas.stillLayer.contents != nil &&
                    (find(in: host) as MotionDurationTextField?) != nil
            }
            try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                             baseline: baseline, context: "show selected transition", compareScrolls: false)
        }
        func pinch() async throws {
            let touch = IntegratedTrackpadEvent()
            touch.position = canvas.convert(CGPoint(x: canvas.canvasRect.midX, y: canvas.canvasRect.midY), to: nil)
            for phase in [NSEvent.Phase.began, .changed, .ended] {
                touch.eventPhase = phase
                touch.amount = phase == .ended ? 0 : 0.05
                canvas.magnify(with: touch)
                try await Task.sleep(for: .milliseconds(30))
            }
            try await waitUntil("pinch revises selected edit as one pending draft") {
                editor.draftState != nil && canvas.stillLayer.contents != nil
            }
        }
        func escape() -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)!
        }

        try await select()
        let beforeBlank = editor.project
        guard let duration: MotionDurationTextField = find(in: host) else {
            throw ProbeError.failed("selected smooth edit lacks native duration input")
        }
        duration.stringValue = "1.25"
        duration.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: duration))
        try await waitUntil("numeric duration refines selected edit without saving") {
            editor.draftState?.zoomKeyframes.first(where: { $0.id == edit.zoomID })?.duration == 1.25 &&
                editor.project == beforeBlank
        }
        let afterDuration = editor.draftState
        for invalid in ["0", "NaN"] {
            duration.stringValue = invalid
            duration.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: duration))
            try await Task.sleep(for: .milliseconds(30))
            guard editor.draftState == afterDuration && editor.project == beforeBlank else {
                throw ProbeError.failed("invalid duration '\(invalid)' changed the edit or its saved history")
            }
        }
        try await pinch()
        guard let draft = editor.draftState else { throw ProbeError.failed("missing draft before blank-lane click") }
        guard editor.project == beforeBlank,
              draft.zoomKeyframes.first(where: { $0.id == edit.zoomID })?.duration == 1.25 else {
            throw ProbeError.failed("pinch must retain numeric duration in the same unsaved edit")
        }
        let playheadBeforeBlank = timeline.playhead
        let sourceTimeBeforeBlank = canvas.playerLayer.player?.currentTime().seconds ?? -.infinity
        let blank = CGPoint(x: timeline.x(for: 3.5), y: 47)
        timeline.mouseDown(with: mouse(.leftMouseDown, at: blank, in: timeline, window: window))
        timeline.mouseUp(with: mouse(.leftMouseUp, at: blank, in: timeline, window: window))
        try await waitUntil("blank edit lane finalizes and deselects without scrubbing") {
            editor.draftState == nil && timeline.selectedEditID == nil &&
                editor.project.state == draft && editor.project.undoHistory.count == beforeBlank.undoHistory.count + 1 &&
                canvas.allowsZoomEditing && canvas.stillLayer.contents != nil
        }
        guard abs(timeline.playhead - playheadBeforeBlank) < 0.000001,
              abs((canvas.playerLayer.player?.currentTime().seconds ?? -.infinity) - sourceTimeBeforeBlank) < 0.000001 else {
            throw ProbeError.failed("blank edit-lane deselection must keep the playhead and source frame")
        }
        guard (find(in: host) as MotionDurationTextField?) == nil else {
            throw ProbeError.failed("deselected transition duration remains in the native accessibility hierarchy")
        }
        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                         baseline: baseline, context: "blank-lane deselection hides transitions", compareScrolls: false)

        try await select()
        let beforeEscape = editor.project
        try await pinch()
        canvas.keyDown(with: escape())
        try await waitUntil("Escape discards draft and deselects the edit") {
            editor.draftState == nil && timeline.selectedEditID == nil && editor.project == beforeEscape &&
                canvas.allowsZoomEditing && canvas.stillLayer.contents != nil
        }
        guard (find(in: host) as MotionDurationTextField?) == nil else {
            throw ProbeError.failed("Escape must remove transition controls from the native hierarchy")
        }
        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                         baseline: baseline, context: "Escape cancels and hides transitions", compareScrolls: false)

        try await select()
        let beforeCleanEscape = editor.project
        guard editor.draftState == nil else { throw ProbeError.failed("selection alone created a draft") }
        timeline.keyDown(with: escape())
        try await waitUntil("Escape deselects a clean edit without history mutation") {
            timeline.selectedEditID == nil && editor.draftState == nil && editor.project == beforeCleanEscape
        }
        guard (find(in: host) as MotionDurationTextField?) == nil else {
            throw ProbeError.failed("clean Escape must hide transition controls")
        }
        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                         baseline: baseline, context: "clean Escape leaves geometry fixed", compareScrolls: false)
    }

    private func waitUntil(_ context: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProbeError.failed(context) }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Let production SwiftUI callbacks settle before the next input.
        try await Task.sleep(for: .milliseconds(30))
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
