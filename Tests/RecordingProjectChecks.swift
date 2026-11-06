import Foundation

// Run with Tests/check-recording-project.sh. No camera, permissions, or account required.
@main
struct RecordingProjectChecks {
    @MainActor static func main() throws {
        try checkPlacementGeometry()
        checkShapeAndCropGeometry()
        checkInteractiveGeometry()
        checkTransitions()
        try checkPersistence()
        try checkShapeHistoryAndLegacyDecoding()
        print("Recording project checks passed: geometry, crop/shape, jump/smooth timing, validation, durable undo/redo, legacy decoding, and immutable originals.")
    }

    static func checkShapeAndCropGeometry() {
        let landscape = CGSize(width: 1920, height: 1080)
        let portrait = CGSize(width: 1080, height: 1920)
        expect(PIPCrop(x: 0, y: 0).rect(in: landscape, shape: .square),
               CGRect(x: 0, y: 0, width: 1080, height: 1080), "Landscape left crop")
        expect(PIPCrop(x: 1, y: 1).rect(in: landscape, shape: .square),
               CGRect(x: 840, y: 0, width: 1080, height: 1080), "Landscape right crop")
        expect(PIPCrop().rect(in: landscape, shape: .circle),
               CGRect(x: 420, y: 0, width: 1080, height: 1080), "Circle uses centered square source")
        expect(PIPCrop(x: 1, y: 0).rect(in: portrait, shape: .circle),
               CGRect(x: 0, y: 0, width: 1080, height: 1080), "Portrait top crop")
        expect(PIPCrop(x: 0, y: 1).rect(in: portrait, shape: .square),
               CGRect(x: 0, y: 840, width: 1080, height: 1080), "Portrait bottom crop")
        expect(PIPCrop().rect(in: portrait, shape: .square),
               CGRect(x: 0, y: 420, width: 1080, height: 1080), "Portrait centered crop")
        expect(PIPCrop(x: 1, y: 0).rect(in: landscape, shape: .original),
               CGRect(origin: .zero, size: landscape), "Original shape retains the full source")
        expect(PIPCrop(x: -1, y: 2).rect(in: portrait, shape: .circle),
               CGRect(x: 0, y: 840, width: 1080, height: 1080), "Crop geometry clamps anchors")
        expect(PIPCrop().rect(in: .zero, shape: .square), .zero, "Empty crop source")
        expect(PIPCrop().rect(in: CGSize(width: Double.infinity, height: 1), shape: .circle), .zero,
               "Invalid crop source")
        for shape in [PIPShape.square, .circle] {
            let placed = PIPPlacement(x: 1, y: 1, scale: 0.25, shape: shape)
            expect(placed.frame(in: landscape, cameraAspect: 16.0 / 9.0),
                   CGRect(x: 1440, y: 600, width: 480, height: 480), "Square output geometry")
            expect(placed.frame(in: landscape, cameraAspect: 0.1),
                   CGRect(x: 1440, y: 600, width: 480, height: 480), "Crop shape ignores native camera aspect")
        }
        expect(PIPPlacement(x: 1, y: 1, scale: 0.5, shape: .circle).frame(in: CGSize(width: 2000, height: 500),
                   cameraAspect: 16.0 / 9.0),
               CGRect(x: 1600, y: 100, width: 400, height: 400), "Circle output respects the canvas height cap")
        expect(PIPCrop(x: 0, y: 1).rect(in: landscape, shape: .rectangle, aspectRatio: 2),
               CGRect(x: 0, y: 120, width: 1920, height: 960), "Free rectangle crops source to its aspect")
        expect(PIPCrop(x: 1, y: 0).rect(in: landscape, shape: .rectangle, aspectRatio: 0.5),
               CGRect(x: 1380, y: 0, width: 540, height: 1080), "Tall free rectangle crop anchor")
        expect(PIPPlacement(x: 0, y: 0, scale: 0.25, shape: .rectangle, aspectRatio: 2)
            .frame(in: landscape, cameraAspect: 0.5),
               CGRect(x: 0, y: 0, width: 480, height: 240), "Free rectangle uses edited aspect rather than native aspect")
    }

