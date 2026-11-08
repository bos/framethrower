import Foundation

private enum MutationCheckError: Error { case failed(String) }

@main
@MainActor
struct EditorMutationChecks {
    static func main() throws {
        try require(MediaProcessing.isSuspended, "media interlock")
        try checkStrictCoding()
        try checkExactScreenAlignment()
        try checkCameraAndSourceIndependence()
        try checkVerifiedPIPAlignment()
        try checkLaneConflicts()
        try checkGlobalPatches()
        try checkAtomicDocumentHistory()
        print("Editor mutation checks passed (strict nested coding, exact pan/zoom/anchors, verified PIP geometry, independent patches, shared motion, lane conflicts, atomic rename+edits, save failure, Undo/Redo).")
    }
    private static func require(_ test: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try test() else { throw MutationCheckError.failed(message) }
    }
    private static func rejects(_ body: () throws -> Void, _ message: String) throws {
        do { try body() } catch is EditorMutationError { return } catch is EditorCommandError { return } catch is ProjectError { return } catch is DecodingError { return }
        throw MutationCheckError.failed(message)
    }
    private static let regionID = UUID(uuidString: "00000000-0000-4000-8000-000000000009")!
    private static let sharedID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private static func project(scale: Double = 2) -> RecordingProject {
        let placement = PIPPlacement(x: 0.75, y: 0.6, scale: 0.25, visible: true, shape: .rectangle,
            aspectRatio: 1.5, crop: PIPCrop(x: 0.3, y: 0.6), sourceZoom: 1.4)
        var state = EditState(trimStart: 0, trimEnd: 10, pipKeyframes: [PIPKeyframe(id: sharedID, time: 0, placement: placement)])
        state.zoomKeyframes = [ZoomKeyframe(id: sharedID, time: 0, scale: scale)]
        state.editAnchors = [EditAnchor(id: sharedID, time: 0)]
        state.regions = [EditorRegion(id: regionID, time: 6, rect: .init(x: 0.1, y: 0.15, width: 0.4, height: 0.3))]
        state.cursorStyle.size = 1.8; state.cursorStyle.smoothing = 0.2
        state.audio.volume = 0.8; state.audio.fadeIn = 0.4; state.audio.fadeOut = 0.8
        return RecordingProject(screenFilename: "unopened-screen.mov", cameraFilename: "unopened-camera.mov", duration: 10, state: state)
    }
    private static let interval = EditorMutationTiming(start: 2, end: 5, easeIn: 0.3, easeOut: 0.7)

