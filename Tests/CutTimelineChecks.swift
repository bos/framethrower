import AppKit

private final class CutTimelinePinch: NSEvent {
    var amount = 0.0
    var position = CGPoint.zero
    override var magnification: CGFloat { amount }
    override var phase: NSEvent.Phase { [] }
    override var locationInWindow: NSPoint { position }
}

/// Metadata, vector paths and synthetic events only; no pixels or media items.
@main @MainActor
struct CutTimelineChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }

    static func main() throws {
        require(MediaProcessing.isSuspended, "media interlock must stay enabled")
        let cut = RecordingCut(start: 4, end: 6, crossfade: 1)
        let map = try RecordingTimeMap(duration: 12, trimStart: 1, trimEnd: 11, cuts: [cut])
        let component = UUID()
        let source = TimelineAnimation(id: .init(lane: .screen, componentID: component), editID: component,
            start: 2, end: 9, easeIn: 3, easeOut: 2, label: "Zoom A", help: "Original movement", editable: true)
        let removedID = UUID()
        let removed = TimelineAnimation(id: .init(lane: .camera, componentID: removedID), editID: removedID,
            start: 5, end: 5, easeIn: 0, easeOut: 0, label: "Camera B", help: "Excluded jump", editable: true)
        let projection = TimelineOutputProjection(animations: [source, removed], map: map)
        require(near(map.outputDuration, 7), "trim/cut/fade output duration")
        require(projection.animations.count == 2, "removed jumps must disappear; retained movement must split")
        let fragments = projection.animations.sorted { $0.start < $1.start }
        require(near(fragments[0].start, 1) && near(fragments[0].end, 3) && near(fragments[1].start, 2) && near(fragments[1].end, 5), "fragments lost overlap/source mapping")
        require(Set(fragments.map(\.id)).count == 2 && projection.sourceIDs.values.allSatisfy { $0 == source.id }, "fragment identity must remain distinct but select the real source edit")
        require(fragments.allSatisfy { !$0.editable && $0.help.contains("Source mode") }, "finished fragments exposed source timing controls")
        let again = TimelineOutputProjection(animations: [source, removed], map: map)
        require(again.animations == projection.animations, "fragment IDs depend on transient view state")
        let right = fragments[1]
        let profile = projection.envelopes[right.id]!
        require(profile.animation == source && near(right.start + profile.sourceOffset, 6), "clipped velocity profile restarted at the join")
        require(map.samples(at: 2.5).count == 2, "crossfade fixture must have two independent source poses")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 980, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = RecordingTimelineView(frame: CGRect(x: 20, y: 20, width: 900, height: 180))
        window.contentView!.addSubview(view)
        view.showsAnimationLanes = true; view.showsClipLane = true
        view.setClock("output", duration: map.outputDuration)
        view.trimStart = 0; view.trimEnd = map.outputDuration; view.showsTrimHandles = false
        view.animationSpans = fragments; view.sourceEnvelopes = projection.envelopes
        view.selectedAnimationID = right.id
        view.cutMarkers = map.joins.map { .init(id: $0.id, start: $0.outputStart, end: $0.outputEnd, help: "Crossfade") }
        require(view.intrinsicContentSize.height == 180 && view.animationLanes().map { $0.frame.minY } == [70,100,130], "Clips row reflowed or hid animation lanes")
        let rows = view.animationLanes()
        let joinFrame = view.cutMarkerFrames().first!.1
        require(joinFrame.width >= 20 && view.cutMarkerFrames().first!.0.end > view.cutMarkerFrames().first!.0.start, "full crossfade span/hard-cut target lost")
        require(near(view.cutTransitionFrames().first!.1.width, view.x(for: 3) - view.x(for: 2)), "crossfade paint must cover the entire effective output interval")
        require(view.cutMarkers.first!.badgeLabel == "1s", "Finished fade badge must identify its duration, not look like Delete")
        require(view.animationGeometry().allSatisfy { $0.startHandle == nil && $0.easeInHandle == nil && $0.deleteButton == nil }, "finished projected fragments must be selectable but read-only")
        let item = view.animationGeometry().first { $0.animation.id == right.id }!
        let path = view.animationEnvelope(for: item)
        let speed = MotionInterpolation.normalizedSpeed(at: 4.5, duration: source.duration, easeIn: source.easeIn, easeOut: source.easeOut)
        let x = view.x(for: 2.5)
        require(path.contains(CGPoint(x: x, y: item.body.maxY - CGFloat(speed) * (item.body.height - 3) + 0.2)), "fragment envelope does not retain its original source velocity")
        var selected: UUID?
        var range: ClosedRange<Double>?
        var cutCalls = 0, trims = 0, animationDeletes = 0
        var restored: [UUID] = []
        var seeks: [Double] = []
        view.onSelectCut = { selected = $0; view.selectedCutID = $0 }
        view.onRangeSelection = { range = $0; view.selectedRange = $0; view.selectedCutID = nil }
        view.onRestoreCut = { restored.append($0) }
        view.onDeleteAnimation = { _ in animationDeletes += 1 }
        view.onCutRange = { cutCalls += 1 }
        view.onTrim = { _, _ in trims += 1 }
        view.onSeek = { seeks.append($0) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func gesture(_ start: CGPoint, _ end: CGPoint) {
            view.mouseDown(with: mouse(.leftMouseDown, start)); view.mouseDragged(with: mouse(.leftMouseDragged, end)); view.mouseUp(with: mouse(.leftMouseUp, end))
        }
        let center = CGPoint(x: joinFrame.midX, y: joinFrame.midY)
        view.mouseDown(with: mouse(.leftMouseDown, center)); view.mouseUp(with: mouse(.leftMouseUp, center))
        require(selected == cut.id && range == nil && seeks.isEmpty, "join click must select controls without seeking")
        let anchor = view.cutAnchor(for: cut.id)!
        require(near(anchor.x, joinFrame.midX / view.bounds.width) && near(anchor.y, joinFrame.midY / view.bounds.height), "join popover is not anchored to its actual native badge")
        func deleteKey() {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51)!)
        }
        var editable = right; editable.editable = true
        view.animationSpans = [editable]
        deleteKey()
        require(restored == [cut.id] && animationDeletes == 0, "Delete on a selected join must restore its section, never delete a prior animation")
        view.selectedCutID = UUID(); deleteKey()
        require(restored.count == 1 && animationDeletes == 0, "a stale selected join must fail closed without falling through to animation Delete")
        view.animationSpans = fragments; view.selectedCutID = nil
        gesture(CGPoint(x: view.x(for: 0.5), y: 51), CGPoint(x: view.x(for: 1.5), y: 51))
        require(near(range!.lowerBound, 0.5) && near(range!.upperBound, 1.5) && seeks.isEmpty, "Clips range uses the wrong clock or seeks instead of selecting")
        deleteKey()
        require(cutCalls == 1, "Delete must cut the selected Clips range")
        view.cancelOperation(nil); require(range == nil, "Escape did not clear the transient range")
        gesture(CGPoint(x: view.x(for: 0), y: 24), CGPoint(x: view.x(for: 1), y: 24))
        require(trims == 0 && !seeks.isEmpty, "Finished top rail accidentally edited source trim")
        let pinch = CutTimelinePinch(); pinch.amount = 1; pinch.position = view.convert(CGPoint(x: view.x(for: 3), y: 24), to: nil)
        view.magnify(with: pinch)
        let outputViewport = (view.visibleStart, view.visibleDuration)
        view.setClock("source", duration: 12); view.trimStart = 2; view.trimEnd = 10
        view.showsTrimHandles = true; view.allowsSeekingOutsideTrim = true
        require(view.animationLanes() == rows && view.intrinsicContentSize.height == 180, "switching clocks moved the lanes")
        gesture(CGPoint(x: view.x(for: 0.5), y: 8), CGPoint(x: view.x(for: 0.5), y: 8))
        require(near(seeks.last!, 0.5), "Source inspection cannot reach trimmed source for restoration")
        view.cutMarkers = [.init(id: cut.id, start: 4, end: 6, help: "Removed source", label: "Fade", showsTransitionSpan: false)]
        require(view.cutTransitionFrames().isEmpty && view.cutMarkerFrames().count == 1 && view.cutMarkers[0].badgeLabel == "Fade", "Source must retain the join badge without painting a crossfade over excluded footage")
        view.cutMarkers = [.init(id: cut.id, start: 5, end: 5, help: "Hard cut")]
        require(view.cutMarkerFrames().first!.1.width >= 28 && view.cutMarkers[0].badgeLabel == "Cut", "zero-duration join needs a clickable Cut label")
        view.setClock("output", duration: map.outputDuration)
        require(near(view.visibleStart, outputViewport.0) && near(view.visibleDuration, outputViewport.1), "Finished viewport did not survive Source inspection")
        window.close()
        print("Cut timeline checks passed: projected source profiles, full join spans, fixed lanes, clock-specific range/trim/viewport behavior.")
    }
}