    static func checkPlacementGeometry() throws {
        let size = CGSize(width: 1920, height: 1080)
        let bottomRight = PIPPlacement(x: 1, y: 1, scale: 0.25).frame(in: size, cameraAspect: 16.0 / 9.0)
        expect(bottomRight, CGRect(x: 1440, y: 810, width: 480, height: 270), "Bottom-right anchor")
        expect(PIPPlacement(x: 0, y: 0, scale: 0.25).frame(in: size, cameraAspect: 16.0 / 9.0),
               CGRect(x: 0, y: 0, width: 480, height: 270), "Top-left anchor")
        let tall = PIPPlacement(x: 1, y: 1, scale: 0.5).frame(in: size, cameraAspect: 0.5)
        expect(tall, CGRect(x: 1488, y: 216, width: 432, height: 864), "Tall camera height cap")
        let clamped = PIPPlacement(x: -1, y: 2, scale: 5).frame(in: size, cameraAspect: 16.0 / 9.0)
        expect(clamped, CGRect(x: 0, y: 540, width: 960, height: 540), "Out-of-bounds geometry stays on screen")
        expect(PIPPlacement().frame(in: .zero, cameraAspect: 1), .zero, "Empty canvas")
        let fallback = PIPPlacement(x: .nan, y: .infinity, scale: .nan).frame(in: size, cameraAspect: .nan)
        precondition(fallback.minX.isFinite && fallback.minY.isFinite && fallback.width.isFinite)
    }

