import Foundation

private struct SpeedTimingFailure: Error { let message: String }
@main @MainActor
struct RecordingSpeedTimeMapChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw SpeedTimingFailure(message: message) }
    }
    static func close(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 1e-9) throws {
        try require(abs(actual - expected) <= tolerance, "\(message): \(actual) != \(expected)")
    }
    static func map(_ points: [RecordingSpeedKeyframe], cuts: [RecordingCut] = [],
                    start: Double = 0, end: Double = 10) throws -> RecordingTimeMap {
        try RecordingTimeMap(duration: 10, trimStart: start, trimEnd: end, cuts: cuts, speedKeyframes: points)
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "Speed tests must not process media")
        try constantAndJumps(); try smoothTiming(); try cutsAndTrims(); try invalidCurves()
        print("Recording speed timing checks passed: source/output round trips, smooth ramps, bounded shared retime cells, hard changes, cuts/crossfades, trim restoration and invalid metadata; no media.")
    }
    static func constantAndJumps() throws {
        let baseline = try map([])
        try require(baseline.clips[0].segments.count == 1, "Normal footage needs one timing cell")
        try close(baseline.outputDuration, 10, "Unedited duration")
        let double = try map([.init(time: 0, rate: 2, transition: .jump)])
        try close(double.outputDuration, 5, "2x halves duration")
        try require(double.clips[0].segments.count == 1, "Constant rates do not produce frame-by-frame metadata")
        try close(double.samples(at: 1)[0].sourceTime, 2, "2x sampling")
        let points: [RecordingSpeedKeyframe] = [.init(time: 2, rate: 2, transition: .jump), .init(time: 6, rate: 1, transition: .jump)]
        let jumps = try map(points)
        try close(jumps.outputDuration, 8, "2x only in source2...6")
        try close(jumps.outputTime(for: 6)!, 4, "Source change arrival")
        try close(jumps.samples(at: 2)[0].sourceTime, 2, "Exact hard change")
        try close(jumps.samples(at: 4)[0].sourceTime, 6, "Return to normal")
        for tick in 0...1000 {
            let output = jumps.outputDuration * Double(tick) / 1000
            let sample = jumps.samples(at: output)[0]
            try close(jumps.outputTime(for: sample.sourceTime)!, output, "Hard-rate inverse round trip")
        }
        let slow = try map([.init(time: 0, rate: 0.1, transition: .jump)])
        try close(slow.outputDuration, 100, "Slow motion duration")
    }
    static func smoothTiming() throws {
        let points: [RecordingSpeedKeyframe] = [.init(time: 6, rate: 3, duration: 6, easeIn: 0, easeOut: 0)]
        let curve = try map(points)
        // With zero ramps shared interpolation is a linear speed, not a linear
        // time map. Its exact output integral is 3*log(1+source/3).
        try close(curve.outputDuration, 3 * log(3) + 4.0 / 3, "Reciprocal speed integral", tolerance: 1e-8)
        try require(curve.clips[0].segments.count > 2 && curve.clips[0].segments.count < 2000, "Adaptive, bounded cells")
        for tick in 0...600 {
            let source = Double(tick) / 100
            let output = curve.outputTime(for: source)!
            try close(output, 3 * log(1 + source / 3), "Linear cells stay within sub-frame timing error", tolerance: 0.00012)
            try close(curve.samples(at: output)[0].sourceTime, source, "Smooth clock inverse", tolerance: 1e-8)
        }
        let smooth: [RecordingSpeedKeyframe] = [.init(time: 8, rate: 5, duration: 6, easeIn: 1.2, easeOut: 2)]
        try close(RecordingRetime.rate(at: 2, points: smooth), 1, "Hold before acceleration")
        try close(RecordingRetime.rate(at: 8, points: smooth), 5, "Target rate persists")
        let epsilon = 0.00001
        try require(abs(RecordingRetime.rate(at: 2 + epsilon, points: smooth) - 1) / epsilon < 0.001,
                    "Ramp begins flat")
        try require(abs(5 - RecordingRetime.rate(at: 8 - epsilon, points: smooth)) / epsilon < 0.001,
                    "Ramp ends flat")
        // Independent midpoint integral, not the production quadrature.
        let count = 100_000, step = 10.0 / Double(count)
        let reference = (0..<count).reduce(0.0) { sum, index in
            sum + step / RecordingRetime.rate(at: (Double(index) + 0.5) * step, points: smooth)
        }
        try close(try map(smooth).outputDuration, reference, "Eased rate independent integral", tolerance: 1e-7)
        let repeated = try map(smooth)
        try require(repeated == (try map(smooth)), "Timing plan deterministic")
        for cell in repeated.clips[0].segments {
            try require(cell.sourceEnd > cell.sourceStart && cell.outputEnd > cell.outputStart && cell.rate > 0, "Every retime cell monotone")
        }
    }
    static func cutsAndTrims() throws {
        let points: [RecordingSpeedKeyframe] = [.init(time: 0, rate: 2, transition: .jump)]
        let cut = RecordingCut(start: 2, end: 4, crossfade: 0.5)
        let composed = try map(points, cuts: [cut])
        try close(composed.outputDuration, 3.5, "Crossfade stays in output seconds after retiming")
        try close(composed.joins[0].outputStart, 0.5, "Retimed overlap start")
        try close(composed.joins[0].outputEnd, 1, "Retimed overlap end")
        let samples = composed.samples(at: 0.75)
        try require(samples.count == 2, "Both retimed branches exist")
        try close(samples[0].sourceTime, 1.5, "Outgoing source clock")
        try close(samples[1].sourceTime, 4.5, "Incoming source clock")
        try close(samples[0].weight, 0.5, "Crossfade alpha")
        let trimmed = try map(points, start: 2, end: 8)
        try close(trimmed.outputDuration, 3, "Trim does not reset speed")
        try close(trimmed.samples(at: 0)[0].sourceTime, 2, "Trim source origin")
        let speedInsideCut: [RecordingSpeedKeyframe] = [.init(time: 3, rate: 2, transition: .jump)]
        let skipped = try map(speedInsideCut, cuts: [.init(start: 2, end: 4)])
        try close(skipped.outputDuration, 5, "Rate set in omitted source still applies to retained successor")
        try close(skipped.samples(at: 3)[0].sourceTime, 6, "Retained successor uses new rate")
        let constrained = try map(points, cuts: [.init(start: 2, end: 3, crossfade: 10), .init(start: 4, end: 5, crossfade: 10)])
        for index in constrained.clips.indices {
            let incoming = index > 0 ? constrained.joins[index - 1].duration : 0
            let outgoing = index < constrained.joins.count ? constrained.joins[index].duration : 0
            let clip = constrained.clips[index]
            try require(incoming + outgoing <= clip.outputEnd - clip.outputStart + 1e-12, "Fade budget uses retimed clip length")
        }
    }
    static func invalidCurves() throws {
        let id = UUID()
        let invalid: [[RecordingSpeedKeyframe]] = [
            [.init(time: -1, rate: 2)], [.init(time: 11, rate: 2)], [.init(time: .nan, rate: 2)],
            [.init(time: 0, rate: 0)], [.init(time: 0, rate: .infinity)], [.init(time: 0, rate: 8.1)],
            [.init(time: 2, rate: 2, duration: 0)], [.init(time: 2, rate: 2, easeOut: -1)],
            [.init(time: 2, rate: 2), .init(time: 1, rate: 1)],
            [.init(time: 2, rate: 2), .init(time: 2, rate: 3)],
            [.init(id: id, time: 1, rate: 2), .init(id: id, time: 2, rate: 3)]]
        for points in invalid {
            var rejected = false
            do { _ = try map(points) } catch { rejected = true }
            try require(rejected, "Invalid speed metadata rejected")
        }
    }
}
