@preconcurrency import AVFoundation
import AppKit

private enum CanvasCheckError: Error { case failed(String) }

/// Checks the actual native layer tree with an asymmetric synthetic image;
/// video decoding and the display server cannot hide orientation mistakes.
@main
@MainActor
struct EditorCanvasChecks {
    static func main() throws {
        _ = NSApplication.shared
        let image = quadrants()
        let player = AVPlayer()
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EditorCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = canvas
        defer { window.close() }

        func configure(_ placement: PIPPlacement) {
            canvas.configure(player: player, image: image, sourceSize: CGSize(width: 200, height: 100),
                             cameraAspect: 2, placement: placement, cameraEnabled: true)
            canvas.layoutSubtreeIfNeeded()
        }
        for y in [0.0, 1.0] {
            for x in [0.0, 1.0] {
                configure(PIPPlacement(x: x, y: y, scale: 0.25))
                try require(canvas.canvasRect == CGRect(x: 0, y: 50, width: 400, height: 200),
                            "native source canvas must preserve aspect and letterbox")
                let rendered = try render(canvas)
                try pixel(rendered, x: 30, y: 80, equals: [1, 0, 0], "top-left source quadrant")
                try pixel(rendered, x: 370, y: 80, equals: [0, 1, 0], "top-right source quadrant")
                try pixel(rendered, x: 30, y: 220, equals: [0, 0, 1], "bottom-left source quadrant")
                try pixel(rendered, x: 370, y: 220, equals: [1, 1, 0], "bottom-right source quadrant")
                try pixel(rendered, x: 20, y: 20, equals: [0, 0, 0], "upper letterbox")
                try pixel(rendered, x: 20, y: 280, equals: [0, 0, 0], "lower letterbox")
                let interiorX = x == 0 ? 100 : 300
                let interiorY = y == 0 ? 100 : 200
                try pixel(rendered, x: interiorX, y: interiorY, equals: [1, 1, 1],
                          "camera corner aligns with top-left placement coordinates")
                try require(canvas.stillLayer.animationKeys()?.isEmpty != false,
                            "still-image updates must not acquire implicit layer animations")
            }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = RecordingProject(screenFilename: "screen.mp4", duration: 10)
        let initial = PIPPlacement(x: 0.3, y: 0.4, scale: 0.25)
        project.state.pipKeyframes[0].placement = initial
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("canvas.framethrower"))
        try require(editor.save(), "save gesture fixture")
        var previews: [PIPPlacement] = []
        var cancellations = 0
        canvas.onPreview = { placement in
            previews.append(placement)
            // Real paused frame updates reconfigure the view while a native
            // drag is active. They must not replace its transient geometry.
            configure(initial)
        }
        canvas.onCancel = { cancellations += 1; configure(initial) }
        canvas.onCommit = { placement, name in
            var state = editor.project.state
            state.pipKeyframes[0].placement = placement
            editor.commit(state, name: name)
        }
        configure(initial)
        let frame = initial.frame(in: canvas.canvasRect.size, cameraAspect: 2)
            .offsetBy(dx: canvas.canvasRect.minX, dy: canvas.canvasRect.minY)
        let start = CGPoint(x: frame.midX, y: frame.midY)
        let moved = CGPoint(x: start.x + 40, y: start.y + 20)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, canvas: canvas, window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: moved, canvas: canvas, window: window))
        try require(previews.count == 1 && editor.project.undoHistory.isEmpty,
                    "an in-progress native drag is preview-only")
        try pixel(try render(canvas), x: 230, y: 180, equals: [1, 1, 1],
                  "a paused-frame reconfigure must preserve the current native drag outline")
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
        canvas.mouseUp(with: mouse(.leftMouseUp, at: moved, canvas: canvas, window: window))
        try require(cancellations == 1 && editor.project == project && !editor.canUndo,
                    "Escape cancels the drag without changing project state or undo history")
        try pixel(try render(canvas), x: 190, y: 160, equals: [1, 1, 1],
                  "Escape restores the original camera outline")
        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.project == project && !reopened.canUndo,
                    "a cancelled gesture must not appear after reopening")
        print("Editor canvas checks passed (quadrant orientation, letterboxing, camera corner alignment, no implicit image animations, draft reconfiguration, and Escape without undo).")
    }

    private static func quadrants() -> CGImage {
        var bytes = [UInt8](repeating: 0, count: 200 * 100 * 4)
        for y in 0..<100 {
            for x in 0..<200 {
                let rgb: [UInt8] = y < 50 ? (x < 100 ? [255, 0, 0] : [0, 255, 0])
                    : (x < 100 ? [0, 0, 255] : [255, 255, 0])
                let index = (y * 200 + x) * 4
                bytes[index] = rgb[0]; bytes[index + 1] = rgb[1]; bytes[index + 2] = rgb[2]; bytes[index + 3] = 255
            }
        }
        return CGImage(width: 200, height: 100, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func render(_ canvas: EditorCanvasView) throws -> NSBitmapImageRep {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Layer.render uses Quartz coordinates. Flip the capture context into
        // Cocoa view coordinates before comparing top-left bitmap samples.
        context.translateBy(x: 0, y: 300)
        context.scaleBy(x: 1, y: -1)
        canvas.layer!.render(in: context)
        guard let image = context.makeImage() else { throw CanvasCheckError.failed("render native layers") }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func pixel(_ image: NSBitmapImageRep, x: Int, y: Int, equals expected: [Double], _ message: String) throws {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            throw CanvasCheckError.failed("missing pixel: \(message)")
        }
        for (actual, target) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
            try require(abs(actual - target) < 0.08, "\(message): \(color) != \(expected)")
        }
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, canvas: NSView, window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CanvasCheckError.failed(message) }
    }
}
