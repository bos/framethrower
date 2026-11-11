import AppKit

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
        try near(quiet.contentHeight, 124, "compact height is derived from actual two media rows")
        let roleLayout = TimelineTrackLayout.make(videoRows: legacy, animations: [camera, pointer], recordedAudioRoles: [.microphone])
        try require(roleLayout.rows.contains { $0.id == .animation(.audioMicrophone) }, "actual microphone is a recorded track even without automation")
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
        print("Timeline hierarchy checks passed: named grouped clips, real/default/read-only channels, shared content height, frozen gestures, stable selection, audio disclosure, ruler ranges, frame nudges and branch-aware cut fragments; no media or focus.")
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
