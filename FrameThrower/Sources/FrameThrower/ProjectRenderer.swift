@preconcurrency import AVFoundation
import Foundation

/// A codec-free plan joins the project's Finished clock to each occurrence's
/// original-source clock. Video and every audio track consume these same cells.
struct MultiVideoRenderPlan: Sendable {
    struct BindingKey: Hashable, Sendable { var clipID: UUID; var branchIndex: Int }
    struct TrackAssignment: Equatable, Sendable {
        var layerID: UUID
        var clipID: UUID
        var sourceID: UUID
        var branchIndex: Int
        var lane: Int
        var outputStart: Double
        var outputEnd: Double
    }
    struct Segment: Equatable, Sendable {
        var layerID: UUID
        var clipID: UUID
        var sourceID: UUID
        var branchIndex: Int
        var projectStart: Double
        var projectEnd: Double
        var sourceStart: Double
        var sourceEnd: Double
        var outputStart: Double
        var outputEnd: Double

        func outputTime(forSource seconds: Double) -> Double {
            outputStart + (seconds - sourceStart) / (sourceEnd - sourceStart) * (outputEnd - outputStart)
        }
    }

    let timingMap: RecordingTimeMap
    let segments: [Segment]
    let trackAssignments: [TrackAssignment]

    init(project: RecordingProject, state: EditState? = nil) throws {
        let state = state ?? project.state
        var snapshot = project; snapshot.state = state
        try snapshot.validate()
        timingMap = try RecordingTimeMap(duration: project.duration, trimStart: state.trimStart,
            trimEnd: state.trimEnd, cuts: state.cuts, speedKeyframes: state.speedKeyframes)
        let sources = Dictionary(uniqueKeysWithValues: project.videoSources.map { ($0.id, $0) })
        var cells: [Segment] = []
        for layer in project.effectiveVideoLayers(in: state) {
            for clip in layer.clips {
                guard let source = sources[clip.sourceID] else { continue }
                let availableEnd = source.duration.map { clip.start + ($0 - clip.sourceStart) / clip.rate } ?? clip.end
                for (branchIndex, branch) in timingMap.clips.enumerated() {
                    for cell in branch.segments {
                        let start = max(cell.sourceStart, clip.start)
                        let end = min(cell.sourceEnd, clip.end, availableEnd)
                        guard end > start else { continue }
                        cells.append(.init(layerID: layer.id, clipID: clip.id, sourceID: source.id,
                            branchIndex: branchIndex, projectStart: start, projectEnd: end,
                            sourceStart: clip.sourceTime(at: start), sourceEnd: clip.sourceTime(at: end),
                            outputStart: cell.outputTime(for: start), outputEnd: cell.outputTime(for: end)))
                    }
                }
            }
        }
        segments = cells
        let groups = Dictionary(grouping: cells) { BindingKey(clipID: $0.clipID, branchIndex: $0.branchIndex) }
        let intervals = groups.values.compactMap { values -> TrackAssignment? in
            guard let first = values.first, let start = values.map(\.outputStart).min(), let end = values.map(\.outputEnd).max() else { return nil }
            return .init(layerID: first.layerID, clipID: first.clipID, sourceID: first.sourceID,
                branchIndex: first.branchIndex, lane: 0, outputStart: start, outputEnd: end)
        }.sorted {
            if $0.outputStart != $1.outputStart { return $0.outputStart < $1.outputStart }
            if $0.branchIndex != $1.branchIndex { return $0.branchIndex < $1.branchIndex }
            return $0.clipID.uuidString < $1.clipID.uuidString
        }
        var ends: [UUID: [Double]] = [:]
        trackAssignments = intervals.map { interval in
            var assignment = interval
            var lanes = ends[interval.layerID] ?? []
            if let lane = lanes.firstIndex(where: { $0 <= interval.outputStart }) {
                assignment.lane = lane; lanes[lane] = interval.outputEnd
            } else {
                assignment.lane = lanes.count; lanes.append(interval.outputEnd)
            }
            ends[interval.layerID] = lanes
            return assignment
        }
    }

    /// Transparent samples must be summed within a layer before that layer is
    /// placed over the next. Independent source-over fades produce a dark dip.
    static func blendedAlpha(_ samples: [(weight: Double, opacity: Double)]) -> Double {
        min(1, max(0, samples.reduce(0) { $0 + $1.weight * $1.opacity }))
    }

