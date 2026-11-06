import AppKit
import Foundation

private enum LifecycleCheckError: Error { case failed(String) }

@MainActor
private final class OriginalWindowDelegate: NSObject, NSWindowDelegate {
    var permitsClose = true
    var closes = 0
    var moves = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { closes += 1; return permitsClose }
    func windowDidMove(_ notification: Notification) { moves += 1 }
}

@main
@MainActor
struct EditorDraftLifecycleChecks {
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidDirectory = directory.appendingPathComponent("missing")
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "screen.mp4", duration: 4),
                                   url: invalidDirectory.appendingPathComponent("test.framethrower"))
        let original = editor.project
        var next = original.state
        next.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2)]
        try require(editor.updateDraft(next, at: 2), "start pending draft")
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let prior = OriginalWindowDelegate()
        window.delegate = prior
        let guardView = EditorDraftLifecycleView()
        guardView.editor = editor
        window.contentView = guardView
        guardView.attach()
        defer { guardView.detach(); window.close() }
        guard let proxy = window.delegate as? EditorDraftWindowDelegate else { throw LifecycleCheckError.failed("guard not attached") }
        try require(!proxy.windowShouldClose(window), "failed save must veto close")
        try require(editor.draftState == next && editor.project == original && editor.errorMessage != nil,
                    "close failure must retain draft, baseline, history, and visible error")
        let app = EditorDraftApplicationDelegate()
        try require(app.terminationReply(for: [window]) == .terminateCancel,
                    "failed save must veto application termination")
        let moved = #selector(NSWindowDelegate.windowDidMove(_:))
        try require(proxy.responds(to: moved) && (proxy.forwardingTarget(for: moved) as AnyObject?) === prior,
                    "unhandled delegate methods must forward to the original delegate")
        window.delegate?.windowDidMove?(Notification(name: NSWindow.didMoveNotification, object: window))
        try require(prior.moves == 1, "native optional delegate dispatch must reach the original delegate")
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        prior.permitsClose = false
        try require(!proxy.windowShouldClose(window) && editor.draftState != nil,
                    "the original delegate may veto close without finalizing the draft")
        prior.permitsClose = true
        try require(proxy.windowShouldClose(window) && editor.draftState == nil && editor.project.undoHistory.count == 1,
                    "successful close saves one combined draft")
        try require(try ProjectEditor.open(url: editor.url).project.state == next, "close persists draft to disk")
        try require(app.terminationReply(for: [window]) == .terminateNow && editor.project.undoHistory.count == 1,
                    "normal quit after close check must not duplicate history")
        next.zoomKeyframes[0].scale = 2.5
        try require(editor.updateDraft(next, at: 2), "begin another pending edit before Quit")
        try require(app.terminationReply(for: [window]) == .terminateNow && editor.draftState == nil &&
                    editor.project.undoHistory.count == 2, "normal Quit saves its pending draft exactly once")
        guardView.detach()
        try require(window.delegate === prior, "detaching must restore the original window delegate")
        print("Editor draft lifecycle checks passed (failed-close/quit veto, retained draft/history/error, original delegate forwarding/veto, successful save, and delegate restoration).")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw LifecycleCheckError.failed(message) }
    }
}
