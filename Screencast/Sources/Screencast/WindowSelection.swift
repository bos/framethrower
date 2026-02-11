import AppKit
import CoreGraphics

enum WindowSelectionError: Error {
    case cancelled
    case noWindow
}

@MainActor
final class WindowSelectionCoordinator: NSObject {
    private static var activeCoordinator: WindowSelectionCoordinator?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<CGWindowID, any Error>?
    private var excludedBundleID: String?
    private let logger: (String) -> Void
    private var eventMonitor: Any?
    private var globalMouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var globalKeyMonitor: Any?
    private var lastHoverID: CGWindowID?

    static func selectWindow(excludingBundleID: String?,
                             log: @escaping (String) -> Void) async throws -> CGWindowID {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = WindowSelectionCoordinator(logger: log)
            WindowSelectionCoordinator.activeCoordinator = coordinator
            coordinator.excludedBundleID = excludingBundleID
            coordinator.continuation = continuation
            coordinator.presentOverlay()
        }
    }

    init(logger: @escaping (String) -> Void) {
        self.logger = logger
    }

    private func presentOverlay() {
        let overlay = WindowSelectionWindow(
            contentRect: NSScreen.screens.reduce(CGRect.zero) { rect, screen in
                rect.union(screen.frame)
            },
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.level = .screenSaver
        overlay.ignoresMouseEvents = false
        overlay.acceptsMouseMovedEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = WindowSelectionView { [weak self] point in
            self?.handleClick(at: point)
        } onHover: { [weak self] point in
            self?.handleHover(at: point)
        } onCancel: { [weak self] in
            self?.finish(.failure(WindowSelectionError.cancelled))
        }
        overlay.contentView = view
        view.frame = overlay.contentLayoutRect
        view.autoresizingMask = [.width, .height]
        overlay.makeFirstResponder(view)

        overlay.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        overlay.makeKeyAndOrderFront(nil)

        window = overlay
        logger("Window selection overlay shown.")
        if excludedBundleID != nil {
            logger("Screencast windows are ignored during selection.")
        }
        startEventMonitoring()
    }

    private func handleHover(at point: CGPoint) {
        guard let view = window?.contentView as? WindowSelectionView else { return }
        let candidates = windowCandidates(at: point, excludingBundleID: excludedBundleID)
        let hit = candidates.first
        if hit?.id != lastHoverID {
            lastHoverID = hit?.id
            if let hit {
                logger(
                    "Hover window \(hit.describe) at \(format(point)) frame \(format(hit.frame))."
                )
            }
        }
        view.highlightedFrame = hit?.frame
    }

    private func handleClick(at point: CGPoint) {
        let candidates = windowCandidates(at: point, excludingBundleID: excludedBundleID)
        guard let hit = candidates.first else {
            logger("Click: no window at \(format(point)).")
            finish(.failure(WindowSelectionError.noWindow))
            return
        }
        logger("Click: selected window \(hit.describe) frame \(format(hit.frame)).")
        finish(.success(hit.id))
    }

    private func finish(_ result: Result<CGWindowID, any Error>) {
        stopEventMonitoring()
        NSCursor.arrow.set()
        window?.orderOut(nil)
        window = nil

        guard let continuation else { return }
        self.continuation = nil
        WindowSelectionCoordinator.activeCoordinator = nil
        continuation.resume(with: result)
    }

    private func startEventMonitoring() {
        if eventMonitor != nil { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .mouseMoved]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 {
                    self.logger("ESC pressed. Cancelling window selection.")
                    self.finish(.failure(WindowSelectionError.cancelled))
                    return nil
                }
            case .leftMouseDown:
                let screenPoint = NSEvent.mouseLocation
                self.handleClick(at: screenPoint)
                return nil
            case .mouseMoved:
                let screenPoint = NSEvent.mouseLocation
                self.handleHover(at: screenPoint)
            default:
                break
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved]
        ) { [weak self] _ in
            guard let self else { return }
            let screenPoint = NSEvent.mouseLocation
            self.handleHover(at: screenPoint)
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            let screenPoint = NSEvent.mouseLocation
            self.handleClick(at: screenPoint)
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            guard let self else { return }
            if event.keyCode == 53 {
                self.logger("ESC pressed (global). Cancelling window selection.")
                self.finish(.failure(WindowSelectionError.cancelled))
            }
        }
    }

    private func stopEventMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }
}

