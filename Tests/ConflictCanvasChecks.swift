@preconcurrency import AVFoundation
import AppKit
import Combine

/// The representable needs this type; no image is created or requested.
@MainActor
final class EditorFrameStore: ObservableObject { @Published var image: CGImage? }

private enum ConflictCanvasFailure: Error { case failed(String) }
private final class ConflictTrackpadEvent: NSEvent {
    var amount = 0.0
    var dx = 0.0
    var dy = 0.0
    var point = CGPoint.zero
    var eventPhase: NSEvent.Phase = []
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var locationInWindow: NSPoint { point }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { [] }
}

@MainActor
private final class VectorCanvasFixture {
    let window = NSWindow(contentRect: CGRect(x: -12000, y: -12000, width: 640, height: 420),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let canvas = EditorCanvasView(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
    // An empty AVPlayer is required by configure. No item, image, asset,
    // renderer, bitmap context, codec or media file is ever constructed.
    let player = AVPlayer()
    var presentation = CanvasPresentation(aspect: .square, padding: 0.12)
    var camera = false
    var zoom = ZoomPlacement()
    init() {
        window.isReleasedWhenClosed = false
        window.contentView = canvas
    }
    func configure() {
        canvas.configure(player: player, image: nil, sourceSize: CGSize(width: 1920, height: 1080),
                         cameraAspect: 16.0 / 9.0, placement: PIPPlacement(), cameraEnabled: camera,
                         zoom: zoom, presentation: presentation)
        canvas.layoutSubtreeIfNeeded()
    }
    func mouse(_ kind: NSEvent.EventType, at point: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: kind, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }
    func drag(from start: CGPoint, to end: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end))
    }
    func escape() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        canvas.keyDown(with: event)
    }
}

