import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation

enum RecordedSceneError: Error { case invalidData, unavailable }

/// Quartz global points use a top-left origin. Source-pixel coordinates keep
/// that origin and describe the original recording, before any editor framing.
struct RecordedSceneSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case display, area, window }
    var kind: Kind
    var displayID: UInt32?
    var windowID: UInt32?
    var processID: Int32?
    var excludedProcessIDs: [Int32] = []
    var excludedWindowIDs: [UInt32] = []
    var globalBounds: CGRect
    var pixelWidth: Int
    var pixelHeight: Int

    func validate() throws {
        guard Self.valid(globalBounds), (1...32768).contains(pixelWidth), (1...32768).contains(pixelHeight),
              excludedProcessIDs.count <= 256, excludedWindowIDs.count <= 512,
              kind != .window || (windowID != nil && processID != nil) else { throw RecordedSceneError.invalidData }
    }

    func sourceRect(fromGlobal rect: CGRect, bounds: CGRect? = nil) -> CGRect? {
        let crop = bounds ?? globalBounds
        guard Self.valid(crop), Self.valid(rect) else { return nil }
        return CGRect(x: (rect.minX - crop.minX) * Double(pixelWidth) / crop.width,
                      y: (rect.minY - crop.minY) * Double(pixelHeight) / crop.height,
                      width: rect.width * Double(pixelWidth) / crop.width,
                      height: rect.height * Double(pixelHeight) / crop.height)
    }

    static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }
}

struct RecordedSceneWindow: Codable, Equatable, Sendable, Identifiable {
    var id: UInt32
    var processID: Int32
    var application: String?
    var bundleID: String? = nil
    var title: String?
    /// Active document only; credentials, query and fragment are discarded.
    var documentURL: String? = nil
    var frame: CGRect
    var zOrder: Int
    var isFocused: Bool?
    var isRecorderApplication: Bool
    /// Rectangle-union estimate, not an assertion about transparent pixels.
    var occlusionEstimate: Double?
    var occlusionIsInferred: Bool = true
}

struct RecordedSceneElement: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var parentID: String?
    var processID: Int32
    var windowID: UInt32?
    var role: String
    var subrole: String?
    var label: String?
    var frame: CGRect
    var isEnabled: Bool?
    var isFocused: Bool?
    var isSelected: Bool?
    var isExpanded: Bool?
    var isMenu: Bool
    var isTab: Bool = false
    /// Populated only for a selected tab when AX explicitly exposes it.
    var documentURL: String? = nil
    /// Editable/secure controls have no text or values in this archive.
    var textRedacted: Bool
}

struct RecordedSceneAvailability: Codable, Equatable, Sendable {
    var windows: Bool
    var accessibilityTrusted: Bool
    var accessibilityCollected: Bool
    var truncated: Bool = false
}

struct RecordedSceneEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case windowAppeared, windowDisappeared, windowMoved, focusChanged, menusChanged, tabChanged, metadataGap }
    var kind: Kind
    var windowID: UInt32?
}

struct RecordedSceneSnapshot: Codable, Equatable, Sendable {
    var time: Double
    /// AX controls may be reused between notifications. This age makes that
    /// distinction explicit rather than presenting cached text as current.
    var accessibilityAge: Double? = nil
    /// A pre-video observation is represented at source0; retain its real age
    /// instead of claiming it was captured exactly at the first movie frame.
    var observationAgeOffset: Double? = nil
    var observationDuration: Double = 0
    var sourceBounds: CGRect?
    var availability: RecordedSceneAvailability
    var focusedProcessID: Int32?
    var focusedWindowID: UInt32?
    var windows: [RecordedSceneWindow]
    var elements: [RecordedSceneElement]
    var events: [RecordedSceneEvent] = []
}

/// This sidecar is immutable capture evidence. Editing never queries the live
/// desktop to answer a question about an earlier source frame.
struct RecordedScene: Codable, Equatable, Sendable {
    var version = 1
    var duration: Double
    var source: RecordedSceneSource
    var sampleInterval: Double = 1
    var collector = "FrameThrower CG/AX metadata v1"
    var snapshots: [RecordedSceneSnapshot]
    static let maximumBytes = 32 * 1024 * 1024
    static let maximumSnapshots = 14_400

