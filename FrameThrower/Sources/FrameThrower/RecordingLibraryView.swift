import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct RecordingLibraryView: View {
    @ObservedObject var library: RecordingLibrary
    let isLocked: Bool
    var editorForURL: (URL) throws -> ProjectEditor
    var onOpen: (URL) -> Void
    var onShare: (URL) -> Bool
    var shareContent: () -> AnyView
    @State private var selectedEditor: ProjectEditor?
    @StateObject private var videoSession = VideoExportSession()

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
                                onRemove: { selectedEditor = nil; library.remove(at: entry.projectURL) },
                                exportSession: videoSession)
                            if entry.id != library.entries.last?.id { Divider().padding(.horizontal, 14) }
                        }
                    }
                }
                .frame(maxHeight: CGFloat(library.entries.count) * RecordingLibraryRow.height)
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
        .modifier(VideoExportPresentation(session: videoSession))
        .focusedSceneValue(\.editorFileActions, selectedEditor.map { editor in
            EditorFileActions(saveProject: { EditorSaveRouting.save(editor: editor, window: videoSession.window) },
                saveVideo: { videoSession.begin(editor: editor, sharing: false) },
                shareVideo: { videoSession.begin(editor: editor, sharing: true) },
                isBusy: isLocked || videoSession.isBusy)
        })
    }
}

struct RecordingLibraryRow: View {
    static let height: CGFloat = 80
    let entry: RecordingLibraryEntry
    let isLocked: Bool
    var editorForURL: (URL) throws -> ProjectEditor
    var onOpen: () -> Void
    var onShare: () -> Bool
    var shareContent: () -> AnyView
    var onSelectEditor: (ProjectEditor) -> Void = { _ in }
    var onRemove: () -> Void = {}
    var exportSession: VideoExportSession? = nil
    @StateObject private var ownExportSession = VideoExportSession()
    @State private var editor: ProjectEditor?
    @State private var renameRequest: UUID?
    @State private var errorMessage: String?
    @State private var isSharingPresented = false
    @State private var isRenaming = false
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let editor {
                    RecordingTitleEditor(editor: editor, renameRequest: renameRequest, onOpen: openRecording,
                        onBeginEditing: { onSelectEditor(editor); errorMessage = nil },
                        onEditingChanged: { editing in
                            isRenaming = editing
                            if !editing { errorMessage = nil }
                        },
                        onRenameError: { errorMessage = $0 })
                        .frame(height: 24)
                } else {
                    Text(entry.displayName).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).frame(height: 24, alignment: .leading)
                }
                RecordingRemoveButton(name: entry.displayName, action: onRemove)
                    .frame(width: 24, height: 24)
                    .opacity(isRenaming ? 0 : 1)
                    .disabled(isRenaming)
                    .allowsHitTesting(!isRenaming)
                    .accessibilityHidden(isRenaming)
            }
            HStack(spacing: 8) {
                RecordingOpenButton(name: entry.displayName, thumbnail: thumbnail,
                    onFocus: { if let editor { onSelectEditor(editor) } },
                    action: openRecording)
                    .frame(width: 48, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(errorMessage ?? (entry.mediaUnavailable ? "Media missing" : mediaDetails))
                        .font(.system(size: 11)).foregroundStyle(errorMessage == nil && !entry.mediaUnavailable ? Color.secondary : Color.red)
                }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: openRecording)
                    .help(entry.mediaUnavailable ? "Open this recording to locate its missing media." : "Duration of the current edit and space used by its originals. Double-click to edit.")
                VideoActionsMenu(editor: editor, session: exportSession ?? ownExportSession,
                    isUnavailable: isLocked, onSelect: { if let editor { onSelectEditor(editor) } },
                    upload: { if onShare() { isSharingPresented = true } })
                .frame(width: 24, height: 20)
                .popover(isPresented: $isSharingPresented) {
                    // The panel keeps its own upload/cancel validation even
                    // while other library actions are locked during upload.
                    shareContent().environment(\.isEnabled, true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: Self.height)
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture(count: 2, perform: openRecording)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open in editor", action: openRecording)
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
        .accessibilityAction(named: "Open in editor", openRecording)
        .accessibilityAction(named: "Rename") { renameRequest = UUID() }
        .disabled(isLocked)
        .controlSize(.small)
        .modifier(RowVideoExportPresentation(session: exportSession == nil ? ownExportSession : nil))
        .task(id: entry.projectURL) {
            do { editor = try editorForURL(entry.projectURL); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
        .task(id: entry.sourceURL.absoluteString + ":" + String(entry.mediaUnavailable)) {
            let image = await RecordingThumbnailCache.shared.thumbnail(for: entry.sourceURL)
            guard !Task.isCancelled else { return }
            thumbnail = image
        }
    }

    private func openRecording() {
        if let editor { onSelectEditor(editor) }
        onOpen()
    }

    private var mediaDetails: String {
        let seconds = max(0, Int(entry.duration))
        var parts = [String(format: "%d:%02d", seconds / 60, seconds % 60)]
        if let bytes = entry.fileSize { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        return parts.joined(separator: "  ·  ")
    }
}

private struct RowVideoExportPresentation: ViewModifier {
    let session: VideoExportSession?
    func body(content: Content) -> some View {
        if let session { content.modifier(VideoExportPresentation(session: session)) }
        else { content }
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
    @objc private func pressed() {
        guard isEnabled else { return }
        // Removing a focused thumbnail must not transfer command ownership to
        // another row as SwiftUI takes this row out of the key-view loop.
        window?.makeFirstResponder(nil)
        onPress?()
    }
}

struct RecordingOpenButton: NSViewRepresentable {
    let name: String
    let thumbnail: CGImage?
    var onFocus: () -> Void = {}
    var action: () -> Void

    func makeNSView(context: Context) -> RecordingOpenButtonView { RecordingOpenButtonView() }
    func updateNSView(_ button: RecordingOpenButtonView, context: Context) {
        button.thumbnail = thumbnail
        button.onFocus = onFocus
        button.onPress = action
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel("Open \(name) in editor")
    }
}

/// A small native open target, independent of the rename field and removal X.
/// Its focus cue belongs to the thumbnail rather than the whole row.
@MainActor
final class RecordingOpenButtonView: NSButton {
    var onPress: (() -> Void)?
    var onFocus: (() -> Void)?
    var thumbnail: CGImage? { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && window != nil && !isHiddenOrHasHiddenAncestor }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        toolTip = "Open in editor. Return or Space opens the focused recording."
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(); needsDisplay = true }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { needsDisplay = true }
        return resigned
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) {
            if !event.isARepeat { pressed() }
        } else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if ![36, 49, 76].contains(event.keyCode) { super.keyUp(with: event) }
    }
    @objc private func pressed() { if isEnabled { onPress?() } }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        shape.fill()
        shape.addClip()
        if let thumbnail {
            let image = NSImage(cgImage: thumbnail, size: CGSize(width: thumbnail.width, height: thumbnail.height))
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height))
        }
        let badge = CGRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14)
        NSColor.black.withAlphaComponent(isHighlighted ? 0.8 : 0.55).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let play = NSBezierPath()
        play.move(to: CGPoint(x: bounds.midX - 2, y: bounds.midY - 4))
        play.line(to: CGPoint(x: bounds.midX + 4, y: bounds.midY))
        play.line(to: CGPoint(x: bounds.midX - 2, y: bounds.midY + 4))
        play.close()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
        play.fill()
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
    }
}

