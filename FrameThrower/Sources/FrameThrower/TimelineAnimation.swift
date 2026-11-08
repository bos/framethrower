import Foundation

enum TimelineAnimationLane: String, CaseIterable, Hashable, Sendable {
    case screen, camera, pointer
}

struct TimelineAnimationID: Hashable, Sendable {
    var lane: TimelineAnimationLane
    var componentID: UUID
}

struct TimelineAnimation: Identifiable, Equatable, Sendable {
    var id: TimelineAnimationID
    var editID: UUID
    var start: Double
    var end: Double
    var easeIn: Double
    var easeOut: Double
    var label: String
    var help: String
    var editable: Bool
    var isReference: Bool = false

    var lane: TimelineAnimationLane { id.lane }
    var componentID: UUID { id.componentID }
    var duration: Double { end - start }
    var isInstant: Bool { start == end }
}

enum TimelineAnimationHandle: Equatable, Sendable {
    case move, start, end, easeIn, easeOut
}

/// Deltas always refer to the gesture's original snapshot, never its preceding
/// preview. Option requests a same-lane push rather than crossing another span.
struct AnimationDrag: Equatable, Sendable {
    var id: TimelineAnimationID
    var handle: TimelineAnimationHandle
    var deltaSeconds: Double
    var push: Bool = false
    // Native views use pixel hysteresis and pass zero; model callers retain
    // the existing source-time contact tolerance by default.
    var snapTolerance: Double = TimelineAnimationSolver.snapTolerance
}

enum TimelineAnimationSolver {
    static let minimumSeparation = 0.000001
    static let snapTolerance = 0.04
    /// Returns changed spans only. A rejected/invalid base has no projection.
    static func solve(_ drag: AnimationDrag, animations: [TimelineAnimation], duration: Double) -> [TimelineAnimation]? {
        guard duration.isFinite, duration >= 0, drag.deltaSeconds.isFinite,
              drag.snapTolerance.isFinite, drag.snapTolerance >= 0,
              Set(animations.map(\.id)).count == animations.count,
              let target = animations.first(where: { $0.id == drag.id }), target.editable else { return nil }
        return solveValidated(drag, target: target, animations: animations, duration: duration)
    }

    private static func solveValidated(_ drag: AnimationDrag, target: TimelineAnimation,
                                       animations: [TimelineAnimation], duration: Double) -> [TimelineAnimation]? {
        guard animations.allSatisfy({ valid($0, duration: duration) }) else { return nil }
        if target.isReference {
            guard drag.handle == .move else { return [] }
            var result = target
            let others = animations.filter { $0.isReference && $0.lane == target.lane && $0.id != target.id }
            let lower = (others.filter { $0.end < target.end }.map(\.end).max().map { $0 + minimumSeparation }) ?? 0
            let upper = (others.filter { $0.end > target.end }.map(\.end).min().map { $0 - minimumSeparation }) ?? duration
            result.start = clamp(target.start + drag.deltaSeconds, lower, upper)
            result.end = result.start
            return result == target ? [] : [result]
        }
        let lane = animations.filter { $0.lane == target.lane && !$0.isReference }.sorted { $0.end < $1.end }
        guard ordered(lane), let index = lane.firstIndex(where: { $0.id == target.id }) else { return nil }
        if drag.handle == .easeIn || drag.handle == .easeOut {
            var result = target
            if drag.handle == .easeIn { result.easeIn = clamp(target.easeIn + drag.deltaSeconds, 0, target.duration - target.easeOut) }
            else { result.easeOut = clamp(target.easeOut - drag.deltaSeconds, 0, target.duration - target.easeIn) }
            return result == target ? [] : [result]
        }

        if drag.handle == .move, !drag.push {
            return moveAcrossGaps(drag, target: target, lane: lane, duration: duration)
        }

        let previous = index > 0 ? lane[index - 1] : nil
        let next = index + 1 < lane.count ? lane[index + 1] : nil
        var lower: Double, upper: Double
        switch drag.handle {
        case .move:
            lower = -target.start
            upper = duration - target.end
            if !drag.push {
                if let previous { lower = max(lower, previous.end - target.start, previous.end + minimumSeparation - target.end) }
                if let next { upper = min(upper, next.start - target.end, next.end - minimumSeparation - target.end) }
            }
        case .start:
            lower = -target.start
            upper = target.duration
            if !drag.push, let previous { lower = max(lower, previous.end - target.start) }
        case .end:
            lower = -target.duration
            if let previous { lower = max(lower, previous.end + minimumSeparation - target.end) }
            upper = duration - target.end
            if !drag.push, let next { upper = min(upper, next.start - target.end, next.end - minimumSeparation - target.end) }
        case .easeIn, .easeOut: return nil
        }
        guard lower <= upper else { return nil }
        var delta = clamp(drag.deltaSeconds, lower, upper)
        if delta > 0, upper - delta <= drag.snapTolerance { delta = upper }
        if delta < 0, delta - lower <= drag.snapTolerance { delta = lower }
        if delta == 0 { return [] }

        func candidate(_ delta: Double) -> [TimelineAnimation]? {
            var values = lane
            switch drag.handle {
            case .move: values[index].start += delta; values[index].end += delta
            case .start: values[index].start += delta
            case .end: values[index].end += delta
            default: return nil
            }
            let span = values[index].duration
            let sum = target.easeIn + target.easeOut
            if sum > span + 0.0000000001 && sum > 0 {
                values[index].easeIn = span * target.easeIn / sum
                values[index].easeOut = span * target.easeOut / sum
            }
            if drag.push, delta > 0, drag.handle != .start, index + 1 < values.count {
                for i in (index + 1)..<values.count {
                    let shift = max(0, values[i - 1].end - values[i].start,
                                    values[i - 1].end + minimumSeparation - values[i].end)
                    if shift > 0 {
                        guard values[i].editable else { return nil }
                        values[i].start += shift; values[i].end += shift
                    }
                }
            }
            if drag.push, delta < 0, drag.handle != .end, index > 0 {
                for i in stride(from: index - 1, through: 0, by: -1) {
                    let shift = max(0, values[i].end - values[i + 1].start,
                                    values[i].end + minimumSeparation - values[i + 1].end)
                    if shift > 0 {
                        guard values[i].editable else { return nil }
                        values[i].start -= shift; values[i].end -= shift
                    }
                }
            }
            guard values.allSatisfy({ valid($0, duration: duration) }), ordered(values) else { return nil }
            return values
        }
        var result = candidate(delta)
        if result == nil {
            // Feasibility is monotone from the original snapshot toward the
            // requested displacement. Clamp the entire cascade at its limit.
            var accepted = 0.0, rejected = delta
            for _ in 0..<64 {
                let mid = accepted + (rejected - accepted) / 2
                if candidate(mid) != nil { accepted = mid } else { rejected = mid }
            }
            result = candidate(accepted)
        }
        guard let result else { return nil }
        return zip(lane, result).compactMap { $0 == $1 ? nil : $1 }
    }

