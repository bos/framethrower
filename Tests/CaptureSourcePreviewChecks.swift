import AppKit
import Foundation

private enum SourcePreviewCheckError: Error { case failed(String) }

@MainActor
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw SourcePreviewCheckError.failed(message) }
}

@main
@MainActor
struct CaptureSourcePreviewChecks {
    static func main() throws {
        let image = try quadrants()
        let display = CapturePreviewSource.display(id: 12, frame: CGRect(x: -100, y: 50, width: 200, height: 100))
        let cache = CaptureSourcePreviews()
        cache.store(image, contentSize: display.frame.size, for: display)
        guard let full = cache.preview(for: display) else { throw SourcePreviewCheckError.failed("stored display missing") }
        try require(full.image === image && full.contentSize == display.frame.size, "full display preview changed")
        let topLeft = CGRect(x: -100, y: 100, width: 100, height: 50)
        guard let top = cache.preview(for: display, area: topLeft) else { throw SourcePreviewCheckError.failed("top-left area missing") }
        try require(top.image.width == 200 && top.image.height == 100, "area source-to-pixel scale changed")
        try require(try pixel(top.image) == [255, 0, 0], "AppKit top-left area did not crop screenshot's top-left")
        let bottomRight = CGRect(x: 0, y: 50, width: 100, height: 50)
        guard let bottom = cache.preview(for: display, area: bottomRight) else { throw SourcePreviewCheckError.failed("bottom-right area missing") }
        try require(try pixel(bottom.image) == [255, 255, 0], "area crop Y axis or negative display origin is wrong")
        guard let clipped = cache.preview(for: display, area: CGRect(x: -150, y: 25, width: 100, height: 100)) else {
            throw SourcePreviewCheckError.failed("clipped area missing")
        }
        try require(clipped.contentSize == CGSize(width: 50, height: 75)
                    && clipped.image.width == 100 && clipped.image.height == 150,
                    "area crop did not clip to the selected display")
        try require(cache.preview(for: display, area: CGRect(x: 1000, y: 1000, width: 10, height: 10)) == nil,
                    "out-of-display area showed unrelated content")
        try require(cache.preview(for: nil) == nil, "unknown selection borrowed an old screenshot")
        let changedDisplay = CapturePreviewSource.display(id: 13, frame: display.frame)
        try require(cache.preview(for: changedDisplay) == nil, "new display borrowed the previous display screenshot")
        let changedGeometry = CapturePreviewSource.display(id: display.id, frame: CGRect(x: -100, y: 50, width: 300, height: 100))
        try require(cache.preview(for: changedGeometry) == nil, "old display geometry was treated as current")

        let owner = CapturePreviewSource(kind: .window, id: 20, frame: CGRect(x: 0, y: 0, width: 200, height: 100),
                                        processID: 100, bundleIdentifier: "com.example.Editor", launchDate: Date(timeIntervalSince1970: 1))
        cache.store(image, contentSize: CGSize(width: 198, height: 98), for: owner)
        var reused = owner
        reused.processID = 101
        try require(cache.preview(for: reused) == nil, "reused window number showed another owner's screenshot")
        reused = owner
        reused.launchDate = Date(timeIntervalSince1970: 2)
        try require(cache.preview(for: reused) == nil, "window screenshot survived owner restart")
        try require(cache.preview(for: owner)?.contentSize == CGSize(width: 198, height: 98),
                    "window layout used outer geometry instead of captured content bounds")
        try require(cache.preview(for: owner, area: topLeft) == nil, "window incorrectly accepted display area cropping")

        let canvas = CGSize(width: 200, height: 112.5)
        let portrait = CaptureSourcePreviewGeometry.fittedRect(contentSize: CGSize(width: 100, height: 200), in: canvas)
        try require(portrait == CGRect(x: 71.875, y: 0, width: 56.25, height: 112.5), "portrait source fit stretched to canvas")
        let wide = CaptureSourcePreviewGeometry.fittedRect(contentSize: CGSize(width: 200, height: 100), in: canvas)
        try require(wide == CGRect(x: 0, y: 6.25, width: 200, height: 100), "wide source letterbox is incorrect")
        let placement = PIPPlacement(x: 1, y: 1, scale: 0.5)
        let pip = placement.frame(in: portrait.size, cameraAspect: 16.0 / 9.0)
            .offsetBy(dx: portrait.minX, dy: portrait.minY)
        try require(portrait.contains(pip), "PIP was placed in letterbox instead of the recorded content")
        try require(CaptureSourcePreviewGeometry.fittedRect(contentSize: .zero, in: canvas) == .zero,
                    "invalid source dimensions produced invalid geometry")

        cache.remove(owner)
        try require(cache.preview(for: owner) == nil, "failed/refreshed source kept stale screenshot")
        for id in 100..<110 {
            cache.store(image, contentSize: display.frame.size,
                        for: .display(id: UInt32(id), frame: display.frame))
        }
        try require(cache.preview(for: .display(id: 100, frame: display.frame)) == nil,
                    "screenshot cache did not bound old source retention")
        cache.clear()
        try require(cache.preview(for: .display(id: 109, frame: display.frame)) == nil,
                    "permission reset did not clear screenshot cache")
        print("Capture source preview checks passed (source identity, area crop pixels, negative origins, fitted placement, and bounded cache).")
    }

    private static func quadrants() throws -> CGImage {
        let width = 400, height = 200
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color: [UInt8]
                if y < height / 2 { color = x < width / 2 ? [255, 0, 0] : [0, 255, 0] }
                else { color = x < width / 2 ? [0, 0, 255] : [255, 255, 0] }
                let index = (y * width + x) * 4
                bytes[index] = color[0]; bytes[index + 1] = color[1]; bytes[index + 2] = color[2]; bytes[index + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw SourcePreviewCheckError.failed("test screenshot")
        }
        return image
    }

    private static func pixel(_ image: CGImage) throws -> [UInt8] {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw SourcePreviewCheckError.failed("cropped pixel bytes")
        }
        return [bytes[0], bytes[1], bytes[2]]
    }
}
