import Foundation

private enum FullscreenFailure: Error { case failed(String) }
@main @MainActor
struct PIPFullscreenChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw FullscreenFailure.failed(message) }
    }
    static func near(_ a: Double, _ b: Double, _ message: String) throws {
        try require(abs(a - b) < 0.000_000_01, message)
    }
    static func sameRect(_ a: CGRect, _ b: CGRect, _ message: String) throws {
        try near(a.minX, b.minX, message); try near(a.minY, b.minY, message)
        try near(a.width, b.width, message); try near(a.height, b.height, message)
    }
    static let normal = PIPPlacement(x: 0.8, y: 0.9, scale: 0.25, visible: true, shape: .circle,
        aspectRatio: 1.7, crop: PIPCrop(x: 0.2, y: 0.7), sourceZoom: 1.4)
    static func fixture() -> RecordingProject {
        var project = RecordingProject(screenFilename: "unopened-screen.mov", cameraFilename: "unopened-camera.mov", duration: 16)
        project.state.pipKeyframes = [PIPKeyframe(time: 0, placement: normal)]
        project.state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 2, x: 0.4, y: 0.4)]
        return project
    }
    static let expand = EditorMutation.cameraOverlay(.init(fullscreen: 1),
        timing: .init(start: 9, end: 11, easeIn: 0.3, easeOut: 0.6))
    static let restore = EditorMutation.cameraOverlay(.init(fullscreen: 0),
        timing: .init(start: 12, end: 14, easeIn: 0.5, easeOut: 0.8))
    static func main() throws {
        try require(MediaProcessing.isSuspended, "media remains suspended")
        try legacyAndValidation()
        try geometryAndCrop()
        try timingAndRestore()
        try durableHistory()
        print("PIP fullscreen checks passed: legacy/nil-zero compatibility, exact output fill, no-stretch aspect-fill, shared 9→11 timing, restore, independent screen, one Undo/Redo and atomic validation; metadata only.")
    }
    static func legacyAndValidation() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let bytes = try encoder.encode(normal)
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        try require(object["fullscreen"] == nil, "legacy normal placement omits optional metadata")
        let legacy = try decoder.decode(PIPPlacement.self, from: bytes)
        try require(legacy == normal && legacy.fullscreen == nil && legacy.fullscreenFraction == 0, "absent field keeps exact normal values")
        for zero in [nil, Double(0)] {
            var project = fixture()
            project.state.pipKeyframes[0].placement.fullscreen = zero
            let original = project.state
            var state = original
            try EditorMutation.cameraOverlay(.init(fullscreen: 0), timing: .init(start: 9, end: 11)).apply(to: &state, project: project)
            try require(state == original, "explicit zero and nil are true no-op mutations")
        }
        for value in [-0.1, 1.1, Double.nan, Double.infinity] {
            let project = fixture()
            var state = project.state
            do {
                try EditorMutation.cameraOverlay(.init(fullscreen: value), timing: .init(start: 9, end: 11)).apply(to: &state, project: project)
                throw FullscreenFailure.failed("invalid fullscreen fraction accepted")
            } catch is ProjectError {}
            try require(state == project.state, "bad fullscreen leaves state untouched")
        }
        let command = EditorCommand.mutate(expand)
        try require(try decoder.decode(EditorCommand.self, from: encoder.encode(command)) == command, "new mutation strict roundtrip")
        do {
            _ = try decoder.decode(EditorMutation.self, from: Data(#"{"operation":"cameraOverlay","patch":{"fullscreen":null},"timing":{"start":9,"end":11}}"#.utf8))
            throw FullscreenFailure.failed("null patch accepted")
        } catch is DecodingError {} catch is EditorMutationError {}
    }
    static func geometryAndCrop() throws {
        let canvases = [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080), CGSize(width: 7680, height: 1080)]
        let sources = [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)]
        for canvas in canvases {
            for source in sources {
                let baseFrame = normal.frame(in: canvas, cameraAspect: source.width / source.height)
                try sameRect(normal.sourceViewport(in: source, canvas: canvas), normal.crop.rect(in: source, shape: normal.shape,
                    aspectRatio: normal.aspectRatio, zoom: normal.sourceZoom), "normal crop remains identical")
                for fraction in [0.0, 0.1, 0.5, 0.9, 1] {
                    var placement = normal
                    placement.fullscreen = fraction
                    let frame = placement.frame(in: canvas, cameraAspect: source.width / source.height)
                    try sameRect(frame, CGRect(x: baseFrame.minX * (1 - fraction), y: baseFrame.minY * (1 - fraction),
                        width: baseFrame.width + (canvas.width - baseFrame.width) * fraction,
                        height: baseFrame.height + (canvas.height - baseFrame.height) * fraction), "entire geometry follows fullscreen fraction")
                    let crop = placement.sourceViewport(in: source, canvas: canvas)
                    try near(crop.width / crop.height, frame.width / frame.height, "intermediate camera has no aspect distortion")
                    try require(crop.minX >= 0 && crop.minY >= 0 && crop.maxX <= source.width + 1e-8 && crop.maxY <= source.height + 1e-8,
                        "aspect-fill crop stays inside original source")
                    try near(placement.cornerRadius(in: frame.size), min(frame.width, frame.height) / 2 * (1 - fraction), "circle becomes rectangular continuously")
                    if fraction == 1 {
                        try require(frame == CGRect(origin: .zero, size: canvas), "fullscreen fills exact canvas independent of normal size/shape")
                        try require(placement.cornerRadius(in: frame.size) == 0, "fullscreen has square corners")
                    }
                }
            }
        }
        var full = normal; full.fullscreen = 1
        try require(full.sourceViewport(in: .zero, canvas: canvases[0]) == .zero && full.frame(in: .zero, cameraAspect: 1) == .zero,
            "invalid geometry produces no nonfinite results")
    }
    static func timingAndRestore() throws {
        let project = fixture()
        var state = project.state
        try expand.apply(to: &state, project: project)
        try restore.apply(to: &state, project: project)
        try require(state.zoomKeyframes == project.state.zoomKeyframes && state.regions == project.state.regions && state.audio == project.state.audio,
            "camera animation leaves screen/boxes/audio untouched")
        try require(state.pipKeyframes[0].id == project.state.pipKeyframes[0].id, "initial identity stable")
        try require(state.placement(at: 8.9) == normal && state.placement(at: 9).fullscreenFraction == 0, "no early camera movement")
        var startingAppearance = state.placement(at: 9)
        startingAppearance.fullscreen = nil // nil and zero are the same normal geometry.
        try require(startingAppearance == normal, "all normal appearance fields preserved at start")
        let arrival = state.pipKeyframes.first { $0.time == 11 }!
        try require(arrival.duration == 2 && arrival.easeIn == 0.3 && arrival.easeOut == 0.6, "exact two-second shared ramp metadata")
        let canvas = CGSize(width: 1280, height: 720), aspect = 16.0 / 9
        for time in [9.1, 9.5, 10, 10.8, 10.99] {
            let p = MotionInterpolation.progress(at: time, from: 9, to: 11, duration: 2, transition: .smooth, easeIn: 0.3, easeOut: 0.6)
            let placement = state.placement(at: time)
            try near(placement.fullscreenFraction, p, "same shared easing as screen/camera motion")
            try require(placement.x == normal.x && placement.y == normal.y && placement.scale == normal.scale && placement.shape == normal.shape && placement.crop == normal.crop,
                "fullscreen does not rewrite saved normal appearance")
        }
        try require(state.placement(at: 11).frame(in: canvas, cameraAspect: aspect) == CGRect(origin: .zero, size: canvas), "exact arrival at11")
        try require(state.placement(at: 11.5).fullscreenFraction == 1, "held fullscreen before return")
        try require(state.placement(at: 14) == normal && state.placement(at: 15) == normal, "return restores all normal placement metadata")
        try require(state.placement(at: 13).fullscreenFraction > 0 && state.placement(at: 13).fullscreenFraction < 1, "return animates rather than switching")
    }
    static func durableHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-fullscreen-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = fixture()
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("test.framethrower"))
        try require(editor.save(), "save fixture")
        let id = UUID()
        let batch = try EditorCommandBatch(projectID: id, revision: EditorCommandDispatcher.revision(for: editor.project), commands: [.mutate(expand), .mutate(restore)])
        try require(EditorCommandDispatcher.apply(batch, to: editor, projectID: id), "apply one fullscreen+return batch")
        let applied = editor.editingState
        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.editingState == applied && reopened.editingState.placement(at: 11).fullscreen == 1, "fullscreen metadata persists across reopen")
        try require(editor.undo() && editor.editingState == project.state && !editor.canUndo, "one Undo restores pre-animation state")
        try require(editor.redo() && editor.editingState == applied, "Redo restores full route")
        let final = try ProjectEditor.open(url: editor.url)
        try require(final.editingState == applied && final.editingState.placement(at: 14) == normal, "durable restore retains normal shape/size/crop")
    }
}
