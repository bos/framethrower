import AppKit
import SwiftUI

/// Production session, views, and metadata. Every media access remains blocked;
/// nonexistent source filenames and empty native layers are intentional.
@main @MainActor
struct ConflictReviewInterfaceChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.failed(message) }
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Requires suspended media")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 12)
        project.state.zoomKeyframes = [ZoomKeyframe(time: 1, scale: 2, transition: .smooth, duration: 1)]
        let box1 = EditorRegion(time: 0, rect: .init(x: 0.1, y: 0.1, width: 0.25, height: 0.3))
        let box2 = EditorRegion(time: 0, rect: .init(x: 0.6, y: 0.5, width: 0.3, height: 0.3))
        project.state.regions = [box1, box2]
        project.ensureReferences()
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("review.framethrower"))
        let original = editor.project
        let session = EditorAssistantSession(transport: { payload in
            let root = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            let text = (root["messages"] as! [[String: Any]]).compactMap { $0["content"] as? String }
                .first { $0.hasPrefix("Current editor context") }!
            let body = text.split(separator: "\n", maxSplits: 1)[1]
            let context = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
            let recording = context["recording"] as! [String: Any]
            let args: [String: Any] = ["project_id": recording["projectID"]!, "expected_revision": recording["revision"]!,
                "from_box_label": "Box 1", "to_box_label": "Box 2", "start_delay_seconds": 0,
                "arrival_seconds": 3, "arrival_origin": "playhead", "path": "direct"]
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [[
                "id": "fixture_conflict", "type": "function", "function": ["name": "move_relative", "arguments":
                    String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]
            ]]]]]])
        })
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, directorModeInitiallyEnabled: false, assistant: session))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1200, height: 850),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { session.suspend(); window.close() }
        try await settle(host)
        guard let canvas = all(EditorCanvasView.self, in: host).first,
              let timeline = all(RecordingTimelineView.self, in: host).first else { throw Failure.failed("Production views missing") }
        let originalWindowFrame = window.frame
        session.instruction = "Pan from Box 1 to Box 2 over the next three seconds."
        session.submit(editor: editor, playhead: 0, regionID: nil, editID: nil)
        for _ in 0..<100 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        try await settle(host)
        guard let review = session.conflictReview else { throw Failure.failed("Pending comparison missing: " + (session.errorMessage ?? session.notice ?? "")) }
        try require(session.awaitsClarification && !session.isBusy && editor.project == original && !editor.canUndo,
                    "Review asks before applying and creates no project/history change")
        try require(canvas.conflictFrames.count == 2 && canvas.zoom == ZoomPlacement() && !canvas.allowsZoomEditing,
                    "Full-source preview exposes both framing outlines without gesture editing")
        try require(timeline.conflictSpans == review.existingSpans + review.proposedSpans &&
                    abs(timeline.playhead - review.inspectionTime) < 0.000001,
                    "The same conflict is visible on the timeline at a differing inspection frame")
        try require(window.frame == originalWindowFrame && timeline.frame.height == 72 &&
                    all(NSTextField.self, in: host).contains { $0.placeholderString == "Your answer…" },
                    "A conflict automatically reveals its question without resizing the window or timeline")
        // Opening the native inspector animates its column. Measure the
        // comparison after that reveal, then verify later scrubs stay fixed.
        try await Task.sleep(for: .milliseconds(400))
        try await settle(host)
        let comparisonPreviewFrame = canvas.frame
        let comparisonTimelineFrame = timeline.frame
        try require(canvas.playerLayer.player == nil && canvas.stillLayer.contents == nil,
                    "Conflict review cannot attach a video source while suspended")
        let firstOutlines = canvas.conflictOutlines
        timeline.onScrubBegan?(); timeline.onSeek?(2); timeline.onScrubEnded?()
        try await settle(host)
        try require(canvas.frame == comparisonPreviewFrame && timeline.frame == comparisonTimelineFrame,
                    "Scrubbing comparison cannot reallocate preview or timeline: before \(comparisonPreviewFrame) / \(comparisonTimelineFrame), after \(canvas.frame) / \(timeline.frame)")
        try require(canvas.conflictOutlines?.time == 2 && canvas.conflictOutlines != firstOutlines && editor.project == original && !editor.canUndo,
                    "Scrubbing compares the actual two curves without committing a movement")
        session.cancel()
        try await settle(host)
        try require(canvas.conflictOutlines == nil && canvas.conflictFrames.isEmpty && timeline.conflictSpans.isEmpty &&
                    timeline.conflictOverlaps.isEmpty && editor.project == original && !editor.canUndo,
                    "Dismiss restores ordinary inspection and clears every transient comparison")
        session.instruction = "Pan from Box 1 to Box 2 over the next three seconds."
        session.submit(editor: editor, playhead: 0, regionID: nil, editID: nil)
        for _ in 0..<100 where session.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        try await settle(host)
        try require(session.conflictReview != nil, "Reopen comparison for manual-edit lifecycle")
        var manual = editor.project.state
        manual.zoomKeyframes = [ZoomKeyframe(time: timeline.playhead, scale: 2.2)]
        try require(editor.updateDraft(manual, at: timeline.playhead), "Begin a manual zoom draft")
        try await settle(host)
        try require(session.conflictReview == nil && !session.awaitsClarification && canvas.conflictFrames.isEmpty &&
                    editor.draftState == manual && abs(canvas.zoom.scale - 2.2) < 0.000001 && editor.project == original,
                    "A manual edit leaves comparison mode and keeps its own preview/draft without applying the old proposal")
        _ = editor.cancelDraft()
        print("Conflict review interface checks passed (actual session, full-source outlines, linked source timeline, read-only scrub, dismissal, fixed geometry and media interlock).")
    }
    static func settle(_ host: NSView) async throws {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60)) }
    }
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
}
