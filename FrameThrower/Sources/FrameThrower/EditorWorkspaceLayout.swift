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
    func makeNSView(context: Context) -> DividerView { DividerView() }
    func updateNSView(_ view: DividerView, context: Context) {}
    final class DividerView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
