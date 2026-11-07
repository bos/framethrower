import Foundation

/// A read-only value projection of the exact pending replacement. Preparing
/// this comparison never commits a project, creates Undo, or opens media.
struct EditorConflictReview: Equatable, Sendable {
    let projectID: UUID
    let revision: String
    let duration: Double
    let existingSpans: [EditorConflictSpan]
    let proposedSpans: [EditorConflictSpan]
    let overlapIntervals: [ClosedRange<Double>]
    let selectedInterval: ClosedRange<Double>?
    let reviewInterval: ClosedRange<Double>
    let previewState: EditState
    private let existingState: EditState
    private let proposedState: EditState

    var inspectionTime: Double {
        let interval = selectedInterval ?? reviewInterval
        return interval.lowerBound + (interval.upperBound - interval.lowerBound) / 2
    }

    static func make(_ conflict: EditorFramingConflict?, project: RecordingProject, projectID: UUID) -> Self? {
        guard let conflict, conflict.proposal.projectID == projectID,
              let revision = try? EditorCommandDispatcher.revision(for: project),
              conflict.proposal.revision == revision,
              (try? project.validate()) != nil else { return nil }
        let affected = Set(conflict.framingIDs)
        let available = Set(project.state.zoomKeyframes.map(\.id))
        guard !affected.isEmpty, affected.count == conflict.framingIDs.count, affected.isSubset(of: available),
              let proposed = try? EditorCommandDispatcher.prepare(conflict.replacement, for: project, projectID: projectID),
              proposed.pipKeyframes == project.state.pipKeyframes,
              proposed.cursorStyle == project.state.cursorStyle,
              proposed.audio == project.state.audio,
              proposed.presentation == project.state.presentation,
              proposed.trimStart == project.state.trimStart, proposed.trimEnd == project.state.trimEnd,
              proposed.regions == project.state.regions else { return nil }

        let oldSegments = segments(in: project.state, duration: project.duration)
        let newSegments = segments(in: proposed, duration: project.duration)
        var references = project.references
        references.register(state: proposed, includeCamera: project.cameraFilename != nil)
        guard (try? references.validate()) != nil else { return nil }
        let existing = oldSegments.enumerated().compactMap { index, segment in
            affected.contains(segment.point.id) ? span(segment, index: index, side: .existing,
                state: project.state, references: project.references) : nil
        }
        let oldByID = Dictionary(uniqueKeysWithValues: oldSegments.map { ($0.point.id, $0) })
        var replacement = newSegments.enumerated().compactMap { index, segment -> EditorConflictSpan? in
            guard oldByID[segment.point.id] != segment else { return nil }
            return span(segment, index: index, side: .proposed, state: proposed, references: references)
        }
        // A deletion-only replacement has no new point to carry a band. Show
        // the affected source interval against the remaining proposed framing.
        if replacement.isEmpty, proposed.zoomKeyframes != project.state.zoomKeyframes {
            replacement = existing.enumerated().map { index, original in
                EditorConflictSpan(id: "proposed-removed-\(index)-\(original.start)-\(original.end)", side: .proposed,
                    start: original.start, end: original.end, label: "Proposed framing",
                    help: "Proposed framing over the removed movement's source interval.")
            }
        }
        guard !existing.isEmpty, !replacement.isEmpty else { return nil }
        let overlaps = merged(existing.flatMap { old in replacement.compactMap { next -> ClosedRange<Double>? in
            let start = max(old.start, next.start), end = min(old.end, next.end)
            return start <= end ? start...end : nil
        } })
        let all = existing + replacement
        let interval = (all.map(\.start).min()!)...(all.map(\.end).max()!)
        let preferred = overlaps.sorted(by: longestFirst)
        let alternatives = replacement.map(\.range).sorted(by: longestFirst) + existing.map(\.range).sorted(by: longestFirst)
        // Prefer a true overlap. If both curves meet at that exact boundary,
        // inspect a differing subinterval rather than the shared initial view.
        let selected = (preferred + alternatives).lazy.compactMap {
            differingInterval($0, existing: project.state, proposed: proposed)
        }.first ?? preferred.first ?? replacement.first?.range
        var preview = project.state
        preview.zoomKeyframes = []
        return Self(projectID: projectID, revision: revision, duration: project.duration,
            existingSpans: existing, proposedSpans: replacement, overlapIntervals: overlaps,
            selectedInterval: selected, reviewInterval: interval, previewState: preview,
            existingState: project.state, proposedState: proposed)
    }

