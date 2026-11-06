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
            if !library.entries.isEmpty {
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
                .frame(maxHeight: CGFloat(library.entries.count) * 68)
                .scrollIndicators(.automatic)
            }
            if let message = library.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
            if library.canUndoRemoval {
                HStack {
                    Button("Undo removal") { _ = library.restoreLastRemoved() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .disabled(isLocked)
                        .help("Put the most recently removed recording back in this list. Its files stayed on disk. Command-Z also restores it.")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let editor {
                    RecordingTitleEditor(editor: editor, renameRequest: renameRequest, onOpen: onOpen,
                        onBeginEditing: { onSelectEditor(editor); errorMessage = nil },
                        onRenameError: { errorMessage = $0 })
                        .frame(height: 24)
                } else {
                    Text(entry.displayName).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).frame(height: 24, alignment: .leading)
                }
                RecordingRemoveButton(name: entry.displayName, action: onRemove)
                    .frame(width: 24, height: 24)
            }
            HStack(spacing: 8) {
                Text(errorMessage ?? details)
                    .font(.system(size: 11)).foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onOpen)
                    .help("Double-click to edit this recording.")
                Button { if onShare() { isSharingPresented = true } } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share \(entry.displayName)")
                .help("Share this recording's current edit.")
                .popover(isPresented: $isSharingPresented) {
                    // The panel keeps its own upload/cancel validation even
                    // while other library actions are locked during upload.
                    shareContent().environment(\.isEnabled, true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 68)
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

/// Plain native buttons accept the first click even in an inactive window.
/// They do not install a focusable wrapper around the entire recording row.
struct RecordingRemoveButton: NSViewRepresentable {
    let name: String
    var action: () -> Void

    func makeNSView(context: Context) -> RecordingRemoveButtonView {
        RecordingRemoveButtonView()
    }

    func updateNSView(_ button: RecordingRemoveButtonView, context: Context) {
        button.onPress = action
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel("Remove \(name) from list")
    }
}

@MainActor
final class RecordingRemoveButtonView: NSButton {
    var onPress: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .inline
        controlSize = .small
        contentTintColor = .secondaryLabelColor
        focusRingType = .none
        toolTip = "Remove from list. Recording files stay on disk."
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func pressed() { if isEnabled { onPress?() } }
}
