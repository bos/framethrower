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
        guard let a = sourcePoint(start), end.x.isFinite, end.y.isFinite else { return nil }
        let viewport = zoom.viewport(in: CGSize(width: 1, height: 1))
        let dx = (end.x - start.x) / contentRect.width * viewport.width
        let dy = (end.y - start.y) / contentRect.height * viewport.height
        guard dx.isFinite, dy.isFinite else { return nil }
        // Equal source-normalized sides retain the video's actual aspect, even
        // with a portrait source, output padding, or a clamped zoom viewport.
        // A purely horizontal/vertical gesture grows the other axis inward.
        let right = dx == 0 ? a.x <= viewport.midX : dx > 0
        let down = dy == 0 ? a.y <= viewport.midY : dy > 0
        let availableX = right ? min(1, viewport.maxX) - a.x : a.x - max(0, viewport.minX)
        let availableY = down ? min(1, viewport.maxY) - a.y : a.y - max(0, viewport.minY)
        var side = min(max(abs(dx), abs(dy)), availableX, availableY)
        guard side > 0 else { return nil }
        var value = EditorRegionRect(x: right ? a.x : a.x - side, y: down ? a.y : a.y - side,
                                     width: side, height: side)
        // Correct only arithmetic rounding at a source edge, shrinking both
        // dimensions together rather than introducing an aspect mismatch.
        if !value.isValid {
            side = side.nextDown
            value = EditorRegionRect(x: right ? a.x : a.x - side, y: down ? a.y : a.y - side,
                                     width: side, height: side)
        }
        let projected = viewRect(value)
        guard value.isValid, projected.width >= 5, projected.height >= 5 else { return nil }
        return value
    }

    func viewRect(_ region: EditorRegionRect) -> CGRect {
        let viewport = zoom.viewport(in: CGSize(width: 1, height: 1))
        return CGRect(x: contentRect.minX + (region.x - viewport.minX) / viewport.width * contentRect.width,
                      y: contentRect.minY + (region.y - viewport.minY) / viewport.height * contentRect.height,
                      width: region.width / viewport.width * contentRect.width,
                      height: region.height / viewport.height * contentRect.height)
    }
}
