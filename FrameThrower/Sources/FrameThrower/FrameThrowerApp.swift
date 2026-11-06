import SwiftUI

@main
struct FrameThrowerApp: App {
    @NSApplicationDelegateAdaptor(EditorDraftApplicationDelegate.self) private var draftApplicationDelegate
    @StateObject private var model = CaptureViewModel()

    var body: some Scene {
        Window("FrameThrower", id: "recorder") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 820)
        .windowStyle(.titleBar)
        .commands {
            ProjectEditingCommands()
            CommandGroup(after: .newItem) { OpenProjectMenu(model: model) }
            EditorFileCommands()
        }

        WindowGroup("Edit recording", id: "editor", for: URL.self) { $url in
            if let url {
                ProjectEditorWindow(url: url, model: model)
            } else {
                VStack(spacing: 16) {
                    OpenProjectMenu(model: model)
                }
                .frame(minWidth: 420, minHeight: 240)
            }
        }
        .defaultSize(width: 940, height: 780)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)

        Settings { AccountsSettingsView(model: model) }
    }
}

private struct ProjectEditorWindow: View {
    @StateObject private var session: EditorWindowSession
    @ObservedObject var model: CaptureViewModel
    @Environment(\.openWindow) private var openWindow

    init(url: URL, model: CaptureViewModel) {
        self.model = model
        _session = StateObject(wrappedValue: EditorWindowSession(url: url, model: model))
    }

    var body: some View {
        Group {
            if let editor = session.editor {
                ProjectEditorView(editor: editor, onDuplicate: { model.duplicateRecording($0) },
                                  isDuplicateUnavailable: !model.canDuplicateRecording)
                    .focusedSceneObject(editor)
            } else {
                ContentUnavailableView("Cannot open recording", systemImage: "exclamationmark.triangle",
                                       description: Text(session.errorMessage ?? "The project could not be opened."))
                    .frame(minWidth: 420, minHeight: 240)
            }
        }
        .onChange(of: model.editorOpenRequest) { _, request in
            if let request { openWindow(id: "editor", value: request.url) }
        }
    }
}

@MainActor
private final class EditorWindowSession: ObservableObject {
    let editor: ProjectEditor?
    let errorMessage: String?

    init(url: URL, model: CaptureViewModel) {
        do {
            editor = try model.editor(for: url)
            errorMessage = nil
        } catch {
            editor = nil
            errorMessage = error.localizedDescription
        }
    }
}

private struct OpenProjectMenu: View {
    @ObservedObject var model: CaptureViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open project…") {
            if let url = model.chooseProject() {
                openWindow(id: "editor", value: url.standardizedFileURL.resolvingSymlinksInPath())
            }
        }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(model.isRecording || model.isCaptureBusy || model.isAnyUploadActive)
    }
}

