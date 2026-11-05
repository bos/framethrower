import AppKit
import Foundation

enum AreaSelectionError: Error {
    case cancelled
}

@MainActor
enum AreaSelectionCoordinator {
    private static var activeController: AreaSelectionWindowController?

    static func selectArea(in frame: CGRect, initialSelection: CGRect?) async throws -> CGRect {
        try await withCheckedThrowingContinuation { continuation in
            let controller = AreaSelectionWindowController(
                frame: frame,
                initialSelection: initialSelection
            ) { result in
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

    init(
        frame: CGRect,
        initialSelection: CGRect?,
        completion: @escaping (AreaSelectionResult) -> Void
    ) {
        self.completion = completion
        let window = AreaSelectionWindow(
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
        let localInitialSelection: CGRect?
        if let initialSelection {
            let clamped = initialSelection.intersection(frame)
            if clamped.width >= 2, clamped.height >= 2 {
                localInitialSelection = CGRect(
                    x: clamped.minX - frame.minX,
                    y: clamped.minY - frame.minY,
                    width: clamped.width,
                    height: clamped.height
                )
            } else {
                localInitialSelection = nil
            }
        } else {
            localInitialSelection = nil
        }
        let view = AreaSelectionView(
            frame: CGRect(origin: .zero, size: frame.size),
            initialSelection: localInitialSelection
        ) { result in
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

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private final class AreaSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class AreaSelectionView: NSView {
    private enum DragMode {
        case creating(anchor: CGPoint)
        case resizing(corner: Corner, opposite: CGPoint)
    }

    private enum Corner: CaseIterable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
    }

    private enum ActionButton {
        case confirm
        case cancel
    }

    private let completion: (AreaSelectionResult) -> Void
    private var selection: CGRect?
    private var dragMode: DragMode?
    private var hasFinishedDragSincePresentation = false
    private var hoveredActionButton: ActionButton?
    private var pointerTrackingArea: NSTrackingArea?
    private let handleSize: CGFloat = 12

    init(
        frame: CGRect,
        initialSelection: CGRect?,
        completion: @escaping (AreaSelectionResult) -> Void
    ) {
        self.completion = completion
        self.selection = initialSelection
        if let initialSelection, initialSelection.width >= 2, initialSelection.height >= 2 {
            hasFinishedDragSincePresentation = true
        }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredActionButton(at: point)
    }

    override func mouseExited(with _: NSEvent) {
        if hoveredActionButton != nil {
            hoveredActionButton = nil
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            completion(.cancelled)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            confirmSelectionIfValid()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredActionButton(at: point)
        if let action = actionButton(at: point) {
            switch action {
            case .confirm:
                confirmSelectionIfValid()
            case .cancel:
                completion(.cancelled)
            }
            return
        }
        if let corner = cornerHandle(at: point), let selection {
            hasFinishedDragSincePresentation = false
            hoveredActionButton = nil
            dragMode = .resizing(
                corner: corner,
                opposite: oppositeCorner(for: corner, in: selection)
            )
            needsDisplay = true
            return
        }
        if let selection, selection.contains(point) {
            dragMode = nil
            return
        }
        hasFinishedDragSincePresentation = false
        hoveredActionButton = nil
        dragMode = .creating(anchor: point)
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredActionButton(at: point)
        switch dragMode {
        case let .creating(anchor):
            selection = rect(from: anchor, to: point)
        case let .resizing(_, opposite):
            selection = rect(from: opposite, to: point)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) {
        defer {
            dragMode = nil
            needsDisplay = true
        }
        switch dragMode {
        case .creating, .resizing:
            if let selection, selection.width >= 2, selection.height >= 2 {
                self.selection = clampToBounds(selection)
                hasFinishedDragSincePresentation = true
            } else {
                self.selection = nil
            }
        case .none:
            break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let selection, selection.width >= 2, selection.height >= 2 else {
            NSColor.black.withAlphaComponent(0.2).setFill()
            bounds.fill()
            drawInstructions()
            return
        }

        let rect = clampToBounds(selection)
        let overlayPath = NSBezierPath(rect: bounds)
        overlayPath.appendRect(rect)
        overlayPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.2).setFill()
        overlayPath.fill()

        let border = NSBezierPath(rect: rect)
        NSColor.white.setStroke()
        border.lineWidth = 2
        border.stroke()
        drawCornerHandles(for: rect)
        drawActionButtons(for: rect)
        drawInstructions()
    }

    private func drawInstructions() {
        let message = (
            "Drag to select an area. Drag corners to adjust. " +
            "Press Return to confirm or Esc to cancel."
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: message, attributes: attributes)
        let maxWidth = min(bounds.width - 40, 760)
        var textRect = attributed.boundingRect(
            with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        textRect.origin.x = (bounds.width - textRect.width) * 0.5
        textRect.origin.y = bounds.height - textRect.height - 28
        let backdropRect = textRect.insetBy(dx: -14, dy: -8)
        let backdrop = NSBezierPath(
            roundedRect: backdropRect,
            xRadius: 10,
            yRadius: 10
        )
        NSColor.black.withAlphaComponent(0.45).setFill()
        backdrop.fill()
        attributed.draw(in: textRect)
    }

    private func rect(from first: CGPoint, to second: CGPoint) -> CGRect {
        let minX = min(first.x, second.x)
        let minY = min(first.y, second.y)
        let maxX = max(first.x, second.x)
        let maxY = max(first.y, second.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clampToBounds(_ rect: CGRect) -> CGRect {
        let clamped = rect.intersection(bounds)
        if clamped.width < 2 || clamped.height < 2 {
            return .zero
        }
        return clamped
    }

    private func cornerHandle(at point: CGPoint) -> Corner? {
        guard let selection, selection.width >= 2, selection.height >= 2 else { return nil }
        let handles = handleRects(for: selection)
        return Corner.allCases.first(where: { corner in
            handles[corner, default: .zero].contains(point)
        })
    }

    private func handleRects(for rect: CGRect) -> [Corner: CGRect] {
        let half = handleSize * 0.5
        return [
            .topLeft: CGRect(x: rect.minX - half, y: rect.maxY - half, width: handleSize,
                             height: handleSize),
            .topRight: CGRect(x: rect.maxX - half, y: rect.maxY - half, width: handleSize,
                              height: handleSize),
            .bottomLeft: CGRect(x: rect.minX - half, y: rect.minY - half, width: handleSize,
                                height: handleSize),
            .bottomRight: CGRect(x: rect.maxX - half, y: rect.minY - half, width: handleSize,
                                 height: handleSize)
        ]
    }

    private func oppositeCorner(for corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:
            return CGPoint(x: rect.maxX, y: rect.minY)
        case .topRight:
            return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomLeft:
            return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottomRight:
            return CGPoint(x: rect.minX, y: rect.maxY)
        }
    }

    private func drawCornerHandles(for rect: CGRect) {
        let handles = handleRects(for: rect)
        for corner in Corner.allCases {
            let handleRect = handles[corner, default: .zero]
            let path = NSBezierPath(
                roundedRect: handleRect,
                xRadius: 2,
                yRadius: 2
            )
            NSColor.systemBlue.withAlphaComponent(0.95).setFill()
            path.fill()
            NSColor.white.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func actionButton(at point: CGPoint) -> ActionButton? {
        guard hasFinishedDragSincePresentation, let selection else { return nil }
        let rect = clampToBounds(selection)
        guard let buttons = actionButtons(for: rect) else { return nil }
        if buttons.confirm.contains(point) {
            return .confirm
        }
        if buttons.cancel.contains(point) {
            return .cancel
        }
        return nil
    }

    private func actionButtons(for rect: CGRect) -> (confirm: CGRect, cancel: CGRect)? {
        guard rect.width >= 220, rect.height >= 56 else { return nil }
        let margin: CGFloat = 10
        let spacing: CGFloat = 8
        let buttonHeight: CGFloat = 30
        let confirmWidth: CGFloat = 96
        let cancelWidth: CGFloat = 88

        let confirmX = rect.maxX - margin - confirmWidth
        let cancelX = confirmX - spacing - cancelWidth
        if cancelX < rect.minX + margin {
            return nil
        }
        let y = rect.minY + margin
        let confirm = CGRect(
            x: confirmX,
            y: y,
            width: confirmWidth,
            height: buttonHeight
        )
        let cancel = CGRect(
            x: cancelX,
            y: y,
            width: cancelWidth,
            height: buttonHeight
        )
        return (confirm: confirm, cancel: cancel)
    }

    private func drawActionButtons(for rect: CGRect) {
        guard hasFinishedDragSincePresentation,
              let buttons = actionButtons(for: rect) else {
            return
        }
        drawActionButton(
            in: buttons.confirm,
            title: "Confirm",
            fillColor: NSColor.systemGreen,
            isHovered: hoveredActionButton == .confirm
        )
        drawActionButton(
            in: buttons.cancel,
            title: "Cancel",
            fillColor: NSColor.systemRed,
            isHovered: hoveredActionButton == .cancel
        )
    }

    private func drawActionButton(
        in rect: CGRect,
        title: String,
        fillColor: NSColor,
        isHovered: Bool
    ) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fillAlpha: CGFloat = isHovered ? 1.0 : 0.9
        fillColor.withAlphaComponent(fillAlpha).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.lineWidth = isHovered ? 1.5 : 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: title, attributes: attributes)
        let textRect = CGRect(
            x: rect.minX,
            y: rect.midY - 9,
            width: rect.width,
            height: 18
        )
        attributed.draw(in: textRect)
    }

    private func updateHoveredActionButton(at point: CGPoint) {
        let newHovered = actionButton(at: point)
        if hoveredActionButton != newHovered {
            hoveredActionButton = newHovered
            needsDisplay = true
        }
    }

    private func confirmSelectionIfValid() {
        guard let selection = selection,
              selection.width >= 2,
              selection.height >= 2 else {
            return
        }
        let rect = clampToBounds(selection)
        guard rect.width >= 2, rect.height >= 2 else { return }
        let windowOrigin = window?.frame.origin ?? .zero
        let screenRect = CGRect(
            x: rect.origin.x + windowOrigin.x,
            y: rect.origin.y + windowOrigin.y,
            width: rect.width,
            height: rect.height
        )
        completion(.selected(screenRect))
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
