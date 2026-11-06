import AppKit
import SwiftUI

private enum DisplayCheckError: Error { case failed(String) }

/// Only fake still images are used; these checks never construct the display
/// capture model, request permission, enumerate screens, or capture pixels.
@main
@MainActor
struct DisplayCarouselChecks {
    static func main() async throws {
        _ = NSApplication.shared
        near(DisplayThumbnailGeometry.fittedSize(for: CGSize(width: 1920, height: 1080), maxHeight: 64),
             CGSize(width: 64.0 * 16 / 9, height: 64), "Compact landscape thumbnail")
        near(DisplayThumbnailGeometry.fittedSize(for: CGSize(width: 1080, height: 1920), maxHeight: 132),
             CGSize(width: 74.25, height: 132), "Portrait thumbnail")
        near(DisplayThumbnailGeometry.fittedSize(for: CGSize(width: 3440, height: 1440), maxHeight: 132),
             CGSize(width: 236, height: 236.0 * 1440 / 3440), "Wide screen fits the width limit")
        near(DisplayThumbnailGeometry.fittedSize(for: .zero, maxHeight: 64), .zero, "Invalid display geometry")

        let context = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.05, green: 0.9, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let image = NSImage(cgImage: context.makeImage()!, size: CGSize(width: 1920, height: 1080))
        var clicks = 0
        let host = NSHostingView(rootView:
            DisplayCarouselTile(title: "Display one", size: image.size, imageHeight: 64, image: image,
                                isSelected: true, isLoading: false, failed: false) { clicks += 1 }
                .padding(20).frame(width: 320, height: 220).background(.black)
        )
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 320, height: 220),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let renderer = ImageRenderer(content: host.rootView)
        renderer.scale = 1
        guard let rendered = renderer.cgImage else { throw DisplayCheckError.failed("render fake display tile") }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        let scaleX = Double(bitmap.pixelsWide) / host.bounds.width
        let scaleY = Double(bitmap.pixelsHigh) / host.bounds.height
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.greenComponent > 0.7 && color.redComponent < 0.2 && color.blueComponent < 0.2 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        try require(maxX > minX && maxY > minY, "fake screen image must actually render")
        let green = CGRect(x: Double(minX) / scaleX, y: Double(minY) / scaleY,
                           width: Double(maxX - minX + 1) / scaleX, height: Double(maxY - minY + 1) / scaleY)
        try require(green.height >= 58 && green.height <= 64, "image should fill the compact64pt preview without extra internal padding")
        try require(green.width >= 106 && green.width <= 115, "thumbnail and border should hug the actual screen aspect")
        var borderMinX = bitmap.pixelsWide, borderMaxX = -1
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: Int(green.midY * scaleY))?.usingColorSpace(.deviceRGB) else { continue }
            if color.redComponent > 0.6 && color.greenComponent < 0.4 && color.blueComponent < 0.35 {
                borderMinX = min(borderMinX, x); borderMaxX = max(borderMaxX, x)
            }
        }
        let borderWidth = Double(borderMaxX - borderMinX + 1) / scaleX
        try require(borderWidth >= 111 && borderWidth <= 116,
                    "the selected border must follow the114pt screen image rather than its old236pt tile width")
        for pointX in [green.minX - 24, green.maxX + 24] {
            let color = bitmap.colorAt(x: Int(pointX * scaleX), y: Int(green.midY * scaleY))!.usingColorSpace(.deviceRGB)!
            try require(color.greenComponent < 0.02 && color.blueComponent < 0.02,
                        "compact thumbnails must not have broad gray wings beside the image")
        }
        for point in [CGPoint(x: green.midX, y: green.midY),
                      CGPoint(x: green.midX, y: green.minY - 22),
                      CGPoint(x: green.midX, y: green.maxY + 20)] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try require(clicks == 3, "screen image, display name, and dimensions must all remain clickable")

        let loaded = NSHostingView(rootView: DisplayCarouselTile(title: "Display one", size: image.size, imageHeight: 132,
            image: image, isSelected: false, isLoading: false, failed: false, select: {}))
        let missing = NSHostingView(rootView: DisplayCarouselTile(title: "Display one", size: image.size, imageHeight: 132,
            image: nil, isSelected: false, isLoading: false, failed: true, select: {}))
        try require(missing.fittingSize.height < loaded.fittingSize.height - 80,
                    "unavailable previews must use a compact status instead of a fake monitor-shaped block")
        print("Display carousel checks passed (aspect-fitted thumbnail bounds, no gray wings, compact unavailable state, and clickable image/name/dimensions).")
    }

    private static func near(_ actual: CGSize, _ expected: CGSize, _ message: String) {
        precondition(abs(actual.width - expected.width) < 0.000_001 && abs(actual.height - expected.height) < 0.000_001, message)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DisplayCheckError.failed(message) }
    }
}
