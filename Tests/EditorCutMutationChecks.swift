import Foundation

private enum CutMutationCheckError: Error { case failed(String) }

@main
@MainActor
struct EditorCutMutationChecks {
    static func main() throws {
        try require(MediaProcessing.isSuspended, "The media interlock stays enabled")
        try strictCodingAndDiscovery()
        try sourceRecordsSurviveCutAndRestore()
        try outputEndpointsAndAmbiguity()
        try mergeIdentityAndRequestedTransitions()
        try invalidChangesAreAtomic()
        try ordinarySavedHistoryAndFailure()
        print("Cut mutation checks passed (explicit time bases, preserved source records, ambiguous endpoint rejection, stable merged joins, requested/effective fades, atomic save and ordinary Undo/Redo).")
    }

    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw CutMutationCheckError.failed(message) }
    }
    private static func rejects(_ body: () throws -> Void, containing text: String? = nil) throws {
        do { try body() }
        catch {
            if let text { try require(error.localizedDescription.contains(text), "Rejection must explain \(text): \(error)") }
            return
        }
        throw CutMutationCheckError.failed("Expected an atomic rejection")
    }
    private static func map(_ state: EditState, duration: Double = 20) throws -> RecordingTimeMap {
        try .init(duration: duration, trimStart: state.trimStart, trimEnd: state.trimEnd, cuts: state.cuts)
    }
    private static func project() -> RecordingProject {
        var value = RecordingProject(screenFilename: "unopened-screen.mov", cameraFilename: "unopened-camera.mov", duration: 20)
        value.state.zoomKeyframes = [ZoomKeyframe(time: 6, scale: 2, x: 0.4, y: 0.6, duration: 2)]
        value.state.pipKeyframes.append(PIPKeyframe(time: 6, placement: PIPPlacement(x: 0.1, y: 0.2, scale: 0.3), duration: 2))
        value.state.regions = [EditorRegion(time: 6, rect: .init(x: 0.2, y: 0.2, width: 0.4, height: 0.4))]
        value.state.editAnchors = [EditAnchor(time: 6)]
        value.state.cursorStyle.size = 1.5
        value.state.audio.volume = 0.6; value.state.audio.fadeIn = 1; value.state.audio.fadeOut = 2
        return value
    }

    private static func strictCodingAndDiscovery() throws {
        let id = UUID()
        let values: [EditorMutation] = [.cutSection(start: 2, end: 4, timeBase: .source),
            .cutSection(start: 2, end: 4, timeBase: .output, crossfade: 0.5),
            .restoreCut(cutID: id), .cutTransition(cutID: id, duration: 1)]
        for value in values {
            let encoded = try JSONEncoder().encode(EditorCommand.mutate(value))
            try require(try JSONDecoder().decode(EditorCommand.self, from: encoded) == .mutate(value), "Cut commands roundtrip through the public dispatcher")
            try require(value.lane == .timing && value.timing == nil && value.conflicts(in: project().state).isEmpty,
                        "Cuts change timing without becoming screen or camera movement conflicts")
            try require(value.effects(duration: 20).allSatisfy { $0.lane == .timing && $0.subject == nil }, "Timing effects are explicit")
        }
        let invalid = [
            #"{"operation":"cutSection","start":2,"end":4}"#,
            #"{"operation":"cutSection","start":2,"end":4,"timeBase":"timeline"}"#,
            #"{"operation":"cutSection","start":2,"end":4,"timeBase":"source","crossfade":null}"#,
            #"{"operation":"cutSection","start":2,"end":4,"timeBase":"source","timing":{"start":0,"end":1}}"#,
            #"{"operation":"restoreCut","cutID":"invalid"}"#,
            "{\"operation\":\"restoreCut\",\"cutID\":\"\(id.uuidString)\",\"start\":2}",
            "{\"operation\":\"cutTransition\",\"cutID\":\"\(id.uuidString)\",\"duration\":null}"]
        for json in invalid { try rejects { _ = try JSONDecoder().decode(EditorMutation.self, from: Data(json.utf8)) } }
        for operation in ["cutSection", "restoreCut", "cutTransition"] {
            let description = try EditorMutation.describe(operation: operation)
            let schema = (description["command_schema"] as! [String: Any])["properties"] as! [String: Any]
            let mutation = schema["mutation"] as! [String: Any]
            try require(mutation["additionalProperties"] as? Bool == false, "Exact cut schemas are closed")
            if operation == "cutSection" {
                try require((mutation["required"] as! [String]).contains("timeBase") &&
                            !(mutation["required"] as! [String]).contains("crossfade"), "Time base is explicit while an omitted fade preserves an existing join")
            }
        }
        let catalog = try EditorMutation.describe(operation: nil)["operations"] as! [String: [String]]
        try require(catalog["timing"] == ["cutSection", "restoreCut", "cutTransition", "speed"], "Director discovers cuts and saved speed in the timing category")
    }

    private static func sourceRecordsSurviveCutAndRestore() throws {
        let base = project()
        var state = base.state
        try EditorMutation.cutSection(start: 4, end: 8, timeBase: .source).apply(to: &state, project: base)
        let cut = state.cuts[0]
        var restored = state; restored.cuts = []
        try require(restored == base.state && (try map(state).outputDuration) == 16,
                    "Cutting hides footage without deleting/retiming source animations, boxes, anchors, audio or pointer settings")
        let sample = try map(state).samples(at: 4)[0]
        try require(sample.sourceTime == 8 && state.zoom(at: sample.sourceTime) == base.state.zoom(at: 8) &&
                    state.placement(at: sample.sourceTime) == base.state.placement(at: 8),
                    "The next visible frame evaluates the original source-time animation, including targets inside the cut")
        try EditorMutation.restoreCut(cutID: cut.id).apply(to: &state, project: base)
        try require(state == base.state, "Restoring the cut restores exactly the original edit state")
    }

    private static func outputEndpointsAndAmbiguity() throws {
        var base = project()
        base.state.cuts = [RecordingCut(start: 5, end: 8, crossfade: 1)]
        var state = base.state
        try EditorMutation.cutSection(start: 6, end: 8, timeBase: .output).apply(to: &state, project: base)
        try require(state.cuts.contains { $0.start == 10 && $0.end == 12 },
                    "Output seconds resolve against both the existing cut and its overlap, not a raw source offset")
        for range in [(4.5, 6.0), (3.0, 4.5)] {
            var unchanged = base.state
            try rejects({ try EditorMutation.cutSection(start: range.0, end: range.1, timeBase: .output).apply(to: &unchanged, project: base) }, containing: "two different source frames")
            try require(unchanged == base.state, "An ambiguous output start or end never guesses a crossfade branch")
        }
        let end = try map(base.state).outputDuration
        let range = try EditorCutEditing.sourceRange(start: 6, end: end, timeBase: .output, state: base.state, duration: base.duration)
        try require(range == 10..<20, "The explicit final output boundary maps to the exclusive source end")
        let boundary = try EditorCutEditing.sourceRange(start: 3, end: 4, timeBase: .output, state: base.state, duration: base.duration)
        try require(boundary == 3..<4, "A zero-weight contributor at the crossfade boundary does not invent ambiguity")
    }

    private static func mergeIdentityAndRequestedTransitions() throws {
        var base = project()
        let first = RecordingCut(start: 2, end: 4, crossfade: 0.4)
        let second = RecordingCut(start: 8, end: 10, crossfade: 0.8)
        base.state.cuts = [first, second]
        var state = base.state
        try EditorMutation.cutSection(start: 4, end: 8, timeBase: .source).apply(to: &state, project: base)
        try require(state.cuts == [RecordingCut(id: first.id, start: 2, end: 10, crossfade: 0.4)],
                    "Abutting cuts merge transitively into the earliest existing identity and requested fade")
        let merged = state
        try EditorMutation.cutSection(start: 3, end: 7, timeBase: .source).apply(to: &state, project: base)
        try require(state == merged, "Repeating an already omitted interval is a no-op, preserving its fade and identity")
        try EditorMutation.cutSection(start: 3, end: 7, timeBase: .source, crossfade: 0).apply(to: &state, project: base)
        try require(state.cuts[0].id == first.id && state.cuts[0].crossfade == 0, "Explicit zero changes a merged join to a hard cut")
        try EditorMutation.cutTransition(cutID: first.id, duration: 100).apply(to: &state, project: base)
        let requested = state
        let effective = try map(state).joins[0]
        try require(state.cuts[0].crossfade == 100 && effective.requestedDuration == 100 && effective.duration <= 2 && effective.duration > 0,
                    "Requested transition length survives while its effective duration fits available retained footage")
        state.trimStart = 1; state.trimEnd = 11
        _ = try map(state)
        try require(state.cuts == requested.cuts, "Changing trim never destroys the requested join duration")
        state.trimStart = 0; state.trimEnd = 20
        try require(try map(state) == map(requested), "Restoring trim restores the same effective timing map")
    }

    private static func invalidChangesAreAtomic() throws {
        let base = project()
        for mutation in [EditorMutation.cutSection(start: -1, end: 2, timeBase: .source),
            .cutSection(start: 3, end: 3, timeBase: .source), .cutSection(start: 0, end: 21, timeBase: .source),
            .cutSection(start: 0, end: 20, timeBase: .source), .cutSection(start: 2, end: 4, timeBase: .source, crossfade: -.infinity),
            .cutSection(start: 0, end: 21, timeBase: .output), .restoreCut(cutID: UUID()), .cutTransition(cutID: UUID(), duration: 1)] {
            var state = base.state
            try rejects { try mutation.apply(to: &state, project: base) }
            try require(state == base.state, "Invalid timing mutations leave every state component untouched")
        }
        var state = base.state
        try EditorMutation.cutSection(start: 2, end: 4, timeBase: .source).apply(to: &state, project: base)
        let before = state
        try rejects { try EditorMutation.cutTransition(cutID: state.cuts[0].id, duration: .nan).apply(to: &state, project: base) }
        try require(state == before, "Invalid join duration cannot mutate an existing cut")
    }

    private static func ordinarySavedHistoryAndFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.framethrower")
        let original = project()
        try JSONEncoder().encode(original).write(to: url)
        let editor = try ProjectEditor.open(url: url), id = UUID()
        let batch = EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: editor.project), commands: [
            .mutate(.cutSection(start: 2, end: 4, timeBase: .source, crossfade: 0.5)),
            .mutate(.cutSection(start: 10, end: 12, timeBase: .source)), .mutate(.pointer(.init(size: 2)))])
        _ = try EditorCommandDispatcher.apply(batch, to: editor, projectID: id, name: "Cut two sections")
        let edited = editor.project
        try require(edited.undoHistory.count == 1 && edited.state.cuts.count == 2, "A mixed cut batch is one ordinary saved Undo operation")
        try require(try ProjectEditor.open(url: url).project == edited, "Cuts and joins survive metadata save/reopen")
        try require(editor.undo() && editor.project.state == original.state, "One Undo restores all cut ranges and other edits")
        try require(editor.redo() && editor.project.state == edited.state, "One Redo restores the same cut identities and joins")
        let before = editor.project, beforeBytes = try Data(contentsOf: url)
        let invalid = EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: before), commands: [
            .mutate(.cutSection(start: 5, end: 7, timeBase: .source)), .mutate(.cutSection(start: 0, end: 20, timeBase: .source))])
        try rejects { _ = try EditorCommandDispatcher.apply(invalid, to: editor, projectID: id) }
        try require(editor.project == before && (try Data(contentsOf: url)) == beforeBytes, "A late invalid cut cannot partially save its earlier commands")
        var external = before; external.title = "External metadata change"
        let externalBytes = try JSONEncoder().encode(external); try externalBytes.write(to: url)
        let restore = EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: before), commands: [.mutate(.restoreCut(cutID: before.state.cuts[0].id))])
        try rejects { _ = try EditorCommandDispatcher.apply(restore, to: editor, projectID: id) }
        try require(editor.project == before && (try Data(contentsOf: url)) == externalBytes, "A failed save preserves source metadata, cut state and both history branches")
    }
}
