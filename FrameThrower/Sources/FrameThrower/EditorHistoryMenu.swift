import SwiftUI

/// The same chronological stack as Command-Z, exposed without a second history
/// model or an agent-only undo path. Selecting a row includes newer entries.
struct EditorHistoryMenu: View {
    @ObservedObject var editor: ProjectEditor

    var body: some View {
        Menu {
            if editor.historyState.undo.isEmpty && editor.historyState.redo.isEmpty {
                Text("No edits yet")
            }
            if !editor.historyState.undo.isEmpty {
                Section("Undo") {
                    ForEach(Array(editor.historyState.undo.prefix(12).enumerated()), id: \.offset) { index, name in
                        Button(title(action: "Undo", count: index + 1, name: name)) {
                            _ = editor.undo(count: index + 1)
                        }
                    }
                }
            }
            if !editor.historyState.redo.isEmpty {
                Section("Redo") {
                    ForEach(Array(editor.historyState.redo.prefix(12).enumerated()), id: \.offset) { index, name in
                        Button(title(action: "Redo", count: index + 1, name: name)) {
                            _ = editor.redo(count: index + 1)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .accessibilityLabel("Edit history")
        .help("Undo and redo history. Choosing an earlier entry includes the changes above it.")
    }

    private func title(action: String, count: Int, name: String) -> String {
        let label = name.replacingOccurrences(of: "\n", with: "; ")
        return count == 1 ? "\(action) \(label)" : "\(action) \(count) changes through \(label)"
    }
}
