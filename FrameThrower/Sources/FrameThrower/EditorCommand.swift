import CryptoKit
import Foundation

/// Timing has the same meaning as a manually authored edit: movement arrives
/// at the edit's source timestamp, with cosine acceleration/deceleration ramps.
struct EditorCommandMotion: Codable, Equatable, Sendable {
    var transition: PIPTransition = .smooth
    var duration: Double = 0.4
    var easeIn: Double? = nil
    var easeOut: Double? = nil

    func validate() throws {
        guard duration.isFinite, duration > 0, duration <= 60,
              [easeIn, easeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 60 }) else {
            throw EditorCommandError.invalid("Movement duration must be greater than zero and no longer than 60 seconds.")
        }
    }
}

/// The external contract is deliberately small and independent of a model or
/// transport. No command accepts a path, a URL, an executable, or source pixels.
enum EditorCommand: Codable, Equatable, Sendable {
    case frameRegion(regionID: UUID, time: Double, motion: EditorCommandMotion = EditorCommandMotion())
    case fullFrame(time: Double, motion: EditorCommandMotion = EditorCommandMotion())
    case holdFraming(time: Double)
    case reviseFraming(editID: UUID, regionID: UUID)
    case moveBetweenEdits(fromEditID: UUID, toEditID: UUID, regionID: UUID)
    case moveForDuration(startEditID: UUID, fromRegionID: UUID, toRegionID: UUID, duration: Double, viaFullFrame: Bool = false)
    case createEdit(time: Double)
    case moveEdit(editID: UUID, time: Double)
    case removeEdit(editID: UUID)
    case labelRegion(regionID: UUID, note: String)

