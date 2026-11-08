import AppKit
import SwiftUI

@MainActor
private final class OffscreenConflictWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class LinkedBoxPinchEvent: NSEvent {
    var position = CGPoint.zero
    var eventPhase: NSEvent.Phase = []
    var amount: CGFloat = 0
    override var locationInWindow: NSPoint { position }
    override var phase: NSEvent.Phase { eventPhase }
    override var magnification: CGFloat { amount }
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
        var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov",
            cursorFilename: "missing-pointer.json", duration: 12)
        project.state.zoomKeyframes = [ZoomKeyframe(time: 1, scale: 2, transition: .smooth, duration: 1),
            ZoomKeyframe(time: 6, scale: 2.5, transition: .smooth, duration: 1),
            ZoomKeyframe(time: 9, scale: 1, transition: .smooth, duration: 1)]
        project.state.pipKeyframes.append(PIPKeyframe(time: 2,
            placement: PIPPlacement(x: 0.15, y: 0.2, scale: 0.38), transition: .smooth, duration: 2))
        project.state.editAnchors = [EditAnchor(time: 4)]
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
        try await previewTools(host: host, window: window, canvas: canvas, timeline: timeline,
            editor: editor, playback: playback)
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
        try await boxDeletion(host: host, window: window, canvas: canvas, editor: editor, session: session)
        try await linkedBoxDeletion(directory: directory)
        print("Conflict review interface checks passed (native preview Pan/Box tools and sidebar/preview Delete with ordinary text editing, vector playthrough, persistent independent lanes, native atomic/ripple/Escape editing, Screen-only conflict review, inspector-independent fixed geometry; no AV objects/media).")
    }
    static func linkedBoxDeletion(directory: URL) async throws {
        var aBox = EditorRegion(time: 0, rect: .init(x: 0.05, y: 0.15, width: 0.25, height: 0.25))
        var bBox = EditorRegion(time: 4, rect: .init(x: 0.35, y: 0.3, width: 0.25, height: 0.25))
        var cBox = EditorRegion(time: 8, rect: .init(x: 0.65, y: 0.6, width: 0.25, height: 0.25))
        func linked(_ region: EditorRegion, duration: Double) -> ZoomKeyframe {
            let fit = region.rect.framing()
            var point = ZoomKeyframe(time: region.time, scale: fit.scale, x: fit.x, y: fit.y,
                transition: region.time == 0 ? .jump : .smooth, duration: duration, easeIn: 1, easeOut: 1)
            point.sourceRegionID = region.id
            return point
        }
        let a = linked(aBox, duration: 0.4), b = linked(bBox, duration: 4), c = linked(cBox, duration: 4)
        aBox.editID = a.id; bBox.editID = b.id; cBox.editID = c.id
        let unlinked = ZoomKeyframe(time: 10, scale: 1, transition: .smooth, duration: 1)
        var project = RecordingProject(screenFilename: "linked-screen.mov", cameraFilename: "linked-camera.mov", duration: 12)
        project.state.regions = [aBox, bBox, cBox]
        project.state.zoomKeyframes = [a, b, c, unlinked]
        project.state.pipKeyframes.append(PIPKeyframe(id: b.id, time: 4,
            placement: PIPPlacement(x: 0.8, y: 0.75, scale: 0.3, shape: .square), transition: .smooth, duration: 2))
        project.ensureReferences()
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("linked-boxes.framethrower"))
        let playback = EditorPlayback()
        let assistant = EditorAssistantSession(transport: { _ in throw Failure.failed("Linked-box UI checks must never call a model") })
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, directorModeInitiallyEnabled: true,
            playback: playback, assistant: assistant))
        let window = OffscreenConflictWindow(contentRect: CGRect(x: -14000, y: -14000, width: 1200, height: 850),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { assistant.suspend(); playback.close(); window.close() }
        try await settle(host)
        try await Task.sleep(for: .milliseconds(400))
        try await settle(host)
        guard let canvas = all(EditorCanvasView.self, in: host).first,
              let timeline = all(RecordingTimelineView.self, in: host).first else { throw Failure.failed("Linked-box native views missing") }
        guard let tools = all(NSSegmentedControl.self, in: host).first(where: {
            $0.segmentCount == 2 && $0.label(forSegment: 0) == "Pan view"
        }) else { throw Failure.failed("Linked-box preview tools missing") }
        tools.selectedSegment = 0
        try require(tools.sendAction(tools.action, to: tools.target), "Linked-box fixture uses actual Pan tool")
        try await settle(host)
        let original = editor.project.state
        func row(_ index: Int, remove: Bool = false) throws -> (NSClipView, CGPoint) {
            let lists = all(NSScrollView.self, in: host).filter {
                $0.contentView.bounds.height >= 80 && $0.contentView.bounds.height <= 140 &&
                ($0.documentView.map { all(NSTextView.self, in: $0).isEmpty } ?? false)
            }
            guard lists.count == 1, let clip = lists.first?.contentView else { throw Failure.failed("Linked-box sidebar list missing") }
            let offset = CGFloat(index) * 48 + 22
            return (clip, CGPoint(x: remove ? clip.bounds.maxX - 16 : clip.bounds.minX + 40,
                y: clip.isFlipped ? clip.bounds.minY + offset : clip.bounds.maxY - offset))
        }
        func clickRow(_ index: Int, remove: Bool = false) throws {
            let (clip, point) = try row(index, remove: remove)
            window.sendEvent(mouse(.leftMouseDown, point, in: clip, window: window))
            window.sendEvent(mouse(.leftMouseUp, point, in: clip, window: window))
        }
        func selectB() async throws {
            let id = TimelineAnimationID(lane: .screen, componentID: b.id)
            let item = timeline.animationGeometry().first { $0.animation.id == id }!
            let point = CGPoint(x: item.body.midX, y: item.body.midY)
            timeline.mouseDown(with: mouse(.leftMouseDown, point, in: timeline, window: window))
            timeline.mouseUp(with: mouse(.leftMouseUp, point, in: timeline, window: window))
            try await settle(host)
            try require(timeline.selectedAnimationID == id, "Linked B Screen target must actually be selected")
        }
        func key(_ code: UInt16) -> NSEvent {
            let value = code == 51 ? "\u{7f}" : "\u{f728}"
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value,
                isARepeat: false, keyCode: code)!
        }
        for route in ["sidebar Delete", "preview Forward Delete", "sidebar X"] {
            playback.seek(6); try await settle(host)
            try await selectB()
            let before = editor.project, cameraFrame = canvas.testPattern?.cameraFrame
            if route == "sidebar Delete" {
                try clickRow(1); try await settle(host)
                window.sendEvent(key(51))
            } else if route == "preview Forward Delete" {
                let badge = canvas.guideBadges.first { $0.regionID == bBox.id }!
                let point = CGPoint(x: badge.frame.midX, y: badge.frame.midY)
                canvas.mouseDown(with: mouse(.leftMouseDown, point, in: canvas, window: window))
                canvas.mouseUp(with: mouse(.leftMouseUp, point, in: canvas, window: window))
                canvas.keyDown(with: key(117))
            } else {
                try clickRow(0); try await settle(host)
                try clickRow(1, remove: true)
            }
            try await settle(host)
            let state = editor.project.state
            let successor = state.zoomKeyframes.first { $0.id == c.id }
            let bridge = timeline.animationSpans.first { $0.lane == .screen && $0.componentID == c.id }
            try require(state.regions == [aBox, cBox] && !state.zoomKeyframes.contains { $0.sourceRegionID == bBox.id } &&
                        state.zoomKeyframes.filter { $0.id != c.id } == [a, unlinked] &&
                        successor?.time == c.time && successor?.placement == c.placement && successor?.sourceRegionID == cBox.id &&
                        bridge?.start == 0 && bridge?.end == 8 && state.zoom(at: 2) != a.placement &&
                        state.zoom(at: 9.5) == original.zoom(at: 9.5) && state.pipKeyframes == original.pipKeyframes &&
                        state.cursorStyle == original.cursorStyle && state.presentation == original.presentation && state.audio == original.audio &&
                        playback.time == 6 && canvas.testPattern?.cameraFrame == cameraFrame &&
                        timeline.selectedAnimationID != TimelineAnimationID(lane: .screen, componentID: b.id) &&
                        editor.project.undoHistory.count == before.undoHistory.count + 1,
                        "\(route) removes B and its linked Screen target in one Undo, bridges A→C at C's original8s arrival, preserves Camera/unlinked edits and source time, and clears dead Screen selection")
            try require(editor.undo(), "One Undo restores linked-box removal")
            try await settle(host)
            try require(editor.project.state == original && canvas.regions.contains { $0.id == bBox.id },
                        "Undo restores exact box, link identities, route durations and independent tracks")
        }
        playback.seek(6); try await settle(host); try await selectB()
        let pinch = LinkedBoxPinchEvent()
        pinch.position = canvas.convert(CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.midY), to: nil)
        pinch.eventPhase = .began; pinch.amount = 0
        canvas.magnify(with: pinch)
        pinch.eventPhase = .changed; pinch.amount = 0.25
        canvas.magnify(with: pinch)
        pinch.eventPhase = .ended; pinch.amount = 0
        canvas.magnify(with: pinch)
        try await settle(host)
        try require(editor.draftState == nil && editor.project.state.zoomKeyframes.first(where: { $0.id == b.id })?.sourceRegionID == bBox.id,
                    "A genuinely clamped no-op pinch preserves the explicit box link")
        playback.seek(6); try await settle(host)
        let start = CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.minY + canvas.contentRect.height * 0.1)
        let end = CGPoint(x: start.x + 30, y: start.y + 15)
        canvas.mouseDown(with: mouse(.leftMouseDown, start, in: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, end, in: canvas, window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, end, in: canvas, window: window))
        try await settle(host)
        let manuallyEdited = editor.draftState?.zoomKeyframes.first(where: { $0.id == b.id })
        try require(manuallyEdited != nil && manuallyEdited?.sourceRegionID == nil && manuallyEdited?.placement != b.placement,
                    "Actual manual reframing detaches only that Screen target from its box")
        try require(editor.finishDraft(name: "Reframe selected target"), "Commit manual detached target")
        try await settle(host)
        let detached = editor.project.state
        playback.seek(6); try await settle(host)
        try clickRow(1, remove: true); try await settle(host)
        try require(editor.project.state.zoomKeyframes == detached.zoomKeyframes &&
                    editor.project.state.pipKeyframes == detached.pipKeyframes &&
                    editor.project.state.regions == [aBox, cBox] && playback.time == 6,
                    "Deleting a guide after manual detachment preserves the manually reframed target and all timing")
        try require(editor.undo(), "Undo restores detached guide removal")
        try await settle(host)
        try require(editor.project.state == detached && !playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer,
                    "Undo restores the guide without inferring its old link again or creating media objects")
    }
    static func boxDeletion(host: NSView, window: NSWindow, canvas: EditorCanvasView,
                            editor: ProjectEditor, session: EditorAssistantSession) async throws {
        _ = editor.cancelDraft()
        let baseline = editor.project
        guard let region = baseline.state.regions.first(where: { $0.id != canvas.selectedRegionID }) ?? baseline.state.regions.first else {
            throw Failure.failed("Delete fixture needs an actual reference box")
        }
        func deleteKey(_ code: UInt16) -> NSEvent {
            let value = code == 51 ? "\u{7f}" : "\u{f728}"
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value,
                isARepeat: false, keyCode: code)!
        }
        session.instruction = "Delete text"
        try await settle(host)
        guard let field = all(NSTextField.self, in: host).first(where: { $0.placeholderString == "What would you like to change?" }) else {
            throw Failure.failed("Actual Director text composer missing")
        }
        try require(window.makeFirstResponder(field), "Composer must receive real text focus")
        guard let text = window.firstResponder as? NSTextView else { throw Failure.failed("Composer field editor missing") }
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        window.sendEvent(deleteKey(51))
        try await settle(host)
        try require(session.instruction == "Delete tex" && editor.project == baseline,
                    "Delete in the actual composer edits text while preserving all boxes and project history")
        let lists = all(NSScrollView.self, in: host).filter {
            $0.contentView.bounds.height >= 80 && $0.contentView.bounds.height <= 140 &&
            ($0.documentView.map { all(NSTextView.self, in: $0).isEmpty } ?? false)
        }
        guard lists.count == 1, let list = lists.first,
              let index = baseline.state.regions.firstIndex(where: { $0.id == region.id }) else {
            throw Failure.failed("Actual compact sidebar box list missing or ambiguous: \(lists.map(\.frame))")
        }
        let clip = list.contentView
        let offset = CGFloat(index) * 48 + 22
        let rowPoint = CGPoint(x: clip.bounds.minX + 40,
            y: clip.isFlipped ? clip.bounds.minY + offset : clip.bounds.maxY - offset)
        window.sendEvent(mouse(.leftMouseDown, rowPoint, in: clip, window: window))
        window.sendEvent(mouse(.leftMouseUp, rowPoint, in: clip, window: window))
        try await settle(host)
        try require(canvas.selectedRegionID == region.id && !((window.firstResponder as? NSTextView)?.isEditable ?? false),
                    "Selecting a sidebar box moves focus out of the composer without a large focus ring")
        window.sendEvent(deleteKey(51))
        try await settle(host)
        var removed = baseline.state
        removed.regions.removeAll { $0.id == region.id }
        try require(editor.project.state == removed && editor.project.undoHistory.count == baseline.undoHistory.count + 1 &&
                    canvas.selectedRegionID == nil && !canvas.regions.contains { $0.id == region.id } && session.instruction == "Delete tex",
                    "Delete from actual sidebar focus removes only that selected box, using the same single Undo action as its X")
        try require(editor.undo(), "Ordinary Undo restores sidebar removal")
        try await settle(host)
        try require(editor.project.state == baseline.state && canvas.regions.contains { $0.id == region.id },
                    "Undo restores the exact box without changing framing, camera, timing or original sources")
        guard let badge = canvas.guideBadges.first(where: { $0.regionID == region.id }) else {
            throw Failure.failed("Restored box has no preview badge")
        }
        let point = CGPoint(x: badge.frame.midX, y: badge.frame.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, point, in: canvas, window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, point, in: canvas, window: window))
        try await settle(host)
        canvas.keyDown(with: deleteKey(117))
        try await settle(host)
        try require(editor.project.state == removed && canvas.selectedRegionID == nil,
                    "Forward Delete from the actual preview uses the same selected-box removal route")
        try require(editor.undo(), "Ordinary Undo restores preview removal")
        try await settle(host)
        try require(editor.project.state == baseline.state && !canvas.hasMediaPlayerLayer,
                    "Both Delete routes preserve independent edit marks and use no video layer")
        session.instruction = ""
    }

    static func previewTools(host: NSView, window: NSWindow, canvas: EditorCanvasView, timeline: RecordingTimelineView,
                             editor: ProjectEditor, playback: EditorPlayback) async throws {
        let original = editor.project, windowFrame = window.frame, playhead = playback.time
        func picker() throws -> NSSegmentedControl {
            guard let control = all(NSSegmentedControl.self, in: host).first(where: {
                $0.segmentCount == 2 && $0.label(forSegment: 0) == "Pan view" && $0.label(forSegment: 1) == "Draw box"
            }) else { throw Failure.failed("Preview Pan view/Draw box selector is missing") }
            return control
        }
        func choose(_ segment: Int) throws {
            let control = try picker()
            control.selectedSegment = segment
            try require(control.sendAction(control.action, to: control.target), "Preview tool sends its native selection action")
        }
        let initialTool = try picker().selectedSegment
        try require(!canvas.scribbleMode && initialTool == 0,
                    "The ordinary editor starts with Pan view while Director is closed")
        try choose(1)
        try await settle(host)
        try await Task.sleep(for: .milliseconds(400))
        try await settle(host)
        try require(canvas.scribbleMode && canvas.drawsReferenceBoxes && canvas.guideBadges.count == original.state.regions.count,
                    "Draw box opens Director and retains every visible source reference")
        let canvasFrame = canvas.frame, timelineFrame = timeline.frame
        let panelFields = all(NSTextField.self, in: host).filter { $0.placeholderString == "What would you like to change?" }
        try require(!panelFields.isEmpty, "Choosing Draw box opens the actual Director composer")
        try choose(0)
        try await settle(host)
        try require(canvas.scribbleMode && !canvas.drawsReferenceBoxes && canvas.guideBadges.count == original.state.regions.count &&
                    !all(NSTextField.self, in: host).filter { $0.placeholderString == "What would you like to change?" }.isEmpty,
                    "Choosing Pan keeps Director, its composer, and reference boxes visible")
        guard let badge = canvas.guideBadges.first else { throw Failure.failed("Director box badge missing in Pan") }
        let point = CGPoint(x: badge.frame.midX, y: badge.frame.midY)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown)); canvas.mouseUp(with: event(.leftMouseUp))
        try await settle(host)
        try require(canvas.guideBadges.contains { $0.regionID == badge.regionID && $0.selected } && !canvas.drawsReferenceBoxes,
                    "An actual Pan-mode badge click selects the box without silently returning to Draw box")
        try choose(1); try await settle(host)
        try choose(0); try await settle(host)
        try require(editor.project == original && !editor.canUndo && editor.draftState == nil && playback.time == playhead &&
                    window.frame == windowFrame && canvas.frame == canvasFrame && timeline.frame == timelineFrame,
                    "Preview tool and reference selection changes preserve source time, metadata/history and settled geometry (canvas \(canvasFrame)→\(canvas.frame), timeline \(timelineFrame)→\(timeline.frame))")
        // Two mouse gestures may revise the same instant. Changing tool while
        // holding the second must restore the first, not cancel the entire
        // unfinished shared edit or create an Undo entry.
        playback.seek(1)
        try await settle(host)
        let start = CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.minY + canvas.contentRect.height * 0.18)
        func panEvent(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let firstEnd = CGPoint(x: start.x + 35, y: start.y + 15)
        canvas.mouseDown(with: panEvent(.leftMouseDown, start))
        canvas.mouseDragged(with: panEvent(.leftMouseDragged, firstEnd))
        canvas.mouseUp(with: panEvent(.leftMouseUp, firstEnd))
        try await settle(host)
        guard let firstDraft = editor.draftState, let firstTime = editor.draftTime else {
            throw Failure.failed("First completed Pan gesture should remain a shared unfinished framing draft")
        }
        try require(firstDraft.zoomKeyframes != original.state.zoomKeyframes && firstDraft.pipKeyframes == original.state.pipKeyframes,
                    "The held background gestures edit Screen framing rather than the animated PIP")
        let firstZoom = canvas.zoom
        canvas.mouseDown(with: panEvent(.leftMouseDown, start))
        canvas.mouseDragged(with: panEvent(.leftMouseDragged, CGPoint(x: start.x - 60, y: start.y - 20)))
        try await settle(host)
        try require(editor.draftState != firstDraft, "The second held pan actually changes the draft before tool cancellation")
        try choose(1)
        try await settle(host)
        canvas.mouseUp(with: panEvent(.leftMouseUp, firstEnd))
        try await settle(host)
        try require(editor.draftState == firstDraft && editor.draftTime == firstTime && canvas.zoom == firstZoom &&
                    editor.project == original && editor.canUndo && !editor.canRedo &&
                    editor.project.undoHistory == original.undoHistory && editor.project.redoHistory == original.redoHistory,
                    "Switching to Draw box restores only the held Pan, retaining earlier completed shared framing without Undo/Redo or a late-release mutation (draft=\(editor.draftState == firstDraft), time \(String(describing: firstTime))→\(String(describing: editor.draftTime)), zoom \(firstZoom)→\(canvas.zoom), project=\(editor.project == original), undo=\(editor.canUndo), redo=\(editor.canRedo))")
        _ = editor.cancelDraft()
        playback.seek(playhead)
        try choose(0)
        try await settle(host)
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
        guard let camera = timeline.animationGeometry().first(where: { $0.animation.lane == .camera && $0.animation.end > 0 }),
              let initialCamera = timeline.animationGeometry().first(where: { $0.animation.lane == .camera && $0.animation.end == 0 }),
              let pointer = timeline.animationGeometry().first(where: { $0.animation.lane == .pointer }),
              let reference = timeline.animationGeometry().first(where: { $0.animation.isReference }) else {
            throw Failure.failed("Selection fixture needs Screen, both Camera cases, Pointer and a reference mark")
        }
        let selectionProject = editor.project
        let selectionTime = playback.time
        let visibleZoom = canvas.zoom, visibleCamera = canvas.placement
        let sourceViewport = canvas.testPattern?.screenViewport, cameraViewport = canvas.testPattern?.cameraViewport
        let sourceFrame = canvas.testPattern?.screenFrame, cameraFrame = canvas.testPattern?.cameraFrame
        try require(visibleZoom == editor.editingState.zoom(at: selectionTime) &&
                    visibleCamera == editor.editingState.placement(at: selectionTime),
                    "Paused preview must initially show source time rather than a previously selected edit's destination")
        for id in [animationID, initialCamera.animation.id, camera.animation.id, pointer.animation.id, reference.animation.id, animationID] {
            guard let item = timeline.animationGeometry().first(where: { $0.animation.id == id }) else {
                throw Failure.failed("Selectable lane item disappeared")
            }
            let click = CGPoint(x: item.body.midX, y: item.body.midY)
            var missingChoice = false
            timeline.presentAnimationMenu = { menu, _ in
                guard let index = menu.items.firstIndex(where: { ($0.representedObject as? TimelineAnimationID) == id }) else {
                    missingChoice = true; return
                }
                menu.performActionForItem(at: index)
            }
            timeline.mouseDown(with: mouse(.leftMouseDown, click, in: timeline, window: window))
            try require(playback.time == selectionTime, "Selecting a lane item cannot seek on mouse-down")
            timeline.mouseUp(with: mouse(.leftMouseUp, click, in: timeline, window: window))
            timeline.presentAnimationMenu = nil
            try await settle(host)
            try require(!missingChoice && timeline.selectedAnimationID == id && playback.time == selectionTime && timeline.playhead == selectionTime &&
                        canvas.zoom == visibleZoom && canvas.placement == visibleCamera &&
                        canvas.testPattern?.screenViewport == sourceViewport && canvas.testPattern?.cameraViewport == cameraViewport &&
                        canvas.testPattern?.screenFrame == sourceFrame && canvas.testPattern?.cameraFrame == cameraFrame &&
                        canvas.frame == fixedCanvas && timeline.frame == fixedTimeline && window.frame == fixedWindow &&
                        editor.project == selectionProject && editor.draftState == nil,
                        "Selecting \(item.animation.label) in \(id.lane) must highlight only that item without moving source time, screen/PIP pixels, layout or history (selected=\(String(describing: timeline.selectedAnimationID)), time \(selectionTime)→\(playback.time), zoom \(visibleZoom)→\(canvas.zoom), camera \(visibleCamera)→\(canvas.placement), project=\(editor.project == selectionProject))")
        }
        try await canvasManipulation(host: host, window: window, timeline: timeline, canvas: canvas,
            editor: editor, playback: playback, screenID: animationID, cameraID: initialCamera.animation.id)
        guard let geometry = timeline.animationGeometry().first(where: { $0.animation.id == animationID }) else {
            throw Failure.failed("Screen animation geometry missing")
        }
        let point = CGPoint(x: geometry.body.midX, y: geometry.body.midY)
        let playhead = playback.time
        timeline.mouseDown(with: mouse(.leftMouseDown, point, in: timeline, window: window))
        try require(playback.time == playhead, "Mouse-down must not seek before click versus drag is known")
        timeline.mouseUp(with: mouse(.leftMouseUp, point, in: timeline, window: window))
        try await settle(host)
        try require(timeline.selectedAnimationID == animationID && playback.time == playhead && canvas.zoom == visibleZoom && canvas.placement == visibleCamera,
                    "A completed plain click selects the animation while retaining the current source frame")
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
    static func canvasManipulation(host: NSView, window: NSWindow, timeline: RecordingTimelineView,
                                   canvas: EditorCanvasView, editor: ProjectEditor, playback: EditorPlayback,
                                   screenID: TimelineAnimationID, cameraID: TimelineAnimationID) async throws {
        let baseline = editor.project.state
        func select(_ id: TimelineAnimationID) async throws {
            playback.seek(6)
            try await settle(host)
            let item = timeline.animationGeometry().first { $0.animation.id == id }!
            let point = CGPoint(x: item.body.midX, y: item.body.midY)
            var missingChoice = false
            timeline.presentAnimationMenu = { menu, _ in
                guard let index = menu.items.firstIndex(where: { ($0.representedObject as? TimelineAnimationID) == id }) else {
                    missingChoice = true; return
                }
                menu.performActionForItem(at: index)
            }
            timeline.mouseDown(with: mouse(.leftMouseDown, point, in: timeline, window: window))
            timeline.mouseUp(with: mouse(.leftMouseUp, point, in: timeline, window: window))
            timeline.presentAnimationMenu = nil
            try await settle(host)
            try require(!missingChoice && timeline.selectedAnimationID == id && playback.time == 6,
                        "Passive selection or explicit overlap-chooser selection cannot inspect the manipulation target")
        }
        try await select(screenID)
        let start = CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.minY + canvas.contentRect.height * 0.1)
        let end = CGPoint(x: start.x + 40, y: start.y + 20)
        canvas.mouseDown(with: mouse(.leftMouseDown, start, in: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x + 1, y: start.y), in: canvas, window: window))
        try require(playback.time == 6 && editor.draftState == nil, "Click jitter cannot inspect or edit a remote target")
        canvas.mouseDragged(with: mouse(.leftMouseDragged, end, in: canvas, window: window))
        try await settle(host)
        let target = baseline.zoom(at: 1)
        let expected = ZoomPlacement(scale: target.scale,
            x: target.x - 40 / (canvas.contentRect.width * target.scale),
            y: target.y - 20 / (canvas.contentRect.height * target.scale)).clamped
        let actualPan = canvas.zoom
        try require(playback.time == 1 && abs(actualPan.scale - expected.scale) < 0.000001 &&
                    abs(actualPan.x - expected.x) < 0.000001 && abs(actualPan.y - expected.y) < 0.000001 &&
                    editor.draftState?.zoom(at: 1) == actualPan,
                    "The first deliberate Pan delta inspects and revises the selected 1s target using its 2× origin")
        canvas.mouseUp(with: mouse(.leftMouseUp, end, in: canvas, window: window))
        try await settle(host)
        try require(playback.time == 1 && canvas.zoom == actualPan && canvas.testPattern?.screenViewport == actualPan.viewport(in: playback.sourceSize),
                    "Pan release cannot snap back to the unrelated later frame")
        try require(editor.undo(), "One ordinary Undo restores the complete prepared Pan")
        try await settle(host)
        try require(editor.project.state == baseline && editor.draftState == nil, "Pan Undo retains all other edit points")
        try await select(cameraID)
        let visibleRect = canvas.testPattern!.cameraFrame
        let cameraStart = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        let cameraEnd = CGPoint(x: cameraStart.x - 40, y: cameraStart.y - 20)
        canvas.mouseDown(with: mouse(.leftMouseDown, cameraStart, in: canvas, window: window))
        try require(playback.time == 6, "Clicking a camera without moving cannot inspect its selected initial target")
        canvas.mouseDragged(with: mouse(.leftMouseDragged, cameraEnd, in: canvas, window: window))
        try await settle(host)
        let originalCamera = baseline.placement(at: 0)
        let targetRect = originalCamera.frame(in: canvas.canvasRect.size, cameraAspect: playback.cameraAspect)
        var expectedCamera = originalCamera
        expectedCamera.x -= 40 / (canvas.canvasRect.width - targetRect.width)
        expectedCamera.y -= 20 / (canvas.canvasRect.height - targetRect.height)
        let actualCamera = editor.draftState?.placement(at: 0)
        try require(playback.time == 0 && actualCamera.map { abs($0.x - expectedCamera.x) < 0.000001 && abs($0.y - expectedCamera.y) < 0.000001 && $0.scale == expectedCamera.scale } == true &&
                    canvas.testPattern?.cameraFrame == actualCamera!.frame(in: canvas.canvasRect.size, cameraAspect: playback.cameraAspect)
                        .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY),
                    "The first PIP delta is based on initial-camera geometry, not the later visible camera")
        canvas.mouseUp(with: mouse(.leftMouseUp, cameraEnd, in: canvas, window: window))
        try await settle(host)
        try require(canvas.placement == actualCamera && playback.time == 0, "PIP release preserves the same prepared target pose")
        try require(editor.undo(), "One ordinary Undo restores the complete prepared PIP change")
        try await settle(host)
        try require(editor.project.state == baseline, "PIP Undo preserves Screen and all other camera edits")
        try await select(screenID)
        canvas.mouseDown(with: mouse(.leftMouseDown, start, in: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, end, in: canvas, window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, end, in: canvas, window: window))
        try await settle(host)
        let earlierDraft = editor.draftState
        playback.seek(6)
        try await settle(host)
        canvas.mouseDown(with: mouse(.leftMouseDown, start, in: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: start.x - 40, y: start.y - 20), in: canvas, window: window))
        try await settle(host)
        try require(playback.time == 1 && editor.draftState != earlierDraft, "Escape fixture has an actual second prepared manipulation")
        canvas.cancelOperation(nil)
        canvas.mouseUp(with: mouse(.leftMouseUp, end, in: canvas, window: window))
        try await settle(host)
        try require(playback.time == 6 && editor.draftState == earlierDraft && canvas.zoom == baseline.zoom(at: 6),
                    "Escape restores the original 6s frame and earlier completed draft, canceling only the held manipulation")
        _ = editor.cancelDraft()
        playback.seek(6)
        try await settle(host)
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
