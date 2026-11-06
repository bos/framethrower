@preconcurrency import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreImage
import Foundation

@main
@MainActor
struct ProjectRendererChecks {
    enum CheckError: Error { case failed(String) }
    private static var cachedConsumer: NativeFrameConsumer?
    private static var phaseStarted = ContinuousClock.now
    private static var phase = "fixture creation" {
        didSet { phaseStarted = .now }
    }

    @MainActor
    static func main() async throws {
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                if ContinuousClock.now - phaseStarted >= .seconds(30) {
                    FileHandle.standardError.write(Data("Renderer check timed out during \(phase).\n".utf8))
                    exit(1)
                }
            }
        }
        defer {
            watchdog.cancel()
            cachedConsumer?.close()
            cachedConsumer = nil
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screen = directory.appendingPathComponent("screen.mov")
        let camera = directory.appendingPathComponent("camera.mov")
        try await movie(to: screen, width: 160, height: 120, duration: 5, camera: false)
        try await movie(to: camera, width: 80, height: 40, duration: 5, camera: true)
        let originalScreen = try Data(contentsOf: screen)
        let originalCamera = try Data(contentsOf: camera)
        var project = RecordingProject(screenFilename: "screen.mov", cameraFilename: "camera.mov", duration: 5)
        project.state.pipKeyframes = [
            PIPKeyframe(time: 0, placement: PIPPlacement(x: 0, y: 0, scale: 0.25)),
            PIPKeyframe(time: 1, placement: PIPPlacement(x: 1, y: 0, scale: 0.25), transition: .jump),
            PIPKeyframe(time: 3, placement: PIPPlacement(x: 0, y: 1, scale: 0.5), transition: .smooth, duration: 1),
            PIPKeyframe(time: 4, placement: PIPPlacement(x: 0, y: 1, scale: 0.5, visible: false))
        ]
        let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
        try require(rendered.screenSize == CGSize(width: 160, height: 120), "native screen dimensions")
        let sourceAudio = try await AVURLAsset(url: screen).loadTracks(withMediaType: .audio)
        let compositionAudio = try await rendered.asset.loadTracks(withMediaType: .audio)
        try require(sourceAudio.count == 2 && compositionAudio.count == 2, "both independent source audio tracks retained")
        try require(abs(rendered.cameraAspect - 2) < 0.0001, "native camera aspect")
        try await frame(rendered, at: 0.5, expected: CGRect(x: 0, y: 0, width: 40, height: 20))
        try await frame(rendered, at: 29.0 / 30, expected: CGRect(x: 0, y: 0, width: 40, height: 20))
        try await frame(rendered, at: 1, expected: CGRect(x: 120, y: 0, width: 40, height: 20))
        try await frame(rendered, at: 1.5, expected: CGRect(x: 120, y: 0, width: 40, height: 20))
        try await frame(rendered, at: 2.25, expected: CGRect(x: 96, y: 15, width: 46, height: 23), yellow: true)
        try await frame(rendered, at: 2.75, expected: CGRect(x: 13.5, y: 70, width: 74, height: 37), yellow: true)
        try await frame(rendered, at: 2.5, expected: CGRect(x: 50, y: 45, width: 60, height: 30), yellow: true)
        try await frame(rendered, at: 3, expected: CGRect(x: 0, y: 80, width: 80, height: 40), yellow: true)
        try await frame(rendered, at: 4, expected: nil)

        // Camera begins later than the screen: no held first frame before it exists.
        var delayed = project
        delayed.cameraOffset = 1
        let delayedRender = try await ProjectRenderer.makePreview(project: delayed, directory: directory)
        try await frame(delayedRender, at: 0.5, expected: nil)
        try await frame(delayedRender, at: 1, expected: CGRect(x: 120, y: 0, width: 40, height: 20))

        // Camera began before the screen: use its later source frames at source time zero.
        var early = project
        early.cameraOffset = -2
        early.state.pipKeyframes = [PIPKeyframe(time: 0, placement: PIPPlacement(x: 0, y: 0, scale: 0.25))]
        let earlyRender = try await ProjectRenderer.makePreview(project: early, directory: directory)
        try await frame(earlyRender, at: 0, expected: CGRect(x: 0, y: 0, width: 40, height: 20), yellow: true)
        try await frame(earlyRender, at: 3.5, expected: nil)

        guard let currentCameraFrame = try await ProjectRenderer.cameraFrame(project: project, directory: directory, at: 2.01) else {
            throw CheckError.failed("current camera frame is available for framing")
        }
        try pixel(currentCameraFrame, x: 40, y: 20, equals: [255, 255, 0])
        let plain = RecordingProject(screenFilename: "screen.mov", duration: 5)
        let plainRender = try await ProjectRenderer.makePreview(project: plain, directory: directory)
        try await frame(plainRender, at: 0.5, expected: nil)
        let plainAudio = try await plainRender.asset.loadTracks(withMediaType: .audio)
        try require(plainAudio.count == 2, "screen-only composition retains all audio")

        let rotatedURL = directory.appendingPathComponent("rotated.mov")
        try await movie(to: rotatedURL, width: 80, height: 40, duration: 5, camera: true,
                        transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 40, ty: 0))
        var rotated = RecordingProject(screenFilename: "screen.mov", cameraFilename: "rotated.mov", duration: 5)
        rotated.state.pipKeyframes = [PIPKeyframe(time: 0, placement: PIPPlacement(x: 1, y: 1, scale: 0.25))]
        let rotatedRender = try await ProjectRenderer.makePreview(project: rotated, directory: directory)
        try require(abs(rotatedRender.cameraAspect - 0.5) < 0.0001, "camera preferred transform determines aspect")
        try await frame(rotatedRender, at: 0.5, expected: CGRect(x: 120, y: 40, width: 40, height: 80))

        var tinyOverlap = project
        tinyOverlap.cameraOffset = 4.999999
        _ = try await ProjectRenderer.makePreview(project: tinyOverlap, directory: directory)

        phase = "geometryChecks"
        try await geometryChecks(project: project, directory: directory)
        phase = "draftChecks"
        try await draftChecks(project: project, directory: directory)
        phase = "zoomChecks"
        try await zoomChecks(directory: directory)
        phase = "cursorChecks"
        try await cursorChecks(directory: directory)

        project.state.trimStart = 1
        project.state.trimEnd = 3.5
        let destination = directory.appendingPathComponent("export.mp4")
        try await ProjectRenderer.export(project: project, directory: directory, to: destination)
        let exported = AVURLAsset(url: destination)
        let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
        try require(!exportedAudio.isEmpty, "export retains recorded audio")
        let exportedDuration = try await exported.load(.duration).seconds
        try require(abs(exportedDuration - 2.5) < 1.0 / 30, "trim export duration")
        let generator = AVAssetImageGenerator(asset: exported)
        defer { generator.cancelAllCGImageGeneration() }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (firstImage, _) = try await generator.image(at: .zero)
        try checkBounds(firstImage, expected: CGRect(x: 120, y: 0, width: 40, height: 20))
        let (middleImage, _) = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600))
        try checkBounds(middleImage, expected: CGRect(x: 50, y: 45, width: 60, height: 30), yellow: true)
        do {
            try await ProjectRenderer.export(project: project, directory: directory, to: screen)
            throw CheckError.failed("renderer overwrote an original")
        } catch ProjectRenderer.RenderError.destinationExists { }
        do {
            try await ProjectRenderer.export(project: project, directory: directory, to: destination)
            throw CheckError.failed("renderer overwrote an existing export")
        } catch ProjectRenderer.RenderError.destinationExists { }
        try require(try Data(contentsOf: screen) == originalScreen, "screen source remains byte-identical")
        try require(try Data(contentsOf: camera) == originalCamera, "camera source remains byte-identical")
        print("Project renderer checks passed (editable cursor/clicks, manual/source zoom/pan, jump, easing, timed shapes, repositionable crops, circle alpha, orientation, sync offsets, independent audio tracks, trim, preview/export parity, source preservation).")
    }

    private static func cursorChecks(directory: URL) async throws {
        let recording = CursorRecording(duration: 5, logicalWidth: 160, logicalHeight: 120,
            samples: [CursorSample(time: 0, x: 0.5, y: 0.3), CursorSample(time: 5, x: 0.5, y: 0.3)], clicks: [])
        let cursorURL = directory.appendingPathComponent("cursor.json")
        try recording.write(to: cursorURL)
        let originalCursor = try Data(contentsOf: cursorURL)
        var project = RecordingProject(screenFilename: "screen.mov", cursorFilename: "cursor.json", duration: 5)
        project.state.cursorStyle = CursorStyle(visible: true, size: 1.5, smoothing: 0, clickHighlight: false)
        let normal = try await image(project, directory: directory, at: 0.5)
        guard let normalBounds = try matchingBounds(normal, matches: { $0 > 180 && $1 > 180 && $2 > 180 }) else {
            throw CheckError.failed("editable cursor is visible")
        }
        try require(abs(normalBounds.minX - 80) <= 3 && abs(normalBounds.minY - 36) <= 3,
                    "cursor tip hotspot remains on recorded source point: \(normalBounds)")
        try require(normalBounds.width > 20 && normalBounds.height > 30, "default pointer is large and readable")
        try pixel(normal, x: 83, y: 46, equals: [255, 255, 255])
        let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
        let sources = try await preparedSources(rendered, at: CMTime(seconds: 0.5, preferredTimescale: 600))
        var larger = project.state
        larger.cursorStyle.size = 3
        let largeImage = try await ProjectRenderer.renderLivePreview(sources, applying: larger)
        guard let largerBounds = try matchingBounds(largeImage, matches: { $0 > 180 && $1 > 180 && $2 > 180 }) else {
            throw CheckError.failed("enlarged live cursor is visible")
        }
        try require(abs(largerBounds.width - normalBounds.width * 2) <= 4 &&
                    abs(largerBounds.height - normalBounds.height * 2) <= 4,
                    "cursor size scales while retaining its source hotspot")
        var hidden = project.state
        hidden.cursorStyle.visible = false
        let hiddenImage = try await ProjectRenderer.renderLivePreview(sources, applying: hidden)
        try blueOnly(hiddenImage)
        var zoomed = project
        zoomed.state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 2, x: 0.7, y: 0.5)]
        let zoomImage = try await image(zoomed, directory: directory, at: 0.5)
        guard let zoomBounds = try matchingBounds(zoomImage, matches: { $0 > 180 && $1 > 180 && $2 > 180 }) else {
            throw CheckError.failed("zoomed cursor is visible")
        }
        try require(abs(zoomBounds.minX - (16 + 2 * (normalBounds.minX - 80))) <= 2 &&
                    abs(zoomBounds.minY - (12 + 2 * (normalBounds.minY - 36))) <= 2 &&
                    abs(zoomBounds.width - normalBounds.width * 2) <= 4,
                    "cursor position and size follow the screen zoom/pan viewport: \(zoomBounds)")
        let zoomLive = try await ProjectRenderer.renderLivePreview(sources, applying: zoomed.state)
        let zoomDifference = zip(try rgba(zoomLive), try rgba(zoomImage)).map { abs(Int($0) - Int($1)) }.max() ?? 0
        try require(zoomDifference <= 1, "cached cursor/zoom graph matches saved rendering")

        // Camera overlays are composed after the cursor, so the pointer cannot
        // float over a presenter's face when it passes beneath that frame.
        project.cameraFilename = "camera.mov"
        project.state.pipKeyframes = [PIPKeyframe(time: 0,
            placement: PIPPlacement(x: 1, y: 35.0 / 80, scale: 0.5))]
        let occluded = try await image(project, directory: directory, at: 0.5)
        try require(try matchingBounds(occluded, matches: { $0 > 180 && $1 > 180 && $2 > 180 }) == nil,
                    "camera overlay covers cursor pixels")
        project.cameraFilename = nil

        let invisible = CursorRecording(duration: 5, logicalWidth: 160, logicalHeight: 120,
            samples: [CursorSample(time: 0, x: 0.5, y: 0.5, visible: false),
                      CursorSample(time: 5, x: 0.5, y: 0.5, visible: false)],
            clicks: [CursorClick(time: 0.25, x: 0.5, y: 0.5, button: 0)])
        try invisible.write(to: directory.appendingPathComponent("clicks.json"))
        project.cursorFilename = "clicks.json"
        project.state.cursorStyle.clickHighlight = true
        let click = try await image(project, directory: directory, at: 0.35)
        try pixel(click, x: 80, y: 60, equals: [0, 0, 255])
        try require(try matchingBounds(click, matches: { $0 < 150 && $1 > 40 && $2 > 180 }) != nil,
                    "recorded click creates a visible hollow pulse even after pointer leaves source")
        project.state.cursorStyle.clickHighlight = false
        let noClick = try await image(project, directory: directory, at: 0.35)
        try blueOnly(noClick)
        project.state.cursorStyle.clickHighlight = true
        let expired = try await image(project, directory: directory, at: 0.8)
        try blueOnly(expired)
        project.state.cursorStyle.visible = false
        let noCursor = try await image(project, directory: directory, at: 0.35)
        try blueOnly(noCursor)

        let jitter = CursorRecording(duration: 5, logicalWidth: 160, logicalHeight: 120,
            samples: [CursorSample(time: 0, x: 0.2, y: 0.2), CursorSample(time: 0.49, x: 0.2, y: 0.2),
                      CursorSample(time: 0.5, x: 0.8, y: 0.2), CursorSample(time: 0.51, x: 0.2, y: 0.2),
                      CursorSample(time: 5, x: 0.2, y: 0.2)], clicks: [])
        try jitter.write(to: directory.appendingPathComponent("jitter.json"))
        project.cursorFilename = "jitter.json"
        project.state.cursorStyle = CursorStyle(visible: true, size: 1.5, smoothing: 0, clickHighlight: false)
        let raw = try await image(project, directory: directory, at: 0.5)
        project.state.cursorStyle.smoothing = 1
        let smoothed = try await image(project, directory: directory, at: 0.5)
        guard let rawBounds = try matchingBounds(raw, matches: { $0 > 180 && $1 > 180 && $2 > 180 }),
              let smoothBounds = try matchingBounds(smoothed, matches: { $0 > 180 && $1 > 180 && $2 > 180 }) else {
            throw CheckError.failed("smoothed cursor rendered")
        }
        try require(smoothBounds.minX < rawBounds.minX - 40, "offline smoothing suppresses isolated pointer jitter")

        project.cursorFilename = "cursor.json"
        project.state.cursorStyle.smoothing = 0
        project.state.trimStart = 0.5
        project.state.trimEnd = 1.0
        let exportURL = directory.appendingPathComponent("cursor-export.mp4")
        try await ProjectRenderer.export(project: project, directory: directory, to: exportURL)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exportURL))
        defer { generator.cancelAllCGImageGeneration() }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (exported, _) = try await generator.image(at: .zero)
        try colorBounds(exported, color: [255, 255, 255], equals: normalBounds)
        try require(try Data(contentsOf: cursorURL) == originalCursor, "pointer edits preserve immutable recorded metadata")
    }

    private static func matchingBounds(_ image: CGImage, matches: (Int, Int, Int) -> Bool) throws -> CGRect? {
        let bytes = try rgba(image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                if matches(Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])) {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        return maxX >= 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
    }

    private static func blueOnly(_ image: CGImage) throws {
        let bytes = try rgba(image)
        for offset in Swift.stride(from: 0, to: bytes.count, by: 4) {
            try require(bytes[offset] < 40 && bytes[offset + 1] < 40 && bytes[offset + 2] > 180,
                        "hidden or expired pointer pixels must reveal the original screen")
        }
    }

    private static func zoomChecks(directory: URL) async throws {
        let source = directory.appendingPathComponent("zoom-screen.mov")
        try await movie(to: source, width: 160, height: 120, duration: 5, camera: false, zoomMarkers: true)
        let original = try Data(contentsOf: source)
        var project = RecordingProject(screenFilename: "zoom-screen.mov", duration: 5)
        project.state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 2, x: 0.5, y: 0.5)]
        phase = "centered zoom rendering"
        let center = try await image(project, directory: directory, at: 0.5)
        try colorBounds(center, color: [255, 0, 0], equals: CGRect(x: 20, y: 20, width: 20, height: 20))
        try opaqueEdges(center)
        for (x, y, color, expected) in [
            (0.0, 0.0, [255, 255, 0], CGRect(x: 20, y: 20, width: 20, height: 20)),
            (1.0, 0.0, [0, 255, 255], CGRect(x: 60, y: 40, width: 20, height: 20)),
            (0.0, 1.0, [255, 255, 255], CGRect(x: 40, y: 60, width: 20, height: 20)),
            (1.0, 1.0, [255, 0, 255], CGRect(x: 120, y: 80, width: 20, height: 20))
        ] {
            phase = "corner zoom rendering at \(x),\(y)"
            project.state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 2, x: x, y: y)]
            let corner = try await image(project, directory: directory, at: 0.5)
            try colorBounds(corner, color: color, equals: expected)
            try opaqueEdges(corner)
        }
        project.state.zoomKeyframes = [ZoomKeyframe(time: 0, scale: 3, x: 1, y: 1)]
        let close = try await image(project, directory: directory, at: 0.5)
        try colorBounds(close, color: [255, 0, 255], equals: CGRect(x: 100, y: 60, width: 30, height: 30))
        try opaqueEdges(close)

        // The screen camera moves; the presenter's camera remains anchored to
        // the output canvas and its source pixels are never magnified with it.
        project.cameraFilename = "camera.mov"
        project.state.pipKeyframes = [PIPKeyframe(time: 0, placement: PIPPlacement(x: 1, y: 1, scale: 0.25))]
        let withPIP = try await image(project, directory: directory, at: 0.5)
        try checkBounds(withPIP, expected: CGRect(x: 120, y: 100, width: 40, height: 20))
        project.cameraFilename = nil
        project.state.zoomKeyframes = [
            ZoomKeyframe(time: 0),
            ZoomKeyframe(time: 1, scale: 2, x: 0.5, y: 0.5),
            ZoomKeyframe(time: 3, scale: 3, x: 1, y: 1, transition: .smooth, duration: 1)
        ]
        let beforeJump = try await image(project, directory: directory, at: 29.0 / 30)
        try colorBounds(beforeJump, color: [255, 0, 0], equals: CGRect(x: 50, y: 40, width: 10, height: 10))
        let jump = try await image(project, directory: directory, at: 1)
        try colorBounds(jump, color: [255, 0, 0], equals: CGRect(x: 20, y: 20, width: 20, height: 20))
        let smooth = try await image(project, directory: directory, at: 2.5)
        try colorBounds(smooth, color: [255, 128, 0], equals: CGRect(x: 63.333, y: 35, width: 25, height: 25))
        let arrived = try await image(project, directory: directory, at: 3)
        try colorBounds(arrived, color: [255, 0, 255], equals: CGRect(x: 100, y: 60, width: 30, height: 30))

        var base = project
        base.state.zoomKeyframes = []
        let rendered = try await ProjectRenderer.makePreview(project: base, directory: directory)
        phase = "zoom live-source preparation"
        let sources = try await preparedSources(rendered, at: CMTime(seconds: 2.5, preferredTimescale: 600))
        let live = try await ProjectRenderer.renderLivePreview(sources, applying: project.state)
        let liveBytes = try rgba(live), smoothBytes = try rgba(smooth)
        let maxDifference = zip(liveBytes, smoothBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        try require(maxDifference <= 1, "cached live zoom/pan differs beyond 8-bit output rounding: \(maxDifference)")
        let unzoomed = try await ProjectRenderer.renderLivePreview(sources, applying: base.state)
        try colorBounds(unzoomed, color: [255, 0, 0], equals: CGRect(x: 50, y: 40, width: 10, height: 10))

        project.state.trimStart = 2.5
        project.state.trimEnd = 3.5
        let exportURL = directory.appendingPathComponent("zoom-export.mp4")
        phase = "zoom export"
        try await ProjectRenderer.export(project: project, directory: directory, to: exportURL)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exportURL))
        defer { generator.cancelAllCGImageGeneration() }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (exportStart, _) = try await generator.image(at: .zero)
        try colorBounds(exportStart, color: [255, 128, 0], equals: CGRect(x: 63.333, y: 35, width: 25, height: 25))
        let (exportEnd, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        try colorBounds(exportEnd, color: [255, 0, 255], equals: CGRect(x: 100, y: 60, width: 30, height: 30))
        try require(try Data(contentsOf: source) == original, "manual zoom preserves original recording bytes")
    }

    private static func colorBounds(_ image: CGImage, color: [Int], equals expected: CGRect) throws {
        let bytes = try rgba(image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                if (0..<3).allSatisfy({ abs(Int(bytes[offset + $0]) - color[$0]) < 50 }) {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        let actual = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        try require(maxX >= 0 && abs(actual.minX - expected.minX) <= 2 && abs(actual.minY - expected.minY) <= 2 &&
                    abs(actual.width - expected.width) <= 3 && abs(actual.height - expected.height) <= 3,
                    "zoomed marker bounds \(actual), expected \(expected)")
    }

    private static func opaqueEdges(_ image: CGImage) throws {
        let bytes = try rgba(image)
        for y in 0..<image.height {
            for x in 0..<image.width where x == 0 || x == image.width - 1 || y == 0 || y == image.height - 1 {
                let offset = (y * image.width + x) * 4
                try require(bytes[offset + 3] == 255 && max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 100,
                            "screen zoom edge (\(x),\(y)) RGBA=\(Array(bytes[offset..<(offset + 4)])) must remain opaque and covered")
            }
        }
    }

    private static func draftChecks(project: RecordingProject, directory: URL) async throws {
        var baseProject = project
        baseProject.state.pipKeyframes = [PIPKeyframe(time: 0, placement: PIPPlacement(x: 0, y: 0, scale: 0.25))]
        let base = try await ProjectRenderer.makePreview(project: baseProject, directory: directory)
        var state = baseProject.state
        state.pipKeyframes[0].placement = PIPPlacement(x: 1, y: 1, scale: 0.4, shape: .circle)
        let draft = ProjectRenderer.preview(base, applying: state)
        try require(draft.asset === base.asset, "live draft reuses loaded source composition")
        try require(draft.screenSize == base.screenSize && draft.cameraAspect == base.cameraAspect,
                    "draft preserves source canvas and camera metadata")
        try require(draft.videoComposition.frameDuration == base.videoComposition.frameDuration &&
                    draft.videoComposition.renderSize == base.videoComposition.renderSize &&
                    draft.videoComposition.colorPrimaries == base.videoComposition.colorPrimaries &&
                    draft.videoComposition.colorTransferFunction == base.videoComposition.colorTransferFunction &&
                    draft.videoComposition.colorYCbCrMatrix == base.videoComposition.colorYCbCrMatrix,
                    "draft preserves frame timing and color settings")
        let draftImage = try await image(draft, at: 0.5)
        try checkCircle(draftImage, frame: CGRect(x: 96, y: 56, width: 64, height: 64), color: [0, 255, 0])
        try pixel(draftImage, x: 20, y: 10, equals: [0, 0, 255])
        var savedProject = baseProject
        savedProject.state = state
        let savedImage = try await image(savedProject, directory: directory, at: 0.5)
        try require(try rgba(draftImage) == rgba(savedImage), "live draft pixels equal a fully rebuilt saved edit")
        var hidden = state
        hidden.pipKeyframes[0].placement.visible = false
        let hiddenImage = try await image(ProjectRenderer.preview(base, applying: hidden), at: 0.5)
        try checkBounds(hiddenImage, expected: nil)
        let baseImage = try await image(base, at: 0.5)
        try checkBounds(baseImage, expected: CGRect(x: 0, y: 0, width: 40, height: 20))
        try require((base.videoComposition.instructions.first as? PIPCompositionInstruction)?.state == baseProject.state,
                    "draft updates never mutate the saved render snapshot")
        try require((draft.videoComposition.instructions.first as? PIPCompositionInstruction)?.state == state,
                    "a later draft never mutates an earlier in-flight render snapshot")

        // Moving the source crop uses the same loaded source frames and exact
        // renderer as a persisted edit, rather than stretching a cached PIP.
        var croppedProject = baseProject
        croppedProject.cameraFilename = "patterned.mov"
        croppedProject.state.pipKeyframes[0].placement.shape = .square
        croppedProject.state.pipKeyframes[0].placement.crop = PIPCrop(x: 0, y: 0.5)
        let croppedBase = try await ProjectRenderer.makePreview(project: croppedProject, directory: directory)
        var cropDraft = croppedProject.state
        cropDraft.pipKeyframes[0].placement.shape = .rectangle
        cropDraft.pipKeyframes[0].placement.aspectRatio = 0.5
        cropDraft.pipKeyframes[0].placement.crop.x = 1
        let cropPreview = ProjectRenderer.preview(croppedBase, applying: cropDraft)
        let cropImage = try await image(cropPreview, at: 0.5)
        try pixel(cropImage, x: 20, y: 20, equals: [0, 255, 0])
        try pixel(cropImage, x: 20, y: 60, equals: [255, 0, 255])
        croppedProject.state = cropDraft
        let cropSaved = try await image(croppedProject, directory: directory, at: 0.5)
        try require(try rgba(cropImage) == rgba(cropSaved), "draft crop and aspect pixels equal the saved edit")

        let frozenTime = CMTime(seconds: 0.5, preferredTimescale: 600)
        let liveSources = try await preparedSources(base, at: frozenTime)
        try require(liveSources.time == frozenTime, "live source pair remains tied to its frozen playhead")
        let liveImage = try await ProjectRenderer.renderLivePreview(liveSources, applying: savedProject.state)
        try require(try rgba(liveImage) == rgba(savedImage), "cached source move/resize/circle pixels equal saved composition")
        try pixel(liveImage, x: 20, y: 10, equals: [0, 0, 255])
        let liveHidden = try await ProjectRenderer.renderLivePreview(liveSources, applying: hidden)
        try checkBounds(liveHidden, expected: nil)
        let smallLive = try await ProjectRenderer.renderLivePreview(liveSources, applying: savedProject.state,
                                                                   maximumSize: CGSize(width: 80, height: 60))
        try require(smallLive.width == 80 && smallLive.height == 60, "cached source drafts respect bounded output size")
        try checkCircle(smallLive, frame: CGRect(x: 48, y: 28, width: 32, height: 32), color: [0, 255, 0])

        let liveCropSources = try await preparedSources(croppedBase, at: frozenTime)
        let liveCrop = try await ProjectRenderer.renderLivePreview(liveCropSources, applying: cropDraft)
        try require(try rgba(liveCrop) == rgba(cropSaved), "cached raw source crop/aspect pixels equal saved composition")
        let laterSources = try await preparedSources(base, at: CMTime(seconds: 2.5, preferredTimescale: 600))
        let laterImage = try await ProjectRenderer.renderLivePreview(laterSources, applying: savedProject.state)
        try checkCircle(laterImage, frame: CGRect(x: 96, y: 56, width: 64, height: 64), color: [255, 255, 0])
        let earlierAgain = try await ProjectRenderer.renderLivePreview(liveSources, applying: savedProject.state)
        try require(try rgba(earlierAgain) == rgba(liveImage), "another playhead never replaces frozen source buffers")

        var delayed = baseProject
        delayed.cameraOffset = 1
        let delayedRender = try await ProjectRenderer.makePreview(project: delayed, directory: directory)
        let beforeCamera = try await preparedSources(delayedRender, at: frozenTime)
        let beforeImage = try await ProjectRenderer.renderLivePreview(beforeCamera, applying: savedProject.state)
        try checkBounds(beforeImage, expected: nil)
        var ended = baseProject
        ended.cameraOffset = -2
        let endedRender = try await ProjectRenderer.makePreview(project: ended, directory: directory)
        let afterCamera = try await preparedSources(endedRender, at: CMTime(seconds: 3.5, preferredTimescale: 600))
        let afterImage = try await ProjectRenderer.renderLivePreview(afterCamera, applying: savedProject.state)
        try checkBounds(afterImage, expected: nil)

        // Preparation captures raw camera independently of its current visibility.
        var initiallyHidden = baseProject
        initiallyHidden.state.pipKeyframes[0].placement.visible = false
        let hiddenRender = try await ProjectRenderer.makePreview(project: initiallyHidden, directory: directory)
        let hiddenSources = try await preparedSources(hiddenRender, at: frozenTime)
        let revealed = try await ProjectRenderer.renderLivePreview(hiddenSources, applying: savedProject.state)
        try require(try rgba(revealed) == rgba(liveImage), "hidden source camera can be revealed without another decode")

        // A paused playhead need not fall on a nominal 30 fps boundary.
        var betweenFrames = baseProject
        betweenFrames.state.pipKeyframes.append(PIPKeyframe(time: 0.75,
            placement: PIPPlacement(x: 1, y: 1, scale: 0.4), transition: .smooth, duration: 0.75))
        let arbitraryTime = CMTime(seconds: 0.5173, preferredTimescale: 1_000_000)
        let arbitrarySources = try await preparedSources(base, at: arbitraryTime)
        let arbitraryLive = try await ProjectRenderer.renderLivePreview(arbitrarySources, applying: betweenFrames.state)
        let arbitrarySaved = try await image(betweenFrames, directory: directory, at: arbitraryTime.seconds)
        try require(try rgba(arbitraryLive) == rgba(arbitrarySaved), "cached source edits preserve sub-frame frozen playhead timing")

        let cancelledPreparation = Task { @MainActor in
            try await ProjectRenderer.prepareLiveSources(base, at: frozenTime)
        }
        cancelledPreparation.cancel()
        do {
            _ = try await cancelledPreparation.value
            throw CheckError.failed("cancelled source preparation returned a stale pair")
        } catch is CancellationError { }
        try focusedCaptureChecks(base, at: frozenTime)

        let clock = ContinuousClock()
        let beginning = clock.now
        for index in 0..<1_000 {
            state.pipKeyframes[0].placement.x = Double(index % 100) / 100
            let next = ProjectRenderer.preview(base, applying: state)
            try require(next.asset === base.asset, "every transient edit reuses loaded media")
        }
        print("Draft compositor check: 1000 source-reusing snapshots in \(beginning.duration(to: clock.now)).")
    }

    private static func focusedCaptureChecks(_ rendered: RenderedProject, at time: CMTime) throws {
        guard let instruction = rendered.videoComposition.instructions.first as? PIPCompositionInstruction else {
            throw CheckError.failed("source capture instruction")
        }
        var dummy: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &dummy) == kCVReturnSuccess,
              let dummy else { throw CheckError.failed("source capture test buffer") }
        let wrongTime = FocusedFrameCapture(target: time, frameDuration: rendered.videoComposition.frameDuration)
        wrongTime.capture(screen: dummy, camera: nil, at: .zero, instruction: instruction)
        try require(wrongTime.finish() == nil, "prefetched frames from another playhead are never retained")
        let cancelled = FocusedFrameCapture(target: time, frameDuration: rendered.videoComposition.frameDuration)
        cancelled.invalidate()
        cancelled.capture(screen: dummy, camera: dummy, at: time, instruction: instruction)
        try require(cancelled.finish() == nil, "late decoder frames cannot repopulate a cancelled source cache")
        let completed = FocusedFrameCapture(target: time, frameDuration: rendered.videoComposition.frameDuration)
        completed.capture(screen: dummy, camera: nil, at: time, instruction: instruction)
        try require(completed.finish() != nil && completed.finish() == nil, "focused source ownership transfers only once")
        completed.capture(screen: dummy, camera: dummy, at: time, instruction: instruction)
        try require(completed.finish() == nil, "completed source preparation rejects late callbacks")
    }

    /// Decode through the same native player path used by the editor. The
    /// output is the display consumer for this headless test; no capture device
    /// or separate custom-composition image generator is involved.
    @MainActor
    private final class NativeFrameConsumer {
        let rendered: RenderedProject
        private let item: AVPlayerItem
        private let output: AVPlayerItemVideoOutput
        private let player: AVPlayer
        private let context = CIContext(options: [.cacheIntermediates: false])
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        init(rendered: RenderedProject, target: CMTime) {
            self.rendered = rendered
            rendered.previewFrames.request(at: target)
            item = AVPlayerItem(asset: rendered.asset)
            item.videoComposition = rendered.videoComposition
            item.seekingWaitsForVideoCompositionRendering = true
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            output.suppressesPlayerRendering = true
            item.add(output)
            player = AVPlayer(playerItem: item)
            player.isMuted = true
        }

        func close() {
            player.pause()
            item.remove(output)
            player.replaceCurrentItem(with: nil)
        }

        func image(at target: CMTime) async throws -> CGImage {
            try Task.checkCancellation()
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while item.status == .unknown, ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard item.status == .readyToPlay else {
                throw item.error ?? CheckError.failed("native renderer item is ready")
            }
            rendered.previewFrames.request(at: target)
            guard await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) else {
                throw item.error ?? CheckError.failed("native renderer seek completed at \(target.seconds)s")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if item.status == .failed { throw item.error ?? CheckError.failed("native renderer item failed") }
                if let error = player.error { throw error }
                let result: CGImage? = autoreleasepool {
                    var display = CMTime.invalid
                    guard let buffer = output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: &display),
                          display.seconds.isFinite,
                          abs(display.seconds - target.seconds) <= rendered.videoComposition.frameDuration.seconds + 0.000_001 else { return nil }
                    let image = CIImage(cvPixelBuffer: buffer)
                    return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
                }
                if let result { return result }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw CheckError.failed("native renderer supplied no frame at \(target.seconds)s")
        }
    }

    private static func image(_ rendered: RenderedProject, at seconds: Double) async throws -> CGImage {
        let target = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        let consumer: NativeFrameConsumer
        if let cachedConsumer, cachedConsumer.rendered.asset === rendered.asset,
           cachedConsumer.rendered.videoComposition === rendered.videoComposition {
            consumer = cachedConsumer
        } else {
            cachedConsumer?.close()
            consumer = NativeFrameConsumer(rendered: rendered, target: target)
            cachedConsumer = consumer
        }
        return try await consumer.image(at: target)
    }

    private static func preparedSources(_ rendered: RenderedProject, at time: CMTime) async throws -> LivePreviewSources {
        _ = try await image(rendered, at: time.seconds)
        return try await ProjectRenderer.prepareLiveSources(rendered, at: time)
    }

    private static func geometryChecks(project: RecordingProject, directory: URL) async throws {
        let patterned = directory.appendingPathComponent("patterned.mov")
        try await movie(to: patterned, width: 80, height: 40, duration: 5, camera: true, pattern: true)
        var cropProject = project
        cropProject.cameraFilename = "patterned.mov"
        func single(_ placement: PIPPlacement) -> RecordingProject {
            var value = cropProject
            value.state.pipKeyframes = [PIPKeyframe(time: 0, placement: placement)]
            return value
        }
        let red = [255, 0, 0], green = [0, 255, 0], yellow = [255, 255, 0], magenta = [255, 0, 255]
        let left = single(PIPPlacement(x: 0, y: 0, scale: 0.25, shape: .square, crop: PIPCrop(x: 0, y: 0.5)))
        let leftImage = try await image(left, directory: directory, at: 0.5)
        try pixel(leftImage, x: 10, y: 10, equals: red)
        try pixel(leftImage, x: 10, y: 30, equals: yellow)
        var internallyZoomed = left
        internallyZoomed.state.pipKeyframes[0].placement.sourceZoom = 2
        internallyZoomed.state.pipKeyframes[0].placement.crop.y = 0
        let internalClose = try await image(internallyZoomed, directory: directory, at: 0.5)
        try pixel(internalClose, x: 10, y: 10, equals: red)
        try pixel(internalClose, x: 10, y: 30, equals: red)
        try pixel(internalClose, x: 45, y: 30, equals: [0, 0, 255])
        internallyZoomed.state.pipKeyframes = [left.state.pipKeyframes[0],
            PIPKeyframe(time: 2, placement: internallyZoomed.state.pipKeyframes[0].placement,
                        transition: .smooth, duration: 1)]
        let internalBefore = try await image(internallyZoomed, directory: directory, at: 1)
        try pixel(internalBefore, x: 10, y: 30, equals: yellow)
        let internalDuring = try await image(internallyZoomed, directory: directory, at: 1.5)
        try pixel(internalDuring, x: 10, y: 20, equals: red)
        try pixel(internalDuring, x: 10, y: 35, equals: yellow)
        let internalAfter = try await image(internallyZoomed, directory: directory, at: 2)
        try pixel(internalAfter, x: 10, y: 30, equals: red)
        let internalBase = try await ProjectRenderer.makePreview(project: left, directory: directory)
        let internalSources = try await preparedSources(internalBase, at: CMTime(seconds: 1.5, preferredTimescale: 600))
        let internalLive = try await ProjectRenderer.renderLivePreview(internalSources, applying: internallyZoomed.state)
        let internalDifference = zip(try rgba(internalLive), try rgba(internalDuring)).map { abs(Int($0) - Int($1)) }.max() ?? 0
        try require(internalDifference <= 1, "camera source zoom shares live/saved viewport rendering")
        let right = single(PIPPlacement(x: 0, y: 0, scale: 0.25, shape: .square, crop: PIPCrop(x: 1, y: 0.5)))
        let rightImage = try await image(right, directory: directory, at: 0.5)
        try pixel(rightImage, x: 10, y: 10, equals: green)
        try pixel(rightImage, x: 10, y: 30, equals: magenta)
        let wideTop = single(PIPPlacement(x: 0, y: 0, scale: 0.25, shape: .rectangle,
                                          aspectRatio: 4, crop: PIPCrop(x: 0.5, y: 0)))
        let wideTopImage = try await image(wideTop, directory: directory, at: 0.5)
        try pixel(wideTopImage, x: 10, y: 3, equals: red)
        try pixel(wideTopImage, x: 30, y: 3, equals: green)
        try pixel(wideTopImage, x: 10, y: 15, equals: [0, 0, 255])
        let wideBottom = single(PIPPlacement(x: 0, y: 0, scale: 0.25, shape: .rectangle,
                                             aspectRatio: 4, crop: PIPCrop(x: 0.5, y: 1)))
        let wideBottomImage = try await image(wideBottom, directory: directory, at: 0.5)
        try pixel(wideBottomImage, x: 10, y: 3, equals: yellow)
        try pixel(wideBottomImage, x: 30, y: 3, equals: magenta)
        let portrait = single(PIPPlacement(x: 0, y: 0, scale: 0.25, shape: .rectangle,
                                           aspectRatio: 0.5, crop: PIPCrop(x: 1, y: 0.5)))
        let portraitImage = try await image(portrait, directory: directory, at: 0.5)
        try pixel(portraitImage, x: 20, y: 20, equals: green)
        try pixel(portraitImage, x: 20, y: 60, equals: magenta)
        try pixel(portraitImage, x: 45, y: 20, equals: [0, 0, 255])

        // Preferred transforms are applied before the crop's top-left axes.
        let rotated = directory.appendingPathComponent("patterned-rotated.mov")
        try await movie(to: rotated, width: 80, height: 40, duration: 5, camera: true,
                        transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 40, ty: 0), pattern: true)
        var rotatedTop = left
        rotatedTop.cameraFilename = "patterned-rotated.mov"
        rotatedTop.state.pipKeyframes[0].placement.crop = PIPCrop(x: 0.5, y: 0)
        let topImage = try await image(rotatedTop, directory: directory, at: 0.5)
        try pixel(topImage, x: 10, y: 10, equals: yellow)
        try pixel(topImage, x: 30, y: 10, equals: red)
        rotatedTop.state.pipKeyframes[0].placement.crop.y = 1
        let bottomImage = try await image(rotatedTop, directory: directory, at: 0.5)
        try pixel(bottomImage, x: 10, y: 10, equals: magenta)
        try pixel(bottomImage, x: 30, y: 10, equals: green)
        guard let rawFrame = try await ProjectRenderer.cameraFrame(project: rotatedTop, directory: directory, at: 0.5) else {
            throw CheckError.failed("raw oriented camera frame")
        }
        try require(rawFrame.width == 40 && rawFrame.height == 80, "raw frame honors preferred orientation")
        try pixel(rawFrame, x: 10, y: 10, equals: yellow)
        try pixel(rawFrame, x: 10, y: 60, equals: magenta)

        // Continuous crop movement is sampled at the exact composition time.
        var cropMotion = left
        cropMotion.state.pipKeyframes.append(PIPKeyframe(
            time: 2, placement: right.state.pipKeyframes[0].placement, transition: .smooth, duration: 2
        ))
        let cropMiddle = try await image(cropMotion, directory: directory, at: 1)
        try pixel(cropMiddle, x: 5, y: 10, equals: red)
        try pixel(cropMiddle, x: 35, y: 10, equals: green)

        var timed = project
        timed.state.pipKeyframes = [
            PIPKeyframe(time: 0, placement: PIPPlacement(x: 0, y: 0, scale: 0.25, shape: .rectangle, aspectRatio: 2)),
            PIPKeyframe(time: 1, placement: PIPPlacement(x: 1, y: 0, scale: 0.25, shape: .square)),
            PIPKeyframe(time: 3, placement: PIPPlacement(x: 0, y: 1, scale: 0.5, shape: .circle), transition: .smooth, duration: 1),
            PIPKeyframe(time: 4, placement: PIPPlacement(x: 1, y: 0, scale: 0.25, shape: .circle), transition: .smooth, duration: 1)
        ]
        let timedRender = try await ProjectRenderer.makePreview(project: timed, directory: directory)
        try await frame(timedRender, at: 29.0 / 30, expected: CGRect(x: 0, y: 0, width: 40, height: 20))
        try await frame(timedRender, at: 1, expected: CGRect(x: 120, y: 0, width: 40, height: 40))
        let beforeCircle = try await image(timed, directory: directory, at: 2.5)
        try pixel(beforeCircle, x: 52, y: 32, equals: yellow)
        let circle = try await image(timed, directory: directory, at: 3)
        try checkCircle(circle, frame: CGRect(x: 0, y: 40, width: 80, height: 80), color: yellow)
        let movingCircle = try await image(timed, directory: directory, at: 3.5)
        try checkCircle(movingCircle, frame: CGRect(x: 50, y: 30, width: 60, height: 60), color: yellow)
        let finalCircle = try await image(timed, directory: directory, at: 4)
        try checkCircle(finalCircle, frame: CGRect(x: 120, y: 0, width: 40, height: 40), color: yellow)

        // Alpha reveals different screen content behind each circle corner.
        let patternedScreen = directory.appendingPathComponent("patterned-screen.mov")
        try await movie(to: patternedScreen, width: 160, height: 120, duration: 5, camera: false, pattern: true)
        var alphaProject = timed
        alphaProject.screenFilename = "patterned-screen.mov"
        alphaProject.state.pipKeyframes = [PIPKeyframe(time: 0, placement: PIPPlacement(x: 0.5, y: 0.5, scale: 0.5, shape: .circle))]
        let alphaImage = try await image(alphaProject, directory: directory, at: 0.5)
        try pixel(alphaImage, x: 42, y: 22, equals: red)
        try pixel(alphaImage, x: 118, y: 22, equals: green)
        try pixel(alphaImage, x: 42, y: 98, equals: yellow)
        try pixel(alphaImage, x: 118, y: 98, equals: magenta)
        try pixel(alphaImage, x: 60, y: 50, equals: green)

        timed.state.trimStart = 3
        timed.state.trimEnd = 4.5
        let exportURL = directory.appendingPathComponent("circle-export.mp4")
        try await ProjectRenderer.export(project: timed, directory: directory, to: exportURL)
        let exportedGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: exportURL))
        defer { exportedGenerator.cancelAllCGImageGeneration() }
        exportedGenerator.requestedTimeToleranceBefore = .zero
        exportedGenerator.requestedTimeToleranceAfter = .zero
        let (first, _) = try await exportedGenerator.image(at: .zero)
        try checkCircle(first, frame: CGRect(x: 0, y: 40, width: 80, height: 80), color: yellow, requireAntialias: false)
        let (middle, _) = try await exportedGenerator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        try checkCircle(middle, frame: CGRect(x: 50, y: 30, width: 60, height: 60), color: yellow, requireAntialias: false)
    }

    private static func image(_ project: RecordingProject, directory: URL, at seconds: Double) async throws -> CGImage {
        let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
        return try await image(rendered, at: seconds)
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CheckError.failed("pixel context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int, equals expected: [Int]) throws {
        let bytes = try rgba(image)
        let index = (y * image.width + x) * 4
        let actual = [Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2])]
        try require(zip(actual, expected).allSatisfy { abs($0 - $1) <= 40 },
                    "pixel (\(x),\(y)) = \(actual), expected \(expected)")
    }

    private static func checkCircle(_ image: CGImage, frame: CGRect, color: [Int], requireAntialias: Bool = true) throws {
        try pixel(image, x: Int(frame.midX), y: Int(frame.midY), equals: color)
        try pixel(image, x: Int(frame.minX + 2), y: Int(frame.minY + 2), equals: [0, 0, 255])
        try pixel(image, x: Int(frame.maxX - 3), y: Int(frame.maxY - 3), equals: [0, 0, 255])
        try pixel(image, x: Int(frame.minX + frame.width * 0.25), y: Int(frame.minY + frame.height * 0.25), equals: color)
        if requireAntialias {
            let bytes = try rgba(image)
            var partialAlpha = false
            for y in Int(frame.minY)..<Int(frame.maxY) {
                for x in Int(frame.minX)..<Int(frame.maxX) {
                    let index = (y * image.width + x) * 4
                    if bytes[index + 1] > 15 && bytes[index + 1] < 240 && bytes[index + 2] > 15 && bytes[index + 2] < 240 {
                        partialAlpha = true
                    }
                }
            }
            try require(partialAlpha, "circle boundary has antialiased alpha")
        }
    }

    @MainActor
    private static func frame(_ rendered: RenderedProject, at seconds: Double, expected: CGRect?, yellow: Bool = false) async throws {
        phase = "source-frame rendering at \(seconds)s"
        let image = try await image(rendered, at: seconds)
        try checkBounds(image, expected: expected, yellow: yellow)
    }

    private static func checkBounds(_ image: CGImage, expected: CGRect?, yellow: Bool = false) throws {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CheckError.failed("image context") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let matches = rgba[offset + 1] > 150 && rgba[offset + 2] < 100 &&
                    (yellow ? rgba[offset] > 150 : rgba[offset] < 100)
                if matches {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        if let expected {
            let actual = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            try require(maxX >= 0 && abs(actual.minX - expected.minX) <= 2 && abs(actual.minY - expected.minY) <= 2 &&
                abs(actual.width - expected.width) <= 3 && abs(actual.height - expected.height) <= 3,
                "camera bounds \(actual), expected \(expected), yellow=\(yellow)")
        } else {
            try require(maxX < 0, "hidden/missing camera must not appear")
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckError.failed(message) }
    }

    private static func ready(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw writer.error ?? CheckError.failed("synthetic writer stopped")
            }
            guard Date() < deadline else { throw CheckError.failed("synthetic writer stalled on \(input.mediaType)") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func audioSamples(frame: Int, frequency: Double) throws -> CMSampleBuffer {
        let count = 1_600
        let samples = (0..<count).map { index in
            Float(sin(Double(frame * count + index) * frequency * 2 * .pi / 48_000) * 0.15)
        }
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        ) == noErr, let description else { throw CheckError.failed("audio description") }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 4,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { throw CheckError.failed("audio data buffer") }
        let copyStatus = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copyStatus == noErr else { throw CheckError.failed("audio samples copy") }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(frame * count), timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var size = 4
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer
        ) == noErr, let buffer else { throw CheckError.failed("audio sample buffer") }
        return buffer
    }

    private static func movie(to url: URL, width: Int, height: Int, duration: Int, camera: Bool, transform: CGAffineTransform = .identity, pattern: Bool = false, zoomMarkers: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            // Small color fiducials use 4:4:4; ordinary screen/camera fixtures
            // retain H264 with independent AAC tracks and MP4 export readback.
            AVVideoCodecKey: zoomMarkers ? AVVideoCodecType.proRes4444 : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        input.transform = transform
        writer.add(input)
        var audioInputs: [AVAssetWriterInput] = []
        if !camera {
            for _ in 0..<2 {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000
                ])
                writer.add(audio)
                audioInputs.append(audio)
            }
        }
        guard writer.startWriting() else { throw writer.error ?? CheckError.failed("start synthetic writer") }
        writer.startSession(atSourceTime: .zero)
        let video = Task { @MainActor in
            try await fillVideo(input, adaptor: adaptor, writer: writer, width: width, height: height, duration: duration, camera: camera, pattern: pattern, zoomMarkers: zoomMarkers)
        }
        var audioTasks: [Task<Void, any Error>] = []
        for (track, audio) in audioInputs.enumerated() {
            audioTasks.append(Task { @MainActor in
                    for index in 0..<(duration * 30) {
                        try await ready(audio, writer: writer)
                        guard audio.append(try audioSamples(frame: index, frequency: Double(440 * (track + 1)))) else {
                            throw writer.error ?? CheckError.failed("append synthetic audio")
                        }
                    }
                    audio.markAsFinished()
            })
        }
        for task in audioTasks { try await task.value }
        try await video.value
        writer.endSession(atSourceTime: CMTime(value: Int64(duration), timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CheckError.failed("finish synthetic writer") }
    }
    private static func fillVideo(_ input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, writer: AVAssetWriter,
                                  width: Int, height: Int, duration: Int, camera: Bool, pattern: Bool, zoomMarkers: Bool) async throws {
        for index in 0..<(duration * 30) {
            try await ready(input, writer: writer)
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw CheckError.failed("synthetic pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    base[offset] = camera ? 0 : 255
                    base[offset + 1] = camera ? 255 : 0
                    base[offset + 2] = camera && index >= 60 ? 255 : 0
                    base[offset + 3] = 255
                    if zoomMarkers {
                        let rgb: [UInt8]?
                        if (50..<60).contains(x), (40..<50).contains(y) { rgb = [255, 0, 0] }
                        else if (10..<20).contains(x), (10..<20).contains(y) { rgb = [255, 255, 0] }
                        else if (140..<150).contains(x), (100..<110).contains(y) { rgb = [255, 0, 255] }
                        else if (110..<120).contains(x), (20..<30).contains(y) { rgb = [0, 255, 255] }
                        else if (100..<110).contains(x), (70..<80).contains(y) { rgb = [255, 128, 0] }
                        else if (20..<30).contains(x), (90..<100).contains(y) { rgb = [255, 255, 255] }
                        else { rgb = nil }
                        if let rgb { base[offset] = rgb[2]; base[offset + 1] = rgb[1]; base[offset + 2] = rgb[0] }
                    }
                    if pattern {
                        let rgb: [UInt8]
                        if y < height / 2 { rgb = x < width / 2 ? [255, 0, 0] : [0, 255, 0] }
                        else { rgb = x < width / 2 ? [255, 255, 0] : [255, 0, 255] }
                        base[offset] = rgb[2]; base[offset + 1] = rgb[1]; base[offset + 2] = rgb[0]
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? CheckError.failed("append synthetic frame")
            }
        }
        input.markAsFinished()
    }

}
