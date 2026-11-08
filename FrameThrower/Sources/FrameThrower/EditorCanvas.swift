import AppKit
import AVFoundation
import SwiftUI

/// Native controls operate on the resolved output width, not the stored normal
/// overlay size. Keep a partial fullscreen morph continuous until it reaches its
/// retained normal frame; ordinary overlay resizing keeps its existing behavior.
enum EditorCameraSizing {
    static func fraction(_ placement: PIPPlacement, in canvas: CGSize, cameraAspect: Double) -> Double {
        guard canvas.width.isFinite, canvas.width > 0 else { return 0 }
        return placement.frame(in: canvas, cameraAspect: cameraAspect).width / canvas.width
    }
    static func minimumFraction(_ placement: PIPPlacement, in canvas: CGSize, cameraAspect: Double) -> Double {
        var minimum = placement; minimum.fullscreen = nil; minimum.scale = 0.12
        return fraction(minimum, in: canvas, cameraAspect: cameraAspect)
    }
    static func sized(_ placement: PIPPlacement, to fraction: Double, in canvas: CGSize, cameraAspect: Double) -> PIPPlacement {
        guard fraction.isFinite, canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return placement }
        var normal = placement; normal.fullscreen = nil
        var maximum = normal; maximum.scale = 0.5
        let currentNormal = self.fraction(normal, in: canvas, cameraAspect: cameraAspect)
        let maximumNormal = self.fraction(maximum, in: canvas, cameraAspect: cameraAspect)
        let wanted = min(1, max(minimumFraction(placement, in: canvas, cameraAspect: cameraAspect), fraction))
        if abs(wanted - self.fraction(placement, in: canvas, cameraAspect: cameraAspect)) < 1e-10 { return placement }
        if placement.fullscreenFraction > 0 && wanted > currentNormal {
            normal.fullscreen = min(1, max(0, (wanted - currentNormal) / max(1e-12, 1 - currentNormal)))
        } else if wanted <= maximumNormal {
            normal.scale = min(0.5, max(0.12, wanted))
        } else {
            normal = maximum
            normal.fullscreen = min(1, max(0, (wanted - maximumNormal) / max(1e-12, 1 - maximumNormal)))
        }
        return normal
    }
    static func resized(_ placement: PIPPlacement, by translation: CGSize, corner: PIPResizeCorner,
                        in canvas: CGSize, cameraAspect: Double) -> PIPPlacement {
        guard translation.width.isFinite, translation.height.isFinite, translation != .zero,
              canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return placement }
        let original = placement.frame(in: canvas, cameraAspect: cameraAspect)
        guard original.width > 0, original.height > 0 else { return placement }
        let right = corner == .topRight || corner == .bottomRight
        let down = corner == .bottomLeft || corner == .bottomRight
        let dx = translation.width * (right ? 1 : -1), dy = translation.height * (down ? 1 : -1)
        let delta: Double
        if placement.fullscreenFraction == 0 && placement.shape == .rectangle { delta = dx }
        else {
            let x = dx / original.width, y = dy / original.height
            delta = original.width * (abs(x) >= abs(y) ? x : y)
        }
        let wanted = min(canvas.width, max(canvas.width * minimumFraction(placement, in: canvas, cameraAspect: cameraAspect), original.width + delta))
        var base = placement
        if placement.fullscreenFraction == 0 {
            let normal = placement.resized(by: translation, corner: corner, in: canvas, cameraAspect: cameraAspect)
            var maximum = placement; maximum.scale = 0.5
            if wanted <= maximum.frame(in: canvas, cameraAspect: cameraAspect).width + 1e-9 { return normal }
            base = normal
        }
        let anchor = CGPoint(x: right ? original.minX : original.maxX, y: down ? original.minY : original.maxY)
        let available = CGSize(width: right ? canvas.width - anchor.x : anchor.x,
                               height: down ? canvas.height - anchor.y : anchor.y)
        func candidate(_ width: Double) -> PIPPlacement { sized(base, to: width / canvas.width, in: canvas, cameraAspect: cameraAspect) }
        var next = candidate(wanted)
        var frame = next.frame(in: canvas, cameraAspect: cameraAspect)
        if frame.width > available.width + 1e-9 || frame.height > available.height + 1e-9 {
            var low = min(original.width, wanted), high = wanted
            for _ in 0..<40 {
                let mid = (low + high) / 2, size = candidate((low + high) / 2).frame(in: canvas, cameraAspect: cameraAspect).size
                if size.width <= available.width && size.height <= available.height { low = mid } else { high = mid }
            }
            next = candidate(low); frame = next.frame(in: canvas, cameraAspect: cameraAspect)
        }
        if placement.fullscreenFraction > 0 && abs(frame.width - original.width) < 1e-9 && abs(frame.height - original.height) < 1e-9 { return placement }
        let x = right ? anchor.x : anchor.x - frame.width, y = down ? anchor.y : anchor.y - frame.height
        next.x = min(1, max(0, x / max(1e-12, canvas.width - frame.width)))
        next.y = min(1, max(0, y / max(1e-12, canvas.height - frame.height)))
        return next
    }
}

