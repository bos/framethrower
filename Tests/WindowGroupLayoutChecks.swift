@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// Events target only this test's own native preview, never system input.
private final class IntegratedTrackpadEvent: NSEvent {
    var amount = 0.0
    var dx = 0.0
    var dy = 0.0
    var position = CGPoint.zero
    var eventPhase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    override var magnification: CGFloat { amount }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var locationInWindow: NSPoint { position }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
}

/// A real SwiftUI scene is required here: NSHostingController does not exercise
/// WindowGroup's content-minimum sizing negotiation and restoration behavior.
@main
struct WindowGroupLayoutChecks: App {
    @StateObject private var probe = WindowGroupLayoutProbe()

    var body: some Scene {
        WindowGroup("WindowGroup layout regression") {
            Group {
                if let editor = probe.editor { ProjectEditorView(editor: editor, assistant: EditorAssistantSession(transport: { _ in throw CancellationError() })).focusedSceneObject(editor) }
                else { ProgressView("Preparing synthetic recording…").frame(width: 940, height: 780) }
            }
            .preferredColorScheme(probe.reviewColorScheme)
            .task { await probe.run() }
        }
        .defaultSize(width: 940, height: 780)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            EditorFileCommands()
            ProjectEditingCommands()
        }
    }
}

@MainActor
private final class WindowGroupLayoutProbe: ObservableObject {
    enum ProbeError: Error { case failed(String) }
    @Published var editor: ProjectEditor?
    @Published var reviewColorScheme: ColorScheme?
    private var started = false