/// All events target only an unshown, offscreen test canvas. Inspect vector
/// paths/layers directly; never snapshot, display, render or decode anything.
@main @MainActor
struct ConflictCanvasChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ConflictCanvasFailure.failed(message) }
    }
    static func near(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < 0.000001 }
    static func sameRect(_ left: CGRect, _ right: CGRect) -> Bool {
        near(left.minX, right.minX) && near(left.minY, right.minY) && near(left.maxX, right.maxX) && near(left.maxY, right.maxY)
    }
    static func descendants(_ layer: CALayer) -> [CALayer] {
        [layer] + (layer.sublayers ?? []).flatMap(descendants)
    }
    static func labels(_ root: CALayer) -> [CATextLayer] {
        descendants(root).compactMap { $0 as? CATextLayer }.filter { ["Existing", "Proposed"].contains($0.string as? String ?? "") }
    }
    static func comparisonLayer(_ canvas: EditorCanvasView) throws -> CALayer {
        guard let found = canvas.layer?.sublayers?.first(where: { !labels($0).isEmpty }) else {
            throw ConflictCanvasFailure.failed("comparison vector layer missing")
        }
        return found
    }
    static func matches(_ color: CGColor?, _ expected: NSColor) -> Bool {
        guard let color, let actual = NSColor(cgColor: color)?.usingColorSpace(.sRGB), let expected = expected.usingColorSpace(.sRGB) else { return false }
        return near(actual.redComponent, expected.redComponent) && near(actual.greenComponent, expected.greenComponent) && near(actual.blueComponent, expected.blueComponent) && near(actual.alphaComponent, expected.alphaComponent)
    }
    static func main() {
        guard MediaProcessing.isSuspended else { print("FAIL: video interlock must remain enabled"); Darwin.exit(1) }
        _ = NSApplication.shared
        let checks: [(String, () throws -> Void)] = [
            ("source projection and distinct styles", projectionAndStyles),
            ("coincident full-frame labels and resize", coincidentAndResize),
            ("nil/empty/null clearing and accessibility", clearing),
            ("conflict blocks new edits and Escape dismisses", blockedInput),
            ("conflict cancels gestures already in progress", interruptedInput)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try check(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        if failures > 0 { Darwin.exit(1) }
        print("Conflict canvas checks passed (actual native vector paths, badges, geometry, accessibility and input guards; no visible windows/images/player items/media).")
    }
    static func projectionAndStyles() throws {
        let fixture = VectorCanvasFixture(); defer { fixture.window.close() }
        let canvas = fixture.canvas
        let first = CGRect(x: 0, y: 0, width: 0.25, height: 0.5)
        let second = CGRect(x: 0.6, y: 0.4, width: 0.3, height: 0.5)
        canvas.conflictOutlines = EditorConflictOutlines(time: 2.75, existing: first, proposed: second)
        fixture.configure()
        let content = canvas.contentRect
        let expected = PresentationGeometry(sourceSize: CGSize(width: 1920, height: 1080), presentation: fixture.presentation).contentRect(in: canvas.bounds)
        try require(sameRect(content, expected) && content.minX > 0 && content.minY > 0, "source content padding/aspect was ignored")
        try require(canvas.conflictFrames.count == 2, "both source viewports must be projected")
        for (source, actual) in zip([first, second], canvas.conflictFrames) {
            let rect = CGRect(x: content.minX + source.minX * content.width, y: content.minY + source.minY * content.height,
                              width: source.width * content.width, height: source.height * content.height)
            try require(sameRect(actual, rect), "viewport corners are not in source content coordinates")
        }
        let root = try comparisonLayer(canvas)
        let shapes = root.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        try require(shapes.count == 2 && !root.isHidden && root.opacity > 0 && shapes.allSatisfy { !$0.isHidden && $0.opacity > 0 }, "outlines must remain separate visible vector shapes")
        guard let orange = shapes.first(where: { matches($0.strokeColor, .systemOrange) }), let cyan = shapes.first(where: { matches($0.strokeColor, .systemCyan) }) else { throw ConflictCanvasFailure.failed("orange Existing/cyan Proposed colors missing") }
        try require(orange.lineDashPattern?.isEmpty ?? true, "Existing must be solid")
        try require((cyan.lineDashPattern?.count ?? 0) >= 2 && cyan.lineDashPattern!.allSatisfy { $0.doubleValue > 0 }, "Proposed must be dashed")
        try require(orange.lineWidth > cyan.lineWidth && cyan.lineWidth > 0, "coincident cyan must leave the orange outline visible")
        try require(orange.fillColor == nil && cyan.fillColor == nil, "comparison outlines must not obscure the recording")
        for (shape, frame) in zip(shapes, canvas.conflictFrames) {
            try require(shape.path != nil && frame.contains(shape.path!.boundingBoxOfPath), "vector outline escaped its projected viewport")
        }
        try require(Set(labels(root).compactMap { $0.string as? String }) == ["Existing", "Proposed"], "both text labels must identify their outline")
        try require((canvas.accessibilityValue() as? String)?.contains("2.75") == true && (canvas.accessibilityHelp() ?? "").contains("Escape"), "comparison has no meaningful accessible time/help")
        try require(!fixture.window.isVisible && canvas.playerLayer.player == nil && canvas.stillLayer.contents == nil, "test exposed a window or media-backed canvas")
        // Normalized source rectangles clip at source edges, not output margins.
        canvas.conflictOutlines = EditorConflictOutlines(time: 3, existing: CGRect(x: -0.1, y: -0.2, width: 0.4, height: 0.6), proposed: CGRect(x: 0.8, y: 0.85, width: 0.5, height: 0.4))
        fixture.configure()
        try require(canvas.conflictFrames.count == 2 && near(canvas.conflictFrames[0].minX, content.minX) && near(canvas.conflictFrames[0].minY, content.minY) && near(canvas.conflictFrames[1].maxX, content.maxX) && near(canvas.conflictFrames[1].maxY, content.maxY), "edge viewports were clipped against the wrong coordinate space")
    }
    static func coincidentAndResize() throws {
        let fixture = VectorCanvasFixture(); defer { fixture.window.close() }
        let canvas = fixture.canvas
        canvas.conflictOutlines = EditorConflictOutlines(time: 0, existing: CGRect(x: 0, y: 0, width: 1, height: 1), proposed: CGRect(x: 0, y: 0, width: 1, height: 1))
        for size in [CGSize(width: 640, height: 420), CGSize(width: 380, height: 280), CGSize(width: 800, height: 500)] {
            canvas.setFrameSize(size); let frame = canvas.frame; let bounds = canvas.bounds
            fixture.configure()
            try require(canvas.frame == frame && canvas.bounds == bounds, "comparison layers changed native view bounds")
            try require(canvas.intrinsicContentSize == NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric), "comparison generated a layout size proposal")
            try require(canvas.conflictFrames.count == 2 && canvas.conflictFrames.allSatisfy { sameRect($0, canvas.contentRect) }, "coincident full frames lost an outline during resize")
            let root = try comparisonLayer(canvas); let badges = labels(root).compactMap(\.superlayer)
            try require(badges.count == 2 && !badges[0].frame.intersects(badges[1].frame) && badges.allSatisfy { !$0.isHidden && $0.opacity > 0 && canvas.contentRect.contains($0.frame) }, "coincident labels overlap or leave the visible source frame")
            try require(root.frame == canvas.bounds, "comparison layer did not resize with the canvas")
        }
    }
    static func clearing() throws {
        let fixture = VectorCanvasFixture(); defer { fixture.window.close() }
        let canvas = fixture.canvas
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        for empty in [Optional<EditorConflictOutlines>.none, EditorConflictOutlines(time: 2, existing: .zero, proposed: .zero), EditorConflictOutlines(time: 2, existing: .null, proposed: .null)] {
            canvas.conflictOutlines = EditorConflictOutlines(time: 1, existing: full, proposed: full); fixture.configure()
            let root = try comparisonLayer(canvas)
            canvas.conflictOutlines = empty; fixture.configure()
            try require(canvas.conflictFrames.isEmpty && (root.sublayers?.isEmpty ?? true) && labels(canvas.layer!).isEmpty, "cleared comparison retained shapes/badges")
            try require(!((canvas.accessibilityValue() as? String) ?? "").contains("Conflict") && !(canvas.accessibilityHelp() ?? "").contains("Compare"), "cleared comparison retained conflict accessibility value/help")
        }
        canvas.conflictOutlines = EditorConflictOutlines(time: 1, existing: full, proposed: full); fixture.configure()
        let root = try comparisonLayer(canvas)
        canvas.setFrameSize(.zero); fixture.configure()
        try require(canvas.conflictFrames.isEmpty && (root.sublayers?.isEmpty ?? true) && !((canvas.accessibilityValue() as? String) ?? "").contains("Conflict") && !(canvas.accessibilityHelp() ?? "").contains("Compare"), "zero-size content retained comparison layers or accessibility")
    }
    static func blockedInput() throws {
        let fixture = VectorCanvasFixture(); defer { fixture.window.close() }
        let canvas = fixture.canvas; fixture.camera = true; fixture.zoom = ZoomPlacement(scale: 2)
        var mutations = 0; var cancels = 0
        canvas.onBegin = { mutations += 1 }; canvas.onPreview = { _ in mutations += 1 }; canvas.onCommit = { _, _ in mutations += 1 }
        canvas.onZoomBegin = { mutations += 1 }; canvas.onZoomPreview = { _ in mutations += 1 }; canvas.onZoomCommit = { _, _ in mutations += 1 }
        canvas.onReferenceBegin = { mutations += 1 }; canvas.onDrawRegion = { _ in mutations += 1 }; canvas.onSelectRegion = { _ in mutations += 1 }; canvas.onCancel = { cancels += 1 }
        canvas.conflictOutlines = EditorConflictOutlines(time: 2, existing: CGRect(x: 0, y: 0, width: 1, height: 1), proposed: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        fixture.configure(); let placement = canvas.placement; let zoom = canvas.zoom
        let start = CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.midY)
        fixture.drag(from: start, to: CGPoint(x: start.x + 40, y: start.y + 25))
        let cameraFrame = placement.frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9.0).offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let cameraCenter = CGPoint(x: cameraFrame.midX, y: cameraFrame.midY)
        fixture.drag(from: cameraCenter, to: CGPoint(x: cameraCenter.x - 35, y: cameraCenter.y - 20))
        fixture.drag(from: CGPoint(x: cameraFrame.minX, y: cameraFrame.minY), to: CGPoint(x: cameraFrame.minX - 30, y: cameraFrame.minY - 20))
        canvas.mouseDown(with: fixture.mouse(.leftMouseDown, at: start, clicks: 2))
        let event = ConflictTrackpadEvent(); event.point = canvas.convert(start, to: nil); event.amount = 0.4; event.dx = 40; event.dy = 30; event.eventPhase = .began
        canvas.magnify(with: event); canvas.scrollWheel(with: event); event.eventPhase = .ended; canvas.magnify(with: event); canvas.scrollWheel(with: event)
        canvas.scribbleMode = true; fixture.configure(); fixture.drag(from: start, to: CGPoint(x: start.x + 60, y: start.y + 35))
        try require(mutations == 0 && canvas.placement == placement && canvas.zoom == zoom, "comparison input edited camera/zoom/references")
        fixture.escape(); try require(cancels == 1, "Escape did not invoke the proposal cancellation callback")
    }
    static func interruptedInput() throws {
        for mode in ["camera", "zoom", "scribble", "trackpad"] {
            let fixture = VectorCanvasFixture(); defer { fixture.window.close() }
            let canvas = fixture.canvas; fixture.camera = mode == "camera"; fixture.zoom = ZoomPlacement(scale: 2); canvas.scribbleMode = mode == "scribble"
            fixture.configure()
            var mutations = 0; var cancels = 0
            canvas.onPreview = { _ in mutations += 1 }; canvas.onCommit = { _, _ in mutations += 1 }
            canvas.onZoomPreview = { _ in mutations += 1 }; canvas.onZoomCommit = { _, _ in mutations += 1 }
            canvas.onDrawRegion = { _ in mutations += 1 }; canvas.onSelectRegion = { _ in mutations += 1 }; canvas.onCancel = { cancels += 1 }
            let camera = canvas.placement.frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9.0).offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
            let start = mode == "camera" ? CGPoint(x: camera.midX, y: camera.midY) : CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.midY)
            let event = ConflictTrackpadEvent(); event.point = canvas.convert(start, to: nil); event.amount = 0.2; event.eventPhase = .began
            if mode == "trackpad" { canvas.magnify(with: event) }
            else { canvas.mouseDown(with: fixture.mouse(.leftMouseDown, at: start)) }
            mutations = 0
            canvas.conflictOutlines = EditorConflictOutlines(time: 2, existing: CGRect(x: 0, y: 0, width: 1, height: 1), proposed: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)); fixture.configure()
            let baselinePlacement = canvas.placement; let baselineZoom = canvas.zoom
            let end = CGPoint(x: start.x + 42, y: start.y + 24)
            canvas.mouseDragged(with: fixture.mouse(.leftMouseDragged, at: end)); canvas.mouseUp(with: fixture.mouse(.leftMouseUp, at: end))
            event.eventPhase = .ended; canvas.magnify(with: event)
            try require(mutations == 0 && canvas.placement == baselinePlacement && canvas.zoom == baselineZoom, "activating comparison failed to cancel in-progress \(mode) input")
            fixture.escape(); try require(cancels == 1, "Escape was consumed by an old \(mode) gesture instead of dismissing comparison")
        }
    }
}
