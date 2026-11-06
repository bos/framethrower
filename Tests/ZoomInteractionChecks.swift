@preconcurrency import AVFoundation
import AppKit
import SwiftUI

private enum ZoomInteractionError: Error { case failed(String) }

/// Runs the production editor and native canvas against real local synthetic
/// media. Every edit goes through the editor's actual gesture callbacks.
@main
@MainActor
struct ZoomInteractionChecks {
    private static weak var outputItem: AVPlayerItem?
    private static var output: AVPlayerItemVideoOutput?

    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenURL = directory.appendingPathComponent("screen.mp4")
        let cameraURL = directory.appendingPathComponent("camera.mp4")
        try await EditorMovieFixtures.make(at: screenURL, width: 1920, height: 1080, duration: 4, camera: false)
        try await EditorMovieFixtures.make(at: cameraURL, width: 640, height: 360, duration: 4, camera: true)
        let screenBytes = try Data(contentsOf: screenURL)
        let cameraBytes = try Data(contentsOf: cameraURL)
        var project = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mp4", duration: 4)
        project.state.pipKeyframes[0].placement = PIPPlacement(x: 0.75, y: 0.75, scale: 0.2)
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("test.framethrower"))
        try require(editor.save(), "save fixture project")
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 940, height: 780),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        guard let canvas: EditorCanvasView = find(in: host) else { throw ZoomInteractionError.failed("missing canvas") }
        try await ready(canvas)
        let baseline = host.convert(canvas.bounds, from: canvas)
        let baselineWindow = window.frame
        let zoomPoint = sourcePoint(x: 0.3, y: 0.4, canvas: canvas)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: zoomPoint, canvas: canvas, window: window, clicks: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: zoomPoint, canvas: canvas, window: window, clicks: 2))
        try await ready(canvas)
        try zoom(editor.editingState.zoom(at: 0), equals: ZoomPlacement(scale: 2, x: 0.3, y: 0.4), "double-click focal zoom")
        try require(editor.draftState != nil && editor.project.undoHistory.isEmpty && editor.project.state.zoomKeyframes.isEmpty,
                    "double-click refines framing without persisting or adding intermediate undo entries")
        try require(editor.editingState.zoomKeyframes.count == 1 && editor.editingState.zoomKeyframes[0].time == 0,
                    "zoom gesture must create its point at the current source playhead")

        let start = sourcePoint(x: 0.15, y: 0.15, canvas: canvas)
        let delta = CGSize(width: 60, height: 40)
        let beforePan = editor.editingState.zoom(at: 0)
        try await drag(canvas, window: window, from: start, by: delta)
        try await ready(canvas)
        let expectedPan = ZoomPlacement(scale: 2,
            x: beforePan.x - delta.width / (canvas.canvasRect.width * 2),
            y: beforePan.y - delta.height / (canvas.canvasRect.height * 2)).clamped
        try zoom(editor.editingState.zoom(at: 0), equals: expectedPan, "pan follows full pointer delta with correct direction")
        try require(editor.draftState != nil && editor.project.undoHistory.isEmpty && editor.editingState.zoomKeyframes.count == 1,
                    "double-click and pan at one instant refine the same pending edit")
        try require(editor.finishDraft() && editor.project.undoHistory.count == 1 && editor.undoName == "Edit",
                    "leaving the instant persists the combined zoom and pan as one undo entry")
        try await ready(canvas)
        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.undo(), "undo combined framing after reopening")
        try zoom(reopened.project.state.zoom(at: 0), equals: ZoomPlacement(), "reopened undo restores the viewport before zoom and pan")
        try require(reopened.redo(), "redo combined framing after reopening")
        try zoom(reopened.project.state.zoom(at: 0), equals: expectedPan, "reopened redo restores viewport")

        let beforeCancel = editor.project
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: start.x - 70, y: start.y - 30), canvas: canvas, window: window))
        try await Task.sleep(for: .milliseconds(60))
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!)
        canvas.mouseUp(with: mouse(.leftMouseUp, at: start, canvas: canvas, window: window))
        try await ready(canvas)
        try require(editor.project == beforeCancel, "Escape must cancel pan without adding undo or changing source state")

        for (movement, focal) in [(10000.0, 0.25), (-10000.0, 0.75)] {
            let count = editor.project.undoHistory.count
            try await drag(canvas, window: window, from: start, by: CGSize(width: movement, height: movement))
            try await ready(canvas)
            try zoom(editor.editingState.zoom(at: 0), equals: ZoomPlacement(scale: 2, x: focal, y: focal), "pan clamps the viewport at source edges")
            try require(editor.draftState != nil && editor.project.undoHistory.count == count,
                        "clamped pan stays pending after finger release")
            try require(editor.finishDraft() && editor.project.undoHistory.count == count + 1,
                        "clamped pan remains a single saved edit")
            try await ready(canvas)
        }

        let zoomBeforeCamera = editor.project.state.zoom(at: 0)
        let initialCamera = editor.project.state.pipKeyframes[0].placement
        let cameraFrame = initialCamera.frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9.0)
            .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let cameraCenter = CGPoint(x: cameraFrame.midX, y: cameraFrame.midY)
        var count = editor.project.undoHistory.count
        canvas.mouseDown(with: mouse(.leftMouseDown, at: cameraCenter, canvas: canvas, window: window, clicks: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: cameraCenter, canvas: canvas, window: window, clicks: 2))
        try await ready(canvas)
        try require(editor.project.undoHistory.count == count, "camera hit target takes precedence over background double-click zoom")
        try await drag(canvas, window: window, from: cameraCenter, by: CGSize(width: 30, height: -20))
        try await ready(canvas)
        try require(editor.draftState != nil && editor.project.undoHistory.count == count,
                    "camera movement has priority over panning and remains a pending edit")
        try zoom(editor.editingState.zoom(at: 0), equals: zoomBeforeCamera, "moving PIP preserves main viewport")
        let pendingCamera = editor.editingState
        let movedCamera = pendingCamera.pipKeyframes[0].placement
        let movedFrame = movedCamera.frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9.0)
            .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let movedCenter = CGPoint(x: movedFrame.midX, y: movedFrame.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: movedCenter, canvas: canvas, window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: movedCenter, canvas: canvas, window: window))
        try await ready(canvas)
        try require(editor.draftState == pendingCamera && editor.project.undoHistory.count == count,
                    "a no-op camera click must preserve the unfinished combined draft")
        try require(editor.finishDraft() && editor.project.undoHistory.count == count + 1 && editor.undoName == "Edit",
                    "leaving the camera edit persists exactly one undo entry")
        try await ready(canvas)
        count = editor.project.undoHistory.count
        try await drag(canvas, window: window, from: CGPoint(x: movedFrame.maxX, y: movedFrame.maxY),
                       by: CGSize(width: 25, height: 10))
        try await ready(canvas)
        try require(editor.draftState != nil && editor.project.undoHistory.count == count,
                    "PIP corner resizing remains available while main view is zoomed and stays pending")
        try zoom(editor.editingState.zoom(at: 0), equals: zoomBeforeCamera, "resizing PIP preserves main viewport")
        try require(editor.finishDraft() && editor.project.undoHistory.count == count + 1 && editor.undoName == "Edit",
                    "leaving the resized framing creates one reversible edit")
        try await ready(canvas)

        canvas.mouseDown(with: mouse(.leftMouseDown, at: zoomPoint, canvas: canvas, window: window, clicks: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: zoomPoint, canvas: canvas, window: window, clicks: 2))
        try await ready(canvas)
        try zoom(editor.editingState.zoom(at: 0), equals: ZoomPlacement(), "double-click zoom out returns to full recording")
        try require(editor.draftState != nil && editor.finishDraft() && editor.undoName == "Edit",
                    "zoom-out finalizes as a normal reversible framing edit")
        try await ready(canvas)
        try rect(host.convert(canvas.bounds, from: canvas), equals: baseline, "inspector switches cannot move or resize preview")
        try rect(window.frame, equals: baselineWindow, "zoom/camera inspectors cannot resize editor window")
        let screenAfter = try Data(contentsOf: screenURL), cameraAfter = try Data(contentsOf: cameraURL)
        try require(screenAfter == screenBytes && cameraAfter == cameraBytes, "all zoom/pan/PIP gestures must preserve original media")
        print("Zoom interaction checks passed (real editor double-click zoom, full-delta pan/clamps, Escape, PIP priority, undo/reopen, and stable inspector layout).")
    }

    private static func ready(_ canvas: EditorCanvasView) async throws {
        try await Task.sleep(for: .milliseconds(80))
        let deadline = Date().addingTimeInterval(10)
        while !canvas.allowsZoomEditing || canvas.playerLayer.player?.currentItem?.status != .readyToPlay || canvas.stillLayer.contents == nil {
            consumeFrame(from: canvas.playerLayer.player)
            guard Date() < deadline else {
                throw ZoomInteractionError.failed("valid editor preview did not settle: allows=\(canvas.allowsZoomEditing), itemStatus=\(String(describing: canvas.playerLayer.player?.currentItem?.status)), itemError=\(String(describing: canvas.playerLayer.player?.currentItem?.error)), still=\(canvas.stillLayer.contents != nil), zoom=\(canvas.zoom)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// An offscreen layer does not request display frames. Pull through a real
    /// video output so this fixture exercises the same native compositor path
    /// as the visible app instead of opening a separate still-image decoder.
    private static func consumeFrame(from player: AVPlayer?) {
        guard let player, let item = player.currentItem else { return }
        if outputItem !== item {
            if let outputItem, let output { outputItem.remove(output) }
            let sink = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(sink)
            outputItem = item
            output = sink
        }
        autoreleasepool {
            guard let output else { return }
            let position = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: position) {
                _ = output.copyPixelBuffer(forItemTime: position, itemTimeForDisplay: nil)
            }
        }
    }

    private static func drag(_ canvas: EditorCanvasView, window: NSWindow, from start: CGPoint, by delta: CGSize) async throws {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        for step in 1...4 {
            canvas.mouseDragged(with: mouse(.leftMouseDragged,
                at: CGPoint(x: start.x + delta.width * Double(step) / 4, y: start.y + delta.height * Double(step) / 4),
                canvas: canvas, window: window))
            try await Task.sleep(for: .milliseconds(20))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: start.x + delta.width, y: start.y + delta.height), canvas: canvas, window: window))
    }

    private static func sourcePoint(x: Double, y: Double, canvas: EditorCanvasView) -> CGPoint {
        CGPoint(x: canvas.canvasRect.minX + canvas.canvasRect.width * x,
                y: canvas.canvasRect.minY + canvas.canvasRect.height * y)
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, canvas: NSView,
                              window: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }

    private static func find<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(in: $0) as T? }.first
    }

    private static func zoom(_ actual: ZoomPlacement, equals expected: ZoomPlacement, _ message: String) throws {
        try require(abs(actual.scale - expected.scale) < 0.000_01 && abs(actual.x - expected.x) < 0.000_01 &&
                    abs(actual.y - expected.y) < 0.000_01, "\(message): \(actual) != \(expected)")
    }

    private static func rect(_ actual: CGRect, equals expected: CGRect, _ message: String) throws {
        try require(abs(actual.minX - expected.minX) < 0.5 && abs(actual.minY - expected.minY) < 0.5 &&
                    abs(actual.width - expected.width) < 0.5 && abs(actual.height - expected.height) < 0.5, message)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ZoomInteractionError.failed(message) }
    }
}
