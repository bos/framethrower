import AppKit
import SwiftUI

struct RecordingTimelineMarker: Identifiable, Equatable {
    let id: UUID
    let time: Double
    let help: String
}

struct RecordingTimeline: NSViewRepresentable {
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let playhead: Double
    var onInteractionBegan: () -> Void
    var onSeek: (Double) -> Void
    var onScrubBegan: () -> Void = {}
    var onScrubEnded: () -> Void = {}
    var onTrim: (Double, Double) -> Void
    var zoomChanges: [RecordingTimelineMarker] = []
    var selectedZoomChangeID: UUID?
    var onSelectZoomChange: (UUID) -> Void = { _ in }

    func makeNSView(context: Context) -> RecordingTimelineView { RecordingTimelineView() }
    func updateNSView(_ view: RecordingTimelineView, context: Context) {
        view.duration = duration
        view.trimStart = trimStart
        view.trimEnd = trimEnd
        view.playhead = playhead
        view.onInteractionBegan = onInteractionBegan
        view.onScrubBegan = onScrubBegan
        view.onScrubEnded = onScrubEnded
        view.onSeek = onSeek
        view.onTrim = onTrim
        view.zoomChanges = zoomChanges
        view.selectedZoomChangeID = selectedZoomChangeID
        view.onSelectZoomChange = onSelectZoomChange
    }
}

