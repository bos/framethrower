import AppKit
import Combine

@MainActor final class EditorFrameStore: ObservableObject { @Published var image: CGImage? }
private struct FullscreenCanvasFailure: Error { let message: String }

/// Offscreen native vector layers and local synthetic events only. No bitmap,
/// player, media asset, system input, focus, screenshot, or running app control.
@main @MainActor
struct CameraFullscreenCanvasChecks {
    static func require(_ value: Bool, _ message: String) throws { if !value { throw FullscreenCanvasFailure(message: message) } }
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-7 }
    static func rectNear(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
    }
    static func sizing() throws {
        let canvas = CGSize(width: 1920, height: 1080)
        let normal = PIPPlacement(x: 0.3, y: 0.4, scale: 0.25, shape: .circle,
            crop: .init(x: 0.2, y: 0.7), sourceZoom: 1.5)
        var full = normal; full.fullscreen = 1
        try require(near(EditorCameraSizing.fraction(full, in: canvas, cameraAspect: 16.0 / 9), 1), "Fullscreen Size reports100%, not the retained25% normal scale")
        try require(EditorCameraSizing.sized(full, to: 1, in: canvas, cameraAspect: 16.0 / 9) == full, "Unchanged Size does not write an invisible metadata edit")
        for fraction in [0.99, 0.8, 0.5, 0.26] {
            let next = EditorCameraSizing.sized(full, to: fraction, in: canvas, cameraAspect: 16.0 / 9)
            try require(near(EditorCameraSizing.fraction(next, in: canvas, cameraAspect: 16.0 / 9), fraction) &&
                        next.scale == normal.scale && next.shape == normal.shape && next.crop == normal.crop && next.sourceZoom == normal.sourceZoom,
                        "Partial Size changes retain source framing/normal shape and resolve their actual width")
        }
        var partial = normal; partial.fullscreen = 0.5
        let old = partial.frame(in: canvas, cameraAspect: 16.0 / 9)
        let slight = EditorCameraSizing.sized(partial, to: (old.width - 1) / canvas.width, in: canvas, cameraAspect: 16.0 / 9)
        let next = slight.frame(in: canvas, cameraAspect: 16.0 / 9)
        try require(near(next.width, old.width - 1) && abs(next.height - old.height) < 2, "Partial morph resizing has no height jump at the old50% limit")
        let returned = EditorCameraSizing.sized(partial, to: 0.24, in: canvas, cameraAspect: 16.0 / 9)
        try require(returned.fullscreenFraction == 0 && near(returned.scale, 0.24), "Shrinking through the retained normal width returns to ordinary overlay sizing")
        var upperLeft = normal; upperLeft.x = 0; upperLeft.y = 0
        let enlarged = EditorCameraSizing.resized(upperLeft, by: .init(width: 1600, height: 900), corner: .bottomRight, in: canvas, cameraAspect: 16.0 / 9)
        try require(rectNear(enlarged.frame(in: canvas, cameraAspect: 16.0 / 9), CGRect(origin: .zero, size: canvas)), "Direct corner resizing can continue beyond the old overlay cap to the full canvas")
        for corner in PIPResizeCorner.allCases {
            let right = corner == .bottomRight || corner == .topRight
            let down = corner == .bottomRight || corner == .bottomLeft
            let shrunk = EditorCameraSizing.resized(full, by: .init(width: right ? -20 : 20, height: down ? -10 : 10), corner: corner,
                in: canvas, cameraAspect: 16.0 / 9)
            let frame = shrunk.frame(in: canvas, cameraAspect: 16.0 / 9)
            try require(frame.width < canvas.width && frame.width > canvas.width - 25 && frame.height > canvas.height - 20 &&
                        near(right ? frame.minX : frame.maxX, right ? 0 : canvas.width) &&
                        near(down ? frame.minY : frame.maxY, down ? 0 : canvas.height), "Each fullscreen corner resizes continuously, preserving its opposite corner")
        }
        try require(EditorCameraSizing.resized(full, by: .init(width: 50, height: 30), corner: .bottomRight, in: canvas, cameraAspect: 16.0 / 9) == full,
                    "A canvas-bounded enlargement does not rewrite invisible stored x/y")
        let tall = PIPPlacement(scale: 0.5, shape: .rectangle, aspectRatio: 0.2)
        let minimum = EditorCameraSizing.minimumFraction(tall, in: canvas, cameraAspect: 16.0 / 9)
        try require(minimum < 0.12 && EditorCameraSizing.fraction(tall, in: canvas, cameraAspect: 16.0 / 9) >= minimum,
                    "Percent range accommodates the existing normal height cap rather than lying about visible width")
    }
    static func pattern() throws {
        let pattern = EditorTestPattern(), bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        var presentation = CanvasPresentation(); presentation.padding = 0.1
        let geometry = PresentationGeometry(sourceSize: EditorTestPattern.sourceSize, presentation: presentation)
        let output = geometry.outputRect(in: bounds), source = CGSize(width: 1920, height: 1080)
        let base = PIPPlacement(x: 0.8, y: 0.7, scale: 0.25, shape: .circle)
        var previousWidth = 0.0
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            var placement = base; placement.fullscreen = fraction
            pattern.update(in: bounds, presentation: presentation, zoom: .init(scale: 2), placement: placement, cameraEnabled: true, cameraAspect: 16.0 / 9)
            let frame = placement.frame(in: output.size, cameraAspect: 16.0 / 9).offsetBy(dx: output.minX, dy: output.minY)
            try require(rectNear(pattern.cameraFrame, frame) && pattern.cameraFrame.width > previousWidth,
                        "Vector camera uses the same increasing fullscreen frame as the model")
            try require(rectNear(pattern.cameraViewport, placement.sourceViewport(in: source, canvas: output.size)) &&
                        near(pattern.cameraViewport.width / pattern.cameraViewport.height, frame.width / frame.height), "Vector source viewport aspect-fills the actual frame without stretching")
            let cameraClip = pattern.layer.sublayers![1]
            try require(near(cameraClip.cornerRadius, placement.cornerRadius(in: frame.size)), "Vector rounding morphs circle to full rectangle through shared geometry")
            previousWidth = frame.width
        }
        try require(rectNear(pattern.cameraFrame, output) && pattern.layer.sublayers![1].cornerRadius == 0 &&
                    rectNear(pattern.screenViewport, ZoomPlacement(scale: 2).viewport(in: source)), "Fullscreen covers final canvas, including padding, while main-screen framing is unchanged")
    }
    static func gestures() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: -18000, y: -18000, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 500)); window.contentView = canvas
        defer { window.close() }
        var begins = 0, previews = [PIPPlacement](), commits = [PIPPlacement](), zooms = [ZoomPlacement]()
        canvas.onBegin = { begins += 1 }; canvas.onPreview = { previews.append($0) }; canvas.onCommit = { value, _ in commits.append(value) }
        canvas.onZoomPreview = { zooms.append($0) }
        let normal = PIPPlacement(x: 0.3, y: 0.3, scale: 0.25, shape: .circle, crop: .init(x: 0.2, y: 0.7), sourceZoom: 1.5)
        func configure(_ placement: PIPPlacement) {
            canvas.configure(player: nil, image: nil, sourceSize: .init(width: 1920, height: 1080), cameraAspect: 16.0 / 9,
                placement: placement, cameraEnabled: true, showsCameraPattern: true, zoom: .init(scale: 2))
            canvas.layoutSubtreeIfNeeded()
        }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var full = normal; full.fullscreen = 1; configure(full)
        let fixedBounds = canvas.bounds, center = CGPoint(x: canvas.canvasRect.midX, y: canvas.canvasRect.midY)
        try require(canvas.interactionCursor(at: center) === NSCursor.arrow, "Fullscreen body does not advertise an impossible move")
        canvas.mouseDown(with: event(.leftMouseDown, center)); canvas.mouseDragged(with: event(.leftMouseDragged, center.applying(.init(translationX: 50, y: 20)))); canvas.mouseUp(with: event(.leftMouseUp, center))
        try require(begins == 0 && previews.isEmpty && commits.isEmpty && zooms.isEmpty, "Fullscreen body drag cannot make invisible camera edits or pan hidden main content")
        let corner = CGPoint(x: canvas.canvasRect.maxX - 1, y: canvas.canvasRect.maxY - 1)
        canvas.mouseDown(with: event(.leftMouseDown, corner)); canvas.mouseDragged(with: event(.leftMouseDragged, corner.applying(.init(translationX: -20, y: -12)))); canvas.mouseUp(with: event(.leftMouseUp, corner))
        try require(commits.count == 1 && commits[0].fullscreenFraction > 0.9 && commits[0].fullscreenFraction < 1 && commits[0].shape == .circle && commits[0].crop == normal.crop,
                    "Native fullscreen corner drag visibly resizes continuously without losing stored Circle/crop")
        previews.removeAll(); commits.removeAll(); begins = 0
        var partial = normal; partial.fullscreen = 0.5; configure(partial)
        let old = partial.frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9)
        let point = CGPoint(x: old.midX + canvas.canvasRect.minX, y: old.midY + canvas.canvasRect.minY)
        canvas.mouseDown(with: event(.leftMouseDown, point)); canvas.mouseDragged(with: event(.leftMouseDragged, point.applying(.init(translationX: 10, y: 5)))); canvas.mouseUp(with: event(.leftMouseUp, point))
        try require(commits.count == 1 && commits[0].fullscreen == partial.fullscreen, "Partial morph body movement preserves its progress")
        let moved = commits[0].frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9)
        try require(near(moved.minX, old.minX + 10) && near(moved.minY, old.minY + 5) && zooms.isEmpty && canvas.bounds == fixedBounds,
                    "Partial morph moves by exact pointer delta with fixed native bounds and untouched main framing")
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "Requires suspended media")
        try sizing(); try pattern(); try gestures()
        print("Camera fullscreen vector checks passed (actual width sizing, continuous anchored resize, circle/viewport morph, final canvas coverage, partial move and fullscreen no-op body; no media/images/app focus).")
    }
}
