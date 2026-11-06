import Combine
import CoreGraphics
import Foundation

enum PIPTransition: String, Codable, CaseIterable, Sendable {
    case jump
    case smooth
}

enum PIPShape: String, Codable, CaseIterable, Sendable {
    case original
    case rectangle
    case square
    case circle
}

enum PIPResizeCorner: CaseIterable, Hashable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// The crop is expressed in the oriented camera source's top-left coordinate
/// space. Its anchor selects a fraction of the available horizontal/vertical
/// travel, so the same edit works independently of the capture resolution.
struct PIPCrop: Codable, Equatable, Sendable {
    var x: Double = 0.5
    var y: Double = 0.5

    func rect(in source: CGSize, shape: PIPShape, aspectRatio: Double = 1) -> CGRect {
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else { return .zero }
        guard shape != .original else { return CGRect(origin: .zero, size: source) }
        let ratio = shape == .rectangle && aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
        let width = min(source.width, source.height * ratio)
        let height = width / ratio
        let horizontal = x.isFinite ? min(1, max(0, x)) : 0.5
        let vertical = y.isFinite ? min(1, max(0, y)) : 0.5
        return CGRect(x: (source.width - width) * horizontal,
                      y: (source.height - height) * vertical,
                      width: width, height: height)
    }

    /// Move the crop window in oriented source coordinates. UI gestures that
    /// move the image itself should negate their translation before calling.
    func moved(by translation: CGSize, in source: CGSize, shape: PIPShape,
               aspectRatio: Double = 1) -> PIPCrop {
        guard translation.width.isFinite, translation.height.isFinite else { return self }
        let bounds = rect(in: source, shape: shape, aspectRatio: aspectRatio)
        guard bounds.width > 0, bounds.height > 0 else { return self }
        var next = self
        let horizontalTravel = source.width - bounds.width
        let verticalTravel = source.height - bounds.height
        if horizontalTravel > 0 {
            next.x = min(1, max(0, x + translation.width / horizontalTravel))
        }
        if verticalTravel > 0 {
            next.y = min(1, max(0, y + translation.height / verticalTravel))
        }
        return next
    }
}

/// Coordinates describe the fraction of the available travel, rather than the
/// canvas itself, so every placement remains on screen as the PIP is resized.
struct PIPPlacement: Codable, Equatable, Sendable {
    var x: Double = 0.95
    var y: Double = 0.95
    var scale: Double = 0.25
    var visible: Bool = true
    var shape: PIPShape = .original
    var aspectRatio: Double = 16.0 / 9.0
    var crop: PIPCrop = PIPCrop()

    init(x: Double = 0.95, y: Double = 0.95, scale: Double = 0.25, visible: Bool = true,
         shape: PIPShape = .original, aspectRatio: Double = 16.0 / 9.0, crop: PIPCrop = PIPCrop()) {
        self.x = x
        self.y = y
        self.scale = scale
        self.visible = visible
        self.shape = shape
        self.aspectRatio = aspectRatio
        self.crop = crop
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, scale, visible, shape, aspectRatio, crop
    }

