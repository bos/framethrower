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
/// Legacy compositions retain source seconds. Cut compositions expose an explicit
/// output timing map shared by preview/export, rather than rewriting source edits.
struct RenderedProject {
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    let screenSize: CGSize
    let sourceSize: CGSize
    let cameraAspect: Double
    let previewFrames: PreviewSourceFrames
    let audioMix: AVAudioMix?
    let audioTrackIDs: [CMPersistentTrackID]
    let timingMap: RecordingTimeMap?
    let cutAudioSegments: [CutAudioSegment]
    var supportsDirectSourcePreview: Bool { timingMap == nil }

    struct CutAudioSegment {
        let trackID: CMPersistentTrackID
        let clipIndex: Int
        let outputStart: Double
        let outputEnd: Double
    }

    init(asset: AVComposition, videoComposition: AVVideoComposition, screenSize: CGSize,
         cameraAspect: Double, sourceSize: CGSize? = nil,
         previewFrames: PreviewSourceFrames = PreviewSourceFrames(),
         audioMix: AVAudioMix? = nil, audioTrackIDs: [CMPersistentTrackID] = [],
         timingMap: RecordingTimeMap? = nil, cutAudioSegments: [CutAudioSegment] = []) {
        self.asset = asset
        self.videoComposition = videoComposition
        self.screenSize = screenSize
        self.sourceSize = sourceSize ?? screenSize
        self.cameraAspect = cameraAspect
        self.previewFrames = previewFrames
        self.audioMix = audioMix
        self.audioTrackIDs = audioTrackIDs
        self.timingMap = timingMap
        self.cutAudioSegments = cutAudioSegments
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
        if !project.state.cuts.isEmpty || !project.state.speedKeyframes.isEmpty {
            return try await makeCutPreview(project: project, directory: directory, screenAsset: screenAsset,
                screenSource: screenSource, duration: duration)
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
            cameraStart: cameraStart, cameraEnd: cameraEnd, state: project.state, cursorRecording: cursorRecording, previewFrames: previewFrames,
            contentAssets: project.contentAssets
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

    /// Retained ranges are placed on alternating tracks, allowing both sides
    /// of a cut to be decoded simultaneously without rewriting source media.
    private static func makeCutPreview(project: RecordingProject, directory: URL,
                                       screenAsset: AVAsset, screenSource: AVAssetTrack,
                                       duration: Double) async throws -> RenderedProject {
        let map = try RecordingTimeMap(duration: project.duration, trimStart: project.state.trimStart,
            trimEnd: min(project.state.trimEnd, duration), cuts: project.state.cuts, speedKeyframes: project.state.speedKeyframes)
        let screenGeometry = try await geometry(of: screenSource)
        let renderSize = PresentationGeometry(sourceSize: screenGeometry.size, presentation: project.state.presentation).outputSize
        let composition = AVMutableComposition()
        func tracks(_ type: AVMediaType) throws -> [AVMutableCompositionTrack] {
            try (0..<2).map { _ in
                guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw RenderError.cannotExport
                }
                return track
            }
        }
        let screenTracks = try tracks(.video)
        var cameraSource: AVAssetTrack?
        var cameraGeometry: PIPSourceGeometry?
        var cameraStart = 0.0, cameraEnd = 0.0
        if let filename = project.cameraFilename {
            let asset = AVURLAsset(url: directory.appendingPathComponent(filename))
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw RenderError.invalidVideo(filename) }
            cameraSource = source
            cameraGeometry = try await geometry(of: source)
            let cameraDuration = try await asset.load(.duration).seconds
            guard cameraDuration.isFinite, cameraDuration > 0 else { throw RenderError.invalidVideo(filename) }
            cameraStart = max(0, project.cameraOffset)
            cameraEnd = min(duration, project.cameraOffset + cameraDuration)
        }
        let cameraTracks: [AVMutableCompositionTrack]
        if cameraSource != nil { cameraTracks = try tracks(.video) }
        else { cameraTracks = [] }
        let audioSources = try await screenAsset.loadTracks(withMediaType: .audio)
        var audioTracks: [[AVMutableCompositionTrack]] = []
        var audioRanges: [CMTimeRange] = []
        for source in audioSources {
            audioTracks.append(try tracks(.audio))
            audioRanges.append(try await source.load(.timeRange))
        }
        var branches: [CutCompositionInstruction.Branch] = []
        var audioSegments: [RenderedProject.CutAudioSegment] = []
        for (index, clip) in map.clips.enumerated() {
            let lane = index % 2
            // A single shared piecewise clock retimes screen, camera and every
            // audio source. Insert/scale each cell before adding its successor;
            // scaling therefore never moves an already-placed later segment.
            func insert(_ source: AVAssetTrack, into track: AVMutableCompositionTrack,
                        sourceStart: Double, sourceEnd: Double, offset: Double = 0) throws {
                for cell in clip.segments {
                    let start = max(cell.sourceStart, sourceStart), end = min(cell.sourceEnd, sourceEnd)
                    guard end > start else { continue }
                    let at = time(cell.outputTime(for: start))
                    let targetEnd = time(cell.outputTime(for: end))
                    let range = CMTimeRange(start: time(start - offset), end: time(end - offset))
                    guard range.duration > .zero, targetEnd > at else { continue }
                    try track.insertTimeRange(range, of: source, at: at)
                    track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: targetEnd - at)
                }
            }
            try insert(screenSource, into: screenTracks[lane], sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd)
            if let cameraSource {
                let start = max(clip.sourceStart, cameraStart), end = min(clip.sourceEnd, cameraEnd)
                if end > start {
                    try insert(cameraSource, into: cameraTracks[lane], sourceStart: start, sourceEnd: end, offset: project.cameraOffset)
                }
            }
            for sourceIndex in audioSources.indices {
                let range = CMTimeRangeGetIntersection(audioRanges[sourceIndex],
                    otherRange: CMTimeRange(start: time(clip.sourceStart), end: time(clip.sourceEnd)))
                guard range.duration > .zero else { continue }
                let outputStart = clip.outputTime(for: range.start.seconds)
                let track = audioTracks[sourceIndex][lane]
                try insert(audioSources[sourceIndex], into: track, sourceStart: range.start.seconds, sourceEnd: range.end.seconds)
                audioSegments.append(.init(trackID: track.trackID, clipIndex: index,
                    outputStart: outputStart, outputEnd: clip.outputTime(for: range.end.seconds)))
            }
            branches.append(.init(screenTrackID: screenTracks[lane].trackID,
                cameraTrackID: cameraTracks.isEmpty ? nil : cameraTracks[lane].trackID))
        }
        let template = PIPCompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: time(map.outputDuration)),
            screenTrackID: screenTracks[0].trackID, cameraTrackID: cameraTracks.first?.trackID,
            screenGeometry: screenGeometry, cameraGeometry: cameraGeometry, renderSize: renderSize,
            cameraStart: cameraStart, cameraEnd: cameraEnd, state: project.state,
            cursorRecording: try project.cursorFilename.map { try CursorRecording.load(from: directory.appendingPathComponent($0)) },
            contentAssets: project.contentAssets)
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = PIPVideoCompositor.self
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_IEC_sRGB
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        video.renderSize = renderSize
        video.frameDuration = CMTime(seconds: project.captureFrameDuration ?? 1.0 / 30, preferredTimescale: 60_000)
        video.instructions = [CutCompositionInstruction(timingMap: map, branches: branches, template: template)]
        return RenderedProject(asset: composition, videoComposition: video, screenSize: renderSize,
            cameraAspect: cameraGeometry.map { $0.size.width / $0.size.height } ?? 16.0 / 9.0,
            sourceSize: screenGeometry.size, audioMix: cutAudioMix(for: project.state, timingMap: map, segments: audioSegments),
            audioTrackIDs: audioTracks.flatMap { $0.map(\.trackID) }, timingMap: map, cutAudioSegments: audioSegments)
    }

    /// The audio branches use the same linear cut gains as video. Multiplying
    /// by master fades is quadratic where ramps overlap; bounded subdivision
    /// approximates that product to <0.0001 gain instead of introducing a bump.
    static func cutAudioMix(for state: EditState, timingMap: RecordingTimeMap,
                                    segments: [RenderedProject.CutAudioSegment]) -> AVAudioMix? {
        guard !segments.isEmpty else { return nil }
        let master = state.audio.envelope(trimStart: 0, trimEnd: timingMap.outputDuration)
        func masterGain(_ at: Double) -> Double {
            guard let first = master.first, let last = master.last else { return 0 }
            if at <= first.time { return first.volume }
            if at >= last.time { return last.volume }
            for (a, b) in zip(master, master.dropFirst()) where at <= b.time {
                return a.volume + (b.volume - a.volume) * (at - a.time) / (b.time - a.time)
            }
            return last.volume
        }
        func gain(_ at: Double, clip: Int) -> Double {
            var weight = 1.0
            if clip > 0 {
                let join = timingMap.joins[clip - 1]
                if join.duration > 0 { weight = min(weight, max(0, min(1, (at - join.outputStart) / join.duration))) }
            }
            if clip < timingMap.joins.count {
                let join = timingMap.joins[clip]
                if join.duration > 0 { weight = min(weight, max(0, min(1, (join.outputEnd - at) / join.duration))) }
            }
            return masterGain(at) * weight
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = Set(segments.map(\.trackID)).sorted().map { trackID in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = trackID
            parameters.audioTimePitchAlgorithm = state.preservesAudioPitch ? .spectral : .varispeed
            parameters.setVolume(0, at: .zero)
            for segment in segments.filter({ $0.trackID == trackID }).sorted(by: { $0.outputStart < $1.outputStart }) {
                var knots = [segment.outputStart, segment.outputEnd] + master.map(\.time)
                for join in timingMap.joins where join.outgoingClipIndex == segment.clipIndex || join.incomingClipIndex == segment.clipIndex {
                    knots += [join.outputStart, join.outputEnd]
                }
                knots = Set(knots.filter { $0 >= segment.outputStart && $0 <= segment.outputEnd }).sorted()
                parameters.setVolume(Float(gain(segment.outputStart, clip: segment.clipIndex)), at: time(segment.outputStart))
                for (a, b) in zip(knots, knots.dropFirst()) {
                    let error = abs((gain(a, clip: segment.clipIndex) + gain(b, clip: segment.clipIndex)) / 2 - gain((a + b) / 2, clip: segment.clipIndex))
                    let count = max(1, Int(ceil(sqrt(error / 0.0001))))
                    for part in 0..<count {
                        let start = a + (b - a) * Double(part) / Double(count)
                        let end = a + (b - a) * Double(part + 1) / Double(count)
                        let range = CMTimeRange(start: time(start), end: time(end))
                        if range.duration > .zero {
                            parameters.setVolumeRamp(fromStartVolume: Float(gain(start, clip: segment.clipIndex)),
                                toEndVolume: Float(gain(end, clip: segment.clipIndex)), timeRange: range)
                        }
                    }
                }
                parameters.setVolume(0, at: time(segment.outputEnd))
            }
            return parameters
        }
        return mix
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
            if let cut = instruction as? CutCompositionInstruction { return cut.applying(state) }
            return instruction
        }
        return RenderedProject(asset: rendered.asset, videoComposition: videoComposition,
                               screenSize: outputSize, cameraAspect: rendered.cameraAspect, sourceSize: rendered.sourceSize,
                               previewFrames: rendered.previewFrames,
                               audioMix: rendered.timingMap.map { cutAudioMix(for: state, timingMap: $0, segments: rendered.cutAudioSegments) }
                                   ?? audioMix(for: state, trackIDs: rendered.audioTrackIDs, duration: rendered.asset.duration.seconds),
                               audioTrackIDs: rendered.audioTrackIDs, timingMap: rendered.timingMap,
                               cutAudioSegments: rendered.cutAudioSegments)
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
        guard rendered.supportsDirectSourcePreview else {
            throw RenderError.invalidVideo("Direct source previews are unavailable during cut transitions")
        }
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
        let end = rendered.timingMap?.outputDuration ?? min(project.state.trimEnd, rendered.asset.duration.seconds)
        let start = rendered.timingMap == nil ? project.state.trimStart : 0
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
            if let cut = instruction as? CutCompositionInstruction { return cut.applying(cut.template.state, renderSize: outputSize) }
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