    func audioGain(project: RecordingProject, state: EditState, clipID: UUID,
                   branchIndex: Int, at outputTime: Double, role: RecordingAudioRole?) -> Double {
        guard timingMap.clips.indices.contains(branchIndex),
              let branch = timingMap.samples(at: outputTime).first(where: { $0.clipIndex == branchIndex }) else { return 0 }
        guard let sample = project.videoSamples(at: branch.sourceTime, state: state).first(where: { $0.clipID == clipID }) else { return 0 }
        // Channel envelopes for the recorded screen stay anchored to its
        // original source. Extra footage has no invented microphone/system role.
        return sample.audioGain * branch.weight * state.audio.gain(role: role,
            sourceTime: sample.sourceTime, outputTime: outputTime, outputDuration: timingMap.outputDuration)
    }
}

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
    let audioRoles: [CMPersistentTrackID: RecordingAudioRole]
    let timingMap: RecordingTimeMap?
    let cutAudioSegments: [CutAudioSegment]
    let multiVideoAudioSegments: [MultiVideoAudioSegment]
    let multiVideoProject: RecordingProject?
    var supportsDirectSourcePreview: Bool { timingMap == nil }

    struct CutAudioSegment {
        let trackID: CMPersistentTrackID
        let clipIndex: Int
        let outputStart: Double
        let outputEnd: Double
        var role: RecordingAudioRole? = nil
    }

    struct MultiVideoAudioSegment {
        let trackID: CMPersistentTrackID
        let clipID: UUID
        let branchIndex: Int
        let outputStart: Double
        let outputEnd: Double
        let role: RecordingAudioRole?
    }

    init(asset: AVComposition, videoComposition: AVVideoComposition, screenSize: CGSize,
         cameraAspect: Double, sourceSize: CGSize? = nil,
         previewFrames: PreviewSourceFrames = PreviewSourceFrames(),
         audioMix: AVAudioMix? = nil, audioTrackIDs: [CMPersistentTrackID] = [],
         audioRoles: [CMPersistentTrackID: RecordingAudioRole] = [:], timingMap: RecordingTimeMap? = nil, cutAudioSegments: [CutAudioSegment] = [],
         multiVideoAudioSegments: [MultiVideoAudioSegment] = [], multiVideoProject: RecordingProject? = nil) {
        self.asset = asset
        self.videoComposition = videoComposition
        self.screenSize = screenSize
        self.sourceSize = sourceSize ?? screenSize
        self.cameraAspect = cameraAspect
        self.previewFrames = previewFrames
        self.audioMix = audioMix
        self.audioTrackIDs = audioTrackIDs
        self.audioRoles = audioRoles
        self.timingMap = timingMap
        self.cutAudioSegments = cutAudioSegments
        self.multiVideoAudioSegments = multiVideoAudioSegments
        self.multiVideoProject = multiVideoProject
    }
}

@MainActor
enum ProjectRenderer {
    enum RenderError: LocalizedError {
        case invalidVideo(String)
        case invalidTrim
        case destinationExists
        case cannotExport
        case unidentifiedAudio(String)

        var errorDescription: String? {
            switch self {
            case let .invalidVideo(name): return "The recording has no usable video: \(name)."
            case .invalidTrim: return "Choose a trim range inside the recording."
            case .destinationExists: return "Choose a different destination. An original recording or a file changed during export cannot be replaced."
            case .cannotExport: return "This recording could not be prepared for export."
            case let .unidentifiedAudio(role): return "The source has no verified \(role) track. Restore the original audio metadata or reset that track’s controls before exporting."
            }
        }
    }

    static func makePreview(project: RecordingProject, directory: URL) async throws -> RenderedProject {
        try MediaProcessing.requireEnabled()
        try project.validate()
        if project.state.videoLayers != nil { return try await makeMultiVideoPreview(project: project, directory: directory) }
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
        var audioRoles: [CMPersistentTrackID: RecordingAudioRole] = [:]
        for audioSource in try await screenAsset.loadTracks(withMediaType: .audio) {
            let available = try await audioSource.load(.timeRange)
            let range = CMTimeRangeGetIntersection(wholeRange, otherRange: available)
            guard range.duration.seconds > 0 else { continue }
            guard let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw RenderError.cannotExport }
            try audioTrack.insertTimeRange(range, of: audioSource, at: range.start)
            audioTrackIDs.append(audioTrack.trackID)
            audioRoles[audioTrack.trackID] = try await audioRole(of: audioSource, bindings: project.audioSources)
        }

