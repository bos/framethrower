@preconcurrency import AVFoundation
import Foundation

/// Both the editor's AVPlayerItem and exported movie use this exact composition.
/// Times remain in source seconds; trimming is applied only when playing/exporting.
struct RenderedProject {
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    let screenSize: CGSize
    let sourceSize: CGSize
    let cameraAspect: Double
    let previewFrames: PreviewSourceFrames

    init(asset: AVComposition, videoComposition: AVVideoComposition, screenSize: CGSize,
         cameraAspect: Double, sourceSize: CGSize? = nil,
         previewFrames: PreviewSourceFrames = PreviewSourceFrames()) {
        self.asset = asset
        self.videoComposition = videoComposition
        self.screenSize = screenSize
        self.sourceSize = sourceSize ?? screenSize
        self.cameraAspect = cameraAspect
        self.previewFrames = previewFrames
    }
}

@MainActor
enum ProjectRenderer {
    enum RenderError: LocalizedError {
        case invalidVideo(String)
        case invalidTrim
        case destinationExists
        case cannotExport

        var errorDescription: String? {
            switch self {
            case let .invalidVideo(name): return "The recording has no usable video: \(name)."
            case .invalidTrim: return "Choose a trim range inside the recording."
            case .destinationExists: return "Choose a different destination. An original recording or a file changed during export cannot be replaced."
            case .cannotExport: return "This recording could not be prepared for export."
            }
        }
    }