    /// Callers cache per project revision; rebuilding with an absent or stale
    /// conflict returns nil and clears its comparison. No proposal IDs are UI.
    func outlines(at sourceTime: Double) -> EditorConflictOutlines? {
        guard sourceTime.isFinite else { return nil }
        let time = min(duration, max(0, sourceTime))
        let source = CGSize(width: 1, height: 1)
        return EditorConflictOutlines(time: time, existing: existingState.zoom(at: time).viewport(in: source),
                                      proposed: proposedState.zoom(at: time).viewport(in: source))
    }

    static func == (a: Self, b: Self) -> Bool {
        guard a.projectID == b.projectID, a.revision == b.revision, a.duration == b.duration,
              a.existingSpans == b.existingSpans, a.proposedSpans == b.proposedSpans,
              a.overlapIntervals == b.overlapIntervals, a.selectedInterval == b.selectedInterval,
              a.reviewInterval == b.reviewInterval, a.previewState == b.previewState,
              a.proposedState.zoomKeyframes.count == b.proposedState.zoomKeyframes.count else { return false }
        // Dispatcher-created point UUIDs differ on repeated projections. They
        // are host implementation details, not part of this visual comparison.
        return zip(a.proposedState.zoomKeyframes, b.proposedState.zoomKeyframes).allSatisfy { left, right in
            left.time == right.time && left.placement == right.placement && left.transition == right.transition &&
            left.duration == right.duration && left.easeIn == right.easeIn && left.easeOut == right.easeOut
        }
    }

    private struct Segment: Equatable {
        let point: ZoomKeyframe
        let previousTime: Double
        let previousPlacement: ZoomPlacement
        let start: Double
        let end: Double
    }

    private static func segments(in state: EditState, duration: Double) -> [Segment] {
        var previousTime = 0.0
        var previousPlacement = ZoomPlacement()
        return state.zoomKeyframes.map { point in
            let target = point.placement.clamped
            let start: Double
            if target == previousPlacement { start = previousTime }
            else if point.transition == .smooth { start = max(previousTime, point.time - point.duration) }
            else { start = point.time }
            let segment = Segment(point: point, previousTime: previousTime, previousPlacement: previousPlacement,
                start: min(duration, max(0, start)), end: min(duration, max(0, point.time)))
            previousTime = point.time
            previousPlacement = target
            return segment
        }
    }

    private static func span(_ segment: Segment, index: Int, side: EditorConflictSide,
                             state: EditState, references: EditorReferences) -> EditorConflictSpan {
        let edit = state.timedEdits(includeCamera: true).first { $0.zoomID == segment.point.id }
            ?? TimedEdit(id: segment.point.id, time: segment.point.time, zoomID: segment.point.id, cameraID: nil)
        let description = EditorActionDescription.describe(edit, in: state, references: references)
        return EditorConflictSpan(id: "\(side.rawValue)-\(index)-\(segment.start)-\(segment.end)", side: side,
            start: segment.start, end: segment.end, label: description.shortLabel, help: description.tooltip)
    }

    private static func merged(_ intervals: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for interval in intervals.sorted(by: { $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, interval.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
            } else { result.append(interval) }
        }
        return result
    }

    private static func longestFirst(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Bool {
        let lengthA = a.upperBound - a.lowerBound, lengthB = b.upperBound - b.lowerBound
        return lengthA == lengthB ? a.lowerBound < b.lowerBound : lengthA > lengthB
    }

    private static func differingInterval(_ interval: ClosedRange<Double>, existing: EditState, proposed: EditState) -> ClosedRange<Double>? {
        var pending = [(interval, 0)]
        while !pending.isEmpty {
            let (range, depth) = pending.removeFirst()
            let midpoint = range.lowerBound + (range.upperBound - range.lowerBound) / 2
            if existing.zoom(at: midpoint) != proposed.zoom(at: midpoint) { return range }
            if depth < 3, range.lowerBound < midpoint, midpoint < range.upperBound {
                pending.append((range.lowerBound...midpoint, depth + 1))
                pending.append((midpoint...range.upperBound, depth + 1))
            }
        }
        return nil
    }
}
