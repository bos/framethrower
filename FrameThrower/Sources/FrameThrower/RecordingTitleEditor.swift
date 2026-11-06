import AppKit
import SwiftUI

/// Undo controls keep the active text editor alive until their command runs.
/// Each marker follows its real native view rather than a toolbar label or a
/// guessed coordinate, and the registry never retains its owning window.
struct EditorTextUndoTarget: NSViewRepresentable {
    func makeNSView(context: Context) -> EditorTextUndoTargetView { EditorTextUndoTargetView() }
    func updateNSView(_ view: EditorTextUndoTargetView, context: Context) { }
    static func dismantleNSView(_ view: EditorTextUndoTargetView, coordinator: ()) { EditorTextUndoTargets.remove(view) }
}

@MainActor
final class EditorTextUndoTargetView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        EditorTextUndoTargets.add(self)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private enum EditorTextUndoTargets {
    private static let views = NSHashTable<EditorTextUndoTargetView>.weakObjects()
    static func add(_ view: EditorTextUndoTargetView) { views.add(view) }
    static func remove(_ view: EditorTextUndoTargetView) { views.remove(view) }
    static func contains(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return views.allObjects.contains { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor &&
                view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}

/// A single click renames; an initial double click opens the recording. Once
/// editing, normal native text selection and keyboard behavior remain intact.
struct RecordingTitleEditor: NSViewRepresentable {
    @ObservedObject var editor: ProjectEditor
    @Environment(\.isEnabled) private var isEnabled
    var renameRequest: UUID?
    var font: NSFont = .systemFont(ofSize: 12, weight: .medium)
    var onOpen: (() -> Void)? = nil
    var onBeginEditing: (() -> Void)? = nil
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onRenameError: ((String?) -> Void)? = nil

    func makeNSView(context: Context) -> RecordingTitleField {
        let field = RecordingTitleField()
        configure(field)
        return field
    }

    func updateNSView(_ field: RecordingTitleField, context: Context) {
        configure(field)
        field.requestRename(renameRequest)
    }

    private func configure(_ field: RecordingTitleField) {
        field.font = font
        field.isEnabled = isEnabled
        field.setTitle(editor.displayName)
        field.onOpen = onOpen
        field.onBeginEditing = onBeginEditing
        field.onEditingChanged = onEditingChanged
        field.onCancel = {
            editor.dismissError()
            onRenameError?(nil)
        }
        field.onRename = { title in
            let succeeded = editor.rename(to: title)
            onRenameError?(succeeded ? nil : editor.errorMessage)
            return succeeded ? editor.displayName : nil
        }
        field.toolTip = editor.errorMessage ?? (onOpen == nil ? "Click to rename this recording." : "Click the name to rename. Double-click to edit the recording.")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecordingTitleField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 220, height: 24)
    }
}

@MainActor
final class RecordingTitleField: NSTextField, NSTextFieldDelegate {
    var onOpen: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onRename: ((String) -> String?)?
    private(set) var isRenaming = false
    private var committedTitle = ""
    private var pendingRename: Task<Void, Never>?
    private var lastRenameRequest: UUID?
    private let cancellationEvents = RenameCancellationEvents()
    let clearButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = RecordingTitleCell(textCell: "")
        delegate = self
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel("Recording name")
        setAccessibilityHelp("Click to rename. Return saves; Escape or clicking outside cancels.")
        setAccessibilityRole(.textField)
        setAccessibilitySubrole(nil)
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear recording name")
        clearButton.imagePosition = .imageOnly
        clearButton.imageScaling = .scaleProportionallyDown
        clearButton.isBordered = false
        clearButton.refusesFirstResponder = true
        clearButton.focusRingType = .none
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clearDraft(_:))
        clearButton.setAccessibilityLabel("Clear recording name")
        clearButton.toolTip = "Clear the name."
        clearButton.isHidden = true
        addSubview(clearButton)
    }

    required init?(coder: NSCoder) { nil }
    deinit { pendingRename?.cancel() }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    override func layout() {
        super.layout()
        clearButton.frame = CGRect(x: max(0, bounds.width - 22), y: (bounds.height - 20) / 2, width: 20, height: 20)
    }

    func setTitle(_ title: String) {
        committedTitle = title
        if !isRenaming, stringValue != title { stringValue = title }
    }

    func requestRename(_ request: UUID?) {
        guard let request, request != lastRenameRequest else { return }
        lastRenameRequest = request
        pendingRename?.cancel()
        installCancellationEvents()
        pendingRename = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.beginRenaming()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if isRenaming { super.mouseDown(with: event); return }
        pendingRename?.cancel()
        if event.clickCount >= 2, let onOpen {
            pendingRename = nil
            cancellationEvents.stop()
            onOpen()
        } else {
            // Keep the initial label in place for the system's double-click
            // interval, so a second click can open instead of selecting text.
            let delay = onOpen == nil ? 0 : NSEvent.doubleClickInterval
            installCancellationEvents()
            pendingRename = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.beginRenaming()
            }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        beginRenaming()
        return true
    }

    func beginRenaming() {
        guard isEnabled, !isRenaming, window != nil else { return }
        pendingRename?.cancel()
        pendingRename = nil
        onBeginEditing?()
        isRenaming = true
        onEditingChanged?(true)
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        focusRingType = .default
        (cell as? RecordingTitleCell)?.showsClearButton = true
        clearButton.isHidden = false
        clearButton.isEnabled = isEnabled
        setAccessibilityChildren([clearButton])
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(self)
        if let text = currentEditor() as? NSTextView {
            text.allowsUndo = true
            text.selectAll(nil)
        }
        installCancellationEvents()
    }

    private func finishRenaming(commit: Bool, resignFocus: Bool = true) {
        guard isRenaming else { return }
        let draft = stringValue
        if commit {
            if let renamed = onRename?(draft) { committedTitle = renamed }
            else if resignFocus { return } // Keep an invalid submitted draft editable.
        }
        isRenaming = false
        cancellationEvents.stop()
        (cell as? RecordingTitleCell)?.showsClearButton = false
        clearButton.isHidden = true
        setAccessibilityChildren([])
        stringValue = committedTitle
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        if resignFocus { window?.makeFirstResponder(nil) }
        if !commit { onCancel?() }
        // Keep row removal hidden until the click that cancelled this draft has
        // finished dispatching. Otherwise that same click could hit the newly
        // revealed remove button. The outside event itself is forwarded.
        Task { @MainActor [weak self] in
            guard let self, !self.isRenaming else { return }
            self.onEditingChanged?(false)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishRenaming(commit: false, resignFocus: false) }

    @objc func clearDraft(_ sender: Any?) {
        guard isEnabled, isRenaming else { return }
        if let text = currentEditor() as? NSTextView {
            guard !text.string.isEmpty else { return }
            text.breakUndoCoalescing()
            text.insertText("", replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
            text.breakUndoCoalescing()
            text.undoManager?.setActionName("Clear name")
            text.setSelectedRange(NSRange(location: 0, length: 0))
        } else { stringValue = "" }
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        if isRenaming || pendingRename != nil { cancelRenaming() }
        else { super.cancelOperation(sender) }
    }

    /// Called before native event dispatch, including clicks on backgrounds
    /// which never become first responder and therefore do not end text editing.
    func cancelForOutsideClick(_ event: NSEvent) {
        guard isRenaming || pendingRename != nil else { return }
        // Menu-bar tracking has no app window. Preserve active name editing
        // so Edit commands and Save can act on that text. Switching apps or
        // windows still cancels through the existing deactivation observers.
        if event.window == nil {
            if !isRenaming { cancelRenaming() }
            return
        }
        if isRenaming, EditorTextUndoTargets.contains(event) { return }
        if event.window === window, bounds.contains(convert(event.locationInWindow, from: nil)) { return }
        cancelRenaming()
    }

    private func cancelRenaming() {
        pendingRename?.cancel()
        pendingRename = nil
        if isRenaming { finishRenaming(commit: false) }
        else { cancellationEvents.stop() }
    }

    private func installCancellationEvents() {
        cancellationEvents.stop()
        cancellationEvents.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                if event.type == .keyDown {
                    if event.keyCode == 53 { self?.cancelRenaming(); return true }
                } else { self?.cancelForOutsideClick(event) }
                return false
            }
            return consumed ? nil : event
        }
        if let window {
            cancellationEvents.observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelRenaming() } })
        }
        cancellationEvents.observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelRenaming() } })
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRenaming(commit: false)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // End-edit delegates are not guaranteed to have copied the field
            // editor's latest text until after this command has been handled.
            stringValue = textView.string
            finishRenaming(commit: true)
            return true
        }
        return false
    }
}

