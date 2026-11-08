import Foundation

@main
@MainActor
struct ZoomModelChecks {
    static func main() throws {
        checkZoomTiming()
        checkSharedMotionAndGeometry()
        checkMotionVelocity()
        checkPIPSourceZoom()
        checkViewportBounds()
        try checkPersistenceAndMigration()
        checkValidation()
        print("Zoom model checks passed (identity defaults, eased zoom/pan, clamped viewports, cursor styling, persistent undo/redo, legacy history migration, and immutable sidecars).")
    }

    private static func checkZoomTiming() {
        var state = RecordingProject(screenFilename: "screen.mp4", duration: 10).state
        precondition(state.zoom(at: 5) == ZoomPlacement())
        precondition(state.cursorStyle == CursorStyle(visible: true, size: 1.5, smoothing: 0.4, clickHighlight: true))
        state.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2, x: 1, y: 0)]
        precondition(state.zoom(at: 1.999) == ZoomPlacement(), "First jump must preserve identity until its timestamp")
        precondition(state.zoom(at: 2) == ZoomPlacement(scale: 2, x: 0.75, y: 0.25))
        state.zoomKeyframes[0].transition = .smooth
        state.zoomKeyframes[0].duration = 1
        precondition(state.zoom(at: 1) == ZoomPlacement(), "First smooth zoom starts from implicit identity")
        expect(state.zoom(at: 1.5), ZoomPlacement(scale: 1 + 45.0 / 91, x: 0.5 + 45.0 / 364, y: 0.5 - 45.0 / 364), "First smooth zoom midpoint")
        expect(state.zoom(at: 1.25), ZoomPlacement(scale: 1 + 15.0 / 91, x: 0.5 + 15.0 / 364, y: 0.5 - 15.0 / 364), "Zoom reaches cruise speed after accelerating")
        state.zoomKeyframes[0].duration = 10
        expect(state.zoom(at: 1), ZoomPlacement(scale: 1 + 45.0 / 91, x: 0.5 + 45.0 / 364, y: 0.5 - 45.0 / 364), "Long first transition clamps to source start")
        state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 2, x: 0.25, y: 0.25, transition: .smooth)]
        expect(state.zoom(at: 0), ZoomPlacement(scale: 2, x: 0.25, y: 0.25), "Time-zero zoom applies immediately")

        state.zoomKeyframes += [
            ZoomKeyframe(time: 4, scale: 3, x: 0.8, y: 0.8, transition: .smooth, duration: 2),
            ZoomKeyframe(time: 5, scale: 1, x: 0, y: 0, transition: .smooth, duration: 10)
        ]
        expect(state.zoom(at: 2), ZoomPlacement(scale: 2, x: 0.25, y: 0.25), "Zoom holds before next transition")
        expect(state.zoom(at: 3), ZoomPlacement(scale: 2 + 45.0 / 91, x: 0.25 + 0.55 * 45 / 91, y: 0.25 + 0.55 * 45 / 91), "Smooth zoom and pan midpoint")
        expect(state.zoom(at: 4), ZoomPlacement(scale: 3, x: 0.8, y: 0.8), "Exact zoom arrival")
        expect(state.zoom(at: 4.5), ZoomPlacement(scale: 3 - 90.0 / 91, x: 0.8 - 0.3 * 45 / 91, y: 0.8 - 0.3 * 45 / 91), "Long later transition cannot start before previous point")
        expect(state.zoom(at: 5), ZoomPlacement(), "Zoom out returns to full source")
        precondition(state.zoom(at: -.infinity) == ZoomPlacement() && state.zoom(at: .nan) == ZoomPlacement())

        state.zoomKeyframes = [
            ZoomKeyframe(time: 0, scale: 2, x: 0.25, y: 0.5),
            ZoomKeyframe(time: 2, scale: 2, x: 0.75, y: 0.5, transition: .smooth, duration: 2)
        ]
        expect(state.zoom(at: 0.5), ZoomPlacement(scale: 2, x: 0.25 + 15.0 / 182, y: 0.5), "Pan uses the same eased timeline")
        expect(state.zoom(at: 1), ZoomPlacement(scale: 2, x: 0.25 + 45.0 / 182, y: 0.5), "Static zoom pans smoothly across source")
        state.zoomKeyframes[0] = ZoomKeyframe(time: 0, scale: 1, x: 0, y: 0)
        state.zoomKeyframes[1] = ZoomKeyframe(time: 2, scale: 2, x: 1, y: 1, transition: .smooth, duration: 2)
        expect(state.zoom(at: 1), ZoomPlacement(scale: 1 + 45.0 / 91, x: 0.5 + 45.0 / 364, y: 0.5 + 45.0 / 364),
               "Interpolation starts from visible clamped viewports, not invisible offscreen focal values")
    }

    private static func checkViewportBounds() {
        let source = CGSize(width: 1921, height: 1081)
        for scale in [1.0, 1.1, 1.7, 2.0, 3.0] {
            for x in [0.0, 0.5, 1.0] {
                for y in [0.0, 0.5, 1.0] {
                    let viewport = ZoomPlacement(scale: scale, x: x, y: y).viewport(in: source)
                    precondition(viewport.minX >= 0 && viewport.minY >= 0 &&
                                 viewport.maxX <= source.width && viewport.maxY <= source.height,
                                 "Zoom viewport must never expose outside-source pixels")
                    near(viewport.width, source.width / scale, "Zoom viewport width")
                    near(viewport.height, source.height / scale, "Zoom viewport height")
                }
            }
        }
        precondition(ZoomPlacement(scale: 3, x: 0, y: 0).viewport(in: .zero) == .zero)
        precondition(ZoomPlacement(scale: .nan, x: .infinity, y: .nan).clamped == ZoomPlacement())
    }

    private static func checkPIPSourceZoom() {
        let source = CGSize(width: 1000, height: 500)
        let centered = PIPCrop()
        let native = centered.rect(in: source, shape: .original, zoom: 2)
        let main = ZoomPlacement(scale: 2).viewport(in: source)
        precondition(native == main, "Native camera source zoom and main source zoom use the same viewport")
        for shape in PIPShape.allCases {
            for zoom in [1.0, 1.5, 2.0, 3.0] {
                for crop in [PIPCrop(x: 0, y: 0), PIPCrop(), PIPCrop(x: 1, y: 1)] {
                    let rect = crop.rect(in: source, shape: shape, aspectRatio: 4, zoom: zoom)
                    precondition(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= source.width && rect.maxY <= source.height)
                    let base = crop.rect(in: source, shape: shape, aspectRatio: 4)
                    near(rect.width, base.width / zoom, "Camera source zoom reduces its crop width")
                    near(rect.height, base.height / zoom, "Camera source zoom reduces its crop height")
                }
            }
        }
        let original = PIPPlacement(x: 0.2, y: 0.3, sourceZoom: 1)
        var magnified = original
        magnified.sourceZoom = 3
        precondition(original.frame(in: source, cameraAspect: 2) == magnified.frame(in: source, cameraAspect: 2),
                     "Source zoom cannot resize or move the output PIP window")
        let panned = centered.moved(by: CGSize(width: 125, height: 62.5), in: source, shape: .original, zoom: 2)
        near(panned.x, 0.75, "Magnified Original camera can pan horizontally")
        near(panned.y, 0.75, "Magnified Original camera can pan vertically")
        var state = RecordingProject(screenFilename: "screen.mp4", duration: 4).state
        state.pipKeyframes = [PIPKeyframe(time: 0, placement: PIPPlacement()),
            PIPKeyframe(time: 2, placement: PIPPlacement(sourceZoom: 3), transition: .smooth, duration: 2)]
        state.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 3, transition: .smooth, duration: 2)]
        for time in [0.0, 0.25, 0.5, 1.0, 1.75, 2] {
            let placement = state.placement(at: time)
            near(placement.sourceZoom, state.zoom(at: time).scale, "PIP and main source zoom share timing and easing")
            let pipViewport = placement.crop.rect(in: source, shape: .original, zoom: placement.sourceZoom)
            let mainViewport = state.zoom(at: time).viewport(in: source)
            near(pipViewport.minX, mainViewport.minX, "Matching camera/main viewport centers")
            near(pipViewport.width, mainViewport.width, "Matching camera/main viewport magnification")
        }
    }

    private static func checkSharedMotionAndGeometry() {
        var state = RecordingProject(screenFilename: "screen.mp4", duration: 10).state
        let initialPIP = PIPPlacement(x: 0.2, y: 0.3, scale: 0.2, shape: .rectangle,
                                      aspectRatio: 1, crop: PIPCrop(x: 0.1, y: 0.2))
        let finalPIP = PIPPlacement(x: 0.8, y: 0.7, scale: 0.4, shape: .rectangle,
                                    aspectRatio: 2, crop: PIPCrop(x: 0.9, y: 0.8))
        for transition in PIPTransition.allCases {
            for duration in [2.0, 20.0] {
                state.pipKeyframes = [PIPKeyframe(time: 0, placement: initialPIP),
                    PIPKeyframe(time: 4, placement: finalPIP, transition: transition, duration: duration)]
                state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 2, x: 0.3, y: 0.3),
                    ZoomKeyframe(time: 4, scale: 3, x: 0.7, y: 0.7, transition: transition, duration: duration)]
                for time in [0.0, 1.99, 2, 2.5, 3, 3.5, 3.999, 4, 5] {
                    let progress = MotionInterpolation.progress(at: time, from: 0, to: 4,
                                                                 duration: duration, transition: transition)
                    let pip = state.placement(at: time)
                    let zoom = state.zoom(at: time)
                    near((pip.x - initialPIP.x) / (finalPIP.x - initialPIP.x), progress,
                         "PIP pan uses shared transition timing")
                    near((pip.scale - initialPIP.scale) / (finalPIP.scale - initialPIP.scale), progress,
                         "PIP zoom uses shared transition timing")
                    near((pip.crop.x - initialPIP.crop.x) / (finalPIP.crop.x - initialPIP.crop.x), progress,
                         "PIP crop pan uses shared transition timing")
                    near(zoom.scale - 2, progress, "Main zoom uses the same easing as PIP")
                    near((zoom.x - 0.3) / 0.4, progress, "Main pan uses the same easing as PIP")
                }
            }
        }
        near(MotionInterpolation.progress(at: 2.5, from: 0, to: 4, duration: 2, transition: .smooth),
             15.0 / 91, "Shared curve reaches cruise speed after its first quarter")
        near(MotionInterpolation.progress(at: 3, from: 3, to: 4, duration: 20, transition: .smooth),
             0, "Shared transition starts no earlier than preceding point")

        let source = CGSize(width: 1000, height: 500)
        let legacy = PIPPlacement(x: 0.2, y: 0.3, scale: 0.4, shape: .rectangle, aspectRatio: 2)
        let pipFrame = legacy.frame(in: source, cameraAspect: 2)
        let zoomFrame = ZoomPlacement(scale: 2.5, x: 0.32, y: 0.38).viewport(in: source)
        let sharedFrame = ViewportGeometry.rect(in: source, size: CGSize(width: 400, height: 200),
                                                center: CGPoint(x: 0.32, y: 0.38))
        for actual in [pipFrame, zoomFrame, sharedFrame] {
            near(actual.minX, 120, "PIP travel coordinates and source focal coordinates describe the same viewport")
            near(actual.minY, 90, "Shared top-left viewport origin")
            near(actual.width, 400, "Shared viewport width")
            near(actual.height, 200, "Shared viewport height")
        }
        let cameraCrop = PIPCrop(x: 0.2, y: 0.3).rect(in: source, shape: .rectangle, aspectRatio: 5)
        near(cameraCrop.minY, zoomFrame.minY, "Camera crop and main zoom share vertical viewport clamping")
        near(cameraCrop.height, zoomFrame.height, "Matching cropped dimensions retain matching legacy pan anchors")
        for center in [CGPoint(x: -1, y: -1), CGPoint(x: 2, y: 2)] {
            let bounded = ViewportGeometry.rect(in: source, size: CGSize(width: 400, height: 200), center: center)
            precondition(bounded.minX >= 0 && bounded.minY >= 0 && bounded.maxX <= source.width && bounded.maxY <= source.height)
        }
    }

    private static func checkMotionVelocity() {
        func progress(_ time: Double) -> Double {
            MotionInterpolation.progress(at: time, from: 0, to: 1, duration: 1, transition: .smooth)
        }
        let delta = 0.000_01
        func velocity(_ time: Double) -> Double {
            (progress(time + delta) - progress(time - delta)) / (2 * delta)
        }
        near(progress(-1), 0, "Smooth motion holds before its beginning")
        near(progress(2), 1, "Smooth motion holds after arrival")
        near(velocity(0), 0, "Smooth motion starts at rest")
        near(velocity(1), 0, "Smooth motion ends at rest")
        for time in [0.26, 0.35, 0.5, 0.65, 0.74] {
            near(velocity(time), 120.0 / 91, "Middle half travels at constant speed")
        }
        precondition(velocity(0.01) < velocity(0.1) && velocity(0.1) < velocity(0.2),
                     "Motion gently accelerates before cruising")
        precondition(velocity(0.8) > velocity(0.9) && velocity(0.9) > velocity(0.99),
                     "Motion gently decelerates to rest")
        for boundary in [0.25, 0.75] {
            precondition(abs(velocity(boundary - delta) - velocity(boundary + delta)) < 0.000_001,
                         "Velocity stays continuous where acceleration meets cruise")
        }
        var previous = 0.0
        for step in 0...1000 {
            let time = Double(step) / 1000
            let current = progress(time)
            precondition(current >= previous && current >= 0 && current <= 1,
                         "Motion is bounded and monotonic")
            previous = current
        }
        precondition(velocity(0.9) > velocity(0.5) * 0.3,
                     "Braking retains visible late movement rather than concentrating travel before an imperceptible tail")
        for time in [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1] {
            near(MotionInterpolation.progress(at: 3 + time, from: 3, to: 4, duration: 20, transition: .smooth),
                 progress(time), "Shortened transitions retain the same acceleration/cruise/deceleration profile")
        }
        near(MotionInterpolation.progress(at: 0.999, from: 0, to: 1, duration: 1, transition: .jump),
             0, "Jump never starts moving early")
        near(MotionInterpolation.progress(at: 1, from: 0, to: 1, duration: 1, transition: .jump),
             1, "Jump applies instantly at arrival")

        func custom(_ time: Double, start: Double?, end: Double?) -> Double {
            MotionInterpolation.progress(at: time, from: 0, to: 1, duration: 1,
                                         transition: .smooth, easeIn: start, easeOut: end)
        }
        let ramps = MotionInterpolation.rampDurations(duration: 1, easeIn: 0.1, easeOut: 0.3)
        near(ramps.easeIn, 0.1, "Acceleration duration is measured in seconds")
        near(ramps.easeOut, 0.3, "Deceleration duration is independent")
        near(custom(0.1, start: 0.1, end: 0.3), 5.0 / 81, "Asymmetric acceleration covers its expected distance")
        near(custom(0.5, start: 0.1, end: 0.3), 5.0 / 9, "Asymmetric movement retains constant cruise speed")
        near(custom(0.7, start: 0.1, end: 0.3), 65.0 / 81, "Asymmetric deceleration begins at its chosen time")
        let shortened = MotionInterpolation.rampDurations(duration: 1, easeIn: 1.2, easeOut: 0.8)
        near(shortened.easeIn, 0.6, "Oversubscribed acceleration shrinks proportionally")
        near(shortened.easeOut, 0.4, "Oversubscribed deceleration shrinks proportionally")
        for step in 0...1000 {
            let time = Double(step) / 1000
            near(custom(time, start: 0, end: 0), time, "Zero ramps explicitly request constant speed")
            let squeezed = custom(time, start: 1.2, end: 0.8)
            precondition(squeezed.isFinite && squeezed >= 0 && squeezed <= 1,
                         "All-ramp movement remains bounded when there is no cruise interval")
        }
        let extreme = MotionInterpolation.rampDurations(duration: 1, easeIn: .greatestFiniteMagnitude,
                                                        easeOut: .greatestFiniteMagnitude)
        near(extreme.easeIn, 0.5, "Extreme finite ramp durations never overflow")
        near(extreme.easeOut, 0.5, "Extreme finite ramp durations preserve their ratio")
    }

    private static func checkPersistenceAndMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = ["screen.mp4": Data("original screen".utf8), "camera.mov": Data("original camera".utf8),
                         "cursor.json": Data("immutable cursor samples".utf8)]
        for (name, bytes) in originals { try bytes.write(to: directory.appendingPathComponent(name)) }
        let project = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mov",
                                      cursorFilename: "cursor.json", duration: 10)
        let url = directory.appendingPathComponent("recording.framethrower")
        let editor = ProjectEditor(project: project, url: url)
        precondition(editor.save())
        var zoomed = project.state
        zoomed.trimEnd = 9
        zoomed.pipKeyframes[0].placement.sourceZoom = 2.25
        zoomed.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2.5, x: 0.7, y: 0.3, transition: .smooth, duration: 1)]
        precondition(editor.commit(zoomed, name: "Zoom"))
        var styled = zoomed
        styled.cursorStyle = CursorStyle(visible: false, size: 3, smoothing: 0.8, clickHighlight: false)
        precondition(editor.commit(styled, name: "Style pointer"))
        let reopened = try ProjectEditor.open(url: url)
        precondition(reopened.project == editor.project && reopened.project.cursorFilename == "cursor.json")
        precondition(reopened.undo() && reopened.project.state == zoomed)
        let withRedo = try ProjectEditor.open(url: url)
        precondition(withRedo.canRedo && withRedo.redo() && withRedo.project.state == styled)
        precondition(withRedo.undo() && withRedo.undo() && withRedo.project.state == project.state)
        precondition(withRedo.redo() && withRedo.project.state == zoomed)

        // Both history branches can predate zoom/style support. Defaults must
        // decode on every snapshot rather than only the active project state.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(withRedo.project)) as! [String: Any]
        func legacy(_ value: Any) -> [String: Any] {
            var state = value as! [String: Any]
            state.removeValue(forKey: "zoomKeyframes")
            state.removeValue(forKey: "cursorStyle")
            state["pipKeyframes"] = (state["pipKeyframes"] as! [[String: Any]]).map { point in
                var point = point
                var placement = point["placement"] as! [String: Any]
                placement.removeValue(forKey: "sourceZoom")
                point["placement"] = placement
                return point
            }
            return state
        }
        json.removeValue(forKey: "cursorFilename")
        json["state"] = legacy(json["state"]!)
        for key in ["undoHistory", "redoHistory"] {
            json[key] = (json[key] as! [[String: Any]]).map { value in
                var snapshot = value
                snapshot["state"] = legacy(value["state"]!)
                return snapshot
            }
        }
        let legacyURL = directory.appendingPathComponent("legacy.framethrower")
        try JSONSerialization.data(withJSONObject: json).write(to: legacyURL)
        let migrated = try ProjectEditor.open(url: legacyURL)
        precondition(migrated.project.cursorFilename == nil && migrated.project.state.zoomKeyframes.isEmpty)
        for state in [migrated.project.state] + (migrated.project.undoHistory + migrated.project.redoHistory).map(\.state) {
            precondition(state.zoomKeyframes.isEmpty && state.cursorStyle == CursorStyle())
            precondition(state.pipKeyframes.allSatisfy { $0.placement.sourceZoom == 1 },
                         "Older camera/history snapshots retain their unzoomed source")
        }
        precondition(migrated.undo() && migrated.project.state.trimEnd == 10)
        precondition(migrated.redo() && migrated.project.state.trimEnd == 9)

        // A failed feature edit must keep the current state and complete redo
        // history, so retrying after a disk problem remains safe.
        let beforeFailure = withRedo.project
        let displaced = directory.appendingPathExtension("displaced")
        try FileManager.default.moveItem(at: directory, to: displaced)
        precondition(!withRedo.commit(styled, name: "Retry style") && withRedo.project == beforeFailure)
        try FileManager.default.moveItem(at: displaced, to: directory)
        precondition(withRedo.commit(styled, name: "Retry style") && !withRedo.canRedo)

        let overwrite = ProjectEditor(project: project, url: directory.appendingPathComponent("cursor.json"))
        precondition(!overwrite.save(), "Saving a project must never replace immutable pointer samples")
        for (name, bytes) in originals {
            let after = try Data(contentsOf: directory.appendingPathComponent(name))
            precondition(after == bytes, "Zoom/style/history operations cannot rewrite source media or pointer samples")
        }
    }

    private static func checkValidation() {
        let project = RecordingProject(screenFilename: "screen.mp4", duration: 10)
        for point in [ZoomKeyframe(time: -1), ZoomKeyframe(time: 11), ZoomKeyframe(time: .nan),
                      ZoomKeyframe(time: 1, scale: 0.9), ZoomKeyframe(time: 1, scale: 3.1),
                      ZoomKeyframe(time: 1, x: -.infinity), ZoomKeyframe(time: 1, y: 1.1),
                      ZoomKeyframe(time: 1, duration: 0)] {
            var invalid = project
            invalid.state.zoomKeyframes = [point]
            reject(invalid)
        }
        var invalid = project
        invalid.state.zoomKeyframes = [ZoomKeyframe(time: 2), ZoomKeyframe(time: 1)]
        reject(invalid)
        invalid.state.zoomKeyframes = [ZoomKeyframe(time: 1), ZoomKeyframe(time: 1)]
        reject(invalid)
        invalid.state.zoomKeyframes[1].time = 2
        invalid.state.zoomKeyframes[1].id = invalid.state.zoomKeyframes[0].id
        reject(invalid)
        for style in [CursorStyle(size: 0.9), CursorStyle(size: 4.1), CursorStyle(size: .nan),
                      CursorStyle(smoothing: -0.1), CursorStyle(smoothing: 1.1), CursorStyle(smoothing: .infinity)] {
            invalid = project
            invalid.state.cursorStyle = style
            reject(invalid)
        }
        for sourceZoom in [0.9, 3.1, Double.nan, Double.infinity] {
            invalid = project
            invalid.state.pipKeyframes[0].placement.sourceZoom = sourceZoom
            reject(invalid)
        }
        for filename in ["../cursor.json", "nested/cursor.json", "screen.mp4", ""] {
            invalid = project
            invalid.cursorFilename = filename
            reject(invalid)
        }
        invalid = project
        var invalidHistory = project.state
        invalidHistory.zoomKeyframes = [ZoomKeyframe(time: 1, scale: 10)]
        invalid.undoHistory = [NamedEditSnapshot(name: "Invalid historical zoom", state: invalidHistory)]
        reject(invalid)
    }

    private static func reject(_ project: RecordingProject) {
        do { try project.validate(); preconditionFailure("Expected invalid zoom/cursor project") }
        catch {}
    }

    private static func expect(_ actual: ZoomPlacement, _ expected: ZoomPlacement, _ message: String) {
        near(actual.scale, expected.scale, message)
        near(actual.x, expected.x, message)
        near(actual.y, expected.y, message)
    }

    private static func near(_ actual: Double, _ expected: Double, _ message: String) {
        precondition(abs(actual - expected) < 0.000_001, "\(message): \(actual) != \(expected)")
    }
}
