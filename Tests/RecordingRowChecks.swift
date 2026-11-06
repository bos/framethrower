import AppKit
import SwiftUI

private enum RowCheckError: Error { case failed(String) }

/// Synthetic metadata and an offscreen native window only. No capture model,
/// screen permission, camera session, or video decoder is constructed.
@main
@MainActor
struct RecordingRowChecks {
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("screen.mp4")
        let sourceBytes = Data("immutable source fixture".utf8)
        try sourceBytes.write(to: source)
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "screen.mp4", duration: 5, title: "My recording"),
            url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "save fixture")
        let entry = RecordingLibraryEntry(projectURL: editor.url, sourceURL: source,
            displayName: editor.displayName, duration: 5, fileSize: Int64(sourceBytes.count), createdAt: Date())
        var removed = 0
        var opened = 0
        let host = NSHostingView(rootView: RecordingLibraryRow(entry: entry, isLocked: false,
            editorForURL: { _ in editor }, onOpen: { opened += 1 }, onShare: { false },
            shareContent: { AnyView(EmptyView()) }, onRemove: { removed += 1 })
            .frame(width: 280, height: 68))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 280, height: 68),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        guard let button: RecordingRemoveButtonView = find(in: host),
              let title: RecordingTitleField = find(in: host) else { throw RowCheckError.failed("native row controls") }
        try require(title.bounds.width >= 200, "narrow sidebar should reserve useful full-width name space")
        let down = mouse(.leftMouseDown, target: button, window: window, count: 1)
        try require(button.acceptsFirstMouse(for: down), "remove must accept the activating click in an inactive window")
        window.resignKey()
        let hit = host.hitTest(button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.superview))
        try require(hit === button, "the X must receive its hit directly instead of a focusable row wrapper")
        button.performClick(nil)
        try require(removed == 1 && opened == 0 && !title.isRenaming,
                    "one initial remove click must act once without selecting/opening/renaming the row")
        button.isEnabled = false
        button.performClick(nil)
        try require(removed == 1, "locked remove must not fire")
        button.isEnabled = true

        window.makeKey()
        for count in [1, 2] {
            window.sendEvent(mouse(.leftMouseDown, target: title, window: window, count: count))
            window.sendEvent(mouse(.leftMouseUp, target: title, window: window, count: count))
        }
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        try require(opened == 1 && removed == 1 && !title.isRenaming,
                    "double-clicking the name must open once without row background stealing or starting rename")
        try require(try Data(contentsOf: source) == sourceBytes && !editor.canUndo,
                    "row navigation/removal callbacks must not alter media or edit history")
        print("Recording row checks passed (280pt title width, inactive first-click acceptance, native remove dispatch, and integrated title double-click routing).")
    }

    private static func mouse(_ type: NSEvent.EventType, target: NSView, window: NSWindow, count: Int) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: count, clickCount: count, pressure: 1)!
    }

    private static func find<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(in: $0) as T? }.first
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw RowCheckError.failed(message) }
    }
}