    func validate() throws {
        try source.validate()
        guard version == 1, duration.isFinite, duration > 0, sampleInterval.isFinite,
              (0.1...5).contains(sampleInterval), collector.count <= 160,
              !snapshots.isEmpty, snapshots.count <= Self.maximumSnapshots else { throw RecordedSceneError.invalidData }
        var previous = -Double.infinity
        for snapshot in snapshots {
            guard snapshot.time.isFinite, snapshot.time >= 0, snapshot.time <= duration,
                  snapshot.time > previous, snapshot.windows.count <= 128, snapshot.elements.count <= 128,
                  snapshot.events.count <= 384,
                  snapshot.observationDuration.isFinite, (0...5).contains(snapshot.observationDuration),
                  snapshot.accessibilityAge.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  snapshot.observationAgeOffset.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  snapshot.sourceBounds.map(RecordedSceneSource.valid) ?? true else { throw RecordedSceneError.invalidData }
            previous = snapshot.time
            guard Set(snapshot.windows.map(\.id)).count == snapshot.windows.count,
                  Set(snapshot.elements.map(\.id)).count == snapshot.elements.count else { throw RecordedSceneError.invalidData }
            let windowIDs = Set(snapshot.windows.map(\.id))
            let elementIDs = Set(snapshot.elements.map(\.id))
            let elementsByID = Dictionary(uniqueKeysWithValues: snapshot.elements.map { ($0.id, $0) })
            guard snapshot.focusedWindowID.map({ windowIDs.contains($0) }) ?? true,
                  snapshot.sourceBounds != nil || (snapshot.windows.isEmpty && snapshot.elements.isEmpty),
                  snapshot.availability.accessibilityTrusted || snapshot.elements.isEmpty,
                  source.kind != .window || snapshot.windows.allSatisfy({ $0.id == source.windowID && $0.processID == source.processID }) else {
                throw RecordedSceneError.invalidData
            }
            for window in snapshot.windows {
                guard RecordedSceneSource.valid(window.frame), window.zOrder >= 0,
                      window.title.map({ $0.count <= 512 }) ?? true,
                      window.application.map({ $0.count <= 256 }) ?? true,
                      window.bundleID.map({ $0.count <= 256 }) ?? true,
                      window.documentURL.map({ Self.sanitizedURL($0) == $0 }) ?? true,
                      window.occlusionEstimate.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                    throw RecordedSceneError.invalidData
                }
            }
            for element in snapshot.elements {
                guard RecordedSceneSource.valid(element.frame), element.id.count <= 100,
                      element.role.count <= 100, element.subrole.map({ $0.count <= 100 }) ?? true,
                      element.parentID.map({ $0 != element.id && elementIDs.contains($0) }) ?? true,
                      element.windowID.map({ windowIDs.contains($0) }) ?? true,
                      element.label.map({ $0.count <= 512 }) ?? true,
                      element.documentURL.map({ element.isTab && element.isSelected == true && Self.sanitizedURL($0) == $0 }) ?? true,
                      !element.textRedacted || element.label == nil else { throw RecordedSceneError.invalidData }
                var seen: Set<String> = [element.id]
                var parent = element.parentID
                while let id = parent {
                    guard seen.insert(id).inserted, seen.count <= 9, let ancestor = elementsByID[id],
                          ancestor.processID == element.processID, ancestor.windowID == element.windowID else {
                        throw RecordedSceneError.invalidData
                    }
                    parent = ancestor.parentID
                }
            }
        }
    }

    static func sanitizedURL(_ raw: String) -> String? {
        guard raw.count <= 4096, var value = URLComponents(string: raw),
              let scheme = value.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        value.user = nil
        value.password = nil
        value.query = nil
        value.fragment = nil
        guard let result = value.string, result.count <= 2048 else { return nil }
        return result
    }

    /// Last actual observation at or before this source time. Its own time is
    /// retained so callers can report its age; it is never interpolated.
    func snapshot(at time: Double) -> RecordedSceneSnapshot? {
        guard time.isFinite, time >= 0, time <= duration else { return nil }
        var lower = 0, upper = snapshots.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if snapshots[middle].time <= time { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return nil }
        var value = snapshots[lower - 1]
        if let age = value.accessibilityAge { value.accessibilityAge = age + max(0, time - value.time) }
        return value
    }

    static func load(from url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumBytes else { throw RecordedSceneError.invalidData }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw RecordedSceneError.invalidData }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    /// Exclusive publication cannot replace a recording or another sidecar.
    func write(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw RecordedSceneError.invalidData }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).scene.tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
            attributes: [.posixPermissions: 0o600]) else { throw RecordedSceneError.unavailable }
        try FileManager.default.linkItem(at: temporary, to: url)
    }

    func writeAsynchronously(to url: URL, timeout: Double = 3) async throws {
        try await RecordedSceneWork.run(timeout: timeout) { try write(to: url) }
    }

    /// Union of opaque rectangle intersections, clipped to the captured crop.
    /// Alpha, shadows, rounded corners and actual visible pixels are unknown.
    static func occlusion(of frame: CGRect, by preceding: [CGRect], crop: CGRect) -> Double? {
        let visible = frame.intersection(crop)
        guard RecordedSceneSource.valid(visible) else { return nil }
        let rectangles = preceding.map { $0.intersection(visible) }.filter(RecordedSceneSource.valid)
        let edges = Array(Set(rectangles.flatMap { [$0.minX, $0.maxX] })).sorted()
        var area = 0.0
        for (left, right) in zip(edges, edges.dropFirst()) where right > left {
            let intervals = rectangles.filter { $0.minX < right && $0.maxX > left }
                .map { $0.minY...$0.maxY }.sorted { $0.lowerBound < $1.lowerBound }
            var end = -Double.infinity, height = 0.0
            for interval in intervals {
                height += max(0, interval.upperBound - max(end, interval.lowerBound))
                end = max(end, interval.upperBound)
            }
            area += (right - left) * height
        }
        return min(1, max(0, area / (visible.width * visible.height)))
    }
}