    static func checkInteractiveGeometry() {
        let canvas = CGSize(width: 1000, height: 800)
        let nativeAspect = 16.0 / 9.0
        let rectangle = PIPPlacement(x: 0.2, y: 0.3, scale: 0.3, shape: .rectangle, aspectRatio: 2)
        let originalRect = rectangle.frame(in: canvas, cameraAspect: nativeAspect)
        let horizontal = rectangle.resized(by: CGSize(width: 100, height: 0), in: canvas, cameraAspect: nativeAspect)
        near(horizontal.aspectRatio, 400.0 / 150.0, "Horizontal resize changes free rectangle aspect")
        expect(horizontal.frame(in: canvas, cameraAspect: nativeAspect),
               CGRect(x: originalRect.minX, y: originalRect.minY, width: 400, height: 150),
               "Horizontal resize anchors the top left")
        let vertical = rectangle.resized(by: CGSize(width: 0, height: 100), in: canvas, cameraAspect: nativeAspect)
        near(vertical.aspectRatio, 1.2, "Vertical resize changes free rectangle aspect")
        expect(vertical.frame(in: canvas, cameraAspect: nativeAspect),
               CGRect(x: originalRect.minX, y: originalRect.minY, width: 300, height: 250),
               "Vertical resize preserves width and top-left anchor")
        let diagonal = rectangle.resized(by: CGSize(width: 100, height: 50), in: canvas, cameraAspect: nativeAspect)
        expect(diagonal.frame(in: canvas, cameraAspect: nativeAspect),
               CGRect(x: originalRect.minX, y: originalRect.minY, width: 400, height: 200),
               "Diagonal resize follows both pointer axes")
        for shape in [PIPShape.original, .square, .circle] {
            let placement = PIPPlacement(x: 0.2, y: 0.3, scale: 0.3, shape: shape)
            let before = placement.frame(in: canvas, cameraAspect: nativeAspect)
            let changed = placement.resized(by: CGSize(width: 100, height: 100), in: canvas, cameraAspect: nativeAspect)
            let after = changed.frame(in: canvas, cameraAspect: nativeAspect)
            near(after.width, 400, "Constrained shapes resize their width")
            near(after.width / after.height, shape == .original ? nativeAspect : 1,
                 "Original, square and circle retain their aspect")
            near(after.minX, before.minX, "Constrained resize anchors X")
            near(after.minY, before.minY, "Constrained resize anchors Y")
            precondition(changed.aspectRatio == placement.aspectRatio)
        }
        near(rectangle.resized(by: CGSize(width: 10000, height: 0), in: canvas,
                              cameraAspect: nativeAspect).scale, 0.5, "Resize maximum width")
        near(rectangle.resized(by: CGSize(width: -10000, height: 0), in: canvas,
                              cameraAspect: nativeAspect).scale, 0.12, "Resize minimum width")
        near(rectangle.resized(by: CGSize(width: 0, height: 10000), in: canvas,
                              cameraAspect: nativeAspect).aspectRatio, 0.2, "Resize minimum aspect")
        near(rectangle.resized(by: CGSize(width: 0, height: -10000), in: canvas,
                              cameraAspect: nativeAspect).aspectRatio, 5, "Resize maximum aspect")
        let corner = PIPPlacement(x: 1, y: 1, scale: 0.3, shape: .circle)
        let expanded = corner.resized(by: CGSize(width: 200, height: 200), in: canvas, cameraAspect: nativeAspect)
        expect(expanded.frame(in: canvas, cameraAspect: nativeAspect), CGRect(x: 500, y: 300, width: 500, height: 500),
               "Expanding at an edge stays inside the canvas")
        let shortCanvas = CGSize(width: 1000, height: 200)
        let capped = rectangle.resized(by: CGSize(width: 100, height: 100), in: shortCanvas, cameraAspect: nativeAspect)
        near(capped.scale, 0.4, "Height cap preserves the requested width fraction")
        near(capped.aspectRatio, 1.6, "Height cap preserves the requested rectangle aspect")
        let cappedRect = capped.frame(in: shortCanvas, cameraAspect: nativeAspect)
        near(cappedRect.height, 160, "Height cap takes precedence over requested width")
        near(cappedRect.width, 256, "Height cap retains the chosen rectangle aspect")
        precondition(cappedRect.minX >= 0 && cappedRect.maxX <= shortCanvas.width && cappedRect.maxY <= shortCanvas.height)
        precondition(rectangle.resized(by: .zero, in: shortCanvas, cameraAspect: nativeAspect) == rectangle,
                     "A stationary resize must not create a spurious edit")

        let landscape = CGSize(width: 1920, height: 1080)
        let portrait = CGSize(width: 1080, height: 1920)
        let centered = PIPCrop()
        let landscapePan = centered.moved(by: CGSize(width: 210, height: 100), in: landscape, shape: .square)
        near(landscapePan.x, 0.75, "Crop pan converts source pixels to horizontal travel fractions")
        near(landscapePan.y, 0.5, "No vertical crop travel leaves the anchor unchanged")
        let portraitPan = centered.moved(by: CGSize(width: 100, height: -210), in: portrait, shape: .circle)
        near(portraitPan.x, 0.5, "No horizontal crop travel leaves the anchor unchanged")
        near(portraitPan.y, 0.25, "Portrait crop pans vertically")
        precondition(centered.moved(by: CGSize(width: 10000, height: -10000), in: landscape, shape: .original) == centered,
                     "Full-source framing cannot pan")
        near(centered.moved(by: CGSize(width: 10000, height: 0), in: landscape, shape: .square).x,
             1, "Crop pan clamps at right edge")
        near(centered.moved(by: CGSize(width: -10000, height: 0), in: landscape, shape: .square).x,
             0, "Crop pan clamps at left edge")
        near(centered.moved(by: CGSize(width: 0, height: 30), in: landscape, shape: .rectangle, aspectRatio: 2).y,
             0.75, "Free rectangle crop pan uses its own aspect")
        precondition(centered.moved(by: .zero, in: .zero, shape: .circle) == centered)
    }

