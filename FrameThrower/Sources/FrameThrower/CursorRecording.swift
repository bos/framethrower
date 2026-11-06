import AppKit
import CoreMedia
import Foundation

struct CursorSample: Codable, Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
    var visible: Bool = true
    var buttons: UInt64 = 0
}

struct CursorClick: Codable, Equatable, Sendable {
    var time: Double
    var x: Double
    var y: Double
    /// AppKit button numbers: 0 left, 1 right, 2 and above other buttons.
    var button: Int
}

enum CursorRecordingError: LocalizedError {
    case invalidData
    case unavailable
    var errorDescription: String? {
        switch self {
        case .invalidData: return "The pointer recording contains invalid data."
        case .unavailable: return "The pointer recording is unavailable."
        }
    }
}

/// Immutable source metadata. Positions are normalized top-left coordinates in
/// the recorded content; timestamps are in the screen movie's source timeline.
struct CursorRecording: Codable, Equatable, Sendable {
    var version = 1
    var duration: Double
    var logicalWidth: Double
    var logicalHeight: Double
    var samples: [CursorSample]
    var clicks: [CursorClick]

    var logicalSize: CGSize { CGSize(width: logicalWidth, height: logicalHeight) }

    func validate() throws {
        guard version == 1, duration.isFinite, duration > 0,
              logicalWidth.isFinite, logicalHeight.isFinite,
              logicalWidth >= 2, logicalHeight >= 2, !samples.isEmpty else {
            throw CursorRecordingError.invalidData
        }
        var previous = -Double.infinity
        for sample in samples {
            guard sample.time.isFinite, sample.time >= 0, sample.time <= duration,
                  sample.time > previous, Self.validPoint(sample.x, sample.y) else {
                throw CursorRecordingError.invalidData
            }
            previous = sample.time
        }
        previous = -Double.infinity
        for click in clicks {
            guard click.time.isFinite, click.time >= 0, click.time <= duration,
                  click.time >= previous, Self.validPoint(click.x, click.y),
                  (0..<64).contains(click.button) else { throw CursorRecordingError.invalidData }
            previous = click.time
        }
    }

    static func load(from url: URL) throws -> CursorRecording {
        let recording = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try recording.validate()
        return recording
    }

    /// Publish a completed JSON file atomically without replacing any source.
    /// The temporary hard link is in the destination directory/volume.
    func write(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).cursor.tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.linkItem(at: temporary, to: url)
    }

    /// Symmetric, offline smoothing has no accumulating playback-state or
    /// direction dependence. Click anchors preserve precise target positions.
    func pointer(at time: Double, smoothing: Double = 0) -> CursorSample? {
        guard var value = rawPointer(at: time) else { return nil }
        let amount = smoothing.isFinite ? min(1, max(0, smoothing)) : 0
        // Dragging, selection, and drawing retain the exact captured path.
        guard value.visible, value.buttons == 0, amount > 0 else { return value }
        let radius = 0.12 * amount
        var left = max(0, time - radius)
        var right = min(duration, time + radius)
        let begin = sampleIndex(atOrBefore: left)
        let end = sampleIndex(atOrBefore: right)
        if begin <= end {
            for index in begin...end where !samples[index].visible || samples[index].buttons != value.buttons {
                if samples[index].time <= time { left = max(left, samples[index].time) }
                else { right = min(right, samples[index].time) }
            }
        }
        var x = 0.0, y = 0.0, weight = 0.0
        for step in -4...4 {
            let position = time + Double(step) * radius / 4
            guard position >= left, position <= right,
                  let neighbor = rawPointer(at: position), neighbor.visible, neighbor.buttons == value.buttons else { continue }
            let contribution = Double(5 - abs(step))
            x += neighbor.x * contribution
            y += neighbor.y * contribution
            weight += contribution
        }
        if weight > 0 { value.x = x / weight; value.y = y / weight }
        let anchorRadius = 0.08 * amount
        let candidate = clickIndex(atOrBefore: time)
        var closest: CursorClick?
        for index in [candidate, candidate + 1] where clicks.indices.contains(index) {
            let click = clicks[index]
            if abs(click.time - time) <= anchorRadius,
               rawPointer(at: click.time)?.buttons == value.buttons,
               closest == nil || abs(click.time - time) < abs(closest!.time - time) { closest = click }
        }
        if let closest {
            let distance = min(1, abs(closest.time - time) / anchorRadius)
            let blend = 1 - distance * distance * (3 - 2 * distance)
            value.x += (closest.x - value.x) * blend
            value.y += (closest.y - value.y) * blend
        }
        value.x = min(1, max(0, value.x))
        value.y = min(1, max(0, value.y))
        return value
    }

    private func rawPointer(at time: Double) -> CursorSample? {
        guard time.isFinite, time >= 0, time <= duration, !samples.isEmpty, time >= samples[0].time else { return nil }
        let index = sampleIndex(atOrBefore: time)
        var value = samples[index]
        value.time = time
        guard samples.indices.contains(index + 1) else { return value }
        let next = samples[index + 1]
        guard value.visible, next.visible, next.time > samples[index].time else { return value }
        let fraction = min(1, max(0, (time - samples[index].time) / (next.time - samples[index].time)))
        value.x += (next.x - value.x) * fraction
        value.y += (next.y - value.y) * fraction
        return value
    }

    private func sampleIndex(atOrBefore time: Double) -> Int {
        var lower = 0, upper = samples.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if samples[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }

    private func clickIndex(atOrBefore time: Double) -> Int {
        var lower = 0, upper = clicks.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if clicks[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        return lower - 1
    }

    private static func validPoint(_ x: Double, _ y: Double) -> Bool {
        x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }
}

/// All regions are in Quartz's global top-left coordinate space. Area sourceRect
/// is the exact display-local rectangle supplied to ScreenCaptureKit.
enum CursorCaptureSource: Sendable {
    case display(bounds: CGRect)
    case area(displayBounds: CGRect, sourceRect: CGRect)
    case window(id: CGWindowID, processID: pid_t, logicalSize: CGSize)

    var logicalSize: CGSize {
        switch self {
        case let .display(bounds): return bounds.size
        case let .area(_, sourceRect): return sourceRect.size
        case let .window(_, _, logicalSize): return logicalSize
        }
    }

    func bounds(windowBounds: (CGWindowID, pid_t) -> CGRect?) -> CGRect? {
        switch self {
        case let .display(bounds): return bounds
        case let .area(displayBounds, sourceRect):
            return sourceRect.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
        case let .window(id, processID, _): return windowBounds(id, processID)
        }
    }

    static func quartzPoint(fromAppKit point: CGPoint, primaryDisplayTop: Double) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayTop - point.y)
    }
}

