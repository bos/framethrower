import Foundation

/// Writes only synthetic project/conversation JSON for visual review with the
/// video interlock enabled. No media, model, microphone, or window is opened.
@main @MainActor
struct MakeConflictReviewFixture {
    static func main() throws {
        guard MediaProcessing.isSuspended, CommandLine.arguments.count == 2 else {
            throw CocoaError(.featureUnsupported)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var project = RecordingProject(screenFilename: "missing-screen.mov", duration: 12)
        project.title = "Conflict review test"
        let existing = ZoomKeyframe(time: 4, scale: 2, x: 0.35, y: 0.45, transition: .smooth, duration: 3)
        project.state.zoomKeyframes = [existing, ZoomKeyframe(time: 9)]
        let first = EditorRegion(time: 0, rect: .init(x: 0.08, y: 0.15, width: 0.25, height: 0.3))
        let second = EditorRegion(time: 0, rect: .init(x: 0.65, y: 0.55, width: 0.25, height: 0.3))
        project.state.regions = [first, second]; project.ensureReferences()
        let editor = ProjectEditor(project: project, url: url)
        guard editor.save() else { throw CocoaError(.fileWriteUnknown) }
        let scope = UUID()
        let context = LocalEditContext(recording: try EditorCommandDispatcher.context(editor: editor, projectID: scope),
            playhead: 0, selectedRegionID: nil, selectedEditID: nil, videoProcessingAvailable: false)
        let batch = EditorCommandBatch(projectID: scope, revision: context.recording.revision, commands: [
            .holdFraming(time: 0), .frameRegion(regionID: first.id, time: 1, motion: .init(transition: .smooth, duration: 1)),
            .frameRegion(regionID: second.id, time: 5, motion: .init(transition: .smooth, duration: 4))])
        let conflict = EditorFramingConflict(proposal: batch, summary: "Move through Box 1 to Box 2.", framingIDs: [existing.id],
            question: "Zoom A changes framing from 1.00 to 4.00 s. Replace that movement, or keep it?")
        guard EditorConflictReview.make(conflict, project: project, projectID: scope) != nil else { throw CocoaError(.fileWriteUnknown) }
        let conversation = DirectorConversation(storageURL: DirectorConversation.storageURL(for: url))
        let requestID = UUID()
        conversation.begin("Test: zoom into Box 1 after one second, then pan to Box 2 over four seconds.", requestID: requestID)
        conversation.finish(requestID: requestID, response: nil, outcome: ["status": "conflict", "question": conflict.question, "applied": false])
        conversation.conflict = DirectorPendingConflict(proposal: conflict, context: context, followup: nil)
        conversation.lastProject = DirectorProjectSnapshot(project)
        guard conversation.save() else { throw CocoaError(.fileWriteUnknown) }
        print("Wrote metadata-only conflict fixture: " + url.path)
    }
}
