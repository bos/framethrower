import AppKit
import SwiftUI

struct RecordingTimelineMarker: Identifiable, Equatable {
    let id: UUID
    let time: Double
    let help: String
    var label: String? = nil
    var transitionStart: Double? = nil
    var easeIn: Double = 0
    var easeOut: Double = 0
    var movable: Bool = true
    var minimumTime: Double = 0
    var maximumTime: Double? = nil
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
    var edits: [RecordingTimelineMarker] = []
    var selectedEditID: UUID?
    var onSelectEdit: (UUID) -> Void = { _ in }
    var frameDuration: Double = 1.0 / 30
    var onMoveEdit: (UUID, Double, Bool) -> Void = { _, _, _ in }
    var onCancelMoveEdit: () -> Void = {}
    var onDeselectEdit: () -> Void = {}
    var onCancelEdit: () -> Void = {}
    var fitRequest: UUID?

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
        view.edits = edits
        view.selectedEditID = selectedEditID
        view.onSelectEdit = onSelectEdit
        view.frameDuration = frameDuration
        view.onMoveEdit = onMoveEdit
        view.onCancelMoveEdit = onCancelMoveEdit
        view.onDeselectEdit = onDeselectEdit
        view.onCancelEdit = onCancelEdit
        view.fit(request: fitRequest)
    }
}

