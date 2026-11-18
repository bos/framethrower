import AppKit
import SwiftUI
@testable import FrameThrower

@main @MainActor
struct VideoCropChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure.failed(message) }
    }
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
    static func event(_ type: NSEvent.EventType, _ point: CGPoint, in view: NSView) throws -> NSEvent {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw Failure.failed("mouse event") }
        return event
    }
    static func drag(_ view: CropSelectionView, _ a: CGPoint, _ b: CGPoint, cancel: Bool = false) throws {
        view.mouseDown(with: try event(.leftMouseDown, a, in: view))
        view.mouseDragged(with: try event(.leftMouseDragged, b, in: view))
        if cancel { view.cancelOperation(nil) }
        view.mouseUp(with: try event(.leftMouseUp, b, in: view))
    }
    static func settle(_ host: NSView) async {
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(20)) }
    }
    static func wholePixels(_ rect: EditorRegionRect, source: CGSize) throws {
        let pixels = CropGeometry.pixels(rect, in: source)
        try require(rect.isValid && pixels.width >= 2 && pixels.height >= 2, "pixel-aligned crop stays inside the source")
        for value in [pixels.minX, pixels.minY, pixels.width, pixels.height] {
            try require(abs(value - value.rounded()) < 0.000001, "crop coordinates and dimensions use whole source pixels: \(pixels)")
        }
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended && MediaProcessing.isCaptureSuspended, "crop UI tests keep media and live capture disabled")
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let source = VideoSource(name: "Test video", kind: .testPattern, duration: 5,
            pixelWidth: 1920, pixelHeight: 1080, hasAudio: false)
        var applied: EditorRegionRect?
        let request = VideoCropRequest(title: "Crop main video", source: source, time: 0,
            sourceSize: source.pixelSize!, crop: .init(x: 0.3037, y: 0.3023, width: 0.5011, height: 0.5022)) { rect, _ in applied = rect }
        let host = NSHostingView(rootView: VideoCropEditor(request: request, directory: FileManager.default.temporaryDirectory))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 760, height: 650),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        NSApp.finishLaunching()
        window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        await settle(host)
        guard let canvas = all(CropSelectionView.self, in: host).first else { throw Failure.failed("shared crop canvas") }
        try wholePixels(canvas.selection, source: canvas.sourceSize)
        let frame = canvas.imageRect
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height) }
        try drag(canvas, point(0.1, 0.1), point(0.7, 0.8))
        await settle(host)
        try require(canvas.selection.isValid && abs(canvas.selection.x - 0.1) < 0.0001 && abs(canvas.selection.height - 0.7) < 0.0001,
                    "a first drag draws a new freeform rectangle")
        try require(applied == nil, "drawing only changes the local draft")
        let first = canvas.selection
        try drag(canvas, point(0.4, 0.4), point(0.5, 0.5))
        await settle(host)
        try require(abs(canvas.selection.x - 0.2) < 0.0001 && canvas.selection.width == first.width, "drag inside moves the crop")
        let moved = canvas.selection
        try drag(canvas, point(0.5, 0.5), point(0.6, 0.6), cancel: true)
        await settle(host)
        try require(canvas.selection == moved, "Escape restores an unfinished gesture")
        // Points between source pixels exercise snapping through native gestures.
        canvas.drawNew = true
        try drag(canvas, point(0.1037, 0.1023), point(0.7011, 0.8022))
        await settle(host)
        try wholePixels(canvas.selection, source: canvas.sourceSize)
        let drawn = canvas.selection
        try drag(canvas, point(drawn.x + drawn.width / 2, drawn.y + drawn.height / 2),
                 point(drawn.x + drawn.width / 2 + 0.0137, drawn.y + drawn.height / 2 + 0.0113))
        await settle(host)
        try wholePixels(canvas.selection, source: canvas.sourceSize)
        for handle in 0..<8 {
            let r = canvas.selection
            let x = [r.x, r.x + r.width / 2, r.x + r.width, r.x + r.width,
                     r.x + r.width, r.x + r.width / 2, r.x, r.x][handle]
            let y = [r.y, r.y, r.y, r.y + r.height / 2,
                     r.y + r.height, r.y + r.height, r.y + r.height, r.y + r.height / 2][handle]
            try drag(canvas, point(x, y), point(x + 0.0037, y + 0.0023))
            await settle(host)
            try wholePixels(canvas.selection, source: canvas.sourceSize)
        }
        canvas.ratio = 9.0 / 16; canvas.drawNew = true
        try drag(canvas, point(0.05, 0.05), point(0.4, 0.9))
        let portrait = CropGeometry.pixels(canvas.selection, in: canvas.sourceSize)
        try wholePixels(canvas.selection, source: canvas.sourceSize)
        try require(abs(portrait.width - portrait.height * 9.0 / 16) <= 1, "portrait aspect rounds to the nearest source pixel")
        // SwiftUI owns the selection; the low-level lock was injected only for the native gesture above.
        await settle(host)
        let selected = canvas.selection
        let fields = all(NSTextField.self, in: host).filter { ["Width", "Height"].contains($0.placeholderString ?? "") }
        try require(fields.count == 2 && fields.allSatisfy { !$0.stringValue.contains(Locale.current.decimalSeparator ?? ".") },
                    "crop pixel fields display integer values")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/framethrower-video-crop-before-apply.png"))
        }
        // SwiftUI omits synthetic AX buttons in offscreen accessory windows.
        // Exercise the real default action through its Return shortcut instead.
        let apply = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36)!
        try require(window.performKeyEquivalent(with: apply), "Return invokes Apply crop")
        await settle(host)
        try require(applied == selected, "Apply returns exactly one selected source rectangle")
        try wholePixels(applied!, source: canvas.sourceSize)
        let outputRequest = VideoCropRequest(title: "Crop main video", source: source, time: 0,
            sourceSize: source.pixelSize!, crop: selected, setsOutputFrame: true,
            outputResolution: CanvasResolution(width: 1080, height: 1920)) { _, _ in }
        let outputHost = NSHostingView(rootView: VideoCropEditor(request: outputRequest, directory: FileManager.default.temporaryDirectory))
        window.contentView = outputHost
        await settle(outputHost)
        let outputFields = all(NSTextField.self, in: outputHost).filter { $0.isEditable }
        let outputValues = outputFields.map { $0.stringValue.replacingOccurrences(of: ",", with: "") }
        try require(outputFields.count == 2, "the main crop editor exposes only Width and Height")
        try require(Set(outputValues) == Set(["1080", "1920"]), "reopening a portrait crop preserves its chosen output resolution")

        if CommandLine.arguments.count > 1, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Video crop UI checks passed (whole-pixel initial values, drawing, movement, eight resize handles, portrait lock, integer fields, gesture cancellation, local drafts, and Apply shortcut).")
    }
}