    /// Decode defaults on each placement so old projects and every old undo/redo
    /// snapshot retain their native camera framing when reopened.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        scale = try values.decode(Double.self, forKey: .scale)
        visible = try values.decode(Bool.self, forKey: .visible)
        shape = try values.decodeIfPresent(PIPShape.self, forKey: .shape) ?? .original
        aspectRatio = try values.decodeIfPresent(Double.self, forKey: .aspectRatio) ?? 16.0 / 9.0
        crop = try values.decodeIfPresent(PIPCrop.self, forKey: .crop) ?? PIPCrop()
    }

    func frame(in canvas: CGSize, cameraAspect: Double) -> CGRect {
        guard canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0 else { return .zero }
        let originalAspect = cameraAspect.isFinite && cameraAspect > 0 ? cameraAspect : 16.0 / 9.0
        let aspect: Double
        switch shape {
        case .original: aspect = originalAspect
        case .square, .circle: aspect = 1
        case .rectangle: aspect = aspectRatio.isFinite ? min(5, max(0.2, aspectRatio)) : 16.0 / 9.0
        }
        let fraction = scale.isFinite ? min(0.5, max(0.12, scale)) : 0.25
        let width = min(canvas.width * fraction, canvas.height * 0.8 * aspect)
        let height = width / aspect
        let horizontal = x.isFinite ? min(1, max(0, x)) : 0.95
        let vertical = y.isFinite ? min(1, max(0, y)) : 0.95
        return CGRect(x: (canvas.width - width) * horizontal,
                      y: (canvas.height - height) * vertical,
                      width: width, height: height)
    }

    /// Resize from any corner while retaining its opposite corner whenever
    /// minimum size and canvas bounds permit. Only rectangles change aspect.
    func resized(by translation: CGSize, corner: PIPResizeCorner = .bottomRight,
                 in canvas: CGSize, cameraAspect: Double) -> PIPPlacement {
        guard canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0,
              translation.width.isFinite, translation.height.isFinite,
              translation != .zero else { return self }
        let original = frame(in: canvas, cameraAspect: cameraAspect)
        let growsRight = corner == .topRight || corner == .bottomRight
        let growsDown = corner == .bottomLeft || corner == .bottomRight
        let anchor = CGPoint(x: growsRight ? original.minX : original.maxX,
                             y: growsDown ? original.minY : original.maxY)
        let availableWidth = growsRight ? canvas.width - anchor.x : anchor.x
        let availableHeight = growsDown ? canvas.height - anchor.y : anchor.y
        let horizontalDelta = translation.width * (growsRight ? 1 : -1)
        let verticalDelta = translation.height * (growsDown ? 1 : -1)
        let widthDelta: Double
        if shape == .rectangle {
            widthDelta = horizontalDelta
        } else {
            let horizontalFraction = horizontalDelta / original.width
            let verticalFraction = verticalDelta / original.height
            let dominant = abs(horizontalFraction) >= abs(verticalFraction) ? horizontalFraction : verticalFraction
            widthDelta = original.width * dominant
        }
        let proposedWidth = max(canvas.width * 0.12,
                                min(canvas.width * 0.5, availableWidth, original.width + widthDelta))
        var next = self
        next.scale = proposedWidth / canvas.width
        if shape == .rectangle {
            let proposedHeight = max(1, min(availableHeight, canvas.height * 0.8, original.height + verticalDelta))
            next.aspectRatio = min(5, max(0.2, proposedWidth / proposedHeight))
        }
        var resized = next.frame(in: canvas, cameraAspect: cameraAspect)
        let fit = min(1, availableWidth / resized.width, availableHeight / resized.height)
        if fit < 1 {
            next.scale = min(0.5, max(0.12, resized.width * max(0, fit) / canvas.width))
            resized = next.frame(in: canvas, cameraAspect: cameraAspect)
        }
        let originX = growsRight ? anchor.x : anchor.x - resized.width
        let originY = growsDown ? anchor.y : anchor.y - resized.height
        next.x = min(1, max(0, originX / max(1, canvas.width - resized.width)))
        next.y = min(1, max(0, originY / max(1, canvas.height - resized.height)))
        return next
    }
}

struct PIPKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var time: Double
    var placement: PIPPlacement
    var transition: PIPTransition = .jump
    /// Smooth transitions arrive at `time`; their beginning is clamped to the
    /// preceding point so transitions never overlap.
    var duration: Double = 0.4
}

struct EditState: Codable, Equatable, Sendable {
    var trimStart: Double
    var trimEnd: Double
    var pipKeyframes: [PIPKeyframe]

