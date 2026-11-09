import Foundation

extension RecordingAudioRole {
    var lane: TimelineAnimationLane { self == .microphone ? .audioMicrophone : .audioSystem }
}
extension TimelineAnimationLane {
    var audioRole: RecordingAudioRole? {
        switch self { case .audioMicrophone: .microphone; case .audioSystem: .systemAudio; default: nil }
    }
}

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
            let cameraPoints = state.pipKeyframes.sorted(by: { $0.time < $1.time })
            for (index, point) in cameraPoints.enumerated() {
                let group = groups.first { $0.cameraID == point.id }
                    ?? TimedEdit(id: point.id, time: point.time, zoomID: nil, cameraID: point.id)
                let referenceID = references.edits[point.id.uuidString] != nil ? point.id : group.id
                let cameraEdit = TimedEdit(id: referenceID, time: point.time, zoomID: nil, cameraID: point.id)
                let description = EditorActionDescription.describe(cameraEdit, in: state, references: references)
                let letter = references.editLabel(for: referenceID).map { String($0.dropFirst(5)) }
                let prior = index > 0 ? cameraPoints[index - 1].placement : PIPPlacement()
                let cameraAction = EditorActionDescription.cameraFadeLabel(point.placement, previous: prior) ?? "Camera"
                let label = index == 0 ? "Initial" : cameraAction + (letter.map { " " + $0 } ?? "")
                let help = index == 0 ? "Initial camera appearance. Select to change its framing and size." : description.tooltip
                result.append(animation(id: point.id, editID: group.id, lane: .camera, end: point.time,
                    previous: previous, transition: point.transition, duration: point.duration,
                    easeIn: point.easeIn, easeOut: point.easeOut,
                    label: label, help: help, editable: index != 0))
                previous = point.time
            }
        }
        previous = 0
        for point in state.speedKeyframes.sorted(by: { $0.time < $1.time }) {
            let group = groups.first { $0.speedID == point.id }
                ?? TimedEdit(id: point.id, time: point.time, zoomID: nil, cameraID: nil, speedID: point.id)
            let referenceID = references.edits[point.id.uuidString] != nil ? point.id : group.id
            let speedEdit = TimedEdit(id: referenceID, time: point.time, zoomID: nil, cameraID: nil, speedID: point.id)
            let description = EditorActionDescription.describe(speedEdit, in: state, references: references)
            let next = state.speedKeyframes.first { $0.time > point.time }
            let heldUntil = next.map { $0.transition == .smooth ? max(point.time, $0.time - $0.duration) : $0.time } ?? duration
            let help = description.tooltip + String(format: " The %.2g× target continues to source %.3f s, until the next rate change or recording end.", point.rate, heldUntil)
            result.append(animation(id: point.id, editID: group.id, lane: .speed, end: point.time,
                previous: previous, transition: point.transition, duration: point.duration,
                easeIn: point.easeIn, easeOut: point.easeOut,
                label: description.shortLabel + String(format: " · %.2g×", point.rate), help: help, editable: true))
            previous = point.time
        }
        for channel in state.audio.channels {
            var previous = 0.0, gain = 1.0
            if channel.points.isEmpty {
                let id = UUID(uuidString: channel.role == .microphone ? "9F0A4A52-9702-468A-94CE-000000000004" : "9F0A4A52-9702-468A-94CE-000000000005")!
                result.append(TimelineAnimation(id: .init(lane: channel.role.lane, componentID: id), editID: id,
                    start: 0, end: duration, easeIn: 0, easeOut: 0, label: channel.role.title,
                    help: "Select to change \(channel.role.title.lowercased()) level or add a source-timed volume change.", editable: false,
                    gainStart: 1, gainEnd: 1))
            }
            for point in channel.points {
                var span = animation(id: point.id, editID: point.id, lane: channel.role.lane, end: point.time,
                    previous: previous, transition: point.transition, duration: point.duration,
                    easeIn: point.easeIn, easeOut: point.easeOut, label: String(format: "%.0f%%", point.gain * 100),
                    help: String(format: "\(channel.role.title) envelope to %.0f%% at %.3f s. Source time; multiplied by the track level.", point.gain * 100, point.time), editable: true)
                span.gainStart = gain; span.gainEnd = point.gain
                result.append(span); previous = point.time; gain = point.gain
            }
        }
        if includeCamera {
            previous = 0
            var previousAlpha = state.cameraOpacityEvents.first?.opacity ?? 1
            let ownIDs = Set(state.cameraOpacityKeyframes.map(\.id))
            for (index, point) in state.cameraOpacityEvents.enumerated() {
                let group = groups.first { $0.cameraOpacityID == point.id }
                let letter = references.editLabel(for: point.id).map { String($0.dropFirst(5)) }
                let action = point.opacity == previousAlpha ? String(format: "Opacity %.0f%%", point.opacity * 100)
                    : EditorActionDescription.cameraOpacityLabel(point.opacity)
                let label = index == 0 && !ownIDs.contains(point.id) ? "Initial opacity" : action + (letter.map { " " + $0 } ?? "")
                result.append(animation(id: point.id, editID: group?.id ?? point.id, lane: .cameraOpacity,
                    end: point.time, previous: previous, transition: point.transition, duration: point.duration,
                    easeIn: point.easeIn, easeOut: point.easeOut,
                    label: label, help: label + ". Camera opacity is independent of camera movement.", editable: ownIDs.contains(point.id)))
                previous = point.time; previousAlpha = point.opacity
            }
        }
        for anchor in state.editAnchors {
            let attachedScreen = state.zoomKeyframes.contains { $0.id == anchor.id && abs($0.time - anchor.time) < 0.000001 }
            let attachedCamera = state.pipKeyframes.contains { $0.id == anchor.id && abs($0.time - anchor.time) < 0.000001 }
            let attachedSpeed = state.speedKeyframes.contains { $0.id == anchor.id && abs($0.time - anchor.time) < 0.000001 }
            guard !attachedScreen && !attachedCamera && !attachedSpeed else { continue }
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
        let existingIDs = Set(state.zoomKeyframes.map(\.id) + state.pipKeyframes.map(\.id) + state.cameraOpacityKeyframes.map(\.id) + state.editAnchors.map(\.id) + state.speedKeyframes.map(\.id))
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
            if let role = change.lane.audioRole {
                var channel = result.audio.channel(role)
                guard let index = channel.points.firstIndex(where: { $0.id == change.componentID }) else { return nil }
                channel.points[index].time = change.end
                if !change.isInstant { channel.points[index].duration = change.duration }
                channel.points[index].transition = change.isInstant ? .jump : .smooth
                channel.points[index].easeIn = change.easeIn; channel.points[index].easeOut = change.easeOut
                channel.points.sort { $0.time < $1.time }
                result.audio.updateChannel(role) { $0 = channel }
                continue
            }
            var newID = change.componentID
            let retimed = change.end != original.end
            let anchored = state.editAnchors.contains { $0.id == change.componentID }
            let shared = (change.lane != .screen && state.zoomKeyframes.contains { $0.id == change.componentID }) ||
                (change.lane != .camera && state.pipKeyframes.contains { $0.id == change.componentID }) ||
                (change.lane != .cameraOpacity && state.cameraOpacityKeyframes.contains { $0.id == change.componentID }) ||
                (change.lane != .speed && state.speedKeyframes.contains { $0.id == change.componentID })
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
            case .speed:
                guard let index = result.speedKeyframes.firstIndex(where: { $0.id == change.componentID }) else { return nil }
                result.speedKeyframes[index].id = newID
                result.speedKeyframes[index].time = change.end
                if change.start != original.start || change.end != original.end {
                    if !change.isInstant { result.speedKeyframes[index].duration = change.duration }
                    result.speedKeyframes[index].transition = change.isInstant ? .jump : .smooth
                    result.speedKeyframes[index].easeIn = change.easeIn
                    result.speedKeyframes[index].easeOut = change.easeOut
                } else {
                    if change.easeIn != original.easeIn { result.speedKeyframes[index].easeIn = change.easeIn }
                    if change.easeOut != original.easeOut { result.speedKeyframes[index].easeOut = change.easeOut }
                }
            case .cameraOpacity:
                guard let index = result.cameraOpacityKeyframes.firstIndex(where: { $0.id == change.componentID }) else { return nil }
                result.cameraOpacityKeyframes[index].id = newID
                result.cameraOpacityKeyframes[index].time = change.end
                if change.start != original.start || change.end != original.end {
                    if !change.isInstant { result.cameraOpacityKeyframes[index].duration = change.duration }
                    result.cameraOpacityKeyframes[index].transition = change.isInstant ? .jump : .smooth
                    result.cameraOpacityKeyframes[index].easeIn = change.easeIn
                    result.cameraOpacityKeyframes[index].easeOut = change.easeOut
                } else {
                    if change.easeIn != original.easeIn { result.cameraOpacityKeyframes[index].easeIn = change.easeIn }
                    if change.easeOut != original.easeOut { result.cameraOpacityKeyframes[index].easeOut = change.easeOut }
                }
            case .pointer, .audioMicrophone, .audioSystem: return nil
            }
        }
        result.zoomKeyframes.sort { $0.time < $1.time }
        result.pipKeyframes.sort { $0.time < $1.time }
        result.speedKeyframes.sort { $0.time < $1.time }
        result.cameraOpacityKeyframes.sort { $0.time < $1.time }
        result.editAnchors.sort { $0.time < $1.time }
        guard ordered(result.zoomKeyframes.map(\.time)), ordered(result.pipKeyframes.map(\.time)), ordered(result.cameraOpacityKeyframes.map(\.time)),
              ordered(result.editAnchors.map(\.time)), ordered(result.speedKeyframes.map(\.time)) else { return nil }
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
                case .speed:
                    guard let index = result.speedKeyframes.firstIndex(where: { $0.id == original.componentID }) else { return nil }
                    if !original.isInstant { result.speedKeyframes[index].duration = original.duration }
                    result.speedKeyframes[index].transition = original.isInstant ? .jump : .smooth
                    result.speedKeyframes[index].easeIn = original.easeIn
                    result.speedKeyframes[index].easeOut = original.easeOut
                case .audioMicrophone, .audioSystem:
                    guard let role = original.lane.audioRole else { return nil }
                    result.audio.updateChannel(role) { channel in
                        if let index = channel.points.firstIndex(where: { $0.id == original.componentID }) {
                            if !original.isInstant { channel.points[index].duration = original.duration }
                            channel.points[index].transition = original.isInstant ? .jump : .smooth
                            channel.points[index].easeIn = original.easeIn; channel.points[index].easeOut = original.easeOut
                        }
                    }
                case .cameraOpacity:
                    guard let index = result.cameraOpacityKeyframes.firstIndex(where: { $0.id == original.componentID }) else { continue }
                    if !original.isInstant { result.cameraOpacityKeyframes[index].duration = original.duration }
                    result.cameraOpacityKeyframes[index].transition = original.isInstant ? .jump : .smooth
                    result.cameraOpacityKeyframes[index].easeIn = original.easeIn
                    result.cameraOpacityKeyframes[index].easeOut = original.easeOut
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
