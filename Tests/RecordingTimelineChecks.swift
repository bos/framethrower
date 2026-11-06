import AppKit

// These synthetic events exercise the production handlers inside an offscreen
// fixture; no system input, recording, or hardware is involved.
private final class TimelineGestureEvent: NSEvent {
    var amount = 0.0
    var dx = 0.0
    var dy = 0.0
    var precise = true
    var position = CGPoint.zero
    var eventPhase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var locationInWindow: NSPoint { position }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
}

// Run with Tests/check-recording-timeline.sh. Exercises native mouse/keyboard
// handling offscreen, including the overlapping trim and playhead controls.
@main
struct RecordingTimelineChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 680, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let timeline = RecordingTimelineView(frame: CGRect(x: 20, y: 20, width: 624, height: 72))
        window.contentView!.addSubview(timeline)

        var seeks: [Double] = []
        var trims: [(Double, Double)] = []
        var interactions = 0
        var scrubPhases: [String] = []
        timeline.onSeek = { time in
            precondition(scrubPhases.last == "begin", "Every seek must occur inside an active scrub")
            seeks.append(time); timeline.playhead = time
        }
        timeline.onScrubBegan = { scrubPhases.append("begin") }
        timeline.onScrubEnded = { scrubPhases.append("end") }
        timeline.onTrim = { start, end in
            trims.append((start, end))
            timeline.trimStart = start
            timeline.trimEnd = end
        }
        timeline.onInteractionBegan = { interactions += 1 }

        func reset(duration: Double = 10, start: Double = 2, end: Double = 8, playhead: Double = 4) {
            timeline.duration = duration
            timeline.trimStart = start
            timeline.trimEnd = end
            timeline.playhead = playhead
            seeks = []
            trims = []
            interactions = 0
            scrubPhases = []
        }
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func down(_ point: CGPoint) { timeline.mouseDown(with: mouse(.leftMouseDown, at: point)) }
        func drag(_ point: CGPoint) { timeline.mouseDragged(with: mouse(.leftMouseDragged, at: point)) }
        func up(_ point: CGPoint) { timeline.mouseUp(with: mouse(.leftMouseUp, at: point)) }
        func gesture(from: CGPoint, to: CGPoint) { down(from); drag(to); up(to) }
        func key(_ code: UInt16, shift: Bool = false) {
            timeline.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: code)!)
        }

        reset()
        precondition(timeline.isFlipped, "Timeline gestures use top-left coordinates")
        near(timeline.x(for: 0), 12, "Source start inset")
        near(timeline.x(for: 10), 612, "Source end inset")
        near(timeline.x(for: 5), 312, "Common source-time geometry")
        down(CGPoint(x: timeline.x(for: 5), y: 24))
        near(seeks.last, 5, "Clicking the track seeks immediately")
        drag(CGPoint(x: timeline.x(for: 6), y: 24))
        near(seeks.last, 6, "Dragging the track seeks before mouse-up")
        up(CGPoint(x: timeline.x(for: 6), y: 24))
        precondition(trims.isEmpty && interactions == 1, "Scrubbing never creates trim edits")
        precondition(scrubPhases == ["begin", "end"], "A mouse scrub has one begin and one end")

        reset()
        gesture(from: CGPoint(x: timeline.x(for: 5), y: 24), to: CGPoint(x: -100, y: 24))
        near(seeks.last, 2, "Scrubbing clamps to the retained start")
        reset()
        gesture(from: CGPoint(x: timeline.x(for: 5), y: 24), to: CGPoint(x: 900, y: 24))
        near(seeks.last, 8, "Scrubbing clamps to the retained end")

        reset()
        let offCenterStart = CGPoint(x: timeline.x(for: 2) + 6, y: 24)
        down(offCenterStart)
        precondition(seeks.isEmpty && trims.isEmpty, "Grabbing a trim handle does not seek or commit")
        drag(CGPoint(x: offCenterStart.x + 60, y: 24))
        drag(CGPoint(x: offCenterStart.x + 120, y: 24))
        precondition(trims.isEmpty, "Trim drag creates no intermediate undo entries")
        up(CGPoint(x: offCenterStart.x + 120, y: 24))
        precondition(trims.count == 1 && interactions == 1, "A trim drag commits once")
        precondition(scrubPhases.isEmpty, "Trimming must not start a video scrub")
        near(trims.last?.0, 4, "Off-center grab uses translation without jumping")
        near(trims.last?.1, 8, "Trimming the start preserves the end")

        reset()
        let offCenterEnd = CGPoint(x: timeline.x(for: 8) - 6, y: 24)
        gesture(from: offCenterEnd, to: CGPoint(x: offCenterEnd.x - 60, y: 24))
        precondition(trims.count == 1)
        near(trims.last?.0, 2, "Trimming the end preserves the start")
        near(trims.last?.1, 7, "End handle uses the same source-time scale")

        reset()
        let stationaryHandle = CGPoint(x: timeline.x(for: 2) + 6, y: 24)
        down(stationaryHandle)
        up(stationaryHandle)
        precondition(trims.isEmpty && seeks.isEmpty, "A stationary handle click creates no undo entry")

        reset(start: 0, end: 10, playhead: 0)
        let topThumb = CGPoint(x: timeline.x(for: 0) + 5, y: 6)
        down(topThumb)
        near(timeline.playhead, 0, "Off-center playhead grab does not jump")
        drag(CGPoint(x: topThumb.x + 60, y: 6))
        near(seeks.last, 1, "Top playhead remains draggable when it overlaps trim start")
        up(CGPoint(x: topThumb.x + 60, y: 6))
        precondition(trims.isEmpty)
        reset(start: 0, end: 10, playhead: 0)
        let lowerTrim = CGPoint(x: timeline.x(for: 0) + 5, y: 24)
        gesture(from: lowerTrim, to: CGPoint(x: lowerTrim.x + 60, y: 24))
        near(trims.last?.0, 1, "Lower trim handle remains independently draggable at overlap")
        precondition(seeks.isEmpty)

        reset()
        gesture(from: CGPoint(x: timeline.x(for: 2), y: 24), to: CGPoint(x: 900, y: 24))
        near(trims.last?.0, 7.9, "Start cannot cross end or discard the minimum retained duration")
        reset()
        gesture(from: CGPoint(x: timeline.x(for: 8), y: 24), to: CGPoint(x: -100, y: 24))
        near(trims.last?.1, 2.1, "End cannot cross start")
        reset()
        gesture(from: CGPoint(x: timeline.x(for: 2), y: 24), to: CGPoint(x: -100, y: 24))
        near(trims.last?.0, 0, "Trim start clamps to original source start")
        reset()
        gesture(from: CGPoint(x: timeline.x(for: 8), y: 24), to: CGPoint(x: 900, y: 24))
        near(trims.last?.1, 10, "Trim end clamps to original source end")

        reset(duration: 0.05, start: 0, end: 0.05, playhead: 0)
        gesture(from: CGPoint(x: timeline.x(for: 0), y: 24), to: CGPoint(x: 900, y: 24))
        near(timeline.trimStart, 0, "Very short recording remains nonempty")
        near(timeline.trimEnd, 0.05, "Very short recording keeps its valid source range")

        reset()
        key(124)
        near(seeks.last, 4.1, "Right arrow steps by 0.1 second")
        key(124, shift: true)
        near(seeks.last, 5.1, "Shift-right steps by one second")
        key(123)
        near(seeks.last, 5, "Left arrow steps backward")
        key(123, shift: true)
        near(seeks.last, 4, "Shift-left steps backward by one second")
        timeline.playhead = 7.9
        key(124, shift: true)
        near(seeks.last, 8, "Keyboard scrub clamps to retained end")
        timeline.playhead = 2.1
        key(123, shift: true)
        near(seeks.last, 2, "Keyboard scrub clamps to retained start")
        precondition(trims.isEmpty, "Keyboard scrubbing does not create edits")

        precondition(scrubPhases == Array(repeating: ["begin", "end"], count: 6).flatMap { $0 },
                     "Each keyboard seek must finish its scrub")
        _ = timeline.accessibilityPerformIncrement()
        precondition(scrubPhases.suffix(2) == ["begin", "end"], "Accessible seek finishes its scrub")

        reset(start: 0, end: 10, playhead: 4)
        func rendering() -> NSBitmapImageRep {
            guard let bitmap = timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds) else {
                fatalError("Could not render timeline focus cue")
            }
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            return bitmap
        }
        func changedPixels(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> [CGPoint] {
            let sx = Double(second.pixelsWide) / timeline.bounds.width
            let sy = Double(second.pixelsHigh) / timeline.bounds.height
            var points: [CGPoint] = []
            for x in 0..<second.pixelsWide {
                for y in 0..<second.pixelsHigh {
                    guard let a = first.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let b = second.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if abs(a.redComponent - b.redComponent) > 0.05 ||
                       abs(a.greenComponent - b.greenComponent) > 0.05 ||
                       abs(a.blueComponent - b.blueComponent) > 0.05 ||
                       abs(a.alphaComponent - b.alphaComponent) > 0.05 {
                        points.append(CGPoint(x: Double(x) / sx, y: Double(y) / sy))
                    }
                }
            }
            return points
        }
        window.makeFirstResponder(nil)
        let unfocused = rendering()
        let mouseFocusPoint = CGPoint(x: timeline.x(for: 4), y: 6)
        down(mouseFocusPoint); up(mouseFocusPoint)
        let mouseFocused = rendering()
        precondition(window.firstResponder === timeline && timeline.focusRingType == .none,
                     "Timeline mouse focus must retain keyboard operability without a default focus ring")
        precondition(changedPixels(unfocused, mouseFocused).isEmpty,
                     "A mouse click must not paint a large focus border or other focus decoration")
        let keyboardAnchor = NSTextField(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView!.addSubview(keyboardAnchor)
        keyboardAnchor.nextKeyView = timeline
        timeline.nextKeyView = keyboardAnchor
        window.orderFront(nil)
        window.makeFirstResponder(keyboardAnchor)
        window.selectKeyView(following: keyboardAnchor)
        precondition(window.firstResponder === timeline, "Tab navigation can focus the timeline")
        let keyboardPixels = changedPixels(mouseFocused, rendering())
        precondition(!keyboardPixels.isEmpty && keyboardPixels.allSatisfy {
            abs($0.x - timeline.x(for: 4)) <= 8 && $0.y >= 34 && $0.y <= 38
        }, "Keyboard focus gets only a small cue below the playhead, never a whole-timeline border")
        key(124)
        near(seeks.last, 4.1, "The keyboard-focused timeline remains arrow-key operable")
        down(CGPoint(x: timeline.x(for: 4.1), y: 6)); up(CGPoint(x: timeline.x(for: 4.1), y: 6))
        let afterMouse = rendering()
        window.makeFirstResponder(nil)
        precondition(changedPixels(afterMouse, rendering()).isEmpty,
                     "A later mouse click clears the keyboard-only cue")
        keyboardAnchor.removeFromSuperview()

        let edit = RecordingTimelineMarker(id: UUID(), time: 5,
            help: "Edit at 5 seconds: zoom 2×. Click to select; drag to move.")
        var selectedEdits: [UUID] = []
        var moves: [(UUID, Double, Bool)] = []
        var cancellations = 0
        var deselections = 0
        var cancelledEdits = 0
        timeline.onSelectEdit = { selectedEdits.append($0) }
        timeline.onMoveEdit = { moves.append(($0, $1, $2)) }
        timeline.onCancelMoveEdit = { cancellations += 1 }
        timeline.onDeselectEdit = { deselections += 1 }
        timeline.onCancelEdit = { cancelledEdits += 1 }
        reset(start: 0, end: 10, playhead: 4)
        let height = timeline.intrinsicContentSize.height
        timeline.edits = [edit]
        let markerPoint = CGPoint(x: timeline.x(for: 5), y: 47)
        down(markerPoint)
        precondition(selectedEdits.isEmpty && seeks.isEmpty,
                     "Pressing a diamond must not select or warp the playhead before deciding click versus drag")
        up(markerPoint)
        precondition(selectedEdits == [edit.id] && seeks.isEmpty && trims.isEmpty && moves.isEmpty,
                     "Releasing a stationary diamond selects that edit without scrubbing, moving, or trimming")
        precondition(timeline.intrinsicContentSize.height == height && height == 72,
                     "Edits have a fixed narrow lane independent of selection or marker count")
        func markerPixels() -> (purple: Int, selectedBorder: Int) {
            guard let bitmap = timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds) else {
                fatalError("Could not render timeline marker")
            }
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            let scaleX = Double(bitmap.pixelsWide) / timeline.bounds.width
            let scaleY = Double(bitmap.pixelsHigh) / timeline.bounds.height
            var purple = 0
            var selectedBorder = 0
            for x in Int((markerPoint.x - 8) * scaleX)...Int((markerPoint.x + 8) * scaleX) {
                for y in Int(38 * scaleY)..<Int(56 * scaleY) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        if color.redComponent > color.greenComponent + 0.1,
                           color.blueComponent > color.greenComponent + 0.2 { purple += 1 }
                        if abs(color.redComponent - color.blueComponent) < 0.1,
                           abs(color.greenComponent - color.blueComponent) < 0.1,
                           max(color.redComponent, color.greenComponent, color.blueComponent) > 0.75 { selectedBorder += 1 }
                    }
                }
            }
            return (purple, selectedBorder)
        }
        precondition(markerPixels().purple >= 12,
                     "Edits have visible purple diamonds in their own lane")

        reset(start: 0, end: 10, playhead: 5)
        let unselectedPixels = markerPixels()
        timeline.selectedEditID = edit.id
        let selectedPixels = markerPixels()
        precondition(selectedPixels.purple >= 12 && selectedPixels.selectedBorder > unselectedPixels.selectedBorder,
                     "A selected edit has a strong visible outline, even at the same time as the playhead")
        selectedEdits = []
        gesture(from: CGPoint(x: markerPoint.x, y: 6), to: CGPoint(x: timeline.x(for: 6), y: 47))
        near(seeks.last, 6, "Starting at the top playhead always scrubs, including while crossing the edit lane")
        precondition(selectedEdits.isEmpty && moves.isEmpty && trims.isEmpty,
                     "Diamonds cannot steal an active playhead drag")
        reset(start: 5, end: 10, playhead: 7)
        gesture(from: CGPoint(x: timeline.x(for: 5), y: 24), to: CGPoint(x: timeline.x(for: 6), y: 47))
        near(trims.last?.0, 6, "Starting at the trim handle always trims, including while crossing the edit lane")
        precondition(selectedEdits.isEmpty && moves.isEmpty && seeks.isEmpty,
                     "Diamonds cannot steal an active trim drag")

        reset(start: 0, end: 10, playhead: 5)
        let offCenterDiamond = CGPoint(x: markerPoint.x + 4, y: 47)
        down(offCenterDiamond)
        drag(CGPoint(x: offCenterDiamond.x + 2, y: 47))
        precondition(moves.isEmpty && selectedEdits.isEmpty, "Tiny click jitter does not move or select the edit")
        drag(CGPoint(x: offCenterDiamond.x + 30, y: 24))
        precondition(selectedEdits == [edit.id] && moves.count == 1 && !moves[0].2,
                     "Crossing the drag threshold selects once and previews the move")
        near(moves.last?.1, 5.5, "Off-center diamond grab preserves its time offset")
        drag(CGPoint(x: offCenterDiamond.x + 60, y: 6))
        precondition(moves.filter(\.2).isEmpty && selectedEdits.count == 1,
                     "Continuous diamond movement creates no intermediate final edits")
        up(CGPoint(x: offCenterDiamond.x + 60, y: 6))
        precondition(moves.count == 3 && moves.filter(\.2).count == 1 && moves.last?.0 == edit.id,
                     "A diamond drag has exactly one final move callback")
        near(moves.last?.1, 6, "Diamond movement retains the shared source-time scale")
        precondition(seeks.isEmpty && trims.isEmpty && scrubPhases.isEmpty,
                     "A diamond drag never becomes playhead or trim movement while crossing their lanes")

        let previous = RecordingTimelineMarker(id: UUID(), time: 4, help: "Previous edit")
        let following = RecordingTimelineMarker(id: UUID(), time: 6, help: "Following edit")
        timeline.edits = [previous, edit, following]
        timeline.frameDuration = 1.0 / 30
        moves = []
        gesture(from: markerPoint, to: CGPoint(x: -100, y: 47))
        near(moves.last?.1, 4 + 1.0 / 30, "Edit movement stops one frame after the previous edit")
        moves = []
        gesture(from: markerPoint, to: CGPoint(x: 900, y: 47))
        near(moves.last?.1, 6 - 1.0 / 30, "Edit movement stops one frame before the following edit")
        precondition(timeline.edits == [previous, edit, following], "Previewing a move cannot overwrite or remove neighboring edits")

        moves = []
        down(markerPoint)
        drag(CGPoint(x: markerPoint.x + 20, y: 47))
        key(53)
        up(CGPoint(x: markerPoint.x + 20, y: 47))
        precondition(cancellations == 1 && moves.count == 1 && moves.allSatisfy { !$0.2 },
                     "Escape cancels a diamond move and mouse-up cannot commit it afterward")
        selectedEdits = []
        moves = []
        down(markerPoint)
        key(53)
        up(markerPoint)
        precondition(selectedEdits.isEmpty && moves.isEmpty && cancellations == 1 && cancelledEdits == 1,
                     "Escape before the drag threshold cancels unfinished edits and deselects without moving")
        key(53)
        precondition(cancelledEdits == 2 && cancellations == 1 && deselections == 0,
                     "Escape with no active drag cancels unfinished edits rather than finalizing them")

        reset(start: 0, end: 10, playhead: 4)
        let blank = CGPoint(x: timeline.x(for: 8), y: 47)
        down(blank)
        precondition(deselections == 0 && seeks.isEmpty,
                     "Pressing blank edit-lane space does not seek or finalize before mouse-up")
        up(blank)
        precondition(deselections == 1 && seeks.isEmpty && trims.isEmpty && moves.isEmpty,
                     "Blank edit-lane click deselects exactly once without moving the playhead")
        selectedEdits = []
        gesture(from: blank, to: markerPoint)
        precondition(deselections == 2 && selectedEdits.isEmpty && seeks.isEmpty && trims.isEmpty && moves.isEmpty,
                     "A drag that starts in blank space stays inert even when it ends over a diamond")
        down(blank)
        key(53)
        up(blank)
        precondition(deselections == 2 && cancelledEdits == 3,
                     "Escape during a blank-lane press cancels instead of finalizing and later mouse-up stays inert")

        let bounded = RecordingTimelineMarker(id: UUID(), time: 1.015, help: "Camera edit",
            minimumTime: 1.0 / 30, maximumTime: 10 - 1.0 / 30)
        timeline.edits = [bounded]
        moves = []
        let boundedPoint = CGPoint(x: timeline.x(for: bounded.time), y: 47)
        down(boundedPoint); up(boundedPoint)
        precondition(moves.isEmpty, "Selecting an off-grid edit preserves its original time")
        gesture(from: boundedPoint, to: CGPoint(x: -100, y: 47))
        near(moves.last?.1, 1.0 / 30, "Camera edit minimum time protects the hidden baseline at source zero")
        gesture(from: boundedPoint, to: CGPoint(x: 900, y: 47))
        near(moves.last?.1, 10 - 1.0 / 30, "Edit maximum time protects the exclusive source end")
        timeline.edits = [previous, edit, following]
        selectedEdits = []; moves = []; seeks = []; trims = []

        let touch = TimelineGestureEvent()
        func pinch(_ amount: Double, fraction: Double = 0.5) {
            touch.amount = amount
            touch.position = timeline.convert(CGPoint(x: 12 + 600 * fraction, y: 24), to: nil)
            timeline.magnify(with: touch)
        }
        func scroll(_ dx: Double, _ dy: Double = 0, precise: Bool = true, momentum: NSEvent.Phase = []) {
            touch.dx = dx; touch.dy = dy; touch.precise = precise; touch.momentum = momentum
            touch.position = timeline.convert(CGPoint(x: 312, y: 24), to: nil)
            timeline.scrollWheel(with: touch)
        }
        near(timeline.visibleStart, 0, "Timeline begins at source overview")
        near(timeline.visibleDuration, 10, "Source overview spans the recording")
        pinch(1, fraction: 0.25)
        near(timeline.visibleDuration, 5, "Pinching in doubles timeline magnification")
        near(timeline.visibleStart, 1.25, "Timeline zoom anchors at the pointer instead of the playhead")
        near(timeline.x(for: 2.5), 162, "The source time under the pinch center stays fixed")
        scroll(-60)
        near(timeline.visibleStart, 1.75, "Precise horizontal scrolling navigates the visible time interval")
        scroll(0, -120)
        near(timeline.visibleStart, 2.75, "Vertical scrolling provides a fallback for time navigation")
        scroll(-60, momentum: .changed)
        near(timeline.visibleStart, 3.25, "Trackpad momentum continues timeline navigation")
        scroll(-10000)
        near(timeline.visibleStart, 5, "Timeline navigation clamps at the recording end")
        scroll(10000)
        near(timeline.visibleStart, 0, "Timeline navigation clamps at the recording start")
        scroll(-1, precise: false)
        near(timeline.visibleStart, 1.0 / 12, "Mouse-wheel detents use useful navigation units")
        precondition(seeks.isEmpty && trims.isEmpty && moves.isEmpty,
                     "Timeline pinch/scroll only navigate the viewport; they cannot edit the project or seek")
        let savedStart = timeline.visibleStart
        let savedSpan = timeline.visibleDuration
        timeline.duration = 10
        timeline.trimStart = 1
        timeline.playhead = 3
        near(timeline.visibleStart, savedStart, "Ordinary view updates preserve the timeline viewport")
        near(timeline.visibleDuration, savedSpan, "Ordinary view updates preserve timeline magnification")

        pinch(-0.999)
        pinch(1)
        near(timeline.visibleStart, 2.5, "Overview can be zoomed around its center")
        near(timeline.visibleDuration, 5, "Visible span used for precise dragging")
        timeline.trimStart = 0; timeline.trimEnd = 10; timeline.playhead = 4
        seeks = []
        gesture(from: CGPoint(x: timeline.x(for: 4), y: 6),
                to: CGPoint(x: timeline.x(for: 4) + 60, y: 6))
        near(seeks.last, 4.5, "Zoomed playhead dragging uses the visible interval")
        trims = []
        timeline.trimStart = 4
        gesture(from: CGPoint(x: timeline.x(for: 4), y: 24),
                to: CGPoint(x: timeline.x(for: 4) + 60, y: 24))
        near(trims.last?.0, 4.5, "Zoomed trim dragging uses the visible interval")
        moves = []
        gesture(from: CGPoint(x: timeline.x(for: 5), y: 47),
                to: CGPoint(x: timeline.x(for: 5) + 30, y: 47))
        near(moves.last?.1, 5 + 8.0 / 30, "Zoomed edit dragging uses the visible interval and frame snapping")
        precondition(moves.last?.2 == true, "Zoomed edit drag retains one final callback")

        let locked = RecordingTimelineMarker(id: UUID(), time: 5, help: "Initial camera edit", movable: false)
        timeline.edits = [locked]
        moves = []; selectedEdits = []
        gesture(from: CGPoint(x: timeline.x(for: 5), y: 47),
                to: CGPoint(x: timeline.x(for: 5) + 100, y: 47))
        precondition(moves.isEmpty && selectedEdits == [locked.id],
                     "An initial camera edit can be selected but cannot be moved")

        let beforeMouseDrag = (timeline.visibleStart, timeline.visibleDuration)
        down(CGPoint(x: timeline.x(for: 5), y: 47))
        pinch(1)
        scroll(-100)
        near(timeline.visibleStart, beforeMouseDrag.0, "Pinch and scroll cannot change time geometry during a mouse drag")
        near(timeline.visibleDuration, beforeMouseDrag.1, "An active mouse drag locks the timeline viewport")
        up(CGPoint(x: timeline.x(for: 5), y: 47))

        pinch(1e9)
        near(timeline.visibleDuration, 4.0 / 30, "Minimum timeline span keeps at least four source frames visible")
        timeline.duration = 2
        precondition(timeline.visibleStart >= 0 && timeline.visibleStart + timeline.visibleDuration <= 2,
                     "Shortening a source constrains an existing zoomed viewport")
        pinch(-0.999)
        timeline.duration = 10000
        near(timeline.visibleDuration, 10000, "Overview follows a changed source duration")
        pinch(1e9)
        near(timeline.visibleDuration, 10, "Long recordings cap timeline magnification at one thousand times")
        timeline.duration = 10
        pinch(-0.999)
        timeline.edits = [RecordingTimelineMarker(id: UUID(), time: 1, help: "Outside viewport"), edit]
        pinch(3, fraction: 0.9)
        near(timeline.visibleDuration, 2.5, "Timeline supports closer inspection near the source end")
        selectedEdits = []; moves = []; seeks = []; trims = []
        down(CGPoint(x: timeline.x(for: 1), y: 47))
        up(CGPoint(x: timeline.x(for: 1), y: 47))
        precondition(selectedEdits.isEmpty && moves.isEmpty,
                     "Offscreen diamonds have no active hit targets")
        down(CGPoint(x: timeline.x(for: 1), y: 24))
        up(CGPoint(x: timeline.x(for: 1), y: 24))
        precondition(seeks.isEmpty && trims.isEmpty, "Offscreen trim or playhead locations cannot receive clicks")

        pinch(-0.999)
        pinch(1)
        let band = RecordingTimelineMarker(id: UUID(), time: 6, help: "Smooth edit",
            transitionStart: 4, easeIn: 0.5, easeOut: 0.5)
        timeline.edits = [band]
        timeline.selectedEditID = band.id
        func purpleBandPixels() -> Int {
            guard let bitmap = timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds) else {
                fatalError("Could not render selected transition")
            }
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            let sx = Double(bitmap.pixelsWide) / timeline.bounds.width
            let sy = Double(bitmap.pixelsHigh) / timeline.bounds.height
            var pixels = 0
            for x in Int(timeline.x(for: 4.6) * sx)..<Int(timeline.x(for: 5.4) * sx) {
                for y in Int(41 * sy)..<Int(53 * sy) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > color.greenComponent + 0.02,
                       color.blueComponent > color.greenComponent + 0.04 { pixels += 1 }
                }
            }
            return pixels
        }
        precondition(purpleBandPixels() > 50, "A selected smooth edit displays its ramp/cruise transition band at close scale")
        timeline.selectedEditID = nil
        precondition(purpleBandPixels() == 0, "Transition bands belong to the selected edit instead of cluttering every edit")
        let beforeInvalid = (timeline.visibleStart, timeline.visibleDuration)
        pinch(.nan)
        scroll(.infinity)
        near(timeline.visibleStart, beforeInvalid.0, "Nonfinite navigation events cannot corrupt timeline position")
        near(timeline.visibleDuration, beforeInvalid.1, "Nonfinite navigation events cannot corrupt timeline magnification")

        let early = RecordingTimelineMarker(id: UUID(), time: 1, help: "Early edit")
        let late = RecordingTimelineMarker(id: UUID(), time: 9, help: "Late edit")
        timeline.edits = [early, late]
        timeline.selectedEditID = late.id
        near(timeline.visibleStart, 5, "Selecting an offscreen edit reveals its diamond")
        near(timeline.visibleDuration, 5, "Revealing a selected edit preserves timeline magnification")
        scroll(1000)
        near(timeline.visibleStart, 0, "The user can navigate away from a selected diamond")
        timeline.selectedEditID = late.id
        near(timeline.visibleStart, 0, "Unchanged selection cannot pull the viewport back during ordinary updates")
        timeline.selectedEditID = early.id
        timeline.selectedEditID = late.id
        near(timeline.visibleStart, 5, "A fresh selection reveals the edit again")

        window.close()
        print("Recording timeline checks passed: shared geometry, continuous scrub, trim grouping, keyboard seek, separate edit lane, selection on release, grouped edit moves, neighbor limits, cancellation, locked drag targets, trackpad timeline navigation, zoomed time precision, selected transition bands, deliberate selection reveal, blank-lane deselection, Escape cancellation, and understated keyboard focus.")
    }

    static func near(_ actual: Double?, _ expected: Double, _ message: String) {
        guard let actual, abs(actual - expected) < 0.000_001 else {
            fatalError("\(message): expected \(expected), got \(String(describing: actual))")
        }
    }
}
