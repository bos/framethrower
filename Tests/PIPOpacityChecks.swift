import AppKit
import Combine
import Darwin

#if !FRAMETHROWER_FULL_EDITING_CHECKS
@MainActor final class EditorFrameStore: ObservableObject { @Published var image: CGImage? }
#endif
private struct OpacityFailure: Error { let message: String }

/// Metadata, native vector layers, and disposable project files only. Never
/// creates a player, source asset, bitmap, captured image, or compositor request.
@main @MainActor
struct PIPOpacityChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw OpacityFailure(message: message) }
    }
    static func near(_ a: Double, _ b: Double, _ message: String) throws {
        try require(abs(a - b) < 0.000001, message)
    }
    static let original = PIPPlacement(x: 0.2, y: 0.8, scale: 0.3, shape: .circle,
        crop: .init(x: 0.25, y: 0.7), sourceZoom: 1.4, fullscreen: 0.4)
    static let fadeOut = EditorMutation.cameraOverlay(.init(opacity: 0), timing: .init(start: 2, end: 4, easeIn: 0.3, easeOut: 0.6))
    static let fadeIn = EditorMutation.cameraOverlay(.init(opacity: 1), timing: .init(start: 6, end: 8, easeIn: 0.2, easeOut: 0.5))
    static func fixture() -> RecordingProject {
        var project = RecordingProject(screenFilename: "unopened-screen.mov", cameraFilename: "unopened-camera.mov", duration: 14)
        project.cameraOffset = 0.75
        project.state.pipKeyframes = [.init(time: 0, placement: original)]
        project.state.zoomKeyframes = [.init(time: 0, scale: 2, x: 0.4, y: 0.5)]
        return project
    }
    static func faded(_ baseline: RecordingProject? = nil) throws -> RecordingProject {
        var project = baseline ?? fixture(), state = project.state
        try fadeOut.apply(to: &state, project: project)
        try fadeIn.apply(to: &state, project: project)
        project.state = state
        return project
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "media interlock stays enabled")
        try legacyAndBounds(); try clockAndIdentity(); try independentGeometry(); try durableHistory(); try vectorBranches()
        print("PIP opacity checks passed: legacy visibility/defaults, exact easing, strict mutation/schema, labels/identity, durable Undo/Redo, independent cut branches and native alpha; no media operations.")
    }
    static func legacyAndBounds() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var legacyObject = try JSONSerialization.jsonObject(with: encoder.encode(original)) as! [String: Any]
        legacyObject.removeValue(forKey: "opacity")
        let legacy = try decoder.decode(PIPPlacement.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        try require(legacy.opacity == 1 && legacy == original, "absent opacity defaults to1 without rewriting legacy metadata")
        var hidden = original; hidden.visible = false
        let old = EditState(trimStart: 0, trimEnd: 14, pipKeyframes: [.init(time: 0, placement: hidden),
            .init(time: 4, placement: original, transition: .smooth, duration: 2)])
        var oldObject = try JSONSerialization.jsonObject(with: encoder.encode(old)) as! [String: Any]
        oldObject.removeValue(forKey: "cameraOpacityKeyframes")
        let roundTrip = try decoder.decode(EditState.self, from: JSONSerialization.data(withJSONObject: oldObject))
        try require(roundTrip.cameraOpacityKeyframes.isEmpty, "legacy states must default to no independent opacity points")
        try require(roundTrip.placement(at: 3.5).renderedOpacity == 0 && roundTrip.placement(at: 4).renderedOpacity == 1,
            "old visible-only transitions must keep their discrete arrival semantics")
        var project = fixture()
        project.state.pipKeyframes.append(.init(time: 2, placement: hidden, transition: .smooth, duration: 1))
        let oldHidden = project.state.pipKeyframes[1]
        var state = project.state
        try EditorMutation.cameraOverlay(.init(opacity: 1), timing: .init(start: 2, end: 4, easeIn: 0.4, easeOut: 0.7)).apply(to: &state, project: project)
        try require(state.pipKeyframes[1] == oldHidden && state.placement(at: 1.5) == project.state.placement(at: 1.5), "new fade-in rewrote the earlier legacy hide/motion")
        let progress = MotionInterpolation.progress(at: 3, from: 2, to: 4, duration: 2, transition: .smooth, easeIn: 0.4, easeOut: 0.7)
        try near(state.placement(at: 3).renderedOpacity, progress, "legacy-hidden camera must fade in before arrival")
        try require(state.placement(at: 2).renderedOpacity == 0 && state.placement(at: 4).renderedOpacity == 1, "legacy fade endpoints")
        var rawAlpha = fixture()
        var partial = original; partial.opacity = 0.2
        rawAlpha.state.pipKeyframes = [.init(time: 0, placement: original),
            .init(time: 4, placement: original, transition: .smooth, duration: 4),
            .init(time: 10, placement: partial, transition: .smooth, duration: 10, easeIn: 2, easeOut: 3)]
        var future = rawAlpha.state
        try EditorMutation.cameraOverlay(.init(opacity: 1), timing: .init(start: 12, end: 13)).apply(to: &future, project: rawAlpha)
        for index in 0...220 {
            let time = Double(index) / 20
            try near(future.placement(at: time).renderedOpacity, rawAlpha.state.placement(at: time).renderedOpacity,
                "future independent point changed an earlier embedded alpha fade or its clipped start")
        }
        let persisted = try decoder.decode(EditState.self, from: encoder.encode(state))
        try near(persisted.placement(at: 3).renderedOpacity, progress, "field presence needed for legacy fade-in was lost on save")
        for bad in [-0.01, 1.01, Double.nan, Double.infinity] {
            let project = fixture(); var value = project.state
            do {
                try EditorMutation.cameraOverlay(.init(opacity: bad), timing: .init(start: 2, end: 4)).apply(to: &value, project: project)
                throw OpacityFailure(message: "invalid opacity accepted")
            } catch is ProjectError {} catch is EditorMutationError {}
            try require(value == project.state, "invalid opacity changed metadata")
        }
        for patch in [#"{"opacity":null}"#, #"{"opacity":true}"#, #"{"opactiy":0.5}"#] {
            let raw = "{\"operation\":\"cameraOverlay\",\"patch\":\(patch),\"timing\":{\"start\":2,\"end\":4}}"
            do { _ = try decoder.decode(EditorMutation.self, from: Data(raw.utf8)); throw OpacityFailure(message: "malformed patch accepted") }
            catch is DecodingError {} catch is EditorMutationError {}
        }
        let project0 = fixture(); var same = project0.state
        try EditorMutation.cameraOverlay(.init(opacity: 1), timing: .init(start: 2, end: 4)).apply(to: &same, project: project0)
        try require(same == project0.state, "explicit1 over legacy visible1 creates a spurious edit")
        let descriptor = EditorMutation.schemaDescriptors.first { (($0["properties"] as? [String: Any])?["operation"] as? [String: Any])?["const"] as? String == "cameraOverlay" }!
        let properties = descriptor["properties"] as! [String: Any]
        let patch = properties["patch"] as! [String: Any]
        let alpha = (patch["properties"] as! [String: Any])["opacity"] as! [String: Any]
        try require(alpha["minimum"] as? Double == 0 && alpha["maximum"] as? Double == 1 && patch["additionalProperties"] as? Bool == false, "discovered schema must strictly bound camera alpha")
        try require(try decoder.decode(EditorCommand.self, from: encoder.encode(EditorCommand.mutate(fadeOut))) == .mutate(fadeOut), "typed opacity roundtrip")
    }
    static func clockAndIdentity() throws {
        let baseline = fixture(), project = try faded(baseline), state = project.state
        for time in [0, 2, 2.1, 2.5, 3, 3.8, 4, 5] as [Double] {
            let expected = 1 - MotionInterpolation.progress(at: time, from: 2, to: 4, duration: 2, transition: .smooth, easeIn: 0.3, easeOut: 0.6)
            try near(state.placement(at: time).opacity, expected, "fade must use the same exact movement clock and ramps")
        }
        try require(state.placement(at: 4).visible && state.placement(at: 4).opacity == 0 && state.placement(at: 8).opacity == 1,
            "new fades must retain visible compatibility without discrete jumps")
        for point in state.pipKeyframes {
            var geometry = point.placement; geometry.opacity = original.opacity
            var normalized = original; normalized.opacity = original.opacity
            try require(geometry == normalized, "fade changed camera framing/fullscreen/crop")
        }
        try require(project.cameraOffset == 0.75 && state.zoomKeyframes == baseline.state.zoomKeyframes, "fade changed source offset or main video framing")
        var references = EditorReferences(); references.register(state: state)
        let animations = EditorAnimationEditing.animations(in: state, references: references, duration: 14)
        let target = state.cameraOpacityKeyframes.first { $0.time == 4 }!
        let lane = animations.first { $0.id == .init(lane: .cameraOpacity, componentID: target.id) }!
        try require(lane.label.hasPrefix("Fade camera out") && lane.start == 2 && lane.end == 4, "camera lane lost fade action or complete interval")
        let edit = state.timedEdits(includeCamera: true).first { $0.cameraOpacityID == target.id }!
        let description = EditorActionDescription.describe(edit, in: state, references: references)
        try require(EditorActionDescription.resolve(description.shortLabel, in: state, references: references)?.cameraOpacityID == target.id,
            "descriptive fade label no longer resolves stable camera identity")
        let changes = TimelineAnimationSolver.solve(.init(id: lane.id, handle: .easeOut, deltaSeconds: -0.1), animations: animations, duration: 14)!
        let adjusted = EditorAnimationEditing.applying(changes, to: state, duration: 14)!
        try require(adjusted.state.cameraOpacityKeyframes.first { $0.id == target.id }!.opacity == target.opacity && adjusted.state.pipKeyframes == state.pipKeyframes, "ramp edit detached camera opacity or geometry")
        try require(EditorActionDescription.cameraOpacityLabel(1) == "Fade camera in" && EditorActionDescription.cameraOpacityLabel(0.4) == "Fade camera to 40%", "partial/full fade labels")
    }
    static func independentGeometry() throws {
        var moving = fixture()
        var destination = original; destination.x = 0.85; destination.y = 0.15; destination.scale = 0.45
        destination.crop = .init(x: 0.7, y: 0.2); destination.sourceZoom = 2; destination.fullscreen = 0.8
        moving.state.pipKeyframes.append(.init(time: 10, placement: destination, transition: .smooth, duration: 10, easeIn: 2, easeOut: 3))
        let baseline = moving.state
        var state = baseline
        let fade = EditorMutation.cameraOverlay(.init(opacity: 0), timing: .init(start: 3, end: 5, easeIn: 0.4, easeOut: 0.6))
        try require(fade.conflicts(in: state).isEmpty, "opacity-only edits conflict with camera geometry")
        try fade.apply(to: &state, project: moving)
        try require(state.pipKeyframes == baseline.pipKeyframes && state.cameraOpacityKeyframes.count == 2, "fade inserted or rewrote geometry points")
        for index in 0...280 {
            let time = Double(index) / 20
            try require(state.cameraGeometry(at: time) == baseline.cameraGeometry(at: time), "fade changed the existing 0→10 camera motion")
            var actual = state.placement(at: time), expected = baseline.placement(at: time)
            actual.opacity = 1; expected.opacity = 1
            try require(actual == expected, "resolved camera geometry changed during independent fade")
        }
        try near(state.cameraOpacity(at: 4), 1 - MotionInterpolation.progress(at: 4, from: 3, to: 5,
            duration: 2, transition: .smooth, easeIn: 0.4, easeOut: 0.6), "opacity owns the complete 3→5 ramp")
        // A later geometry-only command may overlap a long opacity fade.
        var separate = fixture(), alphaState = separate.state
        try EditorMutation.cameraOverlay(.init(opacity: 0), timing: .init(start: 2, end: 12)).apply(to: &alphaState, project: separate)
        separate.state = alphaState
        try EditorMutation.cameraOverlay(.init(position: .init(x: 0.8, y: 0.1)), timing: .init(start: 4, end: 8)).apply(to: &alphaState, project: separate)
        try require(alphaState.cameraOpacityKeyframes == separate.state.cameraOpacityKeyframes, "geometry edit changed independent opacity points")
        for index in 0...140 { try near(alphaState.cameraOpacity(at: Double(index) / 10), separate.state.cameraOpacity(at: Double(index) / 10), "geometry keyframes bounded opacity") }
        let project = fixture(); var combined = project.state
        try EditorMutation.cameraOverlay(.init(position: .init(x: 0.8, y: 0.1), opacity: 0.4), timing: .init(start: 3, end: 5)).apply(to: &combined, project: project)
        try require(combined.pipKeyframes.contains { $0.time == 5 && $0.placement.x == 0.8 } && combined.cameraOpacityKeyframes.contains { $0.time == 5 && $0.opacity == 0.4 }, "combined patch did not create co-timed independent targets atomically")
        var failed = project.state
        do {
            try EditorMutation.cameraOverlay(.init(position: .init(x: 0.8, y: 0.1), opacity: 2), timing: .init(start: 3, end: 5)).apply(to: &failed, project: project)
            throw OpacityFailure(message: "invalid combined alpha accepted")
        } catch is EditorMutationError {}
        try require(failed == project.state, "invalid combined patch partially changed geometry")
        var instant = project.state
        try EditorMutation.cameraOverlay(.init(scale: 0.4, opacity: 0.3), timing: .init(start: 0, end: 0, transition: .jump)).apply(to: &instant, project: project)
        try require(instant.cameraGeometry(at: 0).scale == 0.4 && instant.cameraOpacity(at: 0) == 0.3,
            "same-point combined patch must preserve both independent properties")
        var hidden = instant
        do {
            try EditorMutation.cameraOverlay(.init(visible: false), timing: .init(start: 0, end: 0, transition: .jump)).apply(to: &hidden, project: project)
            try require(hidden.placement(at: 0).renderedOpacity == 0 && hidden.pipKeyframes == instant.pipKeyframes,
                "successful visibility-only patch must hide through opacity ownership without changing geometry")
        } catch let error as EditorMutationError {
            if case .conflicts = error {} else { throw error }
            try require(hidden == instant, "conflicting visibility patch partially changed metadata")
        }
        var contradictory = project.state
        do {
            try EditorMutation.cameraOverlay(.init(visible: false, opacity: 0.5), timing: .init(start: 3, end: 5)).apply(to: &contradictory, project: project)
            throw OpacityFailure(message: "contradictory visibility/nonzero alpha accepted")
        } catch is EditorMutationError {}
        try require(contradictory == project.state, "contradictory visibility patch mutated the project")
        var visibility = project.state
        try EditorMutation.cameraOverlay(.init(visible: false), timing: .init(start: 3, end: 5)).apply(to: &visibility, project: project)
        try require(visibility.pipKeyframes == project.state.pipKeyframes && visibility.placement(at: 5).renderedOpacity == 0,
            "visibility-only patches must use independent alpha, including over a geometry track")
        try EditorMutation.cameraOverlay(.init(visible: true), timing: .init(start: 7, end: 9)).apply(to: &visibility, project: project)
        try require(visibility.placement(at: 9).renderedOpacity == 1 && visibility.pipKeyframes == project.state.pipKeyframes,
            "compatibility Show must restore opacity without geometry points")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-moving-opacity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ProjectEditor(project: moving, url: directory.appendingPathComponent("Moving.framethrower"))
        try require(editor.save(), "save moving camera fixture")
        let scope = UUID()
        let batch = EditorCommandBatch(projectID: scope, revision: try EditorCommandDispatcher.revision(for: editor.project), commands: [.mutate(fade)])
        try require(try EditorCommandDispatcher.apply(batch, to: editor, projectID: scope, name: "Independent fade"), "apply independent fade over moving camera")
        try require(editor.project.undoHistory.count == 1 && editor.project.state.pipKeyframes == baseline.pipKeyframes,
            "independent fade must be one Undo and preserve geometry points")
        try require(editor.undo() && editor.project.state == baseline && editor.redo() && editor.project.state.pipKeyframes == baseline.pipKeyframes,
            "Undo/Redo detached the original moving-camera curve")
    }

    static func durableHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-opacity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = fixture(), editor = ProjectEditor(project: original, url: directory.appendingPathComponent("Opacity.framethrower"))
        try require(editor.save(), "save disposable project")
        let id = UUID(), batch = EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: editor.project), commands: [.mutate(fadeOut), .mutate(fadeIn)])
        try require(try EditorCommandDispatcher.apply(batch, to: editor, projectID: id, name: "Camera fades"), "apply typed fade batch")
        let applied = editor.project.state
        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.project.state == applied && reopened.project.state.placement(at: 5).opacity == 0, "opacity/project history did not persist")
        try require(reopened.undo() && reopened.project.state == original.state && !reopened.canUndo, "one Undo must restore legacy placements")
        let undone = try ProjectEditor.open(url: editor.url)
        try require(undone.project.state.pipKeyframes[0].placement.opacity == 1 && undone.project.state.cameraOpacityKeyframes.isEmpty && undone.canRedo,
            "old/default opacity in Undo snapshots changed")
        try require(undone.redo() && undone.project.state == applied, "durable Redo must restore fade metadata and identities")
    }
    static func vectorBranches() throws {
        _ = NSApplication.shared
        let pattern = EditorTestPattern(), bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
        let source = CGSize(width: 1920, height: 1080)
        let shapeCount = pattern.layer.sublayers![1].sublayers!.count
        for opacity in [0.0, 0.2, 0.6, 1] {
            var placement = original; placement.opacity = opacity
            pattern.update(in: bounds, presentation: .init(), zoom: .init(), placement: placement, cameraEnabled: true, cameraAspect: 16.0 / 9)
            let camera = pattern.layer.sublayers![1]
            try near(Double(camera.opacity), opacity, "vector alpha must multiply only the camera")
            try require(camera.isHidden == (opacity == 0) && camera.sublayers!.count == shapeCount && pattern.layer.sublayers![0].opacity == 1,
                "transparent camera discarded its original content or faded the main screen")
            try require(pattern.cameraViewport == placement.sourceViewport(in: source, canvas: PresentationGeometry(sourceSize: source, presentation: .init()).outputRect(in: bounds).size), "opacity changed original camera crop")
        }
        var project = try faded(); project.state.cuts = [.init(start: 4, end: 6, crossfade: 1)]
        let map = try RecordingTimeMap(duration: 14, trimStart: 0, trimEnd: 14, cuts: project.state.cuts)
        let samples = map.samples(at: 3.5)
        try require(samples.count == 2 && samples[0].sourceTime != samples[1].sourceTime, "cut fixture must show two independent source moments")
        let canvas = EditorCanvasView(frame: bounds)
        let poses = samples.map { EditorCanvasSample(sourceTime: $0.sourceTime, weight: $0.weight,
            zoom: project.state.zoom(at: $0.sourceTime), placement: project.state.placement(at: $0.sourceTime)) }
        canvas.configure(player: nil, image: nil, sourceSize: source, cameraAspect: 16.0 / 9, placement: original,
            cameraEnabled: false, showsCameraPattern: true, outputSamples: poses)
        try require(!canvas.hasMediaPlayerLayer && canvas.testPattern != nil && canvas.incomingTestPattern != nil, "vector branch check created media or lost a branch")
        let timeline = RecordingTimelineView(frame: CGRect(x: 0, y: 0, width: 900, height: RecordingTimeline.clipLaneHeight + 30))
        timeline.showsAnimationLanes = true; timeline.showsClipLane = true; timeline.showsCameraOpacityLane = true
        timeline.duration = 14; timeline.trimStart = 0; timeline.trimEnd = 14; timeline.fit(request: UUID())
        let animations = EditorAnimationEditing.animations(in: project.state, references: .init(), duration: 14)
        timeline.animationSpans = animations
        let opacity = animations.first { $0.lane == .cameraOpacity && !$0.isInstant }!
        timeline.selectedAnimationID = opacity.id
        let handles = timeline.animationGeometry().first { $0.animation.id == opacity.id }!
        try require(timeline.animationLanes().contains { $0.lane == .cameraOpacity && $0.title == "Opacity" } &&
            handles.startHandle != nil && handles.endHandle != nil && handles.easeInHandle != nil,
            "opacity lane must expose the same move/timing/ramp controls independently of camera geometry")
        try require(timeline.intrinsicContentSize.height == RecordingTimeline.clipLaneHeight + 30, "opacity lane must use a fixed native allocation")
        let outgoing = canvas.testPattern!.layer.sublayers![1], incoming = canvas.incomingTestPattern!.layer.sublayers![1]
        try near(Double(outgoing.opacity), poses[0].placement.renderedOpacity, "outgoing branch must evaluate its own source opacity")
        try near(Double(incoming.opacity), poses[1].placement.renderedOpacity, "incoming branch must evaluate its own source opacity")
        try near(Double(canvas.incomingTestPattern!.layer.opacity), poses[1].weight, "cut weight must multiply the complete independently composed camera/screen branch")
    }
}
