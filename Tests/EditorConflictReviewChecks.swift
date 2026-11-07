import Foundation

@main
@MainActor
struct EditorConflictReviewChecks {
    enum Failure: Error { case failed(String) }

    static func main() throws {
        try smoothComparison()
        try instantAndRetainedSegments()
        try scopeAndNoChanges()
        try clippingAndInitialBoundary()
        print("Editor conflict review checks passed (exact scoped replacement, smooth/instant/hold spans, preceding bounds, effective retained segments, overlap and differing inspection, normalized/full-frame viewports, source clipping, stale/keep clearing, deterministic IDs and immutable project/history/non-framing state; no media).")
    }

    private static func smoothComparison() throws {
        let fixture = try Fixture()
        let before = try encode(fixture.project)
        let review = try make(fixture)
        try require(review.existingSpans.count == 1 && review.existingSpans[0].side == .existing &&
                    review.existingSpans[0].start == 2 && review.existingSpans[0].end == 8,
                    "existing movement must include its full actual preceding-clip interval")
        try require(review.proposedSpans.contains { $0.start == 4 && $0.end == 6 && $0.side == .proposed },
                    "proposed movement must use actual replacement timing")
        try require(review.proposedSpans.contains { $0.start == 2 && $0.end == 4 } &&
                    review.overlapIntervals.contains(2...6) && review.selectedInterval == 2...6 && review.inspectionTime == 4,
                    "default inspection must use the overlap midpoint rather than the matching start")
        guard let outlines = review.outlines(at: review.inspectionTime) else { throw Failure.failed("Missing midpoint outlines") }
        try require(outlines.existing != outlines.proposed && outlines.time == 4, "midpoint must compare different actual source views")
        let replacement = try EditorCommandDispatcher.prepare(fixture.conflict.replacement, for: fixture.project, projectID: fixture.id)
        let source = CGSize(width: 1, height: 1)
        for time in [0.0, 2, 4, 4.5, 5, 6, 8, 12] {
            let sample = review.outlines(at: time)!
            try require(sample.existing == fixture.project.state.zoom(at: time).viewport(in: source) &&
                        sample.proposed == replacement.zoom(at: time).viewport(in: source),
                        "outlines must follow the same clamped viewport curve as dispatcher state at \(time)")
            try insideUnit(sample.existing)
            try insideUnit(sample.proposed)
        }
        try require(review.outlines(at: 6)?.proposed == fixture.box.rect.framing().viewport(in: source), "proposal arrival must fit its full source box")
        try require(review.previewState.zoomKeyframes.isEmpty && (0...12).allSatisfy { review.previewState.zoom(at: Double($0)) == ZoomPlacement() },
                    "transient preview alone must show the full original frame")
        var expectedPreview = fixture.project.state
        expectedPreview.zoomKeyframes = []
        try require(review.previewState == expectedPreview && replacement.pipKeyframes == fixture.project.state.pipKeyframes &&
                    replacement.cursorStyle == fixture.project.state.cursorStyle && replacement.audio == fixture.project.state.audio &&
                    replacement.presentation == fixture.project.state.presentation,
                    "camera, pointer, audio, trim, boxes and presentation must be preserved")
        let again = try make(fixture)
        try require(review == again && review.existingSpans.map(\.id) == again.existingSpans.map(\.id) &&
                    review.proposedSpans.map(\.id) == again.proposedSpans.map(\.id), "UUID allocation inside prepare must not make comparison identity nondeterministic")
        try require(try encode(fixture.project) == before && fixture.project.undoHistory.count == 1 && fixture.project.redoHistory.count == 1,
                    "review creation must not alter project bytes or create/consume Undo")
    }

