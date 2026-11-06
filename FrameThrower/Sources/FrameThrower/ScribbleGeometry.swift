import Foundation

/// All guides use original source coordinates. Output padding and the current
/// zoom affect the editing surface only, never the saved rectangle.
struct ScribbleGeometry {
    var contentRect: CGRect
    var zoom: ZoomPlacement

    func sourcePoint(_ point: CGPoint) -> CGPoint? {
        guard contentRect.width > 0, contentRect.height > 0, contentRect.contains(point) else { return nil }
        let viewport = zoom.viewport(in: CGSize(width: 1, height: 1))
        return CGPoint(x: viewport.minX + (point.x - contentRect.minX) / contentRect.width * viewport.width,
                       y: viewport.minY + (point.y - contentRect.minY) / contentRect.height * viewport.height)
    }

    func region(from start: CGPoint, to end: CGPoint) -> EditorRegionRect? {
        guard let a = sourcePoint(start) else { return nil }
        let bounded = CGPoint(x: min(contentRect.maxX.nextDown, max(contentRect.minX, end.x)),
                              y: min(contentRect.maxY.nextDown, max(contentRect.minY, end.y)))
        guard let b = sourcePoint(bounded), abs(bounded.x - start.x) >= 5, abs(bounded.y - start.y) >= 5 else { return nil }
        let value = EditorRegionRect(x: max(0, min(a.x, b.x)), y: max(0, min(a.y, b.y)),
                                    width: abs(a.x - b.x), height: abs(a.y - b.y))
        return value.isValid ? value : nil
    }

    func viewRect(_ region: EditorRegionRect) -> CGRect {
        let viewport = zoom.viewport(in: CGSize(width: 1, height: 1))
        return CGRect(x: contentRect.minX + (region.x - viewport.minX) / viewport.width * contentRect.width,
                      y: contentRect.minY + (region.y - viewport.minY) / viewport.height * contentRect.height,
                      width: region.width / viewport.width * contentRect.width,
                      height: region.height / viewport.height * contentRect.height)
    }
}
