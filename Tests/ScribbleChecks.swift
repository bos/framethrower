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
        print("Scribble checks passed (source-coordinate round trips, clipping, minimum size, numbered guide badges, linked selection, badge hit targets, empty native canvas, Escape, and gesture mode boundaries).")
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
        var referenceBegins = 0
        canvas.onReferenceBegin = { referenceBegins += 1 }
        canvas.onDrawRegion = { drawn.append($0) }
        canvas.onSelectRegion = { selected = $0 }
        canvas.onZoomCommit = { _, _ in zoomCommits += 1 }
        canvas.onCommit = { _, _ in cameraCommits += 1 }
        canvas.scribbleMode = true
        let start = CGPoint(x: 80, y: 90), end = CGPoint(x: 200, y: 180)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        try require(referenceBegins == 1, "new reference gestures notify planning cancellation before the first drag sample")
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, canvas: canvas, window: window))
        try require(drawn.isEmpty, "scribble movement is transient until mouse up")
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end, canvas: canvas, window: window))
        try require(drawn.count == 1 && zoomCommits == 0 && cameraCommits == 0,
                    "drawing cannot pan or move the camera")
        let guide = EditorRegion(time: 0, rect: drawn[0])
        canvas.regions = [guide]
        canvas.regionLabels = [guide.id: "Box 1"]
        configure()
        let inside = CGPoint(x: 120, y: 130)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: inside, canvas: canvas, window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: inside, canvas: canvas, window: window))
        try require(selected == guide.id && drawn.count == 1, "clicking a guide selects rather than duplicates it")
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, canvas: canvas, window: window))
        canvas.cancelOperation(nil)
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end, canvas: canvas, window: window))
        try require(drawn.count == 1, "Escape discards unfinished scribble")

        let other = EditorRegion(time: 0, rect: EditorRegionRect(x: 0.7, y: 0.2, width: 0.2, height: 0.3))
        let edge = EditorRegion(time: 0, rect: EditorRegionRect(x: 0.97, y: 0.9, width: 0.03, height: 0.1))
        canvas.regions = [edge, other, guide]
        canvas.regionLabels = [guide.id: "Box 1", other.id: "Box 7", edge.id: "Box 12"]
        canvas.selectedRegionID = other.id
        configure()
        try require(Set(canvas.guideBadges.map(\.label)) == ["Box 1", "Box 7", "Box 12"],
                    "preview labels use durable references rather than current array indices")
        try require(canvas.guideBadges.first(where: { $0.selected })?.regionID == other.id,
                    "sidebar selection highlights the matching preview badge")
        try require(canvas.guideBadges.allSatisfy { canvas.contentRect.contains($0.frame) },
                    "badges remain fully visible inside the recording even for clipped edge guides")
        let badge = canvas.guideBadges.first { $0.regionID == edge.id }!
        let badgePoint = CGPoint(x: badge.frame.midX, y: badge.frame.midY)
        let beginsBeforeBadge = referenceBegins
        canvas.mouseDown(with: mouse(.leftMouseDown, at: badgePoint, canvas: canvas, window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: badgePoint, canvas: canvas, window: window))
        try require(selected == edge.id && drawn.count == 1,
                    "clicking a badge outside its small box selects that box instead of drawing another")
        try require(referenceBegins == beginsBeforeBadge, "selecting an existing reference badge cannot cancel a planning request")
        canvas.selectedRegionID = selected
        configure()
        try require(canvas.guideBadges.first(where: { $0.selected })?.label == "Box 12",
                    "preview selection round-trips to the same durable reference")
        let nested = EditorRegion(time: 0, rect: guide.rect)
        let third = EditorRegion(time: 0, rect: guide.rect)
        canvas.regions = [guide, nested, third]
        canvas.regionLabels = [guide.id: "Box 1", nested.id: "Box 2", third.id: "Box 3"]
        canvas.selectedRegionID = guide.id
        configure()
        let packed = canvas.guideBadges
        try require(packed.count == 3 && !packed[0].frame.intersects(packed[1].frame) &&
                    !packed[0].frame.intersects(packed[2].frame) && !packed[1].frame.intersects(packed[2].frame),
                    "nested boxes sharing an origin must retain distinct readable number badges")
        for badge in packed {
            let point = CGPoint(x: badge.frame.midX, y: badge.frame.midY)
            canvas.mouseDown(with: mouse(.leftMouseDown, at: point, canvas: canvas, window: window))
            canvas.mouseUp(with: mouse(.leftMouseUp, at: point, canvas: canvas, window: window))
            try require(selected == badge.regionID, "each packed badge selects its own box")
        }
        canvas.selectedRegionID = third.id
        configure()
        try require(canvas.guideBadges.map(\.frame) == packed.map(\.frame),
                    "selection changes highlight guides without shifting their number badges")

        let outside = EditorRegion(time: 0, rect: EditorRegionRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05))
        canvas.regions = [guide, outside]
        canvas.regionLabels = [guide.id: "Box 1", outside.id: "Box 9"]
        canvas.selectedRegionID = outside.id
        configure(zoom: ZoomPlacement(scale: 3))
        guard let edgeBadge = canvas.guideBadges.first(where: { $0.regionID == outside.id }) else {
            throw ScribbleCheckError.failed("offscreen reference badge missing")
        }
        try require(edgeBadge.outsideViewport && canvas.contentRect.contains(edgeBadge.frame),
                    "references outside the current zoom remain available as boundary badges")
        let edgePoint = CGPoint(x: edgeBadge.frame.midX, y: edgeBadge.frame.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: edgePoint, canvas: canvas, window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: edgePoint, canvas: canvas, window: window))
        try require(selected == outside.id, "a boundary badge selects its offscreen reference")

        canvas.scribbleMode = false
        configure(zoom: ZoomPlacement(scale: 2))
        try require(canvas.guideBadges.isEmpty && canvas.accessibilityValue() == nil,
                    "exiting Scribble clears visible and accessibility guide labels")
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