/// A single source-time axis for the playhead and both trim boundaries. Native
/// mouse events keep hit-testing explicit when the playhead meets a trim handle.
@MainActor
final class RecordingTimelineView: NSView, NSViewToolTipOwner {
    var duration = 1.0 { didSet { needsDisplay = true; if duration != oldValue { updateTooltips() } } }
    var trimStart = 0.0 { didSet { needsDisplay = true } }
    var trimEnd = 1.0 { didSet { needsDisplay = true } }
    var playhead = 0.0 { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?
    var onTrim: ((Double, Double) -> Void)?
    var onInteractionBegan: (() -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?
    var zoomChanges: [RecordingTimelineMarker] = [] {
        didSet { if zoomChanges != oldValue { needsDisplay = true; updateTooltips() } }
    }
    var selectedZoomChangeID: UUID? { didSet { needsDisplay = true } }
    var onSelectZoomChange: ((UUID) -> Void)?
    private var tooltipText: [Int: String] = [:]

    private enum Interaction { case start, end, scrub }
    private struct Drag {
        var interaction: Interaction
        var originX: CGFloat
        var originTime: Double
        var start: Double
        var end: Double
    }
    private var drag: Drag?
    private var scrubTime: Double?
    private var railWidth: CGFloat { max(1, bounds.width - 24) }
    private var minimumLength: Double { min(0.1, duration) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Recording timeline")
        setAccessibilityHelp("Drag the top playhead to scrub. Drag either lower blue handle to trim. Purple diamonds mark zoom changes; click one to edit it.")
    }
    required init?(coder: NSCoder) { nil }

    func x(for time: Double) -> CGFloat {
        12 + CGFloat(min(max(time, 0), max(0, duration)) / max(duration, .leastNonzeroMagnitude)) * railWidth
    }

    private func time(for x: CGFloat) -> Double {
        min(max(Double((x - 12) / railWidth) * duration, 0), duration)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTooltips()
    }

    private func updateTooltips() {
        removeAllToolTips()
        tooltipText.removeAll()
        guard duration.isFinite, duration > 0, bounds.width > 0, bounds.height > 0 else { return }
        let base = addToolTip(bounds, owner: self, userData: nil)
        tooltipText[base] = "Drag the playhead to scrub. Drag the blue handles to trim. Purple diamonds mark zoom changes."
        for marker in zoomChanges where marker.time.isFinite {
            let rect = CGRect(x: x(for: marker.time) - 6, y: 0, width: 12, height: 12)
            tooltipText[addToolTip(rect, owner: self, userData: nil)] = marker.help
        }
    }

    func view(_ view: NSView, stringForToolTip tag: Int, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltipText[tag] ?? ""
    }

    override func draw(_ dirtyRect: NSRect) {
        guard duration.isFinite, duration > 0 else { return }
        let start = drag?.start ?? trimStart
        let end = drag?.end ?? trimEnd
        let current = scrubTime ?? playhead
        let rail = CGRect(x: 12, y: 21, width: railWidth, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: CGRect(x: x(for: start), y: 21, width: max(1, x(for: end) - x(for: start)), height: 6)).fill()
        for boundary in [start, end] {
            let handle = CGRect(x: x(for: boundary) - 5, y: 14, width: 10, height: 20)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: handle.insetBy(dx: 4, dy: 6), xRadius: 1, yRadius: 1).fill()
        }
        let cursorX = x(for: current)
        NSColor.labelColor.setStroke()
        let line = NSBezierPath()
        line.move(to: CGPoint(x: cursorX, y: 8))
        line.line(to: CGPoint(x: cursorX, y: 34))
        line.lineWidth = 1
        line.stroke()
        let thumb = NSBezierPath()
        thumb.move(to: CGPoint(x: cursorX - 5, y: 1))
        thumb.line(to: CGPoint(x: cursorX + 5, y: 1))
        thumb.line(to: CGPoint(x: cursorX + 5, y: 5))
        thumb.line(to: CGPoint(x: cursorX, y: 10))
        thumb.line(to: CGPoint(x: cursorX - 5, y: 5))
        thumb.close()
        NSColor.labelColor.setFill()
        thumb.fill()
        // Keep a zoom change visible even when selection moves the white
        // playhead to exactly the same time. The stem still identifies the
        // playhead, whose mouse hit target retains priority over the diamond.
        for marker in zoomChanges where marker.time.isFinite {
            let center = CGPoint(x: x(for: marker.time), y: 6)
            let selected = marker.id == selectedZoomChangeID
            let diamond = NSBezierPath()
            diamond.move(to: CGPoint(x: center.x, y: 1))
            diamond.line(to: CGPoint(x: center.x + 5, y: 6))
            diamond.line(to: CGPoint(x: center.x, y: 11))
            diamond.line(to: CGPoint(x: center.x - 5, y: 6))
            diamond.close()
            NSColor.systemPurple.withAlphaComponent(marker.time >= start && marker.time <= end ? 1 : 0.35).setFill()
            diamond.fill()
            if selected {
                NSColor.labelColor.setStroke()
                diamond.lineWidth = 1.5
                diamond.stroke()
            }
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard duration.isFinite, duration > 0 else { return }
        window?.makeFirstResponder(self)
        onInteractionBegan?()
        let point = convert(event.locationInWindow, from: nil)
        // Keep the scrub thumb easy to grab when it overlaps a change marker.
        // Lower trim handles retain their existing independent hit targets.
        if point.y < 12, abs(point.x - x(for: playhead)) > 10,
           let marker = zoomChanges.filter({ $0.time.isFinite && abs(point.x - x(for: $0.time)) <= 6 })
            .min(by: { abs(point.x - x(for: $0.time)) < abs(point.x - x(for: $1.time)) }) {
            onSelectZoomChange?(marker.id)
            return
        }
        let startDistance = abs(point.x - x(for: trimStart))
        let endDistance = abs(point.x - x(for: trimEnd))
        let interaction: Interaction
        if point.y >= 12, min(startDistance, endDistance) <= 12 {
            interaction = startDistance <= endDistance ? .start : .end
        } else { interaction = .scrub }
        let origin: Double
        if interaction == .scrub {
            onScrubBegan?()
            // Grab the thumb without a jump; a click elsewhere seeks directly.
            origin = point.y < 12 && abs(point.x - x(for: playhead)) <= 10 ? playhead : time(for: point.x)
            seek(origin)
        } else { origin = interaction == .start ? trimStart : trimEnd }
        drag = Drag(interaction: interaction, originX: point.x, originTime: origin, start: trimStart, end: trimEnd)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let next = drag.originTime + Double((point.x - drag.originX) / railWidth) * duration
        switch drag.interaction {
        case .scrub: seek(next)
        case .start: drag.start = min(max(next, 0), drag.end - minimumLength)
        case .end: drag.end = max(min(next, duration), drag.start + minimumLength)
        }
        self.drag = drag
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        scrubTime = nil
        switch drag.interaction {
        case .scrub: onScrubEnded?()
        case .start, .end:
            if drag.start != trimStart || drag.end != trimEnd { onTrim?(drag.start, drag.end) }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 123 || event.keyCode == 124 else { super.keyDown(with: event); return }
        onInteractionBegan?()
        let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
        onScrubBegan?()
        seek(playhead + (event.keyCode == 123 ? -step : step))
        onScrubEnded?()
        scrubTime = nil
        needsDisplay = true
    }

    override func accessibilityValue() -> Any? { NSNumber(value: playhead) }
    override func accessibilityPerformIncrement() -> Bool { accessibleSeek(0.1) }
    override func accessibilityPerformDecrement() -> Bool { accessibleSeek(-0.1) }

    private func accessibleSeek(_ delta: Double) -> Bool {
        onInteractionBegan?()
        onScrubBegan?()
        seek(playhead + delta)
        onScrubEnded?()
        scrubTime = nil
        needsDisplay = true
        return true
    }

    private func seek(_ value: Double) {
        let bounded = min(max(value, trimStart), trimEnd)
        scrubTime = bounded
        onSeek?(bounded)
        needsDisplay = true
    }
}
