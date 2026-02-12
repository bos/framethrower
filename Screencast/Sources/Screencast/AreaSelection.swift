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

enum RecordingCountdownError: Error {
    case cancelled
}

@MainActor
enum RecordingCountdownCoordinator {
    private static var activeState: CountdownState?
    private static var overlayWindows: [CountdownOverlayWindow] = []

    static func run(seconds: Int, onTick: @escaping @MainActor (Int) -> Void) async throws {
        let countdownSeconds = max(1, seconds)
        let state = CountdownState()
        activeState = state
        ensureOverlayWindows()
        defer {
            hideOverlayWindows()
            if activeState === state {
                activeState = nil
            }
        }

        var remaining = countdownSeconds
        while remaining > 0 {
            if state.isCancelled {
                throw RecordingCountdownError.cancelled
            }
            if CGEventSource.keyState(.combinedSessionState, key: 53) {
                throw RecordingCountdownError.cancelled
            }
            showOverlayWindows(remainingSeconds: remaining)
            onTick(remaining)
            let target = Date().addingTimeInterval(1.0)
            while Date() < target {
                if state.isCancelled {
                    throw RecordingCountdownError.cancelled
                }
                if CGEventSource.keyState(.combinedSessionState, key: 53) {
                    throw RecordingCountdownError.cancelled
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            remaining -= 1
        }
    }

    static func cancelCurrent() {
        activeState?.isCancelled = true
    }

    private static func ensureOverlayWindows() {
        let screens = NSScreen.screens
        if overlayWindows.count == screens.count {
            var matches = true
            for (index, screen) in screens.enumerated() {
                if overlayWindows[index].frame != screen.frame {
                    matches = false
                    break
                }
            }
            if matches {
                return
            }
        }

        overlayWindows.removeAll(keepingCapacity: true)
        for screen in screens {
            let window = CountdownOverlayWindow(frame: screen.frame)
            overlayWindows.append(window)
        }
    }

    private static func showOverlayWindows(remainingSeconds: Int) {
        for window in overlayWindows {
            window.overlayView.update(seconds: remainingSeconds)
            window.orderFrontRegardless()
        }
    }

    private static func hideOverlayWindows() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
    }
}

@MainActor
private final class CountdownState {
    var isCancelled = false
}

private final class CountdownOverlayWindow: NSWindow {
    let overlayView: CountdownOverlayView

    init(frame: CGRect) {
        overlayView = CountdownOverlayView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = overlayView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CountdownOverlayView: NSView {
    private let panel = NSView(frame: .zero)
    private let numberLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "Press Esc to cancel")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(seconds: Int) {
        numberLabel.stringValue = "\(seconds)"
    }

    private func setup() {
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.48).cgColor
        panel.layer?.cornerRadius = 16
        panel.layer?.masksToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 180, weight: .bold)
        numberLabel.textColor = .white
        numberLabel.alignment = .center
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(numberLabel)

        hintLabel.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 420),
            panel.heightAnchor.constraint(equalToConstant: 360),

            numberLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            numberLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            numberLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),

            hintLabel.topAnchor.constraint(equalTo: numberLabel.bottomAnchor, constant: -8),
            hintLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            hintLabel.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24)
        ])
    }
}