    func placement(at time: Double) -> PIPPlacement {
        let points = pipKeyframes.sorted { $0.time < $1.time }
        guard var previous = points.first else { return PIPPlacement() }
        guard time.isFinite, time > previous.time else { return previous.placement }
        for point in points.dropFirst() {
            if time >= point.time {
                previous = point
                continue
            }
            guard point.transition == .smooth else { return previous.placement }
            let beginning = max(previous.time, point.time - point.duration)
            guard time > beginning, point.time > beginning else { return previous.placement }
            let progress = min(1, max(0, (time - beginning) / (point.time - beginning)))
            let eased = progress * progress * (3 - 2 * progress)
            func blend(_ start: Double, _ end: Double) -> Double {
                start + (end - start) * eased
            }
            return PIPPlacement(x: blend(previous.placement.x, point.placement.x),
                                y: blend(previous.placement.y, point.placement.y),
                                scale: blend(previous.placement.scale, point.placement.scale),
                                visible: previous.placement.visible,
                                shape: previous.placement.shape,
                                aspectRatio: blend(previous.placement.aspectRatio, point.placement.aspectRatio),
                                crop: PIPCrop(x: blend(previous.placement.crop.x, point.placement.crop.x),
                                              y: blend(previous.placement.crop.y, point.placement.crop.y)))
        }
        return previous.placement
    }

    /// Replacing a point preserves its identity, keeping timeline selection
    /// stable when users adjust the same moment repeatedly.
    mutating func upsert(_ point: PIPKeyframe) {
        if let index = pipKeyframes.firstIndex(where: { abs($0.time - point.time) < 0.000_001 }) {
            var replacement = point
            replacement.id = pipKeyframes[index].id
            replacement.time = pipKeyframes[index].time
            pipKeyframes[index] = replacement
        } else {
            pipKeyframes.append(point)
        }
        pipKeyframes.sort { $0.time < $1.time }
    }
}

struct NamedEditSnapshot: Codable, Equatable, Sendable {
    var name: String
    var state: EditState
}

/// Media filenames are relative to the project. Source media is never opened
/// for writing by the editor, and history survives saving and reopening.
struct RecordingProject: Codable, Equatable, Sendable {
    var version: Int = 1
    var screenFilename: String
    var cameraFilename: String?
    /// Camera start relative to the first screen frame; negative means the
    /// camera started earlier. This is independent of the editable trim.
    var cameraOffset: Double = 0
    var duration: Double
    var state: EditState
    var undoHistory: [NamedEditSnapshot] = []
    var redoHistory: [NamedEditSnapshot] = []

    init(version: Int = 1, screenFilename: String, cameraFilename: String? = nil,
         cameraOffset: Double = 0, duration: Double, state: EditState? = nil,
         undoHistory: [NamedEditSnapshot] = [], redoHistory: [NamedEditSnapshot] = []) {
        self.version = version
        self.screenFilename = screenFilename
        self.cameraFilename = cameraFilename
        self.cameraOffset = cameraOffset
        self.duration = duration
        self.state = state ?? EditState(trimStart: 0, trimEnd: duration,
                                       pipKeyframes: [PIPKeyframe(time: 0, placement: PIPPlacement())])
        self.undoHistory = undoHistory
        self.redoHistory = redoHistory
    }

    /// Geometry edits belong to the source frame visible at the playhead. In
    /// particular, the exclusive source end maps to the final output frame,
    /// rather than creating an edit that can never appear in an export.
    func editingTime(at position: Double, frameDuration: Double = 1.0 / 30.0) -> Double {
        Self.editingTime(at: position, duration: duration, frameDuration: frameDuration)
    }