    /// A body can pass a neighbor only when its entire requested interval
    /// clears it. While intersecting, stop at the contact on the approach side.
    /// This projection is directional, rather than choosing the nearest gap,
    /// which would jump through a partially overlapped neighbor.
    private static func moveAcrossGaps(_ drag: AnimationDrag, target: TimelineAnimation,
                                       lane: [TimelineAnimation], duration: Double) -> [TimelineAnimation]? {
        let others = lane.filter { $0.id != target.id }
        let length = target.duration
        let desired = clamp(target.start + drag.deltaSeconds, 0, duration - length)
        guard desired != target.start else { return [] }
        var gaps: [ClosedRange<Double>] = []
        for index in 0...others.count {
            var lower = 0.0, upper = duration - length
            if index > 0 {
                let previous = others[index - 1]
                lower = max(lower, previous.end, previous.end + minimumSeparation - length)
            }
            if index < others.count {
                let next = others[index]
                upper = min(upper, next.start - length, next.end - minimumSeparation - length)
            }
            if lower <= upper { gaps.append(lower...upper) }
        }
        let start: Double
        if desired > target.start {
            guard let gap = gaps.last(where: { $0.lowerBound <= desired }) else { return nil }
            let projected = min(desired, gap.upperBound)
            start = gap.upperBound - projected <= drag.snapTolerance ? gap.upperBound : projected
        } else {
            guard let gap = gaps.first(where: { $0.upperBound >= desired }) else { return nil }
            let projected = max(desired, gap.lowerBound)
            start = projected - gap.lowerBound <= drag.snapTolerance ? gap.lowerBound : projected
        }
        var moved = target
        moved.start = start; moved.end = start + length
        guard valid(moved, duration: duration), ordered((others + [moved]).sorted { $0.end < $1.end }) else { return nil }
        return moved == target ? [] : [moved]
    }

    private static func valid(_ value: TimelineAnimation, duration: Double) -> Bool {
        [value.start, value.end, value.easeIn, value.easeOut].allSatisfy(\.isFinite) &&
            value.start >= 0 && value.end <= duration && value.end >= value.start &&
            value.easeIn >= 0 && value.easeOut >= 0 && value.easeIn + value.easeOut <= value.duration + 0.0000000001
    }

    private static func ordered(_ lane: [TimelineAnimation]) -> Bool {
        zip(lane, lane.dropFirst()).allSatisfy {
            $0.end <= $1.start && $1.end - $0.end >= minimumSeparation
        }
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
