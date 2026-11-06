import AppKit
import AVFoundation

private enum TrackpadCheckError: Error { case failed(String) }

/// Exercises production AppKit handlers without a camera, input monitoring,
/// recording, or a video decoder. These events are delivered only to the fixture.
private final class TrackpadEvent: NSEvent {
    var kind: NSEvent.EventType = .magnify
    var eventPhase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    var amount = 0.0
    var dx = 0.0
    var dy = 0.0
    var precise = true
    var inverted = false
    var position = CGPoint.zero
    override var type: NSEvent.EventType { kind }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { inverted }
    override var locationInWindow: NSPoint { position }
}

@main
@MainActor
struct EditorTrackpadChecks {
    static func main() throws {
        _ = NSApplication.shared
        let canvas = EditorCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 450))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 800, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        let player = AVPlayer()
        let camera = PIPPlacement()
        func configure(_ zoom: ZoomPlacement) {
            canvas.configure(player: player, image: nil, sourceSize: CGSize(width: 1600, height: 900),
                             cameraAspect: 16.0 / 9.0, placement: camera, cameraEnabled: true, zoom: zoom)
        }
        configure(ZoomPlacement())
        let bounds = canvas.frame
        var begins = 0, cancels = 0
        var previews: [ZoomPlacement] = [], commits: [ZoomPlacement] = []
        canvas.onZoomBegin = { begins += 1 }
        canvas.onZoomPreview = { previews.append($0) }
        canvas.onZoomCommit = { next, _ in commits.append(next) }
        canvas.onCancel = { cancels += 1 }
        let event = TrackpadEvent()
        let pinchPoint = CGPoint(x: 600, y: 225)
        event.position = canvas.convert(pinchPoint, to: nil)
        event.amount = 0.5
        event.eventPhase = .began
        canvas.magnify(with: event)
        try near(canvas.zoom, ZoomPlacement(scale: 1.5, x: 0.5 + 0.25 - 0.25 / 1.5, y: 0.5), "pinch anchors the source pixel under the fingers")
        let first = canvas.zoom
        configure(ZoomPlacement())
        try near(canvas.zoom, first, "stale frame configuration cannot reset an active pinch")
        event.amount = 1.0 / 3.0
        event.eventPhase = .changed
        canvas.magnify(with: event)
        try near(canvas.zoom, ZoomPlacement(scale: 2, x: 0.625, y: 0.5), "pinch accumulates incremental magnification")
        try require(begins == 1 && commits.isEmpty && previews.count == 2, "pinch previews until its end")
        event.amount = 0
        event.eventPhase = .ended
        canvas.magnify(with: event)
        try require(commits.count == 1 && begins == 1, "one pinch invokes one completed gesture callback")
        configure(commits.last!)

        event.kind = .scrollWheel
        event.eventPhase = .began
        event.dx = 40
        event.dy = 30
        let beforePan = canvas.zoom
        canvas.scrollWheel(with: event)
        let pan = ZoomPlacement(scale: 2, x: beforePan.x + 40 / 1600, y: beforePan.y - 30 / 900)
        try near(canvas.zoom, pan, "positive AppKit deltas advance horizontal source offset and reduce vertical source offset")
        configure(beforePan)
        try near(canvas.zoom, pan, "stale frames cannot reset an active pan")
        event.eventPhase = .ended
        event.dx = 0; event.dy = 0
        canvas.scrollWheel(with: event)
        try require(commits.count == 2, "finger pan completes once")
        event.eventPhase = []
        event.momentum = .began
        event.dx = 20; event.dy = -15
        canvas.scrollWheel(with: event)
        event.momentum = .changed
        canvas.scrollWheel(with: event)
        try require(commits.count == 2, "momentum samples remain previews")
        event.momentum = .ended
        event.dx = 0; event.dy = 0
        canvas.scrollWheel(with: event)
        try near(canvas.zoom, ZoomPlacement(scale: 2, x: pan.x + 40 / 1600, y: pan.y + 30 / 900), "momentum continues the native pan direction without losing its accumulated viewport")
        try require(commits.count == 3, "momentum finishes with one callback")

        event.momentum = []
        event.eventPhase = []
        event.precise = false
        event.dx = 10000; event.dy = 10000
        canvas.scrollWheel(with: event)
        try near(canvas.zoom, ZoomPlacement(scale: 2, x: 0.75, y: 0.25), "legacy wheel panning uses the same direction and is bounded to the source")
        event.dx = -10000; event.dy = -10000
        canvas.scrollWheel(with: event)
        try near(canvas.zoom, ZoomPlacement(scale: 2, x: 0.25, y: 0.75), "negative wheel deltas reverse both axes and clamp at opposite source edges")
        event.kind = .magnify
        event.eventPhase = .began
        event.amount = 100
        canvas.magnify(with: event)
        try require(canvas.zoom.scale == 3, "pinch clamps the maximum magnification")
        event.eventPhase = .changed
        event.amount = -100
        canvas.magnify(with: event)
        try near(canvas.zoom, ZoomPlacement(), "pinch zoom out restores full frame")
        event.eventPhase = .ended
        event.amount = 0
        canvas.magnify(with: event)

        configure(ZoomPlacement(scale: 2))
        event.kind = .scrollWheel
        event.eventPhase = .began
        event.precise = true
        event.dx = 20; event.dy = 10
        canvas.scrollWheel(with: event)
        let commitCount = commits.count
        canvas.cancelOperation(nil)
        try near(canvas.zoom, ZoomPlacement(scale: 2), "Escape restores the active gesture origin")
        try require(cancels == 1 && commits.count == commitCount, "Escape cancels without a completion")
        canvas.cancelOperation(nil)
        try require(cancels == 2, "Escape also forwards cancellation between gestures")

        canvas.allowsZoomEditing = false
        event.amount = 0.2
        canvas.magnify(with: event)
        canvas.scrollWheel(with: event)
        try near(canvas.zoom, ZoomPlacement(scale: 2), "loading or scrubbing disables trackpad editing")
        canvas.allowsZoomEditing = true
        event.position = canvas.convert(CGPoint(x: -10, y: -10), to: nil)
        canvas.magnify(with: event)
        canvas.scrollWheel(with: event)
        try near(canvas.zoom, ZoomPlacement(scale: 2), "gestures must begin inside the recording")
        try require(canvas.frame == bounds && canvas.playerLayer.player === player, "gestures leave native preview geometry and player identity stable")

        let noOpPoint = CGPoint(x: 100, y: 100)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let mouse = NSEvent.mouseEvent(with: type, location: canvas.convert(noOpPoint, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { canvas.mouseDown(with: mouse) } else { canvas.mouseUp(with: mouse) }
        }
        try require(cancels == 2, "a no-op mouse click cannot discard an earlier draft")
        for inverted in [false, true] {
            configure(ZoomPlacement(scale: 2))
            event.kind = .scrollWheel
            event.position = canvas.convert(CGPoint(x: 400, y: 225), to: nil)
            event.eventPhase = []
            event.precise = true
            event.inverted = inverted
            event.dx = 30; event.dy = 20
            canvas.scrollWheel(with: event)
            try near(canvas.zoom, ZoomPlacement(scale: 2, x: 0.5 + 30 / 1600, y: 0.5 - 20 / 900),
                     "AppKit's delivered deltas must not be inverted a second time for the macOS scroll preference")
        }
        print("Editor trackpad checks passed (anchored pinch, two-axis pan/momentum, stale frames, bounds, Escape, disabled states, and stable native preview).")
    }

    private static func near(_ actual: ZoomPlacement, _ expected: ZoomPlacement, _ message: String) throws {
        try require(abs(actual.scale - expected.scale) < 0.000_001 && abs(actual.x - expected.x) < 0.000_001 &&
                    abs(actual.y - expected.y) < 0.000_001, "\(message): \(actual) != \(expected)")
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TrackpadCheckError.failed(message) }
    }
}
