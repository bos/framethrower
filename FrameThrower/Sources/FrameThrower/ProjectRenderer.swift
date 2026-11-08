@preconcurrency import AVFoundation
import Foundation

enum VideoExportPreset: String, CaseIterable, Sendable {
    case fullResolution, hd, small

    var title: String {
        switch self {
        case .fullResolution: "Full resolution"
        case .hd: "1080p"
        case .small: "720p"
        }
    }

    /// Fit within the named video bounds, rotating them for portrait output.
    /// Squares use 1080/720 on both axes; smaller recordings are never enlarged.
    func outputSize(for source: CGSize) -> CGSize {
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else {
            return CGSize(width: 2, height: 2)
        }
        let scale: CGFloat
        if self == .fullResolution { scale = 1 }
        else {
            let short: CGFloat = self == .hd ? 1080 : 720
            let long: CGFloat = self == .hd ? 1920 : 1280
            let bounds = source.width == source.height ? CGSize(width: short, height: short)
                : source.width > source.height ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
            scale = min(1, bounds.width / source.width, bounds.height / source.height)
        }
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded(.down) * 2) }
        return CGSize(width: even(source.width * scale), height: even(source.height * scale))
    }
}

/// Both the editor's AVPlayerItem and exported movie use this exact composition.
/// Times remain in source seconds; trimming is applied only when playing/exporting.
struct RenderedProject {
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    let screenSize: CGSize
    let sourceSize: CGSize
    let cameraAspect: Double
    let previewFrames: PreviewSourceFrames
    let audioMix: AVAudioMix?
    let audioTrackIDs: [CMPersistentTrackID]

    init(asset: AVComposition, videoComposition: AVVideoComposition, screenSize: CGSize,
         cameraAspect: Double, sourceSize: CGSize? = nil,
         previewFrames: PreviewSourceFrames = PreviewSourceFrames(),
         audioMix: AVAudioMix? = nil, audioTrackIDs: [CMPersistentTrackID] = []) {
        self.asset = asset
        self.videoComposition = videoComposition
        self.screenSize = screenSize
        self.sourceSize = sourceSize ?? screenSize
        self.cameraAspect = cameraAspect
        self.previewFrames = previewFrames
        self.audioMix = audioMix
        self.audioTrackIDs = audioTrackIDs
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
        try MediaProcessing.requireEnabled()
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
        var audioTrackIDs: [CMPersistentTrackID] = []
        for audioSource in try await screenAsset.loadTracks(withMediaType: .audio) {
            let available = try await audioSource.load(.timeRange)
            let range = CMTimeRangeGetIntersection(wholeRange, otherRange: available)
            guard range.duration.seconds > 0 else { continue }
            guard let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw RenderError.cannotExport }
            try audioTrack.insertTimeRange(range, of: audioSource, at: range.start)
            audioTrackIDs.append(audioTrack.trackID)
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
        videoComposition.frameDuration = CMTime(seconds: project.captureFrameDuration ?? 1.0 / 30, preferredTimescale: 60_000)
        videoComposition.instructions = [instruction]
        return RenderedProject(
            asset: composition, videoComposition: videoComposition,
            screenSize: renderSize, cameraAspect: cameraAspect, sourceSize: sourceGeometry.size,
            previewFrames: previewFrames,
            audioMix: audioMix(for: project.state, trackIDs: audioTrackIDs, duration: duration),
            audioTrackIDs: audioTrackIDs
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
                               previewFrames: rendered.previewFrames,
                               audioMix: audioMix(for: state, trackIDs: rendered.audioTrackIDs,
                                                  duration: rendered.asset.duration.seconds),
                               audioTrackIDs: rendered.audioTrackIDs)
    }

