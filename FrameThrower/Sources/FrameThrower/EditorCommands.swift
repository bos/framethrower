import AppKit
import Combine
import SwiftUI

struct EditorFileCommands: Commands {
    @FocusedValue(\.editorFileActions) private var actions

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Fit Timeline") { actions?.fitTimeline?() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(actions?.fitTimeline == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Save Recording") { actions?.saveProject() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(actions == nil || actions?.isBusy == true)
            Button("Save Video…") { actions?.saveVideo() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(MediaProcessing.isSuspended || actions == nil || actions?.isBusy == true)
            Button("Share Video…") { actions?.shareVideo() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(MediaProcessing.isSuspended || actions == nil || actions?.isBusy == true)
            Divider()
            Button("Rename Recording…") { actions?.rename?() }
                .disabled(actions?.rename == nil || actions?.isBusy == true)
        }
    }
}

struct ProjectEditingCommands: Commands {
    @FocusedObject private var editor: ProjectEditor?
    @FocusedObject private var library: RecordingLibrary?

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            if let editor { ProjectUndoMenu(editor: editor) }
            else if let library {
                Button(library.canUndoRemoval ? "Undo Remove Recording" : "Undo") { _ = library.restoreLastRemoved() }
                    .keyboardShortcut("z", modifiers: .command).disabled(!library.canUndoRemoval)
                Button("Redo") { }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(true)
            } else {
                Button("Undo") { }.keyboardShortcut("z", modifiers: .command).disabled(true)
                Button("Redo") { }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(true)
            }
        }
    }
}

private struct ProjectUndoMenu: View {
    @ObservedObject var editor: ProjectEditor
    @State private var textRevision = 0

    var body: some View {
        let _ = textRevision
        Group {
            Button(EditorUndoRouting.canUndo(editor: editor) ? "Undo " + EditorUndoRouting.undoName(editor: editor) : "Undo") {
                EditorUndoRouting.undo(editor: editor)
            }
            .keyboardShortcut("z", modifiers: .command).disabled(!EditorUndoRouting.canUndo(editor: editor))
            Button(EditorUndoRouting.canRedo(editor: editor) ? "Redo " + EditorUndoRouting.redoName(editor: editor) : "Redo") {
                EditorUndoRouting.redo(editor: editor)
            }
            .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!EditorUndoRouting.canRedo(editor: editor))
        }
        .onReceive(Publishers.MergeMany([
            NSControl.textDidBeginEditingNotification, NSControl.textDidChangeNotification,
            NSControl.textDidEndEditingNotification, Notification.Name.NSUndoManagerDidUndoChange,
            Notification.Name.NSUndoManagerDidRedoChange, Notification.Name.NSUndoManagerDidCloseUndoGroup
        ].map { NotificationCenter.default.publisher(for: $0) })) { _ in textRevision &+= 1 }
    }
}
