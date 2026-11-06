@preconcurrency import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation

@main
@MainActor
struct ProjectRendererChecks {
    enum CheckError: Error { case failed(String) }

    @MainActor
    static func main() async throws {
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

        try await geometryChecks(project: project, directory: directory)
        try await draftChecks(project: project, directory: directory)

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
        print("Project renderer checks passed (jump, easing, timed shapes, repositionable crops, circle alpha, orientation, sync offsets, independent audio tracks, trim, preview/export parity, source preservation).")
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
        let liveSources = try await ProjectRenderer.prepareLiveSources(base, at: frozenTime)
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

        let liveCropSources = try await ProjectRenderer.prepareLiveSources(croppedBase, at: frozenTime)
        let liveCrop = try await ProjectRenderer.renderLivePreview(liveCropSources, applying: cropDraft)
        try require(try rgba(liveCrop) == rgba(cropSaved), "cached raw source crop/aspect pixels equal saved composition")
        let laterSources = try await ProjectRenderer.prepareLiveSources(base, at: CMTime(seconds: 2.5, preferredTimescale: 600))
        let laterImage = try await ProjectRenderer.renderLivePreview(laterSources, applying: savedProject.state)
        try checkCircle(laterImage, frame: CGRect(x: 96, y: 56, width: 64, height: 64), color: [255, 255, 0])
        let earlierAgain = try await ProjectRenderer.renderLivePreview(liveSources, applying: savedProject.state)
        try require(try rgba(earlierAgain) == rgba(liveImage), "another playhead never replaces frozen source buffers")

        var delayed = baseProject
        delayed.cameraOffset = 1
        let delayedRender = try await ProjectRenderer.makePreview(project: delayed, directory: directory)
        let beforeCamera = try await ProjectRenderer.prepareLiveSources(delayedRender, at: frozenTime)
        let beforeImage = try await ProjectRenderer.renderLivePreview(beforeCamera, applying: savedProject.state)
        try checkBounds(beforeImage, expected: nil)
        var ended = baseProject
        ended.cameraOffset = -2
        let endedRender = try await ProjectRenderer.makePreview(project: ended, directory: directory)
        let afterCamera = try await ProjectRenderer.prepareLiveSources(endedRender, at: CMTime(seconds: 3.5, preferredTimescale: 600))
        let afterImage = try await ProjectRenderer.renderLivePreview(afterCamera, applying: savedProject.state)
        try checkBounds(afterImage, expected: nil)

        // Preparation captures raw camera independently of its current visibility.
        var initiallyHidden = baseProject
        initiallyHidden.state.pipKeyframes[0].placement.visible = false
        let hiddenRender = try await ProjectRenderer.makePreview(project: initiallyHidden, directory: directory)
        let hiddenSources = try await ProjectRenderer.prepareLiveSources(hiddenRender, at: frozenTime)
        let revealed = try await ProjectRenderer.renderLivePreview(hiddenSources, applying: savedProject.state)
        try require(try rgba(revealed) == rgba(liveImage), "hidden source camera can be revealed without another decode")

        // A paused playhead need not fall on a nominal 30 fps boundary.
        var betweenFrames = baseProject
        betweenFrames.state.pipKeyframes.append(PIPKeyframe(time: 0.75,
            placement: PIPPlacement(x: 1, y: 1, scale: 0.4), transition: .smooth, duration: 0.75))
        let arbitraryTime = CMTime(seconds: 0.5173, preferredTimescale: 1_000_000)
        let arbitrarySources = try await ProjectRenderer.prepareLiveSources(base, at: arbitraryTime)
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

    private static func image(_ rendered: RenderedProject, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: rendered.asset)
        generator.videoComposition = rendered.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)).image
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
        exportedGenerator.requestedTimeToleranceBefore = .zero
        exportedGenerator.requestedTimeToleranceAfter = .zero
        let (first, _) = try await exportedGenerator.image(at: .zero)
        try checkCircle(first, frame: CGRect(x: 0, y: 40, width: 80, height: 80), color: yellow, requireAntialias: false)
        let (middle, _) = try await exportedGenerator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        try checkCircle(middle, frame: CGRect(x: 50, y: 30, width: 60, height: 60), color: yellow, requireAntialias: false)
    }

    private static func image(_ project: RecordingProject, directory: URL, at seconds: Double) async throws -> CGImage {
        let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
        let generator = AVAssetImageGenerator(asset: rendered.asset)
        generator.videoComposition = rendered.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)).image
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
        let generator = AVAssetImageGenerator(asset: rendered.asset)
        generator.videoComposition = rendered.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
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

    private static func movie(to url: URL, width: Int, height: Int, duration: Int, camera: Bool, transform: CGAffineTransform = .identity, pattern: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
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
            try await fillVideo(input, adaptor: adaptor, writer: writer, width: width, height: height, duration: duration, camera: camera, pattern: pattern)
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
                                  width: Int, height: Int, duration: Int, camera: Bool, pattern: Bool) async throws {
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
