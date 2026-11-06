import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// A numeric window ID alone can be reused by another process. Geometry is part
/// of the key so an image for an old source layout never masquerades as current.
struct CapturePreviewSource: Hashable {
    enum Kind: Hashable { case display, window }
    let kind: Kind
    let id: UInt32
    let frame: CGRect
    var processID: pid_t?
    var bundleIdentifier: String?
    var launchDate: Date?

    static func display(id: CGDirectDisplayID, frame: CGRect) -> Self {
        Self(kind: .display, id: id, frame: frame)
    }

    static func window(_ window: ShareableWindow) -> Self {
        let processID = window.window.owningApplication?.processID
        return Self(kind: .window, id: window.id, frame: window.frame,
                    processID: processID, bundleIdentifier: window.bundleIdentifier,
                    launchDate: processID.flatMap { NSRunningApplication(processIdentifier: $0)?.launchDate })
    }
}

struct CaptureSourcePreview {
    let image: CGImage
    let contentSize: CGSize
}

/// Reuses stills already captured by the source chooser. This never starts a
/// capture stream or asks for permission, and never falls back to another key.
@MainActor
final class CaptureSourcePreviews: ObservableObject {
    let refreshes = CapturePreviewRefreshes()
    private struct Snapshot {
        let image: CGImage
        let contentSize: CGSize
    }
    @Published private(set) var revision = 0
    private var snapshots: [CapturePreviewSource: Snapshot] = [:]
    private var order: [CapturePreviewSource] = []

    func store(_ image: CGImage, contentSize: CGSize, for source: CapturePreviewSource) {
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width > 0, contentSize.height > 0 else { return }
        snapshots[source] = Snapshot(image: image, contentSize: contentSize)
        order.removeAll { $0 == source }
        order.append(source)
        while order.count > 8 { snapshots.removeValue(forKey: order.removeFirst()) }
        revision &+= 1
    }

    func preview(for source: CapturePreviewSource?, area: CGRect? = nil) -> CaptureSourcePreview? {
        guard let source, let snapshot = snapshots[source] else { return nil }
        guard let area else {
            return CaptureSourcePreview(image: snapshot.image, contentSize: snapshot.contentSize)
        }
        guard source.kind == .display,
              let crop = CaptureSourcePreviewGeometry.pixelCrop(for: area, in: source.frame,
                  imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height)),
              let image = snapshot.image.cropping(to: crop) else { return nil }
        return CaptureSourcePreview(image: image, contentSize: area.intersection(source.frame).size)
    }

    func remove(_ source: CapturePreviewSource) {
        guard snapshots.removeValue(forKey: source) != nil else { return }
        order.removeAll { $0 == source }
        revision &+= 1
    }

    func clear() {
        guard !snapshots.isEmpty else { return }
        snapshots = [:]
        order = []
        revision &+= 1
    }
}

/// Display and area views share one capture slot, including while a cancelled
/// SDK request is finishing during a source/view change. Slow captures cannot
/// accumulate work; transient failures retry at a lower rate.
@MainActor
final class CapturePreviewRefreshes {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run(repeating: Bool = true, interval: Duration = .milliseconds(500),
             retryInterval: Duration = .seconds(3),
             capture: @MainActor () async -> Bool) async {
        repeat {
            while busy && !Task.isCancelled {
                await withCheckedContinuation { waiting.append($0) }
            }
            guard !Task.isCancelled else { return }
            busy = true
            let succeeded = await capture()
            busy = false
            let resumed = waiting
            waiting.removeAll()
            for continuation in resumed { continuation.resume() }
            guard repeating, !Task.isCancelled else { return }
            do { try await Task.sleep(for: succeeded ? interval : retryInterval) }
            catch { return }
        } while !Task.isCancelled
    }
}

/// SwiftUI disappearance alone does not cover minimization or full occlusion.
/// Observe the preview's own window so background-but-visible previews keep
/// updating, while hidden windows stop capturing screen pixels.
struct CapturePreviewVisibility: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        let binding = $isVisible
        view.onChange = { binding.wrappedValue = $0 }
        return view
    }
    func updateNSView(_ view: VisibilityView, context: Context) {
        let binding = $isVisible
        view.onChange = { binding.wrappedValue = $0 }
        view.updateVisibility()
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private let observations = PreviewVisibilityObservations()
        private var lastVisible: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.removeAll()
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                         NSApplication.didUnhideNotification] {
                observations.tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateVisibility() }
                })
            }
            updateVisibility()
        }

        override func viewDidHide() { super.viewDidHide(); updateVisibility() }
        override func viewDidUnhide() { super.viewDidUnhide(); updateVisibility() }

        func updateVisibility() {
            let visible = window.map {
                $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
            } == true && !NSApp.isHidden && !isHiddenOrHasHiddenAncestor
            guard lastVisible != visible else { return }
            lastVisible = visible
            // Avoid mutating SwiftUI state during updateNSView/layout.
            Task { @MainActor [weak self] in
                guard let self, self.lastVisible == visible else { return }
                self.onChange?(visible)
            }
        }

    }
}

/// Registration mutates only on the main actor. Observer removal is thread-safe
/// and can also run when AppKit releases its view on a nonisolated deinit path.
private final class PreviewVisibilityObservations: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []
    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }
    deinit { removeAll() }
}

enum CaptureSourcePreviewGeometry {
    static func fittedRect(contentSize: CGSize, in canvas: CGSize) -> CGRect {
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              canvas.width.isFinite, canvas.height.isFinite,
              contentSize.width > 0, contentSize.height > 0,
              canvas.width > 0, canvas.height > 0 else { return .zero }
        let scale = min(canvas.width / contentSize.width, canvas.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func pixelCrop(for area: CGRect, in display: CGRect, imageSize: CGSize) -> CGRect? {
        guard let rect = AreaPreviewGeometry.previewRect(for: area, in: display, size: imageSize) else { return nil }
        let bounds = CGRect(origin: .zero, size: imageSize)
        let pixels = rect.integral.intersection(bounds)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1 else { return nil }
        return pixels
    }
}
