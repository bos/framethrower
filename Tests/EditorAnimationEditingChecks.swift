import Foundation

private enum AnimationCheckFailure: Error { case failed(String) }

/// Production interval solver, metadata projection and ordinary draft history.
/// Every source name is nonexistent; no app, player, image or media is created.
@main @MainActor
struct EditorAnimationEditingChecks {
    static func main() throws {
        try stopSnapAndRipple()
        try endpointsAndRamps()
        try projectionAndAtomicDraft()
        try sharedComponentIdentity()
        try durableSplitReferences()
        try coincidentIndependentLabels()
        try coincidentReference()
        try clippedFollowersStayPut()
        try reorderedMetadata()
        print("Animation editing checks passed (lane-independent stop/snap/reorder/ripple, recording bounds, duration/ramp preservation, shared identities, clipped followers, atomic durable Undo/Redo/Escape and failed-save draft retention; no media).")
    }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AnimationCheckFailure.failed(message) }
    }
    static func near(_ value: Double, _ expected: Double, _ message: String) throws {
        try require(abs(value - expected) < 0.00001, "\(message): expected \(expected), got \(value)")
    }
    static func span(_ lane: TimelineAnimationLane, _ start: Double, _ end: Double,
                     easeIn: Double = 0.2, easeOut: Double = 0.3, editable: Bool = true) -> TimelineAnimation {
        let id = UUID()
        return TimelineAnimation(id: TimelineAnimationID(lane: lane, componentID: id), editID: id, start: start, end: end,
            easeIn: end == start ? 0 : easeIn, easeOut: end == start ? 0 : easeOut,
            label: lane.rawValue, help: lane.rawValue, editable: editable)
    }
    static func solved(_ drag: AnimationDrag, _ base: [TimelineAnimation], duration: Double = 10) throws -> [TimelineAnimation] {
        guard let changes = TimelineAnimationSolver.solve(drag, animations: base, duration: duration) else {
            throw AnimationCheckFailure.failed("Valid gesture rejected: \(drag)")
        }
        return base.map { original in changes.first { $0.id == original.id } ?? original }
    }
    static func at(_ id: TimelineAnimationID, in values: [TimelineAnimation]) -> TimelineAnimation { values.first { $0.id == id }! }
    static func valid(_ values: [TimelineAnimation], duration: Double) throws {
        for item in values {
            try require(item.start >= -0.000001 && item.end <= duration + 0.000001 && item.start <= item.end &&
                        item.easeIn >= 0 && item.easeOut >= 0 && item.easeIn + item.easeOut <= item.duration + 0.000001,
                        "Every resulting animation and its acceleration ramps must fit inside its source interval")
        }
        for lane in TimelineAnimationLane.allCases {
            let items = values.filter { $0.lane == lane }.sorted { $0.start < $1.start }
            for index in 1..<max(1, items.count) {
                try require(items[index - 1].end <= items[index].start + 0.000001,
                            "A solved gesture cannot create same-lane overlaps")
            }
        }
    }
    static func stopSnapAndRipple() throws {
        let a = span(.screen, 1, 3), b = span(.screen, 4, 5), c = span(.screen, 6, 8)
        let camera = span(.camera, 2, 7), pointer = span(.pointer, 0, 10, editable: false)
        let base = [c, camera, a, pointer, b]
        let stopped = try solved(AnimationDrag(id: a.id, handle: .move, deltaSeconds: 5), base)
        try near(at(a.id, in: stopped).end, 4, "Default movement stops at the next animation instead of crossing it")
        try require(at(b.id, in: stopped) == b && at(c.id, in: stopped) == c && at(camera.id, in: stopped) == camera && at(pointer.id, in: stopped) == pointer,
                    "Stopping in one lane cannot retime neighbors or independent camera/pointer targets")
        let snapped = try solved(AnimationDrag(id: a.id, handle: .move, deltaSeconds: 0.98), base)
        try near(at(a.id, in: snapped).end, 4, "Movement approaching the next edge snaps forward within its small tolerance")
        let unsnapped = try solved(AnimationDrag(id: a.id, handle: .move, deltaSeconds: 0.8), base)
        try near(at(a.id, in: unsnapped).end, 3.8, "Ordinary movement outside snap tolerance keeps the requested time")
        let right = try solved(AnimationDrag(id: a.id, handle: .move, deltaSeconds: 5, push: true), base)
        try near(at(a.id, in: right).start, 5, "Ripple movement clamps the entire cascade against the recording end")
        try near(at(b.id, in: right).start, 7, "Ripple pushes the next animation without consuming its duration")
        try near(at(c.id, in: right).end, 10, "Ripple stops at the exact source end")
        let left = try solved(AnimationDrag(id: c.id, handle: .move, deltaSeconds: -5, push: true), base)
        try near(at(a.id, in: left).start, 0, "A reverse cascade stops against the source beginning")
        try near(at(c.id, in: left).start, 3, "Reverse ripple clamps the requested movement rather than allowing negative neighbors")
        for result in [stopped, snapped, unsnapped, right, left] {
            try valid(result, duration: 10)
            for original in [a, b, c] {
                let moved = at(original.id, in: result)
                try near(moved.duration, original.duration, "Moving a whole animation preserves its duration")
                try require(moved.easeIn == original.easeIn && moved.easeOut == original.easeOut,
                            "Moving/pushing an animation preserves its absolute acceleration/deceleration ramps")
            }
            try require(at(camera.id, in: result) == camera && at(pointer.id, in: result) == pointer,
                        "Option ripple is confined to the gesture's lane")
        }
        let locked = span(.screen, 9, 10, editable: false)
        let lockBase = base + [locked]
        let blocked = try solved(AnimationDrag(id: a.id, handle: .move, deltaSeconds: 9, push: true), lockBase)
        try near(at(c.id, in: blocked).end, 9, "A locked animation stops a ripple chain")
        try require(at(locked.id, in: blocked) == locked, "A locked animation can never be pushed")
        try valid(blocked, duration: 10)
        try require(TimelineAnimationSolver.solve(AnimationDrag(id: pointer.id, handle: .move, deltaSeconds: 1), animations: base, duration: 10) == nil,
                    "The read-only whole-recording Pointer lane cannot invent timed style edits")
        try require(TimelineAnimationSolver.solve(AnimationDrag(id: a.id, handle: .move, deltaSeconds: .nan), animations: base, duration: 10) == nil,
                    "Invalid gesture coordinates cannot corrupt a project")
        let fractional = span(.screen, 0, 0.3, easeIn: 0.1, easeOut: 0.2)
        try require(TimelineAnimationSolver.solve(AnimationDrag(id: fractional.id, handle: .move, deltaSeconds: 0), animations: [fractional], duration: 10) == [],
                    "A zero-displacement gesture must not create a spurious edit from floating-point ramp normalization")
    }
    static func endpointsAndRamps() throws {
        let a = span(.screen, 1, 3, easeIn: 0.4, easeOut: 0.6), b = span(.screen, 5, 7)
        let extended = try solved(AnimationDrag(id: a.id, handle: .end, deltaSeconds: 8), [a, b])
        try near(at(a.id, in: extended).end, 5, "Dragging an endpoint stops flush against the next animation")
        try require(at(a.id, in: extended).easeIn == 0.4 && at(a.id, in: extended).easeOut == 0.6,
                    "Extending a duration preserves absolute ramps")
        let shortened = try solved(AnimationDrag(id: a.id, handle: .start, deltaSeconds: 1.5), [a, b])
        try near(at(a.id, in: shortened).duration, 0.5, "The starting endpoint changes duration while preserving the target time")
        try near(at(a.id, in: shortened).easeIn, 0.2, "Short duration scales both ramps proportionally when they no longer fit")
        try near(at(a.id, in: shortened).easeOut, 0.3, "Proportional ramp reduction preserves the acceleration/deceleration ratio")
        let accelerate = try solved(AnimationDrag(id: a.id, handle: .easeIn, deltaSeconds: 9), [a, b])
        try near(at(a.id, in: accelerate).easeIn, 1.4, "Acceleration handle stops at the opposing deceleration ramp")
        let decelerate = try solved(AnimationDrag(id: a.id, handle: .easeOut, deltaSeconds: 0.2), [a, b])
        try near(at(a.id, in: decelerate).easeOut, 0.4, "Moving the deceleration handle right shortens that ramp")
        for result in [extended, shortened, accelerate, decelerate] { try valid(result, duration: 10) }
        let jump = span(.screen, 4, 4)
        let smooth = try solved(AnimationDrag(id: jump.id, handle: .start, deltaSeconds: -1), [jump])
        try near(at(jump.id, in: smooth).start, 3, "An explicitly selected Jump can become a smooth one-second transition by dragging its start")
        try near(at(jump.id, in: smooth).end, 4, "Converting a Jump retains its target endpoint")
    }
    static func projectionAndAtomicDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-animation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let zoomID = UUID(), cameraID = UUID()
        var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 10)
        project.state.zoomKeyframes = [ZoomKeyframe(id: zoomID, time: 3, scale: 2, x: 0.6, y: 0.55,
            transition: .smooth, duration: 2, easeIn: 0.4, easeOut: 0.6)]
        project.state.pipKeyframes.append(PIPKeyframe(id: cameraID, time: 6,
            placement: PIPPlacement(x: 0.2, y: 0.3, scale: 0.35), transition: .smooth, duration: 1, easeIn: 0.2, easeOut: 0.3))
        project.ensureReferences()
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "Save a JSON-only baseline")
        let original = editor.project
        let animations = EditorAnimationEditing.animations(in: original.state, references: editor.references, duration: 10)
        let screenID = TimelineAnimationID(lane: .screen, componentID: zoomID)
        let screen = animations.first { $0.id == screenID }!
        try near(screen.start, 1, "Projection reports the actual effective beginning, not just the arrival timestamp")
        try require(animations.contains { $0.lane == .pointer && !$0.editable } &&
                    animations.filter { $0.lane == .camera && $0.end == 0 }.allSatisfy { !$0.editable },
                    "Whole-recording pointer style and the initial camera placement remain read-only spans")
        for delta in [0.2, 0.5] {
            let changes = TimelineAnimationSolver.solve(AnimationDrag(id: screenID, handle: .move, deltaSeconds: delta), animations: animations, duration: 10)!
            guard let edit = EditorAnimationEditing.applying(changes, to: original.state, duration: 10) else {
                throw AnimationCheckFailure.failed("Valid animation projection could not be applied")
            }
            let candidate = edit.state
            try require(candidate.pipKeyframes == original.state.pipKeyframes && candidate.cursorStyle == original.state.cursorStyle &&
                        candidate.zoomKeyframes[0].placement == original.state.zoomKeyframes[0].placement &&
                        candidate.zoomKeyframes[0].duration == 2 && candidate.zoomKeyframes[0].easeIn == 0.4 && candidate.zoomKeyframes[0].easeOut == 0.6,
                        "Timing a Screen span preserves its target, ramps and every independent track")
            try require(editor.updateDraft(candidate, at: screen.end), "Preview every sample at the same gesture origin")
        }
        try require(editor.project == original && editor.draftState?.zoomKeyframes[0].time == 3.5,
                    "Continuous samples revise one draft instead of accumulating edits or relative deltas")
        let finished = editor.draftState!
        try require(editor.finishDraft(name: "Move Screen animation") && editor.project.undoHistory.count == 1 &&
                    editor.project.state == finished, "A gesture commits one ordinary Undo stack entry")
        try require(editor.undo() && editor.project.state == original.state && editor.redo() && editor.project.state == finished,
                    "One Undo/Redo restores the whole animation gesture atomically")
        let beforeEscape = editor.project
        var canceled = beforeEscape.state; canceled.zoomKeyframes[0].time += 0.5
        try require(editor.updateDraft(canceled, at: 3.5) && editor.cancelDraft() && editor.project == beforeEscape && editor.draftState == nil,
                    "Escape restores the exact saved state and both history branches")
        try require(editor.updateDraft(canceled, at: 3.5), "Create a draft for failed-save retention")
        let saved = try Data(contentsOf: editor.url)
        try FileManager.default.removeItem(at: editor.url)
        try FileManager.default.createDirectory(at: editor.url, withIntermediateDirectories: false)
        try require(!editor.finishDraft(name: "Move Screen animation") && editor.project == beforeEscape && editor.draftState == canceled,
                    "A failed save cannot drop the draft or consume an Undo entry")
        try FileManager.default.removeItem(at: editor.url)
        try saved.write(to: editor.url)
        try require(editor.finishDraft(name: "Move Screen animation") && editor.project.undoHistory.count == beforeEscape.undoHistory.count + 1,
                    "Retrying a failed gesture commits it exactly once")
        var jumped = original.state
        jumped.zoomKeyframes[0].transition = .jump
        let jumpSpan = EditorAnimationEditing.animations(in: jumped, references: editor.references, duration: 10).first { $0.id == screenID }!
        let movedJumpChanges = TimelineAnimationSolver.solve(AnimationDrag(id: screenID, handle: .move, deltaSeconds: 1), animations: [jumpSpan], duration: 10)!
        let movedJump = EditorAnimationEditing.applying(movedJumpChanges, to: jumped, duration: 10)!.state
        var movedJumpProject = original; movedJumpProject.state = movedJump
        try movedJumpProject.validate()
        try require(movedJump.zoomKeyframes[0].transition == .jump && movedJump.zoomKeyframes[0].duration == jumped.zoomKeyframes[0].duration &&
                    movedJump.zoomKeyframes[0].time == 4,
                    "Moving an instantaneous Jump preserves its positive stored duration and remains a valid saved project")
        let smoothChanges = TimelineAnimationSolver.solve(AnimationDrag(id: screenID, handle: .start, deltaSeconds: -1), animations: [jumpSpan], duration: 10)!
        let smoothed = EditorAnimationEditing.applying(smoothChanges, to: jumped, duration: 10)!.state
        try require(smoothed.zoomKeyframes[0].transition == .smooth && smoothed.zoomKeyframes[0].time == 3 &&
                    smoothed.zoomKeyframes[0].duration == 1 && smoothed.zoomKeyframes[0].placement == jumped.zoomKeyframes[0].placement,
                    "Dragging a selected Jump's endpoint creates a smooth animation while retaining its target")
    }
    static func sharedComponentIdentity() throws {
        let shared = UUID(), replacement = UUID()
        var project = RecordingProject(screenFilename: "missing.mov", cameraFilename: "missing-camera.mov", duration: 10)
        project.state.zoomKeyframes = [ZoomKeyframe(id: shared, time: 3, scale: 2, transition: .smooth, duration: 2)]
        project.state.pipKeyframes.append(PIPKeyframe(id: shared, time: 3,
            placement: PIPPlacement(x: 0.2, y: 0.3), transition: .smooth, duration: 1))
        project.state.editAnchors = [EditAnchor(id: shared, time: 3)]
        project.state.regions = [EditorRegion(time: 3, rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), editID: shared)]
        project.ensureReferences()
        let values = EditorAnimationEditing.animations(in: project.state, references: project.references, duration: 10)
        let screenID = TimelineAnimationID(lane: .screen, componentID: shared)
        let cameraID = TimelineAnimationID(lane: .camera, componentID: shared)
        try require(values.contains { $0.id == screenID } && values.contains { $0.id == cameraID } &&
                    Set(values.map(\.id)).count == values.count,
                    "Normal shared-UUID Screen/Camera marks require distinct lane-scoped animation identities")
        let changes = TimelineAnimationSolver.solve(AnimationDrag(id: screenID, handle: .move, deltaSeconds: 1), animations: values, duration: 10)!
        try require(EditorAnimationEditing.applying(changes, to: project.state, duration: 10) == nil,
                    "A retime cannot silently reuse an identity still owned by a stationary anchor or camera")
        let edit = EditorAnimationEditing.applying(changes, to: project.state, duration: 10, replacementIDs: [screenID: replacement])!
        try require(edit.state.zoomKeyframes[0].id == replacement && edit.state.zoomKeyframes[0].time == 4 &&
                    edit.state.pipKeyframes == project.state.pipKeyframes && edit.state.editAnchors == project.state.editAnchors &&
                    edit.state.regions == project.state.regions,
                    "Splitting a shared Screen component preserves the camera, source-time boxes and their original anchor")
        try require(edit.aliases.contains { $0.originalID == shared && $0.replacementID == replacement && $0.lane == .screen },
                    "The helper reports the identity split so reference allocation can remain coherent")
        var references = project.references
        references.edits[replacement.uuidString] = references.edits[shared.uuidString]
        let letter = String(references.editLabel(for: shared)!.dropFirst("Edit ".count))
        try require(EditorActionDescription.resolve("Zoom " + letter, in: edit.state, references: references)?.zoomID == replacement &&
                    EditorActionDescription.resolve("Camera " + letter, in: edit.state, references: references)?.cameraID == shared &&
                    EditorActionDescription.resolve("Edit " + letter, in: edit.state, references: references) == nil,
                    "Lane-qualified references identify split animations independently; their unqualified old group remains ambiguous")
        let second = TimelineAnimationSolver.solve(AnimationDrag(id: screenID, handle: .move, deltaSeconds: 0.5), animations: values, duration: 10)!
        let refined = EditorAnimationEditing.applying(second, to: project.state, duration: 10, replacementIDs: [screenID: replacement])!
        try require(refined.state.zoomKeyframes[0].id == replacement && refined.state.zoomKeyframes[0].time == 3.5,
                    "Every gesture preview reuses its one replacement identity rather than allocating per finger movement")
    }
    static func clippedFollowersStayPut() throws {
        for lane in [TimelineAnimationLane.screen, .camera] {
            var project = RecordingProject(screenFilename: "missing.mov", cameraFilename: "missing-camera.mov", duration: 10)
            let movedID = UUID(), followerID = UUID()
            if lane == .screen {
                project.state.zoomKeyframes = [
                    ZoomKeyframe(id: movedID, time: 3, scale: 2, transition: .smooth, duration: 2),
                    ZoomKeyframe(id: followerID, time: 5, scale: 3, transition: .smooth, duration: 10, easeIn: 4, easeOut: 6)]
            } else {
                project.state.pipKeyframes += [
                    PIPKeyframe(id: movedID, time: 3, placement: PIPPlacement(x: 0.4, y: 0.5, scale: 0.3), transition: .smooth, duration: 2),
                    PIPKeyframe(id: followerID, time: 5, placement: PIPPlacement(x: 0.2, y: 0.3, scale: 0.4), transition: .smooth, duration: 10, easeIn: 4, easeOut: 6)]
            }
            project.ensureReferences()
            let base = EditorAnimationEditing.animations(in: project.state, references: project.references, duration: 10)
            let target = TimelineAnimationID(lane: lane, componentID: movedID)
            let following = TimelineAnimationID(lane: lane, componentID: followerID)
            let changes = TimelineAnimationSolver.solve(AnimationDrag(id: target, handle: .move, deltaSeconds: -1), animations: base, duration: 10)!
            let result = EditorAnimationEditing.applying(changes, to: project.state, duration: 10)!.state
            let after = EditorAnimationEditing.animations(in: result, references: project.references, duration: 10)
            try require(at(following, in: after) == at(following, in: base),
                        "Moving an earlier target cannot silently expand an untouched follower's previously clipped interval or ramps")
            for time in [3.1, 4.0, 4.9] {
                if lane == .screen {
                    try require(result.zoom(at: time) == project.state.zoom(at: time),
                                "The actual screen interpolation must retain the untouched follower's timing curve")
                } else {
                    try require(result.placement(at: time) == project.state.placement(at: time),
                                "The actual camera interpolation must retain the untouched follower's timing curve")
                }
            }
        }
    }
    static func durableSplitReferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-animation-alias-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = UUID(), replacement = UUID()
        var project = RecordingProject(screenFilename: "missing.mov", cameraFilename: "missing-camera.mov", duration: 10)
        project.state.zoomKeyframes = [ZoomKeyframe(id: shared, time: 3, scale: 2, transition: .smooth, duration: 2)]
        project.state.pipKeyframes.append(PIPKeyframe(id: shared, time: 3,
            placement: PIPPlacement(x: 0.2, y: 0.3), transition: .smooth, duration: 1))
        project.state.editAnchors = [EditAnchor(id: shared, time: 3)]
        project.state.regions = [EditorRegion(time: 3, rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), editID: shared)]
        project.ensureReferences()
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "Save the combined JSON baseline")
        let label = editor.references.editLabel(for: shared)
        let saved = try Data(contentsOf: editor.url)
        let base = EditorAnimationEditing.animations(in: editor.project.state, references: editor.references, duration: 10)
        let id = TimelineAnimationID(lane: .screen, componentID: shared)
        let changes = TimelineAnimationSolver.solve(AnimationDrag(id: id, handle: .move, deltaSeconds: 1), animations: base, duration: 10)!
        let result = EditorAnimationEditing.applying(changes, to: editor.project.state, duration: 10, replacementIDs: [id: replacement])!
        let aliases = Dictionary(uniqueKeysWithValues: result.aliases.map { ($0.replacementID, $0.originalID) })
        try require(editor.updateDraft(result.state, at: 3, editAliases: aliases) &&
                    editor.references.editLabel(for: replacement) == label && editor.draftState == result.state,
                    "A split gesture publishes its inherited stable label with the preview state")
        try FileManager.default.removeItem(at: editor.url)
        try FileManager.default.createDirectory(at: editor.url, withIntermediateDirectories: false)
        try require(!editor.finishDraft(name: "Move Screen animation") && editor.references.editLabel(for: replacement) == label &&
                    editor.draftState == result.state && editor.project.undoHistory.isEmpty,
                    "A failed gesture save retains both its draft and already visible reference allocation")
        try FileManager.default.removeItem(at: editor.url)
        try saved.write(to: editor.url)
        try require(editor.finishDraft(name: "Move Screen animation"), "Retry the same split gesture")
        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.references.editLabel(for: replacement) == label && reopened.project.state == result.state &&
                    reopened.project.state.regions[0].editID == shared,
                    "Reopening preserves split references while boxes retain their original source-time association")
        try require(reopened.undo() && reopened.project.state == project.state && reopened.references.editLabel(for: replacement) == label &&
                    reopened.redo() && reopened.project.state == result.state && reopened.references.editLabel(for: replacement) == label,
                    "Shared-stack Undo/Redo restores the split gesture without recycling or renumbering its reference")
    }
    static func coincidentIndependentLabels() throws {
        let screenID = UUID(), cameraID = UUID()
        var project = RecordingProject(screenFilename: "missing.mov", cameraFilename: "missing-camera.mov", duration: 10)
        project.state.zoomKeyframes = [ZoomKeyframe(id: screenID, time: 5, scale: 2, transition: .smooth, duration: 1)]
        project.state.pipKeyframes.append(PIPKeyframe(id: cameraID, time: 2,
            placement: PIPPlacement(x: 0.2, y: 0.3), transition: .smooth, duration: 1))
        project.state.regions = [EditorRegion(time: 2, rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), editID: cameraID)]
        project.ensureReferences()
        let base = EditorAnimationEditing.animations(in: project.state, references: project.references, duration: 10)
        let camera = TimelineAnimationID(lane: .camera, componentID: cameraID)
        let screen = TimelineAnimationID(lane: .screen, componentID: screenID)
        let changes = TimelineAnimationSolver.solve(AnimationDrag(id: camera, handle: .move, deltaSeconds: 3), animations: base, duration: 10)!
        let result = EditorAnimationEditing.applying(changes, to: project.state, duration: 10)!.state
        let projected = EditorAnimationEditing.animations(in: result, references: project.references, duration: 10)
        try require(at(camera, in: projected).label == at(camera, in: base).label && at(screen, in: projected).label == at(screen, in: base).label,
                    "Independent Camera/Screen animations may end together without silently renaming either target")
        try require(project.references.edit(in: result, id: cameraID)?.cameraID == cameraID &&
                    project.references.edit(in: result, id: screenID)?.zoomID == screenID && result.regions == project.state.regions,
                    "Co-timing cannot make a surviving component or a box's original edit reference appear removed")
        let cameraLabel = at(camera, in: base).label, screenLabel = at(screen, in: base).label
        try require(EditorActionDescription.resolve(cameraLabel, in: result, references: project.references)?.cameraID == cameraID &&
                    EditorActionDescription.resolve(screenLabel, in: result, references: project.references)?.zoomID == screenID,
                    "Qualified component labels remain addressable even when the selectable timed group is merged")
        let cameraLetter = String(project.references.editLabel(for: cameraID)!.dropFirst("Edit ".count))
        let screenLetter = String(project.references.editLabel(for: screenID)!.dropFirst("Edit ".count))
        try require(EditorActionDescription.resolve("Camera " + screenLetter, in: result, references: project.references) == nil &&
                    EditorActionDescription.resolve("Zoom " + cameraLetter, in: result, references: project.references) == nil,
                    "A merged group cannot fabricate an unrelated Camera/Screen label by borrowing the other component's letter")
    }
    static func reorderedMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("animation-reorder-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for lane in [TimelineAnimationLane.screen, .camera] {
            for forward in [true, false] {
                let shared = UUID(), middleID = UUID(), lastID = UUID(), anchorID = UUID(), replacement = UUID()
                let sourceTime = forward ? 4.0 : 12.0
                let sourceDuration = forward ? 1.0 : 2.0
                var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 16)
                project.state.zoomKeyframes = [ZoomKeyframe(id: shared, time: sourceTime, scale: 1.8, x: 0.4,
                    transition: .smooth, duration: sourceDuration, easeIn: 0.2, easeOut: 0.3)]
                project.state.pipKeyframes.append(PIPKeyframe(id: shared, time: sourceTime,
                    placement: PIPPlacement(x: 0.3, y: 0.6, scale: 0.35), transition: .smooth,
                    duration: sourceDuration, easeIn: 0.2, easeOut: 0.3))
                let firstTime = forward ? 8.0 : 4.0, secondTime = forward ? 12.0 : 8.0
                let firstDuration = forward ? 12.0 : 1.0, secondDuration = forward ? 2.0 : 12.0
                if lane == .screen {
                    project.state.zoomKeyframes += [ZoomKeyframe(id: middleID, time: firstTime, scale: 2.2,
                        transition: .smooth, duration: firstDuration, easeIn: 0.4, easeOut: 0.6),
                        ZoomKeyframe(id: lastID, time: secondTime, scale: 2.5, transition: .smooth, duration: secondDuration)]
                    project.state.zoomKeyframes.sort { $0.time < $1.time }
                } else {
                    project.state.pipKeyframes += [PIPKeyframe(id: middleID, time: firstTime,
                        placement: PIPPlacement(x: 0.7, y: 0.3), transition: .smooth, duration: firstDuration, easeIn: 0.4, easeOut: 0.6),
                        PIPKeyframe(id: lastID, time: secondTime, placement: PIPPlacement(x: 0.8, y: 0.2),
                            transition: .smooth, duration: secondDuration)]
                    project.state.pipKeyframes.sort { $0.time < $1.time }
                }
                project.state.editAnchors = [EditAnchor(id: anchorID, time: sourceTime)]
                project.state.regions = [EditorRegion(time: sourceTime, rect: .init(x: 0.2, y: 0.2, width: 0.2, height: 0.2), editID: shared)]
                project.state.cursorStyle.size = 2
                project.state.audio.volume = 0.6
                project.state.trimStart = 0.5; project.state.trimEnd = 15.5
                project.references.edits = [shared.uuidString: 1, middleID.uuidString: 2, lastID.uuidString: 3, anchorID.uuidString: 4]
                project.ensureReferences()
                let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("\(lane.rawValue)-\(forward).framethrower"))
                try require(editor.save(), "Save the JSON-only reorder baseline")
                let original = editor.project
                let base = EditorAnimationEditing.animations(in: original.state, references: editor.references, duration: 16)
                let id = TimelineAnimationID(lane: lane, componentID: shared)
                let target = at(id, in: base)
                let replacementMap = [id: replacement]
                var final: EditorAnimationEdit?
                for delta in forward ? [9.5, 10.0] : [-8.5, -9.0] {
                    guard let changes = TimelineAnimationSolver.solve(AnimationDrag(id: id, handle: .move,
                        deltaSeconds: delta, snapTolerance: 0), animations: base, duration: 16),
                        let edit = EditorAnimationEditing.applying(changes, to: original.state, duration: 16, replacementIDs: replacementMap) else {
                        throw AnimationCheckFailure.failed("A fully cleared \(lane.rawValue) reorder must apply to actual project metadata")
                    }
                    let aliases = Dictionary(uniqueKeysWithValues: edit.aliases.map { ($0.replacementID, $0.originalID) })
                    try require(editor.updateDraft(edit.state, at: target.end, editAliases: aliases),
                                "All reordered samples use one frozen gesture origin and identity map")
                    final = edit
                }
                let edit = final!, state = edit.state
                let projected = EditorAnimationEditing.animations(in: state, references: editor.references, duration: 16)
                let moved = at(TimelineAnimationID(lane: lane, componentID: replacement), in: projected)
                try near(moved.start, forward ? 13 : 1, "A fully cleared drag retains the requested translated beginning")
                try near(moved.end, forward ? 14 : 3, "The moved animation's target crosses the original chronological neighbors")
                try require(moved.duration == target.duration && moved.easeIn == target.easeIn && moved.easeOut == target.easeOut,
                            "Reordering retains the selected animation's duration and acceleration/deceleration")
                for neighborID in [middleID, lastID] {
                    let key = TimelineAnimationID(lane: lane, componentID: neighborID)
                    let before = at(key, in: base), after = at(key, in: projected)
                    try require(before.start == after.start && before.end == after.end && before.easeIn == after.easeIn && before.easeOut == after.easeOut,
                                "Reordering cannot expand a previously clipped neighbor or shift its effective interval/ramps")
                }
                try require(state.editAnchors == original.state.editAnchors && state.regions == original.state.regions &&
                            state.cursorStyle == original.state.cursorStyle && state.audio == original.state.audio &&
                            state.trimStart == original.state.trimStart && state.trimEnd == original.state.trimEnd &&
                            (lane == .screen ? state.pipKeyframes == original.state.pipKeyframes : state.zoomKeyframes == original.state.zoomKeyframes),
                            "A reorder leaves the stationary lane, original source anchors/boxes and all global metadata intact")
                try require(edit.aliases == [EditorAnimationIdentityAlias(originalID: shared, replacementID: replacement, lane: lane)] &&
                            editor.references.editLabel(for: replacement) == original.references.editLabel(for: shared),
                            "Splitting the shared raw component retains its own allocation rather than a coincident unrelated anchor's letter")
                let times = lane == .screen ? state.zoomKeyframes.map(\.time) : state.pipKeyframes.dropFirst().map(\.time)
                try require(times == (forward ? [8, 12, 14] : [3, 4, 8]), "Applied source metadata is chronologically sorted after reordering")
                try require(editor.project == original && editor.finishDraft(name: "Reorder \(lane.rawValue) animation") && editor.project.undoHistory.count == 1,
                            "Multiple reordered previews publish one normal saved history change")
                let reopened = try ProjectEditor.open(url: editor.url)
                try require(reopened.project.state == state && reopened.undo() && reopened.project.state == original.state &&
                            reopened.redo() && reopened.project.state == state,
                            "Save/reopen and one Undo/Redo retain both the animation ordering and split identity")
            }
        }
    }

    static func coincidentReference() throws {
        let referenceID = UUID(), screenID = UUID()
        var project = RecordingProject(screenFilename: "missing.mov", duration: 10)
        project.state.editAnchors = [EditAnchor(id: referenceID, time: 1)]
        project.state.zoomKeyframes = [ZoomKeyframe(id: screenID, time: 5, scale: 2, transition: .smooth, duration: 1)]
        project.state.regions = [EditorRegion(time: 1, rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), editID: referenceID)]
        project.ensureReferences()
        let base = EditorAnimationEditing.animations(in: project.state, references: project.references, duration: 10)
        let id = TimelineAnimationID(lane: .screen, componentID: referenceID)
        let changes = TimelineAnimationSolver.solve(AnimationDrag(id: id, handle: .move, deltaSeconds: 4), animations: base, duration: 10)!
        guard let edit = EditorAnimationEditing.applying(changes, to: project.state, duration: 10) else {
            throw AnimationCheckFailure.failed("A reference mark must be allowed to coincide with a framing endpoint")
        }
        let projected = EditorAnimationEditing.animations(in: edit.state, references: project.references, duration: 10)
        let screen = TimelineAnimationID(lane: .screen, componentID: screenID)
        try require(at(screen, in: projected).label == at(screen, in: base).label &&
                    project.references.edit(in: edit.state, id: screenID)?.zoomID == screenID &&
                    project.references.edit(in: edit.state, id: referenceID)?.anchorID == referenceID &&
                    edit.state.regions == project.state.regions,
                    "Co-timing a reference preserves the framing component's label and both source-time associations")
    }
}
