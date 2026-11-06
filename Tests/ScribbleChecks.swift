@preconcurrency import AVFoundation
import AppKit
import Combine

// EditorCanvas's representable uses a frame store, but these tests never create
// images or a player item. Exercise only vector guides and native mouse logic.
@MainActor
final class EditorFrameStore: ObservableObject {
    @Published var image: CGImage?
}

private enum ScribbleCheckError: Error { case failed(String) }

@main
@MainActor
struct ScribbleChecks {
    static func main() throws {
        try checkGeometry()
        try checkNativeCanvas()
        print("Scribble checks passed (source-coordinate round trips, clipping, minimum size, empty native canvas, selection, Escape, and gesture mode boundaries).")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ScribbleCheckError.failed(message) }
    }
    private static func near(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 1e-8 }

    private static func checkGeometry() throws {
        let content = CGRect(x: 40, y: 20, width: 800, height: 450)
        for placement in [ZoomPlacement(), ZoomPlacement(scale: 2, x: 0.4, y: 0.5),
                          ZoomPlacement(scale: 3, x: 0.85, y: 0.85).clamped] {
            let geometry = ScribbleGeometry(contentRect: content, zoom: placement)
            let start = CGPoint(x: 80, y: 80), end = CGPoint(x: 600, y: 330)
            guard let region = geometry.region(from: start, to: end) else { throw ScribbleCheckError.failed("draw region") }
            let rect = geometry.viewRect(region)
            try require(near(rect.minX, start.x) && near(rect.minY, start.y) && near(rect.maxX, end.x) && near(rect.maxY, end.y),
                        "guides round-trip through zoomed source coordinates and output padding")
            try require(geometry.sourcePoint(CGPoint(x: 39, y: 50)) == nil,
                        "source guides cannot start in output padding")
            let reverse = geometry.region(from: end, to: start)
            try require(reverse == region, "drawing direction cannot change saved region")
        }
        let geometry = ScribbleGeometry(contentRect: content, zoom: ZoomPlacement())
        try require(geometry.region(from: CGPoint(x: 80, y: 80), to: CGPoint(x: 82, y: 82)) == nil,
                    "clicks and small movements cannot create an area")
        try require(geometry.region(from: CGPoint(x: 838, y: 468), to: CGPoint(x: 1000, y: 700)) == nil,
                    "a long pointer movement outside the frame cannot create a tiny clipped guide")
        let clipped = geometry.region(from: CGPoint(x: 80, y: 80), to: CGPoint(x: 1000, y: 700))
        try require(clipped?.isValid == true && near(clipped!.rectMaxX, 1) && near(clipped!.rectMaxY, 1),
                    "large areas clip to the original frame")
    }

    private static func checkNativeCanvas() throws {
        try require(MediaProcessing.isSuspended, "native vector test requires video interlock")
        _ = NSApplication.shared
        let player = AVPlayer()
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = canvas
        defer { window.close() }
        func configure(zoom: ZoomPlacement = ZoomPlacement(), camera: Bool = false) {
            canvas.configure(player: player, image: nil, sourceSize: CGSize(width: 1920, height: 1080),
                cameraAspect: 16.0 / 9.0, placement: PIPPlacement(), cameraEnabled: camera, zoom: zoom)
            canvas.layoutSubtreeIfNeeded()
        }
        configure()
        try require(canvas.playerLayer.player == nil && canvas.stillLayer.contents == nil,
                    "no media reaches the suspended canvas")
        var drawn: [EditorRegionRect] = []
        var selected: UUID?
        var zoomCommits = 0
        var cameraCommits = 0
        canvas.onDrawRegion = { drawn.append($0) }
        canvas.onSelectRegion = { selected = $0 }
        canvas.onZoomCommit = { _, _ in zoomCommits += 1 }
        canvas.onCommit = { _, _ in cameraCommits += 1 }
        canvas.scribbleMode = true
        let start = CGPoint(x: 80, y: 90), end = CGPoint(x: 200, y: 180)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, canvas: canvas, window: window))
        try require(drawn.isEmpty, "scribble movement is transient until mouse up")
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end, canvas: canvas, window: window))
        try require(drawn.count == 1 && zoomCommits == 0 && cameraCommits == 0,
                    "drawing cannot pan or move the camera")
        let guide = EditorRegion(time: 0, rect: drawn[0])
        canvas.regions = [guide]
        let inside = CGPoint(x: 120, y: 130)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: inside, canvas: canvas, window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: inside, canvas: canvas, window: window))
        try require(selected == guide.id && drawn.count == 1, "clicking a guide selects rather than duplicates it")
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, canvas: canvas, window: window))
        canvas.cancelOperation(nil)
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end, canvas: canvas, window: window))
        try require(drawn.count == 1, "Escape discards unfinished scribble")

        canvas.scribbleMode = false
        configure(zoom: ZoomPlacement(scale: 2))
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, canvas: canvas, window: window))
        canvas.scribbleMode = true
        configure()
        try require(canvas.zoom == ZoomPlacement(), "entering Scribble releases transient native pan state")
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end, canvas: canvas, window: window))
        try require(zoomCommits == 0, "old pan cannot commit after switching gesture modes")

        canvas.scribbleMode = false
        configure(camera: true)
        let cameraFrame = PIPPlacement().frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9.0)
            .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let cameraStart = CGPoint(x: cameraFrame.midX, y: cameraFrame.midY)
        let cameraEnd = CGPoint(x: cameraStart.x - 40, y: cameraStart.y - 20)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: cameraStart, canvas: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: cameraEnd, canvas: canvas, window: window))
        canvas.scribbleMode = true
        configure(camera: true)
        canvas.mouseUp(with: mouse(.leftMouseUp, at: cameraEnd, canvas: canvas, window: window))
        try require(cameraCommits == 0, "old camera drag cannot commit after switching gesture modes")
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, canvas: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
}

private extension EditorRegionRect {
    var rectMaxX: Double { x + width }
    var rectMaxY: Double { y + height }
}
