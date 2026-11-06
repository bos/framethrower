import AppKit
import AVFoundation
import SwiftUI

/// Pixels and drag geometry stay inside one native view. Neither decoded image
/// dimensions nor a camera gesture can become a SwiftUI layout proposal.
struct EditorCanvas: NSViewRepresentable {
    let player: AVPlayer
    @ObservedObject var frames: EditorFrameStore
    let sourceSize: CGSize
    let cameraAspect: Double
    let placement: PIPPlacement
    let cameraEnabled: Bool
    let showsStill: Bool
    var onBegin: () -> Void
    var onPreview: (PIPPlacement) -> Void
    var onCommit: (PIPPlacement, String) -> Void
    var onCancel: () -> Void
    var zoom = ZoomPlacement()
    var allowsZoomEditing = true
    var onZoomBegin: () -> Void = {}
    var onZoomPreview: (ZoomPlacement) -> Void = { _ in }
    var onZoomCommit: (ZoomPlacement, String) -> Void = { _, _ in }
    var presentation = CanvasPresentation()
    var nativeSourceSize: CGSize? = nil

    func makeNSView(context: Context) -> EditorCanvasView { EditorCanvasView() }
    func updateNSView(_ view: EditorCanvasView, context: Context) {
        view.onBegin = onBegin
        view.onPreview = onPreview
        view.onCommit = onCommit
        view.onCancel = onCancel
        view.onZoomBegin = onZoomBegin
        view.onZoomPreview = onZoomPreview
        view.onZoomCommit = onZoomCommit
        view.allowsZoomEditing = allowsZoomEditing
        view.configure(player: player, image: showsStill ? frames.image : nil,
            sourceSize: sourceSize, cameraAspect: cameraAspect,
            placement: placement, cameraEnabled: cameraEnabled, zoom: zoom,
            presentation: presentation, nativeSourceSize: nativeSourceSize)
    }
}

