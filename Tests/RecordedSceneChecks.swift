import Foundation

@main
@MainActor
struct RecordedSceneChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        guard MediaProcessing.isSuspended else { throw Failure.failed("Requires the media interlock") }
        try geometry()
        try chronologyAndTabs()
        try validationAndFiles()
        try samplingAndSizeBudgets()
        try await suspendedCollector()
        try await slowCollectorDoesNotBlockRecording()
        try projectMetadata()
        print("Recorded scene checks passed (source-pixel coordinates, capture-clock alignment, recorded-only lookup, focus/tab/menu events, privacy/schema guards, exclusive sidecar publication and suspended native collector; no desktop queries/media activity).")
    }

    static var source: RecordedSceneSource {
        .init(kind: .area, displayID: 7, globalBounds: CGRect(x: -1200, y: 150, width: 500, height: 300),
              pixelWidth: 1000, pixelHeight: 600)
    }

    static func observation(title: String = "Document", selectedTab: Int = 1) -> RecordedSceneSnapshot {
        let window = RecordedSceneWindow(id: 42, processID: 123, application: "Browser", bundleID: "org.example.browser",
            title: title, documentURL: "https://example.test/page", frame: CGRect(x: 100, y: 100, width: 600, height: 400),
            zOrder: 1, isFocused: true, isRecorderApplication: false, occlusionEstimate: 0.25)
        let root = RecordedSceneElement(id: "window", processID: 123, windowID: 42, role: "AXWindow", label: title,
            frame: window.frame, isFocused: true, isMenu: false, textRedacted: false)
        let tab1 = RecordedSceneElement(id: "tab-1", parentID: root.id, processID: 123, windowID: 42,
            role: "AXRadioButton", subrole: "AXTabButton", label: "First tab", frame: CGRect(x: 120, y: 110, width: 150, height: 30),
            isSelected: selectedTab == 1, isMenu: false, isTab: true,
            documentURL: selectedTab == 1 ? "https://example.test/first" : nil, textRedacted: false)
        let tab2 = RecordedSceneElement(id: "tab-2", parentID: root.id, processID: 123, windowID: 42,
            role: "AXRadioButton", subrole: "AXTabButton", label: "Second tab", frame: CGRect(x: 270, y: 110, width: 150, height: 30),
            isSelected: selectedTab == 2, isMenu: false, isTab: true,
            documentURL: selectedTab == 2 ? "https://example.test/second" : nil, textRedacted: false)
        let secure = RecordedSceneElement(id: "secure", parentID: root.id, processID: 123, windowID: 42,
            role: "AXTextField", subrole: "AXSecureTextField", frame: CGRect(x: 200, y: 200, width: 150, height: 30),
            isEnabled: true, isMenu: false, textRedacted: true)
        return .init(time: 0, sourceBounds: source.globalBounds,
            availability: .init(windows: true, accessibilityTrusted: true, accessibilityCollected: true),
            focusedProcessID: 123, focusedWindowID: 42, windows: [window], elements: [root, tab1, tab2, secure])
    }

    static func geometry() throws {
        try require(source.sourceRect(fromGlobal: CGRect(x: -1150, y: 200, width: 200, height: 100)) ==
                    CGRect(x: 100, y: 100, width: 400, height: 200),
                    "Retina area capture on a negative-origin display must map exact Quartz points into original source pixels")
        let windowSource = RecordedSceneSource(kind: .window, windowID: 42, processID: 123,
            globalBounds: CGRect(x: 100, y: 200, width: 400, height: 300), pixelWidth: 800, pixelHeight: 600)
        let moved = CGRect(x: -500, y: 50, width: 400, height: 300)
        try require(windowSource.sourceRect(fromGlobal: moved, bounds: moved) == CGRect(x: 0, y: 0, width: 800, height: 600),
                    "Moving an isolated captured window must not shift its own source coordinates")
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let overlap = RecordedScene.occlusion(of: frame,
            by: [CGRect(x: 0, y: 0, width: 60, height: 100), CGRect(x: 40, y: 0, width: 60, height: 100)], crop: frame)
        try require(overlap == 1, "Overlapping occluders must be unioned rather than counted twice")
        try require(RecordedScene.occlusion(of: frame, by: [CGRect(x: 0, y: 0, width: 25, height: 100)],
            crop: CGRect(x: 0, y: 0, width: 50, height: 100)) == 0.5,
                    "Occlusion estimates must use only the portion inside the captured crop")
        try require(RecordedScene.sanitizedURL("https://user:password@example.test/path?token=secret#private") ==
                    "https://example.test/path" && RecordedScene.sanitizedURL("javascript:alert(1)") == nil,
                    "Recorded document URLs must remove credentials/query/fragment and reject non-document schemes")
    }

    static func chronologyAndTabs() throws {
        var builder = RecordedSceneBuilder(source: source)
        var initial = observation()
        initial.accessibilityAge = 0.125
        builder.append(hostTime: 99.6, snapshot: initial)
        var next = observation(selectedTab: 2)
        next.windows[0].frame.origin.x += 20
        next.elements[0].frame.origin.x += 20
        let menu = RecordedSceneElement(id: "menu", processID: 123, role: "AXMenuItem", label: "File",
            frame: CGRect(x: 5, y: 5, width: 80, height: 24), isEnabled: true, isMenu: true, textRedacted: false)
        next.elements.append(menu)
        builder.append(hostTime: 99.9, snapshot: next)
        // A delayed/duplicate observation cannot reorder captured evidence.
        builder.append(hostTime: 99.7, snapshot: observation(title: "Wrong late state"))
        builder.append(hostTime: 99.9, snapshot: observation(title: "Wrong duplicate"))
        var final = next
        final.focusedWindowID = nil
        final.focusedProcessID = nil
        builder.append(hostTime: 100.3, snapshot: final)
        let scene = try builder.recording(screenStartHostTime: 100, duration: 3, firstFrameSourceTime: 0.2)
        try require(scene.snapshots.count == 3 && scene.snapshots[0].time == 0 &&
                    abs(scene.snapshots[1].time - 0.1) < 0.000001 && abs(scene.snapshots[2].time - 0.5) < 0.000001,
                    "Scene timestamps must share the screen/cursor capture clock including a nonzero first video PTS")
        try require(abs((scene.snapshots[0].observationAgeOffset ?? -1) - 0.2) < 0.000001 &&
                    scene.snapshots[0].accessibilityAge == 0.125 &&
                    abs((scene.snapshot(at: 0.05)?.accessibilityAge ?? -1) - 0.175) < 0.000001,
                    "Clamping pre-roll evidence to source0 must preserve its original age separately without double-counting AX age")
        let events = Set(scene.snapshots[1].events.map(\.kind))
        try require(events.contains(.windowMoved) && events.contains(.menusChanged) && events.contains(.tabChanged) &&
                    scene.snapshots[2].events.contains(where: { $0.kind == .focusChanged }),
                    "The archive must describe observed window, visible menu, tab and focus transitions")
        try require(scene.snapshot(at: 0.05)?.windows[0].title == "Document" &&
                    scene.snapshot(at: 0.2)?.elements.first(where: { $0.id == "tab-2" })?.isSelected == true &&
                    scene.snapshot(at: 0.2)?.time == scene.snapshots[1].time &&
                    scene.snapshot(at: -1) == nil && scene.snapshot(at: 4) == nil && scene.snapshot(at: .nan) == nil,
                    "Lookup must return only prior recorded evidence, retaining observation age and never consulting the current desktop")
        var late = RecordedSceneBuilder(source: source)
        late.append(hostTime: 101, snapshot: initial)
        try require(try late.recording(screenStartHostTime: 100, duration: 3).snapshot(at: 0) == nil,
                    "A capture without an initial observation must not invent earlier UI state")
    }

    static func validationAndFiles() throws {
        var scene = RecordedScene(duration: 3, source: source, snapshots: [observation()])
        try scene.validate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scene-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.scene.json")
        try scene.write(to: url)
        try require(try RecordedScene.load(from: url) == scene, "Scene source metadata must round-trip without losing tab/window identity")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try require(permissions?.intValue == 0o600, "Recorded semantic metadata must be owner-readable only")
        let bytes = try Data(contentsOf: url)
        try expectFailure { try scene.write(to: url) }
        try require(try Data(contentsOf: url) == bytes, "Exclusive publication must preserve an existing sidecar")
        let bad = directory.appendingPathComponent("corrupt.json")
        try Data("{\"not\":\"a scene\"}".utf8).write(to: bad)
        try expectFailure { _ = try RecordedScene.load(from: bad) }
        scene.snapshots[0].elements[3].label = "typed password must never persist"
        try expectFailure { try scene.validate() }
        scene.snapshots[0] = observation()
        scene.snapshots[0].elements[1].documentURL = "https://example.test/path?secret=1"
        try expectFailure { try scene.validate() }
        scene.snapshots[0] = observation()
        scene.snapshots[0].elements[1].isSelected = false
        try expectFailure { try scene.validate() }
        scene.snapshots[0] = observation()
        scene.snapshots[0].elements[0].parentID = "tab-1"
        try expectFailure { try scene.validate() }
        scene.snapshots = [observation(), observation()]
        try expectFailure { try scene.validate() }
        var invalid = RecordedSceneBuilder(source: source)
        var duplicate = observation()
        duplicate.windows.append(duplicate.windows[0])
        invalid.append(hostTime: 1, snapshot: duplicate)
        try expectFailure { _ = try invalid.recording(screenStartHostTime: 1, duration: 3) }
    }

    static func suspendedCollector() async throws {
        try expectFailure { _ = try RecordedSceneCollector.collect(source: source) }
        let sampler = RecordedSceneSampler()
        try require(!sampler.start(source: source), "The interlock must reject sampling before any CG/AX/desktop query")
        let result = try await sampler.finish(screenStartHostTime: 0, duration: 1)
        try require(result == nil,
                    "A suspended collector must not create inferred scene evidence or a timer")
    }

    final class SlowProbe: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }

    static func slowCollectorDoesNotBlockRecording() async throws {
        let probe = SlowProbe()
        let snapshot = observation()
        let sampler = RecordedSceneSampler(collector: { _, _ in
            probe.entered.signal()
            _ = probe.release.wait(timeout: .now() + 3)
            return snapshot
        })
        defer { probe.release.signal(); sampler.cancel() }
        let started = ContinuousClock.now
        try require(sampler.start(source: source), "A fake metadata sampler must start without touching native APIs")
        try require(started.duration(to: .now) < .milliseconds(300),
                    "Metadata startup must return immediately instead of waiting for the collector")
        try require(probe.entered.wait(timeout: .now() + 1) == .success, "The injected slow collector must actually be in flight")
        let stopped = ContinuousClock.now
        sampler.stopCollecting()
        try require(stopped.duration(to: .now) < .milliseconds(300),
                    "Metadata Stop must never wait for an unresponsive AX/CG server")
        let finished = ContinuousClock.now
        let result = try await sampler.finish(screenStartHostTime: 0, duration: 1, timeout: 0.1)
        try require(result == nil && finished.duration(to: .now) < .milliseconds(300),
                    "Finalization must use only the immutable buffer and not wait behind an in-flight native query")
        probe.release.signal()
        try await Task.sleep(for: .milliseconds(50))
        let late = try await sampler.finish(screenStartHostTime: 0, duration: 1)
        try require(late == nil, "A late collector completion after Stop must not publish new source evidence")
    }

    static func samplingAndSizeBudgets() throws {
        var last: Double?
        var refreshes: [Int] = []
        for second in 0...10 {
            if RecordedSceneSamplingPolicy.refreshAccessibility(now: Double(second), lastRefresh: last,
                                                               dirty: false, windowFactsChanged: false) {
                refreshes.append(second); last = Double(second)
            }
        }
        try require(refreshes == [0, 10] &&
            RecordedSceneSamplingPolicy.refreshAccessibility(now: 10.5, lastRefresh: last, dirty: true, windowFactsChanged: false) &&
            RecordedSceneSamplingPolicy.refreshAccessibility(now: 10.5, lastRefresh: last, dirty: false, windowFactsChanged: true),
            "Unchanged one-second window fallbacks must not repeatedly crawl AX; real notifications/window changes refresh it")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let small = observation()
        let smallBytes = try encoder.encode(small).count
        var limited = RecordedSceneBuilder(source: source, byteLimit: smallBytes + 32)
        limited.append(hostTime: 0, snapshot: small)
        limited.append(hostTime: 1, snapshot: observation(title: "A changed window"))
        let bounded = try limited.recording(screenStartHostTime: 0, duration: 3)
        try require(limited.isFull && bounded.snapshots.count == 1 && bounded.snapshots[0].availability.truncated,
                    "Reaching the live byte budget must retain valid earlier evidence, explicitly mark truncation and stop deeper collection")
        var unchanged = RecordedSceneBuilder(source: source)
        for second in 0...30 {
            var value = small
            value.accessibilityAge = Double(second % 10)
            value.observationDuration = Double(second % 3) * 0.001
            unchanged.append(hostTime: Double(second), snapshot: value)
        }
        let compact = try unchanged.recording(screenStartHostTime: 0, duration: 31)
        try require(compact.snapshots.map(\.time) == [0, 10, 20, 30],
                    "Unchanged one-second observations must coalesce, retaining only bounded ten-second freshness observations")
        var gap = RecordedSceneBuilder(source: source)
        gap.noteGap()
        gap.append(hostTime: 1, snapshot: small)
        let partial = try gap.recording(screenStartHostTime: 0, duration: 3)
        try require(partial.snapshots[0].time == 1 && partial.snapshots[0].availability.truncated &&
                    partial.snapshots[0].events.contains(where: { $0.kind == .metadataGap }),
                    "A metadata gap before the first late observation must remain explicit, without inventing initial state")
        var typical = small
        typical.windows = (0..<5).map { index in
            var window = small.windows[0]; window.id = UInt32(42 + index)
            window.title = "Document \(index) — application window"; window.zOrder = index
            return window
        }
        typical.elements = (0..<32).map { index in
            var node = small.elements[0]; node.id = "control-\(index)"; node.parentID = nil
            node.role = "AXButton"; node.label = "Visible control \(index)"; return node
        }
        var dense = typical
        dense.windows = (0..<128).map { index in
            var window = small.windows[0]; window.id = UInt32(42 + index); window.zOrder = index
            window.title = String(repeating: "Window title ", count: 10); return window
        }
        dense.elements = (0..<128).map { index in
            var node = typical.elements[0]; node.id = "control-\(index)"
            node.label = String(repeating: "Visible control label ", count: 10); return node
        }
        try RecordedScene(duration: 1, source: source, snapshots: [typical]).validate()
        try RecordedScene(duration: 1, source: source, snapshots: [dense]).validate()
        print("Scene snapshot JSON bytes: small=\(smallBytes), typical5windows32controls=\(try encoder.encode(typical).count), dense128windows128controls=\(try encoder.encode(dense).count). Archive hard cap=\(RecordedScene.maximumBytes), live budget=\(RecordedScene.maximumBytes - 1_000_000), max snapshots=\(RecordedScene.maximumSnapshots).")
    }

    static func projectMetadata() throws {
        var project = RecordingProject(screenFilename: "source.mov", sceneFilename: "source.scene.json", duration: 3)
        try project.validate()
        let encoded = try JSONEncoder().encode(project)
        try require(try JSONDecoder().decode(RecordingProject.self, from: encoded).sceneFilename == "source.scene.json",
                    "The immutable scene sidecar reference must persist alongside the original recording")
        var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        old.removeValue(forKey: "sceneFilename")
        let legacy = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: old))
        try require(legacy.sceneFilename == nil, "Older projects must open without synthesizing current desktop metadata")
        for filename in ["../private.json", "source.mov", "", "/absolute.json"] {
            project.sceneFilename = filename
            try expectFailure { try project.validate() }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        project.sceneFilename = "take copy.framethrower"
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("take.framethrower"))
        try require(editor.save(), "Save the metadata-only project fixture")
        guard let copy = editor.duplicate() else { throw Failure.failed("Duplicate fixture project") }
        try require(copy.url.lastPathComponent == "take copy 2.framethrower" && copy.project.sceneFilename == project.sceneFilename,
                    "Duplicate must share the immutable scene evidence while reserving its filename even when missing")
        var conflict = project
        conflict.sceneFilename = "guard.framethrower.recovery"
        let sentinel = Data("original semantic source".utf8)
        let sidecar = directory.appendingPathComponent(conflict.sceneFilename!)
        try sentinel.write(to: sidecar)
        let protected = ProjectEditor(project: conflict, url: directory.appendingPathComponent("guard.framethrower"))
        var changed = protected.project.state
        changed.trimStart = 0.5
        try require(protected.updateDraft(changed, at: 1) && !protected.flushRecovery() &&
                    protected.draftState == changed && (try Data(contentsOf: sidecar)) == sentinel,
                    "Recovery must retain the edit in memory while refusing to overwrite scene source metadata")
    }

    static func expectFailure(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure.failed("Expected invalid/missing metadata to be rejected")
    }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
}