struct RecordedSceneBuilder {
    struct PreparedObservation: Sendable {
        var snapshot: RecordedSceneSnapshot
        var bytes: Int
    }
    var source: RecordedSceneSource
    private let byteLimit: Int
    private var observations: [(hostTime: Double, snapshot: RecordedSceneSnapshot)] = []
    private var lastObservedHostTime: Double?
    private(set) var droppedObservations = false
    private var byteCount = 0
    private var hasGaps = false
    var isFull: Bool { droppedObservations }
    var isEmpty: Bool { observations.isEmpty }
    mutating func noteGap() { hasGaps = true }

    init(source: RecordedSceneSource, byteLimit: Int = RecordedScene.maximumBytes - 1_000_000) {
        self.source = source
        self.byteLimit = max(0, min(RecordedScene.maximumBytes - 1_000_000, byteLimit))
    }

    mutating func append(hostTime: Double, snapshot: RecordedSceneSnapshot) {
        guard let prepared = Self.prepare(source: source, snapshot: snapshot) else { return }
        append(hostTime: hostTime, prepared: prepared)
    }

    static func prepare(source: RecordedSceneSource, snapshot: RecordedSceneSnapshot) -> PreparedObservation? {
        var checked = snapshot
        checked.time = 0
        guard (try? RecordedScene(duration: 1, source: source, snapshots: [checked]).validate()) != nil,
              let bytes = try? JSONEncoder().encode(snapshot).count else { return nil }
        return PreparedObservation(snapshot: snapshot, bytes: bytes)
    }

    mutating func append(hostTime: Double, prepared: PreparedObservation) {
        guard hostTime.isFinite, lastObservedHostTime.map({ hostTime > $0 }) ?? true else { return }
        lastObservedHostTime = hostTime
        if let last = observations.last, hostTime - last.hostTime < RecordedSceneSamplingPolicy.accessibilityRefreshInterval,
           Self.semantic(last.snapshot) == Self.semantic(prepared.snapshot) { return }
        let bytes = prepared.bytes
        guard observations.count < RecordedScene.maximumSnapshots,
              byteCount + bytes <= byteLimit else { droppedObservations = true; return }
        observations.append((hostTime, prepared.snapshot))
        byteCount += bytes
    }

    private static func semantic(_ snapshot: RecordedSceneSnapshot) -> RecordedSceneSnapshot {
        var value = snapshot
        value.time = 0; value.accessibilityAge = nil; value.observationAgeOffset = nil
        value.observationDuration = 0; value.events = []
        return value
    }

    func recording(screenStartHostTime: Double, duration: Double, firstFrameSourceTime: Double = 0) throws -> RecordedScene {
        guard screenStartHostTime.isFinite, duration.isFinite, duration > 0,
              firstFrameSourceTime.isFinite, firstFrameSourceTime >= 0, firstFrameSourceTime < duration else {
            throw RecordedSceneError.invalidData
        }
        let origin = screenStartHostTime - firstFrameSourceTime
        var result: [RecordedSceneSnapshot] = []
        if let initial = observations.last(where: { $0.hostTime <= origin }) {
            var snapshot = initial.snapshot
            snapshot.time = 0
            snapshot.observationAgeOffset = max(0, origin - initial.hostTime)
            if droppedObservations || hasGaps { snapshot.availability.truncated = true }
            if hasGaps { snapshot.events.append(.init(kind: .metadataGap)) }
            result.append(snapshot)
        }
        for observation in observations where observation.hostTime > origin && observation.hostTime <= origin + duration {
            var snapshot = observation.snapshot
            snapshot.time = observation.hostTime - origin
            if droppedObservations || hasGaps { snapshot.availability.truncated = true }
            if hasGaps && result.isEmpty { snapshot.events.append(.init(kind: .metadataGap)) }
            snapshot.events += Self.events(from: result.last, to: snapshot)
            result.append(snapshot)
        }
        let value = RecordedScene(duration: duration, source: source, snapshots: result)
        try value.validate()
        return value
    }