    func run() async {
        guard !started else { return }
        started = true
        // An Objective-C exception swallowed by AppKit must fail this check,
        // rather than leave a detached native test process running indefinitely.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            FileHandle.standardError.write(Data("WINDOWGROUP LAYOUT FAILURE: exceeded 90-second runtime limit\n".utf8))
            Darwin.exit(1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await EditorMovieFixtures.make(at: directory.appendingPathComponent("screen.mp4"),
                width: 1920, height: 1080, duration: 4, camera: false)
            try await EditorMovieFixtures.make(at: directory.appendingPathComponent("camera.mp4"),
                width: 640, height: 360, duration: 4, camera: true)
            let screenBytes = try Data(contentsOf: directory.appendingPathComponent("screen.mp4"))
            let cameraBytes = try Data(contentsOf: directory.appendingPathComponent("camera.mp4"))
            var project = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mp4", duration: 4)
            project.state.trimStart = 1.733333333
            project.state.trimEnd = 3.2
            let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("test.framethrower"))
            guard editor.save() else { throw ProbeError.failed("save synthetic project") }
            self.editor = editor
            try await inspectWindow()
            let finalScreenBytes = try Data(contentsOf: directory.appendingPathComponent("screen.mp4"))
            let finalCameraBytes = try Data(contentsOf: directory.appendingPathComponent("camera.mp4"))
            guard editor.project == project, finalScreenBytes == screenBytes, finalCameraBytes == cameraBytes else {
                throw ProbeError.failed("Play, trim-handle grab, or scrubbing mutated project/history/source media")
            }
            guard let window = NSApplication.shared.windows.first(where: { window in
                guard let host = window.contentView else { return false }
                return find(in: host) as EditorCanvasView? != nil
            }), let host = window.contentView, let canvas: EditorCanvasView = find(in: host),
                  let timeline: RecordingTimelineView = find(in: host) else {
                throw ProbeError.failed("editor window for title synchronization")
            }
            let beforeRename = measure(window: window, host: host, canvas: canvas, timeline: timeline)
            try inspectToolbar(window: window, host: host, name: editor.displayName)
            guard let frame = window.contentView?.superview,
                  let title: RecordingTitleField = find(in: frame) else {
                throw ProbeError.failed("recording name missing from the native window toolbar")
            }
            title.beginRenaming()
            guard title.isRenaming, let titleEditor = title.currentEditor() as? NSTextView else {
                throw ProbeError.failed("native toolbar name did not enter renaming")
            }
            let renamed = "Renamed recording " + String(repeating: "long name ", count: 12)
            titleEditor.string = renamed
            _ = title.control(title, textView: titleEditor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            guard editor.displayName == renamed.trimmingCharacters(in: .whitespaces) else {
                throw ProbeError.failed("Return in the toolbar name did not rename the recording")
            }
            try await titleMatches(editor, window: window)
            try await inspectNativeTextUndo(editor, window: window, title: title)
            output("Native text Undo/Redo scope checks passed.")
            try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                             baseline: beforeRename, context: "renamed recording", compareScrolls: false)
            try performToolbarAction("Undo", window: window)
            try await waitUntil("native toolbar Undo reverses renaming") { editor.project.title == project.title }
            guard editor.project.state == project.state else {
                throw ProbeError.failed("undo rename without changing video edits")
            }
            try await titleMatches(editor, window: window)
            try inspectToolbar(window: window, host: host, name: editor.displayName)
            try await inspectSaveCommands(editor, window: window, host: host, canvas: canvas)
            output("Native Save command and chooser checks passed.")
            try await inspectCombinedEditing(editor, window: window, host: host, canvas: canvas, timeline: timeline)
            await renderSyntheticWindow(window: window, host: host, timeline: timeline)
            guard try Data(contentsOf: directory.appendingPathComponent("screen.mp4")) == screenBytes,
                  try Data(contentsOf: directory.appendingPathComponent("camera.mp4")) == cameraBytes else {
                throw ProbeError.failed("combined edits changed original media")
            }
            try? FileManager.default.removeItem(at: directory)
            output("WindowGroup layout checks passed (native toolbar/rename, stable Play/trim/scrub, combined drafts, diamond moves/X deletion, numeric duration, deselection/Escape, and Canvas aspect/gesture/Undo integration).")
            Darwin.exit(0)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            output("WINDOWGROUP LAYOUT FAILURE: \(error)")
            Darwin.exit(1)
        }
    }

    private func titleMatches(_ editor: ProjectEditor, window: NSWindow) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while window.title != editor.displayName {
            guard ContinuousClock.now < deadline else {
                throw ProbeError.failed("window title '\(window.title)' does not match '\(editor.displayName)'")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func segmentLabels(_ control: NSSegmentedControl) -> [String] {
        (0..<control.segmentCount).compactMap { control.label(forSegment: $0) }
    }

    private func findInspector(in host: NSView) -> NSSegmentedControl? {
        findAll(NSSegmentedControl.self, in: host).first {
            segmentLabels($0) == ["Zoom", "Pointer", "Camera", "Canvas", "Audio"]
        }
    }

    private func toolbarItems(in window: NSWindow) -> [NSToolbarItem] {
        func flatten(_ item: NSToolbarItem) -> [NSToolbarItem] {
            [item] + ((item as? NSToolbarItemGroup)?.subitems.flatMap(flatten) ?? [])
        }
        return window.toolbar?.items.flatMap(flatten) ?? []
    }

    private func inspectToolbar(window: NSWindow, host: NSView, name: String) throws {
        guard let toolbar = window.toolbar else { throw ProbeError.failed("editor has no native window toolbar") }
        let items = toolbarItems(in: window)
        for label in ["Undo", "Redo"] {
            guard items.contains(where: { $0.label == label || $0.paletteLabel == label }) else {
                throw ProbeError.failed("native toolbar lacks the standard \(label) action")
            }
        }
        guard toolbar.displayMode != .labelOnly else { throw ProbeError.failed("toolbar actions must use their standard icons") }
        guard let frame = window.contentView?.superview else { throw ProbeError.failed("missing native window frame") }
        guard let share: VideoActionsMenuButton = find(in: frame), !share.isDescendant(of: host),
              share.imagePosition == .imageOnly && share.menu?.items.first?.image != nil &&
              share.menu?.items.map(\.title) == ["Share", "Save Video…", "Share Video…"] else {
            throw ProbeError.failed("the native toolbar must contain an icon-only Share menu with separate Save and Share actions")
        }
        let titles = findAll(RecordingTitleField.self, in: frame)
        guard titles.count == 1, titles[0].stringValue == name, !titles[0].isDescendant(of: host),
              findAll(RecordingTitleField.self, in: host).isEmpty else {
            throw ProbeError.failed("recording name must appear once in the native toolbar, without a duplicate content header")
        }
        guard !(titles[0].cell is NSSearchFieldCell) else {
            throw ProbeError.failed("the recording name must not become a search control in the toolbar")
        }
        let visibleTitles = findAll(NSTextField.self, in: frame).filter {
            $0.stringValue == name && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0
        }
        guard visibleTitles.count == 1 else {
            throw ProbeError.failed("the window presents the recording name twice: \(visibleTitles.map { String(describing: type(of: $0)) })")
        }
    }

    private func performToolbarAction(_ label: String, window: NSWindow) throws {
        guard let item = toolbarItems(in: window).first(where: { $0.label == label || $0.paletteLabel == label }) else {
            throw ProbeError.failed("missing toolbar action \(label)")
        }
        if let action = item.action, NSApplication.shared.sendAction(action, to: item.target, from: item) { return }
        guard let view = item.view else { throw ProbeError.failed("toolbar action \(label) has no native action or view") }
        if let button: NSButton = find(in: view), let action = button.action,
           button.sendAction(action, to: button.target) { return }
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        window.sendEvent(mouse(.leftMouseDown, at: center, in: view, window: window))
        window.sendEvent(mouse(.leftMouseUp, at: center, in: view, window: window))
    }

    private func command(_ title: String, prefix: Bool = false) -> (menu: NSMenu, index: Int, item: NSMenuItem)? {
        func search(_ menu: NSMenu) -> (NSMenu, Int, NSMenuItem)? {
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if prefix ? item.title.hasPrefix(title) : item.title == title { return (menu, index, item) }
                if let submenu = item.submenu, let result = search(submenu) { return result }
            }
            return nil
        }
        return NSApplication.shared.mainMenu.flatMap(search)
    }

    private func performCommand(_ title: String, prefix: Bool = false) throws {
        guard let entry = command(title, prefix: prefix), entry.item.isEnabled else {
            throw ProbeError.failed("native menu command '\(title)' is missing or disabled")
        }
        entry.menu.performActionForItem(at: entry.index)
    }

    private func preserveNameForToolbarClick(_ label: String, title: RecordingTitleField, window: NSWindow) throws {
        guard let item = toolbarItems(in: window).first(where: { $0.label == label || $0.paletteLabel == label }),
              let view = item.view, let marker: EditorTextUndoTargetView = find(in: view),
              marker.window === window, marker.bounds.width > 0 && marker.bounds.height > 0 else {
            throw ProbeError.failed("the actual \(label) toolbar control lacks a native text-undo target")
        }
        let point = CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
        title.cancelForOutsideClick(mouse(.leftMouseDown, at: point, in: marker, window: window))
        guard title.isRenaming, window.firstResponder === title.currentEditor() else {
            throw ProbeError.failed("the outside-click monitor cancelled name editing before toolbar \(label)")
        }
    }

    private func inspectNativeTextUndo(_ editor: ProjectEditor, window: NSWindow, title: RecordingTitleField) async throws {
        window.makeKeyAndOrderFront(nil)
        let before = editor.project
        title.beginRenaming()
        guard let text = title.currentEditor() as? NSTextView, text.isFieldEditor, text.allowsUndo else {
            throw ProbeError.failed("toolbar name lacks an undo-enabled native field editor")
        }
        let oldName = text.string
        text.insertText("Native menu typing draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        text.breakUndoCoalescing()
        let menuClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1)!
        guard menuClick.window == nil else { throw ProbeError.failed("menu-tracking fixture unexpectedly has a window") }
        title.cancelForOutsideClick(menuClick)
        guard title.isRenaming else { throw ProbeError.failed("menu tracking must keep the native name editor active") }
        let activeMenu = NSApplication.shared.keyWindow === window
        if !activeMenu { output("Native menu dispatch unavailable without a key window; testing associated-window toolbar routing.") }
        try await Task.sleep(for: .milliseconds(50))
        if activeMenu {
            try await waitUntil("native Undo command becomes available for name typing") {
                command("Undo", prefix: true)?.item.isEnabled == true
            }
            try performCommand("Undo", prefix: true)
        } else {
            try preserveNameForToolbarClick("Undo", title: title, window: window)
            try performToolbarAction("Undo", window: window)
        }
        try await waitUntil("native menu Undo changes letters without undoing recording edits") {
            text.string == oldName && title.isRenaming && editor.project == before
        }
        guard text.undoManager?.canRedo == true && EditorUndoRouting.canRedo(editor: editor, window: window) else {
            throw ProbeError.failed("native name Undo did not create text Redo history")
        }
        if activeMenu { try performCommand("Redo", prefix: true) }
        else {
            try preserveNameForToolbarClick("Redo", title: title, window: window)
            try performToolbarAction("Redo", window: window)
        }
        try await waitUntil("Redo control must restore draft letters when the associated native manager can redo") {
            text.string == "Native menu typing draft" && title.isRenaming && editor.project == before
        }
        text.undoManager?.removeAllActions()
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: title)
        try await Task.sleep(for: .milliseconds(50))
        if activeMenu {
            try await waitUntil("empty text undo stack must not fall through to recording history") {
                command("Undo", prefix: true)?.item.isEnabled == false && editor.project == before
            }
        } else {
            try performToolbarAction("Undo", window: window)
            // Dispatching to a disabled toolbar item can resign a field in an
            // inactive test window. That may expose recording Undo afterward,
            // but the click itself must never mutate the recording history.
            guard editor.project == before,
                  !title.isRenaming || !EditorUndoRouting.canUndo(editor: editor, window: window) else {
                throw ProbeError.failed("an empty native text stack fell through to recording history")
            }
        }
        if title.isRenaming { title.cancelOperation(nil) }
        try await waitUntil("cancel typing restores recording command routing") {
            !title.isRenaming && EditorUndoRouting.canUndo(editor: editor, window: window)
        }
    }

    private func inspectSaveCommands(_ editor: ProjectEditor, window: NSWindow, host: NSView, canvas: EditorCanvasView) async throws {
        window.makeKeyAndOrderFront(nil)
        guard let timeline: RecordingTimelineView = find(in: host) else { throw ProbeError.failed("missing timeline for Save boundary") }
        let baseline = measure(window: window, host: host, canvas: canvas, timeline: timeline)
        let shortcuts: [(String, String, NSEvent.ModifierFlags)] = [
            ("Save Recording", "s", .command), ("Save Video…", "e", .command),
            ("Share Video…", "e", [.command, .shift])
        ]
        for (title, key, modifiers) in shortcuts {
            guard let entry = command(title), entry.item.keyEquivalent == key,
                  entry.item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == modifiers else {
                throw ProbeError.failed("native File command '\(title)' lacks its expected keyboard shortcut")
            }
        }
        let before = editor.project
        guard let frame = window.contentView?.superview, let title: RecordingTitleField = find(in: frame) else {
            throw ProbeError.failed("missing native name field for Save validation")
        }
        title.beginRenaming()
        guard let text = title.currentEditor() as? NSTextView else { throw ProbeError.failed("native name field editor missing before Save") }
        text.string = "   "
        var chooserCalls = 0, renderCalls = 0
        let invalidSession = VideoExportSession(requiresProgressPresentation: false,
            chooser: { _, _, _ in chooserCalls += 1; return nil },
            renderer: { _, _, _, _, _, _ in renderCalls += 1 })
        invalidSession.window = window
        invalidSession.begin(editor: editor, sharing: false)
        guard !invalidSession.isBusy && invalidSession.errorMessage != nil && title.isRenaming &&
              chooserCalls == 0 && renderCalls == 0 && editor.project == before else {
            throw ProbeError.failed("an invalid active name must block export before destination selection or rendering")
        }
        title.cancelOperation(nil)
        try await Task.sleep(for: .milliseconds(50))
        var pending = before.state
        pending.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 1.8)]
        guard editor.updateDraft(pending, at: 2) else { throw ProbeError.failed("prepare pending edit for native Save") }
        let activeMenu = NSApplication.shared.keyWindow === window
        if activeMenu { try performCommand("Save Recording") }
        else if !EditorSaveRouting.save(editor: editor, window: window) { throw ProbeError.failed("associated-window Save failed") }
        try await waitUntil("native Save Recording finalizes one pending edit") {
            editor.draftState == nil && editor.project.state == pending &&
                editor.project.undoHistory.count == before.undoHistory.count + 1 && canvas.allowsZoomEditing
        }
        if activeMenu { try performCommand("Undo", prefix: true) }
        else { try performToolbarAction("Undo", window: window) }
        try await waitUntil("native Undo reverses the saved pending edit") {
            editor.project.state == before.state && canvas.allowsZoomEditing
        }
        let beforePanel = editor.project
        let profile = UserDefaults.standard.string(forKey: "export.preset")
        guard let share: VideoActionsMenuButton = find(in: frame),
              let menu = share.menu, let saveIndex = menu.items.firstIndex(where: { $0.title == "Save Video…" }) else {
            throw ProbeError.failed("missing native Save Video action")
        }
        if activeMenu { try performCommand("Save Video…") }
        else { menu.performActionForItem(at: saveIndex) }
        try await waitUntil("Save Video opens a native sheet on this editor window") {
            window.attachedSheet is NSSavePanel
        }
        guard let panel = window.attachedSheet as? NSSavePanel,
              let accessory = panel.accessoryView,
              let size: NSPopUpButton = find(in: accessory),
              size.itemTitles == VideoExportPreset.allCases.map(\.title),
              panel.nameFieldStringValue == editor.displayName + ".mp4" || panel.nameFieldStringValue == editor.displayName else {
            throw ProbeError.failed("native Save panel must use the recording name and offer all video size profiles")
        }
        try await waitUntil("a visible Save chooser must lock re-entry from toolbar and File commands") {
            !share.isEnabled && (!activeMenu || command("Save Video…")?.item.isEnabled == false)
        }
        size.selectItem(at: VideoExportPreset.allCases.count - 1)
        panel.cancel(nil)
        try await waitUntil("cancelling native Save restores toolbar actions") {
            window.attachedSheet == nil && share.isEnabled
        }
        guard editor.project == beforePanel && UserDefaults.standard.string(forKey: "export.preset") == profile else {
            throw ProbeError.failed("cancelled Save must preserve project history and the previously chosen output profile")
        }
        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
            baseline: baseline, context: "native Save chooser cancellation", compareScrolls: false)
    }

    /// Snapshot only this test's own synthetic window. This never reads the
    /// desktop, capture-source previews, user recordings, or other app windows.
    private func renderSyntheticWindow(window: NSWindow, host: NSView, timeline: RecordingTimelineView) async {
        guard let directoryPath = ProcessInfo.processInfo.environment["FRAMETHROWER_REVIEW_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let appearance = window.appearance
        let colorScheme = reviewColorScheme
        let contentSize = host.frame.size
        defer { reviewColorScheme = colorScheme; window.appearance = appearance; window.setContentSize(contentSize) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let marker = timeline.edits.first {
                let point = CGPoint(x: timeline.x(for: marker.time), y: 47)
                timeline.mouseDown(with: mouse(.leftMouseDown, at: point, in: timeline, window: window))
                timeline.mouseUp(with: mouse(.leftMouseUp, at: point, in: timeline, window: window))
                try await Task.sleep(for: .milliseconds(100))
            }
            for (name, mode) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                reviewColorScheme = name == "light" ? .light : .dark
                window.appearance = NSAppearance(named: mode)
                for width in [820.0, 940.0] {
                    window.setContentSize(CGSize(width: width, height: 780))
                    try await Task.sleep(for: .milliseconds(150))
                    guard let frame = window.contentView?.superview else { continue }
                    frame.layoutSubtreeIfNeeded()
                    guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
                    frame.cacheDisplay(in: frame.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        let url = directory.appendingPathComponent("editor-\(name)-\(Int(width)).png")
                        try png.write(to: url)
                        output("Synthetic native window render: \(url.path)")
                    }
                }
            }
        } catch { output("Synthetic native window renders unavailable: \(error)") }
    }

    private func inspectWindow() async throws {
        let deadline = Date().addingTimeInterval(10)
        var resolved: (NSWindow, NSView, EditorCanvasView, RecordingTimelineView)?
        while Date() < deadline {
            for window in NSApplication.shared.windows {
                guard let host = window.contentView, let canvas: EditorCanvasView = find(in: host),
                      let timeline: RecordingTimelineView = find(in: host),
                      canvas.playerLayer.player?.currentItem?.status == .readyToPlay else { continue }
                resolved = (window, host, canvas, timeline)
                break
            }
            if resolved != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let (window, host, canvas, timeline) = resolved else { throw ProbeError.failed("real editor scene never became ready") }
        try await Task.sleep(for: .milliseconds(300))
        if ProcessInfo.processInfo.environment["FRAMETHROWER_EDIT_CHECKS_ONLY"] == "1" { return }
        for width in [940.0, 820.0] {
            window.setContentSize(CGSize(width: width, height: 780))
            try await Task.sleep(for: .milliseconds(150))
            let baseline = measure(window: window, host: host, canvas: canvas, timeline: timeline)
            output("WindowGroup baseline at width \(width): \(baseline)")
            guard let inspector = findInspector(in: host),
                  let action = inspector.action else {
                throw ProbeError.failed("missing native editor inspector control")
            }
            for segment in [1, 2, 3, 4, 0] {
                inspector.selectedSegment = segment
                guard inspector.sendAction(action, to: inspector.target) else {
                    throw ProbeError.failed("inspector segment action was not delivered")
                }
                try await Task.sleep(for: .milliseconds(80))
                let cameraShapeVisible = findAll(NSSegmentedControl.self, in: host).contains {
                    segmentLabels($0).contains("Original") && segmentLabels($0).contains("Circle")
                }
                guard cameraShapeVisible == (segment == 2) else {
                    throw ProbeError.failed("inspector selection did not change the production controls")
                }
                try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                                 baseline: baseline, context: "width \(width), inspector segment \(segment)", compareScrolls: false)
            }
            for cycle in 0..<3 {
                let timelineRect = host.convert(timeline.bounds, from: timeline)
                let play = CGPoint(x: timelineRect.minX - 35, y: timelineRect.midY)
                window.sendEvent(mouse(.leftMouseDown, at: play, in: host, window: window))
                window.sendEvent(mouse(.leftMouseUp, at: play, in: host, window: window))
                for index in 0..<40 {
                    try await Task.sleep(for: .milliseconds(10))
                    try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                                     baseline: baseline, context: "width \(width), cycle \(cycle), Play tick \(index)")
                }
                guard (canvas.playerLayer.player?.rate ?? 0) > 0 else { throw ProbeError.failed("native Play click did not start playback") }

                let handle = CGPoint(x: timeline.x(for: timeline.trimStart) + 4, y: 24)
                timeline.mouseDown(with: mouse(.leftMouseDown, at: handle, in: timeline, window: window))
                for index in 0..<20 {
                    try await Task.sleep(for: .milliseconds(10))
                    try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                                     baseline: baseline, context: "width \(width), cycle \(cycle), trim handle mouse-down tick \(index)")
                }
                timeline.mouseUp(with: mouse(.leftMouseUp, at: handle, in: timeline, window: window))
                for seconds in [1.8, 2.1, 2.6, 3.1, 2.3, 1.9] {
                    let location = CGPoint(x: timeline.x(for: seconds), y: 6)
                    timeline.mouseDown(with: mouse(.leftMouseDown, at: location, in: timeline, window: window))
                    timeline.mouseUp(with: mouse(.leftMouseUp, at: location, in: timeline, window: window))
                    for index in 0..<10 {
                        try await Task.sleep(for: .milliseconds(10))
                        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                                         baseline: baseline, context: "width \(width), cycle \(cycle), scrub \(seconds) tick \(index)")
                    }
                }
            }
        }
    }

    private func inspectCombinedEditing(_ editor: ProjectEditor, window: NSWindow, host: NSView,
                                        canvas: EditorCanvasView, timeline: RecordingTimelineView) async throws {
        let zoomID = UUID(), cameraID = UUID()
        var initial = editor.project.state
        initial.trimStart = 0
        initial.trimEnd = 4
        initial.zoomKeyframes = [ZoomKeyframe(id: zoomID, time: 1, scale: 1.4)]
        var camera = PIPPlacement()
        camera.x = 0.6; camera.y = 0.6; camera.scale = 0.25
        initial.pipKeyframes.append(PIPKeyframe(id: cameraID, time: 1, placement: camera))
        guard editor.commit(initial, name: "Prepare combined-edit fixture") else {
            throw ProbeError.failed("prepare combined-edit fixture")
        }
        try await waitUntil("combined editor becomes ready") {
            canvas.allowsZoomEditing && timeline.edits.contains { $0.id == zoomID }
        }
        let before = editor.project
        let savedBytes = try Data(contentsOf: editor.url)
        let diamond = CGPoint(x: timeline.x(for: 1), y: 47)
        timeline.mouseDown(with: mouse(.leftMouseDown, at: diamond, in: timeline, window: window))
        timeline.mouseUp(with: mouse(.leftMouseUp, at: diamond, in: timeline, window: window))
        try await waitUntil("diamond selection seeks and highlights the existing edit") {
            timeline.selectedEditID == zoomID && abs(timeline.playhead - 1) < 0.001 &&
                abs(canvas.zoom.scale - 1.4) < 0.001 && canvas.allowsZoomEditing
        }
        let baseline = measure(window: window, host: host, canvas: canvas, timeline: timeline)
        let touch = IntegratedTrackpadEvent()
        touch.position = canvas.convert(CGPoint(x: canvas.canvasRect.minX + canvas.canvasRect.width * 0.4,
            y: canvas.canvasRect.minY + canvas.canvasRect.height * 0.4), to: nil)
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            touch.amount = phase == .ended ? 0 : 0.1
            touch.eventPhase = phase
            canvas.magnify(with: touch)
            try await Task.sleep(for: .milliseconds(30))
        }
        guard editor.draftState != nil, editor.project == before else {
            throw ProbeError.failed("pinch must create a draft without persisting its finger samples")
        }
        let cameraRect = canvas.placement.frame(in: canvas.canvasRect.size, cameraAspect: 16.0 / 9)
            .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let cameraCenter = CGPoint(x: cameraRect.midX, y: cameraRect.midY)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: cameraCenter, in: canvas, window: window))
        for delta in [10.0, 20, 30] {
            canvas.mouseDragged(with: mouse(.leftMouseDragged,
                at: CGPoint(x: cameraCenter.x + delta, y: cameraCenter.y - delta / 2), in: canvas, window: window))
            try await Task.sleep(for: .milliseconds(30))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp,
            at: CGPoint(x: cameraCenter.x + 30, y: cameraCenter.y - 15), in: canvas, window: window))
        try await Task.sleep(for: .milliseconds(30))
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            touch.eventPhase = phase
            touch.dx = phase == .ended ? 0 : 8
            touch.dy = phase == .ended ? 0 : 6
            canvas.scrollWheel(with: touch)
            try await Task.sleep(for: .milliseconds(30))
        }
        guard let draft = editor.draftState,
              editor.project == before, try Data(contentsOf: editor.url) == savedBytes,
              editor.draftTime == 1,
              draft.zoomKeyframes.count == initial.zoomKeyframes.count,
              draft.pipKeyframes.count == initial.pipKeyframes.count,
              draft.zoomKeyframes.first?.id == zoomID,
              draft.pipKeyframes.last?.id == cameraID,
              draft.zoomKeyframes.first?.scale != initial.zoomKeyframes.first?.scale,
              draft.pipKeyframes.last?.placement != initial.pipKeyframes.last?.placement,
              draft.timedEdits(includeCamera: true).filter({ $0.time == 1 }).count == 1 else {
            throw ProbeError.failed("zoom, pan, and camera samples must revise the selected IDs in one shared unsaved edit")
        }
        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
            baseline: baseline, context: "combined draft", compareScrolls: false)
        let leave = CGPoint(x: timeline.x(for: 2.4), y: 6)
        timeline.mouseDown(with: mouse(.leftMouseDown, at: leave, in: timeline, window: window))
        timeline.mouseUp(with: mouse(.leftMouseUp, at: leave, in: timeline, window: window))
        try await waitUntil("leaving edit time finalizes one combined edit") {
            editor.draftState == nil && editor.project.state == draft &&
                editor.project.undoHistory.count == before.undoHistory.count + 1 && timeline.selectedEditID == nil
        }
        try performToolbarAction("Undo", window: window)
        try await waitUntil("Undo restores both zoom and camera together") {
            editor.project.state == initial && editor.project.undoHistory.count == before.undoHistory.count &&
                canvas.allowsZoomEditing
        }
        guard editor.redo() else { throw ProbeError.failed("redo combined edit") }
        try await waitUntil("redo rebuilds the combined edit") {
            editor.project.state == draft && canvas.allowsZoomEditing && timeline.edits.contains { $0.id == zoomID }
        }
        let beforeMove = editor.project
        let from = CGPoint(x: timeline.x(for: 1), y: 47)
        let to = CGPoint(x: timeline.x(for: 1.5), y: 47)
        timeline.mouseDown(with: mouse(.leftMouseDown, at: from, in: timeline, window: window))
        timeline.mouseDragged(with: mouse(.leftMouseDragged, at: to, in: timeline, window: window))
        try await Task.sleep(for: .milliseconds(30))
        guard editor.project == beforeMove, editor.draftState != nil else {
            throw ProbeError.failed("diamond movement must preview without intermediate persistence")
        }
        timeline.mouseUp(with: mouse(.leftMouseUp, at: to, in: timeline, window: window))
        try await waitUntil("diamond move commits both tracks once") {
            editor.draftState == nil && editor.project.undoHistory.count == beforeMove.undoHistory.count + 1 &&
                editor.project.state.zoomKeyframes.first?.time == 1.5 &&
                editor.project.state.pipKeyframes.last?.time == 1.5 && canvas.allowsZoomEditing
        }
        let moved = editor.project
        guard let strip = findAll(NSScrollView.self, in: host).first,
              let document = strip.documentView, document.bounds.width > 28 else {
            throw ProbeError.failed("native edit-strip anchor for inline X")
        }
        // This fixture has exactly one edit chip. Its trailing padding is 4pt
        // and its X target is 20pt wide, so the center is 14pt from its end.
        let removeCenter = host.convert(CGPoint(x: document.bounds.maxX - 14,
            y: document.bounds.midY), from: document)
        window.sendEvent(mouse(.leftMouseDown, at: removeCenter, in: host, window: window))
        window.sendEvent(mouse(.leftMouseUp, at: removeCenter, in: host, window: window))
        try await waitUntil("inline X removes both tracks as one edit") {
            editor.project.undoHistory.count == moved.undoHistory.count + 1 &&
                editor.project.state.zoomKeyframes.isEmpty && editor.project.state.pipKeyframes.count == 1
        }
        guard editor.undo(), editor.project.state == moved.state else {
            throw ProbeError.failed("Undo must restore the whole removed edit")
        }
        try await waitUntil("undo deletion rebuilds editor") { canvas.allowsZoomEditing }
        try await inspectSelectionLifecycle(editor, window: window, host: host, canvas: canvas, timeline: timeline)
        try await inspectCanvasPresentation(editor, window: window, host: host, canvas: canvas, timeline: timeline)
    }

    private func inspectCanvasPresentation(_ editor: ProjectEditor, window: NSWindow, host: NSView,
                                           canvas: EditorCanvasView, timeline: RecordingTimelineView) async throws {
        guard let inspector = findInspector(in: host), let action = inspector.action else {
            throw ProbeError.failed("missing Canvas inspector tab")
        }
        inspector.selectedSegment = 3
        guard inspector.sendAction(action, to: inspector.target) else { throw ProbeError.failed("Canvas tab action failed") }
        try await Task.sleep(for: .milliseconds(50))
        guard let aspect = findAll(NSSegmentedControl.self, in: host).first(where: {
            segmentLabels($0) == ["Source", "16:9", "9:16", "Square"]
        }), let aspectAction = aspect.action else {
            throw ProbeError.failed("Canvas inspector did not expose its native aspect selector")
        }
        let before = editor.project
        let playhead = timeline.playhead
        let baseline = measure(window: window, host: host, canvas: canvas, timeline: timeline)
        aspect.selectedSegment = 2
        guard aspect.sendAction(aspectAction, to: aspect.target) else { throw ProbeError.failed("portrait aspect action failed") }
        try await waitUntil("Canvas aspect selection updates the rendered output") {
            editor.project.state.presentation.aspect == .portrait && canvas.allowsZoomEditing &&
                abs(canvas.canvasRect.width / canvas.canvasRect.height - 9.0 / 16) < 0.000001
        }
        guard editor.draftState == nil && editor.project.undoHistory.count == before.undoHistory.count + 1 &&
              editor.project.state.zoomKeyframes == before.state.zoomKeyframes &&
              editor.project.state.pipKeyframes == before.state.pipKeyframes &&
              abs(canvas.contentRect.width / canvas.contentRect.height - 16.0 / 9) < 0.000001 else {
            throw ProbeError.failed("Canvas aspect must be one whole-recording edit, preserving source and timed geometry")
        }
        var portraitLayout = measure(window: window, host: host, canvas: canvas, timeline: timeline)
        // Only the intentional output aspect changes; the window, canvas view,
        // timeline and inspector keep their existing native allocations.
        portraitLayout.player = baseline.player
        try assertStable(portraitLayout, baseline: baseline, context: "portrait output preserves editor layout", compareScrolls: false)
        let portrait = editor.project
        let touch = IntegratedTrackpadEvent()
        touch.position = canvas.convert(CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.midY), to: nil)
        for phase in [NSEvent.Phase.began, .changed, .ended] {
            touch.eventPhase = phase
            touch.amount = phase == .ended ? 0 : 0.05
            canvas.magnify(with: touch)
            try await Task.sleep(for: .milliseconds(30))
        }
        guard editor.draftState != nil && editor.project == portrait && editor.editingState.presentation == portrait.state.presentation else {
            throw ProbeError.failed("pinching the fitted recording must revise framing without changing or persisting the output canvas")
        }
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        try await waitUntil("Escape cancels framing without reverting the output canvas") {
            editor.draftState == nil && editor.project == portrait && canvas.allowsZoomEditing
        }
        try performToolbarAction("Undo", window: window)
        try await waitUntil("toolbar Undo restores source canvas without seeking") {
            editor.project.state == before.state && editor.historyNavigationTime == nil &&
                abs(timeline.playhead - playhead) < 0.000001 && canvas.allowsZoomEditing
        }
        try performToolbarAction("Redo", window: window)
        try await waitUntil("toolbar Redo restores portrait canvas without seeking") {
            editor.project.state == portrait.state && editor.historyNavigationTime == nil &&
                abs(timeline.playhead - playhead) < 0.000001 && canvas.allowsZoomEditing
        }
        inspector.selectedSegment = 3
        guard inspector.sendAction(action, to: inspector.target) else { throw ProbeError.failed("restore Canvas inspector for review") }
        try await Task.sleep(for: .milliseconds(30))
    }

    private func inspectSelectionLifecycle(_ editor: ProjectEditor, window: NSWindow, host: NSView,
                                           canvas: EditorCanvasView, timeline: RecordingTimelineView) async throws {
        guard let edit = editor.project.state.timedEdits(includeCamera: true).first else {
            throw ProbeError.failed("missing edit for selection lifecycle fixture")
        }
        var smooth = editor.project.state
        if let index = smooth.zoomKeyframes.firstIndex(where: { $0.id == edit.zoomID }) {
            smooth.zoomKeyframes[index].transition = .smooth
            smooth.zoomKeyframes[index].duration = 0.8
        }
        guard editor.commit(smooth, name: "Prepare smooth selection fixture") else {
            throw ProbeError.failed("prepare smooth selection fixture")
        }
        try await waitUntil("selection fixture becomes ready") { canvas.allowsZoomEditing }
        guard let inspector = findInspector(in: host),
              let action = inspector.action else {
            throw ProbeError.failed("missing native inspector for smooth selection")
        }
        inspector.selectedSegment = 0
        guard inspector.sendAction(action, to: inspector.target) else {
            throw ProbeError.failed("could not select zoom inspector")
        }
        try await Task.sleep(for: .milliseconds(50))
        let baseline = measure(window: window, host: host, canvas: canvas, timeline: timeline)

        func select() async throws {
            let diamond = CGPoint(x: timeline.x(for: edit.time), y: 47)
            timeline.mouseDown(with: mouse(.leftMouseDown, at: diamond, in: timeline, window: window))
            timeline.mouseUp(with: mouse(.leftMouseUp, at: diamond, in: timeline, window: window))
            try await waitUntil("selected edit exposes its native transition duration") {
                timeline.selectedEditID == edit.id && abs(timeline.playhead - edit.time) < 0.000001 &&
                    canvas.allowsZoomEditing && canvas.stillLayer.contents != nil &&
                    (find(in: host) as MotionDurationTextField?) != nil
            }
            try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                             baseline: baseline, context: "show selected transition", compareScrolls: false)
        }
        func pinch() async throws {
            let touch = IntegratedTrackpadEvent()
            touch.position = canvas.convert(CGPoint(x: canvas.canvasRect.midX, y: canvas.canvasRect.midY), to: nil)
            for phase in [NSEvent.Phase.began, .changed, .ended] {
                touch.eventPhase = phase
                touch.amount = phase == .ended ? 0 : 0.05
                canvas.magnify(with: touch)
                try await Task.sleep(for: .milliseconds(30))
            }
            try await waitUntil("pinch revises selected edit as one pending draft") {
                editor.draftState != nil && canvas.stillLayer.contents != nil
            }
        }
        func escape() -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)!
        }

        try await select()
        let beforeBlank = editor.project
        guard let duration: MotionDurationTextField = find(in: host) else {
            throw ProbeError.failed("selected smooth edit lacks native duration input")
        }
        duration.stringValue = "1.25"
        duration.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: duration))
        try await waitUntil("numeric duration refines selected edit without saving") {
            editor.draftState?.zoomKeyframes.first(where: { $0.id == edit.zoomID })?.duration == 1.25 &&
                editor.project == beforeBlank
        }
        let afterDuration = editor.draftState
        for invalid in ["0", "NaN"] {
            duration.stringValue = invalid
            duration.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: duration))
            try await Task.sleep(for: .milliseconds(30))
            guard editor.draftState == afterDuration && editor.project == beforeBlank else {
                throw ProbeError.failed("invalid duration '\(invalid)' changed the edit or its saved history")
            }
        }
        try await pinch()
        guard let draft = editor.draftState else { throw ProbeError.failed("missing draft before blank-lane click") }
        guard editor.project == beforeBlank,
              draft.zoomKeyframes.first(where: { $0.id == edit.zoomID })?.duration == 1.25 else {
            throw ProbeError.failed("pinch must retain numeric duration in the same unsaved edit")
        }
        let playheadBeforeBlank = timeline.playhead
        let sourceTimeBeforeBlank = canvas.playerLayer.player?.currentTime().seconds ?? -.infinity
        let blank = CGPoint(x: timeline.x(for: 3.5), y: 47)
        timeline.mouseDown(with: mouse(.leftMouseDown, at: blank, in: timeline, window: window))
        timeline.mouseUp(with: mouse(.leftMouseUp, at: blank, in: timeline, window: window))
        try await waitUntil("blank edit lane finalizes and deselects without scrubbing") {
            editor.draftState == nil && timeline.selectedEditID == nil &&
                editor.project.state == draft && editor.project.undoHistory.count == beforeBlank.undoHistory.count + 1 &&
                canvas.allowsZoomEditing && canvas.stillLayer.contents != nil
        }
        guard abs(timeline.playhead - playheadBeforeBlank) < 0.000001,
              abs((canvas.playerLayer.player?.currentTime().seconds ?? -.infinity) - sourceTimeBeforeBlank) < 0.000001 else {
            throw ProbeError.failed("blank edit-lane deselection must keep the playhead and source frame")
        }
        guard (find(in: host) as MotionDurationTextField?) == nil else {
            throw ProbeError.failed("deselected transition duration remains in the native accessibility hierarchy")
        }
        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                         baseline: baseline, context: "blank-lane deselection hides transitions", compareScrolls: false)

        try await select()
        let beforeEscape = editor.project
        try await pinch()
        canvas.keyDown(with: escape())
        try await waitUntil("Escape discards draft and deselects the edit") {
            editor.draftState == nil && timeline.selectedEditID == nil && editor.project == beforeEscape &&
                canvas.allowsZoomEditing && canvas.stillLayer.contents != nil
        }
        guard (find(in: host) as MotionDurationTextField?) == nil else {
            throw ProbeError.failed("Escape must remove transition controls from the native hierarchy")
        }
        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                         baseline: baseline, context: "Escape cancels and hides transitions", compareScrolls: false)

        try await select()
        let beforeCleanEscape = editor.project
        guard editor.draftState == nil else { throw ProbeError.failed("selection alone created a draft") }
        timeline.keyDown(with: escape())
        try await waitUntil("Escape deselects a clean edit without history mutation") {
            timeline.selectedEditID == nil && editor.draftState == nil && editor.project == beforeCleanEscape
        }
        guard (find(in: host) as MotionDurationTextField?) == nil else {
            throw ProbeError.failed("clean Escape must hide transition controls")
        }
        try assertStable(measure(window: window, host: host, canvas: canvas, timeline: timeline),
                         baseline: baseline, context: "clean Escape leaves geometry fixed", compareScrolls: false)
    }

    private func waitUntil(_ context: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProbeError.failed(context) }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Let production SwiftUI callbacks settle before the next input.
        try await Task.sleep(for: .milliseconds(30))
    }

    private struct Measurements: CustomStringConvertible {
        var window: CGRect
        var host: CGRect
        var fitting: CGSize
        var canvas: CGRect
        var player: CGRect
        var timeline: CGRect
        var scrolls: [CGRect]
        var description: String {
            "window=\(window), host=\(host), fitting=\(fitting), canvas=\(canvas), player=\(player), timeline=\(timeline), scrolls=\(scrolls)"
        }
        var rectangles: [CGRect] { [window, host, CGRect(origin: .zero, size: fitting), canvas, player, timeline] + scrolls }
    }

    private func measure(window: NSWindow, host: NSView, canvas: EditorCanvasView,
                         timeline: RecordingTimelineView) -> Measurements {
        host.layoutSubtreeIfNeeded()
        return Measurements(window: window.frame, host: host.frame, fitting: host.fittingSize,
            canvas: host.convert(canvas.bounds, from: canvas), player: host.convert(canvas.canvasRect, from: canvas),
            timeline: host.convert(timeline.bounds, from: timeline),
            scrolls: findAll(NSScrollView.self, in: host).map { host.convert($0.bounds, from: $0) })
    }

    private func assertStable(_ value: Measurements, baseline: Measurements, context: String,
                              compareScrolls: Bool = true) throws {
        let actualRects = compareScrolls ? value.rectangles : Array(value.rectangles.prefix(6))
        let expectedRects = compareScrolls ? baseline.rectangles : Array(baseline.rectangles.prefix(6))
        for (actual, expected) in zip(actualRects, expectedRects) {
            guard abs(actual.minX - expected.minX) < 0.5, abs(actual.minY - expected.minY) < 0.5,
                  abs(actual.width - expected.width) < 0.5, abs(actual.height - expected.height) < 0.5 else {
                throw ProbeError.failed("\(context) resized/reflowed. Before: \(baseline). After: \(value)")
            }
        }
    }

    private func find<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(in: $0) as T? }.first
    }

    private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { self.findAll(type, in: $0) }
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private func output(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}