    static func makePreview(project: RecordingProject, directory: URL) async throws -> RenderedProject {
        try project.validate()
        let screenAsset = AVURLAsset(url: directory.appendingPathComponent(project.screenFilename))
        guard let screenSource = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw RenderError.invalidVideo(project.screenFilename)
        }
        let sourceDuration = try await screenAsset.load(.duration).seconds
        let duration = min(sourceDuration, project.duration)
        guard duration.isFinite, duration > 0, time(duration) > .zero else {
            throw RenderError.invalidVideo(project.screenFilename)
        }
        let sourceGeometry = try await geometry(of: screenSource)
        let renderSize = PresentationGeometry(sourceSize: sourceGeometry.size,
                                               presentation: project.state.presentation).outputSize
        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw RenderError.cannotExport }
        let wholeRange = CMTimeRange(start: .zero, duration: time(duration))
        try screenTrack.insertTimeRange(wholeRange, of: screenSource, at: .zero)

        // ScreenCaptureKit may produce independent system and microphone tracks.
        // Preserve all of them, including any source-track leading offset.
        for audioSource in try await screenAsset.loadTracks(withMediaType: .audio) {
            let available = try await audioSource.load(.timeRange)
            let range = CMTimeRangeGetIntersection(wholeRange, otherRange: available)
            guard range.duration.seconds > 0 else { continue }
            guard let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw RenderError.cannotExport }
            try audioTrack.insertTimeRange(range, of: audioSource, at: range.start)
        }

        var cameraAspect = 16.0 / 9.0
        var cameraTrackID: CMPersistentTrackID?
        var cameraGeometry: PIPSourceGeometry?
        var cameraStart = 0.0
        var cameraEnd = 0.0

        if let cameraFilename = project.cameraFilename {
            let cameraAsset = AVURLAsset(url: directory.appendingPathComponent(cameraFilename))
            guard let cameraSource = try await cameraAsset.loadTracks(withMediaType: .video).first else {
                throw RenderError.invalidVideo(cameraFilename)
            }
            let loadedCameraGeometry = try await geometry(of: cameraSource)
            cameraGeometry = loadedCameraGeometry
            cameraAspect = loadedCameraGeometry.size.width / loadedCameraGeometry.size.height
            let cameraDuration = try await cameraAsset.load(.duration).seconds
            guard cameraDuration.isFinite, cameraDuration > 0, project.cameraOffset.isFinite else {
                throw RenderError.invalidVideo(cameraFilename)
            }
            cameraStart = max(0, project.cameraOffset)
            cameraEnd = min(duration, project.cameraOffset + cameraDuration)
            if cameraEnd > cameraStart, time(cameraEnd - cameraStart) > .zero {
                guard let cameraTrack = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw RenderError.cannotExport }
                try cameraTrack.insertTimeRange(
                    CMTimeRange(start: time(max(0, -project.cameraOffset)), duration: time(cameraEnd - cameraStart)),
                    of: cameraSource, at: time(cameraStart)
                )
                cameraTrackID = cameraTrack.trackID
            }
        }
        let cursorRecording = try project.cursorFilename.map {
            try CursorRecording.load(from: directory.appendingPathComponent($0))
        }
        let previewFrames = PreviewSourceFrames()
        let instruction = PIPCompositionInstruction(
            timeRange: wholeRange, screenTrackID: screenTrack.trackID, cameraTrackID: cameraTrackID,
            screenGeometry: sourceGeometry, cameraGeometry: cameraGeometry, renderSize: renderSize,
            cameraStart: cameraStart, cameraEnd: cameraEnd, state: project.state, cursorRecording: cursorRecording, previewFrames: previewFrames
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = PIPVideoCompositor.self
        // The compositor renders into sRGB; explicitly tag matching output and
        // request matching source conversion instead of inheriting one track's profile.
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_IEC_sRGB
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        return RenderedProject(
            asset: composition, videoComposition: videoComposition,
            screenSize: renderSize, cameraAspect: cameraAspect, sourceSize: sourceGeometry.size,
            previewFrames: previewFrames
        )
    }

    /// Applies a transient edit snapshot without reopening media or replacing
    /// the source composition. Draft frames and saved/exported edits therefore
    /// run through the same compositor, with the original screen beneath PIP.
    static func preview(_ rendered: RenderedProject, applying state: EditState) -> RenderedProject {
        // AVVideoComposition's NSMutableCopying contract returns its mutable
        // counterpart and preserves frame timing, color, and render settings.
        let videoComposition = rendered.videoComposition.mutableCopy() as! AVMutableVideoComposition
        let outputSize = PresentationGeometry(sourceSize: rendered.sourceSize, presentation: state.presentation).outputSize
        videoComposition.renderSize = outputSize
        videoComposition.instructions = rendered.videoComposition.instructions.map { instruction in
            if let pip = instruction as? PIPCompositionInstruction { return pip.applying(state) }
            return instruction
        }
        return RenderedProject(asset: rendered.asset, videoComposition: videoComposition,
                               screenSize: outputSize, cameraAspect: rendered.cameraAspect, sourceSize: rendered.sourceSize,
                               previewFrames: rendered.previewFrames)
    }

    /// Decode the current screen/camera source pair once for a frozen playhead.
    /// The cache belongs to this preparation, never to exports or other times.
    static func prepareLiveSources(_ rendered: RenderedProject, at time: CMTime) async throws -> LivePreviewSources {
        try Task.checkCancellation()
        guard time.seconds.isFinite, time >= .zero, time < rendered.asset.duration else {
            throw RenderError.invalidTrim
        }
        if let native = rendered.previewFrames.sources(at: time) { return native }
        let capture = FocusedFrameCapture(target: time, frameDuration: rendered.videoComposition.frameDuration)
        let videoComposition = rendered.videoComposition.mutableCopy() as! AVMutableVideoComposition
        videoComposition.instructions = rendered.videoComposition.instructions.map { instruction in
            if let pip = instruction as? PIPCompositionInstruction {
                return pip.applying(pip.state, focusedCapture: capture)
            }
            return instruction
        }
        let generator = AVAssetImageGenerator(asset: rendered.asset)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1, height: 1)
        let preparation = LiveSourcePreparation(generator: generator, capture: capture)
        return try await withTaskCancellationHandler {
            do {
                _ = try await generator.image(at: time)
                try Task.checkCancellation()
                guard let sources = capture.finish() else { throw RenderError.cannotExport }
                // Raw CVPixelBuffers remain valid independently of the decoder.
                // Retire its prefetched work before returning this frozen pair,
                // rather than keeping codec generations alive between seeks.
                preparation.cancel()
                return sources
            } catch {
                preparation.cancel()
                throw error
            }
        } onCancel: {
            preparation.cancel()
        }
    }

    /// Recompose retained raw source pixels with transient edits. No media is
    /// reopened or decoded, and the original screen is exposed as PIP moves.
    static func renderLivePreview(_ sources: LivePreviewSources, applying state: EditState,
                                  maximumSize: CGSize = CGSize(width: 1920, height: 1080)) async throws -> CGImage {
        try await sources.render(applying: state, maximumSize: maximumSize)
    }

    /// A raw, oriented source frame for repositioning the nondestructive crop.
    /// `at` is in screen-source seconds, independent of the editable trim.
    static func cameraFrame(project: RecordingProject, directory: URL, at seconds: Double) async throws -> CGImage? {
        try project.validate()
        guard let filename = project.cameraFilename, seconds.isFinite else { return nil }
        let asset = AVURLAsset(url: directory.appendingPathComponent(filename))
        let cameraTime = seconds - project.cameraOffset
        let duration = try await asset.load(.duration).seconds
        guard cameraTime >= 0, cameraTime < duration else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        defer { generator.cancelAllCGImageGeneration() }
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: time(cameraTime)).image
    }

    static func export(project: RecordingProject, directory: URL, to destination: URL) async throws {
        let originalURLs = [project.screenFilename, project.cameraFilename, project.cursorFilename].compactMap { $0 }.map {
            directory.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath()
        }
        guard !FileManager.default.fileExists(atPath: destination.path),
              !originalURLs.contains(destination.standardizedFileURL.resolvingSymlinksInPath()) else {
            throw RenderError.destinationExists
        }
        let rendered = try await makePreview(project: project, directory: directory)
        let end = min(project.state.trimEnd, rendered.asset.duration.seconds)
        let start = project.state.trimStart
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw RenderError.invalidTrim }
        guard let exporter = AVAssetExportSession(asset: rendered.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RenderError.cannotExport
        }
        exporter.videoComposition = rendered.videoComposition
        exporter.timeRange = CMTimeRange(start: time(start), duration: time(end - start))
        exporter.shouldOptimizeForNetworkUse = true
        do {
            try await exporter.export(to: destination, as: .mp4)
        } catch {
            // Only this invocation's newly created export can be removed on failure.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func geometry(of track: AVAssetTrack) async throws -> PIPSourceGeometry {
        let naturalSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferred).standardized
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw RenderError.cannotExport
        }
        return PIPSourceGeometry(
            size: bounds.size,
            transform: preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        )
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}

/// AVAssetImageGenerator permits asynchronous cancellation; this wrapper keeps
/// that operation and the capture sink together across cancellation callbacks.
private final class LiveSourcePreparation: @unchecked Sendable {
    let generator: AVAssetImageGenerator
    let capture: FocusedFrameCapture

    init(generator: AVAssetImageGenerator, capture: FocusedFrameCapture) {
        self.generator = generator
        self.capture = capture
    }

    func cancel() {
        capture.invalidate()
        generator.cancelAllCGImageGeneration()
    }
}