/// A single source-time axis for the playhead and both trim boundaries. Native
/// mouse events keep hit-testing explicit when the playhead meets a trim handle.
@MainActor
final class RecordingTimelineView: NSView, NSViewToolTipOwner {
    struct MarkerLabel: Equatable {
        let id: UUID
        let text: String
        let frame: CGRect
        let overlaysMarker: Bool
    }
    struct MarkerGroup: Equatable {
        let ids: [UUID]
        let frame: CGRect
        let text: String
        let selectedID: UUID?
        var isCluster: Bool { ids.count > 1 }
    }
    var duration = 1.0 {
        didSet {
            guard duration != oldValue else { return }
            let wasOverview = visibleStart == 0 && abs(visibleDuration - oldValue) < 0.000_001
            constrainViewport(reset: wasOverview)
        }
    }
    private(set) var visibleStart = 0.0
    private(set) var visibleDuration = 1.0
    var trimStart = 0.0 { didSet { needsDisplay = true } }
    var trimEnd = 1.0 { didSet { needsDisplay = true } }
    var playhead = 0.0 { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?
    var onTrim: ((Double, Double) -> Void)?
    var onInteractionBegan: (() -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?
    var edits: [RecordingTimelineMarker] = [] {
        didSet { if edits != oldValue { needsDisplay = true; updateTooltips() } }
    }
    var selectedEditID: UUID? {
        didSet {
            needsDisplay = true
            if selectedEditID != oldValue { updateTooltips() }
            if selectedEditID != oldValue,
               let selected = edits.first(where: { $0.id == selectedEditID }),
               !markerIsVisible(selected.time) {
                setViewport(start: selected.time - visibleDuration / 2, span: visibleDuration)
            }
        }
    }
    var onSelectEdit: ((UUID) -> Void)?
    var frameDuration = 1.0 / 30 { didSet { if frameDuration != oldValue { constrainViewport() } } }
    var onMoveEdit: ((UUID, Double, Bool) -> Void)?
    var onCancelMoveEdit: (() -> Void)?
    var onDeselectEdit: (() -> Void)?
    var onCancelEdit: (() -> Void)?
    private var tooltipText: [Int: String] = [:]
    // Tests exercise the real menu items and selectors without showing a menu
    // on the user's desktop. Production always uses the native popup below.
    var presentMarkerMenu: ((NSMenu, NSPoint) -> Void)?
    private var activeMarkerMenu: NSMenu?

    private enum Interaction: Equatable { case start, end, scrub, edit(UUID), cluster, emptyEditLane }
    private struct Drag {
        var interaction: Interaction
        var originX: CGFloat
        var originTime: Double
        var start: Double
        var end: Double
        var editTime = 0.0
        var minimumTime = 0.0
        var maximumTime = 0.0
        var hasMoved = false
        var movable = true
        var chooserIDs: [UUID]? = nil
        var pointerMoved = false
        var originY: CGFloat = 0
    }
    private var drag: Drag?
    private var scrubTime: Double?
    private var keyboardFocus = false
    private var lastFitRequest: UUID?
    private var railWidth: CGFloat { max(1, bounds.width - 24) }
    private var minimumLength: Double { min(0.1, duration) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 72) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Recording timeline")
        setAccessibilityHelp("Drag the top playhead to scrub or the blue handles to trim. Click an individual edit to select it, or drag to move its time. Count badges contain nearby edits; click to choose one. Dragging a badge moves only its selected edit. Click empty space below the track to clear selection. Escape cancels an unfinished move. Pinch to separate nearby edits; scroll to navigate time.")
    }
    required init?(coder: NSCoder) { nil }

    func fit(request: UUID?) {
        guard let request, request != lastFitRequest else { return }
        lastFitRequest = request
        setViewport(start: 0, span: duration)
    }

    func x(for time: Double) -> CGFloat {
        12 + CGFloat((min(max(time, 0), max(0, duration)) - visibleStart) / max(visibleDuration, .leastNonzeroMagnitude)) * railWidth
    }

    private func time(for x: CGFloat) -> Double {
        min(max(visibleStart + Double((x - 12) / railWidth) * visibleDuration, 0), duration)
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
        tooltipText[base] = "Drag the playhead to scrub, blue handles to trim, or an individual edit to move its time. Click a count badge to choose among nearby edits before dragging. Pinch to separate edits; scroll to navigate time."
        for group in markerGroups() {
            tooltipText[addToolTip(group.frame, owner: self, userData: nil)] = help(for: group)
        }
        for label in markerLabels() {
            if let marker = edits.first(where: { $0.id == label.id }) {
                tooltipText[addToolTip(label.frame, owner: self, userData: nil)] = marker.label.map { marker.help.hasPrefix($0) ? marker.help : $0 + ": " + marker.help } ?? marker.help
            }
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
        let retained = CGRect(x: x(for: start), y: 21, width: max(1, x(for: end) - x(for: start)), height: 6).intersection(rail)
        if !retained.isNull { NSBezierPath(rect: retained).fill() }
        for boundary in [start, end] where markerIsVisible(boundary) {
            let handle = CGRect(x: x(for: boundary) - 5, y: 14, width: 10, height: 20)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: handle.insetBy(dx: 4, dy: 6), xRadius: 1, yRadius: 1).fill()
        }
        let cursorX = x(for: current)
        if markerIsVisible(current) {
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
        }
        // Edits have their own lane, so the white playhead and trim handles
        // remain independent even when all three share a source time.
        NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setStroke()
        let editRail = NSBezierPath()
        editRail.move(to: CGPoint(x: 12, y: 47))
        editRail.line(to: CGPoint(x: bounds.width - 12, y: 47))
        editRail.lineWidth = 1
        editRail.stroke()
        if let selected = edits.first(where: { $0.id == selectedEditID }) {
            drawTransitionBand(for: selected)
        }
        for group in markerGroups() {
            if group.isCluster { drawCluster(group, start: start, end: end); continue }
            guard let marker = edits.first(where: { $0.id == group.ids[0] }) else { continue }
            let dragged = drag?.interaction == .edit(marker.id)
            let markerTime = dragged ? drag?.editTime ?? marker.time : marker.time
            let center = CGPoint(x: x(for: markerTime), y: 47)
            let selected = marker.id == selectedEditID || (dragged && drag?.hasMoved == true)
            let radius: CGFloat = selected ? 6 : 5
            let diamond = NSBezierPath()
            diamond.move(to: CGPoint(x: center.x, y: center.y - radius))
            diamond.line(to: CGPoint(x: center.x + radius, y: center.y))
            diamond.line(to: CGPoint(x: center.x, y: center.y + radius))
            diamond.line(to: CGPoint(x: center.x - radius, y: center.y))
            diamond.close()
            NSColor.systemPurple.withAlphaComponent(markerTime >= start && markerTime <= end ? 1 : 0.35).setFill()
            diamond.fill()
            if selected {
                NSColor.labelColor.setStroke()
                diamond.lineWidth = 2
                diamond.stroke()
            }
        }
        drawMarkerLabels()
        drawTimeTicks()
        if keyboardFocus, window?.firstResponder === self, markerIsVisible(current) {
            NSColor.keyboardFocusIndicatorColor.setFill()
            NSBezierPath(roundedRect: CGRect(x: cursorX - 7, y: 35, width: 14, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    /// A count replaces overlapping hit targets. Recheck the resulting badges,
    /// whose widths depend on their counts/selection, so no two targets overlap.
    func markerGroups() -> [MarkerGroup] {
        let visible = edits.filter { markerIsVisible(displayTime(for: $0)) }.sorted {
            let first = displayTime(for: $0), second = displayTime(for: $1)
            return first == second ? $0.id.uuidString < $1.id.uuidString : first < second
        }
        let selectedIndex = visible.firstIndex { $0.id == selectedEditID }
        func layout(_ range: Range<Int>) -> (frame: CGRect, text: String, selectedID: UUID?) {
            let selected = selectedIndex.flatMap { range.contains($0) ? visible[$0] : nil }
            let token = selected?.label.map { label in
                let segment = label.components(separatedBy: " · ").first ?? label
                return String((segment.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? segment).prefix(3))
            }
            let text = range.count > 1 ? token.map { $0 + " · " + String(range.count) } ?? String(range.count) : ""
            let width = range.count > 1 ? max(24, ceil((text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold)]).width) + 12) : 16
            let center = (x(for: displayTime(for: visible[range.lowerBound])) + x(for: displayTime(for: visible[range.upperBound - 1]))) / 2
            return (CGRect(x: min(max(0, center - width / 2), max(0, bounds.width - width)), y: 38, width: width, height: 18),
                    text, selected?.id)
        }
        // A stack of index ranges keeps a dense timeline linear after sorting,
        // rather than repeatedly copying or scanning every collapsed member.
        var ranges: [Range<Int>] = []
        for index in visible.indices {
            ranges.append(index..<(index + 1))
            while ranges.count > 1 {
                let left = ranges[ranges.count - 2], right = ranges[ranges.count - 1]
                guard layout(left).frame.insetBy(dx: -1, dy: 0).intersects(layout(right).frame.insetBy(dx: -1, dy: 0)) else { break }
                ranges.removeLast(2)
                ranges.append(left.lowerBound..<right.upperBound)
            }
        }
        return ranges.map { range in
            let value = layout(range)
            return MarkerGroup(ids: range.map { visible[$0].id }, frame: value.frame, text: value.text, selectedID: value.selectedID)
        }
    }

    private func help(for group: MarkerGroup) -> String {
        guard group.isCluster else {
            guard let marker = edits.first(where: { $0.id == group.ids.first }) else { return "" }
            return marker.label.map { marker.help.hasPrefix($0) ? marker.help : $0 + ": " + marker.help } ?? marker.help
        }
        let selection = group.selectedID.flatMap { id in edits.first { $0.id == id } }
        let selected = selection.map {
            " \($0.label ?? "An edit") is selected." + ($0.movable ? " Drag to move only that edit." : " Its time is fixed.")
        } ?? " Choose an edit before dragging."
        return "\(group.ids.count) nearby edits. Click to choose an action and time; pinch to separate them." + selected
    }

    private func drawCluster(_ group: MarkerGroup, start: Double, end: Double) {
        let ids = Set(group.ids)
        let retained = edits.contains { ids.contains($0.id) && displayTime(for: $0) >= start && displayTime(for: $0) <= end }
        NSColor.systemPurple.withAlphaComponent(retained ? 0.9 : 0.35).setFill()
        let badge = NSBezierPath(roundedRect: group.frame.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5)
        badge.fill()
        if group.selectedID != nil {
            NSColor.labelColor.setStroke(); badge.lineWidth = 2; badge.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white]
        let text = group.text as NSString
        let width = text.size(withAttributes: attributes).width
        text.draw(at: CGPoint(x: group.frame.midX - width / 2, y: group.frame.minY + 3), withAttributes: attributes)
    }

    /// Labels belong only to individually visible targets. Cluster members are
    /// identified by action and time in the native chooser instead.
    func markerLabels() -> [MarkerLabel] {
        let groups = markerGroups()
        let individuals = Set(groups.filter { !$0.isCluster }.flatMap(\.ids))
        let visible = edits.filter { individuals.contains($0.id) }
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        var labels: [MarkerLabel] = []
        let ordered = visible.sorted { ($0.id == selectedEditID ? 0 : 1) < ($1.id == selectedEditID ? 0 : 1) }
        for marker in ordered {
            guard let label = marker.label, !label.isEmpty else { continue }
            let text = label.hasPrefix("Edit ") ? String(label.dropFirst(5)) : label
            let width = min(70, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 6)
            let center = x(for: displayTime(for: marker))
            let candidates = [CGRect(x: center + 8, y: 39, width: width, height: 16),
                              CGRect(x: center - 8 - width, y: 39, width: width, height: 16)]
            let available = candidates.first { candidate in
                candidate.minX >= 0 && candidate.maxX <= bounds.width &&
                    !groups.contains { other in
                        !other.ids.contains(marker.id) && candidate.insetBy(dx: -2, dy: 0).intersects(other.frame)
                    } && !labels.contains { $0.frame.insetBy(dx: -2, dy: 0).intersects(candidate) }
            }
            if let available { labels.append(MarkerLabel(id: marker.id, text: text, frame: available, overlaysMarker: false)) }
            else if marker.id == selectedEditID {
                let frame = CGRect(x: min(max(0, center - width / 2), max(0, bounds.width - width)),
                                   y: 39, width: width, height: 16)
                if !groups.contains(where: { !$0.ids.contains(marker.id) && $0.frame.insetBy(dx: -2, dy: 0).intersects(frame) }) {
                    labels.append(MarkerLabel(id: marker.id, text: text, frame: frame, overlaysMarker: true))
                }
            }
        }
        return labels
    }

    private func displayTime(for marker: RecordingTimelineMarker) -> Double {
        drag?.interaction == .edit(marker.id) ? drag?.editTime ?? marker.time : marker.time
    }

    private func drawMarkerLabels() {
        for label in markerLabels().reversed() {
            let selected = label.id == selectedEditID
            (label.overlaysMarker ? NSColor.systemPurple : NSColor.windowBackgroundColor).setFill()
            NSBezierPath(roundedRect: label.frame, xRadius: 3, yRadius: 3).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: label.overlaysMarker ? NSColor.white : selected ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]
            let text = label.text as NSString
            let width = text.size(withAttributes: attributes).width
            text.draw(at: CGPoint(x: label.frame.midX - width / 2, y: label.frame.minY + 2), withAttributes: attributes)
        }
    }

    private var minimumVisibleDuration: Double {
        let frame = frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30
        return min(max(duration, .leastNonzeroMagnitude), max(frame * 4, duration / 1000))
    }

    private func markerIsVisible(_ time: Double) -> Bool {
        time.isFinite && time >= visibleStart && time <= visibleStart + visibleDuration
    }

    private func constrainViewport(reset: Bool = false) {
        guard duration.isFinite, duration > 0 else { return }
        setViewport(start: reset ? 0 : visibleStart, span: reset ? duration : visibleDuration)
    }

    private func setViewport(start: Double, span: Double) {
        guard start.isFinite, span.isFinite, duration.isFinite, duration > 0 else { return }
        visibleDuration = min(duration, max(minimumVisibleDuration, span))
        visibleStart = min(max(start, 0), max(0, duration - visibleDuration))
        needsDisplay = true
        updateTooltips()
    }

    override func magnify(with event: NSEvent) {
        guard drag == nil, duration.isFinite, duration > 0, event.magnification.isFinite else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !event.phase.contains(.cancelled) else { return }
        let fraction = min(1, max(0, Double((point.x - 12) / railWidth)))
        let anchor = visibleStart + fraction * visibleDuration
        let nextSpan = min(duration, max(minimumVisibleDuration, visibleDuration / max(0.01, 1 + event.magnification)))
        setViewport(start: anchor - fraction * nextSpan, span: nextSpan)
    }

    override func scrollWheel(with event: NSEvent) {
        guard drag == nil, duration.isFinite, duration > 0,
              !event.phase.contains(.cancelled), !event.momentumPhase.contains(.cancelled) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) || !event.momentumPhase.isEmpty else { return }
        let delta = event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta.isFinite else { return }
        // AppKit already applies the user's natural-scroll preference. Move
        // the time content with the fingers, including inertial scrolling.
        let units = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        setViewport(start: visibleStart - delta * units * visibleDuration / railWidth, span: visibleDuration)
    }

    private func drawTransitionBand(for marker: RecordingTimelineMarker) {
        guard let transitionStart = marker.transitionStart, transitionStart.isFinite,
              marker.time > transitionStart else { return }
        let offset = drag?.interaction == .edit(marker.id) ? (drag?.editTime ?? marker.time) - marker.time : 0
        let from = x(for: transitionStart + offset)
        let to = x(for: marker.time + offset)
        guard to - from >= 20, to >= 12, from <= bounds.width - 12 else { return }
        let duration = marker.time - transitionStart
        let first = min(duration, max(0, marker.easeIn.isFinite ? marker.easeIn : 0))
        let last = min(duration - first, max(0, marker.easeOut.isFinite ? marker.easeOut : 0))
        let riseEnd = x(for: transitionStart + offset + first)
        let fallStart = x(for: marker.time + offset - last)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: 12, y: 38, width: railWidth, height: 18)).addClip()
        let band = NSBezierPath()
        band.move(to: CGPoint(x: from, y: 53))
        band.line(to: CGPoint(x: riseEnd, y: 41))
        band.line(to: CGPoint(x: fallStart, y: 41))
        band.line(to: CGPoint(x: to, y: 53))
        band.close()
        NSColor.systemPurple.withAlphaComponent(0.25).setFill()
        band.fill()
        NSColor.systemPurple.withAlphaComponent(0.75).setStroke()
        band.lineWidth = 1
        band.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawTimeTicks() {
        let targetStep = visibleDuration / max(1, Double(railWidth / 90))
        let magnitude = pow(10, floor(log10(max(targetStep, .leastNonzeroMagnitude))))
        let step = ([1.0, 2, 5, 10].first { $0 * magnitude >= targetStep } ?? 10) * magnitude
        let decimals = min(3, max(0, Int(-floor(log10(step)))))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let last = visibleStart + visibleDuration
        var tick = ceil(visibleStart / step) * step
        while tick <= last + step * 0.000_001 {
            let position = x(for: tick)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: position, y: 57))
            path.line(to: CGPoint(x: position, y: 60))
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            let text = String(format: "%.*f s", decimals, tick) as NSString
            let width = text.size(withAttributes: attributes).width
            let labelX = min(max(position - width / 2, 0), bounds.width - width)
            text.draw(at: CGPoint(x: labelX, y: 61), withAttributes: attributes)
            tick += step
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            keyboardFocus = NSApplication.shared.currentEvent?.type == .keyDown ||
                (window?.keyViewSelectionDirection ?? .directSelection) != .directSelection
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keyboardFocus = false; needsDisplay = true }
        return resigned
    }

    private func chooseEdits(_ ids: [UUID], at point: NSPoint) {
        let markers = ids.compactMap { id in edits.first { $0.id == id } }.sorted {
            $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time < $1.time
        }
        guard !markers.isEmpty else { return }
        let menu = NSMenu(title: "Choose edit")
        menu.autoenablesItems = false
        for marker in markers {
            let item = NSMenuItem(title: "\(marker.label ?? marker.help) · \(String(format: "%.3f s", marker.time))",
                                 action: #selector(chooseMarker(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = marker.id
            item.toolTip = marker.help
            item.state = marker.id == selectedEditID ? .on : .off
            menu.addItem(item)
        }
        activeMarkerMenu = menu
        if let presentMarkerMenu { presentMarkerMenu(menu, point) }
        else { menu.popUp(positioning: nil, at: point, in: self); activeMarkerMenu = nil }
    }

    @objc private func chooseMarker(_ item: NSMenuItem) {
        guard item.menu === activeMarkerMenu, let id = item.representedObject as? UUID,
              edits.contains(where: { $0.id == id }) else { return }
        activeMarkerMenu = nil
        onSelectEdit?(id)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        markerGroups().map { group in
            let name: String
            if group.isCluster { name = "Choose among \(group.ids.count) nearby edits" }
            else if let marker = edits.first(where: { $0.id == group.ids[0] }) {
                name = "Select \(marker.label ?? marker.help) at \(String(format: "%.3f", marker.time)) seconds"
            } else { name = "Select edit" }
            return NSAccessibilityCustomAction(name: name) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    if group.isCluster { self.chooseEdits(group.ids, at: NSPoint(x: group.frame.midX, y: group.frame.maxY)) }
                    else if let id = group.ids.first, self.edits.contains(where: { $0.id == id }) { self.onSelectEdit?(id) }
                    return true
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard duration.isFinite, duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        keyboardFocus = false
        needsDisplay = true
        window?.makeFirstResponder(self)
        onInteractionBegan?()
        if point.y >= 38 && point.y < 56 {
            let labelTarget = markerLabels().first { $0.frame.contains(point) }?.id
            let target = markerGroups().first { group in
                if let labelTarget { return group.ids.contains(labelTarget) }
                return group.frame.contains(point)
            }
            if let target, target.isCluster, target.selectedID == nil {
                drag = Drag(interaction: .cluster, originX: point.x, originTime: playhead,
                            start: trimStart, end: trimEnd, chooserIDs: target.ids, originY: point.y)
            } else if let target, let id = target.selectedID ?? target.ids.first,
                      let marker = edits.first(where: { $0.id == id }) {
                let others = edits.filter { $0.id != marker.id && $0.time.isFinite }
                let gap = frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30
                let previous = others.filter { $0.time < marker.time }.map(\.time).max()
                let following = others.filter { $0.time > marker.time }.map(\.time).min()
                // Existing projects may have off-grid or unusually close edits.
                // Preserve the original time while preventing new collisions.
                let requestedMinimum = marker.minimumTime.isFinite ? marker.minimumTime : 0
                let requestedMaximum = marker.maximumTime.flatMap { $0.isFinite ? $0 : nil } ?? duration
                let minimum = max(requestedMinimum, max(0, min(marker.time, previous.map { $0 + gap } ?? 0)))
                let maximum = min(requestedMaximum, min(duration, max(marker.time, following.map { $0 - gap } ?? duration)))
                drag = Drag(interaction: .edit(marker.id), originX: point.x, originTime: marker.time,
                            start: trimStart, end: trimEnd, editTime: marker.time,
                            minimumTime: minimum, maximumTime: maximum, movable: marker.movable && minimum <= maximum,
                            chooserIDs: target.isCluster ? target.ids : nil, originY: point.y)
            } else {
                drag = Drag(interaction: .emptyEditLane, originX: point.x, originTime: playhead,
                            start: trimStart, end: trimEnd)
            }
            return
        }
        guard point.y < 36 else { return }
        let startDistance = markerIsVisible(trimStart) ? abs(point.x - x(for: trimStart)) : .infinity
        let endDistance = markerIsVisible(trimEnd) ? abs(point.x - x(for: trimEnd)) : .infinity
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
        drag.pointerMoved = drag.pointerMoved || max(abs(point.x - drag.originX), abs(point.y - drag.originY)) >= 3
        self.drag = drag
        let next = drag.originTime + Double((point.x - drag.originX) / railWidth) * visibleDuration
        switch drag.interaction {
        case .emptyEditLane, .cluster: break
        case .scrub: seek(next)
        case .start: drag.start = min(max(next, 0), drag.end - minimumLength)
        case .end: drag.end = max(min(next, duration), drag.start + minimumLength)
        case .edit(let id):
            guard drag.movable, drag.hasMoved || abs(point.x - drag.originX) >= 3 else { return }
            let firstMovement = !drag.hasMoved
            drag.hasMoved = true
            let step = frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30
            drag.editTime = min(max((next / step).rounded() * step, drag.minimumTime), drag.maximumTime)
            self.drag = drag
            if firstMovement, drag.chooserIDs == nil { onSelectEdit?(id) }
            onMoveEdit?(id, drag.editTime, false)
        }
        self.drag = drag
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        scrubTime = nil
        switch drag.interaction {
        case .cluster:
            if !drag.pointerMoved, let ids = drag.chooserIDs {
                chooseEdits(ids, at: convert(event.locationInWindow, from: nil))
            }
        case .emptyEditLane: onDeselectEdit?()
        case .scrub: onScrubEnded?()
        case .start, .end:
            if drag.start != trimStart || drag.end != trimEnd { onTrim?(drag.start, drag.end) }
        case .edit(let id):
            if drag.hasMoved { onMoveEdit?(id, drag.editTime, true) }
            else if !drag.pointerMoved, let ids = drag.chooserIDs {
                chooseEdits(ids, at: convert(event.locationInWindow, from: nil))
            }
            else if drag.chooserIDs == nil { onSelectEdit?(id) }
        }
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        if let activeMarkerMenu { activeMarkerMenu.cancelTracking(); self.activeMarkerMenu = nil; return }
        let active = drag
        drag = nil
        scrubTime = nil
        if let active, case .edit = active.interaction, active.hasMoved {
            onCancelMoveEdit?()
        } else {
            if active?.interaction == .scrub { onScrubEnded?() }
            onCancelEdit?()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        guard event.keyCode == 123 || event.keyCode == 124 else { super.keyDown(with: event); return }
        keyboardFocus = true
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
        keyboardFocus = true
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