    private static func events(from previous: RecordedSceneSnapshot?, to next: RecordedSceneSnapshot) -> [RecordedSceneEvent] {
        guard let previous else { return [] }
        let old = Dictionary(uniqueKeysWithValues: previous.windows.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: next.windows.map { ($0.id, $0) })
        var events = next.windows.compactMap { window -> RecordedSceneEvent? in
            guard let before = old[window.id] else { return .init(kind: .windowAppeared, windowID: window.id) }
            return before.frame == window.frame ? nil : .init(kind: .windowMoved, windowID: window.id)
        }
        events += previous.windows.filter { new[$0.id] == nil }.map { .init(kind: .windowDisappeared, windowID: $0.id) }
        if previous.focusedProcessID != next.focusedProcessID || previous.focusedWindowID != next.focusedWindowID {
            events.append(.init(kind: .focusChanged))
        }
        if previous.elements.filter(\.isMenu) != next.elements.filter(\.isMenu) {
            events.append(.init(kind: .menusChanged))
        }
        if previous.elements.filter({ $0.isTab && $0.isSelected == true }).map(\.id) !=
            next.elements.filter({ $0.isTab && $0.isSelected == true }).map(\.id) {
            events.append(.init(kind: .tabChanged))
        }
        return events
    }
}

/// No permissions are requested here. This collector is reachable only while
/// recording is enabled; construction and all pure archive operations are inert.
enum RecordedSceneCollector {
    static func collect(source: RecordedSceneSource, includeAccessibility: Bool = true) throws -> RecordedSceneSnapshot {
        try MediaProcessing.requireEnabled()
        try source.validate()
        let trusted = AXIsProcessTrusted()
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else {
            return RecordedSceneSnapshot(time: 0, sourceBounds: nil,
                availability: .init(windows: false, accessibilityTrusted: trusted, accessibilityCollected: false),
                windows: [], elements: [])
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.06
        let budget = AXBudget(deadline: deadline)
        let boundedRows = rows.prefix(1024)
        var crop = source.globalBounds
        if source.kind == .window {
            guard let row = boundedRows.first(where: { number($0, kCGWindowNumber)?.uint32Value == source.windowID &&
                number($0, kCGWindowOwnerPID)?.int32Value == source.processID }), let bounds = bounds(row) else {
                return RecordedSceneSnapshot(time: 0, sourceBounds: nil,
                    availability: .init(windows: true, accessibilityTrusted: trusted, accessibilityCollected: false),
                    windows: [], elements: [])
            }
            crop = bounds
        }
        var windows: [RecordedSceneWindow] = []
        var preceding: [CGRect] = []
        var truncated = rows.count > 1024
        for (index, row) in boundedRows.enumerated() {
            if budget.expired { truncated = true; break }
            guard let id = number(row, kCGWindowNumber)?.uint32Value,
                  let pid = number(row, kCGWindowOwnerPID)?.int32Value,
                  !source.excludedProcessIDs.contains(pid), !source.excludedWindowIDs.contains(id),
                  let bounds = bounds(row), bounds.intersects(crop),
                  (number(row, kCGWindowAlpha)?.doubleValue ?? 1) > 0,
                  source.kind != .window || id == source.windowID,
                  let frame = source.sourceRect(fromGlobal: bounds, bounds: crop) else { continue }
            if windows.count == 128 { truncated = true; break }
            let running = NSRunningApplication(processIdentifier: pid)
            windows.append(.init(id: id, processID: pid,
                application: limited(row[kCGWindowOwnerName as String] as? String, 256),
                bundleID: limited(running?.bundleIdentifier, 256),
                title: limited(row[kCGWindowName as String] as? String, 512), frame: frame, zOrder: index,
                isFocused: nil, isRecorderApplication: pid == getpid(),
                occlusionEstimate: source.kind == .window ? nil : RecordedScene.occlusion(of: bounds, by: preceding, crop: crop)))
            if (number(row, kCGWindowAlpha)?.doubleValue ?? 0) >= 0.99 { preceding.append(bounds) }
        }
        var snapshot = RecordedSceneSnapshot(time: 0, sourceBounds: crop,
            availability: .init(windows: true, accessibilityTrusted: trusted, accessibilityCollected: false,
                                truncated: truncated), windows: windows, elements: [])
        guard includeAccessibility, trusted, ProcessInfo.processInfo.systemUptime < deadline else { return snapshot }
        let system = AXUIElementCreateSystemWide()
        guard let focusedApplication = element(budget.attribute(system, kAXFocusedApplicationAttribute)),
              let focusedWindow = element(budget.attribute(focusedApplication, kAXFocusedWindowAttribute)) else { return snapshot }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focusedApplication, &pid) == .success else { return snapshot }
        guard let windowBounds = frame(focusedWindow, budget: budget) else { return snapshot }
        let matches = snapshot.windows.indices.filter { index in
            guard snapshot.windows[index].processID == pid,
                  let sourceFrame = source.sourceRect(fromGlobal: windowBounds, bounds: crop) else { return false }
            let candidate = snapshot.windows[index].frame
            return abs(candidate.minX - sourceFrame.minX) < 2 && abs(candidate.minY - sourceFrame.minY) < 2 &&
                abs(candidate.width - sourceFrame.width) < 2 && abs(candidate.height - sourceFrame.height) < 2
        }
        // Ambiguous AX↔CG window correspondence stays unknown, not guessed.
        guard matches.count == 1, let matched = matches.first else { return snapshot }
        let windowID = snapshot.windows[matched].id
        snapshot.focusedProcessID = pid
        snapshot.focusedWindowID = windowID
        for index in snapshot.windows.indices { snapshot.windows[index].isFocused = index == matched }
        snapshot.windows[matched].documentURL = documentURL(focusedWindow, budget: budget)
        var roots = [(focusedWindow, Optional(windowID))]
        if let menuBar = element(budget.attribute(focusedApplication, kAXMenuBarAttribute)) { roots.append((menuBar, nil)) }
        let controls = collectElements(roots: roots, pid: pid, source: source, crop: crop, budget: budget)
        snapshot.elements = controls.elements
        snapshot.availability.accessibilityCollected = true
        snapshot.accessibilityAge = 0
        snapshot.availability.truncated = snapshot.availability.truncated || controls.truncated
        return snapshot
    }

