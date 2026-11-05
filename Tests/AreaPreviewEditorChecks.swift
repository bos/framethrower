import AppKit
import SwiftUI

// Run with Tests/check-area-preview.sh. These checks use offscreen native views.
@main
struct AreaPreviewEditorChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let display = CGRect(x: 100, y: -500, width: 1000, height: 500)
        let initial = CGRect(x: 300, y: -300, width: 400, height: 200)
        let size = CGSize(width: 500, height: 250)
        expect(AreaPreviewGeometry.previewRect(for: initial, in: display, size: size),
               CGRect(x: 100, y: 50, width: 200, height: 100), "Display-to-preview Y axis")
        expect(AreaPreviewGeometry.captureRect(for: CGRect(x: 100, y: 50, width: 200, height: 100), in: display, size: size),
               initial, "Preview-to-display Y axis")

        for frame in [display, CGRect(x: -1920, y: 900, width: 1920, height: 1080),
                      CGRect(x: -1080, y: -1920, width: 1080, height: 1920)] {
            let selected = CGRect(x: frame.minX + 100, y: frame.minY + 200, width: 400, height: 300)
            let preview = AreaPreviewGeometry.previewRect(for: selected, in: frame, size: size)!
            expect(AreaPreviewGeometry.captureRect(for: preview, in: frame, size: size), selected,
                   "Round trip on offset and portrait displays")
        }
        expect(AreaPreviewGeometry.previewRect(for: CGRect(x: 0, y: -600, width: 300, height: 300), in: display, size: size),
               CGRect(x: 0, y: 150, width: 100, height: 100), "Area spanning display boundary")
        precondition(AreaPreviewGeometry.previewRect(for: .zero, in: display, size: size) == nil)
        precondition(AreaPreviewGeometry.previewRect(for: initial, in: .zero, size: size) == nil)
        precondition(AreaPreviewGeometry.captureRect(for: .zero, in: display, size: size) == nil)

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 540, height: 290),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = AreaPreviewSelectionView(frame: CGRect(x: 20, y: 20, width: 500, height: 250))
        window.contentView!.addSubview(editor)
        editor.displayFrame = display
        var published = initial
        editor.onSelectionChanged = { published = $0 }

        func drag(from: CGPoint, to: CGPoint) {
            func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil),
                                  modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            editor.mouseDown(with: event(.leftMouseDown, at: from))
            editor.mouseDragged(with: event(.leftMouseDragged, at: to))
            editor.mouseUp(with: event(.leftMouseUp, at: to))
            expect(published, editor.selection, "Edits publish recording bounds")
        }
        func reset() {
            editor.selection = initial
            published = initial
        }

        reset()
        drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 40))
        expect(editor.selection, CGRect(x: 120, y: -80, width: 160, height: 60), "Draw a new region")
        reset()
        drag(from: CGPoint(x: 200, y: 100), to: CGPoint(x: 260, y: 130))
        expect(editor.selection, CGRect(x: 420, y: -360, width: 400, height: 200), "Move an existing region")
        reset()
        drag(from: CGPoint(x: 200, y: 100), to: CGPoint(x: 900, y: 900))
        expect(editor.selection, CGRect(x: 700, y: -500, width: 400, height: 200), "Clamp movement to display")
        reset()
        drag(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 60, y: 30))
        expect(editor.selection, CGRect(x: 220, y: -300, width: 480, height: 240), "Resize a corner")
        reset()
        drag(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 340, y: 180))
        expect(editor.selection, CGRect(x: 700, y: -360, width: 80, height: 60), "Resize through opposite corner")
        reset()
        drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.1, y: 10.1))
        expect(editor.selection, initial, "Reject subminimum regions")
        reset()
        editor.isEditable = false
        drag(from: CGPoint(x: 200, y: 100), to: CGPoint(x: 260, y: 130))
        expect(editor.selection, initial, "Lock edits while recording or counting down")
        editor.isEditable = true
        editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, characters: "", charactersIgnoringModifiers: "",
                                             isARepeat: false, keyCode: 123)!)
        expect(editor.selection, initial.offsetBy(dx: -1, dy: 0), "Keyboard move by one point")
        editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift],
                                             timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, characters: "", charactersIgnoringModifiers: "",
                                             isARepeat: false, keyCode: 125)!)
        expect(editor.selection, initial.offsetBy(dx: -1, dy: -10), "Shift-key move by ten points")

        window.close()

        // Exercise the SwiftUI binding and aspect-fit layout used by CapturePreview.
        var area = CaptureArea(x: initial.minX, y: initial.minY, width: initial.width, height: initial.height)
        let desktop = NSImage(size: display.size, flipped: false) { bounds in
            NSGradient(starting: NSColor(red: 0.2, green: 0.4, blue: 0.48, alpha: 1),
                       ending: NSColor(red: 0.55, green: 0.7, blue: 0.6, alpha: 1))!.draw(in: bounds, angle: 30)
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: CGRect(x: 100, y: 50, width: 400, height: 300), xRadius: 12, yRadius: 12).fill()
            NSColor.black.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: CGRect(x: 530, y: 130, width: 350, height: 280), xRadius: 12, yRadius: 12).fill()
            return true
        }
        let preview = NSHostingView(rootView:
            ZStack {
                Color(white: 0.09)
                Image(nsImage: desktop).resizable().aspectRatio(contentMode: .fit)
                    .overlay {
                        AreaPreviewEditor(
                            area: Binding(get: { area }, set: { area = $0 }),
                            displayFrame: display, isEditable: true
                        )
                    }.padding(24)
            }.frame(width: 648, height: 220)
        )
        let previewWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 648, height: 220),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false
        previewWindow.contentView = preview
        preview.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func findEditor(in view: NSView) -> AreaPreviewSelectionView? {
            if let editor = view as? AreaPreviewSelectionView { return editor }
            return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
        }
        let fittedEditor = findEditor(in: preview)!
        expect(fittedEditor.bounds, CGRect(x: 0, y: 0, width: 344, height: 172), "Overlay matches fitted image, excluding letterboxing")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: previewWindow.windowNumber, context: nil, characters: "",
                                  charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        fittedEditor.keyDown(with: key)
        expect(area.rect, initial.offsetBy(dx: 1, dy: 0), "Native edits update the SwiftUI recording-area binding")
        if let output = ProcessInfo.processInfo.environment["AREA_PREVIEW_SNAPSHOT"] {
            let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
        previewWindow.close()
        print("Area preview checks passed: coordinate mapping, clipping, drawing, moving, resizing, keyboard nudges, and recording lock.")
    }

    static func expect(_ actual: CGRect?, _ expected: CGRect, _ message: String) {
        guard let actual,
              abs(actual.minX - expected.minX) < 0.01, abs(actual.minY - expected.minY) < 0.01,
              abs(actual.width - expected.width) < 0.01, abs(actual.height - expected.height) < 0.01 else {
            fatalError("\(message): expected \(expected), got \(String(describing: actual))")
        }
    }
}