struct EditorCanvasEditingPose {
    var zoom: ZoomPlacement
    var placement: PIPPlacement
}

/// Pixels and drag geometry stay inside one native view. Neither decoded image
/// dimensions nor a camera gesture can become a SwiftUI layout proposal.
struct EditorCanvas: NSViewRepresentable {
    let player: AVPlayer?
    @ObservedObject var frames: EditorFrameStore
    let sourceSize: CGSize
    let cameraAspect: Double
    let placement: PIPPlacement
    let cameraEnabled: Bool
    var showsCameraPattern: Bool? = nil
    let showsStill: Bool
    var onBegin: () -> Void
    var onPreview: (PIPPlacement) -> Void
    var onCommit: (PIPPlacement, String) -> Void
    var onCancel: () -> Void
    var onToolCancel: (() -> Void)? = nil
    var prepareEditingPose: (() -> EditorCanvasEditingPose)? = nil
    var onEditingEnded: (() -> Void)? = nil
    var zoom = ZoomPlacement()
    var allowsZoomEditing = true
    var panEditingScale: Double? = nil
    var onZoomBegin: () -> Void = {}
    var onZoomPreview: (ZoomPlacement) -> Void = { _ in }
    var onZoomCommit: (ZoomPlacement, String) -> Void = { _, _ in }
    var presentation = CanvasPresentation()
    var nativeSourceSize: CGSize? = nil
    var scribbleMode = false
    var drawsReferenceBoxes = true
    var regions: [EditorRegion] = []
    var regionLabels: [UUID: String] = [:]
    var selectedRegionID: UUID? = nil
    var onReferenceBegin: () -> Void = {}
    var onDrawRegion: (EditorRegionRect) -> Void = { _ in }
    var onSelectRegion: (UUID?) -> Void = { _ in }
    var onDeleteRegion: (UUID) -> Void = { _ in }
    var conflictOutlines: EditorConflictOutlines? = nil

    func makeNSView(context: Context) -> EditorCanvasView { EditorCanvasView() }
    func updateNSView(_ view: EditorCanvasView, context: Context) {
        view.onBegin = onBegin
        view.onPreview = onPreview
        view.onCommit = onCommit
        view.onCancel = onCancel
        view.onToolCancel = onToolCancel
        view.prepareEditingPose = prepareEditingPose
        view.onEditingEnded = onEditingEnded
        view.onZoomBegin = onZoomBegin
        view.onZoomPreview = onZoomPreview
        view.onZoomCommit = onZoomCommit
        view.allowsZoomEditing = allowsZoomEditing
        view.panEditingScale = panEditingScale
        view.scribbleMode = scribbleMode
        view.drawsReferenceBoxes = drawsReferenceBoxes
        view.regions = regions
        view.regionLabels = regionLabels
        view.selectedRegionID = selectedRegionID
        view.onReferenceBegin = onReferenceBegin
        view.onDrawRegion = onDrawRegion
        view.onSelectRegion = onSelectRegion
        view.onDeleteRegion = onDeleteRegion
        view.conflictOutlines = conflictOutlines
        view.configure(player: player, image: showsStill ? frames.image : nil,
            sourceSize: sourceSize, cameraAspect: cameraAspect,
            placement: placement, cameraEnabled: cameraEnabled, showsCameraPattern: showsCameraPattern, zoom: zoom,
            presentation: presentation, nativeSourceSize: nativeSourceSize)
    }
}