/// Pure capture accumulator, independent of timers, windows, and permissions.
/// Event samples are retained alongside 60Hz motion samples, so a complete click
/// between timer ticks is never lost. Late monitor delivery is sorted by time.
struct CursorCaptureBuilder {
    private struct Sample {
        var hostTime: Double
        var value: CursorSample
        var sequence: Int
    }
    private struct Click {
        var hostTime: Double
        var value: CursorClick
    }
    let logicalSize: CGSize
    private var samples: [Sample] = []
    private var clicks: [Click] = []
    private var sequence = 0
    var isEmpty: Bool { samples.isEmpty }

    mutating func append(hostTime: Double, point: CGPoint, bounds: CGRect?, buttons: UInt64, clickButton: Int? = nil) {
        guard hostTime.isFinite, point.x.isFinite, point.y.isFinite else { return }
        let previous = samples.last?.value
        let valid = bounds.map { !$0.isNull && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 } == true
        let x = valid ? min(1, max(0, (point.x - bounds!.minX) / bounds!.width)) : (previous?.x ?? 0.5)
        let y = valid ? min(1, max(0, (point.y - bounds!.minY) / bounds!.height)) : (previous?.y ?? 0.5)
        let visible = valid && bounds!.contains(point)
        let value = CursorSample(time: 0, x: x, y: y, visible: visible, buttons: buttons)
        samples.append(Sample(hostTime: hostTime, value: value, sequence: sequence))
        sequence += 1
        if visible, let clickButton, (0..<64).contains(clickButton) {
            clicks.append(Click(hostTime: hostTime, value: CursorClick(time: 0, x: x, y: y, button: clickButton)))
        }
    }

    func recording(screenStartHostTime: Double, duration: Double, firstFrameSourceTime: Double = 0) throws -> CursorRecording {
        guard screenStartHostTime.isFinite, duration.isFinite, duration > 0,
              firstFrameSourceTime.isFinite, firstFrameSourceTime >= 0, firstFrameSourceTime < duration,
              !samples.isEmpty else { throw CursorRecordingError.invalidData }
        let origin = screenStartHostTime - firstFrameSourceTime
        let ordered = samples.sorted { $0.hostTime == $1.hostTime ? $0.sequence < $1.sequence : $0.hostTime < $1.hostTime }
        let first = ordered.last(where: { $0.hostTime <= screenStartHostTime }) ?? ordered[0]
        var initial = first.value
        initial.time = firstFrameSourceTime
        var values: [CursorSample] = []
        if firstFrameSourceTime > 0 {
            var hidden = initial; hidden.time = 0; hidden.visible = false
            values.append(hidden)
        }
        values.append(initial)
        for raw in ordered where raw.hostTime > screenStartHostTime && raw.hostTime - origin <= duration {
            var value = raw.value
            value.time = max(firstFrameSourceTime, raw.hostTime - origin)
            if values.last?.time == value.time { values[values.count - 1] = value }
            else { values.append(value) }
        }
        if var last = values.last, last.time < duration { last.time = duration; values.append(last) }
        let events = clicks.sorted { $0.hostTime < $1.hostTime }.compactMap { raw -> CursorClick? in
            let time = raw.hostTime - origin
            guard time >= firstFrameSourceTime, time <= duration else { return nil }
            var event = raw.value; event.time = time
            return event
        }
        let recording = CursorRecording(duration: duration, logicalWidth: logicalSize.width,
            logicalHeight: logicalSize.height, samples: values, clicks: events)
        try recording.validate()
        return recording
    }
}

