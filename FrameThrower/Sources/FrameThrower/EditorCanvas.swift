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

    func makeNSView(context: Context) -> EditorCanvasView { EditorCanvasView() }
    func updateNSView(_ view: EditorCanvasView, context: Context) {
        view.onBegin = onBegin
        view.onPreview = onPreview
        view.onCommit = onCommit
        view.onCancel = onCancel
        view.configure(player: player, image: showsStill ? frames.image : nil,
            sourceSize: sourceSize, cameraAspect: cameraAspect,
            placement: placement, cameraEnabled: cameraEnabled)
    }
}

@MainActor
final class EditorCanvasView: NSView {
    let playerLayer = AVPlayerLayer()
    let stillLayer = CALayer()
    private let outline = CAShapeLayer()
    private let handles = CAShapeLayer()
    private(set) var canvasRect = CGRect.zero
    private(set) var placement = PIPPlacement()
    private var sourceSize = CGSize(width: 1920, height: 1080)
    private var cameraAspect = 16.0 / 9.0
    private var cameraEnabled = false
    var onBegin: (() -> Void)?
    var onPreview: ((PIPPlacement) -> Void)?
    var onCommit: ((PIPPlacement, String) -> Void)?
    var onCancel: (() -> Void)?
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
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        outline.lineWidth = 1
        handles.fillColor = NSColor.white.cgColor
        handles.strokeColor = NSColor.black.withAlphaComponent(0.55).cgColor
        handles.lineWidth = 1
        for child in [playerLayer, stillLayer, outline, handles] { layer?.addSublayer(child) }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Recording preview")
        setAccessibilityHelp("Drag the camera to move it. Drag any camera corner to resize. Escape cancels a drag.")
    }
    required init?(coder: NSCoder) { nil }

    func configure(player: AVPlayer, image: CGImage?, sourceSize: CGSize,
                   cameraAspect: Double, placement: PIPPlacement, cameraEnabled: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playerLayer.player !== player { playerLayer.player = player }
        stillLayer.contents = image
        stillLayer.isHidden = image == nil
        self.sourceSize = sourceSize
        self.cameraAspect = cameraAspect
        self.cameraEnabled = cameraEnabled
        self.placement = placement
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
        let width = max(1, sourceSize.width)
        let height = max(1, sourceSize.height)
        let scale = max(0, min(bounds.width / width, bounds.height / height))
        let size = CGSize(width: width * scale, height: height * scale)
        canvasRect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                            width: size.width, height: size.height)
        playerLayer.frame = canvasRect
        stillLayer.frame = canvasRect
        let current = drag?.draft ?? placement
        outline.isHidden = !cameraEnabled || !current.visible
        handles.isHidden = outline.isHidden
        let rect = current.frame(in: size, cameraAspect: cameraAspect)
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

    override func mouseDown(with event: NSEvent) {
        guard cameraEnabled, placement.visible else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = placement.frame(in: canvasRect.size, cameraAspect: cameraAspect)
            .offsetBy(dx: canvasRect.minX, dy: canvasRect.minY)
        let corner = PIPResizeCorner.allCases.first { corner in
            let target = cornerPoint(corner, in: rect)
            return abs(target.x - point.x) <= 12 && abs(target.y - point.y) <= 12
        }
        guard corner != nil || rect.contains(point) else { return }
        window?.makeFirstResponder(self)
        onBegin?()
        drag = Drag(point: point, origin: placement, corner: corner, draft: placement)
    }

    override func mouseDragged(with event: NSEvent) {
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
        guard let drag else { return }
        self.drag = nil
        placement = drag.draft
        if drag.draft != drag.origin {
            onCommit?(drag.draft, drag.corner == nil ? "Move camera" : "Resize camera")
        } else { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, drag != nil else { super.keyDown(with: event); return }
        drag = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayers()
        CATransaction.commit()
        onCancel?()
    }

    private func snap(_ value: Double) -> Double {
        if value < 0.035 { return 0 }
        if value > 0.965 { return 1 }
        return min(1, max(0, value))
    }
}
