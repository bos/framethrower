import AppKit
import SwiftUI

private struct RecordingActionProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("record-action")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@main
@MainActor
struct CaptureRecordingControlsChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        _ = NSApplication.shared
        for width in [252.0, 280.0] {
            var previousHeight: CGFloat?
            for quality in RecordingQuality.allCases {
                let controls = CaptureRecordingSetup(quality: .constant(quality),
                    details: CaptureRecordingDetails(quality: quality, width: 1900, height: 1736),
                    status: MediaProcessing.statusMessage, isRecording: false, isLocked: false,
                    recordingStartedAt: nil) {
                        RecordingActionProbe().frame(maxWidth: .infinity).frame(height: 48)
                    }
                let host = NSHostingView(rootView: controls.frame(width: width))
                let size = CGSize(width: width, height: host.fittingSize.height)
                let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                guard let action = findAction(in: host) else { throw Failure.failed("Missing recording action") }
                let frame = host.convert(action.bounds, from: action)
                try require(abs(frame.minX - 14) < 1 && abs(frame.width - (width - 28)) < 1,
                    "Record must align to both content edges at \(width)pt")
                try require(host.fittingSize.height < 230, "Capture block must stay compact")
                if let previousHeight {
                    try require(abs(previousHeight - host.fittingSize.height) < 1,
                        "Switching recording quality must not collapse details or move library")
                }
                previousHeight = host.fittingSize.height
                window.close()
            }
        }
        try await checkTitle()
        print("Capture recording controls checks passed (compact aligned block at narrow/default widths, stable quality details, and pending-title Return/Escape/outside behavior; no device/media activity).")
    }

    static func checkTitle() async throws {
        var chosenName = PendingRecordingName()
        let field = RecordingTitleField(frame: CGRect(x: 10, y: 45, width: 260, height: 24))
        field.setTitle(chosenName.displayName)
        field.onRename = { text in
            do { try chosenName.rename(to: text); return chosenName.displayName }
            catch { return nil }
        }
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 280, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 100))
        content.addSubview(field)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try require(!field.isBezeled && !field.drawsBackground, "Title must be plain at rest")
        field.beginRenaming()
        let text = try nativeEditor(field)
        try require(field.isBezeled && field.drawsBackground && !field.clearButton.isHidden,
            "Only active rename must show a field and its clear button")
        let drawing = field.cell!.drawingRect(forBounds: field.bounds)
        try require(drawing.minX > 0 && drawing.maxX <= field.clearButton.frame.minX,
            "Editable title needs native left padding and clear-button space")
        text.string = "Morning demo"
        field.stringValue = text.string
        _ = field.control(field, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(20))
        try require(chosenName.title == "Morning demo" && !field.isRenaming,
            "Return must save the next recording title")
        field.beginRenaming()
        let draft = try nativeEditor(field)
        draft.string = "Unsubmitted title"
        field.stringValue = draft.string
        let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 3, y: 3),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        field.cancelForOutsideClick(outside)
        try await Task.sleep(for: .milliseconds(20))
        try require(chosenName.title == "Morning demo" && field.stringValue == "Morning demo" && !field.isRenaming,
            "Clicking Record/outside cancels only the unsubmitted draft, retaining the saved custom title")
        field.beginRenaming()
        let canceled = try nativeEditor(field)
        canceled.string = "Canceled title"
        field.stringValue = canceled.string
        field.cancelOperation(nil)
        try await Task.sleep(for: .milliseconds(20))
        try require(chosenName.title == "Morning demo" && !field.isRenaming && !field.isBezeled && !field.drawsBackground,
            "Escape must restore the plain saved title")
    }

    static func nativeEditor(_ field: RecordingTitleField) throws -> NSTextView {
        guard let editor = field.currentEditor() as? NSTextView else { throw Failure.failed("Missing native title editor") }
        return editor
    }

    static func findAction(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "record-action" { return view }
        for child in view.subviews { if let match = findAction(in: child) { return match } }
        return nil
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }
}
