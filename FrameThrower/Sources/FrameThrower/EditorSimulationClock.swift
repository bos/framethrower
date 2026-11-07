import Foundation

/// Source-time transport for a vector-only preview. The host supplies a
/// monotonic timestamp; no media clock, source file, or rendering is involved.
struct EditorSimulationClock: Equatable, Sendable {
    static let supportedRates: [Double] = [0.5, 1, 2, 5]
    let bounds: ClosedRange<Double>
    private(set) var time: Double
    private(set) var isPlaying = false
    private(set) var rate = 1.0
    private var startedAt = 0.0
    private var startedFrom = 0.0

    init(bounds: ClosedRange<Double>, time: Double) {
        self.bounds = bounds
        self.time = time.isFinite ? time : bounds.lowerBound
    }

    mutating func play(at timestamp: Double, rate requestedRate: Double? = nil) {
        guard timestamp.isFinite, bounds.upperBound > bounds.lowerBound, !isPlaying else { return }
        if let requestedRate {
            guard Self.supportedRates.contains(requestedRate) else { return }
            rate = requestedRate
        }
        if time < bounds.lowerBound || time >= bounds.upperBound { time = bounds.lowerBound }
        startedFrom = time
        startedAt = timestamp
        isPlaying = true
    }

    mutating func advance(to timestamp: Double) {
        guard isPlaying, timestamp.isFinite else { return }
        time = min(bounds.upperBound, max(time, startedFrom + max(0, timestamp - startedAt) * rate))
        if time >= bounds.upperBound { isPlaying = false }
    }

    mutating func pause(at timestamp: Double) {
        advance(to: timestamp)
        isPlaying = false
    }

    /// Account for elapsed time at the old speed, then start a new segment.
    /// A paused rate change never changes its inspected source position.
    @discardableResult
    mutating func setRate(_ newRate: Double, at timestamp: Double) -> Bool {
        guard timestamp.isFinite, Self.supportedRates.contains(newRate) else { return false }
        advance(to: timestamp)
        rate = newRate
        startedFrom = time
        startedAt = timestamp
        return true
    }

    /// Scrubbing cancels the old time origin, so a delayed callback cannot
    /// move the playhead after the user chooses a new source position.
    mutating func seek(_ position: Double) {
        isPlaying = false
        time = position.isFinite ? position : bounds.lowerBound
    }
}
