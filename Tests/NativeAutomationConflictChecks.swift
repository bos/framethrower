import Combine
import Foundation

private enum NativeConflictFailure: Error { case failed(String) }
@main @MainActor
struct NativeAutomationConflictChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NativeConflictFailure.failed(message) }
    }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
    @MainActor final class Fixture {
        let folder: URL
        let editor: ProjectEditor
        let playback = EditorPlayback()
        let host: EditorAutomationHost
        let guide: EditorRegion
        let crossed: UUID
        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-native-conflict-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guide = EditorRegion(time: 3, rect: .init(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
            let point = ZoomKeyframe(time: 5, scale: 2, x: 0.4, y: 0.4, transition: .smooth, duration: 3)
            crossed = point.id
            var project = RecordingProject(screenFilename: "never-open-screen.mov", cameraFilename: "never-open-camera.mov", duration: 12)
            project.state.regions = [guide]
            project.state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 1, transition: .jump), point,
                ZoomKeyframe(time: 9, scale: 1, transition: .smooth, duration: 2)]
            project.state.pipKeyframes = [PIPKeyframe(time: 0, placement: .init(shape: .circle)),
                PIPKeyframe(time: 5, placement: .init(x: 0.2, y: 0.3, shape: .rectangle), duration: 2)]
            project.ensureReferences()
            editor = ProjectEditor(project: project, url: folder.appendingPathComponent("recording.framethrower"))
            try require(editor.save(), "save temporary project")
            host = EditorAutomationHost(editor: editor, playback: playback)
        }
        func close() { playback.close(); try? FileManager.default.removeItem(at: folder) }
        func apply(_ commands: [EditorCommand], title: String? = nil) async throws -> [String: Any] {
            var args: [String: Any] = ["document_id": host.documentID,
                "expected_revision": try EditorCommandDispatcher.revision(for: editor.project),
                "commands": try JSONSerialization.jsonObject(with: JSONEncoder().encode(commands)), "name": "Director: Reframe"]
            if let title { args["title"] = title }
            return try await call("apply_edits", args)
        }
        func call(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: await host.performAutomation(name, arguments: json(args))) as! [String: Any]
        }
        func proposal(_ commands: [EditorCommand]) async throws -> EditorAutomationFramingProposal {
            let result = try await apply(commands)
            try require(result["ok"] as? Bool == false, "overlap must not report applied")
            try require((result["error"] as? [String: Any])?["code"] as? String == "framing_conflict", "shared conflict response")
            guard let pending = host.pendingFramingProposal else { throw NativeConflictFailure.failed("missing observable proposal") }
            try require(pending.conflict.framingIDs.contains(crossed), "actual crossed component identified")
            return pending
        }
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "metadata/vector interlock")
        try await typedFrozenReviewAndReplace()
        try await legacyMovesAndKeep()
        try await staleDraftAndFailedSave()
        try await explicitResolutionAndBoundaryContact()
        print("Native automation conflict checks passed: typed/legacy preflight, frozen visual state, Keep/Replace, no replan, revision/draft invalidation, one Undo/Redo, failed-save retry and independent camera/pointer/audio preservation; metadata only.")
    }
    static func typedFrozenReviewAndReplace() async throws {
        let f = try Fixture(); defer { f.close() }
        let before = f.editor.project
        let bytes = try Data(contentsOf: f.editor.url)
        var published: [UUID?] = []
        let observation = f.host.$pendingFramingProposal.sink { published.append($0?.id) }
        defer { observation.cancel() }
        let command = EditorCommand.mutate(.zoomScreen(scale: 2.6, center: .init(x: 0.5, y: 0.5), timing: .init(start: 4, end: 6)))
        let result = try await f.apply([command, .mutate(.audio(.init(volume: 0.5)))], title: "Reviewed title")
        try require(result["ok"] as? Bool == false, "mixed batch remains pending as a whole")
        guard let pending = f.host.pendingFramingProposal else { throw NativeConflictFailure.failed("typed proposal") }
        try require(f.editor.project == before && !f.editor.canUndo && f.editor.draftState == nil, "preflight changes no state/history/draft")
        try require(try Data(contentsOf: f.editor.url) == bytes, "preflight leaves original bytes unchanged")
        guard let review = EditorConflictReview.make(pending.conflict, project: before, projectID: pending.context.projectID,
                preparedState: pending.preparedState) else { throw NativeConflictFailure.failed("exact prepared comparison") }
        try require(!review.existingSpans.isEmpty && !review.proposedSpans.isEmpty && !review.overlapIntervals.isEmpty, "Existing/Proposed timeline spans")
        let outlines = review.outlines(at: 4.5)!
        try require(outlines.existing != outlines.proposed, "preview compares actual differing viewports")
        try require(pending.preparedState.pipKeyframes == before.state.pipKeyframes, "screen conflict never removes same-time camera")
        let same = try await f.apply([.fullFrame(time: 4)])
        try require(same["ok"] as? Bool == false && f.host.pendingFramingProposal?.id == pending.id, "another call cannot replace pending proposal")
        let committed = pending.preparedState
        let resolution = try f.host.resolveFramingProposal(id: pending.id, choice: "replace")
        try require((try JSONSerialization.jsonObject(with: resolution) as! [String: Any])["ok"] as? Bool == true, "replace result")
        try require(f.host.pendingFramingProposal == nil && published.last! == nil, "successful Replace publishes clear")
        try require(f.editor.editingState == committed && f.editor.project.title == "Reviewed title", "commit EXACT reviewed UUIDs/state and title")
        try require(f.editor.undo() && f.editor.project.state == before.state && f.editor.project.title == before.title && !f.editor.canUndo,
                    "mixed title/audio/framing is one Undo")
        try require(f.editor.redo() && f.editor.editingState == committed, "Redo preserves frozen identities")
        let reopened = try ProjectEditor.open(url: f.editor.url)
        try require(reopened.editingState == committed && reopened.project.title == "Reviewed title", "durable reviewed state")
        try require(!f.playback.hasMediaPlayer, "no AVPlayer allocated")
    }
    static func legacyMovesAndKeep() async throws {
        for kind in 0..<3 {
            let f = try Fixture(); defer { f.close() }
            let before = f.editor.project
            let command: EditorCommand = kind == 0 ? .frameRegion(regionID: f.guide.id, time: 6, motion: .init(duration: 2)) :
                kind == 1 ? .fullFrame(time: 4, motion: .init(duration: 1)) : .holdFraming(time: 4)
            let pending = try await f.proposal([command])
            _ = try f.host.resolveFramingProposal(id: pending.id, choice: "keep")
            try require(f.host.pendingFramingProposal == nil && f.editor.project == before && !f.editor.canUndo,
                        "legacy fit/fullFrame/hold Keep preserves original and creates no Undo")
        }
    }
    static func staleDraftAndFailedSave() async throws {
        let f = try Fixture(); defer { f.close() }
        let real = EditorCommand.mutate(.zoomScreen(scale: 2.5, center: nil, timing: .init(start: 4, end: 6)))
        let first = try await f.proposal([real])
        var next = f.editor.project.state; next.cursorStyle.size = 2
        try require(f.editor.commit(next, name: "Manual pointer"), "manual update")
        try require(f.host.pendingFramingProposal == nil, "manual revision immediately clears stale proposal")
        do { _ = try f.host.resolveFramingProposal(id: first.id, choice: "replace"); throw NativeConflictFailure.failed("stale proposal resolved") }
        catch is EditorCommandError {} catch is EditorAutomationError {}
        let second = try await f.proposal([real])
        next = f.editor.project.state; next.audio.volume = 0.7
        try require(f.editor.updateDraft(next, at: 4), "pending manual draft")
        try require(f.host.pendingFramingProposal == nil, "manual draft clears comparison")
        _ = f.editor.cancelDraft()
        let final = try await f.proposal([real])
        try require(final.id != second.id, "fresh frozen proposal after discarded draft")
        let originalBytes = try Data(contentsOf: f.editor.url)
        let state = f.editor.project
        let external = Data("external writer bytes".utf8)
        try external.write(to: f.editor.url)
        do { _ = try f.host.resolveFramingProposal(id: final.id, choice: "replace"); throw NativeConflictFailure.failed("overwrote external bytes") }
        catch is EditorCommandError {}
        try require(try Data(contentsOf: f.editor.url) == external && f.editor.project == state && f.host.pendingFramingProposal?.id == final.id,
                    "failed save preserves external bytes, history and pending review")
        try originalBytes.write(to: f.editor.url)
        _ = try f.host.resolveFramingProposal(id: final.id, choice: "replace")
        try require(f.editor.editingState == final.preparedState, "retry commits same reviewed state")
    }
    static func explicitResolutionAndBoundaryContact() async throws {
        let f = try Fixture(); defer { f.close() }
        let pending = try await f.proposal([.fullFrame(time: 4)])
        let inspect = try await f.call("inspect_editor", ["document_id": f.host.documentID, "section": "pending"])
        try require(inspect["ok"] as? Bool == true, "pending proposal inspectable by native client")
        let scope: [String: Any] = ["document_id": f.host.documentID, "expected_revision": pending.context.revision,
            "proposal_id": pending.id.uuidString, "review_choice": "keep", "commands": []]
        var invalid = scope; invalid["commands"] = [["action": "fullFrame", "time": 8]]
        do { _ = try await f.call("apply_edits", invalid); throw NativeConflictFailure.failed("replanned during resolution") }
        catch is EditorAutomationError {}
        let kept = try await f.call("apply_edits", scope)
        try require(kept["ok"] as? Bool == true && f.host.pendingFramingProposal == nil, "same native apply tool resolves frozen choice")
        let boundary = try await f.apply([.mutate(.zoomScreen(scale: 2.5, center: nil, timing: .init(start: 5, end: 7)))])
        try require(boundary["ok"] as? Bool == true && f.host.pendingFramingProposal == nil, "touching existing lane boundaries is not overlap")
    }
}
