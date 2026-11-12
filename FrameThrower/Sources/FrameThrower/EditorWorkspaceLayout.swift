import AppKit
import SwiftUI

struct EditorFlowFullWidth: LayoutValueKey { static let defaultValue = false }

/// Related controls wrap as a unit instead of forcing the editor wider.
struct EditorControlFlow: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 8
    private func placements(_ subviews: Subviews, width: CGFloat) -> ([(CGPoint, CGSize)], CGFloat) {
        var result: [(CGPoint, CGSize)] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let fullWidth = view[EditorFlowFullWidth.self]
            let ideal = view.sizeThatFits(.unspecified)
            let proposed = fullWidth ? width : min(width, ideal.width.isFinite ? ideal.width : width)
            var size = view.sizeThatFits(ProposedViewSize(width: proposed, height: nil))
            if fullWidth { size.width = width }
            if x > 0, fullWidth || x + size.width > width { x = 0; y += rowHeight + rowSpacing; rowHeight = 0 }
            result.append((CGPoint(x: x, y: y), size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (result, y + rowHeight)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(1, proposal.width ?? 280)
        return CGSize(width: width, height: placements(subviews, width: width).1)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, placement) in zip(subviews, placements(subviews, width: bounds.width).0) {
            view.place(at: CGPoint(x: bounds.minX + placement.0.x, y: bounds.minY + placement.0.y), anchor: .topLeading,
                proposal: ProposedViewSize(placement.1))
        }
    }
}

/// Native cursor rectangles end with the divider's lifetime; no pushed cursor
/// can remain behind when a property panel or recording closes.
struct EditorTimelineDivider: NSViewRepresentable {
    var onBegin: () -> Void
    var onDrag: (CGFloat) -> Void
    var onEnd: (Bool) -> Void
    func makeNSView(context: Context) -> DividerView { DividerView() }
    func updateNSView(_ view: DividerView, context: Context) {
        view.onBegin = onBegin; view.onDrag = onDrag; view.onEnd = onEnd
    }
    final class DividerView: NSView {
        var onBegin: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: ((Bool) -> Void)?
        private var originY: CGFloat?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: bounds.midY, width: bounds.width, height: 1)).fill()
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: CGRect(x: bounds.midX - 16, y: bounds.midY - 1, width: 32, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            originY = event.locationInWindow.y
            onBegin?()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let originY else { return }
            onDrag?(event.locationInWindow.y - originY)
        }
        override func mouseUp(with event: NSEvent) {
            guard let originY else { return }
            onDrag?(event.locationInWindow.y - originY)
            self.originY = nil; onEnd?(false)
        }
        override func cancelOperation(_ sender: Any?) {
            guard originY != nil else { return }
            originY = nil; onEnd?(true)
        }
    }
}

/// Allocated workspace, distinct from the aspect-fitted video inside it.
struct EditorPreviewRegionMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}
    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

enum EditorWorkspaceAllocation {
    static func timeline(height: CGFloat, content: CGFloat, initialHeight: CGFloat, initialTimeline: CGFloat,
                         fraction: CGFloat?, dragHeight: CGFloat?) -> CGFloat {
        let upper = max(100, height - 186)
        if let dragHeight { return min(upper, max(100, dragHeight)) }
        if let fraction { return min(upper, max(100, height * fraction)) }
        return min(upper, max(100, min(content, initialTimeline + max(0, height - initialHeight))))
    }
}