    private enum Key: String, CodingKey {
        case action, regionID, time, motion, editID, fromEditID, toEditID, note,
             startEditID, fromRegionID, toRegionID, duration, viaFullFrame
    }
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let action = try values.decode(String.self, forKey: .action)
        let allowed: Set<String>
        switch action {
        case "frameRegion":
            allowed = ["action", "regionID", "time", "motion"]
            self = .frameRegion(regionID: try values.decode(UUID.self, forKey: .regionID),
                                time: try values.decode(Double.self, forKey: .time),
                                motion: try values.decodeIfPresent(EditorCommandMotion.self, forKey: .motion) ?? EditorCommandMotion())
        case "fullFrame":
            allowed = ["action", "time", "motion"]
            self = .fullFrame(time: try values.decode(Double.self, forKey: .time),
                              motion: try values.decodeIfPresent(EditorCommandMotion.self, forKey: .motion) ?? EditorCommandMotion())
        case "holdFraming":
            allowed = ["action", "time"]
            self = .holdFraming(time: try values.decode(Double.self, forKey: .time))
        case "reviseFraming":
            allowed = ["action", "editID", "regionID"]
            self = .reviseFraming(editID: try values.decode(UUID.self, forKey: .editID),
                                  regionID: try values.decode(UUID.self, forKey: .regionID))
        case "labelRegion":
            allowed = ["action", "regionID", "note"]
            self = .labelRegion(regionID: try values.decode(UUID.self, forKey: .regionID),
                                note: try values.decode(String.self, forKey: .note))
        case "moveBetweenEdits":
            allowed = ["action", "fromEditID", "toEditID", "regionID"]
            self = .moveBetweenEdits(fromEditID: try values.decode(UUID.self, forKey: .fromEditID),
                                    toEditID: try values.decode(UUID.self, forKey: .toEditID),
                                    regionID: try values.decode(UUID.self, forKey: .regionID))
        case "moveForDuration":
            allowed = ["action", "startEditID", "fromRegionID", "toRegionID", "duration", "viaFullFrame"]
            self = .moveForDuration(startEditID: try values.decode(UUID.self, forKey: .startEditID),
                fromRegionID: try values.decode(UUID.self, forKey: .fromRegionID),
                toRegionID: try values.decode(UUID.self, forKey: .toRegionID),
                duration: try values.decode(Double.self, forKey: .duration),
                viaFullFrame: try values.decodeIfPresent(Bool.self, forKey: .viaFullFrame) ?? false)
        case "createEdit":
            allowed = ["action", "time"]
            self = .createEdit(time: try values.decode(Double.self, forKey: .time))
        case "moveEdit":
            allowed = ["action", "editID", "time"]
            self = .moveEdit(editID: try values.decode(UUID.self, forKey: .editID), time: try values.decode(Double.self, forKey: .time))
        case "removeEdit":
            allowed = ["action", "editID"]
            self = .removeEdit(editID: try values.decode(UUID.self, forKey: .editID))
        default:
            throw EditorCommandError.invalid("The requested editing action is not supported.")
        }
        let actual = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
        guard actual.isSubset(of: allowed) else {
            throw EditorCommandError.invalid("The editing action contains unsupported fields.")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        switch self {
        case let .frameRegion(regionID, time, motion):
            try values.encode("frameRegion", forKey: .action)
            try values.encode(regionID, forKey: .regionID)
            try values.encode(time, forKey: .time)
            try values.encode(motion, forKey: .motion)
        case let .fullFrame(time, motion):
            try values.encode("fullFrame", forKey: .action)
            try values.encode(time, forKey: .time)
            try values.encode(motion, forKey: .motion)
        case let .holdFraming(time):
            try values.encode("holdFraming", forKey: .action)
            try values.encode(time, forKey: .time)
        case let .reviseFraming(editID, regionID):
            try values.encode("reviseFraming", forKey: .action)
            try values.encode(editID, forKey: .editID)
            try values.encode(regionID, forKey: .regionID)
        case let .labelRegion(regionID, note):
            try values.encode("labelRegion", forKey: .action)
            try values.encode(regionID, forKey: .regionID)
            try values.encode(note, forKey: .note)
        case let .moveBetweenEdits(fromEditID, toEditID, regionID):
            try values.encode("moveBetweenEdits", forKey: .action)
            try values.encode(fromEditID, forKey: .fromEditID)
            try values.encode(toEditID, forKey: .toEditID)
            try values.encode(regionID, forKey: .regionID)
        case let .moveForDuration(startEditID, fromRegionID, toRegionID, duration, viaFullFrame):
            try values.encode("moveForDuration", forKey: .action)
            try values.encode(startEditID, forKey: .startEditID)
            try values.encode(fromRegionID, forKey: .fromRegionID)
            try values.encode(toRegionID, forKey: .toRegionID)
            try values.encode(duration, forKey: .duration)
            try values.encode(viaFullFrame, forKey: .viaFullFrame)
        case let .createEdit(time):
            try values.encode("createEdit", forKey: .action)
            try values.encode(time, forKey: .time)
        case let .moveEdit(editID, time):
            try values.encode("moveEdit", forKey: .action)
            try values.encode(editID, forKey: .editID)
            try values.encode(time, forKey: .time)
        case let .removeEdit(editID):
            try values.encode("removeEdit", forKey: .action)
            try values.encode(editID, forKey: .editID)
        }
    }
}

struct EditorCommandBatch: Codable, Equatable, Sendable {
    var version: Int = 1
    var projectID: UUID
    var revision: String
    var commands: [EditorCommand]
}

struct EditorCommandContext: Codable, Equatable, Sendable {
    var projectID: UUID
    var revision: String
    var duration: Double
    var state: EditState
    var references = EditorReferences()
    var history = EditorHistoryState()
}

enum EditorCommandError: LocalizedError {
    case invalid(String)
    case stale
    case pendingDraft
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message), let .saveFailed(message): return message
        case .stale: return "The recording changed while the request was being prepared. Try the request again."
        case .pendingDraft: return "Finish the current edit before applying this request."
        }
    }
}

