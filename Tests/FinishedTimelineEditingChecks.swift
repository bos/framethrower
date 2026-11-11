import AppKit
import SwiftUI
@testable import FrameThrower

@MainActor private final class FinishedTimingWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
private final class FinishedTimingMagnify: NSEvent {
    var point = CGPoint.zero
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { 1 }
}

/// Metadata, the production SwiftUI editor, and native synthetic events only.
/// Source filenames deliberately do not exist; no AV object is instantiated.
@main @MainActor struct FinishedTimelineEditingChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure.failed(message) }
    }
    static func near(_ a: Double, _ b: Double, _ message: String) throws {
        try require(abs(a - b) < 0.000001, "\(message): \(a) != \(b)")
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Media interlock remains enabled")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try inverseHandlesAndEligibility()
        try boundaryAndRipple()
        try preciseRateCurve()
        try await productionEditor()
        print("Finished timing editing checks passed (nonlinear handle inverses, editable cut fragments, original endpoint handles, full-project ripple, actual-rate precision, native selection/drag, pinned clocks/viewport, Escape/late-up, saved Undo/Redo, failed save, no media).")
    }
    static func span(_ lane: TimelineAnimationLane = .screen, start: Double, end: Double,
                     easeIn: Double = 0.2, easeOut: Double = 0.3) -> TimelineAnimation {
        let id = UUID()
        return .init(id: .init(lane: lane, componentID: id), editID: id, start: start, end: end,
                     easeIn: easeIn, easeOut: easeOut, label: "Test", help: "Test animation", editable: true)
    }
    static func map(cuts: [RecordingCut] = [], trimStart: Double = 0, trimEnd: Double = 14) throws -> RecordingTimeMap {
        try RecordingTimeMap(duration: 14, trimStart: trimStart, trimEnd: trimEnd, cuts: cuts,
            speedKeyframes: [.init(time: 8, rate: 3, duration: 6, easeIn: 1.2, easeOut: 1.4)])
    }
    static func inverseHandlesAndEligibility() throws {
        let clock = try map(), target = span(start: 3, end: 5), clip = clock.clips[0]
        let projection = TimelineOutputProjection(animations: [target], map: clock)
        let displayed = projection.animations[0].id
        let binding = projection.editableBindings[displayed]!
        for (handle, anchor) in [(TimelineAnimationHandle.move, target.start), (.start, target.start),
            (.end, target.end), (.easeIn, target.start + target.easeIn), (.easeOut, target.end - target.easeOut)] {
            let request = AnimationDrag(id: displayed, handle: handle, deltaSeconds: 0.15, snapTolerance: 0)
            let source = TimelineAnimationSolver.sourceDrag(request, original: target, map: clock,
                branchIndex: binding.branchIndex, moveAnchor: binding.visibleSourceStart)!
            try near(source.deltaSeconds, clip.sourceTime(at: clip.outputTime(for: anchor) + 0.15) - anchor,
                     "Each output handle uses its own frozen source anchor")
            let changed = FinishedTimelineEditing.changes(request, animations: [target], map: clock, sourceDuration: 14)!.first!
            if handle == .move { try near(changed.duration, target.duration, "Moving keeps source animation duration") }
            if handle == .easeIn { try near(changed.easeIn, target.easeIn + source.deltaSeconds, "Acceleration handle inverse") }
            if handle == .easeOut { try near(changed.easeOut, target.easeOut - source.deltaSeconds, "Deceleration handle inverse") }
        }
        let projected = TimelineOutputProjection(animations: [target], map: clock).animations[0]
        try require(projected.id != target.id && projected.editable && projection.sourceIDs[projected.id] == target.id,
                    "A visible fragment has a stable display identity resolving to its editable source component")
        try require(TimelineOutputProjection(animations: [target], map: clock).animations[0].id == projected.id,
                    "Repeated projection preserves visible fragment identity")
        try near(projected.easeIn, clip.outputTime(for: target.start + target.easeIn) - projected.start,
                 "Acceleration grip uses nonlinear output distance")
        try near(projected.easeOut, projected.end - clip.outputTime(for: target.end - target.easeOut),
                 "Deceleration grip uses nonlinear output distance")
        let cut = try map(cuts: [.init(start: 4, end: 6, crossfade: 1)])
        let crossing = span(start: 3, end: 8)
        let fragments = TimelineOutputProjection(animations: [crossing], map: cut)
        try require(fragments.animations.count == 2 && fragments.animations.allSatisfy(\.editable) &&
                    fragments.editableBindings.count == 2 && Set(fragments.animations.map(\.id)).count == 2,
                    "Both cut/crossfade fragments remain editable with distinct branch bindings")
        try require(fragments.animations.allSatisfy { fragments.sourceIDs[$0.id] == crossing.id },
                    "Every visible fragment resolves to the original edit for deletion and selection")
        let outgoing = fragments.animations[0], incoming = fragments.animations[1]
        try require(outgoing.showsStartHandle && !outgoing.showsEndHandle &&
                    !incoming.showsStartHandle && incoming.showsEndHandle,
                    "Only original animation endpoints get resize handles; cut edges do not")
        let moved = FinishedTimelineEditing.changes(.init(id: incoming.id, handle: .move,
            deltaSeconds: 0.1, snapTolerance: 0), animations: [crossing], map: cut, sourceDuration: 14)
        try require(moved?.first?.id == crossing.id && (moved?.first?.start ?? 0) > crossing.start,
                    "Dragging the incoming visible fragment edits the shared source animation")
        let clipped = span(start: 0, end: 3)
        let trimmed = try map(trimStart: 1)
        let trimmedProjection = TimelineOutputProjection(animations: [clipped], map: trimmed)
        try require(trimmedProjection.animations.count == 1 && trimmedProjection.animations[0].editable &&
                    !trimmedProjection.animations[0].showsStartHandle && trimmedProjection.animations[0].showsEndHandle,
                    "A trimmed fragment remains editable without a false trim-edge animation handle")
        let removed = span(start: 5, end: 5, easeIn: 0, easeOut: 0)
        try require(TimelineOutputProjection(animations: [removed], map: cut).animations.isEmpty,
                    "A removed jump cannot masquerade as an editable visible target")
    }
    static func boundaryAndRipple() throws {
        let clock = try map(cuts: [.init(start: 7, end: 9)])
        let target = span(start: 2, end: 4), next = span(start: 5, end: 6.5)
        let displayed = TimelineOutputProjection(animations: [target, next], map: clock).animations.first {
            $0.editID == target.editID
        }!.id
        let drag = AnimationDrag(id: displayed, handle: .move, deltaSeconds: 20, push: true, snapTolerance: 0)
        let changed = FinishedTimelineEditing.changes(drag, animations: [target, next], map: clock, sourceDuration: 14)!
        let indexed = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0) })
        try near(indexed[next.id]!.end, 14, "Ripple can cross a cut and stops at the full recording boundary")
        try require(indexed[target.id]!.end <= indexed[next.id]!.start && changed.allSatisfy { $0.end <= 14 },
                    "Finished ripple preserves same-lane ordering across retained branches")
        try near(indexed[next.id]!.duration, next.duration, "Ripple preserves neighbor source duration")
        let locked = span(start: 6, end: 10)
        let limited = FinishedTimelineEditing.changes(drag, animations: [target, locked], map: clock, sourceDuration: 14)!
        try require(limited.contains { $0.id == locked.id } && limited.allSatisfy { $0.end <= 14 },
                    "Option push includes editable split neighbors instead of locking them behind a removed source mode")
    }
    static func preciseRateCurve() throws {
        let point = RecordingSpeedKeyframe(time: 500, rate: 2, duration: 3, easeIn: 0.4, easeOut: 0.6)
        let curve = TimelineSpeedProfile.curves(points: [point], duration: 3600, map: nil)[0]
        for (start, length) in [(497.0, 0.4), (499.4, 0.6)] {
            for sample in 1..<16 {
                let time = start + length * Double(sample) / 16
                try require(curve.contains { abs($0.time - time) < 0.0000001 },
                            "Every rate ramp has sixteen subdivisions even on a one-hour timeline")
            }
        }
        try require(curve.filter { $0.time > 500 }.allSatisfy { $0.rate == 2 }, "Actual-rate curve retains its held plateau")
    }
    static func productionEditor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = RecordingProject(screenFilename: "unopened-finished-screen.mov", cameraFilename: "unopened-finished-camera.mov", duration: 14)
        project.state.trimStart = 1; project.state.trimEnd = 13
        project.state.zoomKeyframes = [.init(time: 3, scale: 2, duration: 1)]
        project.state.pipKeyframes.append(.init(time: 5, placement: .init(x: 0.2, y: 0.3), duration: 1))
        project.state.speedKeyframes = [.init(time: 6, rate: 2, duration: 3, easeIn: 0.7, easeOut: 0.8)]
        let url = directory.appendingPathComponent("finished.framethrower")
        try JSONEncoder().encode(project).write(to: url)
        let editor = try ProjectEditor.open(url: url), original = editor.project
        let playback = EditorPlayback(), session = EditorAssistantSession(transport: { _ in throw Failure.failed("No inference expected") })
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, playback: playback, assistant: session))
        let window = FinishedTimingWindow(contentRect: .init(x: -10000, y: -10000, width: 1200, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { session.suspend(); playback.close(); window.close() }
        try await settle(host)
        guard let timeline = all(RecordingTimelineView.self, in: host).first,
              let canvas = all(EditorCanvasView.self, in: host).first,
              let clock = playback.timingMap else { throw Failure.failed("Production timeline/clock missing") }
        let id = TimelineAnimationID(lane: .speed, componentID: original.state.speedKeyframes[0].id)
        let target = EditorAnimationEditing.animations(in: original.state, references: editor.references, duration: 14).first { $0.id == id }!
        guard let displayID = TimelineOutputProjection(animations: [target], map: clock).animations.first?.id else {
            throw Failure.failed("Projected speed fragment missing")
        }
        try require(timeline.animationDragProjection != nil && timeline.animationSpans.first { $0.id == displayID }?.editable == true,
                    "Production finished view offers speed timing with a projected fragment identity")
        let outputPosition = clock.clips[0].outputTime(for: 10)
        playback.seekOutput(outputPosition); try await settle(host)
        let oldTime = playback.time, oldPose = canvas.testPattern?.screenViewport
        let body = timeline.animationGeometry().first { $0.animation.id == displayID }!.body
        let middle = CGPoint(x: body.midX, y: body.midY)
        timeline.mouseDown(with: event(.leftMouseDown, middle, view: timeline))
        timeline.mouseUp(with: event(.leftMouseUp, middle, view: timeline)); try await settle(host)
        try require(timeline.selectedAnimationID == displayID && playback.time == oldTime && playback.outputTime == outputPosition &&
                    canvas.testPattern?.screenViewport == oldPose && editor.project == original,
                    "Selecting Finished speed does not seek, alter displayed pixels, or save metadata")
        let beforeDuration = timeline.duration, beforeViewport = (timeline.visibleStart, timeline.visibleDuration)
        let beforeFrame = timeline.frame, beforeCanvas = canvas.frame
        let handle = timeline.animationGeometry().first { $0.animation.id == displayID }!.endHandle!
        let start = CGPoint(x: handle.midX, y: handle.midY), end = CGPoint(x: start.x + 45, y: start.y)
        timeline.mouseDown(with: event(.leftMouseDown, start, view: timeline))
        timeline.mouseDragged(with: event(.leftMouseDragged, end, view: timeline)); try await settle(host)
        guard let draft = editor.draftState else { throw Failure.failed("Finished drag did not create a source-timed draft") }
        let arrival = draft.speedKeyframes[0].time
        try require(arrival > target.end && draft.zoomKeyframes == original.state.zoomKeyframes && draft.pipKeyframes == original.state.pipKeyframes,
                    "Native Finished timing changes only source-anchored speed arrival")
        try near(playback.outputTime, outputPosition, "Editing an animation does not move the output playhead")
        try near(playback.time, oldTime, "Timing adjustment preserves the inspected source pose on the frozen clock")
        try require(timeline.duration == beforeDuration && timeline.visibleStart == beforeViewport.0 && timeline.visibleDuration == beforeViewport.1 &&
                    timeline.frame == beforeFrame && canvas.frame == beforeCanvas && playback.timingMap?.outputDuration == clock.outputDuration,
                    "Map, viewport, ruler, and layout remain pinned during a speed draft")
        let pinch = FinishedTimingMagnify(); pinch.point = timeline.convert(middle, to: nil)
        timeline.magnify(with: pinch)
        try require(timeline.visibleDuration == beforeViewport.1, "Concurrent pinch cannot change an active timing drag's clock")
        timeline.cancelOperation(nil); timeline.mouseUp(with: event(.leftMouseUp, end, view: timeline)); try await settle(host)
        try require(editor.project == original && editor.draftState == nil && timeline.selectedAnimationID == displayID,
                    "Escape and a late mouse-up restore metadata and original selection without saving")
        try near(playback.outputTime, outputPosition, "Escape restores the exact original output playhead")
        try near(playback.time, oldTime, "Escape restores the original source pose")
        timeline.mouseDown(with: event(.leftMouseDown, start, view: timeline))
        timeline.mouseDragged(with: event(.leftMouseDragged, end, view: timeline)); try await settle(host)
        timeline.mouseUp(with: event(.leftMouseUp, end, view: timeline)); try await settle(host)
        let committed = editor.project
        try require(committed.undoHistory.count == 1 && editor.draftState == nil && committed.state.speedKeyframes[0].time == arrival &&
                    playback.outputDuration != clock.outputDuration && timeline.duration == playback.outputDuration,
                    "Release saves one operation and replaces the ruler with the newly retimed map")
        try require(editor.undo() && editor.project.state == original.state, "One Undo restores timing and rate metadata")
        try await settle(host)
        try require(editor.redo() && editor.project.state == committed.state, "One Redo restores the whole Finished gesture")
        try await settle(host)
        // Existing baseline protection makes release fail without discarding the gesture.
        timeline.onSelectAnimation?(displayID); try await settle(host)
        guard let currentHandle = timeline.animationGeometry().first(where: { $0.animation.id == displayID })?.endHandle else {
            throw Failure.failed("Reselected speed end handle missing: selected=\(String(describing: timeline.selectedAnimationID)), spans=\(timeline.animationSpans)")
        }
        let retryStart = CGPoint(x: currentHandle.midX, y: currentHandle.midY), retryEnd = CGPoint(x: currentHandle.midX + 30, y: currentHandle.midY)
        timeline.mouseDown(with: event(.leftMouseDown, retryStart, view: timeline))
        timeline.mouseDragged(with: event(.leftMouseDragged, retryEnd, view: timeline)); try await settle(host)
        guard let failedDraft = editor.draftState else { throw Failure.failed("Second timing draft missing") }
        let external = Data("External replacement must survive".utf8); try external.write(to: url)
        timeline.mouseUp(with: event(.leftMouseUp, retryEnd, view: timeline)); try await settle(host)
        try require(editor.project == committed && editor.draftState == failedDraft && editor.errorMessage != nil &&
                    (try? Data(contentsOf: url)) == external,
                    "A failed save preserves the complete timing draft and external metadata")
        try require(!playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer, "Every production interaction remains source-free")
    }
    static func event(_ type: NSEvent.EventType, _ point: CGPoint, view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    static func settle(_ host: NSView) async throws {
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { all(type, in: $0) }
    }
}
