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
        let session = EditorAssistantSession(transport: { _ in throw Failure.failed("No local request expected") })
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
        print("Assistant panel layout checks passed (single instruction field, no automatic note field, content-sized guide rows, preserved instruction text, and durable box references; no microphone/model/media activity).")
    }

    static func checkSingleComposer(_ host: NSView) throws {
        let fields = all(NSTextField.self, in: host)
        try require(fields.count == 1 && fields[0].placeholderString == "What would you like to change?",
                    "Only the instruction composer should appear; optional box naming must remain hidden")
    }
    static func checkList(_ host: NSView, expectedHeight: CGFloat) throws {
        let areas = all(NSScrollView.self, in: host)
        try require(areas.count == 1 && abs(areas[0].frame.height - expectedHeight) < 1,
                    "Guide list must fit its rows without a large empty region")
    }
    static func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
    }
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
    }
}