    private struct Pending {
        var element: AXUIElement
        var parentID: String?
        var windowID: UInt32?
        var depth: Int
        var clip: CGRect
        var parentRole: String?
        var openMenu: Bool
    }

    private static func collectElements(roots: [(AXUIElement, UInt32?)], pid: pid_t,
                                        source: RecordedSceneSource, crop: CGRect, budget: AXBudget)
        -> (elements: [RecordedSceneElement], truncated: Bool) {
        var queue = roots.map { Pending(element: $0.0, windowID: $0.1, depth: 0, clip: crop, openMenu: false) }
        var result: [RecordedSceneElement] = []
        var visited = Set<String>()
        var cursor = 0
        while cursor < queue.count, result.count < 128, !budget.expired {
            let pending = queue[cursor]
            cursor += 1
            let id = "\(pid):\(pending.windowID ?? 0):\(CFHash(pending.element))"
            guard visited.insert(id).inserted,
                  let role = budget.attribute(pending.element, kAXRoleAttribute) as? String,
                  budget.attribute(pending.element, "AXHidden") as? Bool != true,
                  let bounds = frame(pending.element, budget: budget), bounds.intersects(pending.clip),
                  let sourceFrame = source.sourceRect(fromGlobal: bounds, bounds: crop) else { continue }
            let subrole = budget.attribute(pending.element, kAXSubroleAttribute) as? String
            let selected = budget.attribute(pending.element, kAXSelectedAttribute) as? Bool
            let expanded = budget.attribute(pending.element, kAXExpandedAttribute) as? Bool
            let isMenu = role.hasPrefix("AXMenu")
            let isTab = role == "AXTab" || subrole == "AXTabButton" ||
                (pending.parentRole == "AXTabGroup" && role == "AXRadioButton")
            // No value, selected text, help text, URL history or editable text
            // is requested. Secure/editable controls keep only role/geometry.
            let redacted = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role) ||
                subrole == "AXSecureTextField"
            let label = redacted ? nil : limited((budget.attribute(pending.element, kAXTitleAttribute) as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? (budget.attribute(pending.element, kAXDescriptionAttribute) as? String), 512)
            if role == "AXMenu" && !pending.openMenu && budget.attribute(pending.element, "AXVisible") as? Bool != true { continue }
            result.append(.init(id: id, parentID: pending.parentID, processID: pid, windowID: pending.windowID,
                role: String(role.prefix(100)), subrole: limited(subrole, 100), label: label, frame: sourceFrame,
                isEnabled: budget.attribute(pending.element, kAXEnabledAttribute) as? Bool,
                isFocused: budget.attribute(pending.element, kAXFocusedAttribute) as? Bool,
                isSelected: selected, isExpanded: expanded, isMenu: isMenu, isTab: isTab,
                documentURL: isTab && selected == true ? documentURL(pending.element, budget: budget) : nil, textRedacted: redacted))
            guard pending.depth < 7, !redacted, !isTab || selected == true else { continue }
            // Closed menu-bar items can expose their entire hidden menus.
            // Never descend until AX explicitly identifies an open item.
            guard role != "AXMenuBarItem" || selected == true || expanded == true else { continue }
            let menuOpen = pending.openMenu || (role == "AXMenuBarItem" && (selected == true || expanded == true))
            let children = children(pending.element, key: role == "AXMenu" ? "AXVisibleChildren" : kAXChildrenAttribute,
                                    maximum: max(0, 128 - queue.count), budget: budget)
            let clip = isMenu ? crop : bounds.intersection(pending.clip)
            queue += children.map { Pending(element: $0, parentID: id, windowID: pending.windowID,
                depth: pending.depth + 1, clip: clip, parentRole: role, openMenu: menuOpen) }
        }
        return (result, budget.expired || cursor < queue.count || queue.count >= 128)
    }

