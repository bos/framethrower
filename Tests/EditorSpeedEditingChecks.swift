import AppKit
import Foundation

@main @MainActor
struct EditorSpeedEditingChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
    static func rejects(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure.failed("Expected an atomic speed-edit rejection")
    }
    static func near(_ a: Double, _ b: Double, _ message: String) throws {
        try require(abs(a - b) < 0.000001, "\(message): \(a) != \(b)")
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Media interlock remains enabled")
        _ = NSApplication.shared
        try codingAndMigration()
        try independentSourceEdits()
        try preEditOutputMappingAndUndo()
        try timelineGesturesAndProfiles()
        try await actualDirectorAPI()
        print("Speed editing checks passed (legacy state, strict source/output commands, independent lane, pre-edit mapping, saved Undo/Redo, source gestures/Escape, held-rate profile, nonlinear projection, actual Director API, no media).")
    }
    static func project() -> RecordingProject {
        var project = RecordingProject(screenFilename: "unopened-speed.mov", cameraFilename: "unopened-camera.mov", duration: 14)
        project.state.zoomKeyframes = [.init(time: 4, scale: 2)]
        project.state.pipKeyframes.append(.init(time: 4, placement: .init(x: 0.2, y: 0.3)))
        project.state.regions = [.init(time: 4, rect: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.4))]
        return project
    }
    static func codingAndMigration() throws {
        let base = project()
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base.state)) as! [String: Any]
        legacy.removeValue(forKey: "speedKeyframes"); legacy.removeValue(forKey: "preservesAudioPitch")
        let migrated = try JSONDecoder().decode(EditState.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(migrated.speedKeyframes.isEmpty && migrated.preservesAudioPitch && migrated.speed(at: 9) == 1,
                    "Legacy recordings retain1× timing and preserved pitch without synthetic speed edits")
        let samples: [EditorMutation] = [.speed(rate: 2, timing: .init(start: 2, end: 4), preservesPitch: false),
            .speed(rate: 0.5, timing: .at(3), timeBase: .output), .removeAnimation(animationID: "speed:\(UUID().uuidString)")]
        for mutation in samples {
            try require(try JSONDecoder().decode(EditorMutation.self, from: JSONEncoder().encode(mutation)) == mutation,
                        "Typed speed mutations preserve clocks, rate and pitch policy")
        }
        for json in [#"{"operation":"speed","rate":2}"#,
            #"{"operation":"speed","rate":2,"timing":{"start":2,"end":4},"timeBase":"preview"}"#,
            #"{"operation":"speed","rate":2,"timing":{"start":2,"end":4},"preservesPitch":null}"#,
            #"{"operation":"speed","rate":2,"timing":{"start":2,"end":4},"previewRate":5}"#] {
            try rejects { _ = try JSONDecoder().decode(EditorMutation.self, from: Data(json.utf8)) }
        }
        let description = try EditorMutation.describe(operation: "speed")
        let command = description["command_schema"] as! [String: Any]
        let mutation = (command["properties"] as! [String: Any])["mutation"] as! [String: Any]
        try require(mutation["additionalProperties"] as? Bool == false && (mutation["required"] as! [String]).contains("timing"),
                    "Director discovers a closed saved-speed schema requiring an exact timing interval")
    }
    static func independentSourceEdits() throws {
        let base = project(); var state = base.state
        try EditorMutation.speed(rate: 2, timing: .init(start: 2, end: 4, easeIn: 0.3, easeOut: 0.5)).apply(to: &state, project: base)
        try require(state.speedKeyframes.count == 2 && state.speedKeyframes[0].time == 2 && state.speedKeyframes[0].rate == 1 &&
                    state.speedKeyframes[1].time == 4 && state.speedKeyframes[1].rate == 2,
                    "A smooth saved speed change has one baseline and one target, not a stack of gesture samples")
        try near(state.speed(at: 4), 2, "Target rate at arrival")
        try near(state.speed(at: 14), 2, "Rate continues through recording end")
        var unchanged = state; unchanged.speedKeyframes = []
        try require(unchanged == base.state, "Speed edits leave screen/camera/boxes/audio/content source anchors intact")
        let stable = state
        try rejects { try EditorMutation.speed(rate: 3, timing: .init(start: 3, end: 5)).apply(to: &state, project: base) }
        try require(state == stable, "Overlapping speed ramps reject atomically without involving screen/camera lanes")
        try EditorMutation.removeAnimation(animationID: "speed:\(state.speedKeyframes[1].id.uuidString)").apply(to: &state, project: base)
        try require(state.zoomKeyframes == base.state.zoomKeyframes && state.pipKeyframes == base.state.pipKeyframes && state.regions == base.state.regions,
                    "Deleting the speed component preserves coincident independent edit components")
        var pitch = base.state
        try EditorMutation.speed(rate: 1, timing: .at(4), preservesPitch: false).apply(to: &pitch, project: base)
        try require(!pitch.preservesAudioPitch && pitch.speedKeyframes.isEmpty, "A pitch-only policy change does not invent a speed mark")
        var whole = base.state
        try EditorMutation.speed(rate: 2, timing: .init(start: 0, end: 14)).apply(to: &whole, project: base)
        try require(whole.speedKeyframes.last?.time == 14 && whole.speed(at: 14) == 2,
                    "An exported speed ramp can arrive exactly at the recording end")
        for value in [0.0, 8.1, Double.nan, Double.infinity] {
            var candidate = base.state
            try rejects { try EditorMutation.speed(rate: value, timing: .at(4)).apply(to: &candidate, project: base) }
            try require(candidate == base.state, "Invalid saved speed never partially changes state")
        }
    }
    static func preEditOutputMappingAndUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = project(); original.state.speedKeyframes = [.init(time: 0, rate: 2, transition: .jump)]
        let url = directory.appendingPathComponent("speed.framethrower")
        try JSONEncoder().encode(original).write(to: url)
        let editor = try ProjectEditor.open(url: url), id = UUID()
        let batch = EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: editor.project), commands: [
            .mutate(.speed(rate: 4, timing: .init(start: 1, end: 2), timeBase: .output)),
            .mutate(.speed(rate: 1, timing: .at(3), timeBase: .output))])
        _ = try EditorCommandDispatcher.apply(batch, to: editor, projectID: id, name: "Change export speed")
        let changed = editor.project
        try require(changed.state.speedKeyframes.map(\.time) == [0, 2, 4, 6],
                    "Every output reference resolves through the original batch map, not a map modified by an earlier speed command")
        try require(changed.undoHistory.count == 1 && changed.state.zoomKeyframes == original.state.zoomKeyframes,
                    "Saved range edits are one ordinary Undo operation and preserve source framing anchors")
        try require(editor.undo() && editor.project.state == original.state, "One Undo restores the speed map")
        try require(editor.redo() && editor.project.state == changed.state, "One Redo restores stable speed identities")
        try require(try ProjectEditor.open(url: url).project == editor.project, "Speed/pitch metadata survive save and reopen")
        var cuts = original; cuts.state.speedKeyframes = []; cuts.state.cuts = [.init(start: 5, end: 8, crossfade: 1)]
        var state = cuts.state
        try rejects { try EditorMutation.speed(rate: 2, timing: .at(4.5), timeBase: .output).apply(to: &state, project: cuts) }
        try require(state == cuts.state, "A blended output timestamp never guesses which source speed should change")
    }
    static func timelineGesturesAndProfiles() throws {
        var base = project()
        base.state.speedKeyframes = [.init(time: 4, rate: 2, duration: 2)]
        var refs = EditorReferences(); refs.register(state: base.state)
        let spans = EditorAnimationEditing.animations(in: base.state, references: refs, duration: base.duration)
        let target = spans.first { $0.lane == .speed }!
        try require(target.start == 2 && target.end == 4 && target.label.contains("2×") && target.help.contains("14.000"),
                    "Speed uses ordinary arrival/ramp handles while its target label explains the held rate")
        let changes = TimelineAnimationSolver.solve(.init(id: target.id, handle: .move, deltaSeconds: 1, snapTolerance: 0), animations: spans, duration: 14)!
        let applied = EditorAnimationEditing.applying(changes, to: base.state, duration: 14)!
        try require(applied.state.speedKeyframes[0].time == 5 && applied.state.speedKeyframes[0].duration == 2 &&
                    applied.state.zoomKeyframes == base.state.zoomKeyframes && applied.state.pipKeyframes == base.state.pipKeyframes,
                    "The same direct timing solver moves only the speed lane and preserves ramp duration")
        let profile = TimelineSpeedProfile.curves(points: [.init(time: 4, rate: 2, transition: .jump)], duration: 14, map: nil)[0]
        try require(profile.filter { $0.time >= 4 }.allSatisfy { $0.rate == 2 } && profile.last?.time == 14,
                    "The speed graph is an actual held2× plateau, not a velocity envelope dropping to zero at arrival")
        let map = try RecordingTimeMap(duration: 14, trimStart: 0, trimEnd: 14, cuts: [], speedKeyframes: base.state.speedKeyframes)
        let projection = TimelineOutputProjection(animations: spans, map: map)
        let fragment = projection.animations.first { $0.lane == .speed }!
        let envelope = projection.envelopes[fragment.id]!
        let midpoint = map.clips[0].outputTime(for: 3)
        try near(envelope.sourceTime(at: midpoint), 3, "Finished curves use a nonlinear per-clip inverse clock")
        try near(fragment.end, map.clips[0].outputTime(for: 4), "Projected target arrival matches the retimed output map")
        var shared = base.state
        shared.speedKeyframes[0].id = shared.zoomKeyframes[0].id
        let sharedID = shared.zoomKeyframes[0].id
        shared.editAnchors = [.init(id: sharedID, time: 4)]
        var sharedRefs = EditorReferences(); sharedRefs.register(state: shared)
        let sharedSpans = EditorAnimationEditing.animations(in: shared, references: sharedRefs, duration: 14)
        let speed = sharedSpans.first { $0.lane == .speed }!
        let changed = TimelineAnimationSolver.solve(.init(id: speed.id, handle: .move, deltaSeconds: 1, snapTolerance: 0), animations: sharedSpans, duration: 14)!
        let split = EditorAnimationEditing.applying(changed, to: shared, duration: 14,
            replacementIDs: EditorAnimationEditing.replacementIDs(for: sharedSpans))!
        let alias = split.aliases.first { $0.lane == .speed }!
        sharedRefs.edits[alias.replacementID.uuidString] = sharedRefs.edits[alias.originalID.uuidString]
        sharedRefs.register(state: split.state)
        let letter = String(sharedRefs.editLabel(for: sharedID)!.dropFirst(5))
        try require(split.state.zoomKeyframes[0].time == 4 && split.state.editAnchors[0].time == 4 &&
                    EditorActionDescription.resolve("Speed " + letter, in: split.state, references: sharedRefs)?.speedID == alias.replacementID &&
                    EditorActionDescription.resolve("Zoom " + letter, in: split.state, references: sharedRefs)?.zoomID == sharedID,
                    "Retiming a shared-ID speed component preserves stationary source marks and independently qualified stable identities")
        let view = RecordingTimelineView(frame: .init(x: 0, y: 0, width: 900, height: RecordingTimeline.animationLaneHeight))
        view.duration = 14; view.trimEnd = 14; view.showsAnimationLanes = true; view.animationSpans = spans
        view.speedCurves = [profile]
        try require(view.animationLanes().map(\.lane) == [.screen, .camera, .speed, .pointer] && view.intrinsicContentSize.height == 180,
                    "Speed has a persistent fixed-height lane independent of inspector or selection")
        view.selectedAnimationID = target.id
        let geometry = view.animationGeometry().first { $0.animation.id == target.id }!
        try require(geometry.startHandle != nil && geometry.endHandle != nil && geometry.easeInHandle != nil && geometry.easeOutHandle != nil,
                    "Selected speed ramps expose the same direct timing and ramp controls as other animated lanes")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gesture.framethrower")
        try JSONEncoder().encode(base).write(to: url)
        let editor = try ProjectEditor.open(url: url)
        let original = editor.project
        var selected = 0
        view.onSelectAnimation = { _ in selected += 1 }
        view.onAnimationEdit = { drag, final in
            guard let changes = TimelineAnimationSolver.solve(drag, animations: spans, duration: 14),
                  let edit = EditorAnimationEditing.applying(changes, to: original.state, duration: 14) else { return }
            _ = editor.updateDraft(edit.state, at: target.end)
            if final { _ = editor.finishDraft(name: "Move speed animation") }
        }
        view.onAnimationCancel = { _ = editor.cancelDraft() }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let start = CGPoint(x: geometry.body.midX, y: geometry.body.midY)
        let end = CGPoint(x: start.x + 42, y: start.y)
        view.mouseDown(with: event(.leftMouseDown, start)); view.mouseDragged(with: event(.leftMouseDragged, end))
        try require(editor.draftState != nil && editor.project == original && selected == 0,
                    "Dragging a speed span previews one draft without warping selection or saving intermediate samples")
        view.cancelOperation(nil); view.mouseUp(with: event(.leftMouseUp, end))
        try require(editor.project == original && editor.draftState == nil && selected == 0,
                    "Escape restores the original speed state and a late mouse-up cannot commit it")
        view.mouseDown(with: event(.leftMouseDown, start)); view.mouseDragged(with: event(.leftMouseDragged, end)); view.mouseUp(with: event(.leftMouseUp, end))
        let dragged = editor.project
        try require(dragged.undoHistory.count == 1 && dragged.state.speedKeyframes[0].time > 4,
                    "Releasing the speed gesture creates one saved ordinary Undo entry")
        try require(editor.undo() && editor.project.state == original.state && editor.redo() && editor.project.state == dragged.state,
                    "One Undo/Redo restores the complete speed gesture without affecting other lanes")
    }
    static func actualDirectorAPI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("api-speed.framethrower")
        try JSONEncoder().encode(project()).write(to: url)
        let editor = try ProjectEditor.open(url: url), playback = EditorPlayback()
        await playback.rebuild(editor: editor)
        defer { playback.close() }
        let endpoint = EditorAutomationHost(editor: editor, playback: playback)
        let initial = try endpoint.automationContext
        let mutation = EditorCommand.mutate(.speed(rate: 2, timing: .init(start: 2, end: 4)))
        let command = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation))
        _ = try await endpoint.performAutomation("apply_edits", arguments: JSONSerialization.data(withJSONObject: [
            "document_id": initial.documentID, "expected_revision": initial.revision, "commands": [command], "name": "Change saved speed"]))
        let saved = editor.project
        try require(saved.undoHistory.count == 1 && saved.state.speed(at: 10) == 2,
                    "Native Director applies the same speed mutation through the real saved transaction")
        let info = try await endpoint.performAutomation("inspect_editor", arguments: JSONSerialization.data(withJSONObject: [
            "document_id": initial.documentID, "section": "state", "component": "speed", "time": 10]))
        let body = try JSONSerialization.jsonObject(with: info) as! [String: Any]
        let result = body["result"] as! [String: Any], value = result["value"] as! [String: Any]
        try near(value["rate"] as! Double, 2, "Director inspects the actual saved source rate")
        let review = try await endpoint.performAutomation("control_preview", arguments: JSONSerialization.data(withJSONObject: [
            "document_id": initial.documentID, "operation": "set_rate", "rate": 5]))
        try require(String(decoding: review, as: UTF8.self).contains("5") && editor.project == saved && editor.project.undoHistory.count == 1,
                    "Review5× is transient and remains distinct from the saved2× export rate")
        _ = try await endpoint.performAutomation("control_document", arguments: JSONSerialization.data(withJSONObject: [
            "document_id": initial.documentID, "operation": "undo", "expected_revision": try endpoint.automationContext.revision]))
        try require(editor.project.state.speedKeyframes.isEmpty, "Director Undo uses the same ordinary speed history")
    }
}
