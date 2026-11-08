import Foundation

private enum ConnectionFailure: Error { case failed(String) }

/// Pure project metadata, interpolation math, and temporary JSON files only.
/// No source media, player items, capture devices, windows, or image contexts.
@main @MainActor
struct BoxConnectionChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ConnectionFailure.failed(message) }
    }
    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_001 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
    static func legacy(_ data: Data) throws -> Data {
        func strip(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if object["zoomKeyframes"] != nil && object["trimStart"] != nil {
                    object.removeValue(forKey: "boxConnectionsVersion")
                    if let points = object["zoomKeyframes"] as? [[String: Any]] {
                        object["zoomKeyframes"] = points.map { point in
                            var copy = point; copy.removeValue(forKey: "sourceRegionID"); return copy
                        }
                    }
                }
                return object.mapValues(strip)
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        return try json(strip(JSONSerialization.jsonObject(with: data)))
    }
    static func point(_ time: Double, _ region: EditorRegion, transition: PIPTransition = .smooth,
                      duration: Double = 3, easeIn: Double? = 0.4, easeOut: Double? = 0.6, id: UUID = UUID()) -> ZoomKeyframe {
        let placement = region.rect.framing()
        return ZoomKeyframe(id: id, time: time, scale: placement.scale, x: placement.x, y: placement.y,
            transition: transition, duration: duration, easeIn: easeIn, easeOut: easeOut, sourceRegionID: region.id)
    }
    @MainActor struct Fixture {
        let a: EditorRegion
        let b: EditorRegion
        let c: EditorRegion
        let state: EditState
        init() {
            a = EditorRegion(time: 0.5, rect: .init(x: 0.05, y: 0.3, width: 0.2, height: 0.2), note: "A")
            b = EditorRegion(time: 4, rect: .init(x: 0.4, y: 0.3, width: 0.2, height: 0.2), note: "B")
            c = EditorRegion(time: 8, rect: .init(x: 0.75, y: 0.3, width: 0.2, height: 0.2), note: "C")
            let shared = UUID()
            var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 12)
            project.state.regions = [a, b, c]
            project.state.zoomKeyframes = [point(1, a, transition: .jump), point(4, b, id: shared),
                point(8, c, duration: 4, easeIn: 0.7, easeOut: 0.8), ZoomKeyframe(time: 10, scale: 1.2)]
            project.state.pipKeyframes.append(PIPKeyframe(id: shared, time: 4, placement: PIPPlacement(x: 0.2, y: 0.3, scale: 0.2)))
            project.state.editAnchors = [EditAnchor(id: shared, time: 4), EditAnchor(time: 9.5)]
            project.state.cursorStyle.size = 2.2; project.state.audio.volume = 0.6
            project.state.trimStart = 0.2; project.state.trimEnd = 11.5
            state = project.state
        }
        func project(_ replacement: EditState? = nil) -> RecordingProject {
            var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 12)
            project.title = "Box connections"
            project.state = replacement ?? state; project.ensureReferences()
            return project
        }
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "requires suspended media")
        try migrationAndDetachment()
        try bridgeAndPreservation()
        try jumpsHoldsAndRepeatedTargets()
        try timingAndRampsKeepLinks()
        try dispatcherAndDurableUndo()
        print("Box connection checks passed (explicit persisted links, unique/versioned legacy migration including Undo/Redo, detached/full-frame safety, chain bridges, jumps/holds/repeated boxes, shared camera/anchor preservation, timing/ramp edits, consecutive mixed dispatcher deletion and one durable Undo; metadata only).")
    }
    static func migrationAndDetachment() throws {
        let f = Fixture()
        let decoded = try JSONDecoder().decode(EditState.self, from: legacy(JSONEncoder().encode(f.state)))
        try require(decoded.boxConnectionsVersion == 1 && decoded.zoomKeyframes.prefix(3).compactMap(\.sourceRegionID) == [f.a.id, f.b.id, f.c.id], "legacy exact unique targets were not migrated")
        var detached = f.state; detached.zoomKeyframes[1].sourceRegionID = nil
        let detachedRoundtrip = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(detached))
        try require(detachedRoundtrip.zoomKeyframes[1].sourceRegionID == nil && EditorBoxConnections.linkedRegion(for: detachedRoundtrip.zoomKeyframes[1], in: detachedRoundtrip) == nil, "an explicit nil link was inferred again on reopen")
        var ambiguous = f.state; var duplicate = f.b; duplicate.id = UUID(); ambiguous.regions.append(duplicate)
        let ambiguousLegacy = try JSONDecoder().decode(EditState.self, from: legacy(JSONEncoder().encode(ambiguous)))
        try require(ambiguousLegacy.zoomKeyframes[1].sourceRegionID == nil, "ambiguous matching boxes claimed a legacy target")
        var drawnAt = f.state; var wrong = f.a; wrong.editID = f.state.zoomKeyframes[1].id
        drawnAt.regions = [wrong]; drawnAt.zoomKeyframes = [f.state.zoomKeyframes[1]]
        let drawnLegacy = try JSONDecoder().decode(EditState.self, from: legacy(JSONEncoder().encode(drawnAt)))
        try require(drawnLegacy.zoomKeyframes[0].sourceRegionID == nil, "drawn-at editID was treated as ownership")
        var context = f.state
        let giant = EditorRegion(time: 0, rect: .init(x: 0, y: 0, width: 1, height: 1))
        context.regions = [giant]; context.zoomKeyframes = [ZoomKeyframe(time: 1)]
        let contextLegacy = try JSONDecoder().decode(EditState.self, from: legacy(JSONEncoder().encode(context)))
        try require(contextLegacy.zoomKeyframes[0].sourceRegionID == nil, "a giant legacy box claimed an unrelated full-frame context point")
        context.zoomKeyframes[0].sourceRegionID = giant.id
        let explicitFullFrame = try JSONDecoder().decode(EditState.self, from: JSONEncoder().encode(context))
        try require(explicitFullFrame.zoomKeyframes[0].sourceRegionID == giant.id, "a new explicit full-frame link was discarded")
        var project = f.project()
        project.undoHistory = [NamedEditSnapshot(name: "Old Undo", state: f.state)]
        project.redoHistory = [NamedEditSnapshot(name: "Old Redo", state: f.state)]
        let history = try JSONDecoder().decode(RecordingProject.self, from: legacy(JSONEncoder().encode(project)))
        for state in [history.state, history.undoHistory[0].state, history.redoHistory[0].state] {
            try require(state.boxConnectionsVersion == 1 && state.zoomKeyframes[1].sourceRegionID == f.b.id, "legacy history snapshots did not migrate independently")
        }
        try history.validate()
        var dangling = f.project(); dangling.state.zoomKeyframes[0].sourceRegionID = UUID()
        do { try dangling.validate(); throw ConnectionFailure.failed("dangling explicit box link validated") } catch is ProjectError {}
        var badVersion = f.project(); badVersion.state.boxConnectionsVersion = 2
        do { try badVersion.validate(); throw ConnectionFailure.failed("unsupported in-memory connection version validated") } catch is ProjectError {}
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.state)) as! [String: Any]
        object["boxConnectionsVersion"] = NSNull()
        do { _ = try JSONDecoder().decode(EditState.self, from: json(object)); throw ConnectionFailure.failed("present null version triggered legacy inference") } catch is DecodingError {}
    }
    static func bridgeAndPreservation() throws {
        let f = Fixture(), before = f.state
        let next = EditorBoxConnections.removing(regionID: f.b.id, from: before)
        try require(next.regions == [f.a, f.c] && next.zoomKeyframes.map(\.id) == [before.zoomKeyframes[0].id, before.zoomKeyframes[2].id, before.zoomKeyframes[3].id], "deletion removed the wrong target identities")
        let c = next.zoomKeyframes[1]
        try require(c.id == before.zoomKeyframes[2].id && c.time == 8 && c.duration == 7 && c.placement == f.c.rect.framing() && c.sourceRegionID == f.c.id && c.easeIn == 0.4 && c.easeOut == 0.8, "A→B→C did not become one exact A→C movement over the combined interval")
        let progress = MotionInterpolation.progress(at: 4, from: 1, to: 8, duration: 7, transition: .smooth, easeIn: 0.4, easeOut: 0.8)
        let expectedX = MotionInterpolation.blend(f.a.rect.framing().x, f.c.rect.framing().x, progress: progress)
        try require(near(next.zoom(at: 4).x, expectedX) && next.zoom(at: 8) == f.c.rect.framing(), "joined movement did not use shared interpolation or retain its target arrival")
        try require(next.pipKeyframes == before.pipKeyframes && next.cursorStyle == before.cursorStyle && next.audio == before.audio && next.editAnchors == before.editAnchors && next.presentation == before.presentation && next.trimStart == before.trimStart && next.trimEnd == before.trimEnd && next.zoomKeyframes.last == before.zoomKeyframes.last, "box deletion disturbed unrelated screen/camera/pointer/anchor/trim metadata")
        try require(EditorBoxConnections.removing(regionID: UUID(), from: before) == before, "unknown box deletion mutated metadata")
        var authoritative = before; authoritative.zoomKeyframes[1].sourceRegionID = f.a.id
        let keep = EditorBoxConnections.removing(regionID: f.b.id, from: authoritative)
        try require(keep.zoomKeyframes == authoritative.zoomKeyframes && EditorBoxConnections.linkedRegion(for: authoritative.zoomKeyframes[1], in: authoritative)?.id == f.a.id, "geometry overrode an explicit link identity")
        try f.project(next).validate()
    }
    static func jumpsHoldsAndRepeatedTargets() throws {
        let f = Fixture()
        var repeated = f.state
        repeated.zoomKeyframes.insert(point(5, f.b, duration: 1), at: 2)
        let withoutRepeated = EditorBoxConnections.removing(regionID: f.b.id, from: repeated)
        try require(!withoutRepeated.zoomKeyframes.contains { $0.sourceRegionID == f.b.id } && withoutRepeated.zoomKeyframes.first { $0.sourceRegionID == f.c.id }?.duration == 7, "repeated linked box targets/holds survived deletion or broke the combined interval")
        for transition in [PIPTransition.jump, .smooth] {
            var state = f.state
            state.zoomKeyframes[1].transition = transition
            if transition == .smooth { // Actual hold, not a change of framing.
                state.zoomKeyframes[1].scale = state.zoomKeyframes[0].scale
                state.zoomKeyframes[1].x = state.zoomKeyframes[0].x; state.zoomKeyframes[1].y = state.zoomKeyframes[0].y
            }
            state.zoomKeyframes[2].duration = 10 // Originally clipped by B's arrival at 4.
            let next = EditorBoxConnections.removing(regionID: f.b.id, from: state)
            let c = next.zoomKeyframes.first { $0.sourceRegionID == f.c.id }!
            try require(c.duration == 4 && c.easeIn == state.zoomKeyframes[2].easeIn && c.easeOut == state.zoomKeyframes[2].easeOut, "jump/hold removal invented an earlier successor motion by unclipping raw duration")
        }
        var jumpingSuccessor = f.state; jumpingSuccessor.zoomKeyframes[2].transition = .jump
        let afterJump = EditorBoxConnections.removing(regionID: f.b.id, from: jumpingSuccessor)
        try require(afterJump.zoomKeyframes.first { $0.sourceRegionID == f.c.id } == jumpingSuccessor.zoomKeyframes[2], "removing a box turned an immediate jump successor into animation")
        var excursion = f.state
        excursion.zoomKeyframes[2].scale = excursion.zoomKeyframes[0].scale
        excursion.zoomKeyframes[2].x = excursion.zoomKeyframes[0].x; excursion.zoomKeyframes[2].y = excursion.zoomKeyframes[0].y
        excursion.zoomKeyframes[3].transition = .smooth; excursion.zoomKeyframes[3].duration = 2
        let combined = EditorBoxConnections.removing(regionIDs: [f.b.id, f.c.id], from: excursion)
        let reversed = EditorBoxConnections.removing(regionIDs: [f.c.id, f.b.id], from: excursion)
        try require(combined == reversed && combined.zoomKeyframes.last?.duration == 9 && combined.zoomKeyframes.last?.time == 10, "simultaneous deletion lost the original excursion's active start or depended on box order")
    }
    static func timingAndRampsKeepLinks() throws {
        let f = Fixture(), state = f.state
        let spans = EditorAnimationEditing.animations(in: state, references: EditorReferences(), duration: 12)
        let c = TimelineAnimationID(lane: .screen, componentID: state.zoomKeyframes[2].id)
        for request in [AnimationDrag(id: c, handle: .move, deltaSeconds: 0.5, snapTolerance: 0), AnimationDrag(id: c, handle: .easeIn, deltaSeconds: 0.1)] {
            guard let changes = TimelineAnimationSolver.solve(request, animations: spans, duration: 12),
                  let applied = EditorAnimationEditing.applying(changes, to: state, duration: 12) else { throw ConnectionFailure.failed("valid timing/ramp fixture rejected") }
            try require(applied.state.zoomKeyframes.first { $0.id == c.componentID }?.sourceRegionID == f.c.id, "retime/ease edit detached the explicit box connection")
        }
    }
    static func dispatcherAndDurableUndo() throws {
        let f = Fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-box-connections-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = f.project(); project.state.zoomKeyframes = []; project.state.editAnchors = []
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "save dispatcher metadata fixture")
        let projectID = UUID()
        func batch(_ commands: [EditorCommand]) throws -> EditorCommandBatch {
            try EditorCommandBatch(projectID: projectID, revision: EditorCommandDispatcher.revision(for: editor.project), commands: commands)
        }
        try EditorCommandDispatcher.apply(batch([.frameRegion(regionID: f.a.id, time: 1, motion: .init(transition: .jump)),
            .frameRegion(regionID: f.b.id, time: 4, motion: .init(transition: .smooth, duration: 3)),
            .frameRegion(regionID: f.c.id, time: 8, motion: .init(transition: .smooth, duration: 4))]), to: editor, projectID: projectID, name: "Create connected targets")
        try require(editor.project.state.zoomKeyframes.compactMap(\.sourceRegionID) == [f.a.id, f.b.id, f.c.id], "dispatcher failed to persist explicit framing destinations")
        let original = editor.project.state, depth = editor.project.undoHistory.count
        try EditorCommandDispatcher.apply(batch([.removeRegion(regionID: f.b.id)]), to: editor, projectID: projectID, name: "Delete Box 2")
        try require(editor.project.undoHistory.count == depth + 1 && editor.project.state.zoomKeyframes.last?.duration == 7 && editor.project.state.pipKeyframes == original.pipKeyframes, "dispatcher removal did not bridge in one shared Undo step")
        let deleted = editor.project.state
        try require(try ProjectEditor.open(url: editor.url).project.state == deleted && editor.undo() && editor.project.state == original && editor.redo() && editor.project.state == deleted, "box links/removal were not durable through reopen and ordinary Undo/Redo")
        try require(editor.undo(), "restore mixed batch fixture")
        try EditorCommandDispatcher.apply(batch([.holdFraming(time: 9), .fullFrame(time: 10, motion: .init(transition: .smooth, duration: 1))]), to: editor, projectID: projectID, name: "Hold and return")
        try require(editor.project.state.zoomKeyframes.first { $0.time == 9 }?.sourceRegionID == f.c.id && editor.project.state.zoomKeyframes.last?.sourceRegionID == nil, "hold did not inherit its exact target or full-frame retained a stale link")
        let beforeMixed = editor.project, bytes = try Data(contentsOf: editor.url)
        let first = try batch([.labelRegion(regionID: f.a.id, note: "Before"), .removeRegion(regionID: f.b.id), .removeRegion(regionID: f.c.id), .labelRegion(regionID: f.a.id, note: "After")])
        let second = try batch([.labelRegion(regionID: f.a.id, note: "Before"), .removeRegion(regionID: f.c.id), .removeRegion(regionID: f.b.id), .labelRegion(regionID: f.a.id, note: "After")])
        let prepared = try EditorCommandDispatcher.prepare(first, for: beforeMixed, projectID: projectID)
        try require(prepared == EditorCommandDispatcher.prepare(second, for: beforeMixed, projectID: projectID) && prepared.regions.first?.note == "After" && prepared.zoomKeyframes.last?.time == 10 && prepared.zoomKeyframes.last?.duration == 9 && prepared.zoomKeyframes.last?.sourceRegionID == nil, "consecutive deletion/note batch lost sequential semantics or depended on deletion order")
        try require(editor.project == beforeMixed && Data(contentsOf: editor.url) == bytes, "preparing mixed metadata commands mutated disk/history")
        try EditorCommandDispatcher.apply(first, to: editor, projectID: projectID, name: "Delete connected boxes")
        try require(editor.project.state == prepared && editor.project.undoHistory.count == beforeMixed.undoHistory.count + 1 && editor.undo() && editor.project.state == beforeMixed.state, "mixed box removal did not remain one durable reversible edit")
    }
}
