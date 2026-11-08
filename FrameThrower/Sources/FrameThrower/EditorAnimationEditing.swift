import Foundation

struct EditorAnimationIdentityAlias: Equatable, Sendable {
    var originalID: UUID
    var replacementID: UUID
    var lane: TimelineAnimationLane
}

struct EditorAnimationEdit: Equatable, Sendable {
    var state: EditState
    var aliases: [EditorAnimationIdentityAlias]
}

/// Projection/application only. The host owns a frozen gesture snapshot, its
/// replacement-ID map, draft publication, selection, and the single Undo step.
enum EditorAnimationEditing {
    private static let pointerID = UUID(uuidString: "9F0A4A52-9702-468A-94CE-000000000003")!

    static func animations(in state: EditState, references: EditorReferences, duration: Double,
                           includeCamera: Bool = true) -> [TimelineAnimation] {
        let groups = state.timedEdits(includeCamera: includeCamera)
        var result: [TimelineAnimation] = []
        var previous = 0.0
        for point in state.zoomKeyframes.sorted(by: { $0.time < $1.time }) {
            let group = groups.first { $0.zoomID == point.id }
                ?? TimedEdit(id: point.id, time: point.time, zoomID: point.id, cameraID: nil)
            let referenceID = references.edits[point.id.uuidString] != nil ? point.id : group.id
            let screenEdit = TimedEdit(id: referenceID, time: point.time, zoomID: point.id, cameraID: nil)
            let description = EditorActionDescription.describe(screenEdit, in: state, references: references)
            result.append(animation(id: point.id, editID: group.id, lane: .screen, end: point.time,
                previous: previous, transition: point.transition, duration: point.duration,
                easeIn: point.easeIn, easeOut: point.easeOut,
                label: description.shortLabel, help: description.tooltip, editable: true))
            previous = point.time
        }
        if includeCamera {
            previous = 0
            for (index, point) in state.pipKeyframes.sorted(by: { $0.time < $1.time }).enumerated() {
                let group = groups.first { $0.cameraID == point.id }
                    ?? TimedEdit(id: point.id, time: point.time, zoomID: nil, cameraID: point.id)
                let referenceID = references.edits[point.id.uuidString] != nil ? point.id : group.id
                let cameraEdit = TimedEdit(id: referenceID, time: point.time, zoomID: nil, cameraID: point.id)
                let description = EditorActionDescription.describe(cameraEdit, in: state, references: references)
                let letter = references.editLabel(for: referenceID).map { String($0.dropFirst(5)) }
                let label = index == 0 ? "Initial" : "Camera" + (letter.map { " " + $0 } ?? "")
                let help = index == 0 ? "Initial camera appearance. Select to change its framing and size." : description.tooltip
                result.append(animation(id: point.id, editID: group.id, lane: .camera, end: point.time,
                    previous: previous, transition: point.transition, duration: point.duration,
                    easeIn: point.easeIn, easeOut: point.easeOut,
                    label: label, help: help, editable: index != 0))
                previous = point.time
            }
        }
        for anchor in state.editAnchors {
            let attachedScreen = state.zoomKeyframes.contains { $0.id == anchor.id && abs($0.time - anchor.time) < 0.000001 }
            let attachedCamera = state.pipKeyframes.contains { $0.id == anchor.id && abs($0.time - anchor.time) < 0.000001 }
            guard !attachedScreen && !attachedCamera else { continue }
            let group = TimedEdit(id: anchor.id, time: anchor.time, zoomID: nil, cameraID: nil, anchorID: anchor.id)
            let description = EditorActionDescription.describe(group, in: state, references: references)
            result.append(TimelineAnimation(id: TimelineAnimationID(lane: .screen, componentID: group.id),
                editID: group.id, start: group.time, end: group.time, easeIn: 0, easeOut: 0,
                label: description.shortLabel, help: description.tooltip, editable: true, isReference: true))
        }
        result.append(TimelineAnimation(id: TimelineAnimationID(lane: .pointer, componentID: pointerID),
            editID: pointerID, start: 0, end: duration, easeIn: 0, easeOut: 0,
            label: "Pointer", help: "Pointer style applies to the entire recording.", editable: false))
        return result
    }

