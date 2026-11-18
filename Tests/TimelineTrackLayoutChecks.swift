import AppKit

private final class NavigationEvent: NSEvent {
    var amount: CGFloat = 0
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var position = CGPoint.zero
    var eventPhase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    var modifiers: NSEvent.ModifierFlags = []
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var locationInWindow: CGPoint { position }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
}
@MainActor private final class ScrollParent: NSView {
    var events: [(phase: NSEvent.Phase, momentum: NSEvent.Phase, dy: CGFloat)] = []
    override func scrollWheel(with event: NSEvent) {
        events.append((event.phase, event.momentumPhase, event.scrollingDeltaY))
    }
}

@main @MainActor
struct TimelineTrackLayoutChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure.failed(message) }
    }
    static func near(_ value: Double, _ expected: Double, _ message: String) throws {
        try require(abs(value - expected) < 1e-7, "\(message): \(value) != \(expected)")
    }
    static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let project = RecordingProject(screenFilename: "not-opened.mov", cameraFilename: "not-opened-camera.mov", duration: 10)
        let legacy = TimelineVideoRow.make(project: project, state: project.state, map: nil)
        let camera = TimelineAnimation(id: .init(lane: .camera, componentID: UUID()), editID: UUID(), start: 0, end: 0,
            easeIn: 0, easeOut: 0, label: "Initial", help: "", editable: false, isPlaceholder: true)
        let pointer = TimelineAnimation(id: .init(lane: .pointer, componentID: UUID()), editID: UUID(), start: 0, end: 10,
            easeIn: 0, easeOut: 0, label: "Pointer", help: "", editable: false, isPlaceholder: true)
        let quiet = TimelineTrackLayout.make(videoRows: legacy, animations: [camera, pointer])
        try require(quiet.rows.count == 2, "default-only properties must not produce empty tracks")
        try require(quiet.rows.contains { $0.title.contains("PIP") }, "camera track identifies PIP")
        try near(quiet.contentHeight, 138, "compact height is derived from actual two media rows")
        let roleLayout = TimelineTrackLayout.make(videoRows: legacy, animations: [camera, pointer], recordedAudioRoles: [.microphone])
        try require(roleLayout.rows.contains { $0.id == .animation(.audioMicrophone) }, "actual microphone is a recorded track even without automation")
        let microphoneIndex = roleLayout.rows.firstIndex { $0.id == .animation(.audioMicrophone) }!
        try require(microphoneIndex > 0 && roleLayout.rows[microphoneIndex - 1].title.contains("PIP") && roleLayout.rows[microphoneIndex].depth == 1,
            "microphone belongs immediately below PIP, rather than a remote global lane")
        let roleAware = TimelineTrackLayout.make(videoRows: legacy, animations: [], expandedVideoVolumeLayerIDs: Set(legacy.map(\.layerID)), recordedAudioRoles: [.microphone, .systemAudio])
        let systemIndex = roleAware.rows.firstIndex { $0.id == .animation(.audioSystem) }!
        try require(roleAware.rows[systemIndex].depth == 1 && roleAware.rows[systemIndex - 1].id == .media(legacy[0].layerID), "system audio belongs below the screen")
        try require(!roleAware.rows.contains { $0.id == .volume(legacy[0].layerID) }, "role-aware recordings do not expose duplicate generic screen audio")
        try require(!roleLayout.rows.contains { $0.id == .animation(.audioSystem) }, "absent system audio does not create an empty row")
        let readonly = TimelineAnimation(id: .init(lane: .speed, componentID: UUID()), editID: UUID(), start: 1, end: 2,
            easeIn: 0, easeOut: 0, label: "Authored", help: "", editable: false)
        try require(TimelineTrackLayout.make(videoRows: [], animations: [readonly]).rows.count == 1,
            "read-only authored edits remain visible; placeholder and editability are independent")

        var sequential = project
        let first = VideoClip(sourceID: VideoSource.legacyScreenID, start: 0, end: 4, layout: .screen)
        let second = VideoClip(sourceID: VideoSource.legacyScreenID, start: 4, end: 10, sourceStart: 0, layout: .screen)
        let layer = VideoLayer(name: "Screen recording", clips: [first, second])
        sequential.state.videoLayers = [layer]
        let rows = TimelineVideoRow.make(project: sequential, state: sequential.state, map: nil)
        let layout = TimelineTrackLayout.make(videoRows: rows, animations: [])
        try require(rows.count == 2 && layout.rows.count == 1 && layout.rows[0].title == "Screen recording", "two sequential occurrences share one named track")
        let view = RecordingTimelineView(frame: CGRect(x: 0, y: 0, width: 1000, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.duration = 10; view.trimEnd = 10; view.showsAnimationLanes = true; view.videoRows = rows; view.rowLayout = layout
        view.frameDuration = 1.0 / 60; view.playhead = 3
        try near(view.intrinsicContentSize.height, layout.contentHeight, "native height uses exact supplied layout")
        let frames = view.videoClipFrames()
        try require(frames.count == 2 && frames[0].2.minY == frames[1].2.minY && frames[0].2.maxX == frames[1].2.minX,
            "adjacent clips draw on the same visual row")
        var selected: UUID?, seeks: [Double] = [], edits: [TimelineVideoEdit] = []
        view.onSelectVideo = { _, clip, _ in selected = clip; view.selectedVideoClipID = clip }
        view.onSeek = { seeks.append($0) }
        click(view, at: CGPoint(x: frames[1].2.midX, y: frames[1].2.midY))
        try require(selected == second.id && seeks.isEmpty && view.playhead == 3, "clip selection is unambiguous and does not seek")
        let active = TimelineTrackLayout.make(videoRows: rows, animations: [readonly])
        view.onVideoEdit = { request, final in
            edits.append(request)
            if !final { view.rowLayout = active }
        }
        let origin = CGPoint(x: frames[0].2.midX, y: frames[0].2.midY)
        view.mouseDown(with: event(.leftMouseDown, view, origin))
        view.mouseDragged(with: event(.leftMouseDragged, view, CGPoint(x: origin.x + 30, y: origin.y)))
        try require(view.trackLayout == layout && view.intrinsicContentSize.height == layout.contentHeight,
            "row structure stays frozen while an edit preview changes visible channels")
        view.mouseUp(with: event(.leftMouseUp, view, CGPoint(x: origin.x + 30, y: origin.y)))
        try require(view.trackLayout == active && !edits.isEmpty, "new row structure applies after gesture ends")
        view.rowLayout = layout
        let disclosure = view.videoVolumeDisclosureFrames().first!
        view.onToggleVideoVolume = { layerID in
            view.rowLayout = TimelineTrackLayout.make(videoRows: rows, animations: [], expandedVideoVolumeLayerIDs: [layerID])
        }
        click(view, at: CGPoint(x: disclosure.1.midX, y: disclosure.1.midY))
        try require(view.trackLayout.rows.contains { $0.id == .volume(layer.id) }, "audio disclosure reveals a useful source volume row")
        try require(view.trackLayout.contentHeight == view.intrinsicContentSize.height, "expanded row and native height agree")
        view.keyDown(with: key(124, view))
        try near(seeks.last!, 3 + 1.0 / 60, "arrow seeks one frame")
        view.keyDown(with: key(123, view, modifiers: .shift))
        try near(seeks.last!, 2, "Shift-arrow seeks one second")
        var range: ClosedRange<Double>?
        view.onRangeSelection = { range = $0 }
        let from = CGPoint(x: view.x(for: 2), y: 20), to = CGPoint(x: view.x(for: 4), y: 20)
        view.mouseDown(with: event(.leftMouseDown, view, from, modifiers: .shift))
        view.mouseDragged(with: event(.leftMouseDragged, view, to, modifiers: .shift))
        view.mouseUp(with: event(.leftMouseUp, view, to, modifiers: .shift))
        try require(range != nil, "first cut range is available from Shift-drag ruler without an empty Cut track")
        try near(range!.lowerBound, 2, "ruler selection beginning")
        try near(range!.upperBound, 4, "ruler selection ending")

        var splitState = sequential.state
        let occurrence = VideoClip(sourceID: VideoSource.legacyScreenID, start: 1, end: 9, sourceStart: 0)
        splitState.videoLayers = [VideoLayer(id: layer.id, name: layer.name, clips: [occurrence])]
        splitState.cuts = [.init(start: 4, end: 6, crossfade: 1)]
        let map = try RecordingTimeMap(duration: 10, trimStart: 0, trimEnd: 10, cuts: splitState.cuts)
        let split = TimelineVideoRow.make(project: sequential, state: splitState, map: map)
        try require(split.count == 1 && split[0].parts.count == 2 && split[0].editable, "cut fragments remain editable")
        view.duration = map.outputDuration; view.videoRows = split
        view.rowLayout = TimelineTrackLayout.make(videoRows: split, animations: [])
        view.onVideoEdit = { request, _ in edits.append(request) }
        view.selectedVideoClipID = nil
        let start = CGPoint(x: view.x(for: 2), y: view.videoClipFrames()[0].2.midY)
        let end = CGPoint(x: view.x(for: 5), y: start.y)
        view.mouseDown(with: event(.leftMouseDown, view, start))
        view.mouseDragged(with: event(.leftMouseDragged, view, end))
        view.mouseUp(with: event(.leftMouseUp, view, end))
        try near(edits.last!.projectTime, 7, "native split-clip drag crosses the cut through its frozen branch clock")
        let animation = TimelineAnimation(id: .init(lane: .screen, componentID: UUID()), editID: UUID(), start: 2, end: 8,
            easeIn: 1, easeOut: 1, label: "Zoom", help: "", editable: true)
        let projection = TimelineOutputProjection(animations: [animation], map: map)
        try require(projection.animations.count == 2 && Set(projection.animations.map(\.id)).count == 2,
            "visible fragments have unique identities")
        try require(projection.animations.allSatisfy(\.editable) && !projection.animations[0].showsEndHandle && !projection.animations[1].showsStartHandle,
            "fragments are draggable without treating cut edges as animation endpoints")
        try navigationAndLabels()
        try scrollGestureLifecycle()
        print("Timeline hierarchy checks passed: named grouped clips, real/default/read-only channels, shared content height, frozen gestures, stable selection, audio disclosure, ruler ranges, frame nudges, branch-aware cut fragments and complete scroll/momentum gestures; no media or focus.")
    }
    static func navigationAndLabels() throws {
        let parent = ScrollParent(frame: CGRect(x: 0, y: 0, width: 1000, height: 300))
        let view = RecordingTimelineView(frame: parent.bounds)
        parent.addSubview(view)
        view.showsAnimationLanes = true; view.frameDuration = 1.0 / 60
        view.setClock("twenty-minutes", duration: 1200)
        try near(view.visibleDuration, 30, "long recordings begin at a readable thirty-second scale")
        try require(!view.rangeScroller.isHidden && view.rangeScroller.frame.width > view.rangeScroller.frame.height, "horizontal navigation is visible and correctly oriented")
        let event = NavigationEvent(); event.position = CGPoint(x: view.x(for: 15), y: 24)
        event.amount = -0.99; view.magnify(with: event)
        try near(view.visibleDuration, 1200, "pinching out reaches the entire twenty-minute project")
        event.position = CGPoint(x: (view.x(for: 0) + view.x(for: 1200)) / 2, y: 24)
        event.amount = 100000; view.magnify(with: event)
        try near(view.visibleDuration, 4.0 / 60, "frame-scale pinch limit is independent of recording duration")
        try near(view.visibleStart + view.visibleDuration / 2, 600, "pinch remains anchored at the pointer")
        let before = view.visibleStart
        event.amount = 0; event.dx = -30; event.dy = 0; view.scrollWheel(with: event)
        try require(view.visibleStart > before && parent.events.allSatisfy { $0.dy == 0 }, "horizontal natural scroll moves time only")
        let afterHorizontal = view.visibleStart
        event.dx = 0; event.dy = -30; view.scrollWheel(with: event)
        try near(view.visibleStart, afterHorizontal, "vertical track scroll does not pan time")
        try require(parent.events.last?.dy == -30, "vertical scroll reaches track container")
        event.dx = -15; event.dy = -15; view.scrollWheel(with: event)
        try require(view.visibleStart > afterHorizontal && parent.events.last?.dy == -15, "diagonal gestures navigate tracks and time together")
        let start = view.visibleStart, span = view.visibleDuration
        let marker = RecordingTimelineMarker(id: UUID(), time: 1000, help: "Outside viewport", label: "Outside viewport")
        view.edits = [marker]; view.selectedEditID = marker.id
        try near(view.visibleStart, start, "selecting an offscreen edit preserves the viewport")
        try near(view.visibleDuration, span, "selecting preserves timeline scale")
        view.fit(request: UUID()); view.duration = 10; view.trimEnd = 10
        let baseline = TimelineAnimation(id: .init(lane: .screen, componentID: UUID()), editID: UUID(), start: 0, end: 0,
            easeIn: 0, easeOut: 0, label: "Full frame", help: "Baseline", editable: false)
        let zoom = TimelineAnimation(id: .init(lane: .screen, componentID: UUID()), editID: UUID(), start: 0, end: 5,
            easeIn: 1, easeOut: 1, label: "Zoom into browser", help: "Zoom", editable: true)
        view.animationSpans = [baseline, zoom]
        view.rowLayout = TimelineTrackLayout.make(videoRows: [], animations: view.animationSpans)
        view.selectedAnimationID = zoom.id
        let geometry = view.animationGeometry(), crowds = view.animationCrowds()
        try require(geometry.count == 2 && geometry.allSatisfy { $0.labelFrame.isNull }, "coincident baseline and zoom labels never overpaint")
        try require(crowds.count == 1 && Set(crowds[0].ids) == Set([baseline.id, zoom.id]), "one chooser retains access to each overlapping item")
        try require(geometry.allSatisfy { !crowds[0].frame.intersects($0.body) && ![$0.startHandle, $0.endHandle, $0.easeInHandle, $0.easeOutHandle].compactMap { $0 }.contains { crowds[0].frame.intersects($0) } },
            "chooser never obscures a curve or control point")
        var choices = 0
        view.presentAnimationMenu = { menu, _ in choices = menu.items.filter { !$0.isSeparatorItem }.count }
        click(view, at: CGPoint(x: crowds[0].frame.midX, y: crowds[0].frame.midY))
        try require(choices == 2, "clicking gutter chooser exposes both individual changes")
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 1000, height: 130))
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        view.installPinnedTimeRuler(); scroll.tile()
        try require(scroll.hasHorizontalRuler && scroll.rulersVisible && view.pinnedTimeRuler != nil,
            "numeric ruler is installed above the vertically scrolling tracks")
        let ruler = view.pinnedTimeRuler!
        try near(ruler.ruleThickness, 20, "pinned numeric ruler has compact fixed height")
        let rulerFrame = ruler.frame
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 200)); scroll.reflectScrolledClipView(scroll.contentView)
        try require(scroll.contentView.bounds.minY > 0 && ruler.frame == rulerFrame && !ruler.isHidden,
            "numeric ruler stays visible after scrolling down through track lanes")
        let labelsBefore = view.timeRulerTicks().map(\.label)
        ruler.needsDisplay = false
        event.position = view.convert(CGPoint(x: view.bounds.midX, y: 224), to: nil)
        event.amount = 1; view.magnify(with: event)
        try require(view.timeRulerTicks().map(\.label) != labelsBefore && ruler.needsDisplay,
            "pinch updates pinned ruler labels with the new visible time range")
        try require(!view.timeRulerTicks().isEmpty, "compact scrolled timeline retains numeric time labels")

    }
    static func scrollGestureLifecycle() throws {
        let parent = ScrollParent(frame: CGRect(x: 0, y: 0, width: 1000, height: 300))
        let view = RecordingTimelineView(frame: parent.bounds)
        parent.addSubview(view)
        view.showsAnimationLanes = true
        view.setClock("scroll-gesture", duration: 1200)
        let event = NavigationEvent()
        event.position = CGPoint(x: 500, y: 100)
        let phases: [(NSEvent.Phase, NSEvent.Phase, CGFloat, CGFloat)] = [
            (.mayBegin, [], 0, 0), (.began, [], 0, 0),
            (.changed, [], -2, -20), (.changed, [], -20, -2),
            (.ended, [], 0, 0), ([], .began, 0, 0),
            ([], .changed, -4, -10), ([], .changed, -10, -1),
            ([], .ended, 0, 0),
            (.began, [], 0, 0), (.cancelled, [], 0, 0),
            (.began, [], 0, 0), (.ended, [], 0, 0),
            ([], .began, 0, 0), ([], .cancelled, 0, 0)
        ]
        var fingerLiftStart = 0.0
        for (phase, momentum, dx, dy) in phases {
            event.eventPhase = phase; event.momentum = momentum; event.dx = dx; event.dy = dy
            // AppKit routes an active gesture to its original view even after the pointer moves.
            event.position = momentum.isEmpty && phase != .ended ? CGPoint(x: 500, y: 100) : CGPoint(x: 1100, y: 100)
            view.scrollWheel(with: event)
            if phase == .ended { fingerLiftStart = view.visibleStart }
            if momentum == .ended {
                try require(view.visibleStart > fingerLiftStart, "time viewport continues moving during momentum after finger lift")
            }
        }
        try require(parent.events.count == phases.count, "track scroller receives every gesture boundary and momentum event")
        for (received, expected) in zip(parent.events, phases) {
            try require(received.phase == expected.0 && received.momentum == expected.1 && received.dy == expected.3,
                "track scroller receives the original phases and deltas without axis filtering")
        }
        try require(view.visibleStart > 0, "scrolling pans the time viewport")
        let count = parent.events.count, start = view.visibleStart
        event.momentum = .cancelled; event.dx = -100; event.dy = -100
        view.scrollWheel(with: event)
        try near(view.visibleStart, start, "cancelled momentum never pans time")
        try require(parent.events.count == count + 1, "cancelled momentum reaches the native scroller")
        event.position = CGPoint(x: 500, y: 100)
        event.modifiers = .shift; event.momentum = []; event.eventPhase = .changed; event.dx = 0; event.dy = -20
        let shiftedCount = parent.events.count
        view.scrollWheel(with: event)
        try require(view.visibleStart > start && parent.events.count == shiftedCount, "Shift-scroll pans time without scrolling tracks")
    }
    static func event(_ type: NSEvent.EventType, _ view: NSView, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    static func click(_ view: RecordingTimelineView, at point: CGPoint) {
        view.mouseDown(with: event(.leftMouseDown, view, point)); view.mouseUp(with: event(.leftMouseUp, view, point))
    }
    static func key(_ code: UInt16, _ view: NSView, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
}