/// Thumbnail work is restricted to adjacent recorded files. This bounded LRU
/// holds at most 128 small images (including misses) and runs two decodes at a
/// time. Cancellation removes queued work before it opens another asset.
@MainActor
final class RecordingThumbnailCache {
    typealias Loader = @MainActor (URL) async -> CGImage?
    static let shared = RecordingThumbnailCache()
    private struct Result { let image: CGImage? }
    private let capacity: Int
    private let concurrency: Int
    private let loader: Loader
    private var cached: [String: Result] = [:]
    private var order: [String] = []
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    var cachedCount: Int { cached.count }

    init(capacity: Int = 128, concurrency: Int = 2, loader: Loader? = nil) {
        self.capacity = max(1, capacity)
        self.concurrency = max(1, concurrency)
        self.loader = loader ?? Self.load
    }

    func thumbnail(for url: URL) async -> CGImage? {
        guard !MediaProcessing.isSuspended, url.isFileURL, !Task.isCancelled else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = url.standardizedFileURL.path + ":" + String(describing: attributes?[.size]) + ":" + String(describing: attributes?[.modificationDate])
        if let result = cached[key] { touch(key); return result.image }
        guard await acquire() else { return nil }
        defer { release() }
        guard !Task.isCancelled else { return nil }
        if let result = cached[key] { touch(key); return result.image }
        let image = await loader(url)
        guard !Task.isCancelled else { return nil }
        cached[key] = Result(image: image)
        touch(key)
        while order.count > capacity { cached.removeValue(forKey: order.removeFirst()) }
        return image
    }

    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < concurrency { active += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }
    private func release() {
        active -= 1
        if !waiters.isEmpty {
            active += 1
            waiters.removeFirst().1.resume(returning: true)
        }
    }
    private static func load(_ url: URL) async -> CGImage? {
        let request = RecordingThumbnailRequest(url: url)
        return await withTaskCancellationHandler {
            defer { request.cancel() }
            return try? await request.generator.image(at: .zero).image
        } onCancel: { request.cancel() }
    }
}

private final class RecordingThumbnailRequest: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    init(url: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
    }
    func cancel() { generator.cancelAllCGImageGeneration() }
}