    static func editingTime(at position: Double, duration: Double, frameDuration: Double = 1.0 / 30.0) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let candidate = frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30.0
        let interval = (duration / candidate).isFinite ? candidate : 1.0 / 30.0
        let bounded = position.isFinite ? min(max(position, 0), duration) : 0
        let frameIndex = floor(bounded / interval)
        let lastIndex = max(0, ceil(duration / interval) - 1)
        return min(duration, max(0, min(frameIndex, lastIndex) * interval))
    }

    func validate() throws {
        guard version == 1 else { throw ProjectError.invalid("Unsupported project version: \(version).") }
        guard duration.isFinite, duration > 0, cameraOffset.isFinite else {
            throw ProjectError.invalid("The recording has an invalid duration or camera offset.")
        }
        for filename in [screenFilename, cameraFilename].compactMap({ $0 }) {
            guard !filename.isEmpty, filename != ".", filename != "..",
                  !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else {
                throw ProjectError.invalid("Project media must be adjacent files with relative filenames.")
            }
        }
        guard cameraFilename != screenFilename else {
            throw ProjectError.invalid("Screen and camera must use separate source files.")
        }
        try validate(state)
        for snapshot in undoHistory + redoHistory { try validate(snapshot.state) }
    }

    private func validate(_ state: EditState) throws {
        guard state.trimStart.isFinite, state.trimEnd.isFinite,
              state.trimStart >= 0, state.trimEnd <= duration,
              state.trimStart < state.trimEnd else {
            throw ProjectError.invalid("Trim boundaries must keep a nonempty range within the original recording.")
        }
        guard state.pipKeyframes.first?.time == 0 else {
            throw ProjectError.invalid("The initial camera placement must remain at the start of the recording.")
        }
        var priorTime = -Double.infinity
        var identities = Set<UUID>()
        for point in state.pipKeyframes {
            let placement = point.placement
            guard point.time.isFinite, point.time >= 0, point.time <= duration,
                  point.time > priorTime, identities.insert(point.id).inserted,
                  point.duration.isFinite, point.duration > 0,
                  placement.x.isFinite, (0...1).contains(placement.x),
                  placement.y.isFinite, (0...1).contains(placement.y),
                  placement.scale.isFinite, (0.12...0.5).contains(placement.scale),
                  placement.aspectRatio.isFinite, (0.2...5).contains(placement.aspectRatio),
                  placement.crop.x.isFinite, (0...1).contains(placement.crop.x),
                  placement.crop.y.isFinite, (0...1).contains(placement.crop.y) else {
                throw ProjectError.invalid("Camera placements must have unique, ordered times and valid positions and sizes.")
            }
            priorTime = point.time
        }
    }
}

enum ProjectError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        }
    }
}

@MainActor
final class ProjectEditor: ObservableObject {
    @Published private(set) var project: RecordingProject
    @Published private(set) var errorMessage: String?
    let url: URL

    var canUndo: Bool { !project.undoHistory.isEmpty }
    var canRedo: Bool { !project.redoHistory.isEmpty }
    var undoName: String { project.undoHistory.last?.name ?? "" }
    var redoName: String { project.redoHistory.last?.name ?? "" }

    init(project: RecordingProject, url: URL) {
        self.project = project
        self.url = url
    }

    static func open(url: URL) throws -> ProjectEditor {
        let project = try JSONDecoder().decode(RecordingProject.self, from: Data(contentsOf: url))
        try project.validate()
        return ProjectEditor(project: project, url: url)
    }

    func mediaURL(for filename: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(filename)
    }

    @discardableResult
    func commit(_ state: EditState, name: String) -> Bool {
        guard state != project.state else { return true }
        var next = project
        next.undoHistory.append(NamedEditSnapshot(name: name, state: project.state))
        next.redoHistory.removeAll()
        next.state = state
        return persist(next)
    }

    @discardableResult
    func undo() -> Bool {
        guard let snapshot = project.undoHistory.last else { return false }
        var next = project
        next.undoHistory.removeLast()
        next.redoHistory.append(NamedEditSnapshot(name: snapshot.name, state: project.state))
        next.state = snapshot.state
        return persist(next)
    }

    @discardableResult
    func redo() -> Bool {
        guard let snapshot = project.redoHistory.last else { return false }
        var next = project
        next.redoHistory.removeLast()
        next.undoHistory.append(NamedEditSnapshot(name: snapshot.name, state: project.state))
        next.state = snapshot.state
        return persist(next)
    }

    @discardableResult
    func save() -> Bool { persist(project) }

    private func persist(_ candidate: RecordingProject) -> Bool {
        do {
            try candidate.validate()
            let target = url.standardizedFileURL.resolvingSymlinksInPath()
            for filename in [candidate.screenFilename, candidate.cameraFilename].compactMap({ $0 }) {
                guard mediaURL(for: filename).standardizedFileURL.resolvingSymlinksInPath() != target else {
                    throw ProjectError.invalid("The project file cannot replace original media.")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(candidate).write(to: url, options: .atomic)
            project = candidate
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
