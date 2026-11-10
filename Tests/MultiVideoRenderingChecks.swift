@preconcurrency import AVFoundation
import AppKit

/// Metadata plans, native vector layers and AV gain parameters only. The fake
/// movie paths must never be opened; no decoder, compositor or fixture runs.
@main @MainActor
struct MultiVideoRenderingChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure.failed(message) }
    }
    static func near(_ value: Double, _ expected: Double, _ message: String, tolerance: Double = 1e-6) throws {
        try require(abs(value - expected) <= tolerance, "\(message): \(value) != \(expected)")
    }
    static func fixture() -> RecordingProject {
        var project = RecordingProject(screenFilename: "never-open-primary.mov", duration: 12)
        let portrait = VideoSource(name: "Phone", kind: .testPattern, duration: 30,
            pixelWidth: 1080, pixelHeight: 1920, hasAudio: false, patternSeed: 1)
        let desktop = VideoSource(name: "Desktop", kind: .testPattern, duration: 30,
            pixelWidth: 1920, pixelHeight: 1080, hasAudio: false, patternSeed: 2)
        project.videoAssets = [portrait, desktop]
        project.state.videoLayers = [
            VideoLayer(name: "Sequence", clips: [
                VideoClip(sourceID: portrait.id, start: 0, end: 6, sourceStart: 2, rate: 2, volume: 0.8,
                    volumeKeyframes: [.init(time: 8, gain: 0.5, transition: .jump)]),
                VideoClip(sourceID: desktop.id, start: 4, end: 10, volume: 0.4)
            ]),
            VideoLayer(name: "Overlay", clips: [VideoClip(sourceID: portrait.id, start: 0, end: 12,
                geometry: VideoGeometry(rect: .init(x: 0.6, y: 0.1, width: 0.3, height: 0.5)), opacity: 0.3, volume: 0.2)])
        ]
        return project
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "media interlock must remain enabled")
        var project = fixture()
        try project.validate()
        let first = project.state.videoLayers![0].clips[0]
        let second = project.state.videoLayers![0].clips[1]
        let overlay = project.state.videoLayers![1].clips[0]
        let plan = try MultiVideoRenderPlan(project: project)
        let firstCells = plan.segments.filter { $0.clipID == first.id }
        try require(!firstCells.isEmpty, "occurrence has source/output clock cells")
        try near(firstCells.first!.sourceStart, 2, "trim starts in original asset seconds")
        try near(firstCells.last!.sourceEnd, 14, "clip rate retimes original source")
        try near(firstCells.last!.outputEnd, 6, "rate does not change authored clip endpoint")
        try near(firstCells[0].outputTime(forSource: 10), 4, "video and audio use identical source/output affine map")
        try near(plan.audioGain(project: project, state: project.state, clipID: first.id, branchIndex: 0, at: 5, role: nil),
            0.2, "source envelope times clip gain times same-layer dissolve")
        try near(plan.audioGain(project: project, state: project.state, clipID: second.id, branchIndex: 0, at: 5, role: nil),
            0.2, "incoming audio follows the same join")
        try near(plan.audioGain(project: project, state: project.state, clipID: overlay.id, branchIndex: 0, at: 5, role: nil),
            0.2, "visual translucency does not mute audio in independent layers")
        try near(MultiVideoRenderPlan.blendedAlpha([(0.5, 1), (0.5, 1)]), 1,
            "opaque crossdissolve stays opaque; independent source-over would produce 0.75")
        try near(MultiVideoRenderPlan.blendedAlpha([(0.25, 0.4), (0.75, 0.8)]), 0.7,
            "translucent images form one weighted layer")

        // Inspect framework gain parameters without constructing any AVAsset.
        let segment = RenderedProject.MultiVideoAudioSegment(trackID: 47, clipID: first.id, branchIndex: 0,
            outputStart: 0, outputEnd: 6, role: nil)
        let mix = ProjectRenderer.multiVideoAudioMix(project: project, state: project.state, plan: plan, segments: [segment])!
        try gain(mix.inputParameters[0], at: 5, equals: 0.2)
        var muted = project.state
        muted.videoLayers![0].clips[0].isMuted = true
        let muteMix = ProjectRenderer.multiVideoAudioMix(project: project, state: muted, plan: plan, segments: [segment])!
        try gain(muteMix.inputParameters[0], at: 5, equals: 0)

        let sample = project.videoSamples(at: 1).first { $0.clipID == first.id }!
        let portraitSize = CGSize(width: 1080, height: 1920), canvas = CGSize(width: 1920, height: 1080)
        let fit = VideoSampleDrawingGeometry(sample: sample, state: project.state, at: 1,
            sourceSize: portraitSize, primarySize: canvas, canvas: canvas)
        try near(fit.frame.height, 1080, "portrait fit reaches canvas height")
        try near(fit.frame.width, 607.5, "portrait fit preserves oriented aspect ratio")
        var filling = sample; filling.geometry.fit = .fill
        let fill = VideoSampleDrawingGeometry(sample: filling, state: project.state, at: 1,
            sourceSize: portraitSize, primarySize: canvas, canvas: canvas)
        try near(fill.frame.width, 1920, "fill covers canvas")
        try near(fill.viewport.height, 607.5, "fill crops original oriented source instead of stretching it")
        try near(fill.viewport.midY, 960, "fill crop remains centered")

        project.state.cuts = [.init(start: 3, end: 7, crossfade: 1)]
        let cutPlan = try MultiVideoRenderPlan(project: project)
        for assignments in Dictionary(grouping: cutPlan.trackAssignments, by: { "\($0.layerID):\($0.lane)" }).values {
            let ordered = assignments.sorted { $0.outputStart < $1.outputStart }
            try require(zip(ordered, ordered.dropFirst()).allSatisfy { $0.outputEnd <= $1.outputStart },
                "a pooled decoder lane never holds simultaneous occurrences")
        }
        try require(cutPlan.trackAssignments.allSatisfy { $0.lane < 4 }, "two local clips times two global branches bound decoder lanes")
        var sequence = RecordingProject(screenFilename: "never-open-sequence.mov", duration: 100)
        sequence.videoAssets = project.videoAssets
        sequence.state.videoLayers = [VideoLayer(name: "Sequence", clips: (0..<100).map {
            VideoClip(sourceID: project.videoAssets[0].id, start: Double($0), end: Double($0 + 1))
        })]
        let sequencePlan = try MultiVideoRenderPlan(project: sequence)
        try require(sequencePlan.trackAssignments.count == 100 && sequencePlan.trackAssignments.allSatisfy { $0.lane == 0 },
            "a long sequence reuses one decoder lane instead of allocating one per edit")
        let branches = cutPlan.timingMap.samples(at: 2.5)
        try require(branches.count == 2, "global crossfade has two complete project compositions")
        try near(branches[0].sourceTime, 2.5, "outgoing authoring instant")
        try near(branches[1].sourceTime, 7.5, "incoming authoring instant")
        try near(cutPlan.audioGain(project: project, state: project.state, clipID: overlay.id,
            branchIndex: branches[0].clipIndex, at: 2.5, role: nil), 0.1, "global cut weight multiplies clip audio")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try vectorDissolve(project: project)
        let pattern = EditorTestPattern()
        pattern.update(project: project, state: project.state, at: 2.5,
            outputSamples: branches.map { .init(sourceTime: $0.sourceTime, weight: $0.weight,
                zoom: project.state.zoom(at: $0.sourceTime), placement: project.state.placement(at: $0.sourceTime)) },
            in: CGRect(origin: .zero, size: canvas))
        try require(Set(pattern.videoSnapshots.map(\.branch)) == [0, 1], "vector preview samples both global branches")
        let incoming = pattern.videoSnapshots.first { $0.branch == 1 && $0.clipID == second.id }!
        try near(incoming.sourceTime, 3.5, "vector preview uses occurrence original-source clock")
        try near(incoming.weight, 0.5, "vector branch applies global dissolve weight")
        pattern.update(project: project, state: project.state, at: project.duration,
            outputSamples: [], in: CGRect(origin: .zero, size: canvas))
        try require(pattern.videoSnapshots.contains { $0.clipID == overlay.id }, "paused final endpoint shows last frame instead of disappearing")
        var empty = project.state; empty.videoLayers = []
        pattern.update(project: project, state: empty, at: 2, outputSamples: [], in: CGRect(origin: .zero, size: canvas))
        try require(pattern.videoSnapshots.isEmpty, "explicit no-video composition keeps only background")

        let editor = ProjectEditor(project: project, url: URL(fileURLWithPath: "/tmp/never-open-layered.framethrower"))
        let playback = EditorPlayback()
        await playback.rebuild(editor: editor)
        defer { playback.close() }
        playback.seekOutput(2.5)
        try require(playback.canPlay && !playback.hasMediaPlayer, "layered transport remains codec-free under the interlock")
        try require(playback.videoSamples(at: 7.5).contains { $0.clipID == second.id }, "playback exposes source-local samples")
        var draft = project.state; draft.videoLayers![1].clips[0].opacity = 0.1
        playback.preview(draft)
        try near(playback.videoSamples(at: 7.5).first { $0.clipID == overlay.id }!.opacity, 0.1,
            "preview samples transient layer edits without losing source clocks")
        do {
            _ = try await ProjectRenderer.makePreview(project: project, directory: URL(fileURLWithPath: "/tmp"))
            throw Failure.failed("media renderer bypassed the interlock")
        } catch is MediaProcessing.Suspended { }
        print("Multi-video rendering checks passed: source/global clock plans, independent occurrence IDs, grouped blend alpha, portrait fit/fill, clip-envelope audio, muted tracks, global cut branches, vector preview and suspended transport; no media.")
    }

    static func gain(_ parameter: AVAudioMixInputParameters, at seconds: Double, equals expected: Double) throws {
        var start: Float = 0, end: Float = 0, range = CMTimeRange.invalid
        try require(parameter.getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 60_000),
            startVolume: &start, endVolume: &end, timeRange: &range), "gain ramp exists")
        let fraction = range.duration.seconds > 0 ? (seconds - range.start.seconds) / range.duration.seconds : 0
        try near(Double(start) + (Double(end) - Double(start)) * fraction, expected, "actual AV gain", tolerance: 0.001)
    }

    /// Rasterize only the static native paths/text above into a tiny CPU bitmap
    /// to verify the documented CGContext grouping math. No media input, CI
    /// compositor, decoder, scaling driver, fixture movie or AVAsset is used.
    static func vectorDissolve(project: RecordingProject) throws {
        let size = CGSize(width: 64, height: 36)
        let samples = project.videoSamples(at: 2)
        let first = samples.first { $0.sourceID == project.videoAssets[0].id }!
        var second = first; second.sourceID = project.videoAssets[1].id
        let sourceA = project.videoAssets[0], sourceB = project.videoAssets[1]
        var a = EditorVideoVectorDrawing.Clip(source: sourceA, sourceSize: sourceA.pixelSize!,
            geometry: VideoSampleDrawingGeometry(sample: first, state: project.state, at: 2,
                sourceSize: sourceA.pixelSize!, primarySize: size, canvas: size), weight: 1)
        var b = EditorVideoVectorDrawing.Clip(source: sourceB, sourceSize: sourceB.pixelSize!,
            geometry: VideoSampleDrawingGeometry(sample: second, state: project.state, at: 2,
                sourceSize: sourceB.pixelSize!, primarySize: size, canvas: size), weight: 1)
        func pixels(_ clips: [EditorVideoVectorDrawing.Clip], flippedHost: Bool = false) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 64 * 36 * 4)
            try bytes.withUnsafeMutableBytes { storage in
                guard let context = CGContext(data: storage.baseAddress, width: 64, height: 36,
                    bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                    throw Failure.failed("static vector CPU drawing context")
                }
                if flippedHost {
                    context.translateBy(x: 0, y: size.height)
                    context.scaleBy(x: 1, y: -1)
                }
                EditorVideoVectorDrawing.draw(.init(size: size, background: .init(red: 0.1, green: 0.15, blue: 0.2),
                    branches: [.init(weight: 1, layers: [clips])]), in: context,
                    coordinates: flippedHost ? .topLeft : .bottomLeft)
                context.flush()
            }
            return bytes
        }
        let upright = try pixels([b])
        let flippedHost = try pixels([b], flippedHost: true)
        try require(upright == flippedHost, "already-flipped layer context preserves asymmetric chart rows and upright labels")
        let rowSize = 64 * 4
        try require(Array(upright.prefix(rowSize * 9)) != Array(upright.suffix(rowSize * 9)),
            "orientation fixture must distinguish chart top and bottom")
        for alpha in [(1.0, 1.0), (0.4, 0.8)] {
            a.geometry.opacity = alpha.0; b.geometry.opacity = alpha.1
            a.weight = 1; b.weight = 1
            let onlyA = try pixels([a]), onlyB = try pixels([b])
            a.weight = 0.5; b.weight = 0.5
            let blended = try pixels([a, b])
            let error = zip(blended.indices, blended).map { index, actual in
                abs(Double(actual) - (Double(onlyA[index]) + Double(onlyB[index])) / 2)
            }.max()!
            try require(error <= 3, "actual vector grouped crossdissolve has no dark dip (maximum channel error \(error))")
        }
    }
}
