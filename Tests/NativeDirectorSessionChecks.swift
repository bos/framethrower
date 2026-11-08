import Combine
import Foundation

private enum NativeCheckFailure: Error { case failed(String) }
private actor NativeTurnRecorder {
    var requests: [Data] = []
    func turn(_ input: Data, url: URL, provider: DirectorProvider) throws -> Data {
        requests.append(input)
        return try JSONSerialization.data(withJSONObject: ["ok": true, "native_session_id": "native-fixture",
            "text": "Native reply \(requests.count)", "usage": [:], "events": []])
    }
    func values() -> [Data] { requests }
}
@MainActor
private final class NativeFixtureEndpoint: EditorAutomationEndpoint {
    let editor: ProjectEditor
    let documentID = UUID().uuidString
    private let publisher = PassthroughSubject<EditorAutomationEvent, Never>()
    init(_ editor: ProjectEditor) { self.editor = editor }
    var automationContext: EditorAutomationContext {
        get throws { .init(documentID: documentID, name: editor.displayName,
            revision: try EditorCommandDispatcher.revision(for: editor.project), hasDraft: editor.draftState != nil,
            preview: .init(time: 9, frameTime: 9, isPlaying: false, rate: 1, canPlay: true, kind: .testPattern),
            selectedEditID: nil, selectedBoxID: nil, selectedAnimationID: nil, inspector: "Camera") }
    }
    var automationEvents: AnyPublisher<EditorAutomationEvent, Never> { publisher.eraseToAnyPublisher() }
    func performAutomation(_ name: String, arguments: Data) async throws -> Data { throw NativeCheckFailure.failed("Native runtime, not legacy planner, must own tool execution") }
}
@main @MainActor
struct NativeDirectorSessionChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NativeCheckFailure.failed(message) }
    }
    static func wait(_ session: EditorAssistantSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while session.isBusy {
            if ContinuousClock.now > deadline { throw NativeCheckFailure.failed("native turn timeout") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-native-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let editor = ProjectEditor(project: .init(screenFilename: "absent.mov", duration: 14), url: folder.appendingPathComponent("native.framethrower"))
        try require(editor.save(), "prepare metadata")
        let endpoint = NativeFixtureEndpoint(editor), recorder = NativeTurnRecorder()
        let session = EditorAssistantSession(persistsConversation: false, provider: .claudeSonnet,
            nativeTransport: { input, url, provider in try await recorder.turn(input, url: url, provider: provider) })
        session.attach(to: editor); session.attachAutomation(endpoint)
        let longInstruction = "A native conversation retains this message: " + String(repeating: "user words ", count: 3000) + "."
        session.instruction = longInstruction
        session.submit(editor: editor, playhead: 9, regionID: nil, editID: nil)
        try await wait(session)
        try require(session.errorMessage == nil && session.notice == "Native reply 1", "natural native result appears in conversation")
        var state = editor.project.state; state.cursorStyle.size = 2
        try require(editor.commit(state, name: "Manual pointer size"), "manual edit")
        var draft = editor.project.state; draft.presentation.padding = 0.1
        try require(editor.updateDraft(draft, at: 9), "manual draft")
        let history = editor.project.undoHistory.count
        session.instruction = "Yes, the picture in picture."
        session.submit(editor: editor, playhead: 10, regionID: nil, editID: nil)
        try await wait(session)
        let calls = await recorder.values()
        try require(calls.count == 2, "one native turn per user message")
        let first = try JSONSerialization.jsonObject(with: calls[0]) as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: calls[1]) as! [String: Any]
        try require(first["text"] as? String == longInstruction, "new utterances are not truncated by an app context budget")
        try require(first["messages"] == nil && first["tools"] == nil && second["messages"] == nil,
            "the editor never reconstructs model conversation or a command schema")
        try require(second["text"] as? String == "Yes, the picture in picture.", "only the new literal followup is submitted")
        let events = second["editor_events"] as! [[String: Any]]
        try require(events.contains { ($0["names"] as? [String])?.contains("Manual pointer size") == true }, "actual manual changes reach native session")
        try require(editor.draftState == draft && editor.project.undoHistory.count == history, "conversation submission does not save or alter an unfinished edit")
        let page = try session.conversationPage(offset: 0, limit: 2)
        try require((page["exchanges"] as? [Any])?.count == 2, "prior dialogue is queryable as complete exchanges")
        _ = editor.cancelDraft()
        var framed = editor.project.state
        let existing = ZoomKeyframe(time: 5, scale: 2, transition: .smooth, duration: 3)
        framed.zoomKeyframes = [existing]
        try require(editor.commit(framed, name: "Existing zoom"), "prepare conflict")
        let revision = try EditorCommandDispatcher.revision(for: editor.project)
        let batch = EditorCommandBatch(projectID: editor.automationID, revision: revision,
            commands: [.mutate(.zoomScreen(scale: 3, center: nil, timing: .init(start: 3, end: 6)))])
        let conflict = EditorFramingConflict(proposal: batch, summary: "New zoom", framingIDs: [existing.id],
            question: "Replace the existing zoom, or keep it?")
        let prepared = try EditorCommandDispatcher.prepare(conflict.replacement, for: editor.project, projectID: editor.automationID)
        let beforeReview = editor.project
        let reviewID = UUID()
        var choices = [String]()
        session.presentNativeConflict(id: reviewID, conflict: conflict,
            context: try EditorCommandDispatcher.context(editor: editor, projectID: editor.automationID),
            preparedState: prepared) { choice in
                choices.append(choice)
                return try JSONSerialization.data(withJSONObject: ["ok": true, "result": ["choice": choice]])
            }
        try require(session.conflictReview != nil && session.conflictReviewID == reviewID && session.awaitsClarification,
            "native conflict exposes the existing visual review and choices")
        try require(editor.project == beforeReview, "presenting native review does not mutate or save")
        try require(session.resolveConflict(.existing, editor: editor, reviewID: reviewID), "native Existing button resolves through host callback")
        try require(choices == ["keep"] && session.conflictReview == nil && !session.awaitsClarification,
            "native choice uses frozen identity and clears selection/question state")
        try require(editor.project == beforeReview, "keeping native proposal leaves document/history untouched")
        let archiveURL = folder.appendingPathComponent("scoped-conversation.json")
        let archive = DirectorConversation(storageURL: archiveURL, recordingID: editor.automationID)
        archive.begin("This conversation belongs to the original recording.", requestID: UUID())
        try require(archive.save(), "save identified conversation")
        try require(DirectorConversation(storageURL: archiveURL, recordingID: editor.automationID).exchanges.count == 1,
            "reopening the same recording retains visible dialogue")
        try require(DirectorConversation(storageURL: archiveURL, recordingID: UUID()).exchanges.isEmpty,
            "replacing a recording at the same path does not expose its previous dialogue through MCP")
        let visibleLog = DirectorConversation()
        visibleLog.event(["kind": "edit", "actor": "automation", "names": ["Expand camera"]])
        let rows = DirectorTranscript.entries(in: visibleLog, references: editor.references)
        try require(rows.last?.text == "Applied: Expand camera", "native tool effects are not mislabeled as manual edits")
        let failed = EditorAssistantSession(provider: .claudeSonnet, nativeTransport: { _, _, _ in
            try JSONSerialization.data(withJSONObject: ["ok": false, "native_session_id": "known-failed-session",
                "text": "Reconnect the editor.", "error": ["code": "tool_runtime_unavailable", "message": "Native tool runtime is unavailable."],
                "events": []])
        })
        failed.attach(to: editor); failed.attachAutomation(endpoint)
        failed.instruction = "Expand the camera."
        failed.submit(editor: editor, playhead: 9, regionID: nil, editID: nil)
        try await wait(failed)
        let failedRows = DirectorTranscript.entries(in: failed.conversation, references: editor.references)
        try require(failed.errorMessage == "Native tool runtime is unavailable." && failed.notice == nil &&
            failedRows.last?.text == failed.errorMessage, "infrastructure failure shows its actual cause instead of misleading model prose")
        try require(failed.instruction == "Expand the camera.", "failed native turn preserves the user's input")
        print("Native Director Session checks passed (new turns only, no app history reconstruction/truncation, actual manual events, natural replies and untouched drafts).")
    }
}
