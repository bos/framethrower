@preconcurrency import AVFoundation
import Foundation

private enum CheckError: Error { case failed(String) }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckError.failed(message) }
}

private func sample(at time: CMTime) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else { throw CheckError.failed("pixel buffer") }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<48 {
            for x in 0..<64 {
                let offset = y * stride + x * 4
                bytes[offset] = 20
                bytes[offset + 1] = 80
                bytes[offset + 2] = 220
                bytes[offset + 3] = 255
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
    ) == noErr, let format else { throw CheckError.failed("format") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
        sampleTiming: &timing, sampleBufferOut: &sample
    ) == noErr, let sample else { throw CheckError.failed("sample") }
    return sample
}

private func finish(_ writer: CameraTrackWriter) async throws {
    try await withCheckedThrowingContinuation { continuation in
        writer.finish { continuation.resume(with: $0) }
    }
}

@main
struct CameraRecordingChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("camera.mov")
        let writer = CameraTrackWriter(url: url)
        // Real capture timestamps are on a long-running clock, not zero-based.
        for frame in 0..<15 {
            let pts = CMTime(value: 3000 + Int64(frame), timescale: 30)
            let buffer = try sample(at: pts)
            let deadline = Date().addingTimeInterval(5)
            while try !writer.append(buffer, hostTime: 100 + Double(frame) / 30) {
                try require(Date() < deadline, "encoder stalled")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        try await finish(writer)
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try require(video.count == 1, "camera source must contain exactly one video track")
        try require(audio.isEmpty, "camera must not change or duplicate microphone capture")
        let range = try await video[0].load(.timeRange)
        try require(abs(range.start.seconds) < 0.001, "written source must begin at zero despite host-clock PTS")
        let duration = try await asset.load(.duration).seconds
        try require(abs(duration - 0.5) < 0.05, "source duration must preserve the camera frame timeline")
        let size = try await video[0].load(.naturalSize)
        try require(size == CGSize(width: 64, height: 48), "source must retain full captured dimensions")
        do {
            try writer.append(sample(at: CMTime(value: 3015, timescale: 30)), hostTime: 100.5)
            throw CheckError.failed("append after finish should fail")
        } catch is CameraRecordingError {}

        let sourceBytes = try Data(contentsOf: url)
        let overwrite = CameraTrackWriter(url: url)
        do {
            try overwrite.append(sample(at: CMTime(value: 1, timescale: 30)), hostTime: 1)
            throw CheckError.failed("existing camera source should not be overwritten")
        } catch let error as CheckError { throw error }
        catch {}
        let sourceBytesAfter = try Data(contentsOf: url)
        try require(sourceBytesAfter == sourceBytes, "existing media bytes changed")

        let empty = CameraTrackWriter(url: directory.appendingPathComponent("empty.mov"))
        do {
            try await finish(empty)
            throw CheckError.failed("empty capture should fail")
        } catch is CameraRecordingError {}

        let invalid = CameraTrackWriter(url: directory.appendingPathComponent("invalid.mov"))
        do {
            try invalid.append(sample(at: .zero), hostTime: .nan)
            throw CheckError.failed("invalid synchronization timestamp should fail")
        } catch is CameraRecordingError {}
        let invalidSource = CameraTrackWriter(url: directory.appendingPathComponent("invalid-source.mov"))
        do {
            try invalidSource.append(sample(at: .invalid), hostTime: 1)
            throw CheckError.failed("invalid source presentation timestamp should fail")
        } catch is CameraRecordingError {}
        print("Camera recording checks passed (synthetic video, timeline, source preservation, and failures).")
    }
}
