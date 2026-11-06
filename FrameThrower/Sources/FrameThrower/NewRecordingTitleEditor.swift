import AppKit
import SwiftUI

/// Uses the same native rename interactions as saved recordings: Return saves,
/// Escape or an outside click cancels, and the inline X clears the draft.
struct NewRecordingTitleEditor: NSViewRepresentable {
    @ObservedObject var model: CaptureViewModel
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> RecordingTitleField {
        let field = RecordingTitleField()
        configure(field)
        return field
    }

    func updateNSView(_ field: RecordingTitleField, context: Context) { configure(field) }

    private func configure(_ field: RecordingTitleField) {
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.isEnabled = isEnabled
        field.setTitle(model.nextRecordingName.displayName)
        field.onRename = { proposedName in
            model.renameNextRecording(to: proposedName) ? model.nextRecordingName.displayName : nil
        }
        field.onCancel = { model.dismissNextRecordingNameError() }
        field.toolTip = model.nextRecordingNameError ?? "Name the next recording. Return saves; Escape or clicking outside cancels. Clear the name for automatic naming."
        field.setAccessibilityLabel("New recording name")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecordingTitleField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 220, height: 24)
    }
}