@MainActor
final class EditorCanvasView: NSView {
    let playerLayer = AVPlayerLayer()
    let stillLayer = CALayer()
    private let canvasBorder = CALayer()
    private let outline = CAShapeLayer()
    private let handles = CAShapeLayer()
    private(set) var canvasRect = CGRect.zero
    private(set) var contentRect = CGRect.zero
    private(set) var placement = PIPPlacement()
    private var sourceSize = CGSize(width: 1920, height: 1080)
    private var presentation = CanvasPresentation()
    private var cameraAspect = 16.0 / 9.0
    private var cameraEnabled = false
    var onBegin: (() -> Void)?
    var onPreview: ((PIPPlacement) -> Void)?
    var onCommit: ((PIPPlacement, String) -> Void)?
    var onCancel: (() -> Void)?
    var onZoomBegin: (() -> Void)?
    var onZoomPreview: ((ZoomPlacement) -> Void)?
    var onZoomCommit: ((ZoomPlacement, String) -> Void)?
    var allowsZoomEditing = true {
        didSet { if !allowsZoomEditing { trackpad = nil; zoomDrag = nil } }
    }
    private(set) var zoom = ZoomPlacement()
    private struct ZoomDrag {
        let point: CGPoint
        let origin: ZoomPlacement
        var draft: ZoomPlacement
    }
    private var zoomDrag: ZoomDrag?
    private enum TrackpadKind { case pinch, pan }
    private struct TrackpadGesture {
        var kind: TrackpadKind
        var origin: ZoomPlacement
        var draft: ZoomPlacement
    }
    private var trackpad: TrackpadGesture?
    private struct Drag {
        let point: CGPoint
        let origin: PIPPlacement
        let corner: PIPResizeCorner?
        var draft: PIPPlacement
    }
    private var drag: Drag?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        stillLayer.contentsGravity = .resizeAspect
        // Preview-only bounds distinguish a black output canvas from the
        // surrounding viewer, especially with portrait and square outputs.
        canvasBorder.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        canvasBorder.borderWidth = 1
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        outline.lineWidth = 1
        handles.fillColor = NSColor.white.cgColor
        handles.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        handles.lineWidth = 1
        for child in [playerLayer, stillLayer, canvasBorder, outline, handles] { layer?.addSublayer(child) }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Recording preview")
        setAccessibilityHelp("Pinch to zoom; use two fingers to pan. Double-click to zoom, or drag a zoomed recording to pan. Drag the camera or its corners to move or resize it. Escape cancels unfinished edits.")
    }
    required init?(coder: NSCoder) { nil }

    func configure(player: AVPlayer, image: CGImage?, sourceSize: CGSize,
                   cameraAspect: Double, placement: PIPPlacement, cameraEnabled: Bool, zoom: ZoomPlacement = ZoomPlacement(),
                   presentation: CanvasPresentation = CanvasPresentation(), nativeSourceSize: CGSize? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playerLayer.player !== player { playerLayer.player = player }
        stillLayer.contents = image
        stillLayer.isHidden = image == nil
        self.sourceSize = nativeSourceSize ?? sourceSize
        self.presentation = presentation
        self.cameraAspect = cameraAspect
        self.cameraEnabled = cameraEnabled
        self.placement = placement
        // Frame delivery and SwiftUI updates may arrive between native gesture
        // samples. Continue from the gesture's viewport, never from an older
        // frame's configuration.
        self.zoom = trackpad?.draft ?? zoomDrag?.draft ?? zoom
        updateLayers()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayers()
        CATransaction.commit()
    }

    private func updateLayers() {
        let geometry = PresentationGeometry(sourceSize: sourceSize, presentation: presentation)
        canvasRect = geometry.outputRect(in: bounds)
        contentRect = geometry.contentRect(in: bounds)
        playerLayer.frame = canvasRect
        stillLayer.frame = canvasRect
        canvasBorder.frame = canvasRect
        let current = drag?.draft ?? placement
        outline.isHidden = !cameraEnabled || !current.visible
        handles.isHidden = outline.isHidden
        let rect = current.frame(in: canvasRect.size, cameraAspect: cameraAspect)
            .offsetBy(dx: canvasRect.minX, dy: canvasRect.minY)
        outline.path = current.shape == .circle ? CGPath(ellipseIn: rect, transform: nil)
            : CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        let circles = CGMutablePath()
        for corner in PIPResizeCorner.allCases {
            let point = cornerPoint(corner, in: rect)
            circles.addEllipse(in: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
        }
        handles.path = circles
    }

    private func cornerPoint(_ corner: PIPResizeCorner, in rect: CGRect) -> CGPoint {
        CGPoint(x: corner == .topLeft || corner == .bottomLeft ? rect.minX : rect.maxX,
                y: corner == .topLeft || corner == .topRight ? rect.minY : rect.maxY)
    }

    override func resetCursorRects() {
        if allowsZoomEditing, zoom.scale > 1 { addCursorRect(canvasRect, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rect = placement.frame(in: canvasRect.size, cameraAspect: cameraAspect)
            .offsetBy(dx: canvasRect.minX, dy: canvasRect.minY)
        let corner = PIPResizeCorner.allCases.first { corner in
            let target = cornerPoint(corner, in: rect)
            return abs(target.x - point.x) <= 12 && abs(target.y - point.y) <= 12
        }
        if cameraEnabled, placement.visible, corner != nil || rect.contains(point) {
            window?.makeFirstResponder(self)
            onBegin?()
            drag = Drag(point: point, origin: placement, corner: corner, draft: placement)
            return
        }
        guard allowsZoomEditing, canvasRect.contains(point), canvasRect.width > 0, canvasRect.height > 0 else { return }
        if event.clickCount == 2 {
            window?.makeFirstResponder(self)
            onZoomBegin?()
            let viewport = zoom.viewport(in: CGSize(width: 1, height: 1))
            let next = zoom.scale > 1 ? ZoomPlacement() : ZoomPlacement(scale: 2,
                x: viewport.minX + min(1, max(0, (point.x - contentRect.minX) / contentRect.width)) * viewport.width,
                y: viewport.minY + min(1, max(0, (point.y - contentRect.minY) / contentRect.height)) * viewport.height).clamped
            zoom = next
            onZoomCommit?(next, next.scale > 1 ? "Zoom in" : "Zoom out")
        } else if zoom.scale > 1 {
            window?.makeFirstResponder(self)
            onZoomBegin?()
            zoomDrag = ZoomDrag(point: point, origin: zoom.clamped, draft: zoom.clamped)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if var pan = zoomDrag {
            let point = convert(event.locationInWindow, from: nil)
            let next = ZoomPlacement(scale: pan.origin.scale,
                x: pan.origin.x - (point.x - pan.point.x) / max(1, contentRect.width * pan.origin.scale),
                y: pan.origin.y - (point.y - pan.point.y) / max(1, contentRect.height * pan.origin.scale)).clamped
            guard next != pan.draft else { return }
            pan.draft = next
            zoomDrag = pan
            zoom = next
            onZoomPreview?(next)
            return
        }
        guard var drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let translation = CGSize(width: point.x - drag.point.x, height: point.y - drag.point.y)
        var next = drag.origin
        if let corner = drag.corner {
            next = next.resized(by: translation, corner: corner, in: canvasRect.size, cameraAspect: cameraAspect)
        } else {
            let rect = drag.origin.frame(in: canvasRect.size, cameraAspect: cameraAspect)
            next.x = snap(next.x + translation.width / max(1, canvasRect.width - rect.width))
            next.y = snap(next.y + translation.height / max(1, canvasRect.height - rect.height))
        }
        guard next != drag.draft else { return }
        drag.draft = next
        self.drag = drag
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayers()
        CATransaction.commit()
        onPreview?(next)
    }

    override func mouseUp(with event: NSEvent) {
        if let pan = zoomDrag {
            zoomDrag = nil
            zoom = pan.draft
            if pan.draft != pan.origin { onZoomCommit?(pan.draft, "Pan recording") }
            return
        }
        guard let drag else { return }
        self.drag = nil
        placement = drag.draft
        if drag.draft != drag.origin {
            onCommit?(drag.draft, drag.corner == nil ? "Move camera" : "Resize camera")
        }
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else { super.keyDown(with: event); return }
        cancelOperation(nil)
    }

    override func magnify(with event: NSEvent) {
        guard acceptsTrackpad(event), event.magnification.isFinite else { return }
        if event.phase.contains(.cancelled) { cancelOperation(nil); return }
        if event.phase.contains(.began) { beginTrackpad(.pinch) }
        if event.magnification != 0 {
            beginTrackpad(.pinch)
            let point = convert(event.locationInWindow, from: nil)
            let u = min(1, max(0, (point.x - contentRect.minX) / contentRect.width))
            let v = min(1, max(0, (point.y - contentRect.minY) / contentRect.height))
            let old = zoom.clamped
            let scale = min(3, max(1, old.scale * max(0.01, 1 + event.magnification)))
            // Preserve the source pixel beneath the pinch center. Clamping at
            // an edge is the only case in which that pixel has to move.
            let next = ZoomPlacement(scale: scale,
                x: old.x + (u - 0.5) / old.scale - (u - 0.5) / scale,
                y: old.y + (v - 0.5) / old.scale - (v - 0.5) / scale).clamped
            previewTrackpad(next)
        }
        if event.phase.contains(.ended) || event.phase.isEmpty { finishTrackpad() }
    }

    override func scrollWheel(with event: NSEvent) {
        guard acceptsTrackpad(event) else { return }
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled) {
            cancelOperation(nil)
            return
        }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if zoom.scale > 1, event.phase.contains(.began) || event.momentumPhase.contains(.began) {
            beginTrackpad(.pan)
        }
        if zoom.scale > 1, dx.isFinite, dy.isFinite, dx != 0 || dy != 0 {
            beginTrackpad(.pan)
            // AppKit has already applied the user's natural-scroll preference.
            // Convert deltas into source viewport offsets. Moving the viewport
            // center translates the visible image in the opposite direction.
            let units = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
            let next = ZoomPlacement(scale: zoom.scale,
                x: zoom.x + dx * units / (contentRect.width * zoom.scale),
                y: zoom.y - dy * units / (contentRect.height * zoom.scale)).clamped
            previewTrackpad(next)
        }
        if event.momentumPhase.contains(.ended) ||
            (event.phase.contains(.ended) && event.momentumPhase.isEmpty) ||
            (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            finishTrackpad()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if let trackpad { zoom = trackpad.origin }
        else if let zoomDrag { zoom = zoomDrag.origin }
        trackpad = nil
        zoomDrag = nil
        drag = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayers()
        CATransaction.commit()
        onCancel?()
    }

    private func acceptsTrackpad(_ event: NSEvent) -> Bool {
        guard allowsZoomEditing, drag == nil, zoomDrag == nil,
              contentRect.width > 0, contentRect.height > 0 else { return false }
        return trackpad != nil || canvasRect.contains(convert(event.locationInWindow, from: nil))
    }

    private func beginTrackpad(_ kind: TrackpadKind) {
        if trackpad?.kind == kind { return }
        finishTrackpad()
        window?.makeFirstResponder(self)
        onZoomBegin?()
        trackpad = TrackpadGesture(kind: kind, origin: zoom, draft: zoom)
    }

    private func previewTrackpad(_ next: ZoomPlacement) {
        guard next != zoom else { return }
        zoom = next
        trackpad?.draft = next
        onZoomPreview?(next)
        window?.invalidateCursorRects(for: self)
    }

    private func finishTrackpad() {
        guard let gesture = trackpad else { return }
        trackpad = nil
        if gesture.draft != gesture.origin {
            onZoomCommit?(gesture.draft, gesture.kind == .pinch ? "Zoom recording" : "Pan recording")
        }
    }

    private func snap(_ value: Double) -> Double {
        if value < 0.035 { return 0 }
        if value > 0.965 { return 1 }
        return min(1, max(0, value))
    }
}
