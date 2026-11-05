import AppKit
import SwiftUI

/// Uses the same display coordinates as recording; the preview's Y axis points down.
enum AreaPreviewGeometry {
    static func previewRect(for selection: CGRect, in display: CGRect, size: CGSize) -> CGRect? {
        guard display.width > 0, display.height > 0, size.width > 0, size.height > 0 else { return nil }
        let clipped = selection.intersection(display)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else { return nil }
        return CGRect(
            x: (clipped.minX - display.minX) / display.width * size.width,
            y: (display.maxY - clipped.maxY) / display.height * size.height,
            width: clipped.width / display.width * size.width,
            height: clipped.height / display.height * size.height
        )
    }

    static func captureRect(for preview: CGRect, in display: CGRect, size: CGSize) -> CGRect? {
        guard display.width > 0, display.height > 0, size.width > 0, size.height > 0 else { return nil }
        let rect = CGRect(
            x: (display.minX + preview.minX / size.width * display.width).rounded(),
            y: (display.maxY - preview.maxY / size.height * display.height).rounded(),
            width: (preview.width / size.width * display.width).rounded(),
            height: (preview.height / size.height * display.height).rounded()
        ).intersection(display)
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return nil }
        return rect
    }

    static func moved(_ rect: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        CGRect(
            x: min(max(rect.minX + delta.width, bounds.minX), bounds.maxX - rect.width),
            y: min(max(rect.minY + delta.height, bounds.minY), bounds.maxY - rect.height),
            width: rect.width,
            height: rect.height
        )
    }
}

struct AreaPreviewEditor: NSViewRepresentable {
    @Binding var area: CaptureArea
    var displayFrame: CGRect
    var isEditable: Bool

    func makeNSView(context: Context) -> AreaPreviewSelectionView {
        AreaPreviewSelectionView()
    }

    func updateNSView(_ view: AreaPreviewSelectionView, context: Context) {
        view.displayFrame = displayFrame
        view.selection = area.rect
        view.isEditable = isEditable
        let binding = $area
        view.onSelectionChanged = { rect in
            binding.wrappedValue = CaptureArea(
                x: rect.minX, y: rect.minY, width: rect.width, height: rect.height
            )
        }
    }
}

/// A native overlay keeps pointer hit testing and dragging aligned with the fitted image.
final class AreaPreviewSelectionView: NSView {
    var displayFrame: CGRect = .zero { didSet { needsDisplay = true } }
    var selection: CGRect = .zero {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var isEditable = true {
        didSet {
            if !isEditable { drag = nil }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onSelectionChanged: ((CGRect) -> Void)?

    private enum Drag {
        case create(anchor: CGPoint)
        case move(rect: CGRect, anchor: CGPoint)
        case resize(opposite: CGPoint)
    }
    private var drag: Drag?
    private let handleSize: CGFloat = 7
    private let accent = NSColor(red: 0.86, green: 0.24, blue: 0.18, alpha: 1)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEditable }

    private var previewSelection: CGRect? {
        AreaPreviewGeometry.previewRect(for: selection, in: displayFrame, size: bounds.size)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recording area")
        setAccessibilityHelp("Drag outside the region to draw an area. Drag inside to move it, or drag a corner to resize. Arrow keys move the area; Shift moves it ten points.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityValue() -> Any? {
        "\(Int(selection.width)) by \(Int(selection.height)) points"
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        let rect = previewSelection
        if let rect { shade.appendRect(rect) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.48).setFill()
        shade.fill()

        guard let rect else { return }
        let border = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        accent.setStroke()
        border.lineWidth = 2
        border.stroke()
        for corner in corners(of: rect) {
            let handle = NSBezierPath(roundedRect: CGRect(
                x: corner.x - handleSize / 2, y: corner.y - handleSize / 2,
                width: handleSize, height: handleSize
            ), xRadius: 1.5, yRadius: 1.5)
            NSColor.white.setFill()
            handle.fill()
            accent.setStroke()
            handle.lineWidth = 1.5
            handle.stroke()
        }
    }

    override func resetCursorRects() {
        guard isEditable else { return }
        addCursorRect(bounds, cursor: .crosshair)
        guard let rect = previewSelection else { return }
        addCursorRect(rect, cursor: .openHand)
        for corner in corners(of: rect) {
            addCursorRect(CGRect(x: corner.x - 7, y: corner.y - 7, width: 14, height: 14), cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditable else { return }
        window?.makeFirstResponder(self)
        let point = clamped(convert(event.locationInWindow, from: nil))
        if let rect = previewSelection {
            for corner in corners(of: rect) where abs(point.x - corner.x) <= 7 && abs(point.y - corner.y) <= 7 {
                drag = .resize(opposite: CGPoint(
                    x: corner.x == rect.minX ? rect.maxX : rect.minX,
                    y: corner.y == rect.minY ? rect.maxY : rect.minY
                ))
                return
            }
            if rect.contains(point) {
                drag = .move(rect: rect, anchor: point)
                return
            }
        }
        drag = .create(anchor: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditable, let drag else { return }
        let point = clamped(convert(event.locationInWindow, from: nil))
        let rect: CGRect
        switch drag {
        case let .create(anchor), let .resize(anchor):
            rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                          width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        case let .move(initial, anchor):
            rect = AreaPreviewGeometry.moved(
                initial, by: CGSize(width: point.x - anchor.x, height: point.y - anchor.y), within: bounds
            )
        }
        if let capture = AreaPreviewGeometry.captureRect(for: rect, in: displayFrame, size: bounds.size) {
            updateSelection(capture)
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    override func keyDown(with event: NSEvent) {
        guard isEditable, let previewSelection,
              let rect = AreaPreviewGeometry.captureRect(for: previewSelection, in: displayFrame, size: bounds.size)
        else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: CGSize
        switch event.keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: -step)
        case 126: delta = CGSize(width: 0, height: step)
        default:
            super.keyDown(with: event)
            return
        }
        updateSelection(AreaPreviewGeometry.moved(rect, by: delta, within: displayFrame))
    }

    private func updateSelection(_ rect: CGRect) {
        selection = rect
        onSelectionChanged?(rect)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }
}