    /// Source-time ramps preserve independent tracks and any leading gaps.
    /// Identity settings deliberately leave the original audio pipeline alone.
    static func audioMix(for state: EditState, trackIDs: [CMPersistentTrackID],
                         duration: Double) -> AVAudioMix? {
        guard state.audio != RecordingAudio(), !trackIDs.isEmpty else { return nil }
        let points = state.audio.envelope(trimStart: state.trimStart, trimEnd: min(state.trimEnd, duration))
        guard let first = points.first else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = trackIDs.map { trackID in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = trackID
            parameters.setVolume(Float(state.audio.isMuted ? 0 : state.audio.volume), at: .zero)
            parameters.setVolume(Float(first.volume), at: time(first.time))
            for (start, end) in zip(points, points.dropFirst()) {
                let range = CMTimeRange(start: time(start.time), end: time(end.time))
                if range.duration > .zero {
                    parameters.setVolumeRamp(fromStartVolume: Float(start.volume), toEndVolume: Float(end.volume),
                                             timeRange: range)
                }
            }
            return parameters
        }
        return mix
    }

    /// Decode the current screen/camera source pair once for a frozen playhead.
    /// The cache belongs to this preparation, never to exports or other times.
    static func prepareLiveSources(_ rendered: RenderedProject, at time: CMTime) async throws -> LivePreviewSources {
        try MediaProcessing.requireEnabled()
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
        try MediaProcessing.requireEnabled()
        return try await sources.render(applying: state, maximumSize: maximumSize)
    }

    /// A raw, oriented source frame for repositioning the nondestructive crop.
    /// `at` is in screen-source seconds, independent of the editable trim.
    static func cameraFrame(project: RecordingProject, directory: URL, at seconds: Double) async throws -> CGImage? {
        try MediaProcessing.requireEnabled()
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

    static func export(project: RecordingProject, directory: URL, to destination: URL,
                       preset: VideoExportPreset = .fullResolution,
                       replaceExisting: Bool = false,
                       progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async throws {
        try MediaProcessing.requireEnabled()
        try Task.checkCancellation()
        let originalURLs = [project.screenFilename, project.cameraFilename, project.cursorFilename, project.sceneFilename].compactMap { $0 }.map {
            directory.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath()
        }
        let files = FileManager.default
        let existed = files.fileExists(atPath: destination.path)
        let originalAttributes = existed ? try files.attributesOfItem(atPath: destination.path) : nil
        guard (!existed || replaceExisting),
              !originalURLs.contains(destination.standardizedFileURL.resolvingSymlinksInPath()) else {
            throw RenderError.destinationExists
        }
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".framethrower-export-" + UUID().uuidString + ".mp4")
        defer { try? files.removeItem(at: staged) }
        let rendered = try await makePreview(project: project, directory: directory)
        let end = min(project.state.trimEnd, rendered.asset.duration.seconds)
        let start = project.state.trimStart
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw RenderError.invalidTrim }
        try Task.checkCancellation()
        // AVFoundation's named presets treat square output as a long-edge
        // limit (1920² for "1080p"). Render explicitly at the requested bounds
        // instead, preserving presentation geometry and smaller originals.
        let outputSize = preset.outputSize(for: rendered.screenSize)
        let videoComposition = rendered.videoComposition.mutableCopy() as! AVMutableVideoComposition
        videoComposition.renderSize = outputSize
        videoComposition.instructions = rendered.videoComposition.instructions.map { instruction in
            if let pip = instruction as? PIPCompositionInstruction {
                return pip.applying(pip.state, preservePreviewFrames: false, renderSize: outputSize)
            }
            return instruction
        }
        guard let exporter = AVAssetExportSession(asset: rendered.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RenderError.cannotExport
        }
        exporter.videoComposition = videoComposition
        exporter.audioMix = rendered.audioMix
        exporter.timeRange = CMTimeRange(start: time(start), duration: time(end - start))
        exporter.shouldOptimizeForNetworkUse = true
        let progressTask = Task { @MainActor in
            for await state in exporter.states(updateInterval: 0.2) {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { progressTask.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await exporter.export(to: staged, as: .mp4)
                try Task.checkCancellation()
            } onCancel: { exporter.cancelExport() }
            if existed {
                let current = try files.attributesOfItem(atPath: destination.path)
                for key: FileAttributeKey in [.systemFileNumber, .size, .modificationDate] {
                    guard (originalAttributes?[key] as? NSObject)?.isEqual(current[key]) == true else {
                        throw RenderError.destinationExists
                    }
                }
                _ = try files.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
            } else { try files.moveItem(at: staged, to: destination) }
            progress(1)
        } catch {
            // The destination is replaced only after a complete, uncancelled
            // export. Failed attempts remove only this invocation's staging file.
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
