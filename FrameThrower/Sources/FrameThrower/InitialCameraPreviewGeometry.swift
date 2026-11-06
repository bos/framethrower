import Foundation

enum InitialCameraPreviewGeometry {
    /// The main area preview shows the full display. The camera belongs inside
    /// the selected recording region, not in its surrounding display pixels.
    static func recordingRect(area: CGRect?, display: CGRect?, in size: CGSize) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        if let area, let display {
            return AreaPreviewGeometry.previewRect(for: area, in: display, size: size) ?? .zero
        }
        return CGRect(origin: .zero, size: size)
    }

    static func cameraRect(_ placement: PIPPlacement, in recordingRect: CGRect) -> CGRect {
        placement.frame(in: recordingRect.size, cameraAspect: 16.0 / 9.0)
            .offsetBy(dx: recordingRect.minX, dy: recordingRect.minY)
    }

    static func moved(_ origin: PIPPlacement, by translation: CGSize, in recordingRect: CGRect) -> PIPPlacement {
        guard translation.width.isFinite, translation.height.isFinite,
              recordingRect.width > 0, recordingRect.height > 0 else { return origin }
        let camera = cameraRect(origin, in: recordingRect)
        var next = origin
        next.x = min(1, max(0, origin.x + translation.width / max(1, recordingRect.width - camera.width)))
        next.y = min(1, max(0, origin.y + translation.height / max(1, recordingRect.height - camera.height)))
        return next
    }
}
