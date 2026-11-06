import AppKit
import Foundation

private enum TitleCheckError: Error { case failed(String) }

@main
@MainActor
struct RecordingTitleChecks {
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("screen.mp4")
        let bytes = Data("immutable recording source".utf8)
        try bytes.write(to: source)
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "screen.mp4", duration: 5),
                                   url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "save test recording")
        let field = RecordingTitleField(frame: CGRect(x: 10, y: 45, width: 300, height: 24))
        field.setTitle(editor.displayName)
        var opened = 0
        var began = 0
        field.onOpen = { opened += 1 }
        field.onBeginEditing = { began += 1 }
        field.onRename = { editor.rename(to: $0) ? editor.displayName : nil }
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 320, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        container.addSubview(field)
        let other = NSTextField(frame: CGRect(x: 10, y: 10, width: 300, height: 24))
        container.addSubview(other)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        field.mouseDown(with: click(count: 1, field: field, window: window))
        field.mouseDown(with: click(count: 2, field: field, window: window))
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.03))
        try require(opened == 1 && !field.isRenaming && began == 0 && !editor.canUndo,
                    "double-click must open once without beginning a rename or mutating the recording")

        field.mouseDown(with: click(count: 1, field: field, window: window))
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.03))
        try require(field.isRenaming && began == 1, "single-click name must begin native inline editing (began=\(began), editing=\(field.isRenaming), responder=\(String(describing: window.firstResponder)))")
        guard let text = window.fieldEditor(false, for: field) as? NSTextView else {
            throw TitleCheckError.failed("native field editor was not focused")
        }
        text.string = "Dinner demo"
        _ = field.control(field, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try require(!field.isRenaming && editor.displayName == "Dinner demo", "Enter commits the displayed recording name")
        try require(editor.undoName == "Rename recording" && editor.project.undoHistory.count == 1,
                    "one title edit must be one durable undo step")
        try require(try ProjectEditor.open(url: editor.url).displayName == "Dinner demo", "name must survive reopening")

        field.beginRenaming()
        text.string = "Uncommitted draft"
        _ = field.control(field, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try require(!field.isRenaming && field.stringValue == "Dinner demo" && editor.project.undoHistory.count == 1,
                    "Escape restores the name without adding history")

        field.beginRenaming()
        guard let editing = window.fieldEditor(false, for: field) as? NSTextView else {
            throw TitleCheckError.failed("native field editor missing before focus transfer")
        }
        editing.string = "Focus transfer"
        field.stringValue = editing.string
        window.makeFirstResponder(other)
        try await Task.sleep(for: .milliseconds(20))
        try require(editor.displayName == "Focus transfer" && !field.isRenaming,
                    "moving focus must commit the title")
        try require((window.firstResponder as? NSTextView)?.delegate === other,
                    "committing the old name must not steal focus from the next input")

        field.beginRenaming()
        guard let invalid = window.fieldEditor(false, for: field) as? NSTextView else {
            throw TitleCheckError.failed("native editor missing before validation")
        }
        invalid.string = "   "
        _ = field.control(field, textView: invalid, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try require(field.isRenaming && field.stringValue == "   " && editor.displayName == "Focus transfer",
                    "an invalid submitted name must keep its draft editable and preserve the saved name")
        _ = field.control(field, textView: invalid, doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        try require(editor.undo() && editor.displayName == "Dinner demo", "undo restores the prior recording name")
        try require(editor.redo() && editor.displayName == "Focus transfer", "redo restores the renamed recording")
        try require(try Data(contentsOf: source) == bytes, "renaming must never alter original media")
        print("Recording title checks passed (single/double click, native Enter/Escape/focus transfer, invalid drafts, persistent undo/redo, and source preservation).")
    }

    private static func click(count: Int, field: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown,
            location: field.convert(CGPoint(x: 20, y: 12), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: count, clickCount: count, pressure: 1)!
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TitleCheckError.failed(message) }
    }
}
