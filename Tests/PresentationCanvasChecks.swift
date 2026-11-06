@preconcurrency import AVFoundation
import AppKit

private final class PresentationGestureEvent: NSEvent {
    var amount = 0.0, dx = 0.0, dy = 0.0
    var position = CGPoint.zero
    var eventPhase: NSEvent.Phase = []
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var locationInWindow: NSPoint { position }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { [] }
}

@main
@MainActor
struct PresentationCanvasChecks {
    enum Failure: Error { case failed(String) }
    static func main() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 800, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = canvas
        defer { window.close() }
        let player = AVPlayer(), source = CGSize(width: 1920, height: 1080)
        let frame = canvas.frame
        let touch = PresentationGestureEvent()
        var zoomCommits: [ZoomPlacement] = [], cameraCommits: [PIPPlacement] = []
        var cameraPreviews: [PIPPlacement] = []
        var cameraBegins = 0
        canvas.onZoomCommit = { next, _ in zoomCommits.append(next) }
        canvas.onBegin = { cameraBegins += 1 }
        canvas.onPreview = { cameraPreviews.append($0) }
        canvas.onCommit = { next, _ in cameraCommits.append(next) }
        func configure(_ presentation: CanvasPresentation, zoom: ZoomPlacement = ZoomPlacement(),
                       placement: PIPPlacement = PIPPlacement(), camera: Bool = false) {
            // The saved render's output size can lag a live presentation draft.
            // Native geometry must follow presentation + original source size.
            canvas.configure(player: player, image: nil, sourceSize: source,
                cameraAspect: 2, placement: placement, cameraEnabled: camera, zoom: zoom,
                presentation: presentation, nativeSourceSize: source)
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        func pinch(_ amount: Double, at point: CGPoint, phase: NSEvent.Phase) {
            touch.amount = amount; touch.position = canvas.convert(point, to: nil); touch.eventPhase = phase
            canvas.magnify(with: touch)
        }
        for aspect in CanvasAspect.allCases {
            let presentation = CanvasPresentation(aspect: aspect, padding: 0.1, cornerRadius: 0.12)
            let geometry = PresentationGeometry(sourceSize: source, presentation: presentation)
            configure(presentation)
            try rect(canvas.canvasRect, geometry.outputRect(in: canvas.bounds), "output/PIP surface follows selected aspect")
            try rect(canvas.contentRect, geometry.contentRect(in: canvas.bounds), "source surface stays fitted inside output padding")
            try rect(canvas.playerLayer.frame, canvas.canvasRect, "decoded presentation image fits the output surface")
            let sourcePoint = CGPoint(x: canvas.contentRect.minX + canvas.contentRect.width * 0.75,
                                      y: canvas.contentRect.minY + canvas.contentRect.height * 0.25)
            pinch(1, at: sourcePoint, phase: .began)
            try zoom(canvas.zoom, ZoomPlacement(scale: 2, x: 0.625, y: 0.375), "pinch anchors inside the source, independently of canvas margins")
            configure(presentation)
            try zoom(canvas.zoom, ZoomPlacement(scale: 2, x: 0.625, y: 0.375), "paused-frame reconfiguration cannot reset an active pinch")
            pinch(0, at: sourcePoint, phase: .ended)
            configure(presentation, zoom: ZoomPlacement(scale: 2))
            let center = CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.midY)
            touch.position = canvas.convert(center, to: nil)
            touch.dx = 20; touch.dy = 10; touch.eventPhase = .began
            canvas.scrollWheel(with: touch)
            try zoom(canvas.zoom, ZoomPlacement(scale: 2,
                x: 0.5 + 20 / (canvas.contentRect.width * 2),
                y: 0.5 - 10 / (canvas.contentRect.height * 2)), "two-finger pan uses source-surface dimensions and the confirmed direction")
            touch.dx = 0; touch.dy = 0; touch.eventPhase = .ended
            canvas.scrollWheel(with: touch)
            configure(presentation, zoom: ZoomPlacement(scale: 2))
            canvas.mouseDown(with: mouse(.leftMouseDown, center))
            let dragged = CGPoint(x: center.x + 20, y: center.y + 10)
            canvas.mouseDragged(with: mouse(.leftMouseDragged, dragged))
            canvas.mouseUp(with: mouse(.leftMouseUp, dragged))
            try zoom(canvas.zoom, ZoomPlacement(scale: 2,
                x: 0.5 - 20 / (canvas.contentRect.width * 2),
                y: 0.5 - 10 / (canvas.contentRect.height * 2)), "mouse drag pans source pixels under the pointer")
            configure(presentation)
            canvas.mouseDown(with: mouse(.leftMouseDown, sourcePoint, clicks: 2))
            try zoom(canvas.zoom, ZoomPlacement(scale: 2, x: 0.75, y: 0.25), "double-click centers the clicked source location")
            configure(presentation)
            let margin = CGPoint(x: canvas.canvasRect.minX + 1, y: canvas.canvasRect.minY + 1)
            pinch(1, at: margin, phase: .began)
            pinch(0, at: margin, phase: .ended)
            try zoom(canvas.zoom, ZoomPlacement(scale: 2, x: 0.25, y: 0.25), "pinching a canvas margin clamps to the nearest source edge")
            configure(presentation)
            let commits = zoomCommits.count
            touch.position = canvas.convert(margin, to: nil)
            touch.dx = 20; touch.dy = 10; touch.eventPhase = []
            canvas.scrollWheel(with: touch)
            try require(canvas.zoom == ZoomPlacement() && zoomCommits.count == commits,
                        "source at 1× cannot acquire a pan edit")
            try require(canvas.frame == frame && canvas.playerLayer.player === player,
                        "presentation changes never relayout the view or replace its player")
        }
        let portrait = CanvasPresentation(aspect: .portrait, padding: 0.1)
        let initial = PIPPlacement(x: 0.1, y: 0.1, scale: 0.25)
        configure(portrait, placement: initial, camera: true)
        let pip = initial.frame(in: canvas.canvasRect.size, cameraAspect: 2)
            .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let center = CGPoint(x: pip.midX, y: pip.midY)
        try require(!canvas.contentRect.contains(center), "fixture camera sits in a canvas margin")
        canvas.mouseDown(with: mouse(.leftMouseDown, center))
        let moved = CGPoint(x: center.x + 10, y: center.y + 15)
        canvas.mouseDragged(with: mouse(.leftMouseDragged, moved))
        canvas.mouseUp(with: mouse(.leftMouseUp, moved))
        guard let placement = cameraCommits.last else { throw Failure.failed("camera margin drag") }
        let movedFrame = placement.frame(in: canvas.canvasRect.size, cameraAspect: 2)
        try near(movedFrame.minX - (pip.minX - canvas.canvasRect.minX), 10, "camera drag translates in full output width")
        try near(movedFrame.minY - (pip.minY - canvas.canvasRect.minY), 15, "camera drag translates in full output height")
        try require(cameraBegins == 1 && cameraPreviews.count == 1 && cameraCommits.count == 1,
                    "camera retains mouse priority in canvas margins")
        configure(portrait, placement: placement, camera: true)
        let cameraFrame = placement.frame(in: canvas.canvasRect.size, cameraAspect: 2)
            .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let corner = CGPoint(x: cameraFrame.maxX, y: cameraFrame.maxY)
        canvas.mouseDown(with: mouse(.leftMouseDown, corner))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: corner.x + 12, y: corner.y + 6)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: corner.x + 12, y: corner.y + 6)))
        guard let resized = cameraCommits.last else { throw Failure.failed("camera resize") }
        let resizedFrame = resized.frame(in: canvas.canvasRect.size, cameraAspect: 2)
        try require(resizedFrame.width > movedFrame.width && CGRect(origin: .zero, size: canvas.canvasRect.size).contains(resizedFrame),
                    "camera resizing is bounded by the complete output, not the source surface")
        try near(resizedFrame.minX, movedFrame.minX, "resizing in a margin preserves opposite horizontal corner")
        try near(resizedFrame.minY, movedFrame.minY, "resizing in a margin preserves opposite vertical corner")
        try require(canvas.stillLayer.animationKeys()?.isEmpty != false && canvas.playerLayer.animationKeys()?.isEmpty != false,
                    "presentation updates use no implicit layer animations")
        print("Presentation canvas checks passed (all output aspects, source bounds, pinch anchors, pan/double-click mapping, margin gestures, PIP drag/resize, stable layout/player, and no implicit animations).")
    }

    private static func zoom(_ actual: ZoomPlacement, _ expected: ZoomPlacement, _ context: String) throws {
        try near(actual.scale, expected.scale, context); try near(actual.x, expected.x, context); try near(actual.y, expected.y, context)
    }
    private static func rect(_ actual: CGRect, _ expected: CGRect, _ context: String) throws {
        try near(actual.minX, expected.minX, context); try near(actual.minY, expected.minY, context)
        try near(actual.width, expected.width, context); try near(actual.height, expected.height, context)
    }
    private static func near(_ actual: Double, _ expected: Double, _ context: String) throws {
        try require(abs(actual - expected) < 0.000001, "\(context): \(actual), expected \(expected)")
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
    }
}