        try requireControlledAudioRoles(project.state.audio, found: Array(audioRoles.values))
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
            audioMix: audioMix(for: project.state, trackIDs: audioTrackIDs, duration: duration, roles: audioRoles),
            audioTrackIDs: audioTrackIDs, audioRoles: audioRoles
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
        var sourceRoles: [RecordingAudioRole?] = []
        for source in audioSources {
            audioTracks.append(try tracks(.audio))
            audioRanges.append(try await source.load(.timeRange))
            sourceRoles.append(try await audioRole(of: source, bindings: project.audioSources))
        }
        try requireControlledAudioRoles(project.state.audio, found: sourceRoles.compactMap { $0 })
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
                    outputStart: outputStart, outputEnd: clip.outputTime(for: range.end.seconds), role: sourceRoles[sourceIndex]))
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

    /// Each occurrence owns an independent track per retained global branch.
    /// This also supports two simultaneous occurrences of the same source at
    /// different source times; source IDs alone cannot identify decoder tracks.
    private static func makeMultiVideoPreview(project: RecordingProject, directory: URL) async throws -> RenderedProject {
        try MediaProcessing.requireEnabled()
        let plan = try MultiVideoRenderPlan(project: project)
        let composition = AVMutableComposition()
        composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: time(plan.timingMap.outputDuration)))
        let sources = Dictionary(uniqueKeysWithValues: project.videoSources.map { ($0.id, $0) })
        let usedSources = Set(plan.segments.map(\.sourceID))
        var videos: [UUID: AVAssetTrack] = [:]
        var videoRanges: [UUID: CMTimeRange] = [:]
        var geometries: [UUID: PIPSourceGeometry] = [:]
        var audios: [UUID: [AVAssetTrack]] = [:]
        var audioRanges: [ObjectIdentifier: CMTimeRange] = [:]
        var sourceRoles: [ObjectIdentifier: RecordingAudioRole] = [:]
        for source in project.videoSources where usedSources.contains(source.id) && source.kind == .file {
            let asset = AVURLAsset(url: try source.resolvedURL(in: directory))
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw RenderError.invalidVideo(source.name)
            }
            videos[source.id] = video
            videoRanges[source.id] = try await video.load(.timeRange)
            geometries[source.id] = try await geometry(of: video)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            audios[source.id] = tracks
            for track in tracks {
                audioRanges[ObjectIdentifier(track)] = try await track.load(.timeRange)
                if source.id == VideoSource.legacyScreenID {
                    sourceRoles[ObjectIdentifier(track)] = try await audioRole(of: track, bindings: project.audioSources)
                }
            }
        }
        try requireControlledAudioRoles(project.state.audio, found: Array(sourceRoles.values))
        var primarySize = geometries[VideoSource.legacyScreenID]?.size
            ?? sources[VideoSource.legacyScreenID]?.pixelSize ?? CGSize(width: 1920, height: 1080)
        // Canvas .source belongs to the project, not whichever occurrence is
        // currently visible. Removing its screen layer must not turn a portrait
        // recording into a landscape canvas. Read metadata only if that source
        // was not already loaded, inside the same media interlock as above.
        if geometries[VideoSource.legacyScreenID] == nil, let primary = sources[VideoSource.legacyScreenID] {
            let url = try primary.resolvedURL(in: directory)
            if FileManager.default.fileExists(atPath: url.path) {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw RenderError.invalidVideo(primary.name)
                }
                primarySize = try await geometry(of: track).size
            }
        }
        let renderSize = PresentationGeometry(sourceSize: primarySize, presentation: project.state.presentation).outputSize
        var bindings: [MultiVideoCompositionInstruction.Binding] = []
        var audioSegments: [RenderedProject.MultiVideoAudioSegment] = []
        // Interval coloring reuses non-overlapping decoder tracks. At most two
        // local clips × two global cut branches need pixels in one layer.
        let groups = Dictionary(grouping: plan.segments) { MultiVideoRenderPlan.BindingKey(clipID: $0.clipID, branchIndex: $0.branchIndex) }
        var videoPools: [UUID: [AVMutableCompositionTrack]] = [:]
        struct AudioPoolKey: Hashable { var role: RecordingAudioRole? }
        struct AudioSlot { var track: AVMutableCompositionTrack; var end: Double }
        var audioPools: [AudioPoolKey: [AudioSlot]] = [:]
        for assignment in plan.trackAssignments {
            let key = MultiVideoRenderPlan.BindingKey(clipID: assignment.clipID, branchIndex: assignment.branchIndex)
            guard let cells = groups[key], let sourceID = cells.first?.sourceID, let source = sources[sourceID], source.kind == .file,
                  let videoSource = videos[sourceID], let sourceGeometry = geometries[sourceID] else { continue }
            var pool = videoPools[assignment.layerID] ?? []
            while pool.count <= assignment.lane {
                guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw RenderError.cannotExport
                }
                pool.append(track)
            }
            videoPools[assignment.layerID] = pool
            let track = pool[assignment.lane]
            func insert(_ source: AVAssetTrack, into target: AVMutableCompositionTrack, available: CMTimeRange? = nil) throws {
                for cell in cells.sorted(by: { $0.outputStart < $1.outputStart }) {
                    let first = max(cell.sourceStart, available?.start.seconds ?? cell.sourceStart)
                    let last = min(cell.sourceEnd, available?.end.seconds ?? cell.sourceEnd)
                    guard last > first else { continue }
                    let outputStart = time(cell.outputTime(forSource: first)), outputEnd = time(cell.outputTime(forSource: last))
                    let range = CMTimeRange(start: time(first), end: time(last))
                    guard range.duration > .zero, outputEnd > outputStart else { continue }
                    try target.insertTimeRange(range, of: source, at: outputStart)
                    target.scaleTimeRange(CMTimeRange(start: outputStart, duration: range.duration), toDuration: outputEnd - outputStart)
                }
            }
            try insert(videoSource, into: track, available: videoRanges[sourceID])
            bindings.append(.init(clipID: key.clipID, branchIndex: key.branchIndex, trackID: track.trackID, geometry: sourceGeometry))
            for audioSource in audios[sourceID] ?? [] {
                guard let available = audioRanges[ObjectIdentifier(audioSource)] else { throw RenderError.cannotExport }
                let covered = cells.compactMap { cell -> (Double, Double)? in
                    let first = max(cell.sourceStart, available.start.seconds), last = min(cell.sourceEnd, available.end.seconds)
                    return last > first ? (cell.outputTime(forSource: first), cell.outputTime(forSource: last)) : nil
                }
                guard let start = covered.map(\.0).min(), let end = covered.map(\.1).max() else { continue }
                let role = sourceID == VideoSource.legacyScreenID ? sourceRoles[ObjectIdentifier(audioSource)] : nil
                let audioKey = AudioPoolKey(role: role)
                var audioPool = audioPools[audioKey] ?? []
                let audio: AVMutableCompositionTrack
                if let index = audioPool.firstIndex(where: { $0.end <= start }) {
                    audio = audioPool[index].track; audioPool[index].end = end
                } else {
                    guard let added = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                        throw RenderError.cannotExport
                    }
                    audio = added; audioPool.append(.init(track: added, end: end))
                }
                audioPools[audioKey] = audioPool
                try insert(audioSource, into: audio, available: available)
                for range in covered {
                    audioSegments.append(.init(trackID: audio.trackID, clipID: key.clipID, branchIndex: key.branchIndex,
                        outputStart: range.0, outputEnd: range.1, role: role))
                }
            }
        }
        let instruction = MultiVideoCompositionInstruction(project: project, plan: plan, bindings: bindings,
            sourceSize: primarySize, renderSize: renderSize,
            cursorRecording: try project.cursorFilename.map { try CursorRecording.load(from: directory.appendingPathComponent($0)) })
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = PIPVideoCompositor.self
        video.renderSize = renderSize
        video.frameDuration = time(project.captureFrameDuration ?? 1.0 / 30)
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_IEC_sRGB
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        video.instructions = [instruction]
        return RenderedProject(asset: composition, videoComposition: video, screenSize: renderSize,
            cameraAspect: geometries[VideoSource.legacyCameraID].map { $0.size.width / $0.size.height } ?? 16.0 / 9.0,
            sourceSize: primarySize,
            audioMix: multiVideoAudioMix(project: project, state: project.state, plan: plan, segments: audioSegments),
            audioTrackIDs: Array(Set(audioSegments.map(\.trackID))).sorted(), timingMap: plan.timingMap,
            multiVideoAudioSegments: audioSegments, multiVideoProject: project)
    }

    static func multiVideoAudioMix(project: RecordingProject, state: EditState, plan: MultiVideoRenderPlan,
                                   segments: [RenderedProject.MultiVideoAudioSegment]) -> AVAudioMix? {
        guard !segments.isEmpty else { return nil }
        let clips = Dictionary(uniqueKeysWithValues: project.effectiveVideoLayers(in: state).flatMap(\.clips).map { ($0.id, $0) })
        let mix = AVMutableAudioMix()
        mix.inputParameters = Set(segments.map(\.trackID)).sorted().map { trackID in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = trackID
            parameters.audioTimePitchAlgorithm = state.preservesAudioPitch ? .spectral : .varispeed
            parameters.setVolume(0, at: .zero)
            for segment in segments.filter({ $0.trackID == trackID }).sorted(by: { $0.outputStart < $1.outputStart }) {
                guard let clip = clips[segment.clipID] else { continue }
                let branch = plan.timingMap.clips[segment.branchIndex]
                var knots = [segment.outputStart, segment.outputEnd]
                knots += branch.segments.flatMap { [$0.outputStart, $0.outputEnd] }
                knots += plan.timingMap.joins.flatMap { [$0.outputStart, $0.outputEnd] }
                knots += state.audio.envelope(trimStart: 0, trimEnd: plan.timingMap.outputDuration).map(\.time)
                knots += state.audio.sourceKnots(role: segment.role).map { branch.outputTime(for: clip.start + ($0 - clip.sourceStart) / clip.rate) }
                for key in clip.volumeKeyframes {
                    knots += [key.time, key.time - key.duration].map { branch.outputTime(for: clip.start + ($0 - clip.sourceStart) / clip.rate) }
                }
                // Same-layer join boundaries are also gain-envelope knots.
                knots += project.effectiveVideoLayers(in: state).flatMap(\.clips).flatMap { [branch.outputTime(for: $0.start), branch.outputTime(for: $0.end)] }
                knots = knots.filter { $0 >= segment.outputStart && $0 <= segment.outputEnd }
                let points = RecordingAudio.sampledEnvelope(knots: knots) { at in
                    // A half-open media range keeps its left-limit gain until
                    // its endpoint; silence is set separately after that range.
                    let sampleTime = at == segment.outputEnd ? max(segment.outputStart, at - 1e-8) : at
                    return plan.audioGain(project: project, state: state, clipID: segment.clipID,
                        branchIndex: segment.branchIndex, at: sampleTime, role: segment.role)
                }
                applyGainPoints(points, to: parameters)
                parameters.setVolume(0, at: time(segment.outputEnd))
            }
            return parameters
        }
        return mix
    }

    /// The audio branches use the same linear cut gains as video. Multiplying
    /// by master fades is quadratic where ramps overlap; bounded subdivision
    /// approximates that product to <0.0001 gain instead of introducing a bump.
    static func cutAudioMix(for state: EditState, timingMap: RecordingTimeMap,
                                    segments: [RenderedProject.CutAudioSegment]) -> AVAudioMix? {
        guard !segments.isEmpty else { return nil }
        let master = state.audio.envelope(trimStart: 0, trimEnd: timingMap.outputDuration)
        func gain(_ at: Double, clip: Int, role: RecordingAudioRole?) -> Double {
            var weight = 1.0
            if clip > 0 {
                let join = timingMap.joins[clip - 1]
                if join.duration > 0 { weight = min(weight, max(0, min(1, (at - join.outputStart) / join.duration))) }
            }
            if clip < timingMap.joins.count {
                let join = timingMap.joins[clip]
                if join.duration > 0 { weight = min(weight, max(0, min(1, (join.outputEnd - at) / join.duration))) }
            }
            let source = timingMap.clips[clip].sourceTime(at: at)
            return state.audio.gain(role: role, sourceTime: source, outputTime: at, outputDuration: timingMap.outputDuration) * weight
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
                let clip = timingMap.clips[segment.clipIndex]
                knots += state.audio.sourceKnots(role: segment.role).map { clip.outputTime(for: $0) }
                knots += clip.segments.flatMap { [$0.outputStart, $0.outputEnd] }
                knots = knots.filter { $0 >= segment.outputStart && $0 <= segment.outputEnd }
                let points = RecordingAudio.sampledEnvelope(knots: knots) { gain($0, clip: segment.clipIndex, role: segment.role) }
                applyGainPoints(points, to: parameters)
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
            if let multi = instruction as? MultiVideoCompositionInstruction { return multi.applying(state, renderSize: outputSize) }
            return instruction
        }
        let updatedAudioMix: AVAudioMix?
        if let multi = rendered.videoComposition.instructions.compactMap({ $0 as? MultiVideoCompositionInstruction }).first {
            updatedAudioMix = multiVideoAudioMix(project: multi.project, state: state, plan: multi.plan,
                segments: rendered.multiVideoAudioSegments)
        } else if let map = rendered.timingMap {
            updatedAudioMix = cutAudioMix(for: state, timingMap: map, segments: rendered.cutAudioSegments)
        } else {
            updatedAudioMix = audioMix(for: state, trackIDs: rendered.audioTrackIDs, duration: rendered.asset.duration.seconds, roles: rendered.audioRoles)
        }
        return RenderedProject(asset: rendered.asset, videoComposition: videoComposition,
                               screenSize: outputSize, cameraAspect: rendered.cameraAspect, sourceSize: rendered.sourceSize,
                               previewFrames: rendered.previewFrames,
                               audioMix: updatedAudioMix,
                               audioTrackIDs: rendered.audioTrackIDs, audioRoles: rendered.audioRoles, timingMap: rendered.timingMap,
                               cutAudioSegments: rendered.cutAudioSegments, multiVideoAudioSegments: rendered.multiVideoAudioSegments,
                               multiVideoProject: rendered.multiVideoProject)
    }

    /// Source-time ramps preserve independent tracks and any leading gaps.
    /// Identity settings deliberately leave the original audio pipeline alone.
    static func audioMix(for state: EditState, trackIDs: [CMPersistentTrackID],
                         duration: Double, roles: [CMPersistentTrackID: RecordingAudioRole] = [:]) -> AVAudioMix? {
        guard state.audio != RecordingAudio(), !trackIDs.isEmpty else { return nil }
        let start = state.trimStart, end = min(state.trimEnd, duration)
        let mix = AVMutableAudioMix()
        mix.inputParameters = trackIDs.map { trackID in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = trackID
            parameters.setVolume(0, at: .zero)
            let role = roles[trackID]
            let knots = [start, end] + state.audio.envelope(trimStart: start, trimEnd: end).map(\.time)
                + state.audio.sourceKnots(role: role).filter { $0 >= start && $0 <= end }
            let points = RecordingAudio.sampledEnvelope(knots: knots) {
                state.audio.gain(role: role, sourceTime: $0, outputTime: $0 - start, outputDuration: end - start)
            }
            applyGainPoints(points, to: parameters)
            return parameters
        }
        return mix
    }

    private static func applyGainPoints(_ points: [RecordingAudio.Point], to parameters: AVMutableAudioMixInputParameters) {
        guard let first = points.first else { return }
        parameters.setVolume(Float(first.volume), at: time(first.time))
        for (a, b) in zip(points, points.dropFirst()) {
            let range = CMTimeRange(start: time(a.time), end: time(b.time))
            if range.duration > .zero { parameters.setVolumeRamp(fromStartVolume: Float(a.volume), toEndVolume: Float(b.volume), timeRange: range) }
            else { parameters.setVolume(Float(b.volume), at: time(b.time)) }
        }
    }
    private static func requireControlledAudioRoles(_ audio: RecordingAudio, found: [RecordingAudioRole]) throws {
        guard Set(found).count == found.count else { throw RenderError.unidentifiedAudio("uniquely identified microphone/system audio") }
        for channel in audio.channels where channel != RecordingAudioChannel(role: channel.role) && !found.contains(channel.role) {
            throw RenderError.unidentifiedAudio(channel.role.title.lowercased())
        }
    }
    private static func audioRole(of track: AVAssetTrack, bindings: [RecordingAudioSource]) async throws -> RecordingAudioRole? {
        guard !bindings.isEmpty, let metadata = try? await track.load(.metadata) else { return nil }
        var roles = Set<RecordingAudioRole>()
        for item in metadata {
            let value = try? await item.load(.stringValue)
            if let role = RecordingAudioSource.resolve(identifier: item.identifier?.rawValue, value: value, bindings: bindings) { roles.insert(role) }
        }
        return roles.count == 1 ? roles.first : nil
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
        var originalURLs = [project.screenFilename, project.cameraFilename, project.cursorFilename, project.sceneFilename].compactMap { $0 }.map {
            directory.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath()
        }
        originalURLs += try project.videoSources.filter { $0.kind == .file }.map {
            try $0.resolvedURL(in: directory).standardizedFileURL.resolvingSymlinksInPath()
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
            if let multi = instruction as? MultiVideoCompositionInstruction { return multi.applying(multi.project.state, renderSize: outputSize) }
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
