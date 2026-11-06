@preconcurrency import AVFoundation
import Foundation

/// Both the editor's AVPlayerItem and exported movie use this exact composition.
/// Times remain in source seconds; trimming is applied only when playing/exporting.
struct RenderedProject {
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    let screenSize: CGSize
    let cameraAspect: Double
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
            case .destinationExists: return "Export needs a new file; existing files and original recordings are never replaced."
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
        let renderSize = CGSize(
            width: max(2, (sourceGeometry.size.width / 2).rounded() * 2),
            height: max(2, (sourceGeometry.size.height / 2).rounded() * 2)
        )
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

        let screenLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: screenTrack)
        screenLayer.setTransform(sourceGeometry.transform.concatenating(CGAffineTransform(
            scaleX: renderSize.width / sourceGeometry.size.width,
            y: renderSize.height / sourceGeometry.size.height
        )), at: .zero)
        var layers: [AVVideoCompositionLayerInstruction] = [screenLayer]
        var cameraAspect = 16.0 / 9.0

        if let cameraFilename = project.cameraFilename {
            let cameraAsset = AVURLAsset(url: directory.appendingPathComponent(cameraFilename))
            guard let cameraSource = try await cameraAsset.loadTracks(withMediaType: .video).first else {
                throw RenderError.invalidVideo(cameraFilename)
            }
            let cameraGeometry = try await geometry(of: cameraSource)
            cameraAspect = cameraGeometry.size.width / cameraGeometry.size.height
            let cameraDuration = try await cameraAsset.load(.duration).seconds
            guard cameraDuration.isFinite, cameraDuration > 0, project.cameraOffset.isFinite else {
                throw RenderError.invalidVideo(cameraFilename)
            }
            let cameraStart = max(0, project.cameraOffset)
            let cameraEnd = min(duration, project.cameraOffset + cameraDuration)
            if cameraEnd > cameraStart, time(cameraEnd - cameraStart) > .zero {
                guard let cameraTrack = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { throw RenderError.cannotExport }
                try cameraTrack.insertTimeRange(
                    CMTimeRange(start: time(max(0, -project.cameraOffset)), duration: time(cameraEnd - cameraStart)),
                    of: cameraSource, at: time(cameraStart)
                )
                let cameraLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: cameraTrack)
                configureCamera(
                    cameraLayer, state: project.state, geometry: cameraGeometry,
                    renderSize: renderSize, start: cameraStart, end: cameraEnd
                )
                layers.insert(cameraLayer, at: 0)
            }
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = wholeRange
        instruction.layerInstructions = layers
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]
        return RenderedProject(
            asset: composition, videoComposition: videoComposition,
            screenSize: renderSize, cameraAspect: cameraAspect
        )
    }

    static func export(project: RecordingProject, directory: URL, to destination: URL) async throws {
        let originalURLs = [project.screenFilename, project.cameraFilename].compactMap { $0 }.map {
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

    private struct Geometry {
        let size: CGSize
        let transform: CGAffineTransform
    }

    private static func geometry(of track: AVAssetTrack) async throws -> Geometry {
        let naturalSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferred).standardized
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw RenderError.cannotExport
        }
        return Geometry(
            size: bounds.size,
            transform: preferred.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        )
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }

    private static func configureCamera(
        _ layer: AVMutableVideoCompositionLayerInstruction, state: EditState,
        geometry: Geometry, renderSize: CGSize, start: Double, end: Double
    ) {
        let aspect = geometry.size.width / geometry.size.height
        func transform(at seconds: Double) -> CGAffineTransform {
            let frame = state.placement(at: seconds).frame(in: renderSize, cameraAspect: aspect)
            // AVVideoComposition transforms use top-left coordinates, just like the editor.
            return geometry.transform
                .concatenating(CGAffineTransform(scaleX: frame.width / geometry.size.width, y: frame.height / geometry.size.height))
                .concatenating(CGAffineTransform(translationX: frame.minX, y: frame.minY))
        }
        let points = state.pipKeyframes.sorted { $0.time < $1.time }
        var boundaries = Set([start, end])
        var smoothRanges: [ClosedRange<Double>] = []
        for (index, point) in points.enumerated() {
            if point.time > start, point.time < end { boundaries.insert(point.time) }
            guard index > 0, point.transition == .smooth, point.duration > 0 else { continue }
            let beginning = max(points[index - 1].time, point.time - point.duration)
            let low = max(start, beginning)
            let high = min(end, point.time)
            guard high > low else { continue }
            smoothRanges.append(low...high)
            boundaries.insert(low)
            boundaries.insert(high)
            // Sample easing only during actual movement, never throughout long holds.
            let steps = max(1, Int(ceil((high - low) * 30)))
            for step in 1..<steps {
                boundaries.insert(low + (high - low) * Double(step) / Double(steps))
            }
        }
        // Canonicalize to the composition timebase so near-identical saved
        // timestamps cannot create zero-length or overlapping transform ramps.
        let times = Set(boundaries.map { time($0).value }).sorted().map { Double($0) / 60_000 }
        for index in 0..<(times.count - 1) {
            let a = times[index]
            let b = times[index + 1]
            if smoothRanges.contains(where: { $0.contains((a + b) / 2) }) {
                layer.setTransformRamp(
                    fromStart: transform(at: a), toEnd: transform(at: b),
                    timeRange: CMTimeRange(start: time(a), duration: time(b - a))
                )
            } else {
                layer.setTransform(transform(at: a), at: time(a))
            }
        }
        // Visibility changes are discrete; a missing camera segment stays transparent.
        if start > 0 { layer.setOpacity(0, at: .zero) }
        layer.setOpacity(state.placement(at: start).visible ? 1 : 0, at: time(start))
        for point in points where point.time > start && point.time < end {
            layer.setOpacity(point.placement.visible ? 1 : 0, at: time(point.time))
        }
        layer.setOpacity(0, at: time(end))
    }
}
