import AppKit
import SwiftUI

@MainActor
final class VideoExportSession: ObservableObject {
    struct Destination { let url: URL; let preset: VideoExportPreset }
    typealias Chooser = @MainActor (String, VideoExportPreset, NSWindow?) async -> Destination?
    typealias Renderer = @MainActor (RecordingProject, URL, URL, VideoExportPreset, Bool,
        @escaping @MainActor @Sendable (Double) -> Void) async throws -> Void
    @Published private(set) var isBusy = false
    @Published private(set) var isExporting = false
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var shareURL: URL?
    @Published private(set) var shareRequest: UUID?
    private(set) var currentProjectURL: URL?
    weak var window: NSWindow?
    weak var shareAnchor: NSView?
    private var task: Task<Void, Never>?
    private var panel: NSSavePanel?
    private var progressIsVisible = false
    private var sharePending = false
    private let defaults: UserDefaults
    private let chooser: Chooser?
    private let renderer: Renderer
    private let requiresProgressPresentation: Bool

    init(defaults: UserDefaults = .standard, requiresProgressPresentation: Bool = true,
         chooser: Chooser? = nil, renderer: Renderer? = nil) {
        self.defaults = defaults
        self.requiresProgressPresentation = requiresProgressPresentation
        self.chooser = chooser
        self.renderer = renderer ?? { project, directory, url, preset, replace, progress in
            try await ProjectRenderer.export(project: project, directory: directory, to: url,
                preset: preset, replaceExisting: replace, progress: progress)
        }
    }

    func begin(editor: ProjectEditor, sharing: Bool, anchor: NSView? = nil) {
        guard !MediaProcessing.isSuspended else { errorMessage = MediaProcessing.statusMessage; return }
        guard !isBusy else { return }
        shareAnchor = anchor
        guard EditorSaveRouting.save(editor: editor, window: window) else { errorMessage = editor.errorMessage; return }
        let snapshot = editor.project
        let directory = editor.url.deletingLastPathComponent()
        currentProjectURL = editor.url
        shareURL = nil; shareRequest = nil; sharePending = false; errorMessage = nil
        isBusy = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.task = nil; if !self.progressIsVisible { self.isBusy = false } }
            await self.prepare(snapshot: snapshot, projectURL: editor.url, directory: directory, sharing: sharing)
        }
    }

    func cancel() { task?.cancel(); panel?.cancel(nil); sharePending = false }
    func dismissError() { errorMessage = nil }
    func progressDidAppear() { progressIsVisible = true }
    func progressDidDismiss() {
        progressIsVisible = false
        if sharePending { shareRequest = UUID(); sharePending = false }
        if task == nil { isBusy = false }
    }

    private func prepare(snapshot: RecordingProject, projectURL: URL, directory: URL, sharing: Bool) async {
        let name = snapshot.displayName(projectURL: projectURL)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let filename = name.lowercased().hasSuffix(".mp4") ? name : name + ".mp4"
        var preset = VideoExportPreset(rawValue: defaults.string(forKey: "export.preset") ?? "") ?? .fullResolution
        let url: URL
        if sharing {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FrameThrower-Share-" + UUID().uuidString)
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            catch { errorMessage = error.localizedDescription; return }
            url = folder.appendingPathComponent(filename)
        } else {
            let destination: Destination?
            if let chooser { destination = await chooser(filename, preset, window) }
            else { destination = await chooseDestination(filename: filename, preset: preset) }
            guard let destination else { return }
            url = destination.url; preset = destination.preset
            defaults.set(preset.rawValue, forKey: "export.preset")
        }
        guard !Task.isCancelled else { return }
        progress = 0
        isExporting = true
        defer { isExporting = false }
        do {
            // Rendering starts after the progress sheet appears. A tiny export
            // therefore cannot skip the dismissal that must precede sharing.
            while requiresProgressPresentation && !progressIsVisible {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            }
            try await renderer(snapshot, directory, url, preset, !sharing, { [weak self] value in self?.progress = value })
            try Task.checkCancellation()
            if sharing { shareURL = url; sharePending = true }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
    }

    private func chooseDestination(filename: String, preset: VideoExportPreset) async -> Destination? {
        let panel = NSSavePanel()
        self.panel = panel
        defer { self.panel = nil }
        panel.title = "Save Video"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = filename
        panel.canCreateDirectories = true
        let options = NSStackView()
        options.orientation = .horizontal; options.spacing = 8
        options.addArrangedSubview(NSTextField(labelWithString: "Size:"))
        let size = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 180, height: 26), pullsDown: false)
        size.addItems(withTitles: VideoExportPreset.allCases.map(\.title))
        size.selectItem(at: VideoExportPreset.allCases.firstIndex(of: preset) ?? 0)
        size.toolTip = "Smaller dimensions make smaller video files."
        options.addArrangedSubview(size)
        panel.accessoryView = options
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else { response = panel.runModal() }
        guard response == .OK, let url = panel.url else { return nil }
        let index = min(VideoExportPreset.allCases.count - 1, max(0, size.indexOfSelectedItem))
        return Destination(url: url, preset: VideoExportPreset.allCases[index])
    }
}

