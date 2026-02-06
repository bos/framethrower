import AppKit
import Foundation

enum AreaSelectionError: Error {
    case cancelled
}

@MainActor
enum AreaSelectionCoordinator {
    private static var activeController: AreaSelectionWindowController?

    static func selectArea(in frame: CGRect) async throws -> CGRect {
        try await withCheckedThrowingContinuation { continuation in
            let controller = AreaSelectionWindowController(frame: frame) { result in
                activeController = nil
                switch result {
                case let .selected(rect):
                    continuation.resume(returning: rect)
                case .cancelled:
                    continuation.resume(throwing: AreaSelectionError.cancelled)
                }
            }
            activeController = controller
            controller.showWindow(nil)
        }
    }
}

private enum AreaSelectionResult {
    case selected(CGRect)
    case cancelled
}

@MainActor
private final class AreaSelectionWindowController: NSWindowController {
    private let completion: (AreaSelectionResult) -> Void

    init(frame: CGRect, completion: @escaping (AreaSelectionResult) -> Void) {
        self.completion = completion
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = AreaSelectionView(frame: CGRect(origin: .zero, size: frame.size)) { result in
            completion(result)
            window.orderOut(nil)
        }
        window.contentView = view
        window.makeFirstResponder(view)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class AreaSelectionView: NSView {
    private let completion: (AreaSelectionResult) -> Void
    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

    init(frame: CGRect, completion: @escaping (AreaSelectionResult) -> Void) {
        self.completion = completion
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            completion(.cancelled)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let rect = selectionRect(), rect.width >= 2, rect.height >= 2 else {
            completion(.cancelled)
            return
        }
        let windowOrigin = window?.frame.origin ?? .zero
        let screenRect = CGRect(
            x: rect.origin.x + windowOrigin.x,
            y: rect.origin.y + windowOrigin.y,
            width: rect.width,
            height: rect.height
        )
        completion(.selected(screenRect))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let rect = selectionRect() else { return }
        let overlay = NSColor.black.withAlphaComponent(0.2)
        overlay.setFill()
        rect.fill()

        let border = NSBezierPath(rect: rect)
        NSColor.white.setStroke()
        border.lineWidth = 2
        border.stroke()
    }

    private func selectionRect() -> CGRect? {
        guard let startPoint, let currentPoint else { return nil }
        let minX = min(startPoint.x, currentPoint.x)
        let minY = min(startPoint.y, currentPoint.y)
        let maxX = max(startPoint.x, currentPoint.x)
        let maxY = max(startPoint.y, currentPoint.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