/// Every adapter passes through this boundary. Validation builds a separate
/// value before commit, so a rejected command cannot partially edit a project.
enum EditorCommandDispatcher {
    static func revision(for project: RecordingProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(project)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func context(editor: ProjectEditor, projectID: UUID) throws -> EditorCommandContext {
        guard editor.draftState == nil else { throw EditorCommandError.pendingDraft }
        return EditorCommandContext(projectID: projectID, revision: try revision(for: editor.project),
                                    duration: editor.project.duration, state: editor.project.state,
                                    references: editor.project.references, history: editor.historyState)
    }

    static func prepare(_ batch: EditorCommandBatch, for project: RecordingProject,
                        projectID: UUID) throws -> EditState {
        try project.validate()
        guard batch.version == 1 else { throw EditorCommandError.invalid("This editing request uses an unsupported version.") }
        guard batch.projectID == projectID, batch.revision == (try revision(for: project)) else {
            throw EditorCommandError.stale
        }
        guard !batch.commands.isEmpty, batch.commands.count <= 128 else {
            throw EditorCommandError.invalid("An editing request must contain between 1 and 128 actions.")
        }
        var next = project.state
        var previousTime = -Double.infinity
        func validTime(_ time: Double) throws {
            // The exclusive end cannot hold a visible edit. Callers use the
            // actual last frame timestamp rather than silently moving a request.
            guard time.isFinite, time >= 0, time < project.duration else {
                throw EditorCommandError.invalid("The edit time must be before the end of the recording.")
            }
            guard time >= previousTime else {
                throw EditorCommandError.invalid("New edits in a request must be in time order.")
            }
            previousTime = time
        }
        func region(_ id: UUID) throws -> EditorRegion {
            guard let value = next.regions.first(where: { $0.id == id }) else {
                throw EditorCommandError.invalid("That box no longer exists. Select a numbered box and try again.")
            }
            return value
        }
        func put(_ placement: ZoomPlacement, at time: Double, motion: EditorCommandMotion,
                 preserving point: ZoomKeyframe? = nil) {
            let sameTime = next.zoomKeyframes.first { abs($0.time - time) < 0.000_001 }
            let group = next.timedEdits(includeCamera: true).first { abs($0.time - time) < 0.000_001 }
            let existing = point ?? sameTime
            let targetTime = existing?.time ?? group?.time ?? time
            next.zoomKeyframes.removeAll { abs($0.time - targetTime) < 0.000_001 }
            next.zoomKeyframes.append(ZoomKeyframe(id: existing?.id ?? group?.id ?? UUID(), time: targetTime,
                scale: placement.scale, x: placement.x, y: placement.y,
                transition: motion.transition, duration: motion.duration, easeIn: motion.easeIn, easeOut: motion.easeOut))
            next.zoomKeyframes.sort { $0.time < $1.time }
        }
        for command in batch.commands {
            switch command {
            case let .createEdit(time):
                guard time.isFinite, time >= 0, time < project.duration else {
                    throw EditorCommandError.invalid("The edit mark must be inside the recording.")
                }
                if !next.timedEdits(includeCamera: true).contains(where: { abs($0.time - time) < 0.000_001 }) {
                    next.editAnchors.append(EditAnchor(time: time))
                    next.editAnchors.sort { $0.time < $1.time }
                }
            case let .moveEdit(editID, time):
                guard time.isFinite, time >= 0, time < project.duration else {
                    throw EditorCommandError.invalid("The edit mark must stay inside the recording.")
                }
                let edits = next.timedEdits(includeCamera: true)
                guard let edit = edits.first(where: { $0.id == editID }) else {
                    throw EditorCommandError.invalid("The edit mark no longer exists. Select a visible edit and try again.")
                }
                guard !edits.contains(where: { $0.id != editID && abs($0.time - time) < 0.000_001 }) else {
                    throw EditorCommandError.invalid("Another edit already marks that time. Choose a different time.")
                }
                // The initial camera placement must remain at zero; timed edits
                // never include it as a movable component.
                if edit.cameraID != nil, time == 0 {
                    throw EditorCommandError.invalid("Move this camera edit after the initial placement at the start of the recording.")
                }
                next.move(edit, to: time)
            case let .removeEdit(editID):
                guard let edit = next.timedEdits(includeCamera: true).first(where: { $0.id == editID }) else {
                    throw EditorCommandError.invalid("The edit mark no longer exists. Select a visible edit and try again.")
                }
                next.remove(edit)
            case let .frameRegion(regionID, time, motion):
                try validTime(time)
                try motion.validate()
                put(try region(regionID).rect.framing(), at: time, motion: motion)
            case let .fullFrame(time, motion):
                try validTime(time)
                try motion.validate()
                put(ZoomPlacement(), at: time, motion: motion)
            case let .holdFraming(time):
                try validTime(time)
                let placement = next.zoom(at: time)
                put(placement, at: time, motion: EditorCommandMotion(transition: .jump))
            case let .reviseFraming(editID, regionID):
                guard let edit = next.timedEdits(includeCamera: true).first(where: { $0.id == editID }) else {
                    throw EditorCommandError.invalid("The selected edit no longer exists. Select an edit and try again.")
                }
                let original = next.zoomKeyframes.first { $0.id == edit.zoomID }
                let motion = original.map { EditorCommandMotion(transition: $0.transition, duration: $0.duration,
                                                                 easeIn: $0.easeIn, easeOut: $0.easeOut) } ?? EditorCommandMotion()
                put(try region(regionID).rect.framing(), at: edit.time, motion: motion, preserving: original)
            case let .labelRegion(regionID, note):
                guard let index = next.regions.firstIndex(where: { $0.id == regionID }) else {
                    throw EditorCommandError.invalid("That box no longer exists. Select a numbered box and try again.")
                }
                next.regions[index].note = note
                try next.regions[index].validate(duration: project.duration)
            case let .moveBetweenEdits(fromEditID, toEditID, regionID):
                let edits = next.timedEdits(includeCamera: true)
                guard let from = edits.first(where: { $0.id == fromEditID }),
                      let to = edits.first(where: { $0.id == toEditID }),
                      to.time - from.time >= 0.1 else {
                    throw EditorCommandError.invalid("Choose two different edits with room for a smooth movement between them.")
                }
                guard !next.zoomKeyframes.contains(where: { $0.time > from.time && $0.time < to.time }) else {
                    throw EditorCommandError.invalid("There are framing edits between those edits. Choose adjacent framing edits or revise the intervening edits first.")
                }
                if to.zoomID == nil,
                   let crossing = next.zoomKeyframes.first(where: { $0.time > to.time }),
                   crossing.transition == .smooth, crossing.time - crossing.duration < to.time {
                    throw EditorCommandError.invalid("An existing framing movement crosses the destination edit. Revise that movement before adding this path.")
                }
                let target = try region(regionID).rect.framing()
                let midpoint = from.time + (to.time - from.time) / 2
                let duration = midpoint - from.time
                // Materialize an unchanged starting view for a reference-only
                // or camera-only edit. No earlier interpolation is rewritten.
                if from.zoomID == nil {
                    let crossing = next.zoomKeyframes.first { $0.time > from.time }
                    if let crossing, crossing.transition == .smooth,
                       crossing.time - crossing.duration < from.time {
                        throw EditorCommandError.invalid("An existing framing movement crosses the starting edit. Revise that movement before adding this path.")
                    }
                    put(next.zoom(at: from.time), at: from.time, motion: EditorCommandMotion(transition: .jump))
                }
                put(ZoomPlacement(), at: midpoint, motion: EditorCommandMotion(transition: .smooth, duration: duration))
                let existing = next.zoomKeyframes.first { $0.id == to.zoomID }
                put(target, at: to.time, motion: EditorCommandMotion(transition: .smooth, duration: duration), preserving: existing)
            case let .moveForDuration(startEditID, fromRegionID, toRegionID, duration, viaFullFrame):
                guard duration.isFinite, duration > 0, duration <= 60 else {
                    throw EditorCommandError.invalid("Choose a movement lasting more than zero and at most 60 seconds.")
                }
                guard let start = next.timedEdits(includeCamera: true).first(where: { $0.id == startEditID }) else {
                    throw EditorCommandError.invalid("The starting edit no longer exists. Select a visible edit and try again.")
                }
                let end = start.time + duration
                guard end.isFinite, end < project.duration else {
                    throw EditorCommandError.invalid("The movement would finish at or past the end of the recording. Choose a shorter duration or an earlier starting edit.")
                }
                let source = try region(fromRegionID).rect.framing()
                let target = try region(toRegionID).rect.framing()
                let original = next.zoomKeyframes.first { $0.id == start.zoomID }
                let arrival = next.zoomKeyframes.first { abs($0.time - end) < 0.000_001 }
                guard !next.zoomKeyframes.contains(where: { $0.time > start.time + 0.000_001 && $0.time < end - 0.000_001 }) else {
                    throw EditorCommandError.invalid("Another screen-framing edit falls inside this movement. Choose how to handle that edit before adding the movement.")
                }
                if let arrival, arrival.placement.clamped != target {
                    throw EditorCommandError.invalid("A different screen-framing edit already occupies the arrival time. Choose whether to replace it before adding this movement.")
                }
                if let following = next.zoomKeyframes.first(where: { $0.time > end + 0.000_001 }),
                   following.transition == .smooth, following.time - following.duration < end {
                    throw EditorCommandError.invalid("An existing screen-framing movement crosses the arrival time. Revise that movement before adding this one.")
                }
                if original == nil, let crossing = next.zoomKeyframes.first(where: { $0.time > start.time }),
                   crossing.transition == .smooth, crossing.time - crossing.duration < start.time {
                    throw EditorCommandError.invalid("An existing screen-framing movement crosses the starting edit. Revise that movement before adding this one.")
                }
                // Setting the named start is an explicit revision of that edit.
                // Preserve its incoming movement; new reference marks start with a cut.
                let startMotion = original.map {
                    EditorCommandMotion(transition: $0.transition, duration: $0.duration,
                        easeIn: $0.easeIn, easeOut: $0.easeOut)
                } ?? EditorCommandMotion(transition: .jump)
                put(source, at: start.time, motion: startMotion, preserving: original)
                if !next.timedEdits(includeCamera: true).contains(where: { abs($0.time - end) < 0.000_001 }) {
                    next.editAnchors.append(EditAnchor(time: end))
                    next.editAnchors.sort { $0.time < $1.time }
                }
                if viaFullFrame {
                    let half = duration / 2
                    put(ZoomPlacement(), at: start.time + half, motion: EditorCommandMotion(transition: .smooth, duration: half))
                    put(target, at: end, motion: EditorCommandMotion(transition: .smooth, duration: half), preserving: arrival)
                } else {
                    put(target, at: end, motion: EditorCommandMotion(transition: .smooth, duration: duration), preserving: arrival)
                }
            }
        }
        var candidate = project
        candidate.state = next
        try candidate.validate()
        return next
    }

    @MainActor
    @discardableResult
    static func apply(_ batch: EditorCommandBatch, to editor: ProjectEditor, projectID: UUID,
                      name: String = "Edit with assistant") throws -> Bool {
        guard editor.draftState == nil else { throw EditorCommandError.pendingDraft }
        let next = try prepare(batch, for: editor.project, projectID: projectID)
        guard editor.commit(next, name: name) else {
            throw EditorCommandError.saveFailed(editor.errorMessage ?? "The recording could not be saved.")
        }
        return true
    }
}