struct VideoActionsMenu: NSViewRepresentable {
    let editor: ProjectEditor?
    @ObservedObject var session: VideoExportSession
    var isUnavailable = false
    var onSelect: () -> Void = {}
    var upload: (() -> Void)? = nil

    func makeNSView(context: Context) -> VideoActionsMenuButton { VideoActionsMenuButton(frame: .zero) }
    func updateNSView(_ button: VideoActionsMenuButton, context: Context) {
        button.configure(isEnabled: !MediaProcessing.isSuspended && context.environment.isEnabled && !isUnavailable && !session.isBusy && editor != nil,
            name: editor?.displayName,
            save: { [weak button] in
                guard let editor else { return }
                onSelect(); session.begin(editor: editor, sharing: false, anchor: button)
            }, share: { [weak button] in
                guard let editor else { return }
                onSelect(); session.begin(editor: editor, sharing: true, anchor: button)
            }, upload: upload.map { action in { onSelect(); action() } })
    }
}

@MainActor
final class VideoActionsMenuButton: NSPopUpButton {
    override init(frame: NSRect) {
        super.init(frame: frame, pullsDown: true)
        isBordered = false
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        imagePosition = .imageOnly
        focusRingType = .none
        toolTip = "Save or share the edited video"
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func configure(isEnabled: Bool, name: String?, save: @escaping () -> Void,
                   share: @escaping () -> Void, upload: (() -> Void)?) {
        self.isEnabled = isEnabled
        setAccessibilityLabel(name.map { "Share \($0)" } ?? "Share")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        menu.addItem(title)
        add("Save Video…", symbol: "square.and.arrow.down", action: save, to: menu)
        add("Share Video…", symbol: "square.and.arrow.up", action: share, to: menu)
        if let upload { menu.addItem(.separator()); add("Upload…", symbol: "icloud.and.arrow.up", action: upload, to: menu) }
        self.menu = menu
    }
    private func add(_ title: String, symbol: String, action: @escaping () -> Void, to menu: NSMenu) {
        let item = VideoActionMenuItem(title: title, action: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = isEnabled
        menu.addItem(item)
    }
}

@MainActor
private final class VideoActionMenuItem: NSMenuItem {
    private let invoke: () -> Void
    init(title: String, action: @escaping () -> Void) {
        invoke = action
        super.init(title: title, action: #selector(pressed), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("Video action items are created programmatically") }
    @objc private func pressed() { if isEnabled { invoke() } }
}

struct VideoExportPresentation: ViewModifier {
    @ObservedObject var session: VideoExportSession
    func body(content: Content) -> some View {
        content
            .background(VideoExportAnchor(session: session))
            .sheet(isPresented: Binding(get: { session.isExporting }, set: { if !$0 && session.isExporting { session.cancel() } }),
                   onDismiss: { session.progressDidDismiss() }) {
                VStack(spacing: 16) {
                    ProgressView("Preparing video…", value: session.progress, total: 1)
                    HStack {
                        Text(session.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { session.cancel() }.keyboardShortcut(.cancelAction)
                    }
                }
                .padding(24).frame(width: 320)
                .interactiveDismissDisabled()
                .onAppear { session.progressDidAppear() }
            }
            .alert("Couldn't prepare video", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.dismissError() } })) {
                Button("OK", role: .cancel) { session.dismissError() }
            } message: { Text(session.errorMessage ?? "") }
            .onDisappear { session.cancel() }
    }
}

private struct VideoExportAnchor: NSViewRepresentable {
    @ObservedObject var session: VideoExportSession
    func makeNSView(context: Context) -> VideoExportAnchorView { VideoExportAnchorView() }
    func updateNSView(_ view: VideoExportAnchorView, context: Context) {
        view.session = session
        view.present(url: session.shareURL, request: session.shareRequest)
    }
}
@MainActor
private final class VideoExportAnchorView: NSView {
    weak var session: VideoExportSession? { didSet { session?.window = window } }
    private var lastRequest: UUID?
    private var picker: NSSharingServicePicker?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); session?.window = window }
    func present(url: URL?, request: UUID?) {
        guard let url, let request, request != lastRequest else { return }
        lastRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            let anchor = self.session?.shareAnchor ?? self
            let rect = anchor === self ? CGRect(x: bounds.maxX - 24, y: bounds.maxY - 8, width: 16, height: 1) : anchor.bounds
            let picker = NSSharingServicePicker(items: [url])
            self.picker = picker
            picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
        }
    }
}

struct EditorFileActions {
    var saveProject: () -> Void
    var saveVideo: () -> Void
    var shareVideo: () -> Void
    var rename: (() -> Void)? = nil
    var fitTimeline: (() -> Void)? = nil
    var duplicate: (() -> Void)? = nil
    var isBusy: Bool
}
private struct EditorFileActionsKey: FocusedValueKey { typealias Value = EditorFileActions }
extension FocusedValues {
    var editorFileActions: EditorFileActions? {
        get { self[EditorFileActionsKey.self] }
        set { self[EditorFileActionsKey.self] = newValue }
    }
}
