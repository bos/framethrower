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
        let originalName = editor.displayName
        let field = RecordingTitleField(frame: CGRect(x: 10, y: 45, width: 300, height: 24))
        field.setTitle(originalName)
        var opened = 0
        var began = 0
        var editingChanges: [Bool] = []
        field.onOpen = { opened += 1 }
        field.onBeginEditing = { began += 1 }
        field.onEditingChanged = { editingChanges.append($0) }
        field.onCancel = { editor.dismissError() }
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
        try await waitForSingleClick()
        try require(opened == 1 && !field.isRenaming && began == 0 && !editor.canUndo,
                    "double-click opens once without beginning a rename or mutating the recording")

        field.mouseDown(with: click(count: 1, field: field, window: window))
        field.cancelForOutsideClick(backgroundClick(window))
        try await waitForSingleClick()
        try require(!field.isRenaming && began == 0, "an outside click cancels a pending single-click rename")
        field.mouseDown(with: click(count: 1, field: field, window: window))
        field.cancelOperation(nil)
        try await waitForSingleClick()
        try require(!field.isRenaming && began == 0, "Escape cancels a pending single-click rename")

        field.mouseDown(with: click(count: 1, field: field, window: window))
        try await waitForSingleClick()
        try require(field.isRenaming && began == 1 && editingChanges == [true], "single-click begins native inline editing and reports its state")
        var text = try nativeEditor(field)
        text.string = "Dinner demo"
        _ = field.control(field, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        await settle()
        try require(!field.isRenaming && editor.displayName == "Dinner demo" && editingChanges == [true, false], "Return commits the recording name and reports editing ended")
        try require(editor.undoName == "Rename recording" && editor.project.undoHistory.count == 1,
                    "one title edit is one durable undo step")
        try require(try ProjectEditor.open(url: editor.url).displayName == "Dinner demo", "name survives reopening")

        field.beginRenaming()
        text = try nativeEditor(field)
        text.string = "Draft to clear"
        field.stringValue = text.string
        guard let searchCell = field.cell as? NSSearchFieldCell,
              let clear = searchCell.cancelButtonCell, let action = clear.action else {
            throw TitleCheckError.failed("native clear button missing")
        }
        try require(searchCell.searchButtonCell == nil && clear.target === field, "rename exposes only the native inside clear control")
        try require(NSApplication.shared.sendAction(action, to: clear.target, from: field), "native clear action is connected")
        try require(field.isRenaming && field.stringValue.isEmpty && text.string.isEmpty && field.currentEditor() === text,
                    "inside X clears only the draft and retains editing focus")
        text.string = "Uncommitted draft"
        _ = field.control(field, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        await settle()
        try require(!field.isRenaming && field.stringValue == "Dinner demo" && editor.project.undoHistory.count == 1,
                    "Escape restores the name without adding history")

        field.beginRenaming()
        text = try nativeEditor(field)
        text.string = "Background draft"
        field.stringValue = text.string
        field.cancelForOutsideClick(click(count: 1, field: field, window: window))
        try require(field.isRenaming, "a click inside the text box does not cancel")
        field.cancelForOutsideClick(backgroundClick(window))
        await settle()
        try require(!field.isRenaming && field.stringValue == "Dinner demo" && editor.project.undoHistory.count == 1,
                    "nonfocusable background click cancels the draft without saving or history")

        field.beginRenaming()
        text = try nativeEditor(field)
        text.string = "Focus transfer"
        field.stringValue = text.string
        window.makeFirstResponder(other)
        await settle()
        try require(editor.displayName == "Dinner demo" && !field.isRenaming && editor.project.undoHistory.count == 1,
                    "moving focus cancels the draft")
        try require((window.firstResponder as? NSTextView)?.delegate === other,
                    "cancelling the old name does not steal focus from the next input")

        for notification in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            field.beginRenaming()
            text = try nativeEditor(field)
            text.string = "Deactivated draft"
            NotificationCenter.default.post(name: notification, object: notification == NSWindow.didResignKeyNotification ? window : NSApplication.shared)
            await settle()
            try require(!field.isRenaming && field.stringValue == "Dinner demo", "window/app deactivation cancels the draft")
        }

        field.beginRenaming()
        text = try nativeEditor(field)
        text.string = "   "
        _ = field.control(field, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try require(field.isRenaming && field.stringValue == "   " && editor.displayName == "Dinner demo" && editor.errorMessage != nil,
                    "invalid Return keeps its draft editable and preserves the saved name")
        field.cancelOperation(nil)
        await settle()
        try require(editor.errorMessage == nil && editor.project.undoHistory.count == 1,
                    "cancelling invalid draft dismisses the validation error without adding history")
        try require(editingChanges.count % 2 == 0 && editingChanges.enumerated().allSatisfy { $0.element == ($0.offset % 2 == 0) },
                    "every rename begin has one matching end callback")

        field.isEnabled = false
        field.beginRenaming()
        field.mouseDown(with: click(count: 1, field: field, window: window))
        field.mouseDown(with: click(count: 2, field: field, window: window))
        try await waitForSingleClick()
        try require(!field.isRenaming && opened == 1 && !field.accessibilityPerformPress(), "disabled recording titles cannot rename or open")
        try require(editor.undo() && editor.displayName == originalName, "undo restores the prior recording name")
        try require(editor.redo() && editor.displayName == "Dinner demo", "redo restores the renamed recording")
        try require(try Data(contentsOf: source) == bytes, "renaming never alters original media")
        print("Recording title checks passed (Enter saves; Escape/outside/focus/deactivation cancel; inside clear; pending clicks; state callbacks; undo/redo; source preservation).")
    }

    private static func nativeEditor(_ field: RecordingTitleField) throws -> NSTextView {
        guard let text = field.currentEditor() as? NSTextView else { throw TitleCheckError.failed("native field editor was not focused") }
        return text
    }
    private static func waitForSingleClick() async throws { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.03)) }
    private static func settle() async { try? await Task.sleep(for: .milliseconds(20)) }
    private static func backgroundClick(_ window: NSWindow) -> NSEvent { mouseEvent(at: CGPoint(x: 315, y: 90), window: window) }
    private static func click(count: Int, field: NSView, window: NSWindow) -> NSEvent {
        mouseEvent(at: field.convert(CGPoint(x: 20, y: 12), to: nil), window: window, count: count)
    }
    private static func mouseEvent(at location: CGPoint, window: NSWindow, count: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: count, clickCount: count, pressure: 1)!
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TitleCheckError.failed(message) }
    }
}