/// A plain title remains a plain text field when AppKit adopts it into a
/// toolbar. Reserve the trailing clear target only while the name is editable.
private final class RecordingTitleCell: NSTextFieldCell {
    var showsClearButton = false

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        if showsClearButton {
            result.origin.x += 6
            result.size.width = max(0, result.width - 34)
        }
        return result
    }
}

/// A text field owns Undo while its field editor is focused. Missing or empty
/// native history must never fall through into the recording's edit history.
@MainActor
enum EditorUndoRouting {
    private static func fieldEditor(in window: NSWindow?) -> NSTextView? {
        guard let text = (window ?? NSApplication.shared.keyWindow)?.firstResponder as? NSTextView,
              text.isFieldEditor else { return nil }
        return text
    }

    static func canUndo(editor: ProjectEditor, window: NSWindow? = nil) -> Bool {
        if let text = fieldEditor(in: window) { return text.undoManager?.canUndo ?? false }
        return editor.canUndo
    }

    static func canRedo(editor: ProjectEditor, window: NSWindow? = nil) -> Bool {
        if let text = fieldEditor(in: window) { return text.undoManager?.canRedo ?? false }
        return editor.canRedo
    }

    static func undoName(editor: ProjectEditor, window: NSWindow? = nil) -> String {
        if let text = fieldEditor(in: window) { return text.undoManager?.undoActionName ?? "" }
        return editor.undoName
    }

