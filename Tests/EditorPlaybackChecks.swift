@preconcurrency import AVFoundation
import Foundation

private enum PlaybackCheckError: Error { case failed(String), cancelled }

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PlaybackCheckError.failed(message) }
}

/// Deliberately ignores cancellation until finish() is called. Real decoder
/// cancellation also completes asynchronously, so a new request must wait.
@MainActor
private final class DecoderProbe {
    var started: [Int] = []
    var cancelled: [Int] = []
    var delivered: [Int] = []
    var failed: [Int] = []
    var maximumActive = 0
    private var continuations: [Int: CheckedContinuation<Int, any Error>] = [:]

    func generate(_ id: Int) async throws -> Int {
        started.append(id)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            maximumActive = max(maximumActive, continuations.count)
        }
    }

    func finish(_ id: Int, fails: Bool = false) throws {
        guard let continuation = continuations.removeValue(forKey: id) else {
            throw PlaybackCheckError.failed("request \(id) was not active")
        }
        if fails { continuation.resume(throwing: PlaybackCheckError.cancelled) }
        else { continuation.resume(returning: id) }
    }

    func submit(_ id: Int, to queue: LatestStillFrameQueue<Int>) {
        queue.request(generate: { try await self.generate(id) },
                      cancel: { self.cancelled.append(id) },
                      receive: { self.delivered.append($0) },
                      failure: { self.failed.append(id) })
    }
}

@main
struct EditorPlaybackChecks {
    @MainActor
    private static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @MainActor
    static func main() async throws {
        let queue = LatestStillFrameQueue<Int>()
        let decoder = DecoderProbe()
        decoder.submit(1, to: queue)
        await settle()
        try require(decoder.started == [1], "initial decode did not start")
        for id in 2...1000 { decoder.submit(id, to: queue) }
        await settle()
        try require(decoder.started == [1], "scrubbing spawned overlapping decoder work")
        try require(decoder.cancelled == [1], "active decoder cancellation should happen once")
        try decoder.finish(1)
        await settle()
        try require(decoder.delivered.isEmpty, "obsolete frame was delivered")
        try require(decoder.started == [1, 1000], "pending seeks were not coalesced to newest frame")
        try decoder.finish(1000)
        await settle()
        try require(decoder.delivered == [1000], "latest frame did not arrive")
        try require(decoder.maximumActive == 1, "more than one decoder was active")

        // Rebuild/play/close all invalidate through the same path. An old
        // operation that succeeds despite cancellation must still be discarded.
        decoder.submit(1001, to: queue)
        await settle()
        decoder.submit(1002, to: queue)
        queue.invalidate()
        try decoder.finish(1001)
        await settle()
        try require(decoder.started == [1, 1000, 1001], "invalidated pending work was started")
        try require(decoder.delivered == [1000], "invalidated frame was delivered")
        decoder.submit(1003, to: queue)
        await settle()
        decoder.submit(1004, to: queue)
        try decoder.finish(1003, fails: true)
        await settle()
        try require(decoder.started.last == 1004, "decode failure prevented newest request")
        try decoder.finish(1004)
        await settle()
        try require(decoder.delivered == [1000, 1004], "queue did not recover after cancellation failure")
        try require(decoder.failed.isEmpty, "obsolete decoder error reached current preview")

        // Invalidation also suppresses work that has not reached the worker yet.
        decoder.submit(1005, to: queue)
        queue.invalidate()
        await settle()
        try require(!decoder.started.contains(1005), "queued decode survived immediate close")
        decoder.submit(1006, to: queue)
        await settle()
        try decoder.finish(1006, fails: true)
        await settle()
        try require(decoder.failed == [1006], "current decode error did not clear the stale preview")

        let range = 1.0...1.01 // Shorter than a 30 fps frame, with a nonzero in point.
        let end = EditorPlayback.frameTime(at: range.upperBound, bounds: range).seconds
        try require(end >= range.lowerBound && end < range.upperBound,
                    "sub-frame trim must seek inside retained interval")
        try require(end > 1.009, "end seek jumped back to trim start")
        try require(EditorPlayback.frameTime(at: -100, bounds: range).seconds == range.lowerBound,
                    "seek before trim start was not clamped")
        try require(EditorPlayback.frameTime(at: .nan, bounds: range).seconds == range.lowerBound,
                    "non-finite seek was not clamped")
        let ordinary = EditorPlayback.frameTime(at: 3, bounds: 0...10).seconds
        try require(abs(ordinary - 3) < 0.000001, "ordinary seek position changed")
        let fractionalEnd = EditorPlayback.frameTime(at: 1.0 / 30, bounds: 0...(1.0 / 30)).seconds
        try require(fractionalEnd >= 0 && fractionalEnd < 1.0 / 30,
                    "fractional media end must remain exclusive")

        let playback = EditorPlayback()
        playback.close()
        playback.seek(10)
        playback.togglePlayback()
        playback.close()
        try require(playback.stillFrame == nil && !playback.isPlaying && !playback.isLoading,
                    "closed player accepted new playback work")
        print("Editor playback checks passed (1000 coalesced seeks, cancellation, stale results, recovery, and exclusive bounds).")
    }
}
