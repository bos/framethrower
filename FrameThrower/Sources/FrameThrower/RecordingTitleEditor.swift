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
    var onRename: ((String) -> String?)?
    private(set) var isRenaming = false
    private var committedTitle = ""
    private var pendingRename: Task<Void, Never>?
    private var lastRenameRequest: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        setAccessibilityHelp("Click to rename this recording.")
    }

    required init?(coder: NSCoder) { nil }
    deinit { pendingRename?.cancel() }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }

    func setTitle(_ title: String) {
        committedTitle = title
        if !isRenaming { stringValue = title }
    }

    func requestRename(_ request: UUID?) {
        guard let request, request != lastRenameRequest else { return }
        lastRenameRequest = request
        pendingRename?.cancel()
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
            onOpen()
        } else {
            // Keep the initial label in place for the system's double-click
            // interval, so a second click can open instead of selecting text.
            let delay = onOpen == nil ? 0 : NSEvent.doubleClickInterval
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
        onBeginEditing?()
        isRenaming = true
        isEditable = true
        isSelectable = true
        isBezeled = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        focusRingType = .default
        window?.makeFirstResponder(self)
        (currentEditor() as? NSTextView)?.selectAll(nil)
    }

    private func finishRenaming(commit: Bool, resignFocus: Bool = true) {
        guard isRenaming else { return }
        let draft = stringValue
        if commit {
            if let renamed = onRename?(draft) { committedTitle = renamed }
            else if resignFocus { return } // Keep an invalid submitted draft editable.
        }
        isRenaming = false
        stringValue = committedTitle
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        if resignFocus { window?.makeFirstResponder(nil) }
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishRenaming(commit: true, resignFocus: false) }

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