    static func redoName(editor: ProjectEditor, window: NSWindow? = nil) -> String {
        if let text = fieldEditor(in: window) { return text.undoManager?.redoActionName ?? "" }
        return editor.redoName
    }

    @discardableResult
    static func undo(editor: ProjectEditor, window: NSWindow? = nil) -> Bool {
        if let text = fieldEditor(in: window) {
            guard let manager = text.undoManager, manager.canUndo else { return false }
            manager.undo()
            return true
        }
        return editor.undo()
    }

    @discardableResult
    static func redo(editor: ProjectEditor, window: NSWindow? = nil) -> Bool {
        if let text = fieldEditor(in: window) {
            guard let manager = text.undoManager, manager.canRedo else { return false }
            manager.redo()
            return true
        }
        return editor.redo()
    }
}

@MainActor
enum EditorSaveRouting {
    @discardableResult
    static func save(editor: ProjectEditor, window: NSWindow? = nil) -> Bool {
        if let text = (window ?? NSApplication.shared.keyWindow)?.firstResponder as? NSTextView,
           text.isFieldEditor, let field = text.delegate as? NSTextField {
            _ = field.delegate?.control?(field, textView: text,
                doCommandBy: #selector(NSResponder.insertNewline(_:)))
            // Invalid submitted names remain editable and must not be
            // silently omitted from a Save command.
            if let title = field as? RecordingTitleField, title.isRenaming { return false }
        }
        return editor.save()
    }
}


/// Registration and removal occur on the main actor; the opaque handles can be
/// retained for cleanup after AppKit releases its view from a nonisolated path.
private final class RenameCancellationEvents: @unchecked Sendable {
    var monitor: Any?
    var observers: [any NSObjectProtocol] = []

    @MainActor func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    deinit {
        let cleanup = RenameCancellationCleanup(monitor: monitor, observers: observers)
        Task { @MainActor in cleanup.remove() }
    }
}

private struct RenameCancellationCleanup: @unchecked Sendable {
    let monitor: Any?
    let observers: [any NSObjectProtocol]

    @MainActor func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
