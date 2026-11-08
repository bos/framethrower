import AppKit
import Combine

@MainActor final class EditorFrameStore: ObservableObject {
    @Published var image: CGImage?
}
private enum PreviewToolFailure: Error { case failed(String) }
private final class PreviewGesture: NSEvent {
    var position = CGPoint.zero
    var eventPhase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    var amount: CGFloat = 0
    var dx: CGFloat = 0
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var locationInWindow: NSPoint { position }
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { 0 }
    override var hasPreciseScrollingDeltas: Bool { true }
}

/// Events go directly to an offscreen vector-only fixture. No system input is
/// posted and no player, asset, decoded image, or source file is created.
@main @MainActor struct PreviewToolChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PreviewToolFailure.failed(message) }
    }
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-8 }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "Requires suspended media processing")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: -18000, y: -18000, width: 800, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = canvas
        defer { window.close() }
        let fixedFrame = canvas.frame
        let initial = ZoomPlacement(scale: 2, x: 0.5, y: 0.5)
        let pip = PIPPlacement(x: 0.9, y: 0.9, scale: 0.2)
        func configure(_ zoom: ZoomPlacement = initial, camera: Bool = false, source: CGSize = CGSize(width: 1920, height: 1080)) {
            canvas.configure(player: nil, image: nil, sourceSize: source, cameraAspect: 16.0 / 9,
                placement: pip, cameraEnabled: camera, zoom: zoom)
            canvas.layoutSubtreeIfNeeded()
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func press(_ point: CGPoint) { canvas.mouseDown(with: mouse(.leftMouseDown, point)) }
        func move(_ point: CGPoint) { canvas.mouseDragged(with: mouse(.leftMouseDragged, point)) }
        func release(_ point: CGPoint) { canvas.mouseUp(with: mouse(.leftMouseUp, point)) }
        var zoomPreviews: [ZoomPlacement] = [], zoomCommits: [ZoomPlacement] = []
        var pipPreviews: [PIPPlacement] = [], pipCommits: [PIPPlacement] = []
        var boxes: [EditorRegionRect] = [], selections: [UUID?] = []
        var canceled = 0, referenceBegins = 0
        canvas.onZoomPreview = { zoomPreviews.append($0) }
        canvas.onZoomCommit = { next, _ in zoomCommits.append(next) }
        canvas.onPreview = { pipPreviews.append($0) }
        canvas.onCommit = { next, _ in pipCommits.append(next) }
        canvas.onCancel = { canceled += 1 }
        canvas.onDrawRegion = { boxes.append($0) }
        canvas.onSelectRegion = { selections.append($0) }
        canvas.onReferenceBegin = { referenceBegins += 1 }
        canvas.scribbleMode = true
        canvas.drawsReferenceBoxes = false
        let region = EditorRegion(time: 0, rect: EditorRegionRect(x: 0.3, y: 0.3, width: 0.08, height: 0.08))
        canvas.regions = [region]
        canvas.regionLabels = [region.id: "Box 1"]
        configure()
        guard let badge = canvas.guideBadges.first else { throw PreviewToolFailure.failed("Pan must retain Director boxes") }
        let badgePoint = CGPoint(x: badge.frame.midX, y: badge.frame.midY)
        try require(canvas.interactionCursor(at: badgePoint) === NSCursor.pointingHand, "Box badge has a selection cursor in Pan")
        press(badgePoint); release(badgePoint)
        try require(selections.count == 1 && selections[0] == region.id && zoomCommits.isEmpty && boxes.isEmpty,
            "A Pan-mode badge press selects that box, without panning or drawing")
        let start = CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.midY)
        let end = CGPoint(x: start.x + 80, y: start.y + 30)
        try require(canvas.interactionCursor(at: start) === NSCursor.openHand, "Pan advertises a hand over the zoomed background")
        press(start)
        try require(canvas.interactionCursor(at: start) === NSCursor.closedHand, "Held main-view pan uses closed hand")
        move(end); release(end)
        try require(zoomPreviews.count == 1 && zoomCommits.count == 1 && zoomCommits[0].x < initial.x && zoomCommits[0].y < initial.y && boxes.isEmpty,
            "Pan inside Director moves the actual viewport with mouse direction and never creates a box")
        let completed = canvas.zoom
        canvas.drawsReferenceBoxes = true
        try require(canvas.zoom == completed && canceled == 0 && canvas.guideBadges.count == 1,
            "Tool changes preserve completed drafts and visible boxes")
        configure()
        press(start); move(end)
        guard let draft = canvas.referenceDraft else { throw PreviewToolFailure.failed("Box needs a visible live draft before mouseUp") }
        try require(near(draft.width, draft.height) && referenceBegins == 1 && boxes.isEmpty,
            "Box aspect is locked while dragging, with no edit before release")
        let frozen = draft
        // Simulate host frame/clock delivery after reference begin. It cannot
        // remap the held gesture to a different source viewport.
        configure(ZoomPlacement(scale: 3, x: 0.8, y: 0.8))
        move(end)
        try require(canvas.referenceDraft == frozen && canvas.zoom == initial,
            "A held box freezes its original source viewport despite a newer clock/configuration sample")
        release(end)
        try require(boxes == [frozen] && canvas.referenceDraft == nil, "Release publishes the exact live box once")
        configure()
        press(start); move(end)
        canvas.drawsReferenceBoxes = false
        release(end)
        try require(boxes.count == 1 && canvas.referenceDraft == nil && canceled == 0,
            "Switching out of a held Box cancels locally; a late mouseUp cannot create it")
        configure()
        press(start); move(end)
        let previewsBeforeSwitch = zoomPreviews.count
        canvas.drawsReferenceBoxes = true
        try require(canvas.zoom == initial && canceled == 1, "Switching out of a changed pan restores origin and cancels the editor draft once")
        release(end)
        try require(zoomCommits.count == 1 && zoomPreviews.count == previewsBeforeSwitch,
            "Canceled pan's late release cannot publish a stale commit")
        canvas.drawsReferenceBoxes = false
        press(start)
        canvas.drawsReferenceBoxes = true
        release(start)
        try require(canceled == 1, "No-movement tool changes cannot discard completed editor framing")
        canvas.allowsZoomEditing = false
        let count = referenceBegins
        press(start); move(end); release(end)
        try require(referenceBegins == count && canvas.referenceDraft == nil && boxes.count == 1,
            "Loading/scrubbing-disabled canvas cannot start a Box gesture")
        canvas.allowsZoomEditing = true
        canvas.regions = []
        configure(ZoomPlacement())
        canvas.drawsReferenceBoxes = false
        try require(canvas.interactionCursor(at: start) === NSCursor.arrow, "At full frame there is no misleading pan hand")
        // Trackpad pinch works in both tools. A tool switch restores the active
        // gesture; a subsequent physical gesture may begin normally.
        for boxTool in [false, true] {
            canvas.drawsReferenceBoxes = boxTool
            configure()
            let gesture = PreviewGesture()
            gesture.position = canvas.convert(start, to: nil)
            gesture.eventPhase = .began; gesture.amount = 0.2
            canvas.magnify(with: gesture)
            try require(canvas.zoom.scale > initial.scale, "Trackpad pinch remains active in either preview tool")
            gesture.eventPhase = .ended; gesture.amount = 0
            canvas.magnify(with: gesture)
        }
        // Finalize existing trackpad movement before drawing, reject delayed
        // momentum even after box release, then accept a genuinely new gesture.
        configure()
        let scroll = PreviewGesture()
        scroll.position = canvas.convert(start, to: nil)
        scroll.eventPhase = .began; scroll.dx = 25
        canvas.scrollWheel(with: scroll)
        let afterScroll = canvas.zoom, beforeBoxCommits = zoomCommits.count
        press(start); move(end); release(end)
        try require(zoomCommits.count == beforeBoxCommits + 1, "Box press finalizes the preceding trackpad gesture once")
        scroll.eventPhase = []; scroll.momentum = .changed; scroll.dx = 50
        canvas.scrollWheel(with: scroll)
        try require(canvas.zoom == afterScroll, "Delayed trackpad momentum cannot move the box's frozen source viewport")
        scroll.eventPhase = .began; scroll.momentum = []; scroll.dx = -20
        canvas.scrollWheel(with: scroll)
        try require(canvas.zoom != afterScroll, "A new physical trackpad gesture remains usable after drawing")
        _ = canvas.cancelActiveInteraction()
        // Existing PIP direct dragging takes priority in Pan, including corner
        // resizing. Switching tools restores a held PIP without committing it.
        canvas.drawsReferenceBoxes = false
        configure(initial, camera: true)
        let cameraFrame = pip.frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9)
            .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let center = CGPoint(x: cameraFrame.midX, y: cameraFrame.midY)
        press(center); move(CGPoint(x: center.x - 40, y: center.y - 20))
        try require(pipPreviews.count == 1 && canvas.interactionCursor(at: center) === NSCursor.closedHand,
            "Pan tool retains direct PIP dragging with an accurate held cursor")
        let beforeCancel = canceled
        canvas.drawsReferenceBoxes = true
        release(center)
        try require(canvas.placement == pip && canceled == beforeCancel + 1 && pipCommits.isEmpty,
            "Switching from held PIP restores its source geometry without a late commit")
        canvas.drawsReferenceBoxes = false
        configure(initial, camera: true)
        let corner = CGPoint(x: cameraFrame.minX, y: cameraFrame.minY)
        try require(canvas.interactionCursor(at: corner) !== NSCursor.openHand,
            "Camera corner advertises resizing rather than background panning")
        press(corner); move(CGPoint(x: corner.x - 30, y: corner.y - 15)); release(corner)
        try require(pipCommits.count == 1 && pipCommits[0].scale != pip.scale,
            "Direct camera corner resizing still commits normally in Pan")
        canvas.drawsReferenceBoxes = true
        configure(initial, camera: true)
        try require(canvas.interactionCursor(at: center) === NSCursor.crosshair,
            "Box tool consistently draws over the camera instead of secretly moving it")
        var toolCanceled = 0
        canvas.onToolCancel = { toolCanceled += 1 }
        let priorCanceled = canceled, priorCommits = zoomCommits.count
        canvas.drawsReferenceBoxes = false
        configure()
        press(start); move(end)
        canvas.drawsReferenceBoxes = true
        release(end)
        try require(toolCanceled == 1 && canceled == priorCanceled && canvas.zoom == initial && zoomCommits.count == priorCommits,
            "Tool cancellation restores held pan origin using its distinct callback, without canceling the shared draft or committing on late mouseUp")
        canvas.drawsReferenceBoxes = false
        canvas.drawsReferenceBoxes = true
        press(start); move(end)
        canvas.drawsReferenceBoxes = false
        release(end)
        try require(toolCanceled == 1 && canceled == priorCanceled,
            "Completed drafts, idle switches, and locally canceled boxes never request shared draft restoration")
        configure(initial, camera: true)
        press(center); move(CGPoint(x: center.x - 30, y: center.y - 15))
        canvas.drawsReferenceBoxes = true
        release(center)
        try require(toolCanceled == 2 && canceled == priorCanceled && canvas.placement == pip,
            "PIP tool cancellation also restores origin through the distinct callback")
        canvas.drawsReferenceBoxes = false
        configure()
        press(start); move(end)
        canvas.cancelOperation(nil)
        release(end)
        try require(toolCanceled == 2 && canceled == priorCanceled + 1 && canvas.zoom == initial,
            "Escape retains its ordinary cancellation route rather than the tool-switch callback")
        try require(canvas.frame == fixedFrame && !canvas.hasMediaPlayerLayer && canvas.stillLayer.contents == nil && canvas.testPattern != nil,
            "All preview-tool interactions preserve layout and use only native vector content")
        print("Preview tool checks passed (Director Pan/Box routing, badges/cursors, live locked boxes/frozen source, trackpad momentum, cancellation/late release, PIP move/resize, fixed vector layout; no AV objects/media).")
    }
}
