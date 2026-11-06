import AppKit
import SwiftUI

/// Keep a failed draft save visible instead of allowing its window to close.
struct EditorDraftLifecycle: NSViewRepresentable {
    let editor: ProjectEditor

    func makeNSView(context: Context) -> EditorDraftLifecycleView {
        let view = EditorDraftLifecycleView()
        view.editor = editor
        return view
    }

    func updateNSView(_ view: EditorDraftLifecycleView, context: Context) {
        view.editor = editor
        view.attach()
    }

    static func dismantleNSView(_ view: EditorDraftLifecycleView, coordinator: ()) { view.detach() }
}

@MainActor
final class EditorDraftLifecycleView: NSView {
    var editor: ProjectEditor? { didSet { proxy?.editor = editor } }
    private weak var attachedWindow: NSWindow?
    private var proxy: EditorDraftWindowDelegate?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    func attach() {
        guard let window else { detach(); return }
        if attachedWindow === window, window.delegate === proxy { return }
        detach()
        let proxy = EditorDraftWindowDelegate(editor: editor, original: window.delegate)
        self.proxy = proxy
        attachedWindow = window
        window.delegate = proxy
    }

    func detach() {
        if let attachedWindow, attachedWindow.delegate === proxy { attachedWindow.delegate = proxy?.original }
        attachedWindow = nil
        proxy = nil
    }
}

@MainActor
final class EditorDraftWindowDelegate: NSObject, NSWindowDelegate {
    var editor: ProjectEditor?
    weak var original: (any NSWindowDelegate)?

    init(editor: ProjectEditor?, original: (any NSWindowDelegate)?) {
        self.editor = editor
        self.original = original
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) ?? true else { return false }
        return editor?.finishDraft() ?? true
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return MainActor.assumeIsolated { original?.responds(to: aSelector) ?? false }
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        MainActor.assumeIsolated {
            DelegateForwardTarget(value: original.flatMap { $0.responds(to: aSelector) ? $0 : nil })
        }.value
    }
}

// Objective-C asks for a forwarding object through a nonisolated NSObject API;
// AppKit invokes it on the main thread alongside the delegate itself.
private struct DelegateForwardTarget: @unchecked Sendable { let value: Any? }

/// Termination occurs before SwiftUI window teardown; a failed draft save must
/// veto Quit while its editor and error are still available to the user.
@MainActor
final class EditorDraftApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationReply(for: sender.windows)
    }

    func terminationReply(for windows: [NSWindow]) -> NSApplication.TerminateReply {
        for window in windows {
            if let delegate = window.delegate as? EditorDraftWindowDelegate,
               let editor = delegate.editor, !editor.finishDraft() { return .terminateCancel }
        }
        return .terminateNow
    }
}
