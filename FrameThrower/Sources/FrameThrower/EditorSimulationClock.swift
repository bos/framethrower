import Foundation

/// Source-time transport for a vector-only preview. The host supplies a
/// monotonic timestamp; no media clock, source file, or rendering is involved.
struct EditorSimulationClock: Equatable, Sendable {
    let bounds: ClosedRange<Double>
    private(set) var time: Double
    private(set) var isPlaying = false
    private var startedAt = 0.0
    private var startedFrom = 0.0

    init(bounds: ClosedRange<Double>, time: Double) {
        self.bounds = bounds
        self.time = time.isFinite ? time : bounds.lowerBound
    }

    mutating func play(at timestamp: Double) {
        guard timestamp.isFinite, bounds.upperBound > bounds.lowerBound, !isPlaying else { return }
        if time < bounds.lowerBound || time >= bounds.upperBound { time = bounds.lowerBound }
        startedFrom = time
        startedAt = timestamp
        isPlaying = true
    }

    mutating func advance(to timestamp: Double) {
        guard isPlaying, timestamp.isFinite else { return }
        time = min(bounds.upperBound, max(time, startedFrom + max(0, timestamp - startedAt)))
        if time >= bounds.upperBound { isPlaying = false }
    }

    mutating func pause(at timestamp: Double) {
        advance(to: timestamp)
        isPlaying = false
    }

    /// Scrubbing cancels the old time origin, so a delayed callback cannot
    /// move the playhead after the user chooses a new source position.
    mutating func seek(_ position: Double) {
        isPlaying = false
        time = position.isFinite ? position : bounds.lowerBound
    }
}