    static func checkTransitions() {
        let first = PIPPlacement(x: 0, y: 0, scale: 0.2)
        let second = PIPPlacement(x: 0.2, y: 0.4, scale: 0.3, visible: false)
        let third = PIPPlacement(x: 1, y: 1, scale: 0.5, visible: true)
        var state = EditState(trimStart: 0, trimEnd: 12, pipKeyframes: [
            PIPKeyframe(time: 0, placement: first),
            PIPKeyframe(time: 2, placement: second),
            PIPKeyframe(time: 8, placement: third, transition: .smooth, duration: 2)
        ])
        precondition(state.placement(at: -1) == first)
        precondition(state.placement(at: 1.999) == first, "Jump must not interpolate")
        precondition(state.placement(at: 2) == second, "Jump happens at its exact timestamp")
        precondition(state.placement(at: 6) == second, "Smooth motion starts at arrival minus duration")
        let midpoint = state.placement(at: 7)
        near(midpoint.x, 0.6, "Smooth midpoint X")
        near(midpoint.y, 0.7, "Smooth midpoint Y")
        near(midpoint.scale, 0.4, "Smooth midpoint size")
        precondition(!midpoint.visible, "Visibility remains discrete until arrival")
        let early = state.placement(at: 6.5)
        near(early.x, 0.2 + 0.8 * 0.15625, "Smoothstep easing, not linear motion")
        precondition(state.placement(at: 8) == third)
        precondition(state.placement(at: 100) == third)

        state.pipKeyframes[2].duration = 100
        precondition(state.placement(at: 2) == second, "Long transition cannot begin before previous point")
        near(state.placement(at: 5).x, 0.6, "Long transition is clamped to previous point")
        let identity = state.pipKeyframes[1].id
        state.upsert(PIPKeyframe(time: 2, placement: third))
        precondition(state.pipKeyframes.count == 3 && state.pipKeyframes[1].id == identity)
        precondition(state.pipKeyframes[1].placement == third)
        state.upsert(PIPKeyframe(time: 0.000_000_5, placement: third))
        precondition(state.pipKeyframes[0].time == 0, "Near-zero replacement preserves the initial timestamp")
        state.upsert(PIPKeyframe(time: 1, placement: first))
        precondition(state.pipKeyframes.map(\.time) == [0, 1, 2, 8])

        let rectangle = PIPPlacement(shape: .rectangle, aspectRatio: 2, crop: PIPCrop(x: 0, y: 1))
        let circle = PIPPlacement(shape: .circle, aspectRatio: 1, crop: PIPCrop(x: 1, y: 0))
        let geometry = EditState(trimStart: 0, trimEnd: 10, pipKeyframes: [
            PIPKeyframe(time: 0, placement: rectangle),
            PIPKeyframe(time: 8, placement: circle, transition: .smooth, duration: 2)
        ])
        let during = geometry.placement(at: 7)
        precondition(during.shape == .rectangle, "Shape switches discretely at the target timestamp")
        near(during.aspectRatio, 1.5, "Free rectangle aspect interpolates")
        near(during.crop.x, 0.5, "Crop X interpolates")
        near(during.crop.y, 0.5, "Crop Y interpolates")
        near(geometry.placement(at: 6.5).crop.x, 0.15625, "Crop uses smoothstep easing")
        precondition(geometry.placement(at: 6) == rectangle)
        precondition(geometry.placement(at: 8) == circle)
    }