    private static func number(_ row: [String: Any], _ key: CFString) -> NSNumber? { row[key as String] as? NSNumber }
    private static func bounds(_ row: [String: Any]) -> CGRect? {
        guard let value = row[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: value as CFDictionary), RecordedSceneSource.valid(rect) else { return nil }
        return rect
    }
    private static func limited(_ value: String?, _ count: Int) -> String? { value.map { String($0.prefix(count)) } }
    private struct AXBudget {
        let deadline: Double
        var expired: Bool { ProcessInfo.processInfo.systemUptime >= deadline }
        func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.005, remaining)))
            return true
        }
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard prepare(element) else { return nil }
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
    }
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func frame(_ element: AXUIElement, budget: AXBudget) -> CGRect? {
        guard let position = budget.attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = budget.attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeDowncast(position, to: AXValue.self)
        let sizeValue = unsafeDowncast(size, to: AXValue.self)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        let rect = CGRect(origin: point, size: dimensions)
        return RecordedSceneSource.valid(rect) ? rect : nil
    }
    private static func children(_ element: AXUIElement, key: String, maximum: Int, budget: AXBudget) -> [AXUIElement] {
        guard maximum > 0, budget.prepare(element) else { return [] }
        var count = 0
        guard AXUIElementGetAttributeValueCount(element, key as CFString, &count) == .success, count > 0 else { return [] }
        guard budget.prepare(element) else { return [] }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, key as CFString, 0, min(count, maximum), &values) == .success else { return [] }
        return (values as? [AXUIElement]) ?? []
    }
    private static func documentURL(_ element: AXUIElement, budget: AXBudget) -> String? {
        for key in ["AXDocument", "AXURL"] {
            let attribute = budget.attribute(element, key)
            if let raw = attribute as? String, let value = RecordedScene.sanitizedURL(raw) { return value }
            if let url = attribute as? URL, let value = RecordedScene.sanitizedURL(url.absoluteString) { return value }
        }
        return nil
    }
}

struct RecordedSceneSamplingPolicy {
    static let fallbackInterval = 1.0
    static let accessibilityRefreshInterval = 10.0
    static let eventCoalescingInterval = 0.25

    static func refreshAccessibility(now: Double, lastRefresh: Double?, dirty: Bool, windowFactsChanged: Bool) -> Bool {
        guard let lastRefresh else { return true }
        return dirty || windowFactsChanged || now - lastRefresh >= accessibilityRefreshInterval
    }
}

private final class RecordedSceneDirtySignal: @unchecked Sendable {
    let changed: @Sendable () -> Void
    init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
}

private final class RecordedSceneAXResources: @unchecked Sendable {
    let observer: AXObserver
    let signal: RecordedSceneDirtySignal
    let registrations: [(AXUIElement, CFString)]
    init(observer: AXObserver, signal: RecordedSceneDirtySignal, registrations: [(AXUIElement, CFString)]) {
        self.observer = observer; self.signal = signal; self.registrations = registrations
    }
}

/// AX callbacks run on the main run loop, but setup/removal IPC runs on utility
/// queues. A final main-queue barrier keeps callback refcon alive through removal.
private final class RecordedSceneAXWatch: @unchecked Sendable {
    private let resources: RecordedSceneAXResources
    let processID: Int32
    let windowID: UInt32

    init?(processID: Int32, windowID: UInt32, changed: @escaping @Sendable () -> Void) {
        guard !MediaProcessing.isSuspended, AXIsProcessTrusted() else { return nil }
        var observer: AXObserver?
        guard AXObserverCreate(processID, { _, _, _, context in
            guard let context else { return }
            Unmanaged<RecordedSceneDirtySignal>.fromOpaque(context).takeUnretainedValue().changed()
        }, &observer) == .success, let observer else { return nil }
        let signal = RecordedSceneDirtySignal(changed)
        let application = AXUIElementCreateApplication(processID)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
        AXUIElementSetMessagingTimeout(application, 0.005)
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused)
        var elements = [application]
        if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            elements.append(unsafeDowncast(focused, to: AXUIElement.self))
        }
        let notifications = [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
            kAXWindowCreatedNotification, kAXMovedNotification, kAXResizedNotification,
            kAXTitleChangedNotification, kAXMenuOpenedNotification, kAXMenuClosedNotification,
            kAXSelectedChildrenChangedNotification, kAXLayoutChangedNotification]
        var registrations: [(AXUIElement, CFString)] = []
        for element in elements {
            AXUIElementSetMessagingTimeout(element, 0.005)
            for name in notifications {
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                let key = name as CFString
                if AXObserverAddNotification(observer, element, key, Unmanaged.passUnretained(signal).toOpaque()) == .success {
                    registrations.append((element, key))
                }
            }
        }
        self.processID = processID; self.windowID = windowID
        let resources = RecordedSceneAXResources(observer: observer, signal: signal, registrations: registrations)
        self.resources = resources
        // CoreFoundation run-loop source registration is thread-safe. Finish
        // the add before publishing this owner so cancellation cannot remove a
        // not-yet-added source and then accidentally add it afterward.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(resources.observer), .commonModes)
    }

    deinit {
        let resources = resources
        DispatchQueue.global(qos: .utility).async {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(resources.observer), .commonModes)
            for (element, name) in resources.registrations {
                AXObserverRemoveNotification(resources.observer, element, name)
            }
            DispatchQueue.main.async { withExtendedLifetime(resources) {} }
        }
    }
}

