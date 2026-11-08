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
    static let animationLaneHeight: CGFloat = 150
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let playhead: Double
    var onInteractionBegan: () -> Void
    var onSeek: (Double) -> Void
    var onScrubBegan: () -> Void = {}
    var onScrubEnded: () -> Void = {}
    var onTrim: (Double, Double) -> Void
    var onTrimPlayhead: (Double) -> Void = { _ in }
    var edits: [RecordingTimelineMarker] = []
    var selectedEditID: UUID?
    var onSelectEdit: (UUID) -> Void = { _ in }
    var frameDuration: Double = 1.0 / 30
    var onMoveEdit: (UUID, Double, Bool) -> Void = { _, _, _ in }
    var onCancelMoveEdit: () -> Void = {}
    var onDeselectEdit: () -> Void = {}
    var onCancelEdit: () -> Void = {}
    var fitRequest: UUID?
    var conflictSpans: [EditorConflictSpan] = []
    var conflictOverlaps: [ClosedRange<Double>] = []
    var showsAnimationLanes = false
    var pointerClickTimes: [Double] = []
    var animations: [TimelineAnimation] = []
    var selectedAnimationID: TimelineAnimationID?
    var onSelectAnimation: (TimelineAnimationID) -> Void = { _ in }
    var onAnimationEdit: (AnimationDrag, Bool) -> Void = { _, _ in }
    var onAnimationCancel: () -> Void = {}
    var onDeleteAnimation: (TimelineAnimationID) -> Void = { _ in }

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
        view.onTrimPlayhead = onTrimPlayhead
        view.edits = edits
        view.selectedEditID = selectedEditID
        view.onSelectEdit = onSelectEdit
        view.frameDuration = frameDuration
        view.onMoveEdit = onMoveEdit
        view.onCancelMoveEdit = onCancelMoveEdit
        view.onDeselectEdit = onDeselectEdit
        view.onCancelEdit = onCancelEdit
        view.conflictSpans = conflictSpans
        view.conflictOverlaps = conflictOverlaps
        view.showsAnimationLanes = showsAnimationLanes
        view.pointerClickTimes = pointerClickTimes
        view.animationSpans = animations
        view.selectedAnimationID = selectedAnimationID
        view.onSelectAnimation = onSelectAnimation
        view.onAnimationEdit = onAnimationEdit
        view.onAnimationCancel = onAnimationCancel
        view.onDeleteAnimation = onDeleteAnimation
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
    struct ConflictBand: Equatable {
        let span: EditorConflictSpan
        let frame: CGRect
    }
    struct AnimationLaneGeometry: Equatable {
        let lane: TimelineAnimationLane
        let title: String
        let frame: CGRect
        let labelFrame: CGRect
    }
    struct AnimationCrowdGeometry: Equatable {
        let ids: [TimelineAnimationID]
        let frame: CGRect
        let sourceX: CGFloat
    }
    struct PointerClickGeometry: Equatable {
        let time: Double
        let frame: CGRect
    }
    struct AnimationGeometry: Equatable {
        let animation: TimelineAnimation
        let body: CGRect
        let labelFrame: CGRect
        let startHandle: CGRect?
        let endHandle: CGRect?
        let easeInHandle: CGRect?
        let easeOutHandle: CGRect?
        let deleteButton: CGRect?
    }
    var showsAnimationLanes = false {
        didSet {
            guard showsAnimationLanes != oldValue else { return }
            cancelAnimationGesture()
            invalidateIntrinsicContentSize()
            needsDisplay = true; updateTooltips()
            setAccessibilityHelp(showsAnimationLanes
                ? "Screen, Camera and Pointer use one source-time axis. Drag a span to move it; selected edge handles resize it and inner dots change its ramps. Option-drag pushes same-lane neighbors. Delete removes the selected animation. Escape cancels a preview. Pinch to reveal fine controls."
                : "Drag the playhead to scrub or the blue handles to trim. Click an edit to select it, or drag to move its time. Pinch to separate nearby edits; scroll to navigate time.")
        }
    }
    var pointerClickTimes: [Double] = [] {
        didSet { if pointerClickTimes != oldValue { needsDisplay = true; updateTooltips() } }
    }
    var animationSpans: [TimelineAnimation] = [] {
        didSet {
            guard animationSpans != oldValue else { return }
            needsDisplay = true; updateTooltips()
        }
    }
    var selectedAnimationID: TimelineAnimationID? { didSet { if selectedAnimationID != oldValue { needsDisplay = true; updateTooltips() } } }
    var onSelectAnimation: ((TimelineAnimationID) -> Void)?
    var onAnimationEdit: ((AnimationDrag, Bool) -> Void)?
    var onAnimationCancel: (() -> Void)?
    var onDeleteAnimation: ((TimelineAnimationID) -> Void)?
    var presentAnimationMenu: ((NSMenu, NSPoint) -> Void)?
    private(set) var blockedAnimationIDs = Set<TimelineAnimationID>()
    private struct AnimationGesture {
        let id: TimelineAnimationID
        let handle: TimelineAnimationHandle
        let origin: CGPoint
        let base: [TimelineAnimation]
        var hasMoved = false
        var lastRequest: AnimationDrag?
        var valid = true
        var snappedDelta: Double?
    }
    private var animationGesture: AnimationGesture?
    private var animationPreview: [TimelineAnimation]?
    private var blockedAnimation: TimelineAnimation?
    private var animationClickID: TimelineAnimationID?
    private var animationDeleteID: TimelineAnimationID?
    private var animationChooserIDs: [TimelineAnimationID]?
    private var animationEmptyClick = false
    private var animationPointerOrigin: CGPoint?
    private var activeAnimationMenu: NSMenu?
    var conflictSpans: [EditorConflictSpan] = [] {
        didSet { if conflictSpans != oldValue { needsDisplay = true; updateTooltips() } }
    }
    var conflictOverlaps: [ClosedRange<Double>] = [] {
        didSet { if conflictOverlaps != oldValue { needsDisplay = true; updateTooltips() } }
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
    var onTrimPlayhead: ((Double) -> Void)?
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
        var originalPlayhead: Double? = nil
    }
    private var drag: Drag?
    private var scrubTime: Double?
    private var keyboardFocus = false
    private var lastFitRequest: UUID?
    private var railOrigin: CGFloat { showsAnimationLanes ? 64 : 12 }
    private var railWidth: CGFloat { max(1, bounds.width - railOrigin - 12) }
    private var minimumLength: Double { min(0.1, duration) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: showsAnimationLanes ? RecordingTimeline.animationLaneHeight : 72) }

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
        railOrigin + CGFloat((min(max(time, 0), max(0, duration)) - visibleStart) / max(visibleDuration, .leastNonzeroMagnitude)) * railWidth
    }

    private func time(for x: CGFloat) -> Double {
        min(max(visibleStart + Double((x - railOrigin) / railWidth) * visibleDuration, 0), duration)
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
        tooltipText[base] = showsAnimationLanes ? "Drag spans to move; selected edges resize and dots adjust ramps. Option-drag pushes neighbors. Pinch for finer controls." : "Drag the playhead to scrub, blue handles to trim, or an individual edit to move its time. Click a count badge to choose among nearby edits before dragging. Pinch to separate edits; scroll to navigate time."
        for band in conflictBands() {
            let side = band.span.side == .existing ? "Existing" : "Proposed"
            tooltipText[addToolTip(band.frame.insetBy(dx: -2, dy: -2), owner: self, userData: nil)] =
                "\(side): \(band.span.help) Click to review this source time."
        }
        for interval in conflictOverlaps {
            if let frame = conflictFrame(start: interval.lowerBound, end: interval.upperBound, y: 0, height: 12) {
                tooltipText[addToolTip(frame, owner: self, userData: nil)] = String(format:
                    "Existing and proposed framing overlap from %.3f to %.3f seconds. Click to review; no changes are applied.", interval.lowerBound, interval.upperBound)
            }
        }
        if showsAnimationLanes {
            for crowd in animationCrowds() {
                tooltipText[addToolTip(crowd.frame, owner: self, userData: nil)] = "\(crowd.ids.count) crowded animations or reference marks. Click to choose by name and source interval."
            }
            for click in pointerClickGeometry() {
                tooltipText[addToolTip(click.frame.insetBy(dx: -2, dy: -2), owner: self, userData: nil)] = String(format: "Recorded click at %.3f seconds.", click.time)
            }
            for item in animationGeometry() {
                tooltipText[addToolTip(item.body.union(item.labelFrame), owner: self, userData: nil)] = item.animation.help
                let handles: [(CGRect?, String)] = [(item.startHandle, item.animation.isInstant ? "Drag left to animate into this target." : "Drag to change the animation start."),
                    (item.endHandle, "Drag to change the animation end."), (item.easeInHandle, "Drag to change the acceleration ramp."),
                    (item.easeOutHandle, "Drag to change the deceleration ramp."), (item.deleteButton, "Delete this animation.")]
                for (frame, help) in handles { if let frame { tooltipText[addToolTip(frame, owner: self, userData: nil)] = help } }
            }
            return
        }
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
        drawConflictReview(keptStart: start, keptEnd: end)
        let rail = CGRect(x: railOrigin, y: 21, width: railWidth, height: 6)
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
        if showsAnimationLanes {
            drawAnimationLanes()
            drawTimeTicks()
            return
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

    func animationLanes() -> [AnimationLaneGeometry] {
        TimelineAnimationLane.allCases.enumerated().map { index, lane in
            let y = CGFloat(40 + index * 30)
            let title: String = switch lane { case .screen: "Screen"; case .camera: "Camera"; case .pointer: "Pointer" }
            return AnimationLaneGeometry(lane: lane, title: title,
                frame: CGRect(x: railOrigin, y: y, width: railWidth, height: 26),
                labelFrame: CGRect(x: 8, y: y + 5, width: 52, height: 16))
        }
    }

    func pointerClickGeometry() -> [PointerClickGeometry] {
        pointerClickTimes.filter { $0.isFinite && $0 >= 0 && $0 <= duration && markerIsVisible($0) }.map {
            PointerClickGeometry(time: $0, frame: CGRect(x: x(for: $0) - 1, y: 123, width: 2, height: 3))
        }
    }

    private var displayedAnimations: [TimelineAnimation] {
        if let gesture = animationGesture { return animationPreview ?? gesture.base }
        return animationSpans
    }

    func animationGeometry() -> [AnimationGeometry] {
        let selected = animationGesture?.id ?? selectedAnimationID
        return displayedAnimations.compactMap { animation in
            guard animation.start.isFinite, animation.end.isFinite, animation.start <= animation.end,
                  animation.end >= visibleStart, animation.start <= visibleStart + visibleDuration,
                  let lane = animationLanes().first(where: { $0.lane == animation.lane }) else { return nil }
            let left = max(railOrigin, x(for: animation.start)), right = min(bounds.width - 12, x(for: animation.end))
            guard right >= left else { return nil }
            let width = max(6, right - left)
            let body = CGRect(x: animation.isInstant ? left - 3 : left, y: lane.frame.minY + 7, width: width, height: 17)
            let textWidth = min(130, ceil((animation.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)]).width))
            let editable = animation.id == selected && animation.editable
            let labelX = width >= textWidth + 8 ? body.minX + 4 : body.maxX + (editable ? 18 : 4)
            let label = CGRect(x: min(max(railOrigin, labelX), max(railOrigin, bounds.width - 12 - textWidth)),
                y: body.minY + 2, width: textWidth, height: 13)
            let timing = editable && !animation.isReference
            let wide = width >= 80 && !animation.isInstant
            let start = timing ? CGRect(x: left - 4, y: lane.frame.minY + (wide ? 8 : 0), width: 8, height: wide ? 10 : 8) : nil
            let end = timing && !animation.isInstant ? CGRect(x: right - 4, y: lane.frame.minY + (wide ? 8 : 18), width: 8, height: wide ? 10 : 8) : nil
            let easeIn = timing && wide ? CGRect(x: x(for: animation.start + animation.easeIn) - 3.5, y: lane.frame.minY, width: 7, height: 7) : nil
            let easeOut = timing && wide ? CGRect(x: x(for: animation.end - animation.easeOut) - 3.5, y: lane.frame.minY + 19, width: 7, height: 7) : nil
            let deletion = editable ? CGRect(x: min(body.maxX + 4, bounds.width - 24), y: lane.frame.minY + 9, width: 10, height: 10) : nil
            return AnimationGeometry(animation: animation, body: body, labelFrame: label, startHandle: start,
                endHandle: end, easeInHandle: easeIn, easeOutHandle: easeOut, deleteButton: deletion)
        }
    }

    /// External labels can cover a very short neighboring Hold/Zoom. Keep
    /// every body visible and expose each crowded group in a native chooser.
    func animationCrowds() -> [AnimationCrowdGeometry] {
        let geometry = animationGeometry()
        let handles = geometry.flatMap { [$0.startHandle, $0.endHandle, $0.easeInHandle, $0.easeOutHandle].compactMap { $0 } }
        var result: [AnimationCrowdGeometry] = []
        for lane in animationLanes() {
            let ordered = geometry.filter { $0.animation.lane == lane.lane }.sorted {
                $0.animation.start == $1.animation.start ? $0.animation.end < $1.animation.end : $0.animation.start < $1.animation.start
            }
            var groups: [[AnimationGeometry]] = []
            for item in ordered {
                var members = [item]
                while let previous = groups.last,
                      previous.contains(where: { first in members.contains { second in
                          first.body.union(first.labelFrame).intersects(second.body.union(second.labelFrame))
                      } }) {
                    members = groups.removeLast() + members
                }
                groups.append(members)
            }
            for group in groups where group.count > 1 {
                let anchor = group.reduce(CGFloat.zero) { $0 + x(for: $1.animation.end) } / CGFloat(group.count)
                let width = max(18, CGFloat(String(group.count).count * 6 + 10))
                let candidates = [anchor - width / 2, anchor + 6, anchor - width - 6].map {
                    CGRect(x: min(max(railOrigin, $0), bounds.width - 12 - width), y: lane.frame.maxY, width: width, height: 11)
                }
                let frame = candidates.first { candidate in !handles.contains { $0.intersects(candidate) } &&
                    !result.contains { $0.frame.intersects(candidate) } } ?? candidates[0]
                result.append(AnimationCrowdGeometry(ids: group.map { $0.animation.id }, frame: frame, sourceX: anchor))
            }
        }
        return result
    }

    private func animationColor(_ lane: TimelineAnimationLane) -> NSColor {
        switch lane { case .screen: .systemPurple; case .camera: .systemTeal; case .pointer: .secondaryLabelColor }
    }

    /// Use source coordinates before viewport clipping so a partially visible
    /// movement retains its actual ramp shape when the timeline is magnified.
    func animationEnvelope(for item: AnimationGeometry) -> NSBezierPath {
        let animation = item.animation
        guard !animation.isInstant, !animation.isReference, animation.lane != .pointer else {
            return NSBezierPath(roundedRect: item.body, xRadius: 2, yRadius: 2)
        }
        let envelope = NSBezierPath()
        envelope.move(to: CGPoint(x: x(for: animation.start), y: item.body.maxY))
        envelope.line(to: CGPoint(x: x(for: animation.start + animation.easeIn), y: item.body.minY + 3))
        envelope.line(to: CGPoint(x: x(for: animation.end - animation.easeOut), y: item.body.minY + 3))
        envelope.line(to: CGPoint(x: x(for: animation.end), y: item.body.maxY))
        envelope.close()
        return envelope
    }

    private func drawAnimationLanes() {
        for lane in animationLanes() {
            NSColor.black.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: lane.frame, xRadius: 3, yRadius: 3).fill()
            (lane.title as NSString).draw(in: lane.labelFrame, withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            if lane.lane != .screen, !displayedAnimations.contains(where: { $0.lane == lane.lane }) {
                ("Not recorded" as NSString).draw(at: CGPoint(x: railOrigin + 5, y: lane.frame.minY + 8), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor])
            }
        }
        drawConflictReview(keptStart: trimStart, keptEnd: trimEnd)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: railOrigin, y: 38, width: railWidth, height: 90)).addClip()
        for item in animationGeometry() {
            let animation = item.animation
            let selected = animation.id == (animationGesture?.id ?? selectedAnimationID)
            let color = blockedAnimationIDs.contains(animation.id) ? NSColor.systemRed : animationColor(animation.lane)
            let envelope = animationEnvelope(for: item)
            color.withAlphaComponent(selected ? 0.68 : 0.53).setFill()
            envelope.fill()
            color.withAlphaComponent(selected ? 1 : 0.85).setStroke()
            envelope.lineWidth = selected ? 1.5 : 1
            envelope.stroke()
            (animation.label as NSString).draw(in: item.labelFrame, withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.labelColor])
            for handle in [item.startHandle, item.endHandle].compactMap({ $0 }) {
                // Preserve the generous hit regions while painting quiet grips.
                color.setFill()
                let grip = CGRect(x: handle.midX - 1.5, y: handle.midY - 4, width: 3, height: 8)
                NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
            }
            for handle in [item.easeInHandle, item.easeOutHandle].compactMap({ $0 }) {
                let dot = handle.insetBy(dx: 1, dy: 1)
                color.setFill(); NSBezierPath(ovalIn: dot).fill()
            }
            if let button = item.deleteButton {
                NSColor.secondaryLabelColor.setStroke()
                let cross = NSBezierPath(); cross.lineWidth = 1.5
                cross.move(to: CGPoint(x: button.minX + 2, y: button.minY + 2)); cross.line(to: CGPoint(x: button.maxX - 2, y: button.maxY - 2))
                cross.move(to: CGPoint(x: button.maxX - 2, y: button.minY + 2)); cross.line(to: CGPoint(x: button.minX + 2, y: button.maxY - 2)); cross.stroke()
            }
        }
        NSColor.secondaryLabelColor.setFill()
        for click in pointerClickGeometry() { NSBezierPath(rect: click.frame).fill() }
        if let blockedAnimation, let lane = animationLanes().first(where: { $0.lane == blockedAnimation.lane }) {
            let rect = CGRect(x: x(for: blockedAnimation.start), y: lane.frame.minY + 6,
                width: max(6, x(for: blockedAnimation.end) - x(for: blockedAnimation.start)), height: 19)
            NSColor.systemRed.setStroke(); let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            outline.setLineDash([3, 2], count: 2, phase: 0); outline.lineWidth = 2; outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        for crowd in animationCrowds() {
            NSColor.secondaryLabelColor.setStroke()
            let leader = NSBezierPath()
            leader.move(to: CGPoint(x: crowd.sourceX, y: crowd.frame.minY - 2))
            leader.line(to: CGPoint(x: crowd.frame.midX, y: crowd.frame.minY + 1)); leader.stroke()
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: crowd.frame, xRadius: 4, yRadius: 4).fill()
            let text = String(crowd.ids.count) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold), .foregroundColor: NSColor.white]
            let width = text.size(withAttributes: attributes).width
            text.draw(at: CGPoint(x: crowd.frame.midX - width / 2, y: crowd.frame.minY), withAttributes: attributes)
        }
    }

    private func animationTargets(at point: CGPoint) -> [AnimationGeometry] {
        let geometry = animationGeometry()
        let bodies = geometry.filter { $0.body.contains(point) }
        return bodies.isEmpty ? geometry.filter { $0.labelFrame.contains(point) } : bodies
    }

    private func beginAnimationInteraction(at point: CGPoint) {
        animationPointerOrigin = point
        let geometry = animationGeometry()
        if let selected = geometry.first(where: { $0.animation.id == selectedAnimationID }) {
            if selected.deleteButton?.contains(point) == true { animationDeleteID = selected.animation.id; return }
            let handles: [(CGRect?, TimelineAnimationHandle)] = [(selected.easeInHandle, .easeIn), (selected.easeOutHandle, .easeOut),
                (selected.startHandle, .start), (selected.endHandle, .end)]
            for (frame, handle) in handles where frame?.contains(point) == true {
                animationPointerOrigin = point
                animationGesture = AnimationGesture(id: selected.animation.id, handle: handle, origin: point, base: animationSpans); return
            }
        }
        if let crowd = animationCrowds().first(where: { $0.frame.contains(point) }) {
            animationPointerOrigin = point; animationChooserIDs = crowd.ids; return
        }
        guard animationLanes().contains(where: { $0.frame.contains(point) || $0.labelFrame.contains(point) }) else { return }
        if conflictBands().contains(where: { $0.frame.contains(point) }) {
            onScrubBegan?()
            let sourceTime = time(for: point.x)
            seek(sourceTime)
            drag = Drag(interaction: .scrub, originX: point.x, originTime: sourceTime,
                start: trimStart, end: trimEnd, originY: point.y)
            return
        }
        animationPointerOrigin = point
        let targets = animationTargets(at: point)
        if targets.count > 1 { animationChooserIDs = targets.map { $0.animation.id }; return }
        if let target = targets.first {
            animationClickID = target.animation.id
            if target.animation.editable { animationGesture = AnimationGesture(id: target.animation.id, handle: .move, origin: point, base: animationSpans) }
        } else if let lane = animationLanes().first(where: { $0.labelFrame.contains(point) }),
                  let animation = animationSpans.first(where: { $0.lane == lane.lane }) {
            animationClickID = animation.id
        } else { animationEmptyClick = true }
    }

    private func snappedAnimationDelta(_ delta: Double, gesture: inout AnimationGesture) -> Double {
        guard gesture.handle == .move || gesture.handle == .start || gesture.handle == .end,
              let target = gesture.base.first(where: { $0.id == gesture.id }) else { return delta }
        let unit = visibleDuration / Double(railWidth)
        if let sticky = gesture.snappedDelta, abs(delta - sticky) <= unit * 10 { return sticky }
        gesture.snappedDelta = nil
        let others = gesture.base.filter { $0.id != target.id && $0.lane == target.lane && !$0.isReference }
        let candidates: [Double]
        switch gesture.handle {
        case .start: candidates = [-target.start] + others.map { $0.end - target.start }
        case .end: candidates = [duration - target.end] + others.map { $0.start - target.end }
        default: candidates = [-target.start, duration - target.end] + others.flatMap { [$0.end - target.start, $0.start - target.end] }
        }
        if let closest = candidates.min(by: { abs($0 - delta) < abs($1 - delta) }), abs(closest - delta) <= unit * 6 {
            gesture.snappedDelta = closest; return closest
        }
        return delta
    }

    private func dragAnimation(with event: NSEvent) {
        guard var gesture = animationGesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard gesture.hasMoved || max(abs(point.x - gesture.origin.x), abs(point.y - gesture.origin.y)) >= 3 else { return }
        gesture.hasMoved = true
        animationClickID = nil
        let raw = Double((point.x - gesture.origin.x) / railWidth) * visibleDuration
        let delta = snappedAnimationDelta(raw, gesture: &gesture)
        let request = AnimationDrag(id: gesture.id, handle: gesture.handle, deltaSeconds: delta,
            push: event.modifierFlags.contains(.option), snapTolerance: 0)
        guard let changed = TimelineAnimationSolver.solve(request, animations: gesture.base, duration: duration) else {
            if gesture.lastRequest != nil, gesture.valid { onAnimationCancel?() }
            gesture.valid = false; gesture.lastRequest = request
            animationPreview = nil
            if var target = gesture.base.first(where: { $0.id == gesture.id }) {
                switch gesture.handle {
                case .move: target.start += delta; target.end += delta
                case .start: target.start += delta
                case .end: target.end += delta
                case .easeIn, .easeOut: break
                }
                blockedAnimationIDs = collisionIDs(for: target, in: gesture.base)
                blockedAnimation = blockedAnimationIDs.isEmpty ? nil : target
            }
            animationGesture = gesture; needsDisplay = true; return
        }
        blockedAnimation = nil; blockedAnimationIDs.removeAll()
        gesture.valid = true; gesture.lastRequest = request
        let changes = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0) })
        animationPreview = gesture.base.map { changes[$0.id] ?? $0 }
        if var wanted = gesture.base.first(where: { $0.id == gesture.id }),
           let projected = animationPreview?.first(where: { $0.id == gesture.id }) {
            switch gesture.handle {
            case .move: wanted.start += delta; wanted.end += delta
            case .start: wanted.start += delta
            case .end: wanted.end += delta
            case .easeIn, .easeOut: break
            }
            if abs(wanted.start - projected.start) > 0.000_001 || abs(wanted.end - projected.end) > 0.000_001 {
                blockedAnimationIDs = collisionIDs(for: wanted, in: gesture.base)
                blockedAnimation = blockedAnimationIDs.isEmpty ? nil : wanted
            }
        }
        animationGesture = gesture
        onAnimationEdit?(request, false)
        needsDisplay = true; updateTooltips()
    }

    private func collisionIDs(for wanted: TimelineAnimation, in base: [TimelineAnimation]) -> Set<TimelineAnimationID> {
        var ids = Set(base.filter { $0.lane == wanted.lane && $0.id != wanted.id && !$0.isReference &&
            $0.start < wanted.end && $0.end > wanted.start }.map(\.id))
        if !ids.isEmpty || wanted.start < 0 || wanted.end > duration || wanted.start > wanted.end { ids.insert(wanted.id) }
        return ids
    }

    private func endAnimationInteraction(at point: CGPoint) {
        let gesture = animationGesture, clicked = animationClickID, deleted = animationDeleteID, chooser = animationChooserIDs, empty = animationEmptyClick
        let origin = animationPointerOrigin; animationPointerOrigin = nil
        animationGesture = nil; animationPreview = nil; blockedAnimation = nil; blockedAnimationIDs.removeAll()
        animationClickID = nil; animationDeleteID = nil; animationChooserIDs = nil; animationEmptyClick = false
        if gesture?.hasMoved != true, let origin, max(abs(point.x - origin.x), abs(point.y - origin.y)) >= 3 { needsDisplay = true; return }
        if let gesture, gesture.hasMoved {
            if gesture.valid, let request = gesture.lastRequest { onAnimationEdit?(request, true) }
            else { onAnimationCancel?() }
        } else if let deleted, animationSpans.contains(where: { $0.id == deleted && $0.editable }) { onDeleteAnimation?(deleted) }
        else if let chooser { chooseAnimations(chooser, at: point) }
        else if let clicked { onSelectAnimation?(clicked) }
        else if empty { onDeselectEdit?() }
        needsDisplay = true; updateTooltips()
    }

    private func cancelAnimationGesture() {
        let hadPreview = animationGesture?.hasMoved == true
        animationPointerOrigin = nil
        animationGesture = nil; animationPreview = nil; blockedAnimation = nil; blockedAnimationIDs.removeAll()
        animationClickID = nil; animationDeleteID = nil; animationChooserIDs = nil; animationEmptyClick = false
        if hadPreview { onAnimationCancel?() }
        needsDisplay = true
    }

    private func animationAccessibilityActions() -> [NSAccessibilityCustomAction] {
        var actions = displayedAnimations.map { animation in
            NSAccessibilityCustomAction(name: "Select \(animation.label) in \(animation.lane.rawValue), \(String(format: "%.3f to %.3f seconds", animation.start, animation.end))") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.animationSpans.contains(where: { $0.id == animation.id }) else { return false }
                    self.onSelectAnimation?(animation.id); return true
                }
            }
        }
        for crowd in animationCrowds() {
            actions.append(NSAccessibilityCustomAction(name: "Choose among \(crowd.ids.count) crowded animations") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    self.chooseAnimations(crowd.ids, at: CGPoint(x: crowd.frame.midX, y: crowd.frame.maxY)); return true
                }
            })
        }
        if let id = selectedAnimationID, let selected = animationSpans.first(where: { $0.id == id && $0.editable }) {
            actions.append(NSAccessibilityCustomAction(name: "Delete \(selected.label)") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.animationSpans.contains(where: { $0.id == id && $0.editable }) else { return false }
                    self.onInteractionBegan?(); self.onDeleteAnimation?(id); return true
                }
            })
        }
        return actions
    }

    private func chooseAnimations(_ ids: [TimelineAnimationID], at point: CGPoint) {
        let menu = NSMenu(title: "Choose animation"); menu.autoenablesItems = false
        for id in ids {
            guard let animation = animationSpans.first(where: { $0.id == id }) else { continue }
            let item = NSMenuItem(title: String(format: "%@ · %.3f–%.3f s", animation.label, animation.start, animation.end),
                action: #selector(chooseAnimation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; item.toolTip = animation.help
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else { return }
        activeAnimationMenu = menu
        if let presentAnimationMenu { presentAnimationMenu(menu, point) }
        else { menu.popUp(positioning: nil, at: point, in: self); activeAnimationMenu = nil }
    }

    @objc private func chooseAnimation(_ item: NSMenuItem) {
        guard item.menu === activeAnimationMenu, let id = item.representedObject as? TimelineAnimationID,
              animationSpans.contains(where: { $0.id == id }) else { return }
        activeAnimationMenu = nil; onSelectAnimation?(id)
    }

    @objc private func deleteAnimation(_ item: NSMenuItem) {
        guard item.menu === activeAnimationMenu, let id = item.representedObject as? TimelineAnimationID,
              animationSpans.contains(where: { $0.id == id && $0.editable }) else { return }
        activeAnimationMenu = nil; onInteractionBegan?(); onDeleteAnimation?(id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard showsAnimationLanes else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let targets = animationTargets(at: point)
        guard let target = targets.first(where: { $0.animation.id == selectedAnimationID }) ?? targets.first else { return nil }
        let menu = NSMenu(title: target.animation.label); menu.autoenablesItems = false
        let select = NSMenuItem(title: "Select \(target.animation.label)", action: #selector(chooseAnimation(_:)), keyEquivalent: "")
        select.target = self; select.representedObject = target.animation.id; menu.addItem(select)
        if target.animation.editable {
            let deletion = NSMenuItem(title: "Delete \(target.animation.label)", action: #selector(deleteAnimation(_:)), keyEquivalent: "")
            deletion.target = self; deletion.representedObject = target.animation.id; menu.addItem(deletion)
        }
        activeAnimationMenu = menu
        return menu
    }

    /// Conflict comparison uses the space above the scrub rail, preserving the
    /// edit lane and the timeline's height. The white playhead draws over it.
    func conflictBands() -> [ConflictBand] {
        conflictSpans.compactMap { span in
            guard let frame = conflictFrame(start: span.start, end: span.end,
                y: showsAnimationLanes ? (span.side == .existing ? 41 : 63) : (span.side == .existing ? 2 : 8), height: 3) else { return nil }
            return ConflictBand(span: span, frame: frame)
        }
    }

    private func conflictFrame(start: Double, end: Double, y: CGFloat, height: CGFloat) -> CGRect? {
        guard start.isFinite, end.isFinite, start <= end,
              end >= visibleStart, start <= visibleStart + visibleDuration,
              end >= 0, start <= duration else { return nil }
        let lower = max(railOrigin, x(for: start)), upper = min(bounds.width - 12, x(for: end))
        let width = max(start == end ? 4 : 2, upper - lower)
        let frame = CGRect(x: start == end ? lower - width / 2 : lower, y: y, width: width, height: height)
            .intersection(CGRect(x: railOrigin, y: y, width: railWidth, height: height))
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    private func drawConflictReview(keptStart: Double, keptEnd: Double) {
        let lane = CGRect(x: railOrigin, y: showsAnimationLanes ? 40 : 0, width: railWidth, height: showsAnimationLanes ? 26 : 12)
        func draw(alpha: CGFloat) {
            for interval in conflictOverlaps {
                guard let frame = conflictFrame(start: interval.lowerBound, end: interval.upperBound, y: lane.minY, height: lane.height) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: frame).addClip()
                NSColor.labelColor.withAlphaComponent(0.25 * alpha).setStroke()
                let hatch = NSBezierPath()
                var position = frame.minX - 12
                while position <= frame.maxX {
                    hatch.move(to: CGPoint(x: position, y: lane.maxY))
                    hatch.line(to: CGPoint(x: position + 12, y: lane.minY))
                    position += 6
                }
                hatch.lineWidth = 1; hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            for band in conflictBands() {
                let existing = band.span.side == .existing
                let color = (existing ? NSColor.systemOrange : NSColor.systemCyan).withAlphaComponent(alpha)
                color.setStroke(); color.setFill()
                if band.span.isInstant {
                    let tick = CGRect(x: x(for: band.span.start) - 2, y: band.frame.midY - 2, width: 4, height: 4)
                    if existing { NSBezierPath(rect: tick).fill() }
                    else { let ring = NSBezierPath(ovalIn: tick); ring.lineWidth = 1; ring.stroke() }
                    continue
                }
                let line = NSBezierPath()
                line.lineWidth = 3
                if !existing { line.setLineDash([4, 3], count: 2, phase: 0) }
                line.move(to: CGPoint(x: x(for: band.span.start), y: band.frame.midY))
                line.line(to: CGPoint(x: x(for: band.span.end), y: band.frame.midY))
                line.stroke()
            }
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: lane).addClip()
        draw(alpha: 0.28)
        NSBezierPath(rect: CGRect(x: x(for: keptStart), y: lane.minY,
            width: max(0, x(for: keptEnd) - x(for: keptStart)), height: lane.height)).addClip()
        draw(alpha: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A count replaces overlapping hit targets. Recheck the resulting badges,
    /// whose widths depend on their counts/selection, so no two targets overlap.
    func markerGroups() -> [MarkerGroup] {
        if showsAnimationLanes { return [] }
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
        guard drag == nil, animationGesture == nil, duration.isFinite, duration > 0, event.magnification.isFinite else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !event.phase.contains(.cancelled) else { return }
        let fraction = min(1, max(0, Double((point.x - railOrigin) / railWidth)))
        let anchor = visibleStart + fraction * visibleDuration
        let nextSpan = min(duration, max(minimumVisibleDuration, visibleDuration / max(0.01, 1 + event.magnification)))
        setViewport(start: anchor - fraction * nextSpan, span: nextSpan)
    }

    override func scrollWheel(with event: NSEvent) {
        guard drag == nil, animationGesture == nil, duration.isFinite, duration > 0,
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
            let tickY: CGFloat = showsAnimationLanes ? 130 : 57
            path.move(to: CGPoint(x: position, y: tickY))
            path.line(to: CGPoint(x: position, y: tickY + 3))
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            let text = String(format: "%.*f s", decimals, tick) as NSString
            let width = text.size(withAttributes: attributes).width
            let labelX = min(max(position - width / 2, 0), bounds.width - width)
            text.draw(at: CGPoint(x: labelX, y: showsAnimationLanes ? 134 : 61), withAttributes: attributes)
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
        let markerActions = showsAnimationLanes ? animationAccessibilityActions() : markerGroups().map { group in
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
        let conflictActions = conflictBands().map { band in
            let side = band.span.side == .existing ? "Existing" : "Proposed"
            let name = String(format: "Review %@: %@, %.3f to %.3f seconds", side, band.span.label, band.span.start, band.span.end)
            return NSAccessibilityCustomAction(name: name) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.conflictSpans.contains(where: { $0 == band.span }) else { return false }
                    self.onInteractionBegan?(); self.onScrubBegan?()
                    self.seek(max(self.visibleStart, band.span.start))
                    self.onScrubEnded?(); self.scrubTime = nil
                    return true
                }
            }
        }
        return markerActions + conflictActions
    }

    override func mouseDown(with event: NSEvent) {
        guard duration.isFinite, duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        keyboardFocus = false
        needsDisplay = true
        window?.makeFirstResponder(self)
        onInteractionBegan?()
        if showsAnimationLanes, point.y >= 38 {
            beginAnimationInteraction(at: point)
            return
        }
        guard point.x >= railOrigin else { return }
        if !showsAnimationLanes, point.y >= 38 && point.y < 56 {
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
        if interaction == .start || interaction == .end { drag?.originalPlayhead = playhead }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if showsAnimationLanes, animationGesture != nil { dragAnimation(with: event); return }
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
        if drag.interaction == .start || drag.interaction == .end {
            let current = scrubTime ?? playhead
            let clamped = min(max(current, drag.start), drag.end)
            if clamped != current {
                scrubTime = clamped
                onTrimPlayhead?(clamped)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if showsAnimationLanes, animationGesture != nil || animationClickID != nil || animationDeleteID != nil || animationChooserIDs != nil || animationEmptyClick {
            endAnimationInteraction(at: convert(event.locationInWindow, from: nil)); return
        }
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
        if let activeAnimationMenu { activeAnimationMenu.cancelTracking(); self.activeAnimationMenu = nil; return }
        if showsAnimationLanes, animationGesture != nil || animationClickID != nil || animationDeleteID != nil || animationChooserIDs != nil || animationEmptyClick {
            cancelAnimationGesture(); return
        }
        if let activeMarkerMenu { activeMarkerMenu.cancelTracking(); self.activeMarkerMenu = nil; return }
        let active = drag
        if let original = active?.originalPlayhead, scrubTime != nil {
            onTrimPlayhead?(original)
        }
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
        if showsAnimationLanes, event.keyCode == 51 || event.keyCode == 117 {
            guard let id = selectedAnimationID, animationSpans.contains(where: { $0.id == id && $0.editable }) else { return }
            cancelAnimationGesture(); onInteractionBegan?(); onDeleteAnimation?(id); return
        }
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
