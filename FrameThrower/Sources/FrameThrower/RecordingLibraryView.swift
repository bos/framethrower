import AppKit
import SwiftUI

struct RecordingLibraryView: View {
    @ObservedObject var library: RecordingLibrary
    let isLocked: Bool
    var editorForURL: (URL) throws -> ProjectEditor
    var onOpen: (URL) -> Void
    var onShare: (URL) -> Bool
    var shareContent: () -> AnyView
    @State private var selectedEditor: ProjectEditor?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(library.errorMessage ?? "Recordings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(library.errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .help(library.errorMessage ?? "Recent recordings")
                Spacer()
                if library.canUndoRemoval {
                    Button("Undo remove") { _ = library.restoreLastRemoved() }
                        .controlSize(.small)
                        .disabled(isLocked)
                        .help("Return the most recently removed recording to this list.")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 28)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(library.entries) { entry in
                        RecordingLibraryRow(entry: entry, isLocked: isLocked,
                            editorForURL: editorForURL,
                            onOpen: { onOpen(entry.projectURL) }, onShare: { onShare(entry.projectURL) },
                            shareContent: shareContent,
                            onSelectEditor: { selectedEditor = $0 },
                            onRemove: { selectedEditor = nil; library.remove(at: entry.projectURL) })
                        if entry.id != library.entries.last?.id { Divider().padding(.horizontal, 14) }
                    }
                }
            }
            .frame(height: min(132, CGFloat(library.entries.count) * 56))
            .scrollIndicators(.automatic)
        }
        .modifier(RecorderCard())
        .accessibilityLabel("Recent recordings")
        .focusedSceneObject(selectedEditor)
        .focusedSceneObject(selectedEditor == nil ? library : nil)
    }
}

struct RecordingLibraryRow: View {
    let entry: RecordingLibraryEntry
    let isLocked: Bool
    var editorForURL: (URL) throws -> ProjectEditor
    var onOpen: () -> Void
    var onShare: () -> Bool
    var shareContent: () -> AnyView
    var onSelectEditor: (ProjectEditor) -> Void = { _ in }
    var onRemove: () -> Void = {}
    @State private var editor: ProjectEditor?
    @State private var renameRequest: UUID?
    @State private var errorMessage: String?
    @State private var isSharingPresented = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 22)).foregroundStyle(RecorderStyle.accent)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onOpen)
                .help("Double-click to edit this recording.")
            VStack(alignment: .leading, spacing: 1) {
                if let editor {
                    RecordingTitleEditor(editor: editor, renameRequest: renameRequest, onOpen: onOpen,
                        onBeginEditing: { onSelectEditor(editor); errorMessage = nil },
                        onRenameError: { errorMessage = $0 })
                        .frame(height: 24)
                } else {
                    Text(entry.displayName).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).frame(height: 24, alignment: .leading)
                }
                Text(errorMessage ?? details)
                    .font(.system(size: 11)).foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onOpen)
                    .help("Double-click to edit this recording.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { if onShare() { isSharingPresented = true } } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
                .help("Share this recording's current edit.")
                .popover(isPresented: $isSharingPresented) {
                    // The panel keeps its own upload/cancel validation even
                    // while other library actions are locked during upload.
                    shareContent().environment(\.isEnabled, true)
                }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove from list. Recording files stay on disk.")
            .accessibilityLabel("Remove \(entry.displayName) from list")
        }
        .padding(.horizontal, 14)
        .frame(height: 55)
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture(count: 2, perform: onOpen)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open in editor", action: onOpen)
            Button("Rename") { renameRequest = UUID() }
                .disabled(editor == nil)
            Button("Show in Finder") {
                var files = [entry.projectURL, entry.sourceURL]
                if let editor {
                    files += [editor.project.cameraFilename, editor.project.cursorFilename]
                        .compactMap { $0 }.map { editor.mediaURL(for: $0) }
                }
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
        }
        .focusable()
        .onKeyPress(.return) { onOpen(); return .handled }
        .accessibilityAction(named: "Open in editor", onOpen)
        .accessibilityAction(named: "Rename") { renameRequest = UUID() }
        .disabled(isLocked)
        .controlSize(.small)
        .task(id: entry.projectURL) {
            do { editor = try editorForURL(entry.projectURL); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private var details: String {
        let seconds = max(0, Int(entry.duration))
        var parts = [entry.createdAt.formatted(date: .abbreviated, time: .shortened),
                     String(format: "%d:%02d", seconds / 60, seconds % 60)]
        if let bytes = entry.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        return parts.joined(separator: "  ·  ")
    }
}
