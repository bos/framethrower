import AppKit
import SwiftUI

/// Tests production controls in an offscreen window. No microphone, model,
/// video source, pixel buffer, or system accessibility grant is used.
@main
@MainActor
struct AssistantPanelLayoutChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        guard MediaProcessing.isSuspended else { throw Failure.failed("Requires media interlock") }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editID = UUID()
        let region = EditorRegion(time: 1, rect: EditorRegionRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), editID: editID)
        let other = EditorRegion(time: 3, rect: EditorRegionRect(x: 0.6, y: 0.5, width: 0.2, height: 0.3))
        var project = RecordingProject(screenFilename: "missing.mov", duration: 12)
        project.state.zoomKeyframes = [ZoomKeyframe(id: editID, time: 1, scale: 2)]
        project.state.regions = [region]
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
        let question = "How long should the movement take?"
        let session = EditorAssistantSession(transport: { _ in
            try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "tool_calls": [[
                "id": "layout_question", "type": "function", "function": ["name": "ask_clarification", "arguments": "{\"question\":\"How long should the movement take?\"}"]
            ]]]]]])
        })
        let panel = EditorAssistantPanel(editor: editor, session: session, selectedRegionID: region.id,
            onSelectRegion: { _ in }, onRemoveRegion: { _ in }, onSubmit: {})
        let host = NSHostingView(rootView: panel)
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 300, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close(); _ = editor.cancelDraft() }
        try await settle(host)
        try checkSingleComposer(host)
        try checkList(host, expectedHeight: 44)
        session.instruction = "At Edit A, frame Box 1."
        var state = editor.project.state
        state.regions.append(other)
        try require(editor.updateDraft(state, at: 3), "Create second guide without writing media")
        try await settle(host)
        try checkSingleComposer(host)
        try checkList(host, expectedHeight: 92)
        try require(all(NSTextField.self, in: host).first?.stringValue == session.instruction,
                    "Changing box selection/context cannot replace the current instruction")
        try require(editor.references.boxLabel(for: region.id) == "Box 1" && editor.references.boxLabel(for: other.id) == "Box 2",
                    "Both rows use distinct durable references")
        try require(editor.cancelDraft(), "Cancel metadata draft")
        try await settle(host)
        try checkList(host, expectedHeight: 44)
        try require(!session.isBusy, "Showing guides cannot submit an instruction")
        session.attach(to: editor)
        for index in 0..<12 {
            let id = UUID()
            session.conversation.begin("Instruction \(index): make this movement easy to follow while preserving the selected text area.", requestID: id)
            session.conversation.finish(requestID: id, response: nil,
                outcome: ["status": "applied", "summary": "Adjusted movement \(index) with a smooth acceleration and deceleration."])
        }
        session.instruction = "Can you improve this movement?"
        session.submit(editor: editor, playhead: 1, regionID: nil, editID: editID)
        for _ in 0..<20 where session.isBusy { try await Task.sleep(for: .milliseconds(20)) }
        try await settle(host)
        try require(session.awaitsClarification && session.notice == question && session.errorMessage == nil,
                    "The real session must expose the fake model's pending question")
        let composer = all(NSTextField.self, in: host)
        try require(composer.count == 1 && composer[0].placeholderString == "Your answer…" &&
                    host.bounds.contains(composer[0].convert(composer[0].bounds, to: host)),
                    "A long transcript must keep the one answer composer fully on screen at 300 by 600")
        let composerRect = composer[0].convert(composer[0].bounds, to: host)
        let bottomGap = host.isFlipped ? host.bounds.maxY - composerRect.maxY : composerRect.minY - host.bounds.minY
        try require((0...100).contains(bottomGap),
                    "The answer composer must remain anchored at the bottom of the panel, beside its microphone/send controls")
        try checkList(host, expectedHeight: 44)
        let transcript = try transcriptScroll(in: host, regionHeight: 44)
        try require(transcript.frame.height > 100 && (transcript.documentView?.bounds.height ?? 0) > transcript.contentView.bounds.height,
                    "Nonempty dialogue must scroll in its own bounded transcript rather than expanding the inspector")
        try atBottom(transcript, "The pending question at the end of a long transcript must be visible")
        session.conversation.event(["kind": "edit", "names": ["A new manual adjustment while following the latest conversation result"]])
        try await settle(host)
        try atBottom(transcript, "New transcript content must keep following the latest entry when already at the bottom")
        print("Assistant panel layout checks passed (single bottom-pinned composer, bounded reference list and nonempty conversation, visible pending question and follow-latest after append; user scrolling requires live interaction verification; no microphone/model/media activity).")
    }

    static func checkSingleComposer(_ host: NSView) throws {
        let fields = all(NSTextField.self, in: host)
        try require(fields.count == 1 && fields[0].placeholderString == "What would you like to change?",
                    "Only the instruction composer should appear; optional box naming must remain hidden")
    }
    static func checkList(_ host: NSView, expectedHeight: CGFloat) throws {
        let areas = all(NSScrollView.self, in: host)
        try require(areas.count == 2 && areas.filter { abs($0.frame.height - expectedHeight) < 1 }.count == 1,
                    "The reference list must fit its rows independently of the conversation scroll area")
    }
    static func transcriptScroll(in host: NSView, regionHeight: CGFloat) throws -> NSScrollView {
        guard let scroll = all(NSScrollView.self, in: host).first(where: { abs($0.frame.height - regionHeight) >= 1 }) else {
            throw Failure.failed("Conversation scroll area missing")
        }
        return scroll
    }
    static func atBottom(_ scroll: NSScrollView, _ message: String) throws {
        guard let document = scroll.documentView else { throw Failure.failed("Conversation document missing") }
        try require(scroll.documentVisibleRect.maxY >= document.bounds.maxY - 4,
                    message + " (visible=\(scroll.documentVisibleRect), document=\(document.bounds), flipped=\(document.isFlipped))")
    }
    static func settle(_ host: NSView) async throws {
        // A scroll-to-anchor request queued by layout must get its own native
        // turn, especially when this offscreen window has no display ticks.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
    }
}
