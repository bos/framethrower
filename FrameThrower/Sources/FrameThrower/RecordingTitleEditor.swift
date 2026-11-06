import AppKit
import SwiftUI

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
final class RecordingTitleField: NSSearchField, NSSearchFieldDelegate {
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
        (cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        maximumRecents = 0
        sendsWholeSearchString = true
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
    }

    required init?(coder: NSCoder) { nil }
    deinit { pendingRename?.cancel() }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

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
        if let searchCell = cell as? NSSearchFieldCell {
            searchCell.resetCancelButtonCell()
            searchCell.cancelButtonCell?.target = self
            searchCell.cancelButtonCell?.action = #selector(clearDraft(_:))
            searchCell.cancelButtonCell?.setAccessibilityLabel("Clear recording name")
        }
        window?.makeFirstResponder(self)
        (currentEditor() as? NSTextView)?.selectAll(nil)
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
        (cell as? NSSearchFieldCell)?.cancelButtonCell = nil
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
        stringValue = ""
        if let text = currentEditor() as? NSTextView {
            text.string = ""
            text.setSelectedRange(NSRange(location: 0, length: 0))
        }
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
