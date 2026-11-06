@preconcurrency import AVFoundation
import Foundation

private enum CadenceCheckError: Error { case failed(String) }
private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CadenceCheckError.failed(message) }
}

@main
@MainActor
struct RenderCadenceChecks {
    static func main() async throws {
        try modelChecks()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-cadence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("sparse60.mov")
        let writer = try ScreenMasterWriter(url: source, width: 64, height: 48, audioTracks: [],
            frameDuration: CMTime(value: 1, timescale: 60), onFirstVideo: { _ in }, onFailure: { _ in })
        try require(writer.append(try sample(at: 100), track: .video, hostTime: 500), "sparse master first picture")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.finish(at: CMTime(seconds: 103, preferredTimescale: 60_000)) { continuation.resume(with: $0) }
        }
        let sourceBytes = try Data(contentsOf: source)
        let sourceAsset = AVURLAsset(url: source)
        let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video)[0]
        let averageRate = try await sourceTrack.load(.nominalFrameRate)
        try require(averageRate < 1, "fixture must represent ScreenCaptureKit's static-screen sparse sampling")
        try require(try countPictures(sourceAsset, track: sourceTrack) == 2, "fixture should contain only first and closing pictures")

        for cadence in [Optional(1.0 / 60), nil] {
            let project = RecordingProject(screenFilename: source.lastPathComponent, duration: 3, captureFrameDuration: cadence)
            let expectedRate = cadence == nil ? 30 : 60
            let rendered = try await ProjectRenderer.makePreview(project: project, directory: directory)
            try require(abs(rendered.videoComposition.frameDuration.seconds - 1 / Double(expectedRate)) < 0.000001,
                        "preview must use stored capture policy or the legacy30fps default, never sparse average rate")
            let revised = ProjectRenderer.preview(rendered, applying: project.state)
            try require(revised.videoComposition.frameDuration == rendered.videoComposition.frameDuration,
                        "live preview changes must preserve the render cadence")
            for preset in VideoExportPreset.allCases {
                let exported = directory.appendingPathComponent("export-\(expectedRate)-\(preset.rawValue).mp4")
                try await ProjectRenderer.export(project: project, directory: directory, to: exported, preset: preset)
                let asset = AVURLAsset(url: exported)
                let track = try await asset.loadTracks(withMediaType: .video)[0]
                let rate = try await track.load(.nominalFrameRate)
                let minimum = try await track.load(.minFrameDuration).seconds
                try require(abs(Double(rate) - Double(expectedRate)) < 0.01 && abs(minimum - 1 / Double(expectedRate)) < 0.000001,
                            "compressed export must retain the composition cadence for\(preset.rawValue): expected\(expectedRate), actual\(rate)")
                try require(try countPictures(asset, track: track) == expectedRate * 3,
                            "export must render every motion frame despite a source with only two stored pictures")
            }
        }
        try require(try Data(contentsOf: source) == sourceBytes, "cadence changes and export must preserve original video bytes")
        print("Render cadence checks passed (legacy JSON30fps, immutable60fps metadata, invalid hints, sparse ProRes preview/live edits, and actual30/60fps compressed exports).")
    }

    private static func modelChecks() throws {
        let legacy = RecordingProject(screenFilename: "screen.mov", duration: 3)
        let data = try JSONEncoder().encode(legacy)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try require(object["captureFrameDuration"] == nil, "legacy projects omit optional cadence")
        let decoded = try JSONDecoder().decode(RecordingProject.self, from: data)
        try decoded.validate()
        try require(decoded.captureFrameDuration == nil, "legacy project decode must retain the30fps fallback")
        let sixty = RecordingProject(screenFilename: "screen.mov", duration: 3, captureFrameDuration: 1.0 / 60)
        let restored = try JSONDecoder().decode(RecordingProject.self, from: JSONEncoder().encode(sixty))
        try restored.validate()
        try require(restored.captureFrameDuration == sixty.captureFrameDuration, "capture cadence must survive saving and reopening")
        for duration in [Double.nan, .infinity, -.infinity, 0, -1, 1.0 / 121, 1.01] {
            let invalid = RecordingProject(screenFilename: "screen.mov", duration: 3, captureFrameDuration: duration)
            do { try invalid.validate(); throw CadenceCheckError.failed("invalid capture cadence accepted: \(duration)") }
            catch is ProjectError { }
        }
        for duration in [1.0 / 120, 1.0] {
            try RecordingProject(screenFilename: "screen.mov", duration: 3, captureFrameDuration: duration).validate()
        }
        var malformed = object
        malformed["captureFrameDuration"] = "sixty"
        do {
            _ = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: malformed))
            throw CadenceCheckError.failed("malformed cadence JSON accepted")
        } catch is DecodingError { }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-cadence-model-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ProjectEditor(project: sixty, url: directory.appendingPathComponent("test.framethrower"))
        try require(editor.save(), "save cadence model fixture")
        var edited = sixty.state
        edited.zoomKeyframes = [ZoomKeyframe(time: 1, scale: 2)]
        try require(editor.commit(edited, name: "Edit") && editor.undo() && editor.redo() && editor.project.captureFrameDuration == sixty.captureFrameDuration,
                    "capture cadence is source metadata and must not change with edit undo/redo")
    }

    private static func countPictures(_ asset: AVAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        try require(reader.startReading(), "cadence sample reader")
        defer { reader.cancelReading() }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 && CMSampleBufferGetTotalSampleSize(sample) > 0 { count += 1 }
        }
        return count
    }

    private static func sample(at seconds: Double) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        try require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess, "cadence fixture pixels")
        guard let pixels else { throw CadenceCheckError.failed("cadence fixture image") }
        CVPixelBufferLockBaseAddress(pixels, [])
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<48 { for x in 0..<64 {
            let offset = y * row + x * 4
            base[offset] = 32; base[offset + 1] = 128; base[offset + 2] = 224; base[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        try require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescriptionOut: &format) == noErr, "cadence fixture format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60_000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        try require(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &buffer) == noErr, "cadence fixture sample")
        return buffer!
    }
}
