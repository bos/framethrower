import AppKit
import SwiftUI

private enum RowCheckError: Error { case failed(String) }

/// Synthetic metadata/movie and an offscreen native window only. No capture
/// model, screen permission, camera session, or user recording is involved.
@main
@MainActor
struct RecordingRowChecks {
    static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await run(); Darwin.exit(0) }
            catch {
                FileHandle.standardError.write(Data("Recording row checks failed: \(error)\n".utf8))
                Darwin.exit(1)
            }
        }
        // AVFoundation thumbnail callbacks and AppKit's key-view loop share
        // the Cocoa run loop. Keep it alive until the async fixture finishes.
        app.run()
        FileHandle.standardError.write(Data("Recording row fixture stopped before completing its checks.\n".utf8))
        Darwin.exit(1)
    }

    private static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("screen.mp4")
        let sourceBytes = Data("immutable source fixture".utf8)
        try sourceBytes.write(to: source)
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "screen.mp4", duration: 5, title: "My recording"),
            url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "save fixture")
        let entry = RecordingLibraryEntry(projectURL: editor.url, sourceURL: source,
            displayName: editor.displayName, duration: 5, fileSize: Int64(sourceBytes.count), createdAt: Date())
        var removed = 0
        var opened = 0
        var selectedEditor: ProjectEditor?
        let host = NSHostingView(rootView: RecordingLibraryRow(entry: entry, isLocked: false,
            editorForURL: { _ in editor }, onOpen: { opened += 1 }, onShare: { false },
            shareContent: { AnyView(EmptyView()) }, onSelectEditor: { selectedEditor = $0 }, onRemove: { removed += 1 })
            .frame(width: 280, height: RecordingLibraryRow.height))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 280, height: RecordingLibraryRow.height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        guard let button: RecordingRemoveButtonView = find(in: host),
              let open: RecordingOpenButtonView = find(in: host),
              let title: RecordingTitleField = find(in: host) else { throw RowCheckError.failed("native row controls") }
        try require(title.bounds.width >= 200, "narrow sidebar should reserve useful full-width name space")
        let down = mouse(.leftMouseDown, target: button, window: window, count: 1)
        try require(button.acceptsFirstMouse(for: down), "remove must accept the activating click in an inactive window")
        window.resignKey()
        let hit = host.hitTest(button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.superview))
        try require(hit === button, "the X must receive its hit directly instead of a focusable row wrapper")
        button.performClick(nil)
        try require(removed == 1 && opened == 0 && !title.isRenaming,
                    "one initial remove click must act once without selecting/opening/renaming the row")
        button.isEnabled = false
        button.performClick(nil)
        try require(removed == 1, "locked remove must not fire")
        button.isEnabled = true

        try require(open.acceptsFirstMouse(for: down), "thumbnail must accept the initial activating click")
        let openHit = host.hitTest(open.convert(CGPoint(x: open.bounds.midX, y: open.bounds.midY), to: host.superview))
        try require(openHit === open && open.bounds.width == 48 && open.bounds.height == 28,
                    "the thumbnail has its own direct open target without reducing name width")
        open.performClick(nil)
        try require(opened == 1 && selectedEditor === editor && removed == 1 && !title.isRenaming,
                    "a single thumbnail press opens and selects its shared editor without removing or renaming")
        open.isEnabled = false
        open.performClick(nil)
        try require(opened == 1, "locked thumbnail does not open")
        open.isEnabled = true
        let anchor = NSTextField(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        host.addSubview(anchor)
        anchor.nextKeyView = open
        open.nextKeyView = anchor
        window.makeFirstResponder(anchor)
        window.selectKeyView(following: anchor)
        try require(window.firstResponder === open && selectedEditor === editor,
                    "Tab can focus the thumbnail and selects its editor for commands")
        for code: UInt16 in [36, 49] {
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code)!
            open.keyDown(with: key)
        }
        try require(opened == 3 && removed == 1 && !title.isRenaming,
                    "Return and Space each open the focused recording once")
        anchor.removeFromSuperview()

        window.makeKey()
        let beforeDoubleClick = opened
        let titleHit = host.hitTest(title.convert(CGPoint(x: title.bounds.midX, y: title.bounds.midY), to: host.superview))
        try require(titleHit === title, "thumbnail focus must not steal hit testing from the full-width name")
        for count in [1, 2] {
            window.sendEvent(mouse(.leftMouseDown, target: title, window: window, count: count))
            window.sendEvent(mouse(.leftMouseUp, target: title, window: window, count: count))
        }
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        try require(opened == beforeDoubleClick + 1 && removed == 1 && !title.isRenaming,
                    "double-clicking the name must open once without row background stealing or starting rename")
        title.beginRenaming()
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        try require(title.isRenaming && !button.isEnabled,
                    "row removal must be disabled and hidden throughout name editing")
        button.performClick(nil)
        try require(removed == 1, "the removal control cannot dismiss a row while its name is being edited")
        guard let editing = window.fieldEditor(false, for: title) as? NSTextView else {
            throw RowCheckError.failed("rename field editor")
        }
        editing.string = "Uncommitted name"
        _ = title.control(title, textView: editing, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        try require(!title.isRenaming && button.isEnabled && editor.displayName == "My recording" && removed == 1,
                    "Escape cancels the name and safely restores the row action")
        try require(try Data(contentsOf: source) == sourceBytes && !editor.canUndo,
                    "row navigation/removal callbacks must not alter media or edit history")
        window.makeFirstResponder(open)
        let beforeRemove = removed
        button.performClick(nil)
        try require(removed == beforeRemove + 1 && window.firstResponder !== open,
                    "removal releases thumbnail focus before its row disappears")
        try await checkThumbnailCache(directory: directory)
        try await checkVideoActions(directory: directory, first: editor)
        print("Recording row checks passed (first-click remove/open, keyboard opening, rename protection, bounded thumbnails, per-recording Save/Share/Upload, export cancellation, and once-only sharing after progress dismissal).")
    }

    private static func checkVideoActions(directory: URL, first: ProjectEditor) async throws {
        try Data("second original".utf8).write(to: directory.appendingPathComponent("second.mp4"))
        let second = ProjectEditor(project: RecordingProject(screenFilename: "second.mp4", duration: 5, title: "Second recording"),
            url: directory.appendingPathComponent("second.framethrower"))
        try require(second.save(), "save second recording fixture")
        var selectedURL: URL?, chooserNames: [String] = [], renderedSources: [String] = [], destinations: [URL] = []
        var holdRender = false, uploads = 0
        let session = VideoExportSession(requiresProgressPresentation: false,
            chooser: { name, _, _ in
                chooserNames.append(name)
                try? await Task.sleep(for: .milliseconds(30))
                return nil
            }, renderer: { project, _, url, _, _, progress in
                renderedSources.append(project.screenFilename)
                destinations.append(url)
                if holdRender { try await Task.sleep(for: .seconds(5)) }
                try Data("synthetic prepared video".utf8).write(to: url)
                progress(1)
            })
        defer { for url in destinations { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) } }
        func entry(_ editor: ProjectEditor) -> RecordingLibraryEntry {
            RecordingLibraryEntry(projectURL: editor.url, sourceURL: editor.mediaURL(for: editor.project.screenFilename),
                displayName: editor.displayName, duration: 5, fileSize: 20, createdAt: Date())
        }
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            RecordingLibraryRow(entry: entry(first), isLocked: false, editorForURL: { _ in first },
                onOpen: {}, onShare: { uploads += 1; return false }, shareContent: { AnyView(EmptyView()) },
                onSelectEditor: { selectedURL = $0.url }, exportSession: session)
            RecordingLibraryRow(entry: entry(second), isLocked: false, editorForURL: { _ in second },
                onOpen: {}, onShare: { false }, shareContent: { AnyView(EmptyView()) },
                onSelectEditor: { selectedURL = $0.url }, exportSession: session)
        }.frame(width: 280, height: 160))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 280, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { session.cancel(); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let buttons = findAll(VideoActionsMenuButton.self, in: host)
        guard let firstMenu = buttons.first(where: { $0.accessibilityLabel() == "Share My recording" }),
              let secondMenu = buttons.first(where: { $0.accessibilityLabel() == "Share Second recording" }) else {
            throw RowCheckError.failed("native recording video action menus")
        }
        try require(firstMenu.acceptsFirstMouse(for: nil) && firstMenu.menu?.items.map(\.title) == ["Share", "Save Video…", "Share Video…", "", "Upload…"],
                    "each row uses the standard share menu with distinct Save, system Share, and optional Upload actions")
        firstMenu.menu?.performActionForItem(at: 1)
        try require(session.isBusy && selectedURL == first.url && session.currentProjectURL == first.url,
                    "Save selects and snapshots the clicked row before presenting its chooser")
        session.begin(editor: second, sharing: true)
        try require(session.currentProjectURL == first.url, "an active chooser cannot be replaced with another recording")
        try await waitUntil("cancelled save chooser finishes") { !session.isBusy }
        try require(chooserNames == ["My recording.mp4"] && renderedSources.isEmpty,
                    "cancelled Save uses that row's name and renders nothing")
        secondMenu.menu?.performActionForItem(at: 2)
        try await waitUntil("second-row Share preparation finishes") { !session.isBusy }
        try require(selectedURL == second.url && session.currentProjectURL == second.url && renderedSources == ["second.mp4"],
                    "Share renders the selected recording, independent of the previously selected row")
        guard let shared = session.shareURL else { throw RowCheckError.failed("prepared share URL") }
        try require(FileManager.default.fileExists(atPath: shared.path) && session.shareRequest == nil,
                    "a prepared video remains available but the system picker waits for progress dismissal")
        session.progressDidDismiss()
        let request = session.shareRequest
        session.progressDidDismiss()
        try require(request != nil && session.shareRequest == request && FileManager.default.fileExists(atPath: shared.path),
                    "progress dismissal triggers sharing exactly once and keeps the temporary movie valid")
        firstMenu.menu?.performActionForItem(at: 4)
        try require(uploads == 1 && selectedURL == first.url, "Upload selects its own row before opening the existing upload flow")
        holdRender = true
        secondMenu.menu?.performActionForItem(at: 2)
        try await waitUntil("cancellable preparation starts") { session.isExporting && renderedSources.count == 2 }
        session.cancel()
        try await waitUntil("preparation cancellation finishes") { !session.isBusy }
        try require(session.shareURL == nil && session.shareRequest == nil && session.errorMessage == nil,
                    "Cancel creates neither an error alert nor a share request")
        var fastRenders = 0
        let handshake = VideoExportSession(renderer: { _, _, url, _, _, progress in
            fastRenders += 1; destinations.append(url)
            try Data("fast prepared video".utf8).write(to: url); progress(1)
        })
        handshake.begin(editor: first, sharing: true)
        try await waitUntil("progress presentation is requested") { handshake.isExporting }
        try require(fastRenders == 0, "even an instant renderer waits until its progress sheet appears")
        handshake.progressDidAppear()
        try await waitUntil("instant preparation completes") { handshake.shareURL != nil && !handshake.isExporting }
        try require(handshake.isBusy && handshake.shareRequest == nil,
                    "an instant export keeps actions locked until its sheet actually dismisses")
        handshake.progressDidDismiss()
        let fastRequest = handshake.shareRequest
        handshake.progressDidDismiss()
        try require(!handshake.isBusy && fastRequest != nil && handshake.shareRequest == fastRequest,
                    "instant preparation follows the same once-only dismissal handshake")
    }

    private static func waitUntil(_ context: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RowCheckError.failed(context) }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
    }

    private static func checkThumbnailCache(directory: URL) async throws {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = context.makeImage()!
        var loads = 0, active = 0, peak = 0
        let cache = RecordingThumbnailCache(capacity: 2, concurrency: 2, loader: { _ in
            loads += 1; active += 1; peak = max(peak, active)
            try? await Task.sleep(for: .milliseconds(20))
            active -= 1
            return image
        })
        let urls = (0..<8).map { directory.appendingPathComponent("thumbnail-\($0).mov") }
        _ = await cache.thumbnail(for: urls[0]); _ = await cache.thumbnail(for: urls[0])
        try require(loads == 1, "repeated visible thumbnail requests reuse the cached image")
        _ = await cache.thumbnail(for: urls[1]); _ = await cache.thumbnail(for: urls[2])
        try require(cache.cachedCount == 2, "thumbnail memory is bounded by its configured capacity")
        _ = await cache.thumbnail(for: urls[0])
        try require(loads == 4, "least-recently-used thumbnails are evicted")
        let tasks = urls.map { url in Task { @MainActor in await cache.thumbnail(for: url) } }
        for task in tasks { _ = await task.value }
        try require(peak <= 2 && cache.cachedCount <= 2, "thumbnail decoding and memory remain bounded under concurrent requests")
        var cancelledLoads = 0
        let cancellable = RecordingThumbnailCache(concurrency: 1, loader: { _ in
            cancelledLoads += 1
            try? await Task.sleep(for: .milliseconds(60))
            return image
        })
        let activeRequest = Task { @MainActor in await cancellable.thumbnail(for: urls[0]) }
        try await Task.sleep(for: .milliseconds(5))
        let waitingRequest = Task { @MainActor in await cancellable.thumbnail(for: urls[1]) }
        try await Task.sleep(for: .milliseconds(5))
        waitingRequest.cancel()
        _ = await waitingRequest.value
        _ = await activeRequest.value
        try require(cancelledLoads == 1, "scrolling away cancels queued thumbnails before opening their media")
        var misses = 0
        let missing = RecordingThumbnailCache(loader: { _ in misses += 1; return nil })
        _ = await missing.thumbnail(for: urls[0]); _ = await missing.thumbnail(for: urls[0])
        try require(misses == 1, "unavailable previews retain their actionable placeholder without repeated failed decodes")
        let movie = directory.appendingPathComponent("thumbnail-source.mp4")
        try await EditorMovieFixtures.make(at: movie, width: 320, height: 180, duration: 1, camera: false)
        let original = try Data(contentsOf: movie)
        let real = RecordingThumbnailCache()
        guard let thumbnail = await real.thumbnail(for: movie) else { throw RowCheckError.failed("original-video thumbnail") }
        try require(thumbnail.width <= 160 && thumbnail.height <= 160 && thumbnail.width * 9 == thumbnail.height * 16,
                    "original-video thumbnail is bounded and preserves source aspect")
        try require(try Data(contentsOf: movie) == original, "thumbnail generation never rewrites the original movie")
    }

    private static func mouse(_ type: NSEvent.EventType, target: NSView, window: NSWindow, count: Int) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: count, clickCount: count, pressure: 1)!
    }

    private static func find<T: NSView>(in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { find(in: $0) as T? }.first
    }

    private static func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { findAll(type, in: $0) }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw RowCheckError.failed(message) }
    }
}
