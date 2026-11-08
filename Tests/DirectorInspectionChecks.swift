import Foundation

private enum InspectionCheckError: Error { case failed(String) }

@main
@MainActor
struct DirectorInspectionChecks {
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "media interlock remains enabled")
        try checkParserAndGeometry()
        try await checkRecordedOnlyAndAtomicProposal()
        try await checkLazyAndBounds()
        try await checkFrameCapabilityAndAssociations()
        try await checkTargetedLookup()
        try await measurePayloads()
        try require(MediaProcessing.isSuspended, "inspection cannot change media interlock")
        print("Director inspection checks passed (recorded-only observations, lazy metadata, strict scope, bounded projections, original-pixel fitting, synthetic native-image associations, and atomic Undo).")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw InspectionCheckError.failed(message) }
    }
    private static func rejects(_ body: () throws -> Void, _ message: String) throws {
        do { try body() } catch is DirectorInspectionError { return } catch is EditorCommandError { return }
        throw InspectionCheckError.failed(message)
    }
    private static func rejectsAsync(_ body: () async throws -> Void, _ message: String) async throws {
        do { try await body() } catch is DirectorInspectionError { return } catch is EditorCommandError { return }
        throw InspectionCheckError.failed(message)
    }
    private static func json(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InspectionCheckError.failed("JSON result") }
        return result
    }
    private static func observation(_ outcome: DirectorInspectionOutcome) throws -> DirectorInspectionObservation {
        guard case let .observation(value) = outcome else { throw InspectionCheckError.failed("expected observation") }
        return value
    }
    private static func proposal(_ outcome: DirectorInspectionOutcome) throws -> EditorCommandBatch {
        guard case let .proposal(value, _) = outcome else { throw InspectionCheckError.failed("expected proposal") }
        return value
    }

    private static func fixture(dense: Bool = false) -> RecordedScene {
        let source = RecordedSceneSource(kind: .display, globalBounds: CGRect(x: -100, y: 0, width: 960, height: 540), pixelWidth: 1920, pixelHeight: 1080)
        let windows = (1...(dense ? 128 : 3)).map { number in
            RecordedSceneWindow(id: UInt32(number), processID: 100, application: dense ? String(repeating: "界", count: 256) : "Browser",
                bundleID: "test.browser", title: dense ? String(repeating: "🦊", count: 512) : "Document \(number)",
                documentURL: "https://example.test/document/" + String(repeating: "a", count: dense ? 400 : 4),
                frame: CGRect(x: 100 + number * 10, y: 100, width: 800, height: 500), zOrder: number - 1,
                isFocused: number == 1, isRecorderApplication: false, occlusionEstimate: number == 1 ? 0 : 0.3)
        }
        let elements = (1...(dense ? 128 : 4)).map { number in
            RecordedSceneElement(id: "control-\(number)", parentID: nil, processID: 100, windowID: 1,
                role: "AXButton", subrole: nil, label: dense ? String(repeating: "界", count: 512) : "Button \(number)",
                frame: CGRect(x: 110 + number * 10, y: 120, width: 80, height: 40), isEnabled: true,
                isFocused: nil, isSelected: nil, isExpanded: nil, isMenu: false, textRedacted: false)
        }
        var first = RecordedSceneSnapshot(time: 0, accessibilityAge: 0.25, observationDuration: 0.012,
            sourceBounds: source.globalBounds, availability: .init(windows: true, accessibilityTrusted: true, accessibilityCollected: true),
            windows: windows, elements: elements)
        var later = first
        later.time = 3
        later.windows[0].frame.origin.x = 1000
        later.windows[0].title = "FUTURE WINDOW"
        first.events = []
        return RecordedScene(duration: 12, source: source, snapshots: [first, later])
    }

    private static func context(_ project: RecordingProject, id: UUID) throws -> EditorCommandContext {
        EditorCommandContext(projectID: id, revision: try EditorCommandDispatcher.revision(for: project), duration: project.duration, state: project.state)
    }
    private static func sceneAction(_ context: EditorCommandContext, time: Double = 2, detail: DirectorSceneInspectionRequest.Detail = .windows, limit: Int = 8) -> DirectorInspectionAction {
        .scene(.init(projectID: context.projectID, revision: context.revision, sourceTime: time, detail: detail,
            windowID: detail == .controls ? 1 : nil, limit: limit))
    }

    private static func checkParserAndGeometry() throws {
        let project = RecordingProject(screenFilename: "absent-screen.mov", duration: 12)
        let ctx = try context(project, id: UUID())
        let args: [String: Any] = ["version": 1, "project_id": ctx.projectID.uuidString, "expected_revision": ctx.revision,
            "time_seconds": 2, "detail": "windows", "limit": 8]
        guard case let .scene(request)? = try DirectorInspection.parse(name: "inspect_scene", args: args, context: ctx) else { throw InspectionCheckError.failed("scene parse") }
        try require(request.sourceTime == 2 && request.windowID == nil, "optional window omitted")
        for (key, value) in [("version", true as Any), ("expected_revision", "OLD"), ("project_id", UUID().uuidString),
                             ("limit", 17), ("time_seconds", Double.nan), ("extra", "unsupported")] {
            var invalid = args; invalid[key] = value
            try rejects({ _ = try DirectorInspection.parse(name: "inspect_scene", args: invalid, context: ctx) }, "invalid or stale parser values reject")
        }
        var controls = args; controls["detail"] = "controls"
        try rejects({ _ = try DirectorInspection.parse(name: "inspect_scene", args: controls, context: ctx) }, "controls require explicit window identity")
        try require(try DirectorInspection.parse(name: "unrelated_tool", args: [:], context: ctx) == nil, "unrelated parser remains composable")
        for (width, height) in [(1920, 1080), (1080, 1920), (6016, 3384)] {
            for rect in [EditorRegionRect(x: 0.2, y: 0.2, width: 0.5, height: 0.4),
                         EditorRegionRect(x: 0, y: 0, width: 0.2, height: 0.6),
                         EditorRegionRect(x: 0.8, y: 0.7, width: 0.2, height: 0.3),
                         EditorRegionRect(x: 0.4, y: 0.4, width: 0.01, height: 0.01)] {
                let fitted = try DirectorInspection.fittedRect(rect, pixelWidth: width, pixelHeight: height, marginPixels: 30)
                try require(fitted.isValid && abs(fitted.width - fitted.height) < 1e-12, "source-aspect fit remains bounded in every orientation")
                let left = max(0, rect.x - 30 / Double(width)), top = max(0, rect.y - 30 / Double(height))
                let right = min(1, rect.x + rect.width + 30 / Double(width)), bottom = min(1, rect.y + rect.height + 30 / Double(height))
                let expectedSide = max(1 / 3.0, right - left, bottom - top)
                try require(abs(fitted.width - expectedSide) < 1e-12, "viewport is the smallest supported zoom that fits the source-pixel border")
                try require(fitted.x <= left + 1e-12 && fitted.y <= top + 1e-12 && fitted.x + fitted.width >= right - 1e-12 && fitted.y + fitted.height >= bottom - 1e-12,
                            "fitting includes the original target and all available source-pixel margin")
                let viewport = EditorRegion(time: 0, rect: fitted, framingPadding: 0).framing.viewport(in: CGSize(width: 1, height: 1))
                try require(abs(viewport.minX - fitted.x) < 1e-12 && abs(viewport.width - fitted.width) < 1e-12, "padding is not applied a second time")
            }
        }
        try rejects({ _ = try DirectorInspection.fittedRect(.init(x: 0, y: 0, width: 1, height: 1), pixelWidth: 0, pixelHeight: 1080, marginPixels: 30) }, "missing source pixels reject")
        try rejects({ _ = try DirectorInspection.fittedRect(.init(x: .nan, y: 0, width: 1, height: 1), pixelWidth: 1920, pixelHeight: 1080, marginPixels: 30) }, "invalid normalized geometry rejects")
    }

    private static func checkRecordedOnlyAndAtomicProposal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Metadata.framethrower")
        let project = RecordingProject(screenFilename: "nonexistent-original.mov", duration: 12)
        try JSONEncoder().encode(project).write(to: url)
        let editor = try ProjectEditor.open(url: url), id = UUID()
        let ctx = try context(editor.project, id: id)
        let originalBytes = try Data(contentsOf: url), original = editor.project
        let cache = DirectorInspectionCache(scene: fixture())
        let observed = try observation(try await cache.perform(sceneAction(ctx), project: editor.project, projectID: id, supportsImages: false))
        let result = try json(observed.result)
        try require(observed.sourceTime == 0 && result["age_seconds"] as? Double == 2, "query uses recorded preceding observation, never future/live scene")
        try require(result["accessibility_age_seconds"] as? Double == 2.25 && result["observation_duration"] as? Double == 0.012, "cached AX age includes source sample age")
        var preRoll = fixture(); preRoll.snapshots[0].observationAgeOffset = 4
        let preRollObservation = try observation(try await DirectorInspectionCache(scene: preRoll).perform(sceneAction(ctx), project: editor.project, projectID: id, supportsImages: false))
        let preRollFields = try json(preRollObservation.result)
        try require(preRollFields["age_seconds"] as? Double == 6 && preRollFields["accessibility_age_seconds"] as? Double == 6.25, "pre-roll source-zero clamp retains age offset exactly once")
        try require(!String(decoding: observed.result, as: UTF8.self).contains("FUTURE"), "future metadata not leaked backward")
        try require(editor.project == original && editor.project.undoHistory.isEmpty && (try Data(contentsOf: url)) == originalBytes, "read-only scene query creates no edits, files or Undo")
        let framing = DirectorObservationFramingRequest(projectID: id, revision: ctx.revision, observationID: observed.id,
            target: .recorded("window:1"), marginPixels: 30, time: 4, motion: EditorCommandMotion(duration: 1))
        let batch = try proposal(try await cache.perform(.frameObservation(framing), project: editor.project, projectID: id, supportsImages: false))
        try require(editor.project == original && (try Data(contentsOf: url)) == originalBytes, "proposal alone never applies")
        try EditorCommandDispatcher.apply(batch, to: editor, projectID: id)
        try require(editor.project.undoHistory.count == 1 && editor.project.state.regions.count == 1 && editor.project.state.zoomKeyframes.count == 1, "Box and framing commit as one Undo")
        let region = editor.project.state.regions[0], zoom = editor.project.state.zoomKeyframes[0]
        try require(region.framingPadding == 0 && region.time == 0 && zoom.time == 4 && zoom.sourceRegionID == region.id, "frozen source timestamp and explicit Box connection persist")
        try require(editor.project.state.pipKeyframes == original.state.pipKeyframes, "camera remains unchanged")
        try require(editor.project.state.cursorStyle == original.state.cursorStyle, "pointer remains unchanged")
        try require(editor.project.state.audio == original.state.audio, "audio remains unchanged")
        try require(editor.undo() && editor.project.state == original.state, "one Undo removes both Box and movement")
        try require(editor.redo() && editor.project.state.regions[0].id == region.id, "Redo restores stable Box/target identity")
        try await rejectsAsync({ _ = try await cache.perform(.frameObservation(framing), project: editor.project, projectID: id, supportsImages: false) }, "changed revision cannot reuse observation")
        var foreign = framing; foreign.projectID = UUID()
        try await rejectsAsync({ _ = try await cache.perform(.frameObservation(foreign), project: original, projectID: id, supportsImages: false) }, "foreign project observation rejected")
    }

    private static func checkLazyAndBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sceneURL = directory.appendingPathComponent("scene.json")
        let cache = DirectorInspectionCache(recordedSceneURL: sceneURL)
        try require(cache.capabilities(supportsImages: true) == .init(scene: true, frame: false), "URL capability does not require synchronous archive load")
        try fixture(dense: true).write(to: sceneURL)
        let project = RecordingProject(screenFilename: "absent.mov", duration: 12), id = UUID()
        let ctx = try context(project, id: id)
        let first = try observation(try await cache.perform(sceneAction(ctx, limit: 16), project: project, projectID: id, supportsImages: false))
        let value = try json(first.result)
        try require(first.result.count <= DirectorInspection.maximumResultBytes && value["total"] as? Int == 128,
                    "dense scene projection is capped by UTF-8 bytes")
        let returned = value["returned"] as? Int ?? -1, omitted = value["omitted"] as? Int ?? -1
        try require(returned > 0 && returned <= 16 && omitted == 128 - returned && value["truncated"] as? Bool == true, "omission counts remain exact after byte clipping")
        let small = try observation(try await cache.perform(sceneAction(ctx, limit: 16), project: project, projectID: id, supportsImages: false, maximumResultBytes: 1536))
        let smallFields = try json(small.result), smallReturned = smallFields["returned"] as? Int ?? -1
        try require(small.result.count <= 1536 && smallFields["omitted"] as? Int == 128 - smallReturned, "continuation byte budget is enforced inside observation cache with exact returned IDs")
        try FileManager.default.removeItem(at: sceneURL)
        let controls = try observation(try await cache.perform(sceneAction(ctx, detail: .controls, limit: 16), project: project, projectID: id, supportsImages: false))
        try require(controls.result.count <= DirectorInspection.maximumResultBytes && (try json(controls.result))["window_id"] as? Int == 1, "lazy archive loaded once; controls stay scoped to selected recorded window")
        let unknown = DirectorObservationFramingRequest(projectID: id, revision: ctx.revision, observationID: first.id,
            target: .recorded("window:128"), marginPixels: 0, time: 4)
        try await rejectsAsync({ _ = try await cache.perform(.frameObservation(unknown), project: project, projectID: id, supportsImages: false) }, "omitted target cannot be invented by model")
        for index in 0..<8 { _ = try await cache.perform(sceneAction(ctx, time: Double(index) / 10), project: project, projectID: id, supportsImages: false) }
        var expired = unknown; expired.target = .recorded("window:1")
        try await rejectsAsync({ _ = try await cache.perform(.frameObservation(expired), project: project, projectID: id, supportsImages: false) }, "ninth observation evicts oldest stable identity")
        cache.close()
        var wrong = fixture(); wrong.duration = 11
        let wrongCache = DirectorInspectionCache(scene: wrong)
        try await rejectsAsync({ _ = try await wrongCache.perform(sceneAction(ctx), project: project, projectID: id, supportsImages: false) }, "wrong recording duration cannot supply adjacent scene evidence")
    }

    private static func checkFrameCapabilityAndAssociations() async throws {
        let project = RecordingProject(screenFilename: "never-open-original.mov", duration: 12), id = UUID()
        let ctx = try context(project, id: id)
        let action = DirectorInspectionAction.frame(.init(projectID: id, revision: ctx.revision, sourceTime: 2.125))
        let ordinary = DirectorInspectionCache()
        try require(ordinary.capabilities(supportsImages: true) == .init(scene: false, frame: false), "interlock advertises no ordinary frame provider")
        try await rejectsAsync({ _ = try await ordinary.perform(action, project: project, projectID: id, supportsImages: true) }, "suspended frame lookup never opens source media")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAGAAAAAwCAIAAABhdOiYAAAAjElEQVR4nO3YwQmAQAwAwVRiYdZpYZagFbiIIIgz5H55LffKLOtmLmbOt9/xt32BgkBBoCBQECgIFAQKAgWBgkBBoCBQECgIFOb9C8u3xg8KAgWBgkBBoCBQECgIFAQKAgWBgkBBoCBQECi4B7kHPdsXKAgUBAoCBYGCQEGgIFAQKAgUBAoCBYGCQOEA1ZYPSk/T0ZcAAAAASUVORK5CYII=")!
        let synthetic = DirectorInspectionCache(syntheticFrameProvider: { time in .init(sourceTime: time, pixelWidth: 96, pixelHeight: 48, png: png) })
        try require(synthetic.capabilities(supportsImages: false).frame == false, "Qwen remains text only even with injected fixture")
        try await rejectsAsync({ _ = try await synthetic.perform(action, project: project, projectID: id, supportsImages: false) }, "text-only model never receives a native image")
        let frame = try observation(try await synthetic.perform(action, project: project, projectID: id, supportsImages: true))
        let message = frame.imageMessage(toolCallID: "actual-inspect-call")!
        let content = message["content"] as! [[String: Any]], metadata = try json(Data((content[0]["text"] as! String).utf8))
        try require(metadata["originating_tool_call_id"] as? String == "actual-inspect-call" && metadata["frame_id"] as? String == frame.id.uuidString && metadata["source_time"] as? Double == 2.125, "native image association preserves actual call and actual source timestamp")
        try require(metadata["evidence"] as? String == "synthetic_fixture" && frame.imagePNG == png && !(String(decoding: frame.result, as: UTF8.self).contains(png.base64EncodedString())), "synthetic evidence is explicit and pixels stay out of tool text")
        let framing = DirectorObservationFramingRequest(projectID: id, revision: ctx.revision, observationID: frame.id,
            target: .imageRect(.init(x: 0.2, y: 0.2, width: 0.4, height: 0.4)), marginPixels: 2, time: 4)
        _ = try proposal(try await synthetic.perform(.frameObservation(framing), project: project, projectID: id, supportsImages: true))
        let invalid = DirectorInspectionCache(syntheticFrameProvider: { time in .init(sourceTime: time, pixelWidth: 1920, pixelHeight: 1080, png: png) })
        try await rejectsAsync({ _ = try await invalid.perform(action, project: project, projectID: id, supportsImages: true) }, "original-pixel mismatch rejected before attachment")
        let atEnd = DirectorInspectionCache(syntheticFrameProvider: { _ in .init(sourceTime: 12, pixelWidth: 96, pixelHeight: 48, png: png) })
        try await rejectsAsync({ _ = try await atEnd.perform(action, project: project, projectID: id, supportsImages: true) }, "exclusive end is not an observed source frame")
    }

    private static func measurePayloads() async throws {
        func size(_ value: Any) throws -> Int { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).count }
        for capabilities in [DirectorInspectionCapabilities(scene: false, frame: false), .init(scene: true, frame: false), .init(scene: false, frame: true), .init(scene: true, frame: true)] {
            let tools = DirectorInspection.tools(capabilities: capabilities)
            print("Inspection schema bytes scene=\(capabilities.scene) frame=\(capabilities.frame): \(try size(tools)); capability bytes: \(try JSONEncoder().encode(capabilities).count).")
            if !capabilities.scene && !capabilities.frame { try require(tools.isEmpty, "disabled inspection leaves legacy toolset unchanged") }
        }
        let project = RecordingProject(screenFilename: "absent.mov", duration: 12), id = UUID(), ctx = try context(project, id: id)
        for dense in [false, true] {
            let cache = DirectorInspectionCache(scene: fixture(dense: dense))
            for detail in [DirectorSceneInspectionRequest.Detail.windows, .controls] {
                let result = try observation(try await cache.perform(sceneAction(ctx, detail: detail, limit: 16), project: project, projectID: id, supportsImages: false)).result
                let fields = try json(result)
                print("Inspection \(dense ? "dense" : "typical") \(detail.rawValue) bytes=\(result.count), returned=\(fields["returned"]!), omitted=\(fields["omitted"]!), rough tokens~\((result.count + 3) / 4) (byte/4 estimate, not tokenizer).")
            }
            let query = dense ? "界" : "Button 1"
            let action = DirectorInspectionAction.scene(.init(projectID: id, revision: ctx.revision, sourceTime: 2, detail: .search,
                limit: 8, query: query, kind: .control))
            let result = try observation(try await cache.perform(action, project: project, projectID: id, supportsImages: false)).result
            let fields = try json(result)
            print("Inspection \(dense ? "dense" : "typical") targeted bytes=\(result.count), returned=\(fields["returned"]!), omitted=\(fields["omitted"]!), rough tokens~\((result.count + 3) / 4) (byte/4 estimate, not tokenizer).")
        }
    }

    private static func checkTargetedLookup() async throws {
        let project = RecordingProject(screenFilename: "no-media-opened.mov", duration: 12), id = UUID(), ctx = try context(project, id: id)
        var scene = fixture()
        scene.snapshots[0].windows[1].title = "File"
        scene.snapshots[0].elements += [
            RecordedSceneElement(id: "global-file", parentID: nil, processID: 100, windowID: nil, role: "AXMenuBarItem", subrole: nil,
                label: "File", frame: CGRect(x: 8, y: 4, width: 40, height: 24), isEnabled: true, isFocused: nil, isSelected: false,
                isExpanded: false, isMenu: true, textRedacted: false),
            RecordedSceneElement(id: "selected-tab", parentID: nil, processID: 100, windowID: 1, role: "AXRadioButton", subrole: "AXTabButton",
                label: "Project.swift", frame: CGRect(x: 120, y: 120, width: 160, height: 32), isEnabled: true, isFocused: nil,
                isSelected: true, isExpanded: nil, isMenu: false, isTab: true, documentURL: "https://example.test/Project.swift", textRedacted: false)]
        let cache = DirectorInspectionCache(scene: scene)
        func search(_ query: String, _ kind: DirectorSceneInspectionRequest.Kind = .any) -> DirectorInspectionAction {
            .scene(.init(projectID: id, revision: ctx.revision, sourceTime: 2, detail: .search, limit: 8, query: query, kind: kind))
        }
        let args: [String: Any] = ["version": 1, "project_id": id.uuidString, "expected_revision": ctx.revision,
            "time_seconds": 2, "query": "File", "kind": "menu", "limit": 8]
        guard case let .scene(parsed)? = try DirectorInspection.parse(name: "find_scene_targets", args: args, context: ctx) else { throw InspectionCheckError.failed("targeted parser") }
        try require(parsed.detail == .search && parsed.kind == .menu && parsed.query == "File", "target lookup stays typed and literal")
        for (key, value) in [("query", "" as Any), ("limit", 9), ("kind", "guess"), ("window_id", 1)] {
            var invalid = args; invalid[key] = value
            try rejects({ _ = try DirectorInspection.parse(name: "find_scene_targets", args: invalid, context: ctx) }, "targeted query rejects unbounded/unsupported fields")
        }
        try require(!cache.hasObservations, "read-only terminal reports require prior actual lookup")
        let menu = try observation(try await cache.perform(search("FÍLE", .menu), project: project, projectID: id, supportsImages: false))
        let fields = try json(menu.result), candidates = fields["candidates"] as! [[String: Any]]
        try require(fields["match"] as? String == "exact" && candidates.count == 1, "Unicode case/diacritic folded exact visible menu match")
        try require(candidates[0]["target_id"] as? String == "element:global-file" && candidates[0]["window_id"] == nil && candidates[0]["window_title"] == nil,
                    "global menu is reachable without inventing first-window ownership")
        try require(candidates[0]["application"] as? String == "Browser" && candidates[0]["is_menu"] as? Bool == true, "global menu retains recorded app and role evidence")
        try require(cache.hasObservations && (try cache.validatedObservation(id: menu.id, project: project, projectID: id)) == menu, "report validation returns only actual cached immutable evidence")
        try rejects({ _ = try cache.validatedObservation(id: UUID(), project: project, projectID: id) }, "invented report observation rejected")
        let batch = try proposal(try await cache.perform(.frameObservation(.init(projectID: id, revision: ctx.revision,
            observationID: menu.id, target: .recorded("element:global-file"), marginPixels: 30, time: 4)), project: project, projectID: id, supportsImages: false))
        try require(batch.commands.count == 2 && project.state.regions.isEmpty && project.undoHistory.isEmpty, "targeted File menu becomes a pure ordinary linked Box/framing proposal")
        let ambiguous = try observation(try await cache.perform(search("File"), project: project, projectID: id, supportsImages: false))
        try require((try json(ambiguous.result))["returned"] as? Int == 2, "ambiguous exact targets returned together, never silently selected")
        let tab = try observation(try await cache.perform(search("Project.swift", .tab), project: project, projectID: id, supportsImages: false))
        let row = (try json(tab.result))["candidates"] as! [[String: Any]]
        try require(row.count == 1 && row[0]["is_tab"] as? Bool == true && row[0]["subrole"] as? String == "AXTabButton" && row[0]["document_url"] as? String == "https://example.test/Project.swift", "selected tab remains distinguished from generic radio button")
        let fallback = try observation(try await cache.perform(search("Button", .control), project: project, projectID: id, supportsImages: false))
        try require((try json(fallback.result))["match"] as? String == "contains", "contains used only when no exact visible label matches")
        let none = try observation(try await cache.perform(search("Unrecorded target"), project: project, projectID: id, supportsImages: false))
        try require((try json(none.result))["returned"] as? Int == 0, "unrecorded target returns no fabricated geometry")
        try await rejectsAsync({ _ = try await cache.perform(.frameObservation(.init(projectID: id, revision: ctx.revision,
            observationID: none.id, target: .recorded("element:global-file"), marginPixels: 0, time: 4)), project: project, projectID: id, supportsImages: false) }, "empty observation cannot borrow target from another lookup")
        var changed = project; changed.title = "Changed"
        try rejects({ _ = try cache.validatedObservation(id: menu.id, project: changed, projectID: id) }, "read-only terminal report still rejects stale scope")
    }
}
