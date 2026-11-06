import Foundation

/// Conservative, editable zooms derived from recorded clicks. Nearby activity
/// shares one focus; long gaps return to context instead of following every tap.
enum CursorZoomSuggestions {
    enum Preset: String, CaseIterable, Sendable {
        case subtle
        case focused

        var title: String { rawValue.capitalized }
        var scale: Double { self == .subtle ? 1.5 : 2 }
    }

    static func points(in recording: CursorRecording, range: ClosedRange<Double>, preset: Preset,
                       frameDuration: Double = 1.0 / 30) -> [ZoomKeyframe] {
        guard recording.duration.isFinite, recording.duration > 0,
              range.lowerBound.isFinite, range.upperBound.isFinite,
              frameDuration.isFinite, frameDuration > 0 else { return [] }
        let lower = max(0, range.lowerBound)
        let upper = min(recording.duration, range.upperBound)
        guard upper > lower, (upper / frameDuration).isFinite,
              upper / frameDuration < Double(Int.max) / 2 else { return [] }
        // Small rounding tolerance retains exact frame boundaries represented
        // a few ulps to either side; the upper bound remains exclusive.
        let firstFrame = max(0, Int(ceil(lower / frameDuration - 0.000_000_1)))
        let lastFrame = Int(ceil(upper / frameDuration - 0.000_000_1)) - 1
        guard lastFrame >= firstFrame else { return [] }
        let clicks = recording.clicks.filter {
            $0.time.isFinite && $0.time >= lower && $0.time < upper &&
            $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) &&
            ($0.button == 0 || $0.button == 1)
        }.sorted { $0.time < $1.time }
        guard !clicks.isEmpty else { return [] }
        var bursts: [Burst] = []
        for click in clicks {
            if let last = bursts.last, click.time - last.last <= 1.2,
               hypot(click.x - last.x, click.y - last.y) <= 0.2 {
                bursts[bursts.count - 1].append(click)
            } else {
                bursts.append(Burst(click))
            }
        }
        // Keep a long recording editable: at most sixty uniformly distributed
        // bursts, preserving both ends and returning wide between omitted work.
        if bursts.count > 60 {
            let source = bursts
            bursts = (0..<60).map { source[Int((Double($0) * Double(source.count - 1) / 59).rounded())] }
        }
        func frame(_ seconds: Double) -> Int {
            min(lastFrame, max(firstFrame, Int((min(upper, max(lower, seconds)) / frameDuration).rounded())))
        }
        func holdFrame(_ seconds: Double) -> Int {
            min(lastFrame, max(firstFrame, Int(ceil(min(upper, max(lower, seconds)) / frameDuration - 0.000_000_1))))
        }
        let transition = 0.4
        let transitionFrames = max(1, min(lastFrame - firstFrame + 1,
            Int(ceil(min(transition, upper - lower) / frameDuration))))
        var output: [ZoomKeyframe] = []
        func append(_ index: Int, placement: ZoomPlacement, transition kind: PIPTransition) {
            let placement = placement.clamped
            let point = ZoomKeyframe(id: identity(frame: index, preset: preset),
                time: Double(index) * frameDuration, scale: placement.scale,
                x: placement.x, y: placement.y, transition: kind, duration: transition)
            if let last = output.last, last.time == point.time { output[output.count - 1] = point }
            else { output.append(point) }
        }
        append(firstFrame, placement: ZoomPlacement(), transition: .jump)
        for (index, burst) in bursts.enumerated() {
            let focus = ZoomPlacement(scale: preset.scale, x: burst.x, y: burst.y).clamped
            let arrival = frame(burst.first)
            append(arrival, placement: focus, transition: .smooth)
            let lastClick = max(arrival, frame(burst.last))
            let desiredHold = max(lastClick, holdFrame(burst.last + 0.8))
            if bursts.indices.contains(index + 1) {
                let next = bursts[index + 1]
                let nextArrival = max(arrival, frame(next.first))
                let nearby = next.first - burst.last <= 2.4 && hypot(next.x - burst.x, next.y - burst.y) <= 0.45
                // There is no useful wide pause if two transitions would touch.
                // Pan once across rapid activity instead of bouncing out and in.
                let noWidePause = nextArrival - desiredHold <= transitionFrames * 2
                if nearby || noWidePause {
                    let end = min(desiredHold, max(lastClick, nextArrival - transitionFrames))
                    if end > arrival, end < nextArrival { append(end, placement: focus, transition: .jump) }
                } else {
                    if desiredHold > arrival { append(desiredHold, placement: focus, transition: .jump) }
                    let wide = min(lastFrame, desiredHold + transitionFrames)
                    if wide > desiredHold { append(wide, placement: ZoomPlacement(), transition: .smooth) }
                }
            } else {
                if desiredHold > arrival { append(desiredHold, placement: focus, transition: .jump) }
                let wide = min(lastFrame, desiredHold + transitionFrames)
                if wide > desiredHold { append(wide, placement: ZoomPlacement(), transition: .smooth) }
            }
        }
        // Distinct click bursts can quantize to the same source frame. Last
        // focus wins, and sorting/deduplication keeps the project valid.
        var unique: [Int: ZoomKeyframe] = [:]
        for point in output { unique[frame(point.time)] = point }
        return unique.keys.sorted().compactMap { unique[$0] }
    }

    private struct Burst {
        let first: Double
        var last: Double
        var x: Double
        var y: Double
        var count = 1

        init(_ click: CursorClick) {
            first = click.time; last = click.time; x = click.x; y = click.y
        }

        mutating func append(_ click: CursorClick) {
            count += 1
            x += (click.x - x) / Double(count)
            y += (click.y - y) / Double(count)
            last = click.time
        }
    }

    /// Stable per-frame identities make repeated suggestions deterministic,
    /// including their undo snapshots and timeline selections.
    private static func identity(frame: Int, preset: Preset) -> UUID {
        let value = UInt64(frame)
        let bytes: [UInt8] = [0x46, 0x54, 0x5a, 0x4f, 0x4f, 0x4d, 0x50, preset == .subtle ? 0 : 1,
            0x80 | UInt8((value >> 56) & 0x3f), UInt8((value >> 48) & 0xff), UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff), UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
