import SwiftUI

@main
struct FrameThrowerApp: App {
    @StateObject private var model = CaptureViewModel()

    var body: some Scene {
        Window("FrameThrower", id: "recorder") {
            ContentView(model: model)
        }
        .defaultSize(width: 740, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                if let editor = model.projectEditor { ProjectUndoMenu(editor: editor) }
            }
            CommandGroup(after: .newItem) {
                Button("Open FrameThrower Project…") { model.chooseProject() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isRecording || model.isCaptureBusy || model.isAnyUploadActive)
            }
        }

        Settings {
            AccountsSettingsView(model: model)
        }
    }
}

private struct ProjectUndoMenu: View {
    @ObservedObject var editor: ProjectEditor
    var body: some View {
        Button(editor.canUndo ? "Undo " + editor.undoName : "Undo") { editor.undo() }
            .keyboardShortcut("z", modifiers: .command).disabled(!editor.canUndo)
        Button(editor.canRedo ? "Redo " + editor.redoName : "Redo") { editor.redo() }
            .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo)
    }
}