/// Mouse-only AppKit monitors require no Accessibility request. Key events and
/// event taps are deliberately absent. Motion sampling uses the global position;
/// actual down/up monitors preserve clicks shorter than a sampling interval.
@MainActor
final class CursorRecorder {
    private var source: CursorCaptureSource?
    private var builder: CursorCaptureBuilder?
    private let monitors = CursorMonitorResources()
    private var eventClockOffset = 0.0
    private var buttons: UInt64 = 0
    private(set) var lastRecording: CursorRecording?

    deinit {
        let monitors = monitors
        Task { @MainActor in monitors.stop() }
    }

    @discardableResult
    func start(source: CursorCaptureSource) -> Bool {
        guard monitors.timer == nil, Self.validSize(source.logicalSize), let bounds = source.bounds(windowBounds: Self.windowBounds),
              Self.validSize(bounds.size) else { return false }
        self.source = source
        builder = CursorCaptureBuilder(logicalSize: source.logicalSize)
        lastRecording = nil
        let now = Self.hostTime()
        eventClockOffset = now - ProcessInfo.processInfo.systemUptime
        buttons = UInt64(bitPattern: Int64(NSEvent.pressedMouseButtons))
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        monitors.global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.capture(event) }
        monitors.local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.capture(event)
            return event
        }
        guard monitors.global != nil, monitors.local != nil else { cancel(); return false }
        sample()
        guard builder?.isEmpty == false else { cancel(); return false }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        monitors.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func stopCollecting() {
        monitors.stop()
    }

    func finish(screenStartHostTime: Double, duration: Double, firstFrameSourceTime: Double = 0) throws -> CursorRecording {
        stopCollecting()
        guard let builder else { throw CursorRecordingError.unavailable }
        let recording = try builder.recording(screenStartHostTime: screenStartHostTime,
            duration: duration, firstFrameSourceTime: firstFrameSourceTime)
        lastRecording = recording
        return recording
    }

    func cancel() {
        stopCollecting()
        builder = nil
        source = nil
        lastRecording = nil
    }

    private func sample() {
        guard let source else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        let point = CursorCaptureSource.quartzPoint(fromAppKit: NSEvent.mouseLocation, primaryDisplayTop: top)
        buttons = UInt64(bitPattern: Int64(NSEvent.pressedMouseButtons))
        builder?.append(hostTime: Self.hostTime(), point: point,
                        bounds: source.bounds(windowBounds: Self.windowBounds), buttons: buttons)
    }

    private func capture(_ event: NSEvent) {
        guard let source, (0..<64).contains(event.buttonNumber) else { return }
        let down = event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
        let flag = UInt64(1) << event.buttonNumber
        if down { buttons |= flag } else { buttons &= ~flag }
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height
        let point = event.cgEvent?.location
            ?? CursorCaptureSource.quartzPoint(fromAppKit: NSEvent.mouseLocation, primaryDisplayTop: top)
        let timestamp = event.timestamp + eventClockOffset
        builder?.append(hostTime: timestamp.isFinite && event.timestamp > 0 ? timestamp : Self.hostTime(),
            point: point, bounds: source.bounds(windowBounds: Self.windowBounds), buttons: buttons,
            clickButton: down ? event.buttonNumber : nil)
    }

    private static func hostTime() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    private static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width >= 2 && size.height >= 2
    }
    private static func windowBounds(id: CGWindowID, processID: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let info = windows.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id
                    && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID
              }), let dictionary = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary), validSize(bounds.size) else { return nil }
        return bounds
    }
}


/// AppKit's opaque handles are only accessed on the main actor. This container
/// can be handed to that actor for cleanup when its owner is deinitialized.
private final class CursorMonitorResources: @unchecked Sendable {
    var timer: Timer?
    var global: Any?
    var local: Any?
    @MainActor func stop() {
        timer?.invalidate()
        timer = nil
        if let global { NSEvent.removeMonitor(global); self.global = nil }
        if let local { NSEvent.removeMonitor(local); self.local = nil }
    }
}