extension WindowSelectionCoordinator: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {}
}

private final class WindowSelectionView: NSView {
    private let onClick: (CGPoint) -> Void
    private let onHover: (CGPoint) -> Void
    private let onCancel: () -> Void
    private let overlayFill = NSColor.black.withAlphaComponent(0.2)
    private let highlightFill = NSColor.systemBlue.withAlphaComponent(0.35)
    private let highlightStroke = NSColor.systemBlue.withAlphaComponent(0.85)
    private var trackingArea: NSTrackingArea?
    private let instructionsBackground = NSView(frame: .zero)
    private lazy var instructionsLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Click a window to select. Esc to cancel.")
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.white
        label.alignment = .center
        return label
    }()
    private lazy var cameraCursor: NSCursor = {
        let image = makeCameraCursorImage()
        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2)
        )
    }()

    var highlightedFrame: CGRect? {
        didSet { needsDisplay = true }
    }

    init(onClick: @escaping (CGPoint) -> Void,
         onHover: @escaping (CGPoint) -> Void,
         onCancel: @escaping () -> Void) {
        self.onClick = onClick
        self.onHover = onHover
        self.onCancel = onCancel
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        window?.makeKey()
        NSCursor.unhide()
        NSCursor.setHiddenUntilMouseMoves(false)
        cameraCursor.set()
        setupInstructions()
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cameraCursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let windowPoint = event.locationInWindow
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        onClick(screenPoint)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let window else { return }
        let windowPoint = event.locationInWindow
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        onHover(screenPoint)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        overlayFill.setFill()
        NSBezierPath(rect: bounds).fill()
        guard let highlightedFrame,
              let window = window else { return }
        let windowRect = window.convertFromScreen(highlightedFrame)
        let viewRect = convert(windowRect, from: nil)
        let path = NSBezierPath(rect: viewRect)
        highlightFill.setFill()
        path.fill()
        highlightStroke.setStroke()
        path.lineWidth = 2.5
        path.stroke()
    }

    private func setupInstructions() {
        if instructionsBackground.superview == nil {
            instructionsBackground.wantsLayer = true
            instructionsBackground.layer?.backgroundColor = NSColor.black
                .withAlphaComponent(0.6).cgColor
            instructionsBackground.layer?.cornerRadius = 6
            instructionsBackground.layer?.masksToBounds = true
            addSubview(instructionsBackground)
        }
        if instructionsLabel.superview == nil {
            instructionsBackground.addSubview(instructionsLabel)
        }
        instructionsBackground.translatesAutoresizingMaskIntoConstraints = false
        instructionsLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            instructionsBackground.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            instructionsBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            instructionsLabel.leadingAnchor.constraint(equalTo: instructionsBackground.leadingAnchor,
                                                       constant: 12),
            instructionsLabel.trailingAnchor.constraint(equalTo: instructionsBackground.trailingAnchor,
                                                        constant: -12),
            instructionsLabel.topAnchor.constraint(equalTo: instructionsBackground.topAnchor,
                                                   constant: 6),
            instructionsLabel.bottomAnchor.constraint(equalTo: instructionsBackground.bottomAnchor,
                                                      constant: -6)
        ])
    }
}

private extension NSImage {
    func drawCameraIcon(in rect: NSRect,
                        fill: NSColor,
                        stroke: NSColor) {
        let radius = min(rect.width, rect.height) / 2 - 1
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let outer = NSBezierPath()
        outer.appendArc(withCenter: center,
                        radius: radius,
                        startAngle: 0,
                        endAngle: 360)
        stroke.setStroke()
        outer.lineWidth = 2
        outer.stroke()

        let inner = NSBezierPath()
        inner.appendArc(withCenter: center,
                        radius: radius - 2,
                        startAngle: 0,
                        endAngle: 360)
        fill.setFill()
        inner.fill()

        let body = NSBezierPath(roundedRect: NSRect(
            x: center.x - radius * 0.55,
            y: center.y - radius * 0.25,
            width: radius * 1.1,
            height: radius * 0.7
        ), xRadius: 2, yRadius: 2)
        stroke.setFill()
        body.fill()

        let lens = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius * 0.18,
            y: center.y - radius * 0.05,
            width: radius * 0.36,
            height: radius * 0.36
        ))
        fill.setFill()
        lens.fill()
    }
}