    /// Allocate once at gesture begin, then reuse for every preview and commit.
    static func replacementIDs(for animations: [TimelineAnimation]) -> [TimelineAnimationID: UUID] {
        Dictionary(uniqueKeysWithValues: animations.filter { $0.editable && !$0.isReference }.map { ($0.id, UUID()) })
    }

    static func applying(_ changes: [TimelineAnimation], to state: EditState, duration: Double,
                         replacementIDs: [TimelineAnimationID: UUID] = [:]) -> EditorAnimationEdit? {
        guard duration.isFinite, duration >= 0,
              Set(changes.map(\.id)).count == changes.count else { return nil }
        let baseline = animations(in: state, references: EditorReferences(), duration: duration)
        var result = state
        var aliases: [EditorAnimationIdentityAlias] = []
        let existingIDs = Set(state.zoomKeyframes.map(\.id) + state.pipKeyframes.map(\.id) + state.editAnchors.map(\.id))
        var usedReplacements = Set<UUID>()
        for change in changes {
            guard let original = baseline.first(where: { $0.id == change.id }), original.editable,
                  change.editID == original.editID, change.isReference == original.isReference,
                  [change.start, change.end, change.easeIn, change.easeOut].allSatisfy(\.isFinite),
                  change.start >= 0, change.end <= duration, change.start <= change.end,
                  change.easeIn >= 0, change.easeOut >= 0,
                  change.easeIn + change.easeOut <= change.duration + 0.0000000001 else { return nil }
            if change.isReference {
                guard change.isInstant, change.easeIn == 0, change.easeOut == 0,
                      let index = result.editAnchors.firstIndex(where: { $0.id == change.componentID }) else { return nil }
                result.editAnchors[index].time = change.end
                continue
            }
            var newID = change.componentID
            let retimed = change.end != original.end
            let anchored = state.editAnchors.contains { $0.id == change.componentID }
            let shared = change.lane == .screen
                ? state.pipKeyframes.contains { $0.id == change.componentID }
                : state.zoomKeyframes.contains { $0.id == change.componentID }
            if retimed && (anchored || shared) {
                guard let replacement = replacementIDs[change.id], !existingIDs.contains(replacement),
                      usedReplacements.insert(replacement).inserted else { return nil }
                newID = replacement
                aliases.append(EditorAnimationIdentityAlias(originalID: change.componentID,
                    replacementID: replacement, lane: change.lane))
            }
            switch change.lane {
            case .screen:
                guard let index = result.zoomKeyframes.firstIndex(where: { $0.id == change.componentID }) else { return nil }
                result.zoomKeyframes[index].id = newID
                result.zoomKeyframes[index].time = change.end
                if change.start != original.start || change.end != original.end {
                    if !change.isInstant { result.zoomKeyframes[index].duration = change.duration }
                    result.zoomKeyframes[index].transition = change.isInstant ? .jump : .smooth
                    result.zoomKeyframes[index].easeIn = change.easeIn
                    result.zoomKeyframes[index].easeOut = change.easeOut
                } else {
                    if change.easeIn != original.easeIn { result.zoomKeyframes[index].easeIn = change.easeIn }
                    if change.easeOut != original.easeOut { result.zoomKeyframes[index].easeOut = change.easeOut }
                }
            case .camera:
                guard let index = result.pipKeyframes.firstIndex(where: { $0.id == change.componentID }) else { return nil }
                result.pipKeyframes[index].id = newID
                result.pipKeyframes[index].time = change.end
                if change.start != original.start || change.end != original.end {
                    if !change.isInstant { result.pipKeyframes[index].duration = change.duration }
                    result.pipKeyframes[index].transition = change.isInstant ? .jump : .smooth
                    result.pipKeyframes[index].easeIn = change.easeIn
                    result.pipKeyframes[index].easeOut = change.easeOut
                } else {
                    if change.easeIn != original.easeIn { result.pipKeyframes[index].easeIn = change.easeIn }
                    if change.easeOut != original.easeOut { result.pipKeyframes[index].easeOut = change.easeOut }
                }
            case .pointer: return nil
            }
        }
        result.zoomKeyframes.sort { $0.time < $1.time }
        result.pipKeyframes.sort { $0.time < $1.time }
        result.editAnchors.sort { $0.time < $1.time }
        guard ordered(result.zoomKeyframes.map(\.time)), ordered(result.pipKeyframes.map(\.time)),
              ordered(result.editAnchors.map(\.time)) else { return nil }
        // A source point may store a long duration whose visible start was
        // clipped by its predecessor. Keep an otherwise untouched follower's
        // original visible interval when that predecessor moves away.
        let touched = Set(changes.map(\.id))
        let touchedLanes = Set(changes.filter { !$0.isReference }.map(\.lane))
        let intermediate = animations(in: result, references: EditorReferences(), duration: duration)
        for original in baseline where !original.isReference && !touched.contains(original.id) && touchedLanes.contains(original.lane) {
            guard let actual = intermediate.first(where: { $0.id == original.id }) else { return nil }
            if actual.start != original.start || actual.easeIn != original.easeIn || actual.easeOut != original.easeOut {
                switch original.lane {
                case .screen:
                    guard let index = result.zoomKeyframes.firstIndex(where: { $0.id == original.componentID }) else { return nil }
                    if !original.isInstant { result.zoomKeyframes[index].duration = original.duration }
                    result.zoomKeyframes[index].transition = original.isInstant ? .jump : .smooth
                    result.zoomKeyframes[index].easeIn = original.easeIn
                    result.zoomKeyframes[index].easeOut = original.easeOut
                case .camera:
                    guard let index = result.pipKeyframes.firstIndex(where: { $0.id == original.componentID }) else { return nil }
                    if !original.isInstant { result.pipKeyframes[index].duration = original.duration }
                    result.pipKeyframes[index].transition = original.isInstant ? .jump : .smooth
                    result.pipKeyframes[index].easeIn = original.easeIn
                    result.pipKeyframes[index].easeOut = original.easeOut
                case .pointer: break
                }
            }
        }
        // Ensure the metadata produces exactly the spans the user previewed.
        let projected = animations(in: result, references: EditorReferences(), duration: duration)
        for change in changes {
            let id = aliases.first(where: { $0.originalID == change.componentID && $0.lane == change.lane })?.replacementID ?? change.componentID
            guard let actual = projected.first(where: { $0.id == TimelineAnimationID(lane: change.lane, componentID: id) }),
                  abs(actual.start - change.start) < 0.00000001, abs(actual.end - change.end) < 0.00000001,
                  abs(actual.easeIn - change.easeIn) < 0.00000001, abs(actual.easeOut - change.easeOut) < 0.00000001 else { return nil }
        }
        return EditorAnimationEdit(state: result, aliases: aliases)
    }

    private static func animation(id: UUID, editID: UUID, lane: TimelineAnimationLane, end: Double,
                                  previous: Double, transition: PIPTransition, duration: Double,
                                  easeIn: Double?, easeOut: Double?, label: String, help: String,
                                  editable: Bool) -> TimelineAnimation {
        let start = transition == .smooth ? max(previous, end - duration) : end
        let ramps = MotionInterpolation.rampDurations(duration: end - start, easeIn: easeIn, easeOut: easeOut)
        return TimelineAnimation(id: TimelineAnimationID(lane: lane, componentID: id), editID: editID,
            start: start, end: end, easeIn: ramps.easeIn, easeOut: ramps.easeOut,
            label: label, help: help, editable: editable)
    }

    private static func ordered(_ times: [Double]) -> Bool {
        zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= TimelineAnimationSolver.minimumSeparation }
    }
}
