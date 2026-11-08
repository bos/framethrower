import AppKit
import SwiftUI

@MainActor
private final class OffscreenConflictWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Production session, views, and metadata. Every media access remains blocked;
/// nonexistent source filenames and empty native layers are intentional.
@main @MainActor
struct ConflictReviewInterfaceChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.failed(message) }
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Requires suspended media")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 12)
        project.state.zoomKeyframes = [ZoomKeyframe(time: 1, scale: 2, transition: .smooth, duration: 1),
            ZoomKeyframe(time: 6, scale: 2.5, transition: .smooth, duration: 1),
            ZoomKeyframe(time: 9, scale: 1, transition: .smooth, duration: 1)]
        project.state.pipKeyframes.append(PIPKeyframe(time: 2,
            placement: PIPPlacement(x: 0.15, y: 0.2, scale: 0.38), transition: .smooth, duration: 2))
        let box1 = EditorRegion(time: 0, rect: .init(x: 0.1, y: 0.1, width: 0.25, height: 0.3))
        let box2 = EditorRegion(time: 0, rect: .init(x: 0.6, y: 0.5, width: 0.3, height: 0.3))
        project.state.regions = [box1, box2]
        project.ensureReferences()
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("review.framethrower"))
        let original = editor.project
        let session = EditorAssistantSession(transport: { payload in
            let root = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            let text = (root["messages"] as! [[String: Any]]).compactMap { $0["content"] as? String }
                .first { $0.hasPrefix("Current editor context") }!
            let body = text.split(separator: "\n", maxSplits: 1)[1]
            let context = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
            let recording = context["recording"] as! [String: Any]
            let args: [String: Any] = ["project_id": recording["projectID"]!, "expected_revision": recording["revision"]!,
                "from_box_label": "Box 1", "to_box_label": "Box 2", "start_delay_seconds": 0,
                "arrival_seconds": 3, "arrival_origin": "playhead", "path": "direct"]
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [[
                "id": "fixture_conflict", "type": "function", "function": ["name": "move_relative", "arguments":
                    String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]
            ]]]]]])
        })
        let playback = EditorPlayback()
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, directorModeInitiallyEnabled: false,
            playback: playback, assistant: session))
        let window = OffscreenConflictWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1200, height: 850),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { session.suspend(); window.close() }
        try await settle(host)
        guard let canvas = all(EditorCanvasView.self, in: host).first,
              let timeline = all(RecordingTimelineView.self, in: host).first else { throw Failure.failed("Production views missing") }
        let originalWindowFrame = window.frame
        let playingCanvasFrame = canvas.frame, playingTimelineFrame = timeline.frame
        let initialViewport = canvas.testPattern?.screenViewport, initialCameraFrame = canvas.testPattern?.cameraFrame
        try require(playback.canPlay && !playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer,
                    "The actual editor is playable through its vector clock without creating any AV player/layer")
        guard let speed = all(NSSegmentedControl.self, in: host).first(where: {
            $0.segmentCount == 4 && $0.label(forSegment: 0) == "0.5×"
        }) else { throw Failure.failed("Playback speed selector missing from the editor") }
        try require((0..<4).map { speed.label(forSegment: $0) ?? "" } == ["0.5×", "1×", "2×", "5×"],
                    "Review speeds are directly visible together beside Play")
        speed.selectedSegment = 2
        try require(speed.sendAction(speed.action, to: speed.target), "Native speed selection sends its action")
        try await settle(host)
        try require(playback.playbackRate == 2 && !playback.isPlaying && playback.time == 0 && editor.project == original,
                    "The actual speed selector changes paused transport without starting playback or editing metadata")
        _ = playback.setPlaybackRate(1)
        try await settle(host)
        playback.togglePlayback()
        for _ in 0..<100 where playback.time <= 0.12 { try await Task.sleep(for: .milliseconds(10)) }
        try await settle(host)
        try require(playback.isPlaying && timeline.playhead > 0.12 && canvas.zoom == original.state.zoom(at: timeline.playhead) &&
                    canvas.testPattern?.screenViewport != initialViewport && canvas.testPattern?.cameraFrame != initialCameraFrame,
                    "The real editor playhead animates actual screen and PIP interpolation against the static vector chart")
        try require(canvas.frame == playingCanvasFrame && timeline.frame == playingTimelineFrame &&
                    !playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer && editor.project == original && !editor.canUndo,
                    "Visual playthrough preserves window layout and edit history while every AV object stays absent (canvas \(playingCanvasFrame)→\(canvas.frame), timeline \(playingTimelineFrame)→\(timeline.frame), AVplayer=\(playback.hasMediaPlayer), AVlayer=\(canvas.hasMediaPlayerLayer), projectEqual=\(editor.project == original), canUndo=\(editor.canUndo), window \(originalWindowFrame)→\(window.frame))")
        playback.pause(); playback.seek(0)
        try await settle(host)
        session.instruction = "Pan from Box 1 to Box 2 over the next three seconds."
        session.submit(editor: editor, playhead: 0, regionID: nil, editID: nil)
        for _ in 0..<100 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        try await settle(host)
        guard let review = session.conflictReview else { throw Failure.failed("Pending comparison missing: " + (session.errorMessage ?? session.notice ?? "")) }
        try require(session.awaitsClarification && !session.isBusy && editor.project == original && !editor.canUndo,
                    "Review asks before applying and creates no project/history change")
        try require(canvas.conflictFrames.count == 2 && canvas.zoom == ZoomPlacement() && !canvas.allowsZoomEditing,
                    "Full-source preview exposes both framing outlines without gesture editing")
        try require(timeline.conflictSpans == review.existingSpans + review.proposedSpans &&
                    abs(timeline.playhead - review.inspectionTime) < 0.000001,
                    "The same conflict is visible on the timeline at a differing inspection frame")
        try require(window.frame == originalWindowFrame && timeline.showsAnimationLanes &&
                    timeline.frame.height == timeline.intrinsicContentSize.height && timeline.frame.height == RecordingTimeline.animationLaneHeight &&
                    all(NSTextField.self, in: host).contains { $0.placeholderString == "Your answer…" },
                    "A conflict automatically reveals its question without resizing the window or timeline")
        let lanes = timeline.animationLanes()
        try require(Set(lanes.map(\.lane)) == [.screen, .camera, .pointer],
                    "All three persistent animation lanes remain visible during Director review")
        let screenLane = lanes.first { $0.lane == .screen }!.frame
        let cameraLane = lanes.first { $0.lane == .camera }!.frame
        let pointerLane = lanes.first { $0.lane == .pointer }!.frame
        try require(!timeline.conflictBands().isEmpty && timeline.conflictBands().allSatisfy {
            screenLane.contains($0.frame) && !cameraLane.intersects($0.frame) && !pointerLane.intersects($0.frame)
        }, "Director framing conflicts must appear only in the affected Screen lane")
        // Opening the native inspector animates its column. Measure the
        // comparison after that reveal, then verify later scrubs stay fixed.
        try await Task.sleep(for: .milliseconds(400))
        try await settle(host)
        let comparisonPreviewFrame = canvas.frame
        let comparisonTimelineFrame = timeline.frame
        try require(!playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer && canvas.stillLayer.contents == nil && canvas.testPattern != nil,
                    "Conflict review renders a vector chart without creating an AV player/layer or attaching a video source")
        let comparisonStart = playback.time
        let comparisonFrames = canvas.conflictFrames
        playback.togglePlayback()
        for _ in 0..<100 where playback.time <= comparisonStart + 0.12 { try await Task.sleep(for: .milliseconds(10)) }
        try await settle(host)
        try require(playback.isPlaying && playback.isPreviewing && canvas.zoom == ZoomPlacement() &&
                    canvas.conflictFrames != comparisonFrames && canvas.conflictOutlines?.time == timeline.playhead,
                    "Comparison Play advances both real curves while preserving the source-frame preview")
        try require(canvas.frame == comparisonPreviewFrame && timeline.frame == comparisonTimelineFrame &&
                    editor.project == original && !editor.canUndo && !playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer,
                    "Playing a comparison changes only clock/vector geometry, never layout, history or media state")
        playback.pause()
        let firstOutlines = canvas.conflictOutlines
        timeline.onScrubBegan?(); timeline.onSeek?(2); timeline.onScrubEnded?()
        try await settle(host)
        try require(canvas.frame == comparisonPreviewFrame && timeline.frame == comparisonTimelineFrame,
                    "Scrubbing comparison cannot reallocate preview or timeline: before \(comparisonPreviewFrame) / \(comparisonTimelineFrame), after \(canvas.frame) / \(timeline.frame)")
        try require(canvas.conflictOutlines?.time == 2 && canvas.conflictOutlines != firstOutlines && editor.project == original && !editor.canUndo,
                    "Scrubbing compares the actual two curves without committing a movement")
        session.cancel()
        try await settle(host)
        try require(canvas.conflictOutlines == nil && canvas.conflictFrames.isEmpty && timeline.conflictSpans.isEmpty &&
                    timeline.conflictOverlaps.isEmpty && editor.project == original && !editor.canUndo,
                    "Dismiss restores ordinary inspection and clears every transient comparison")
        session.instruction = "Pan from Box 1 to Box 2 over the next three seconds."
        session.submit(editor: editor, playhead: 0, regionID: nil, editID: nil)
        for _ in 0..<100 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        try await settle(host)
        try require(session.conflictReview != nil, "Reopen comparison for manual-edit lifecycle")
        var manual = editor.project.state
        manual.zoomKeyframes = [ZoomKeyframe(time: timeline.playhead, scale: 2.2)]
        try require(editor.updateDraft(manual, at: timeline.playhead), "Begin a manual zoom draft")
        try await settle(host)
        try require(session.conflictReview == nil && !session.awaitsClarification && canvas.conflictFrames.isEmpty &&
                    editor.draftState == manual && abs(canvas.zoom.scale - 2.2) < 0.000001 && editor.project == original,
                    "A manual edit leaves comparison mode and keeps its own preview/draft without applying the old proposal")
        _ = editor.cancelDraft()
        try await settle(host)
        func trimEvent(_ type: NSEvent.EventType, time: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(CGPoint(x: timeline.x(for: time), y: 24), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        playback.seek(3)
        try await settle(host)
        timeline.mouseDown(with: trimEvent(.leftMouseDown, time: 0))
        timeline.mouseDragged(with: trimEvent(.leftMouseDragged, time: 5))
        try await settle(host)
        try require(abs(playback.time - 5) < 0.000001 && abs(timeline.playhead - 5) < 0.000001 &&
                    editor.project.state.trimStart == 0 && !editor.canUndo,
                    "Crossing trim start updates the real preview immediately without committing during the drag")
        timeline.mouseUp(with: trimEvent(.leftMouseUp, time: 5))
        try await settle(host)
        try require(abs(playback.time - 5) < 0.000001 && abs(editor.project.state.trimStart - 5) < 0.000001 && editor.project.undoHistory.count == 1,
                    "Releasing trim keeps the carried playhead and creates one Undo entry: \(playback.time), \(editor.project.state.trimStart), \(editor.project.undoHistory.count)")
        playback.seek(9)
        try await settle(host)
        timeline.mouseDown(with: trimEvent(.leftMouseDown, time: 12))
        timeline.mouseDragged(with: trimEvent(.leftMouseDragged, time: 7))
        try await settle(host)
        try require(abs(playback.time - 7) < 0.000001 && editor.project.state.trimEnd == 12,
                    "Crossing trim end carries the real playhead before release")
        timeline.mouseUp(with: trimEvent(.leftMouseUp, time: 7))
        try await settle(host)
        try require(abs(playback.time - 7) < 0.000001 && abs(editor.project.state.trimEnd - 7) < 0.000001 && editor.project.undoHistory.count == 2,
                    "Trim-end release preserves the playhead after the asynchronous preview rebuild")
        playback.seek(6)
        try await settle(host)
        timeline.mouseDown(with: trimEvent(.leftMouseDown, time: 5))
        timeline.mouseDragged(with: trimEvent(.leftMouseDragged, time: 6.5))
        timeline.cancelOperation(nil)
        try await settle(host)
        try require(abs(playback.time - 6) < 0.000001 && abs(editor.project.state.trimStart - 5) < 0.000001 && editor.project.undoHistory.count == 2,
                    "Canceling a crossed trim restores the original playhead without changing saved trim/history")
        try await laneGestures(host: host, window: window, timeline: timeline, canvas: canvas, editor: editor, playback: playback)
        print("Conflict review interface checks passed (vector playthrough, persistent independent lanes, native atomic/ripple/Escape editing, Screen-only conflict review, inspector-independent fixed geometry; no AV objects/media).")
    }
    static func laneGestures(host: NSView, window: NSWindow, timeline: RecordingTimelineView,
                             canvas: EditorCanvasView, editor: ProjectEditor, playback: EditorPlayback) async throws {
        playback.pause()
        let fixedCanvas = canvas.frame, fixedTimeline = timeline.frame, fixedWindow = window.frame
        guard let tabs = all(NSSegmentedControl.self, in: host).first(where: { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Camera" } &&
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Pointer" }
        }) else { throw Failure.failed("Native inspector tabs missing") }
        for name in ["Camera", "Pointer", "Zoom"] {
            guard let index = (0..<tabs.segmentCount).first(where: { tabs.label(forSegment: $0) == name }) else {
                throw Failure.failed("Inspector tab missing: " + name)
            }
            tabs.selectedSegment = index
            try require(tabs.sendAction(tabs.action, to: tabs.target), "The fixture must deliver a real native inspector selection")
            try await settle(host)
            let cameraShapeVisible = all(NSSegmentedControl.self, in: host).contains { control in
                (0..<control.segmentCount).contains { control.label(forSegment: $0) == "Circle" }
            }
            try require(cameraShapeVisible == (name == "Camera"),
                        "The native tab change must actually update the inspector's controls")
            try require(canvas.frame == fixedCanvas && timeline.frame == fixedTimeline && window.frame == fixedWindow &&
                        Set(timeline.animationLanes().map(\.lane)) == [.screen, .camera, .pointer],
                        "Changing inspector tabs cannot hide a timeline lane or resize the preview/timeline")
        }
        let componentID = editor.project.state.zoomKeyframes[0].id
        let animationID = TimelineAnimationID(lane: .screen, componentID: componentID)
        guard let geometry = timeline.animationGeometry().first(where: { $0.animation.id == animationID }) else {
            throw Failure.failed("Screen animation geometry missing")
        }
        let point = CGPoint(x: geometry.body.midX, y: geometry.body.midY)
        let playhead = playback.time
        timeline.mouseDown(with: mouse(.leftMouseDown, point, in: timeline, window: window))
        try require(playback.time == playhead, "Mouse-down must not seek before click versus drag is known")
        timeline.mouseUp(with: mouse(.leftMouseUp, point, in: timeline, window: window))
        try await settle(host)
        try require(timeline.selectedAnimationID == animationID && abs(playback.time - geometry.animation.end) < 0.000001,
                    "A completed plain click selects the animation and inspects its destination")
        let baseline = editor.project
        let destination = CGPoint(x: point.x + timeline.x(for: 3) - timeline.x(for: 1), y: point.y)
        timeline.mouseDown(with: mouse(.leftMouseDown, point, in: timeline, window: window))
        timeline.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: point.x + 2, y: point.y), in: timeline, window: window))
        try require(editor.draftState == nil && editor.project == baseline,
                    "Click jitter below the drag threshold cannot begin a lane edit")
        timeline.mouseDragged(with: mouse(.leftMouseDragged, destination, in: timeline, window: window))
        try require(editor.project == baseline && abs((editor.draftState?.zoomKeyframes.first?.time ?? .nan) - 3) < 0.000001,
                    "A native span drag previews one draft without saving intermediate finger samples")
        timeline.mouseUp(with: mouse(.leftMouseUp, destination, in: timeline, window: window))
        try await settle(host)
        try require(editor.draftState == nil && editor.project.undoHistory.count == baseline.undoHistory.count + 1 &&
                    abs((editor.project.state.zoomKeyframes.first?.time ?? .nan) - 3) < 0.000001 && editor.project.state.pipKeyframes == baseline.state.pipKeyframes,
                    "Mouse-up commits one atomic Screen gesture while preserving independent Camera timing")
        let committed = editor.project
        try require(editor.undo() && editor.project.state == baseline.state && editor.redo() && editor.project.state == committed.state,
                    "One ordinary Undo/Redo restores the entire native lane gesture")
        try await settle(host)
        let moved = timeline.animationGeometry().first { $0.animation.id == animationID }!
        let source = CGPoint(x: moved.body.midX, y: moved.body.midY)
        let ripplePoint = CGPoint(x: source.x + timeline.x(for: 11) - timeline.x(for: 3), y: source.y)
        timeline.mouseDown(with: mouse(.leftMouseDown, source, in: timeline, window: window, flags: .option))
        timeline.mouseDragged(with: mouse(.leftMouseDragged, ripplePoint, in: timeline, window: window, flags: .option))
        try require(editor.project == committed && abs((editor.draftState?.zoomKeyframes.last?.time ?? .nan) - 12) < 0.000001 &&
                    editor.draftState?.pipKeyframes == committed.state.pipKeyframes,
                    "Option ripple previews the whole same-lane cascade clamped to the source edge")
        timeline.cancelOperation(nil)
        timeline.mouseUp(with: mouse(.leftMouseUp, ripplePoint, in: timeline, window: window, flags: .option))
        try await settle(host)
        try require(editor.project == committed && editor.draftState == nil && editor.project.undoHistory == committed.undoHistory &&
                    canvas.frame == fixedCanvas && timeline.frame == fixedTimeline && !playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer,
                    "Escape cancels the complete ripple preview, preserves history and cannot resize or activate media")
    }
    static func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView, window: NSWindow,
                      flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    static func settle(_ host: NSView) async throws {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60)) }
    }
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
}
