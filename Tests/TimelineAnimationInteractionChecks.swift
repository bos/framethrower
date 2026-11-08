import AppKit

private final class AnimationPinchEvent: NSEvent {
    var amount = 0.0
    var position = CGPoint.zero
    override var magnification: CGFloat { amount }
    override var phase: NSEvent.Phase { [] }
    override var locationInWindow: NSPoint { position }
}

/// Offscreen vector geometry and synthetic native events only. No display,
/// screenshots, bitmap contexts, player items, source files, or media work.
@main @MainActor
struct TimelineAnimationInteractionChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func span(_ lane: TimelineAnimationLane, _ start: Double, _ end: Double, _ label: String,
                     editable: Bool = true, reference: Bool = false, component: UUID = UUID()) -> TimelineAnimation {
        TimelineAnimation(id: TimelineAnimationID(lane: lane, componentID: component), editID: component,
            start: start, end: end, easeIn: min(0.3, (end - start) / 3), easeOut: min(0.3, (end - start) / 3),
            label: label, help: label + " animation", editable: editable, isReference: reference)
    }
    static func main() {
        require(MediaProcessing.isSuspended, "requires the media interlock")
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 980, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = RecordingTimelineView(frame: CGRect(x: 20, y: 20, width: 900, height: 150))
        window.contentView!.addSubview(view)
        view.showsAnimationLanes = true
        require(view.animationLanes().count == 3 && view.animationGeometry().isEmpty && view.intrinsicContentSize.height == RecordingTimeline.animationLaneHeight, "empty recording lost its persistent fixed lanes")
        var requests: [(AnimationDrag, Bool)] = []
        var selections: [TimelineAnimationID] = []
        var deletions: [TimelineAnimationID] = []
        var seeks: [Double] = []
        var trims: [(Double, Double)] = []
        var cancels = 0
        view.onAnimationEdit = { requests.append(($0, $1)) }
        view.onAnimationCancel = { cancels += 1 }
        view.onSelectAnimation = { selections.append($0); view.selectedAnimationID = $0 }
        view.onDeleteAnimation = { deletions.append($0) }
        view.onSeek = { seeks.append($0) }
        view.onTrim = { trims.append(($0, $1)) }
        func reset(_ animations: [TimelineAnimation], selected: TimelineAnimationID? = nil) {
            view.cancelOperation(nil)
            view.duration = 12; view.trimStart = 0; view.trimEnd = 12; view.playhead = 6
            view.fit(request: UUID()); view.animationSpans = animations; view.selectedAnimationID = selected
            view.conflictSpans = []; view.conflictOverlaps = []
            requests = []; selections = []; deletions = []; seeks = []; trims = []; cancels = 0
            view.onAnimationEdit = { requests.append(($0, $1)) }
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, option: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: option ? [.option] : [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func down(_ point: CGPoint) { view.mouseDown(with: mouse(.leftMouseDown, point)) }
        func drag(_ point: CGPoint, option: Bool = false) { view.mouseDragged(with: mouse(.leftMouseDragged, point, option: option)) }
        func up(_ point: CGPoint) { view.mouseUp(with: mouse(.leftMouseUp, point)) }
        func gesture(_ start: CGPoint, _ end: CGPoint, option: Bool = false) { down(start); drag(end, option: option); up(end) }
        func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
        func geometry(_ id: TimelineAnimationID) -> RecordingTimelineView.AnimationGeometry {
            guard let item = view.animationGeometry().first(where: { $0.animation.id == id }) else { preconditionFailure("missing animation geometry") }
            return item
        }
        func key(_ code: UInt16) {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!)
        }
        let shared = UUID()
        let screen = span(.screen, 1, 3, "Zoom A", component: shared)
        let camera = span(.camera, 1, 3, "Camera A", component: shared)
        let pointer = span(.pointer, 0, 12, "Pointer", editable: false)
        reset([screen, camera, pointer])
        let rows = view.animationLanes()
        require(view.animationGeometry().allSatisfy { $0.startHandle == nil && $0.endHandle == nil && $0.deleteButton == nil }, "unselected animations exposed edit handles")
        require(rows.map(\.title) == ["Screen", "Camera", "Pointer"] && rows.map { $0.frame.minY } == [40, 70, 100], "all lanes must always share fixed geometry")
        require(view.intrinsicContentSize.height == RecordingTimeline.animationLaneHeight && view.x(for: 0) == 64 && view.x(for: 12) == 888, "lane mode has a fixed height and common gutter/time axis")
        view.edits = [RecordingTimelineMarker(id: shared, time: 3, help: "legacy", label: "Edit A")]
        for selected in [screen.id, camera.id, pointer.id] {
            view.selectedAnimationID = selected
            let all = view.animationGeometry()
            require(all.count == 3 && all.allSatisfy { !$0.labelFrame.isEmpty } && view.animationLanes() == rows && view.intrinsicContentSize.height == 150, "selection hid labels or resized the timeline")
            require(all.filter { $0.startHandle != nil }.allSatisfy { $0.animation.id == selected }, "only the selected editable component gets handles")
        }
        let envelopeGeometry = geometry(screen.id)
        let envelope = view.animationEnvelope(for: envelopeGeometry)
        let rampTime = screen.start + screen.easeIn / 2
        let rampX = view.x(for: rampTime)
        require(!envelope.contains(CGPoint(x: rampX, y: envelopeGeometry.body.minY + 4)) &&
            envelope.contains(CGPoint(x: rampX, y: envelopeGeometry.body.maxY - 2)),
            "animation fill must leave the area above the ramp as lane background and fill below it")
        require(!envelope.contains(CGPoint(x: view.x(for: 2), y: envelopeGeometry.body.minY + 1)) &&
            envelope.contains(CGPoint(x: view.x(for: 2), y: envelopeGeometry.body.maxY - 2)),
            "animation plateau must preserve the clear area above its curve")
        view.pointerClickTimes = [1, 3, .nan, -1, 13]
        require(view.pointerClickGeometry().map(\.time) == [1, 3] && view.pointerClickGeometry().allSatisfy { $0.frame.minY >= 100 && $0.frame.maxY <= 126 }, "readonly recorded clicks lost their source-time axis or escaped Pointer lane")
        require(view.markerGroups().isEmpty && view.markerLabels().isEmpty, "lane mode duplicated the legacy marker rail")
        require(view.accessibilityCustomActions()?.contains { $0.name.contains("Camera A") } == true, "lane animations lost accessible selection")
        require(geometry(pointer.id).deleteButton == nil && geometry(pointer.id).startHandle == nil, "global pointer settings invented editable keyframes")

        // A click selects; a body drag never seeks or invokes click selection.
        reset([screen, camera, pointer])
        let body = center(geometry(screen.id).body)
        down(body); up(body)
        require(selections == [screen.id] && requests.isEmpty && seeks.isEmpty, "plain lane click is separate from source scrubbing")
        selections = []
        var split = screen; split.id.componentID = UUID()
        view.onAnimationEdit = { request, final in
            requests.append((request, final))
            if !final { view.animationSpans = [split, camera, pointer]; view.selectedAnimationID = split.id }
        }
        down(body); drag(CGPoint(x: body.x + (view.x(for: 0.5) - view.x(for: 0)), y: body.y))
        require(near(geometry(screen.id).animation.start, 1.5) && view.animationGeometry().contains { $0.animation.id == camera.id }, "preview lost the frozen component after incoming split-ID update")
        let finalPoint = CGPoint(x: body.x + view.x(for: 1) - view.x(for: 0), y: body.y)
        drag(finalPoint); up(finalPoint)
        require(requests.count == 3 && requests.last?.0.id == screen.id && near(requests.last?.0.deltaSeconds ?? .nan, 1) && requests.last?.1 == true && selections.isEmpty && seeks.isEmpty, "drag accumulated previews, changed identity, selected/seeked early, or lost its final callback")

        reset([screen], selected: screen.id)
        let initial = center(geometry(screen.id).body)
        down(initial); drag(CGPoint(x: initial.x + 40, y: initial.y)); key(53); up(CGPoint(x: initial.x + 40, y: initial.y))
        require(cancels == 1 && requests.count == 1 && requests.allSatisfy { !$0.1 } && geometry(screen.id).animation == screen, "Escape did not discard the native preview without a late final")

        // Ordinary movement clamps/highlights contact; Option explicitly pushes.
        let first = span(.screen, 2, 4, "Pan B"), next = span(.screen, 5, 7, "Zoom C")
        reset([first, next, camera], selected: first.id)
        let origin = center(geometry(first.id).body)
        down(origin); drag(CGPoint(x: origin.x + view.x(for: 2) - view.x(for: 0), y: origin.y))
        require(abs(geometry(first.id).animation.end - 5) < 0.000_001 && geometry(next.id).animation == next && view.blockedAnimationIDs.contains(next.id), "ordinary collision pushed an unrelated span or lacked collision feedback")
        // Continue the SAME gesture through the neighbor. Only a wholly
        // cleared requested interval may reorder; no neighbor is pushed.
        drag(CGPoint(x: origin.x + view.x(for: 4.75) - view.x(for: 0), y: origin.y))
        require(near(geometry(first.id).animation.end, 5) && view.blockedAnimationIDs.contains(next.id), "a partially overlapping body jumped through its neighbor")
        let cleared = CGPoint(x: origin.x + view.x(for: 5.25) - view.x(for: 0), y: origin.y)
        drag(cleared)
        require(near(geometry(first.id).animation.start, 7.25) && near(geometry(first.id).animation.end, 9.25) && geometry(next.id).animation == next && view.blockedAnimationIDs.isEmpty,
                "a fully cleared move remained clamped or falsely marked conflicting")
        up(cleared)
        require(requests.last?.1 == true && near(requests.last?.0.deltaSeconds ?? .nan, 5.25), "reordered movement lost its final frozen-base request")
        let backward = span(.screen, 8, 10, "Pan backward"), earlier = span(.screen, 4, 6, "Zoom earlier")
        let leftBlocked = TimelineAnimationSolver.solve(AnimationDrag(id: backward.id, handle: .move, deltaSeconds: -3, snapTolerance: 0), animations: [earlier, backward], duration: 12)
        let leftClear = TimelineAnimationSolver.solve(AnimationDrag(id: backward.id, handle: .move, deltaSeconds: -6.25, snapTolerance: 0), animations: [earlier, backward], duration: 12)
        require(leftBlocked?.first.map { near($0.start, 6) } == true && leftClear?.count == 1 && leftClear?.first.map { near($0.start, 1.75) && near($0.end, 3.75) } == true, "directional reorder was not symmetric or moved an untouched neighbor")
        let resize = TimelineAnimationSolver.solve(AnimationDrag(id: first.id, handle: .end, deltaSeconds: 5.25, snapTolerance: 0), animations: [first, next], duration: 12)
        require(resize?.first.map { near($0.end, 5) } == true, "resize unexpectedly reordered instead of stopping at contact")
        let tooClose = span(.screen, 8, 10, "Zoom tight")
        let narrowGap = TimelineAnimationSolver.solve(AnimationDrag(id: first.id, handle: .move, deltaSeconds: 5.5, snapTolerance: 0), animations: [first, next, tooClose], duration: 12)
        require(narrowGap?.first.map { near($0.end, 5) } == true, "body was projected into a gap too short to contain it")
        reset([first, next, camera], selected: first.id)
        let pushing = center(geometry(first.id).body)
        down(pushing); drag(CGPoint(x: pushing.x + view.x(for: 2) - view.x(for: 0), y: pushing.y), option: true)
        require(near(geometry(first.id).animation.start, 4) && near(geometry(next.id).animation.start, 6) && geometry(camera.id).animation == camera && requests.last?.0.push == true, "Option push crossed lanes or did not push the contacted neighbor")
        key(53)

        reset([screen, next], selected: screen.id)
        let stickyOrigin = center(geometry(screen.id).body)
        down(stickyOrigin)
        drag(CGPoint(x: stickyOrigin.x + view.x(for: 1.96) - view.x(for: 0), y: stickyOrigin.y))
        require(near(requests.last?.0.deltaSeconds ?? .nan, 2), "near contact did not snap")
        drag(CGPoint(x: stickyOrigin.x + view.x(for: 2.08) - view.x(for: 0), y: stickyOrigin.y))
        require(near(requests.last?.0.deltaSeconds ?? .nan, 2), "contact snap did not remain sticky inside its release distance")
        key(53)

        let long = span(.screen, 2, 6, "Pan D")
        for handle in [TimelineAnimationHandle.start, .end, .easeIn, .easeOut] {
            reset([long], selected: long.id)
            let item = geometry(long.id)
            let frame: CGRect = switch handle { case .start: item.startHandle!; case .end: item.endHandle!; case .easeIn: item.easeInHandle!; case .easeOut: item.easeOutHandle!; case .move: item.body }
            let start = center(frame), delta = handle == .start || handle == .easeOut ? -0.2 : 0.2
            down(start); drag(CGPoint(x: start.x + view.x(for: delta + 1) - view.x(for: 1), y: start.y))
            require(requests.last?.0.handle == handle && requests.last?.1 == false, "selected timing/ramp handle did not retain its explicit operation")
            key(53)
        }
        let jump = span(.screen, 6, 6, "Zoom E")
        reset([jump], selected: jump.id)
        let grip = center(geometry(jump.id).startHandle!)
        down(grip); drag(CGPoint(x: grip.x - (view.x(for: 2) - view.x(for: 0)), y: grip.y))
        require(near(geometry(jump.id).animation.start, 4) && near(geometry(jump.id).animation.end, 6) && requests.last?.0.handle == .start, "a selected jump could not be animated by dragging its visible start grip left")
        key(53)
        let reference = span(.screen, 6, 6, "Ref F", reference: true)
        reset([reference, pointer], selected: reference.id)
        require(geometry(reference.id).startHandle == nil && geometry(reference.id).endHandle == nil && geometry(reference.id).deleteButton != nil, "a reference mark offered fake animation resizing or disappeared")
        let pointerLabel = center(view.animationLanes().last!.labelFrame)
        down(pointerLabel); up(pointerLabel)
        require(selections == [pointer.id] && requests.isEmpty, "the persistent Pointer lane did not open its settings without creating keyframes")

        let narrow = span(.screen, 2, 2.04, "Pan G")
        reset([narrow], selected: narrow.id)
        let small = geometry(narrow.id)
        require(!small.startHandle!.intersects(small.endHandle!) && small.easeInHandle == nil && small.easeOutHandle == nil, "narrow span controls overlapped or exposed ambiguous ramp dots")
        let pinch = AnimationPinchEvent(); pinch.amount = 50; pinch.position = view.convert(CGPoint(x: view.x(for: 2.02), y: 52), to: nil)
        view.magnify(with: pinch)
        require(geometry(narrow.id).easeInHandle != nil && geometry(narrow.id).easeOutHandle != nil && view.intrinsicContentSize.height == 150 && seeks.isEmpty, "pinching did not reveal fine controls on the same fixed source-time axis")

        // At this magnification 0.03 source seconds is over 100 pixels. A
        // solver's legacy 0.04-second tolerance must not override 6-pixel snap.
        let fine = span(.screen, 2, 2.04, "Pan fine"), contact = span(.screen, 2.09, 2.13, "Zoom contact")
        reset([fine, contact], selected: fine.id)
        let zoom = AnimationPinchEvent(); zoom.amount = 50
        zoom.position = view.convert(CGPoint(x: view.x(for: 2.06), y: 52), to: nil)
        view.magnify(with: zoom)
        let fineOrigin = center(geometry(fine.id).body)
        down(fineOrigin); drag(CGPoint(x: fineOrigin.x + view.x(for: 2.02) - view.x(for: 2), y: fineOrigin.y))
        require(near(geometry(fine.id).animation.end, 2.06) && requests.last?.0.snapTolerance == 0 &&
                view.x(for: contact.start) - view.x(for: geometry(fine.id).animation.end) > 100,
                "fixed source-time snapping overrode native pixel hysteresis at high magnification")
        key(53)
        let legacyContact = TimelineAnimationSolver.solve(AnimationDrag(id: fine.id, handle: .move, deltaSeconds: 0.02), animations: [fine, contact], duration: 12)
        require(legacyContact?.first(where: { $0.id == fine.id }).map { near($0.end, contact.start) } == true,
                "default model solver contact tolerance changed")
        require(TimelineAnimationSolver.solve(AnimationDrag(id: fine.id, handle: .move, deltaSeconds: 0.02, snapTolerance: .nan), animations: [fine, contact], duration: 12) == nil &&
                TimelineAnimationSolver.solve(AnimationDrag(id: fine.id, handle: .move, deltaSeconds: 0.02, snapTolerance: -1), animations: [fine, contact], duration: 12) == nil,
                "invalid snap tolerance escaped solver validation")

        reset([screen, camera, pointer], selected: screen.id)
        let deletion = center(geometry(screen.id).deleteButton!)
        down(deletion); up(CGPoint(x: deletion.x + 30, y: deletion.y))
        require(deletions.isEmpty, "dragging away from X still deleted the animation")
        down(deletion); up(deletion)
        require(deletions == [screen.id] && requests.isEmpty, "selected X did not delete exactly the component")
        deletions = []; key(51)
        require(deletions == [screen.id], "Delete key lost the selected component identity")
        deletions = []
        let context = view.menu(for: mouse(.rightMouseDown, center(geometry(camera.id).body)))!
        let deleteItem = context.items.first { $0.title.hasPrefix("Delete ") }!
        require(NSApp.sendAction(deleteItem.action!, to: deleteItem.target, from: deleteItem) && deletions == [camera.id], "context menu deleted a different co-timed component")
        view.selectedAnimationID = pointer.id; deletions = []; key(51)
        require(deletions.isEmpty, "Delete created a destructive operation for readonly pointer settings")

        // Real crowded case: a Hold ends where a six-millisecond Zoom
        // starts. Both remain discoverable even when their labels overlap.
        let hold = span(.screen, 4.6, 5, "Hold D"), tinyZoom = span(.screen, 5, 5.006, "Zoom A")
        reset([hold, tinyZoom], selected: tinyZoom.id)
        let crowds = view.animationCrowds()
        require(crowds.count == 1 && Set(crowds[0].ids) == [hold.id, tinyZoom.id] && view.animationGeometry().allSatisfy { !crowds[0].frame.intersects($0.body) }, "hidden Hold/Zoom lacked a crowd badge or the badge concealed a span body")
        var crowdMenu: NSMenu?
        view.presentAnimationMenu = { menu, _ in crowdMenu = menu }
        let badge = center(crowds[0].frame)
        down(badge); up(badge)
        require(crowdMenu?.items.count == 2 && crowdMenu?.items.contains { $0.title.contains("Hold D") && $0.title.contains("4.600–5.000") } == true && crowdMenu?.items.contains { $0.title.contains("Zoom A") && $0.title.contains("5.000–5.006") } == true && requests.isEmpty,
                "crowd chooser did not expose each individual action and source interval")
        let tinyItem = crowdMenu!.items.first { $0.title.contains("Zoom A") }!
        require(NSApp.sendAction(tinyItem.action!, to: tinyItem.target, from: tinyItem), "crowded Zoom could not be selected")
        let tinyBody = geometry(tinyZoom.id).body
        let grab = CGPoint(x: tinyBody.maxX - 1, y: tinyBody.midY)
        let away = CGPoint(x: grab.x + view.x(for: 0.1) - view.x(for: 0), y: grab.y)
        crowdMenu = nil; requests = []; selections = []
        down(grab); drag(away); up(away)
        require(requests.last?.0.id == tinyZoom.id && requests.last?.1 == true && crowdMenu == nil && selections.isEmpty,
                "another span's external label made an abutting short span difficult to grab")

        // Coincident reference targets use a chooser, not overlapping drag hits.
        let otherRef = span(.screen, 6, 6, "Ref H", reference: true)
        reset([reference, otherRef])
        var chooser: NSMenu?
        view.presentAnimationMenu = { menu, _ in chooser = menu }
        let coincident = center(geometry(reference.id).body)
        down(coincident); up(coincident)
        require(chooser?.items.count == 2 && requests.isEmpty && selections.isEmpty, "coincident targets did not offer an unambiguous native chooser")
        let chosen = chooser!.items[1]
        require(NSApp.sendAction(chosen.action!, to: chosen.target, from: chosen) && selections == [otherRef.id], "chooser did not preserve the selected component identity")

        reset([screen, camera, pointer])
        view.conflictSpans = [EditorConflictSpan(id: "existing", side: .existing, start: 1, end: 3, label: "Existing", help: "Existing framing"),
            EditorConflictSpan(id: "proposed", side: .proposed, start: 2, end: 4, label: "Proposed", help: "Proposed framing")]
        view.conflictOverlaps = [2...3]
        let bands = view.conflictBands()
        require(bands.count == 2 && bands.allSatisfy { $0.frame.minY >= 40 && $0.frame.maxY <= 66 } && bands[0].frame.minY != bands[1].frame.minY && abs(bands[0].frame.minX - view.x(for: 1)) < 0.000_001, "Director conflict source spans did not remain in the Screen lane")
        require(view.accessibilityCustomActions()?.contains { $0.name.contains("Proposed") } == true, "conflict comparison lost accessible time review")
        let comparison = center(bands[0].frame)
        down(comparison); up(comparison)
        require(seeks.count == 1 && near(seeks[0], 2) && requests.isEmpty, "comparison stripe did not stay a read-only source-time review")
        seeks = []
        let ruler = CGPoint(x: view.x(for: 4), y: 3)
        down(ruler); up(ruler)
        require(seeks == [4] && requests.isEmpty, "ruler scrubbing was confused with a lane edit")
        let trim = CGPoint(x: view.x(for: 0), y: 20), trimmed = CGPoint(x: view.x(for: 0.5), y: 20)
        gesture(trim, trimmed)
        require(trims.count == 1 && abs(trims[0].0 - 0.5) < 0.000_001, "gutter mode changed trim source-clock geometry")
        view.showsAnimationLanes = false
        require(view.intrinsicContentSize.height == 72 && view.x(for: 0) == 12 && !view.markerGroups().isEmpty, "legacy marker mode changed when animation lanes were disabled")
        print("Timeline animation interaction checks passed (three persistent vector lanes, frozen typed identities, click/drag separation, resize/ramps/jump, Option push/contact, collision feedback, chooser/delete/cancel, Director bands and source-clock viewport; no media or bitmap rendering).")
    }
}