    private static func checkStrictCoding() throws {
        let samples: [EditorMutation] = [
            .panScreen(center: .init(x: 0.4, y: 0.4), timing: interval),
            .zoomScreen(scale: 2.5, center: nil, timing: interval),
            .alignScreen(regionID: regionID, subjectAnchor: .topLeft, targetAnchor: .topLeft, axes: .both, scalePolicy: .preserve, timing: interval),
            .cameraOverlay(.init(position: .init(x: 0, y: 0), scale: 0.2, shape: .circle, visible: false), timing: interval),
            .cameraSource(.init(crop: PIPCrop(x: 0.2, y: 0.5), sourceZoom: 2), timing: interval),
            .alignCameraOverlay(regionID: regionID, subjectAnchor: .center, targetAnchor: .center, axes: .both, timing: interval),
            .pointer(.init(size: 2)), .audio(.init(volume: 0.5)), .canvas(.init(padding: 0.1)), .trim(start: 1, end: 9)]
        for value in samples {
            let data = try JSONEncoder().encode(EditorCommand.mutate(value))
            try require(try JSONDecoder().decode(EditorCommand.self, from: data) == .mutate(value), "every mutation roundtrips through existing command decoder")
        }
        let invalid = [
            #"{"operation":"panScreen","center":{"x":0.5,"y":0.5,"path":"/private"},"timing":{"start":2,"end":5}}"#,
            #"{"operation":"cameraOverlay","patch":{"position":{"x":0.5,"y":0.5},"sourceZoom":2},"timing":{"start":2,"end":5}}"#,
            #"{"operation":"audio","patch":{"volume":0.5,"file":"secret"}}"#,
            #"{"operation":"audio","patch":{"volume":null}}"#,
            #"{"operation":"pointer","patch":{"visible":1}}"#,
            #"{"operation":"canvas","patch":{"background":{"red":1,"green":0,"blue":0,"alpha":0}}}"#,
            #"{"operation":"cameraSource","patch":{"crop":{"x":0.5,"y":0.5,"zoom":2}},"timing":{"start":2,"end":5}}"#,
            #"{"operation":"zoomScreen","scale":2,"timing":{"start":2,"end":5,"speed":5}}"#,
            #"{"operation":"panScreen","center":{"x":0.5,"y":0.5},"scale":3,"timing":{"start":2,"end":5}}"#]
        for json in invalid {
            try rejects({ _ = try JSONDecoder().decode(EditorMutation.self, from: Data(json.utf8)) }, "unknown, null, wrong-type and cross-subject fields reject")
        }
        let schema = try JSONSerialization.jsonObject(with: EditorMutation.schemaData()) as! [String: Any]
        try require((schema["oneOf"] as? [Any])?.count == samples.count, "catalog covers all mutation cases")
        try require(JSONSerialization.isValidJSONObject(EditorMutation.documentation), "catalog documentation is serializable")
    }

    private static func checkExactScreenAlignment() throws {
        let base = project(), previous = base.state
        var state = previous
        let pan = EditorMutation.alignScreen(regionID: regionID, subjectAnchor: .topLeft, targetAnchor: .topLeft,
            axes: .both, scalePolicy: .preserve, timing: interval)
        try pan.apply(to: &state, project: base)
        let viewport = state.zoom(at: 5).viewport(in: CGSize(width: 1, height: 1))
        try require(abs(viewport.minX - 0.1) < 1e-12 && abs(viewport.minY - 0.15) < 1e-12 && state.zoom(at: 5).scale == 2,
                    "pan aligns raw Box corner without fitting or zooming")
        try require(state.zoom(at: 1.9) == previous.zoom(at: 1.9), "source before requested start unchanged")
        let end = state.zoomKeyframes.last!
        try require(end.time == 5 && end.duration == 3 && end.easeIn == 0.3 && end.easeOut == 0.7 && end.sourceRegionID == regionID, "exact source range, ramps and explicit Box connection retained")
        let p = MotionInterpolation.progress(at: 3.3, from: 2, to: 5, duration: 3, transition: .smooth, easeIn: 0.3, easeOut: 0.7)
        try require(abs(state.zoom(at: 3.3).x - (0.5 + (0.35 - 0.5) * p)) < 1e-12, "screen uses shared motion rather than bespoke interpolation")
        try require(state.pipKeyframes == previous.pipKeyframes && state.regions == previous.regions && state.editAnchors == previous.editAnchors, "other lane and reference identities untouched")
        let full = project(scale: 1)
        state = full.state
        try rejects({ try pan.apply(to: &state, project: full) }, "captured full-frame corner pan is impossible")
        try require(state == full.state, "impossible pan creates no partial start anchor")
        var fit = previous
        try EditorMutation.alignScreen(regionID: regionID, subjectAnchor: .topLeft, targetAnchor: .topLeft,
            axes: .both, scalePolicy: .fitRegion, timing: interval).apply(to: &fit, project: base)
        try require(abs(fit.zoom(at: 5).scale - 2.5) < 1e-12 && abs(fit.zoom(at: 5).viewport(in: CGSize(width: 1, height: 1)).minX - 0.1) < 1e-12,
                    "explicit zoom-to-fit uses raw size and anchor, not legacy10% center padding")
        var horizontal = previous
        try EditorMutation.alignScreen(regionID: regionID, subjectAnchor: .left, targetAnchor: .left,
            axes: .horizontal, scalePolicy: .preserve, timing: interval).apply(to: &horizontal, project: base)
        try require(horizontal.zoom(at: 5).y == previous.zoom(at: 2).y, "one-axis alignment preserves unrequested focal axis")
        var noOp = previous
        try EditorMutation.panScreen(center: .init(x: 0.5, y: 0.5), timing: interval).apply(to: &noOp, project: base)
        try require(noOp == previous, "no-op pan creates no timing-only history noise")
    }

    private static func checkCameraAndSourceIndependence() throws {
        let base = project(), before = base.state.placement(at: 2)
        var state = base.state
        try EditorMutation.cameraOverlay(.init(position: .init(x: 0, y: 0)), timing: interval).apply(to: &state, project: base)
        var expected = before; expected.x = 0; expected.y = 0
        try require(state.placement(at: 5) == expected, "overlay pan preserves shape size visibility and camera source crop/zoom")
        try require(state.zoomKeyframes == base.state.zoomKeyframes, "camera pan cannot fit the main screen Box")
        let p = MotionInterpolation.progress(at: 3.3, from: 2, to: 5, duration: 3, transition: .smooth, easeIn: 0.3, easeOut: 0.7)
        try require(abs(state.placement(at: 3.3).x - before.x * (1 - p)) < 1e-12, "PIP uses the same shared motion")
        state = base.state
        try EditorMutation.cameraSource(.init(crop: PIPCrop(x: 0.1, y: 0.8), sourceZoom: 2), timing: interval).apply(to: &state, project: base)
        var cropped = before; cropped.crop = PIPCrop(x: 0.1, y: 0.8); cropped.sourceZoom = 2
        try require(state.placement(at: 5) == cropped, "camera-source framing leaves overlay position/shape/size alone")
        state = base.state
        try EditorMutation.cameraOverlay(.init(scale: 0.3, shape: .circle, visible: false), timing: .at(0)).apply(to: &state, project: base)
        try require(state.pipKeyframes.first?.id == sharedID && state.zoomKeyframes.first?.id == sharedID,
                    "editing initial appearance preserves shared raw identities without editing screen")
        try require(state.pipKeyframes.first?.placement.crop == before.crop && state.pipKeyframes.first?.placement.visible == false,
                    "appearance patch does not reset camera framing")
        var absent = base; absent.cameraFilename = nil
        var absentState = absent.state
        try rejects({ try EditorMutation.cameraOverlay(.init(scale: 0.2), timing: interval).apply(to: &absentState, project: absent) }, "no fabricated camera source")
    }

    private static func checkVerifiedPIPAlignment() throws {
        var base = project(scale: 1)
        base.state.presentation = CanvasPresentation(aspect: .portrait, padding: 0.1)
        let geometry = EditorMutationGeometry(sourceSize: CGSize(width: 1920, height: 1080), cameraAspect: 4 / 3.0)
        let mutation = EditorMutation.alignCameraOverlay(regionID: regionID, subjectAnchor: .topLeft, targetAnchor: .topLeft, axes: .both, timing: interval)
        var state = base.state
        try rejects({ try mutation.apply(to: &state, project: base) }, "unknown source geometry must not use16:9 simulation fallback")
        try require(state == base.state, "unavailable geometry is atomic")
        try mutation.apply(to: &state, project: base, geometry: geometry)
        let presentation = PresentationGeometry(sourceSize: geometry.sourceSize, presentation: base.state.presentation)
        let frame = state.placement(at: 5).frame(in: presentation.outputSize, cameraAspect: geometry.cameraAspect!)
        let box = base.state.regions[0].rect
        try require(abs(frame.minX - (presentation.contentRect.minX + box.x * presentation.contentRect.width)) < 1e-8 &&
                    abs(frame.minY - (presentation.contentRect.minY + box.y * presentation.contentRect.height)) < 1e-8,
                    "PIP maps original screen Box through padded portrait output instead of treating travel as source coords")
        try require(state.placement(at: 5).scale == base.state.placement(at: 2).scale && state.placement(at: 5).crop == base.state.placement(at: 2).crop,
                    "alignment preserves size and crop")
        base.state.pipKeyframes[0].placement.shape = .original
        state = base.state
        try rejects({ try mutation.apply(to: &state, project: base, geometry: .init(sourceSize: geometry.sourceSize, cameraAspect: nil)) }, "original camera shape requires verified camera aspect")
    }

    private static func checkLaneConflicts() throws {
        var base = project()
        let screenID = UUID(), cameraID = UUID()
        base.state.zoomKeyframes.append(ZoomKeyframe(id: screenID, time: 6, scale: 2.5, transition: .smooth, duration: 3))
        let pan = EditorMutation.panScreen(center: .init(x: 0.4, y: 0.4), timing: interval)
        let conflicts = pan.conflicts(in: base.state)
        try require(conflicts.count == 1 && conflicts[0].lane == .screen && conflicts[0].componentID == screenID && conflicts[0].start == 3 && conflicts[0].end == 6,
                    "following movement crossing arrival is an explicit same-lane conflict")
        var state = base.state
        try rejects({ try pan.apply(to: &state, project: base) }, "cannot silently clip or replace existing movement")
        try require(state == base.state, "conflict does not insert start/end points")
        let camera = EditorMutation.cameraOverlay(.init(position: .init(x: 0.1, y: 0.2)), timing: interval)
        try require(camera.conflicts(in: base.state).isEmpty, "screen movement does not block independent camera lane")
        try camera.apply(to: &state, project: base)
        base = project()
        base.state.pipKeyframes.append(PIPKeyframe(id: cameraID, time: 4, placement: PIPPlacement(), transition: .smooth, duration: 2))
        try require(camera.conflicts(in: base.state).first?.componentID == cameraID, "camera conflicts identify component, not grouped screen edit")
        base = project(); base.state.zoomKeyframes.append(ZoomKeyframe(id: screenID, time: 5, scale: 2.2, transition: .jump))
        try require(pan.conflicts(in: base.state).count == 1, "occupied jump arrival cannot be overwritten at a touching boundary")
        try require(camera.effects(duration: 10).first?.subject == .cameraOverlay, "host preflight has lane/range/subject metadata")
    }

    private static func checkGlobalPatches() throws {
        let base = project()
        var state = base.state
        try EditorMutation.pointer(.init(size: 2.5)).apply(to: &state, project: base)
        try require(state.cursorStyle.size == 2.5 && state.cursorStyle.smoothing == base.state.cursorStyle.smoothing, "pointer patch preserves unrequested style")
        try EditorMutation.audio(.init(volume: 0.3, fadeOut: 5)).apply(to: &state, project: base)
        try EditorMutation.trim(start: 2, end: 3).apply(to: &state, project: base)
        try require(state.audio.fadeOut == 5 && state.audio.fadeIn == 0.4 && state.audio.effectiveFades(duration: 1).fadeOut < 1, "trim keeps requested fades while effective envelope clamps")
        try EditorMutation.canvas(.init(padding: 0.1)).apply(to: &state, project: base)
        try require(state.presentation.padding == 0.1 && state.presentation.aspect == base.state.presentation.aspect && state.zoomKeyframes == base.state.zoomKeyframes, "canvas does not rewrite source coordinates")
        let before = state
        for mutation in [EditorMutation.pointer(.init()), .audio(.init(volume: 2)), .trim(start: 3, end: 2), .canvas(.init(padding: -1))] {
            try rejects({ try mutation.apply(to: &state, project: base) }, "invalid global patch rejects")
            try require(state == before, "inout direct call is atomic on every validation error")
        }
    }

    private static func checkAtomicDocumentHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Metadata.framethrower"), initial = project()
        try JSONEncoder().encode(initial).write(to: url)
        let editor = try ProjectEditor.open(url: url), id = UUID(), original = editor.project
        let commands: [EditorCommand] = [.mutate(.panScreen(center: .init(x: 0.4, y: 0.4), timing: interval)),
            .mutate(.cameraOverlay(.init(position: .init(x: 0.1, y: 0.2)), timing: interval)), .mutate(.audio(.init(volume: 0.4)))]
        let batch = EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: original), commands: commands, title: "Named recording")
        _ = try EditorCommandDispatcher.apply(batch, to: editor, projectID: id)
        let changed = editor.project
        try require(changed.title == "Named recording" && changed.undoHistory.count == 1, "rename plus parallel screen/camera/audio edits commit one transaction")
        try require(editor.undo() && editor.project.state == original.state && editor.project.title == original.title, "one Undo restores title and every state component")
        try require(editor.redo() && editor.project.state == changed.state && editor.project.title == changed.title, "one Redo restores mixed transaction")
        try require(try ProjectEditor.open(url: url).project == editor.project, "transaction survives metadata save/reopen without media")
        let before = editor.project, beforeBytes = try Data(contentsOf: url)
        let invalid = EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: before),
            commands: [.mutate(.pointer(.init(size: 3))), .mutate(.audio(.init(volume: 9)))], title: "Should not save")
        try rejects({ _ = try EditorCommandDispatcher.apply(invalid, to: editor, projectID: id) }, "late invalid command rejects whole batch")
        try require(editor.project == before && (try Data(contentsOf: url)) == beforeBytes, "invalid batch preserves title history and bytes")
        var external = before; external.title = "External"
        let externalBytes = try JSONEncoder().encode(external); try externalBytes.write(to: url)
        let valid = EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: before), commands: [.mutate(.pointer(.init(size: 3)))], title: "Conflict")
        try rejects({ _ = try EditorCommandDispatcher.apply(valid, to: editor, projectID: id) }, "external save conflict rejects mixed transaction")
        try require(editor.project == before && (try Data(contentsOf: url)) == externalBytes, "failed save leaves external bytes and editor history intact")
        var foreign = valid; foreign.projectID = UUID()
        try rejects({ _ = try EditorCommandDispatcher.prepare(foreign, for: before, projectID: id) }, "scope remains guarded")
    }
}