    private static func instantAndRetainedSegments() throws {
        var fixture = try Fixture()
        fixture.project.state.zoomKeyframes[1].time = 5
        fixture.project.state.zoomKeyframes[1].transition = .jump
        fixture.project.state.zoomKeyframes.append(ZoomKeyframe(time: 9, scale: 2.6, x: 0.7, transition: .smooth, duration: 2))
        fixture.refresh()
        let review = try make(fixture)
        try require(review.existingSpans.count == 1 && review.existingSpans[0].isInstant && review.existingSpans[0].range == 5...5,
                    "an existing jump must remain an instant rather than a fake smooth interval")
        try require(review.overlapIntervals.contains(5...5) && review.inspectionTime == 5,
                    "an instant inside a proposed smooth span is an actual point overlap")
        try require(review.outlines(at: 5)!.existing != review.outlines(at: 5)!.proposed, "instant inspection must compare views after the existing jump")
        try require(review.proposedSpans.contains { $0.start == 7 && $0.end == 9 },
                    "retained point with unchanged own fields but a different incoming source view is also a changed proposed span")

        var fullFrame = fixture
        fullFrame.conflict.proposal.commands = [.holdFraming(time: 4), .fullFrame(time: 6, motion: EditorCommandMotion(duration: 2))]
        let fullReview = try make(fullFrame)
        try require(fullReview.outlines(at: 6)?.proposed == CGRect(x: 0, y: 0, width: 1, height: 1), "full-frame replacement must produce the unit source viewport")
    }