/// Sampling never touches the screen/video pipeline. Its lock covers only the
/// bounded in-memory archive; slow accessibility queries cannot block Stop.
final class RecordedSceneSampler: @unchecked Sendable {
    typealias Collector = @Sendable (RecordedSceneSource, Bool) throws -> RecordedSceneSnapshot
    private let queue = DispatchQueue(label: "framethrower.recorded-scene", qos: .utility)
    private let lock = NSLock()
    private let injectedCollector: Collector?
    private var timer: (any DispatchSourceTimer)?
    private var builder: RecordedSceneBuilder?
    private var generation = UUID()
    private var active = false
    private var collecting = false
    private var dirtyRevision = 0
    private var sampledRevision = -1
    private var pendingEvent = false
    private var lastSampleHostTime: Double?
    private var lastAccessibilityHostTime: Double?
    private var previous: RecordedSceneSnapshot?
    private var axWatch: RecordedSceneAXWatch?
    private var workspaceObservers: [any NSObjectProtocol] = []

    /// The injected path is for pure metadata fixtures. It never registers
    /// workspace/AX observers or invokes the native collector.
    init(collector: Collector? = nil) { injectedCollector = collector }

    @discardableResult
    func start(source: RecordedSceneSource) -> Bool {
        guard (injectedCollector != nil || !MediaProcessing.isSuspended), (try? source.validate()) != nil else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return false }
        let token = UUID()
        generation = token
        active = true
        collecting = false
        builder = RecordedSceneBuilder(source: source)
        dirtyRevision = 0; sampledRevision = -1; pendingEvent = false
        lastSampleHostTime = nil; lastAccessibilityHostTime = nil; previous = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sample(source: source, token: token) }
        self.timer = timer
        timer.resume()
        if injectedCollector == nil {
            queue.async { [weak self] in self?.installWorkspaceObservers(source: source, token: token) }
        }
        return true
    }

    func stopCollecting() {
        lock.lock()
        active = false
        if collecting { builder?.noteGap() }
        timer?.cancel()
        timer = nil
        axWatch = nil
        let observers = workspaceObservers
        workspaceObservers = []
        lock.unlock()
        if !observers.isEmpty {
            // This cleanup may wait behind an in-flight metadata query. Stop
            // itself never waits for that queue or the application's AX server.
            let holder = RecordedSceneObserverTokens(observers)
            queue.async { for observer in holder.values { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
        }
    }

    func cancel() {
        stopCollecting()
        lock.lock()
        builder = nil
        generation = UUID()
        lock.unlock()
    }

    func finish(screenStartHostTime: Double, duration: Double, firstFrameSourceTime: Double = 0,
                timeout: Double = 3) async throws -> RecordedScene? {
        stopCollecting()
        let captured = takeBuilder()
        guard let captured, !captured.isEmpty else { return nil }
        return try await RecordedSceneWork.run(timeout: timeout) {
            try captured.recording(screenStartHostTime: screenStartHostTime,
                duration: duration, firstFrameSourceTime: firstFrameSourceTime)
        }
    }

    private func takeBuilder() -> RecordedSceneBuilder? {
        lock.lock(); defer { lock.unlock() }
        let captured = builder
        builder = nil
        return captured
    }

    private func sample(source: RecordedSceneSource, token: UUID) {
        lock.lock()
        let shouldCollect = active && generation == token && builder?.isFull == false
        let revision = dirtyRevision
        let dirty = revision != sampledRevision
        let previous = previous
        let lastAX = lastAccessibilityHostTime
        if shouldCollect { collecting = true }
        lock.unlock()
        guard shouldCollect, injectedCollector != nil || !MediaProcessing.isSuspended else { return }
        defer {
            lock.lock()
            if generation == token { collecting = false }
            lock.unlock()
        }
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        guard var snapshot = try? collect(source: source, deep: false) else { noteGap(token: token); return }
        let changed = previous.map { Self.windowFacts($0) != Self.windowFacts(snapshot) || $0.sourceBounds != snapshot.sourceBounds ||
            $0.availability.accessibilityTrusted != snapshot.availability.accessibilityTrusted } ?? true
        let deep = RecordedSceneSamplingPolicy.refreshAccessibility(now: hostTime, lastRefresh: lastAX,
                                                                  dirty: dirty, windowFactsChanged: changed)
        if deep {
            guard let collected = try? collect(source: source, deep: true) else { noteGap(token: token); return }
            snapshot = collected
        } else if let previous {
            snapshot.elements = previous.elements
            snapshot.focusedProcessID = previous.focusedProcessID
            snapshot.focusedWindowID = previous.focusedWindowID
            snapshot.availability.accessibilityCollected = previous.availability.accessibilityCollected
            snapshot.availability.truncated = snapshot.availability.truncated || previous.availability.truncated
            snapshot.accessibilityAge = lastAX.map { max(0, hostTime - $0) }
            for index in snapshot.windows.indices {
                if let old = previous.windows.first(where: { $0.id == snapshot.windows[index].id }) {
                    snapshot.windows[index].isFocused = old.isFocused
                    snapshot.windows[index].documentURL = old.documentURL
                }
            }
        }
        snapshot.observationDuration = max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - hostTime)
        guard snapshot.observationDuration <= 5 else {
            lock.lock(); if active && generation == token { builder?.noteGap() }; lock.unlock()
            return
        }
        var newWatch: RecordedSceneAXWatch?
        lock.lock()
        let needsWatch = injectedCollector == nil && active && generation == token && deep && snapshot.focusedProcessID != nil && snapshot.focusedWindowID != nil &&
            (axWatch?.processID != snapshot.focusedProcessID || axWatch?.windowID != snapshot.focusedWindowID)
        lock.unlock()
        if needsWatch, let pid = snapshot.focusedProcessID, let window = snapshot.focusedWindowID {
            newWatch = RecordedSceneAXWatch(processID: pid, windowID: window) { [weak self] in
                self?.markDirty(source: source, token: token)
            }
        }
        // Validation/encoding stay outside the buffer lock and every media
        // critical path. Only the already prepared value is appended below.
        let prepared = RecordedSceneBuilder.prepare(source: source, snapshot: snapshot)
        lock.lock()
        if active && generation == token {
            if let prepared { builder?.append(hostTime: hostTime, prepared: prepared) }
            else { builder?.noteGap() }
            self.previous = snapshot
            lastSampleHostTime = hostTime
            if deep { sampledRevision = revision; lastAccessibilityHostTime = hostTime }
            if let newWatch { axWatch = newWatch }
            else if snapshot.focusedProcessID == nil { axWatch = nil }
        }
        lock.unlock()
    }

    private func collect(source: RecordedSceneSource, deep: Bool) throws -> RecordedSceneSnapshot {
        if let injectedCollector { return try injectedCollector(source, deep) }
        return try RecordedSceneCollector.collect(source: source, includeAccessibility: deep)
    }

    private func noteGap(token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if active && generation == token { builder?.noteGap() }
    }

    private func installWorkspaceObservers(source: RecordedSceneSource, token: UUID) {
        lock.lock()
        let enabled = active && generation == token
        lock.unlock()
        guard enabled, !MediaProcessing.isSuspended else { return }
        let center = NSWorkspace.shared.notificationCenter
        let values = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                      NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.markDirty(source: source, token: token)
            }
        }
        lock.lock()
        if active && generation == token { workspaceObservers = values; lock.unlock() }
        else { lock.unlock(); for value in values { center.removeObserver(value) } }
    }

    private func markDirty(source: RecordedSceneSource, token: UUID) {
        lock.lock()
        guard active, generation == token else { lock.unlock(); return }
        dirtyRevision += 1
        guard !pendingEvent else { lock.unlock(); return }
        pendingEvent = true
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let delay = max(0.05, (lastSampleHostTime ?? now) + RecordedSceneSamplingPolicy.eventCoalescingInterval - now)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.active, self.generation == token else { self.lock.unlock(); return }
            self.pendingEvent = false
            self.lock.unlock()
            self.sample(source: source, token: token)
        }
    }

    private static func windowFacts(_ snapshot: RecordedSceneSnapshot) -> [RecordedSceneWindow] {
        snapshot.windows.map { value in
            var window = value
            window.isFocused = nil; window.documentURL = nil
            return window
        }
    }

    deinit { stopCollecting() }
}

private final class RecordedSceneObserverTokens: @unchecked Sendable {
    let values: [any NSObjectProtocol]
    init(_ values: [any NSObjectProtocol]) { self.values = values }
}

private enum RecordedSceneWork {
    static func run<Value: Sendable>(timeout: Double, operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let completion = RecordedSceneFinish<Value>(continuation)
            DispatchQueue.global(qos: .utility).async { completion.complete(Result { try operation() }) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, min(5, timeout))) {
                completion.complete(.failure(RecordedSceneError.unavailable))
            }
        }
    }
}

private final class RecordedSceneFinish<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    func complete(_ result: Result<Value, any Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}
