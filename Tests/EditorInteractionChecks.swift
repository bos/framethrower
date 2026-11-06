import AppKit
import SwiftUI

private enum InteractionCheckError: Error { case failed(String) }

/// Hosts the actual production editor interactions in an offscreen native window.
/// These tests require no capture permission, camera, or account.
@main
@MainActor
struct EditorInteractionChecks {
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenBytes = Data("original screen source placeholder".utf8)
        let cameraBytes = Data("original camera source placeholder".utf8)
        let screen = directory.appendingPathComponent("screen.mp4")
        let camera = directory.appendingPathComponent("camera.mov")
        try screenBytes.write(to: screen)
        try cameraBytes.write(to: camera)

        var project = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mov", duration: 10)
        project.state.pipKeyframes[0].placement = PIPPlacement(x: 0.2, y: 0.2, scale: 0.25,
                                                               shape: .rectangle, aspectRatio: 2)
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("editor.json"))
        try require(editor.save(), "initial project save")
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor))
        let window = makeWindow(content: host, size: CGSize(width: 940, height: 800))
        defer { window.close() }
        await settle()
        host.layoutSubtreeIfNeeded()
        guard let surface: EditorCanvasView = find(in: host) else {
            throw InteractionCheckError.failed("production editor did not create its native player surface")
        }
        let canvas = host.convert(surface.canvasRect, from: surface)
        let initial = project.state.pipKeyframes[0].placement
        let originalFrame = initial.frame(in: canvas.size, cameraAspect: 16.0 / 9.0)
        let baselineFittingSize = host.fittingSize
        let baselineWindowSize = window.frame.size
        for corner in PIPResizeCorner.allCases {
            let isRight = corner == .topRight || corner == .bottomRight
            let isBottom = corner == .bottomLeft || corner == .bottomRight
            let resizeStart = CGPoint(x: canvas.minX + (isRight ? originalFrame.maxX : originalFrame.minX),
                                      y: canvas.minY + (isBottom ? originalFrame.maxY : originalFrame.minY))
            let resizeDelta = CGSize(width: isRight ? 40 : -40, height: isBottom ? 10 : -10)
            try await drag(in: window, host: host, from: resizeStart, by: resizeDelta)
            try require(editor.draftState != nil && editor.project.undoHistory.isEmpty,
                        "each corner resize stays in one pending draft after release")
            let expectedResize = initial.resized(by: resizeDelta, corner: corner, in: canvas.size, cameraAspect: 16.0 / 9.0)
            try placement(editor.editingState.pipKeyframes[0].placement, equals: expectedResize,
                          "every resize handle must use the full pointer delta")
            try require(editor.finishDraft() && editor.project.undoHistory.count == 1 && editor.undoName == "Edit",
                        "leaving each resized framing produces one undo entry without also moving the camera")
            let reopened = try ProjectEditor.open(url: editor.url)
            try require(reopened.project == editor.project, "native resize and its undo history must survive reopen")
            try require(editor.undo(), "undo native resize")
            try placement(editor.project.state.pipKeyframes[0].placement, equals: initial, "undo restores initial framing")
            try require(editor.redo(), "redo native resize")
            try placement(editor.project.state.pipKeyframes[0].placement, equals: expectedResize, "redo restores resize")
            try require(editor.undo(), "restore initial geometry before next corner resize")
            await settle()
            try size(host.fittingSize, equals: baselineFittingSize, "resize must not rearrange editor fitting size")
            try size(window.frame.size, equals: baselineWindowSize, "resize must not resize its native window")
        }

        let moveStart = CGPoint(x: canvas.minX + originalFrame.midX, y: canvas.minY + originalFrame.midY)
        let moveDelta = CGSize(width: 40, height: -20)
        try await drag(in: window, host: host, from: moveStart, by: moveDelta)
        try require(editor.draftState != nil && editor.project.undoHistory.isEmpty,
                    "a move drag remains pending without creating intermediate undo entries")
        var expectedMove = initial
        expectedMove.x += moveDelta.width / (canvas.width - originalFrame.width)
        expectedMove.y += moveDelta.height / (canvas.height - originalFrame.height)
        try placement(editor.editingState.pipKeyframes[0].placement, equals: expectedMove,
                      "moving camera must use the entire pointer delta")
        try require(editor.finishDraft() && editor.project.undoHistory.count == 1 && editor.undoName == "Edit",
                    "leaving the moved framing creates exactly one undo entry")
        try require(editor.project.redoHistory.isEmpty, "a new gesture invalidates the prior redo branch")
        let movedReopen = try ProjectEditor.open(url: editor.url)
        try require(movedReopen.undo(), "undo native move after reopening")
        try placement(movedReopen.project.state.pipKeyframes[0].placement, equals: initial,
                      "reopened move undo restores original placement")

        guard let timeline: RecordingTimelineView = find(in: host) else {
            throw InteractionCheckError.failed("production editor did not create its native timeline")
        }
        let trimHistoryCount = editor.project.undoHistory.count
        let trimStart = CGPoint(x: timeline.x(for: 0) + 4, y: 24)
        let trimEnd = CGPoint(x: trimStart.x + (timeline.bounds.width - 24) / 10, y: 24)
        func trimEvent(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        timeline.mouseDown(with: trimEvent(.leftMouseDown, at: trimStart))
        timeline.mouseDragged(with: trimEvent(.leftMouseDragged, at: trimEnd))
        try require(editor.project.undoHistory.count == trimHistoryCount,
                    "native trim cannot persist intermediate drag states")
        timeline.mouseUp(with: trimEvent(.leftMouseUp, at: trimEnd))
        try require(editor.project.undoHistory.count == trimHistoryCount + 1 && editor.undoName == "Trim",
                    "native timeline must persist one trim edit on release")
        try near(editor.project.state.trimStart, 1, "native trim callback updates the editor")
        try placement(editor.project.state.pipKeyframes[0].placement, equals: expectedMove,
                      "trimming preserves camera geometry")
        let trimmedReopen = try ProjectEditor.open(url: editor.url)
        try require(trimmedReopen.undo(), "undo native trim after reopening")
        try near(trimmedReopen.project.state.trimStart, 0, "reopened trim undo restores discarded source range")
        try require(trimmedReopen.redo(), "redo native trim after reopening")
        try near(trimmedReopen.project.state.trimStart, 1, "reopened redo restores trim")

        var withPoint = editor.project.state
        withPoint.pipKeyframes.append(PIPKeyframe(time: 5, placement: initial))
        try require(editor.commit(withPoint, name: "Add camera point"), "add first nonzero point for layout check")
        await settle()
        try size(host.fittingSize, equals: baselineFittingSize, "first nonzero point must not grow the editor")
        try require(timeline.edits.count == 1 && timeline.edits[0].time == 5,
                    "camera changes appear in the shared edit timeline")
        let editPoint = CGPoint(x: timeline.x(for: 5), y: 47)
        timeline.mouseDown(with: trimEvent(.leftMouseDown, at: editPoint))
        timeline.mouseUp(with: trimEvent(.leftMouseUp, at: editPoint))
        await settle()
        try require(timeline.selectedEditID == withPoint.pipKeyframes[1].id,
                    "clicking the camera diamond selects its unified edit")
        try size(host.fittingSize, equals: baselineFittingSize, "selecting a nonzero point must keep stable controls height")
        var smoothPoint = editor.project.state
        smoothPoint.pipKeyframes[1].transition = .smooth
        try require(editor.commit(smoothPoint, name: "Smooth camera point"), "set Smooth transition for layout check")
        await settle()
        try size(host.fittingSize, equals: baselineFittingSize, "showing Smooth duration must not rearrange the editor")
        try size(window.frame.size, equals: baselineWindowSize, "point details and duration must not resize the editor window")

        try await checkCrop(in: directory)
        let screenAfter = try Data(contentsOf: screen)
        let cameraAfter = try Data(contentsOf: camera)
        try require(screenAfter == screenBytes && cameraAfter == cameraBytes,
                    "native geometry gestures must preserve source media bytes")
        print("Editor interaction checks passed (production move/resize/crop gestures, full pointer deltas, single undo groups, persistence, and unchanged sources).")
    }

    private static func checkCrop(in directory: URL) async throws {
        var project = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mov", duration: 10)
        project.state.pipKeyframes[0].placement.shape = .square
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("crop.json"))
        try require(editor.save(), "initial crop project save")
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = context.makeImage()!
        let host = NSHostingView(rootView: CropProbe(editor: editor, image: image))
        let window = makeWindow(content: host, size: CGSize(width: 392, height: 340))
        defer { window.close() }
        await settle()
        // Production framing presents a 360x180 image with 16pt padding and a
        // heading above it. This point is safely inside its centered crop.
        let center = CGPoint(x: 196, y: 135)
        try await drag(in: window, host: host, from: center, by: CGSize(width: 36, height: 0))
        try require(editor.draftState != nil && editor.project.undoHistory.isEmpty,
                    "crop drag refines a pending framing edit after release")
        let crop = editor.editingState.pipKeyframes[0].placement.crop
        try near(crop.x, 0.7, "crop must use full pointer delta: 36 display pixels = 20 source pixels")
        try near(crop.y, 0.5, "crop axis with no travel must remain unchanged")
        try require(editor.finishDraft() && editor.project.undoHistory.count == 1 && editor.undoName == "Edit",
                    "leaving the crop edit commits exactly one undo step")
        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.undo(), "undo crop after reopening")
        try require(reopened.project.state.pipKeyframes[0].placement.crop == PIPCrop(), "crop undo restores center")
        try require(reopened.redo(), "redo crop after reopening")
        try near(reopened.project.state.pipKeyframes[0].placement.crop.x, 0.7, "redo restores framing")
    }

    private struct CropProbe: View {
        @ObservedObject var editor: ProjectEditor
        let image: CGImage
        var body: some View {
            CameraFramingPopover(image: image, errorMessage: nil,
                                 placement: editor.editingState.pipKeyframes[0].placement) { crop in
                var state = editor.editingState
                state.pipKeyframes[0].placement.crop = crop
                editor.updateDraft(state, at: 0)
            }
        }
    }

    private static func makeWindow<Content: View>(content: NSHostingView<Content>, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        return window
    }

    private static func drag<Content: View>(in window: NSWindow, host: NSHostingView<Content>,
                                           from start: CGPoint, by delta: CGSize) async throws {
        func send(_ type: NSEvent.EventType, point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            if let canvas: EditorCanvasView = find(in: host),
               host.convert(canvas.bounds, from: canvas).contains(point) {
                switch type {
                case .leftMouseDown: canvas.mouseDown(with: event)
                case .leftMouseDragged: canvas.mouseDragged(with: event)
                case .leftMouseUp: canvas.mouseUp(with: event)
                default: break
                }
            } else { window.sendEvent(event) }
        }
        send(.leftMouseDown, point: start)
        for step in 1...4 {
            let fraction = Double(step) / 4
            send(.leftMouseDragged, point: CGPoint(x: start.x + delta.width * fraction,
                                                   y: start.y + delta.height * fraction))
            try await Task.sleep(for: .milliseconds(20))
        }
        send(.leftMouseUp, point: CGPoint(x: start.x + delta.width, y: start.y + delta.height))
        await settle()
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    private static func find<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(in: $0) as T? }.first
    }

    private static func placement(_ actual: PIPPlacement, equals expected: PIPPlacement, _ message: String) throws {
        try near(actual.x, expected.x, message)
        try near(actual.y, expected.y, message)
        try near(actual.scale, expected.scale, message)
        try near(actual.aspectRatio, expected.aspectRatio, message)
        try require(actual.shape == expected.shape && actual.crop == expected.crop && actual.visible == expected.visible, message)
    }

    private static func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        // SwiftUI retains fractional layout widths while NSView reports a
        // pixel-aligned player surface. This tolerance is under a tenth of a
        // preview pixel and still catches gesture-delta feedback decisively.
        try require(abs(actual - expected) < 0.000_1, "\(message): \(actual) != \(expected)")
    }

    private static func size(_ actual: CGSize, equals expected: CGSize, _ message: String) throws {
        try require(abs(actual.width - expected.width) < 0.5 && abs(actual.height - expected.height) < 0.5,
                    "\(message): \(actual) != \(expected)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw InteractionCheckError.failed(message) }
    }
}