@MainActor
final class EditorCanvasView: NSView {
    struct GuideBadge: Equatable {
        let regionID: UUID
        let label: String
        let frame: CGRect
        let selected: Bool
        var outsideViewport = false
    }
    private var mediaLayer: AVPlayerLayer?
    var playerLayer: AVPlayerLayer {
        if let mediaLayer { return mediaLayer }
        let playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        mediaLayer = playerLayer
        layer?.insertSublayer(playerLayer, at: 0)
        return playerLayer
    }
    var hasMediaPlayerLayer: Bool { mediaLayer != nil }
    private(set) var testPattern: EditorTestPattern?
    let stillLayer = CALayer()
    private let canvasBorder = CALayer()
    private let outline = CAShapeLayer()
    private let handles = CAShapeLayer()
    private let guides = CALayer()
    private let conflictGuides = CALayer()
    var conflictOutlines: EditorConflictOutlines? {
        didSet {
            guard oldValue != conflictOutlines else { return }
            trackpad = nil; zoomDrag = nil; drag = nil
            scribbleStart = nil; referenceDraft = nil; referenceGeometry = nil; guidePressID = nil
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private(set) var conflictFrames: [CGRect] = []
    var scribbleMode = false {
        didSet {
            guard oldValue != scribbleMode else { return }
            cancelActiveInteraction(toolChange: true)
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var drawsReferenceBoxes = true {
        didSet {
            guard oldValue != drawsReferenceBoxes else { return }
            cancelActiveInteraction(toolChange: true)
            needsLayout = true
            window?.invalidateCursorRects(for: self)
        }
    }
    private var isBoxTool: Bool { scribbleMode && drawsReferenceBoxes && allowsZoomEditing }
    var regions: [EditorRegion] = []
    var regionLabels: [UUID: String] = [:]
    var selectedRegionID: UUID?
    var onReferenceBegin: (() -> Void)?
    var onDrawRegion: ((EditorRegionRect) -> Void)?
    var onSelectRegion: ((UUID?) -> Void)?
    var onDeleteRegion: ((UUID) -> Void)?
    private var scribbleStart: CGPoint?
    private(set) var referenceDraft: EditorRegionRect?
    private var referenceGeometry: ScribbleGeometry?
    private var guidePressID: UUID?
    private var ignoresTrackpadRemainder = false
    private var cursorTrackingArea: NSTrackingArea?
    private(set) var guideBadges: [GuideBadge] = []
    private(set) var canvasRect = CGRect.zero
    private(set) var contentRect = CGRect.zero
    private(set) var placement = PIPPlacement()
    private var sourceSize = CGSize(width: 1920, height: 1080)
    private var presentation = CanvasPresentation()
    private var cameraAspect = 16.0 / 9.0
    private var cameraEnabled = false
    private var showsCameraPattern = false
    var onBegin: (() -> Void)?
    var onPreview: ((PIPPlacement) -> Void)?
    var onCommit: ((PIPPlacement, String) -> Void)?
    var onCancel: (() -> Void)?
    var onToolCancel: (() -> Void)?
    var prepareEditingPose: (() -> EditorCanvasEditingPose)?
    var onEditingEnded: (() -> Void)?
    var onZoomBegin: (() -> Void)?
    var onZoomPreview: ((ZoomPlacement) -> Void)?
    var onZoomCommit: ((ZoomPlacement, String) -> Void)?
    var allowsZoomEditing = true {
        didSet {
            if oldValue && !allowsZoomEditing { cancelActiveInteraction() }
        }
    }
    private(set) var zoom = ZoomPlacement()
    var panEditingScale: Double? {
        didSet {
            if ((oldValue ?? zoom.scale) > 1) != ((panEditingScale ?? zoom.scale) > 1) {
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    private var canPan: Bool { allowsZoomEditing && (panEditingScale ?? zoom.scale).isFinite && (panEditingScale ?? zoom.scale) > 1 }
    private static let navigationHelp = "Pinch to zoom; use two fingers to pan. Double-click to zoom, or drag a zoomed recording to pan. Drag the camera or its corners to move or resize it. Escape cancels unfinished edits."
    private struct ZoomDrag {
        let point: CGPoint
        var origin: ZoomPlacement
        var draft: ZoomPlacement
        var hasBegun = false
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
        var origin: PIPPlacement
        let corner: PIPResizeCorner?
        var draft: PIPPlacement
        var hasBegun = false
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
        for child in [stillLayer, canvasBorder, outline, handles, guides, conflictGuides] { layer?.addSublayer(child) }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Recording preview")
        setAccessibilityHelp(Self.navigationHelp)
    }
    required init?(coder: NSCoder) { nil }

    func configure(player: AVPlayer?, image: CGImage?, sourceSize: CGSize,
                   cameraAspect: Double, placement: PIPPlacement, cameraEnabled: Bool,
                   showsCameraPattern: Bool? = nil, zoom: ZoomPlacement = ZoomPlacement(),
                   presentation: CanvasPresentation = CanvasPresentation(), nativeSourceSize: CGSize? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if MediaProcessing.isSuspended {
            mediaLayer?.player = nil
            mediaLayer?.isHidden = true
            stillLayer.contents = nil
            stillLayer.isHidden = true
            if testPattern == nil {
                let pattern = EditorTestPattern()
                testPattern = pattern
                layer?.insertSublayer(pattern.layer, at: 0)
            }
            testPattern?.layer.isHidden = false
        } else {
            testPattern?.layer.isHidden = true
            if playerLayer.player !== player { playerLayer.player = player }
            playerLayer.isHidden = false
            stillLayer.contents = image
            stillLayer.isHidden = image == nil
        }
        self.sourceSize = nativeSourceSize ?? sourceSize
        self.presentation = presentation
        self.cameraAspect = cameraAspect
        self.cameraEnabled = cameraEnabled
        self.showsCameraPattern = showsCameraPattern ?? cameraEnabled
        self.placement = placement
        // Frame delivery and SwiftUI updates may arrive between native gesture
        // samples. Continue from the gesture's viewport, never from an older
        // frame's configuration.
        self.zoom = referenceGeometry?.zoom ?? trackpad?.draft ?? zoomDrag?.draft ?? zoom
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
        mediaLayer?.frame = canvasRect
        stillLayer.frame = canvasRect
        canvasBorder.frame = canvasRect
        let current = drag?.draft ?? placement
        if MediaProcessing.isSuspended {
            testPattern?.update(in: bounds, sourceSize: sourceSize, presentation: presentation, zoom: zoom,
                placement: current, cameraEnabled: showsCameraPattern, cameraAspect: cameraAspect)
        }
        outline.isHidden = !cameraEnabled || !current.visible
        handles.isHidden = outline.isHidden
        let rect = current.frame(in: canvasRect.size, cameraAspect: cameraAspect)
            .offsetBy(dx: canvasRect.minX, dy: canvasRect.minY)
        let radius = current.cornerRadius(in: rect.size)
        outline.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let circles = CGMutablePath()
        for corner in PIPResizeCorner.allCases {
            let point = cornerPoint(corner, in: rect)
            circles.addEllipse(in: CGRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9))
        }
        handles.path = circles
        updateGuides()
        updateConflictGuides()
    }

    private var scribbleGeometry: ScribbleGeometry { ScribbleGeometry(contentRect: contentRect, zoom: zoom) }

    private func updateGuides() {
        guides.frame = bounds
        guides.sublayers?.forEach { $0.removeFromSuperlayer() }
        guideBadges = []
        setAccessibilityValue(nil)
        setAccessibilityHelp(scribbleMode ? (isBoxTool ?
            "Box tool. Drag to draw a reference box; click a box number to select it. Pinch to zoom and use two fingers to pan. Escape cancels an unfinished action." :
            "Pan tool. Drag a zoomed recording to pan; click a box number to select it. Pinch to zoom and use two fingers to pan. Drag the camera or its corners to move or resize it.") : Self.navigationHelp)
        guard scribbleMode, contentRect.width > 0, contentRect.height > 0 else { return }
        let values = regions.map { ($0.rect, $0.id == selectedRegionID, Optional($0.id)) }
            + (referenceDraft.map { [($0, true, nil as UUID?)] } ?? [])
        var shapeLayers: [(CALayer, Bool)] = []
        var badgeLayers: [(CALayer, Bool)] = []
        for (region, selected, id) in values {
            let projected = scribbleGeometry.viewRect(region)
            let rect = projected.intersection(contentRect)
            let outside = rect.isNull || rect.isEmpty
            let shape = CAShapeLayer()
            if !outside { shape.path = CGPath(rect: rect, transform: nil) }
            shape.strokeColor = (selected ? NSColor.controlAccentColor : NSColor.white).cgColor
            shape.fillColor = NSColor.controlAccentColor.withAlphaComponent(selected ? 0.15 : 0.04).cgColor
            shape.lineWidth = selected ? 2 : 1
            shape.lineDashPattern = selected ? nil : [5, 3]
            if !outside { shapeLayers.append((shape, selected)) }
            if let id, let label = regionLabels[id] {
                let displayedLabel = outside ? label + " " + offscreenDirection(for: projected) : label
                let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                let measured = (displayedLabel as NSString).size(withAttributes: [.font: font]).width + 14
                let width = min(max(38, measured), contentRect.width)
                let height = min(22, contentRect.height)
                let origin = outside ? CGPoint(x: projected.midX - width / 2, y: projected.midY - height / 2) : rect.origin
                let frame = availableBadgeFrame(at: origin, size: CGSize(width: width, height: height))
                if !outside, !frame.intersects(rect) {
                    let connector = CAShapeLayer()
                    let line = CGMutablePath()
                    let center = CGPoint(x: frame.midX, y: frame.midY)
                    line.move(to: center)
                    line.addLine(to: CGPoint(x: min(rect.maxX, max(rect.minX, center.x)),
                                            y: min(rect.maxY, max(rect.minY, center.y))))
                    connector.path = line
                    connector.strokeColor = shape.strokeColor
                    connector.lineWidth = 1
                    shapeLayers.append((connector, selected))
                }
                let badge = CALayer()
                badge.frame = frame
                badge.backgroundColor = (selected ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.85)).cgColor
                badge.borderWidth = selected ? 2 : 1
                badge.borderColor = NSColor.white.cgColor
                badge.cornerRadius = 4
                let text = CATextLayer()
                text.string = displayedLabel
                text.font = font
                text.fontSize = 11
                text.alignmentMode = .center
                text.truncationMode = .end
                text.foregroundColor = NSColor.white.cgColor
                text.contentsScale = window?.backingScaleFactor ?? 2
                text.frame = CGRect(x: 4, y: 3, width: max(0, width - 8), height: max(0, height - 4))
                badge.addSublayer(text)
                badgeLayers.append((badge, selected))
                guideBadges.append(GuideBadge(regionID: id, label: label, frame: frame, selected: selected, outsideViewport: outside))
            }
        }
        for (child, _) in shapeLayers.sorted(by: { !$0.1 && $1.1 }) { guides.addSublayer(child) }
        for (child, _) in badgeLayers.sorted(by: { !$0.1 && $1.1 }) { guides.addSublayer(child) }
        setAccessibilityValue(guideBadges.map {
            $0.label + ($0.selected ? ", selected" : "") + ($0.outsideViewport ? ", outside current view" : "")
        }.joined(separator: "; "))
    }

    private func updateConflictGuides() {
        conflictGuides.frame = bounds
        conflictGuides.sublayers?.forEach { $0.removeFromSuperlayer() }
        conflictFrames = []
        guard let comparison = conflictOutlines, contentRect.width > 0, contentRect.height > 0 else { return }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard [comparison.existing, comparison.proposed].allSatisfy({ rect in
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) &&
                rect.width > 0 && rect.height > 0 && !rect.intersection(unit).isEmpty && !rect.intersection(unit).isNull
        }) else { return }
        let values: [(CGRect, String, NSColor, Bool)] = [
            (comparison.existing, "Existing", .systemOrange, false),
            (comparison.proposed, "Proposed", .systemCyan, true)]
        for (source, title, color, dashed) in values {
            let rect = CGRect(x: contentRect.minX + source.minX * contentRect.width,
                y: contentRect.minY + source.minY * contentRect.height,
                width: source.width * contentRect.width, height: source.height * contentRect.height)
                .intersection(contentRect)
            guard !rect.isNull, !rect.isEmpty else { continue }
            conflictFrames.append(rect)
            let shape = CAShapeLayer()
            shape.path = CGPath(rect: rect.insetBy(dx: 2, dy: 2), transform: nil)
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = dashed ? 2 : 4
            shape.lineDashPattern = dashed ? [8, 4] : nil
            conflictGuides.addSublayer(shape)
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let width = min(contentRect.width, (title as NSString).size(withAttributes: [.font: font]).width + 14)
            let badge = CALayer()
            let y = dashed ? rect.maxY - 24 : rect.minY + 4
            badge.frame = CGRect(x: min(max(rect.minX + 4, contentRect.minX), contentRect.maxX - width),
                y: min(max(y, contentRect.minY), contentRect.maxY - 22), width: width, height: 22)
            badge.cornerRadius = 4
            badge.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            badge.borderWidth = 1
            badge.borderColor = color.cgColor
            let text = CATextLayer()
            text.string = title; text.font = font; text.fontSize = 11
            text.foregroundColor = color.cgColor; text.alignmentMode = .center
            text.contentsScale = window?.backingScaleFactor ?? 2
            text.frame = CGRect(x: 4, y: 3, width: max(0, width - 8), height: 16)
            badge.addSublayer(text); conflictGuides.addSublayer(badge)
        }
        guard conflictFrames.count == 2 else { return }
        setAccessibilityValue(String(format: "Conflict at %.2f seconds. Solid orange Existing frame; dashed cyan Proposed frame.", comparison.time))
        setAccessibilityHelp("Compare the solid Existing frame and dashed Proposed frame. Scrub the highlighted timeline spans to inspect the movement. Escape dismisses the proposal.")
    }

    private func offscreenDirection(for rect: CGRect) -> String {
        let horizontal = rect.maxX <= contentRect.minX ? -1 : rect.minX >= contentRect.maxX ? 1 : 0
        let vertical = rect.maxY <= contentRect.minY ? -1 : rect.minY >= contentRect.maxY ? 1 : 0
        switch (horizontal, vertical) {
        case (-1, -1): return "↖"
        case (0, -1): return "↑"
        case (1, -1): return "↗"
        case (-1, 0): return "←"
        case (1, 0): return "→"
        case (-1, 1): return "↙"
        case (0, 1): return "↓"
        case (1, 1): return "↘"
        default: return "↗"
        }
    }

    private func availableBadgeFrame(at point: CGPoint, size: CGSize) -> CGRect {
        func frame(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: min(max(x, contentRect.minX), contentRect.maxX - size.width),
                   y: min(max(y, contentRect.minY), contentRect.maxY - size.height),
                   width: size.width, height: size.height)
        }
        let preferred = frame(point.x, point.y)
        let horizontalStep = size.width + 4
        let verticalStep = size.height + 4
        let columns = max(1, Int(contentRect.width / horizontalStep) + 1)
        let rows = max(1, Int(contentRect.height / verticalStep) + 1)
        // Pack along the box's top edge first, then above/below it. Placement
        // follows guide order, not selection, so highlighting cannot move names.
        let horizontal = [CGFloat.zero] + (1...columns).flatMap { [CGFloat($0), -CGFloat($0)] }
        let vertical = [CGFloat.zero] + (1...rows).flatMap { [CGFloat($0), -CGFloat($0)] }
        for row in vertical {
            for column in horizontal {
                let candidate = frame(preferred.minX + column * horizontalStep, preferred.minY + row * verticalStep)
                if !guideBadges.contains(where: { $0.frame.insetBy(dx: -2, dy: -2).intersects(candidate) }) {
                    return candidate
                }
            }
        }
        return preferred
    }

    private func cornerPoint(_ corner: PIPResizeCorner, in rect: CGRect) -> CGPoint {
        CGPoint(x: corner == .topLeft || corner == .bottomLeft ? rect.minX : rect.maxX,
                y: corner == .topLeft || corner == .topRight ? rect.minY : rect.maxY)
    }

    private var cameraRect: CGRect {
        placement.frame(in: canvasRect.size, cameraAspect: cameraAspect)
            .offsetBy(dx: canvasRect.minX, dy: canvasRect.minY)
    }

    private func cameraCorner(at point: CGPoint) -> PIPResizeCorner? {
        PIPResizeCorner.allCases.first { corner in
            let target = cornerPoint(corner, in: cameraRect)
            return abs(target.x - point.x) <= 12 && abs(target.y - point.y) <= 12
        }
    }

    /// Shared by native cursor updates and offscreen interaction checks, so
    /// the hand never advertises a pan where a camera or box receives a press.
    func interactionCursor(at point: CGPoint) -> NSCursor {
        guard conflictOutlines == nil else { return .arrow }
        if zoomDrag != nil { return .closedHand }
        if scribbleMode, guideBadges.contains(where: { $0.frame.contains(point) }) { return .pointingHand }
        if cameraEnabled, placement.visible {
            if let corner = cameraCorner(at: point) {
                let position: NSCursor.FrameResizePosition
                switch corner {
                case .topLeft: position = .topLeft
                case .topRight: position = .topRight
                case .bottomLeft: position = .bottomLeft
                case .bottomRight: position = .bottomRight
                }
                return .frameResize(position: position, directions: .all)
            }
            if cameraRect.contains(point) { return placement.fullscreenFraction == 1 ? .arrow : (drag == nil ? .openHand : .closedHand) }
        }
        if isBoxTool { return contentRect.contains(point) ? .crosshair : .arrow }
        return canPan && canvasRect.contains(point) ? .openHand : .arrow
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        interactionCursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseEntered(with event: NSEvent) { cursorUpdate(with: event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func resetCursorRects() {
        // Per-point cursor routing uses the same priority as mouseDown.
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        guard conflictOutlines == nil else { window?.makeFirstResponder(self); return }
        let point = convert(event.locationInWindow, from: nil)
        defer { if window?.isKeyWindow == true { interactionCursor(at: point).set() } }
        if scribbleMode, let badge = guideBadges.reversed().first(where: { $0.frame.contains(point) }) {
            window?.makeFirstResponder(self)
            guidePressID = badge.regionID
            return
        }
        let rect = cameraRect
        let corner = cameraCorner(at: point)
        if cameraEnabled, placement.visible, corner != nil || rect.contains(point) {
            window?.makeFirstResponder(self)
            guard corner != nil || placement.fullscreenFraction < 1 else { return }
            finishTrackpad()
            ignoresTrackpadRemainder = true
            drag = Drag(point: point, origin: placement, corner: corner, draft: placement)
            return
        }
        if isBoxTool {
            window?.makeFirstResponder(self)
            guard scribbleGeometry.sourcePoint(point) != nil else { onSelectRegion?(nil); return }
            finishTrackpad()
            ignoresTrackpadRemainder = true
            let geometry = scribbleGeometry
            referenceGeometry = geometry
            scribbleStart = point
            referenceDraft = nil
            onReferenceBegin?()
            return
        }
        guard allowsZoomEditing, canvasRect.contains(point), canvasRect.width > 0, canvasRect.height > 0 else { return }
        finishTrackpad()
        ignoresTrackpadRemainder = true
        if event.clickCount == 2 {
            window?.makeFirstResponder(self)
            prepareGesture(camera: false)
            let viewport = zoom.viewport(in: CGSize(width: 1, height: 1))
            let next = zoom.scale > 1 ? ZoomPlacement() : ZoomPlacement(scale: 2,
                x: viewport.minX + min(1, max(0, (point.x - contentRect.minX) / contentRect.width)) * viewport.width,
                y: viewport.minY + min(1, max(0, (point.y - contentRect.minY) / contentRect.height)) * viewport.height).clamped
            zoom = next
            onZoomCommit?(next, next.scale > 1 ? "Zoom in" : "Zoom out")
        } else if canPan {
            window?.makeFirstResponder(self)
            zoomDrag = ZoomDrag(point: point, origin: zoom.clamped, draft: zoom.clamped)
            window?.invalidateCursorRects(for: self)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let scribbleStart {
            referenceDraft = referenceGeometry?.region(from: scribbleStart, to: convert(event.locationInWindow, from: nil))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            updateGuides()
            CATransaction.commit()
            return
        }
        if var pan = zoomDrag {
            let point = convert(event.locationInWindow, from: nil)
            if !pan.hasBegun {
                guard hypot(point.x - pan.point.x, point.y - pan.point.y) >= 3 else { return }
                prepareGesture(camera: false)
                pan.origin = zoom.clamped
                pan.draft = pan.origin
                pan.hasBegun = true
            }
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
        if !drag.hasBegun {
            guard hypot(translation.width, translation.height) >= 3 else { return }
            prepareGesture(camera: true)
            drag.origin = placement
            drag.draft = placement
            drag.hasBegun = true
        }
        var next = drag.origin
        if let corner = drag.corner {
            next = EditorCameraSizing.resized(next, by: translation, corner: corner, in: canvasRect.size, cameraAspect: cameraAspect)
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
        defer {
            if window?.isKeyWindow == true { interactionCursor(at: convert(event.locationInWindow, from: nil)).set() }
        }
        if let guidePressID {
            self.guidePressID = nil
            onSelectRegion?(guidePressID)
            return
        }
        if let scribbleStart {
            let point = convert(event.locationInWindow, from: nil)
            let geometry = referenceGeometry ?? scribbleGeometry
            let region = geometry.region(from: scribbleStart, to: point)
            self.scribbleStart = nil
            referenceDraft = nil
            referenceGeometry = nil
            if let region { onDrawRegion?(region) }
            else {
                onSelectRegion?(regions.reversed().first { scribbleGeometry.viewRect($0.rect).contains(point) }?.id)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            updateGuides()
            CATransaction.commit()
            return
        }
        if let pan = zoomDrag {
            zoomDrag = nil
            zoom = pan.draft
            window?.invalidateCursorRects(for: self)
            if pan.draft != pan.origin { onZoomCommit?(pan.draft, "Pan recording") }
            if pan.hasBegun { onEditingEnded?() }
            return
        }
        guard let drag else { return }
        self.drag = nil
        placement = drag.draft
        window?.invalidateCursorRects(for: self)
        if drag.draft != drag.origin {
            onCommit?(drag.draft, drag.corner == nil ? "Move camera" : "Resize camera")
        }
        if drag.hasBegun { onEditingEnded?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, scribbleMode {
            if scribbleStart != nil {
                cancelActiveInteraction()
                return
            }
            if let selectedRegionID, regions.contains(where: { $0.id == selectedRegionID }) {
                onDeleteRegion?(selectedRegionID)
                return
            }
        }
        guard event.keyCode == 53 else { super.keyDown(with: event); return }
        cancelOperation(nil)
    }

    override func magnify(with event: NSEvent) {
        guard acceptsTrackpad(event), event.magnification.isFinite else { return }
        if event.phase.contains(.cancelled) {
            if trackpad != nil { cancelOperation(nil) }
            return
        }
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
            if trackpad != nil { cancelOperation(nil) }
            return
        }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if canPan, dx.isFinite, dy.isFinite, dx != 0 || dy != 0 {
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
        if !cancelActiveInteraction() { onCancel?() }
    }

    /// Cancels only a currently held native gesture. Completed framing drafts
    /// remain the editor's responsibility when the host switches tools.
    @discardableResult
    func cancelActiveInteraction(toolChange: Bool = false) -> Bool {
        let active = guidePressID != nil || scribbleStart != nil || trackpad != nil || zoomDrag != nil || drag != nil
        guard active else { return false }
        var changed = false
        let prepared = trackpad != nil || zoomDrag?.hasBegun == true || drag?.hasBegun == true
        if let trackpad { zoom = trackpad.origin; changed = trackpad.draft != trackpad.origin }
        else if let zoomDrag { zoom = zoomDrag.origin; changed = zoomDrag.draft != zoomDrag.origin }
        if let drag { placement = drag.origin; changed = changed || drag.draft != drag.origin }
        if trackpad != nil { ignoresTrackpadRemainder = true }
        trackpad = nil
        zoomDrag = nil
        drag = nil
        guidePressID = nil
        scribbleStart = nil
        referenceDraft = nil
        referenceGeometry = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateLayers()
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
        if changed || prepared {
            if toolChange, let onToolCancel { onToolCancel() }
            else { onCancel?() }
        }
        return true
    }

    private func acceptsTrackpad(_ event: NSEvent) -> Bool {
        guard conflictOutlines == nil, allowsZoomEditing, drag == nil, zoomDrag == nil, scribbleStart == nil, guidePressID == nil,
              contentRect.width > 0, contentRect.height > 0 else { return false }
        if ignoresTrackpadRemainder {
            guard event.momentumPhase.isEmpty,
                  event.phase.contains(.began) || event.phase.isEmpty else { return false }
            ignoresTrackpadRemainder = false
        }
        return trackpad != nil || canvasRect.contains(convert(event.locationInWindow, from: nil))
    }

    private func beginTrackpad(_ kind: TrackpadKind) {
        if trackpad?.kind == kind { return }
        finishTrackpad()
        window?.makeFirstResponder(self)
        prepareGesture(camera: false)
        trackpad = TrackpadGesture(kind: kind, origin: zoom, draft: zoom)
    }

    /// The host may inspect a selected edit before manipulation. Obtain its
    /// authoritative pose synchronously: a later SwiftUI configure intentionally
    /// preserves the gesture's frozen origin and cannot safely rebase it.
    private func prepareGesture(camera: Bool) {
        if camera { onBegin?() } else { onZoomBegin?() }
        if let pose = prepareEditingPose?() {
            zoom = pose.zoom.clamped
            placement = pose.placement
            if var pending = drag, !pending.hasBegun {
                pending.origin = placement
                pending.draft = placement
                drag = pending
            }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        updateLayers()
        CATransaction.commit()
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
        onEditingEnded?()
    }

    private func snap(_ value: Double) -> Double {
        if value < 0.035 { return 0 }
        if value > 0.965 { return 1 }
        return min(1, max(0, value))
    }
}
