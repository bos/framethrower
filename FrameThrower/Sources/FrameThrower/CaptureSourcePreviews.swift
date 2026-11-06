import AppKit
import Combine
import CoreGraphics

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