    @MainActor static func checkPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = Data("immutable original screen".utf8)
        let camera = Data("immutable original camera".utf8)
        try screen.write(to: directory.appendingPathComponent("screen.mp4"))
        try camera.write(to: directory.appendingPathComponent("camera.mov"))
        let projectURL = directory.appendingPathComponent("recording.framethrower")
        let original = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mov",
                                        cameraOffset: -0.25, duration: 10)
        let editor = ProjectEditor(project: original, url: projectURL)
        precondition(editor.save(), editor.errorMessage ?? "Save failed")
        var trimmed = original.state
        trimmed.trimStart = 1
        trimmed.trimEnd = 9
        precondition(editor.commit(trimmed, name: "Trim"))
        var moved = trimmed
        moved.upsert(PIPKeyframe(time: 4, placement: PIPPlacement(x: 0, y: 0), transition: .smooth))
        precondition(editor.commit(moved, name: "Move camera"))
        precondition(editor.canUndo && !editor.canRedo && editor.undoName == "Move camera")

        let reopened = try ProjectEditor.open(url: projectURL)
        precondition(reopened.project == editor.project, "Full history must survive reopening")
        precondition(reopened.undo() && reopened.project.state == trimmed && reopened.redoName == "Move camera")
        let reopenedAgain = try ProjectEditor.open(url: projectURL)
        precondition(reopenedAgain.canRedo && reopenedAgain.redo())
        precondition(reopenedAgain.project.state == moved)
        precondition(reopenedAgain.undo() && reopenedAgain.undo())
        precondition(reopenedAgain.project.state == original.state && !reopenedAgain.canUndo)
        precondition(reopenedAgain.redo() && reopenedAgain.project.state == trimmed)

        var branch = trimmed
        branch.trimEnd = 8
        precondition(reopenedAgain.commit(branch, name: "New trim"))
        precondition(!reopenedAgain.canRedo, "New edit invalidates the redo branch")
        let unchangedHistory = reopenedAgain.project
        precondition(reopenedAgain.commit(branch, name: "No-op") && reopenedAgain.project == unchangedHistory)

        var invalid = branch
        invalid.trimStart = 9
        let bytesBefore = try Data(contentsOf: projectURL)
        precondition(!reopenedAgain.commit(invalid, name: "Invalid trim"))
        precondition(reopenedAgain.errorMessage != nil && reopenedAgain.project == unchangedHistory)
        let bytesAfter = try Data(contentsOf: projectURL)
        precondition(bytesAfter == bytesBefore, "Invalid edit cannot alter durable history")

        // Force an actual persistence failure. The editor must retain its undo
        // entry and current edit when the project directory becomes unavailable.
        let movedDirectory = directory.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: directory, to: movedDirectory)
        precondition(!reopenedAgain.undo() && reopenedAgain.project == unchangedHistory)
        try FileManager.default.moveItem(at: movedDirectory, to: directory)
        precondition(reopenedAgain.undo(), "A failed undo must remain retryable")
        precondition(reopenedAgain.errorMessage == nil)

        var dangerous = original
        dangerous.screenFilename = "../screen.mp4"
        expectInvalid(dangerous, "Path traversal")
        dangerous = original
        dangerous.cameraFilename = dangerous.screenFilename
        expectInvalid(dangerous, "Shared screen/camera source")
        dangerous = original
        dangerous.version = 99
        expectInvalid(dangerous, "Unknown version")
        dangerous = original
        dangerous.state.pipKeyframes.append(dangerous.state.pipKeyframes[0])
        expectInvalid(dangerous, "Duplicate placement timestamp")
        dangerous = original
        dangerous.state.pipKeyframes[0].time = 1
        expectInvalid(dangerous, "Missing initial placement")
        dangerous = original
        dangerous.undoHistory.append(NamedEditSnapshot(name: "Corrupt history", state: invalid))
        expectInvalid(dangerous, "Invalid undo snapshot")
        for crop in [PIPCrop(x: -0.1), PIPCrop(y: 1.1), PIPCrop(x: .nan), PIPCrop(y: .infinity)] {
            dangerous = original
            dangerous.state.pipKeyframes[0].placement.crop = crop
            expectInvalid(dangerous, "Invalid crop")
        }
        dangerous = original
        var invalidCrop = original.state
        invalidCrop.pipKeyframes[0].placement.crop.x = .infinity
        dangerous.redoHistory.append(NamedEditSnapshot(name: "Corrupt crop history", state: invalidCrop))
        expectInvalid(dangerous, "Invalid crop inside redo snapshot")
        for aspect in [-1, 0, 0.1, 5.1, Double.nan, Double.infinity] {
            dangerous = original
            dangerous.state.pipKeyframes[0].placement.aspectRatio = aspect
            expectInvalid(dangerous, "Invalid free rectangle aspect")
        }

        let overwrite = ProjectEditor(project: original, url: directory.appendingPathComponent("screen.mp4"))
        precondition(!overwrite.save(), "Project must never overwrite source media")
        let screenAfter = try Data(contentsOf: directory.appendingPathComponent("screen.mp4"))
        let cameraAfter = try Data(contentsOf: directory.appendingPathComponent("camera.mov"))
        precondition(screenAfter == screen)
        precondition(cameraAfter == camera)
    }

    @MainActor static func checkShapeHistoryAndLegacyDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = Data("original screen for shape checks".utf8)
        let camera = Data("original camera for shape checks".utf8)
        let screenURL = directory.appendingPathComponent("screen.mp4")
        let cameraURL = directory.appendingPathComponent("camera.mov")
        try screen.write(to: screenURL)
        try camera.write(to: cameraURL)
        let projectURL = directory.appendingPathComponent("recording.framethrower")
        let original = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mov", duration: 10)
        let editor = ProjectEditor(project: original, url: projectURL)
        precondition(editor.save())
        var square = original.state
        square.pipKeyframes[0].placement.shape = .square
        square.pipKeyframes[0].placement.crop = PIPCrop(x: 0, y: 1)
        precondition(editor.commit(square, name: "Crop camera"))
        var circle = square
        circle.upsert(PIPKeyframe(time: 4,
            placement: PIPPlacement(shape: .circle, crop: PIPCrop(x: 1, y: 0)), transition: .smooth))
        precondition(editor.commit(circle, name: "Circle camera"))
        let reopened = try ProjectEditor.open(url: projectURL)
        precondition(reopened.project.state == circle)
        precondition(reopened.undo() && reopened.project.state == square)
        let withRedo = try ProjectEditor.open(url: projectURL)
        precondition(withRedo.redo() && withRedo.project.state == circle)
        precondition(withRedo.undo() && withRedo.undo() && withRedo.project.state == original.state)
        precondition(withRedo.redo() && withRedo.project.state == square)

        // Remove the additive fields throughout the JSON to reproduce projects
        // written before shape/crop existed, including both history branches.
        let encoder = JSONEncoder()
        let data = try encoder.encode(withRedo.project)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func legacy(_ value: Any) -> [String: Any] {
            var state = value as! [String: Any]
            state["pipKeyframes"] = (state["pipKeyframes"] as! [[String: Any]]).map { point in
                var oldPoint = point
                var placement = point["placement"] as! [String: Any]
                placement.removeValue(forKey: "shape")
                placement.removeValue(forKey: "aspectRatio")
                placement.removeValue(forKey: "crop")
                oldPoint["placement"] = placement
                return oldPoint
            }
            return state
        }
        for key in ["undoHistory", "redoHistory"] {
            json[key] = (json[key] as! [[String: Any]]).map { snapshot in
                var old = snapshot
                old["state"] = legacy(snapshot["state"]!)
                return old
            }
        }
        // Mixed projects also occur: a current edit can have shape/crop while
        // its old undo/redo snapshots still need default values.
        let mixed = try JSONDecoder().decode(RecordingProject.self,
            from: JSONSerialization.data(withJSONObject: json))
        try mixed.validate()
        precondition(mixed.state == square)
        for snapshot in mixed.undoHistory + mixed.redoHistory {
            for point in snapshot.state.pipKeyframes {
                precondition(point.placement.shape == .original && point.placement.crop == PIPCrop())
                near(point.placement.aspectRatio, 16.0 / 9.0, "Legacy aspect defaults to original camera ratio")
            }
        }
        json["state"] = legacy(json["state"]!)
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        try legacyData.write(to: projectURL)
        let oldEditor = try ProjectEditor.open(url: projectURL)
        precondition(oldEditor.project.version == 1)
        precondition(oldEditor.project.state.pipKeyframes.allSatisfy {
            $0.placement.shape == .original && $0.placement.crop == PIPCrop()
        })
        precondition(oldEditor.canUndo && oldEditor.canRedo)
        precondition(oldEditor.undo() && oldEditor.redo() && oldEditor.redo())
        precondition(oldEditor.project.state.pipKeyframes.allSatisfy {
            $0.placement.shape == .original && $0.placement.crop == PIPCrop()
        })
        let savedAgain = try ProjectEditor.open(url: projectURL)
        precondition(savedAgain.project == oldEditor.project, "Legacy defaults persist safely on the next save")
        let screenAfter = try Data(contentsOf: screenURL)
        let cameraAfter = try Data(contentsOf: cameraURL)
        precondition(screenAfter == screen && cameraAfter == camera, "Shape/crop edits never modify source media")
    }

    static func expectInvalid(_ project: RecordingProject, _ message: String) {
        do {
            try project.validate()
            preconditionFailure("Expected invalid project: \(message)")
        } catch {}
    }

    static func near(_ actual: Double, _ expected: Double, _ message: String) {
        precondition(abs(actual - expected) < 0.000_001, "\(message): \(actual) != \(expected)")
    }

    static func expect(_ actual: CGRect, _ expected: CGRect, _ message: String) {
        near(actual.minX, expected.minX, message)
        near(actual.minY, expected.minY, message)
        near(actual.width, expected.width, message)
        near(actual.height, expected.height, message)
    }
}