    private static func scopeAndNoChanges() throws {
        let fixture = try Fixture()
        try require(EditorConflictReview.make(nil, project: fixture.project, projectID: fixture.id) == nil,
                    "keeping framing or clearing pending conflict must clear review")
        var changed = fixture.project
        changed.state.audio.volume = 0.2
        try require(EditorConflictReview.make(fixture.conflict, project: changed, projectID: fixture.id) == nil,
                    "any changed project revision must clear the cached conflict projection")
        try require(EditorConflictReview.make(fixture.conflict, project: fixture.project, projectID: UUID()) == nil, "foreign host project must be rejected")
        var missing = fixture.conflict
        missing.framingIDs = [UUID()]
        try require(EditorConflictReview.make(missing, project: fixture.project, projectID: fixture.id) == nil, "missing affected points cannot create a partial review")
        var invalid = fixture.conflict
        invalid.proposal.commands = [.fullFrame(time: 13)]
        try require(EditorConflictReview.make(invalid, project: fixture.project, projectID: fixture.id) == nil, "invalid replacement must fail without partial projection")
        var nonFraming = fixture.conflict
        let cameraEdit = fixture.project.state.timedEdits(includeCamera: true).first { $0.cameraID != nil }!
        nonFraming.proposal.commands = [.removeEdit(editID: cameraEdit.id)]
        try require(EditorConflictReview.make(nonFraming, project: fixture.project, projectID: fixture.id) == nil,
                    "a framing review cannot silently include changed camera metadata")

        var noChange = fixture
        noChange.project = RecordingProject(screenFilename: "missing.txt", duration: 5,
            state: EditState(trimStart: 0, trimEnd: 5, pipKeyframes: [PIPKeyframe(time: 0, placement: PIPPlacement())],
                             zoomKeyframes: [ZoomKeyframe(time: 0)]))
        noChange.conflict.framingIDs = [noChange.project.state.zoomKeyframes[0].id]
        noChange.conflict.proposal.commands = [.holdFraming(time: 0)]
        noChange.refresh()
        try require(EditorConflictReview.make(noChange.conflict, project: noChange.project, projectID: noChange.id) == nil,
                    "a valid replacement with identical framing points needs no visual review")
        let keepResponse = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [["type": "function", "function": [
            "name": "resolve_framing_conflict", "arguments": String(decoding: JSONSerialization.data(withJSONObject: [
                "project_id": fixture.id.uuidString, "expected_revision": fixture.conflict.proposal.revision, "choice": "keep"]), as: UTF8.self)]]]]]]])
        guard case .noChanges = try LocalEditPlanner.conflictResult(keepResponse, conflict: fixture.conflict) else {
            throw Failure.failed("valid keep must remain a no-changes decision")
        }
    }

    private static func clippingAndInitialBoundary() throws {
        var fixture = try Fixture()
        fixture.project.state.zoomKeyframes = [ZoomKeyframe(time: 0), ZoomKeyframe(time: 12, scale: 2.4, transition: .smooth, duration: 60)]
        fixture.conflict.framingIDs = [fixture.project.state.zoomKeyframes[1].id]
        fixture.refresh()
        let review = try make(fixture)
        try require(review.existingSpans[0].start == 0 && review.existingSpans[0].end == 12, "movement bounds clip to source duration and preceding start")
        try require(review.outlines(at: -100)?.time == 0 && review.outlines(at: 100)?.time == 12 &&
                    review.outlines(at: .nan) == nil && review.outlines(at: .infinity) == nil, "arbitrary inspection time must remain finite and source bounded")

        var initial = fixture
        initial.project.state.zoomKeyframes = [ZoomKeyframe(time: 0)]
        initial.conflict.framingIDs = [initial.project.state.zoomKeyframes[0].id]
        initial.conflict.proposal.commands = [.holdFraming(time: 0), .frameRegion(regionID: initial.box.id, time: 1, motion: EditorCommandMotion(duration: 1))]
        initial.refresh()
        let initialReview = try make(initial)
        try require(initialReview.inspectionTime > 0 && initialReview.outlines(at: initialReview.inspectionTime)!.existing != initialReview.outlines(at: initialReview.inspectionTime)!.proposed,
                    "a shared instant at zero must not default inspection to two matching initial views")
    }

    private struct Fixture {
        let id = UUID()
        let box: EditorRegion
        var project: RecordingProject
        var conflict: EditorFramingConflict
        init() throws {
            box = EditorRegion(time: 3, rect: EditorRegionRect(x: 0.62, y: 0.2, width: 0.2, height: 0.25))
            var state = EditState(trimStart: 1, trimEnd: 11, pipKeyframes: [PIPKeyframe(time: 0, placement: PIPPlacement()),
                PIPKeyframe(time: 3, placement: PIPPlacement(x: 0.2, shape: .circle))],
                zoomKeyframes: [ZoomKeyframe(time: 2, scale: 1.3), ZoomKeyframe(time: 8, scale: 2, x: 0.35, transition: .smooth, duration: 20)],
                cursorStyle: CursorStyle(size: 2), regions: [box], audio: RecordingAudio(volume: 0.7, fadeIn: 1, fadeOut: 2))
            state.presentation.padding = 0.1
            project = RecordingProject(screenFilename: "screen.txt", cameraFilename: "camera.txt", cursorFilename: "pointer.txt",
                cameraOffset: -0.2, duration: 12, state: state,
                undoHistory: [NamedEditSnapshot(name: "Earlier", state: state)], redoHistory: [NamedEditSnapshot(name: "Later", state: state)])
            conflict = EditorFramingConflict(proposal: EditorCommandBatch(projectID: id,
                revision: try EditorCommandDispatcher.revision(for: project), commands: [.holdFraming(time: 4),
                    .frameRegion(regionID: box.id, time: 6, motion: EditorCommandMotion(duration: 2))]),
                summary: "Replacement movement", framingIDs: [state.zoomKeyframes[1].id], question: "Replace the existing movement?")
        }
        mutating func refresh() {
            project.ensureReferences()
            conflict.proposal.revision = try! EditorCommandDispatcher.revision(for: project)
        }
    }
    private static func make(_ fixture: Fixture) throws -> EditorConflictReview {
        guard let review = EditorConflictReview.make(fixture.conflict, project: fixture.project, projectID: fixture.id) else {
            throw Failure.failed("Valid metadata conflict did not project")
        }
        return review
    }
    private static func insideUnit(_ rect: CGRect) throws {
        try require(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1.000001 && rect.maxY <= 1.000001 && rect.width > 0 && rect.height > 0,
                    "viewport escaped the normalized source")
    }
    private static func encode(_ project: RecordingProject) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(project)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.failed(message) }
    }
}