private func format(_ point: CGPoint) -> String {
    String(format: "x=%.0f y=%.0f", point.x, point.y)
}

private func format(_ rect: CGRect) -> String {
    String(format: "x=%.0f y=%.0f w=%.0f h=%.0f",
           rect.origin.x,
           rect.origin.y,
           rect.size.width,
           rect.size.height)
}

private func makeCameraCursorImage() -> NSImage {
    let size = NSSize(width: 24, height: 24)
    let image = NSImage(size: size)
    image.lockFocus()
    let rect = NSRect(origin: .zero, size: size)
    NSColor.black.setFill()
    rect.fill()
    image.unlockFocus()

    let composed = NSImage(size: size)
    composed.lockFocus()
    let clearRect = NSRect(origin: .zero, size: size)
    NSColor.clear.setFill()
    clearRect.fill()
    composed.drawCameraIcon(
        in: clearRect,
        fill: NSColor.systemYellow,
        stroke: NSColor.black.withAlphaComponent(0.9)
    )
    composed.unlockFocus()
    return composed
}

private final class WindowSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct WindowHit {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let ownerName: String
    let windowTitle: String
    let layer: Int
    let order: Int

    var describe: String {
        let title = windowTitle.isEmpty ? "Untitled" : windowTitle
        return "\(ownerName) — \(title) [id \(id) pid \(pid) layer \(layer) order \(order)]"
    }
}

private func windowCandidates(at point: CGPoint, excludingBundleID: String?) -> [WindowHit] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
        as? [[String: Any]] else {
        return []
    }
    let quartzPoint = quartzPoint(fromCocoaPoint: point)

    var candidates: [WindowHit] = []
    for (index, window) in info.enumerated() {
        guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else {
            continue
        }
        if let onScreen = window[kCGWindowIsOnscreen as String] as? NSNumber,
           onScreen.intValue == 0 {
            continue
        }
        if let alpha = window[kCGWindowAlpha as String] as? NSNumber,
           alpha.doubleValue < 0.01 {
            continue
        }
        guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
              let rawBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            continue
        }
        if rawBounds.width < 2 || rawBounds.height < 2 {
            continue
        }
        if !rawBounds.contains(quartzPoint) {
            continue
        }
        if let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid == getpid() {
            continue
        }
        if let excludingBundleID, let pid = window[kCGWindowOwnerPID as String] as? pid_t {
            let running = NSRunningApplication(processIdentifier: pid)
            if running?.bundleIdentifier == excludingBundleID {
                continue
            }
        }
        guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else {
            continue
        }
        guard let id = window[kCGWindowNumber as String] as? CGWindowID else {
            continue
        }
        let bounds = normalizeWindowBounds(rawBounds)
        let ownerName = window[kCGWindowOwnerName as String] as? String ?? "Unknown"
        let windowTitle = window[kCGWindowName as String] as? String ?? ""
        candidates.append(WindowHit(id: id,
                                    pid: pid,
                                    frame: bounds,
                                    ownerName: ownerName,
                                    windowTitle: windowTitle,
                                    layer: layer,
                                    order: index))
    }
    return candidates
}

private func normalizeWindowBounds(_ bounds: CGRect) -> CGRect {
    guard let desktopBounds = unifiedDesktopBounds() else {
        return bounds
    }
    // CGWindow bounds use a top-left origin; Cocoa uses bottom-left.
    let flippedY = desktopBounds.maxY - bounds.origin.y - bounds.size.height
    return CGRect(
        x: bounds.origin.x,
        y: flippedY,
        width: bounds.size.width,
        height: bounds.size.height
    )
}

private func quartzPoint(fromCocoaPoint point: CGPoint) -> CGPoint {
    guard let desktopBounds = unifiedDesktopBounds() else {
        return point
    }
    return CGPoint(x: point.x, y: desktopBounds.maxY - point.y)
}

private func unifiedDesktopBounds() -> CGRect? {
    let screens = NSScreen.screens
    guard let first = screens.first else { return nil }
    return screens.dropFirst().reduce(first.frame) { rect, screen in
        rect.union(screen.frame)
    }
}
