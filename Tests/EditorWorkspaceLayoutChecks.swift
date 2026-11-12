import AppKit
import SwiftUI
@testable import FrameThrower

private final class WorkspaceWindowHookView: NSView {
    var found: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // This is this test's own real SwiftUI window. Keep it invisible and
        // offscreen without activating another app or sending system input.
        window.alphaValue = 0
        window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        found?(window)
    }
}
private struct WorkspaceWindowHook: NSViewRepresentable {
    let found: (NSWindow) -> Void
    func makeNSView(context: Context) -> WorkspaceWindowHookView {
        let view = WorkspaceWindowHookView(); view.found = found; return view
    }
    func updateNSView(_ view: WorkspaceWindowHookView, context: Context) { view.found = found }
}
@MainActor private final class WorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
}

/// Real WindowGroup/contentMinSize negotiation, entirely vector-based. A plain
/// NSHostingView forcibly placed in a small NSWindow cannot catch native minimum
/// size inflation, which was the regression this test is intended to expose.
@main @MainActor
struct EditorWorkspaceLayoutChecks: App {
    @NSApplicationDelegateAdaptor(WorkspaceApplicationDelegate.self) private var delegate
    @StateObject private var probe = WorkspaceLayoutProbe()
    var body: some Scene {
        WindowGroup("Offscreen editor workspace check") {
            Group {
                if let editor = probe.editor {
                    ProjectEditorView(editor: editor, directorModeInitiallyEnabled: probe.director,
                        playback: probe.playback,
                        assistant: EditorAssistantSession(transport: { _ in throw CancellationError() }, persistsConversation: false))
                        .background(WorkspaceWindowHook { window in
                            Task { await probe.inspect(window) }
                        }.frame(width: 0, height: 0))
                } else {
                    Color.clear.frame(width: 320, height: 200).task { probe.prepare() }
                }
            }
        }
        .defaultSize(width: 1100, height: 780)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}

@MainActor private final class WorkspaceLayoutProbe: ObservableObject {
    enum Failure: Error { case failed(String) }
    @Published var editor: ProjectEditor?
    let director = CommandLine.arguments.contains("--director")
    let playback = EditorPlayback()
    private var directory: URL?
    private var started = false
    private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.failed(message) }
    }
    func prepare() {
        guard editor == nil else { return }
        do {
            try require(MediaProcessing.isSuspended && MediaProcessing.isCaptureSuspended, "Vector mode and live capture Off are mandatory")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-workspace-layout-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            var project = RecordingProject(screenFilename: "unopened-screen.mov", cameraFilename: "unopened-camera.mov", duration: 12)
            project.state.zoomKeyframes = [.init(time: 3, scale: 2, transition: .smooth, duration: 1)]
            project.state.pipKeyframes.append(.init(time: 5, placement: .init(x: 0.2, y: 0.3, scale: 0.3), transition: .smooth, duration: 1))
            let value = ProjectEditor(project: project, url: folder.appendingPathComponent("workspace.framethrower"))
            try require(value.save(), "Prepare metadata-only project")
            editor = value
        } catch { finish(error) }
    }
    func inspect(_ window: NSWindow) async {
        guard !started, editor != nil else { return }; started = true
        do {
            // The deadline uses awake time: machine sleep is not a layout error.
            let deadline = SuspendingClock.now.advanced(by: .seconds(15))
            while !playback.canPlay || first(EditorCanvasView.self, in: window.contentView!) == nil {
                try require(SuspendingClock.now < deadline, "Vector editor did not appear")
                try await Task.sleep(for: .milliseconds(30))
            }
            try await run(window)
            finish(nil)
        } catch { finish(error) }
    }
    private func run(_ window: NSWindow) async throws {
        guard let host = window.contentView, let canvas = first(EditorCanvasView.self, in: host),
              let previewRegion = first(EditorPreviewRegionMarker.MarkerView.self, in: host),
              let timeline = first(RecordingTimelineView.self, in: host), let editor else { throw Failure.failed("Missing production editor views") }
        let unchanged = editor.project
        let nativeToolbarHeight = window.contentRect(forFrameRect: window.frame).height - window.contentLayoutRect.height
        let sizes = [CGSize(width: 720, height: 540), CGSize(width: 1024, height: 760), CGSize(width: 1280, height: 900)]
        for size in sizes {
            window.setContentSize(CGSize(width: size.width, height: size.height + nativeToolbarHeight))
            try await settle(host)
            let content = window.contentLayoutRect.size
            try require(abs(content.width - size.width) <= 2 && abs(content.height - size.height) <= 2,
                "Native WindowGroup forced requested \(size) to \(content) (Director \(director)); layout \(window.contentLayoutRect), host \(host.bounds), min \(window.contentMinSize)")
            let minimum = window.contentMinSize
            try require(minimum.width <= sizes[0].width + 2 && minimum.height - nativeToolbarHeight <= sizes[0].height + 2,
                "Native minimum inflated to \(minimum), compact target \(sizes[0])")
            let preview = canvas.convert(canvas.bounds, to: host)
            try require(preview.width > 300 && preview.height >= 160 && host.bounds.insetBy(dx: -2, dy: -2).contains(preview),
                "Compact preview clipped or unusable: \(preview), host \(host.bounds)")
            // AppKit rounds the fitted native view to backing pixels. Its
            // actual output rectangle retains the exact video aspect ratio.
            try require(abs(canvas.bounds.height - canvas.bounds.width * 9 / 16) <= 1 / max(1, window.backingScaleFactor),
                "The production canvas view does not fit its actual output aspect ratio: \(canvas.bounds)")
            try require(abs(canvas.canvasRect.width / canvas.canvasRect.height - 16.0 / 9) < 0.000001,
                "Native pixel rounding stretched the actual output canvas")
            try controlsFit(host)
            try EditorUIProbe.checkSliderWidths(in: host)
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let filename = "/tmp/framethrower-workspace-\(director ? "director" : "properties")-\(Int(size.width))x\(Int(size.height)).png"
                    try png.write(to: URL(fileURLWithPath: filename))
                }
            }
            try require(!canvas.hasMediaPlayerLayer && !playback.hasMediaPlayer, "Layout check opened media")
        }
        // With the same width and tools, added height should go to the preview,
        // not into blank property-panel background or unused timeline rows.
        window.setContentSize(CGSize(width: 1100, height: 700 + nativeToolbarHeight)); try await settle(host)
        let before = previewRegion.bounds.height
        window.setContentSize(CGSize(width: 1100, height: 900 + nativeToolbarHeight)); try await settle(host)
        try require(previewRegion.bounds.height - before >= 160,
            "Preview workspace received only \(previewRegion.bounds.height - before) of 200 extra points")
        try require(editor.project == unchanged, "Resizing changed recording/history")
        let baseline = [previewRegion.frame, canvas.frame, timeline.frame]
        let position = playback.outputTime
        if let animation = timeline.animationSpans.first(where: { $0.lane == .screen }) {
            timeline.onSelectAnimation?(animation.id); try await settle(host)
            try require(playback.outputTime == position && !playback.isInspectingSource,
                "Animation selection moved the project playhead or changed its clock")
            try require(window.contentMinSize.width <= sizes[0].width + 2 && window.contentMinSize.height - nativeToolbarHeight <= sizes[0].height + 2,
                "Selection enlarged native minimum")
            timeline.onDeselectEdit?(); try await settle(host)
            try require([previewRegion.frame, canvas.frame, timeline.frame] == baseline, "Deselecting unexpectedly changed the workspace allocation")
        }
        print("Editor workspace WindowGroup checks passed: Director=\(director), reachable compact sizes, contained controls, preview receives resize height, stable selection/project clock; no focus, devices or media.")
    }
    private func controlsFit(_ host: NSView) throws {
        for control in all(NSControl.self, in: host) where !control.isHiddenOrHasHiddenAncestor && control.alphaValue > 0 && control.bounds.width > 1 && control.bounds.height > 1 {
            let rect = control.convert(control.bounds, to: host)
            var parent = control.superview
            var clips: [NSClipView] = []
            while let view = parent { if let clip = view as? NSClipView { clips.append(clip) }; parent = view.superview }
            // Properties below their vertical fold are intentionally hidden.
            // On a visible row, controls must fit each vertical viewport—not
            // merely the much wider overall editor window.
            guard rect.intersects(host.bounds), clips.allSatisfy({ clip in
                let viewport = clip.convert(clip.bounds, to: host)
                return rect.maxY > viewport.minY && rect.minY < viewport.maxY
            }) else { continue }
            let constraints = [host.bounds] + clips.filter { $0.enclosingScrollView?.hasHorizontalScroller != true }.map { $0.convert($0.bounds, to: host) }
            for available in constraints {
                try require(rect.minX >= available.minX - 2 && rect.maxX <= available.maxX + 2,
                    "A visible \(type(of: control)) is horizontally clipped: \(rect), viewport \(available)")
            }
        }
    }
    private func settle(_ view: NSView) async throws {
        for _ in 0..<4 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    }
    private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? { all(type, in: view).first }
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
    private func finish(_ error: (any Error)?) {
        playback.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let error { FileHandle.standardError.write(Data("Editor workspace layout failed: \(error)\n".utf8)) }
        Darwin.exit(error == nil ? 0 : 1)
    }
}
