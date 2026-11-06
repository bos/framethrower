import Combine
import CoreGraphics
import CryptoKit
import Foundation

enum PIPTransition: String, Codable, CaseIterable, Sendable {
    case jump
    case smooth
}

enum MotionInterpolation {
    /// All camera and screen movement arrives at the target timestamp. The
    /// preceding point bounds the start, so smooth transitions never overlap.
    static func progress(at time: Double, from previousTime: Double, to targetTime: Double,
                         duration: Double, transition: PIPTransition,
                         easeIn: Double? = nil, easeOut: Double? = nil) -> Double {
        guard time.isFinite, previousTime.isFinite, targetTime.isFinite else { return 0 }
        if time >= targetTime { return 1 }
        guard transition == .smooth, duration.isFinite, duration > 0 else { return 0 }
        let beginning = max(previousTime, targetTime - duration)
        guard time > beginning, targetTime > beginning else { return 0 }
        let fraction = min(1, max(0, (time - beginning) / (targetTime - beginning)))
        // Integrate cosine velocity ramps around a constant-speed middle.
        // Velocity and acceleration stay continuous wherever a ramp is used.
        let span = targetTime - beginning
        let ramps = rampDurations(duration: span, easeIn: easeIn, easeOut: easeOut)
        let startRamp = ramps.easeIn / span
        let endRamp = ramps.easeOut / span
        let distance = 1 - (startRamp + endRamp) / 2
        func accelerate(_ fraction: Double, ramp: Double) -> Double {
            (fraction / 2 - ramp / (2 * .pi) * sin(.pi * fraction / ramp)) / distance
        }
        if fraction < startRamp { return accelerate(fraction, ramp: startRamp) }
        if fraction > 1 - endRamp { return 1 - accelerate(1 - fraction, ramp: endRamp) }
        return (fraction - startRamp / 2) / distance
    }

    /// Ramp values are seconds within the effective movement interval. If an
    /// adjacent edit shortens the interval, both ramps shrink proportionally.
    static func rampDurations(duration: Double, easeIn: Double? = nil,
                              easeOut: Double? = nil) -> (easeIn: Double, easeOut: Double) {
        guard duration.isFinite, duration > 0 else { return (0, 0) }
        func bounded(_ value: Double?) -> Double {
            guard let value, value.isFinite else { return duration / 4 }
            return max(0, value)
        }
        let start = bounded(easeIn)
        let end = bounded(easeOut)
        // Divide first, avoiding overflow when two individually valid durations
        // are extremely large. The relative lengths are still preserved.
        let largest = max(start, end)
        guard largest > 0 else { return (0, 0) }
        let relativeSum = start / largest + end / largest
        if largest > duration / relativeSum {
            return (duration * (start / largest) / relativeSum,
                    duration * (end / largest) / relativeSum)
        }
        return (start, end)
    }

    static func blend(_ start: Double, _ end: Double, progress: Double) -> Double {
        let fraction = progress.isFinite ? min(1, max(0, progress)) : 0
        return start + (end - start) * fraction
    }
}

/// Shared source-viewport geometry for screen zooms, camera crops, and PIP
/// frames. Travel anchors are converted to source focal points at this boundary
/// so existing PIP project coordinates retain their exact meaning.
enum ViewportGeometry {
    static func rect(in source: CGSize, size: CGSize, center: CGPoint) -> CGRect {
        guard let size = boundedSize(size, in: source) else { return .zero }
        let x = center.x.isFinite ? min(1, max(0, center.x)) : 0.5
        let y = center.y.isFinite ? min(1, max(0, center.y)) : 0.5
        return CGRect(x: min(source.width - size.width, max(0, source.width * x - size.width / 2)),
                      y: min(source.height - size.height, max(0, source.height * y - size.height / 2)),
                      width: size.width, height: size.height)
    }

    static func rect(in source: CGSize, size: CGSize, travelAnchor: CGPoint) -> CGRect {
        guard let size = boundedSize(size, in: source) else { return .zero }
        let x = travelAnchor.x.isFinite ? min(1, max(0, travelAnchor.x)) : 0.5
        let y = travelAnchor.y.isFinite ? min(1, max(0, travelAnchor.y)) : 0.5
        let center = CGPoint(x: (size.width / 2 + (source.width - size.width) * x) / source.width,
                             y: (size.height / 2 + (source.height - size.height) * y) / source.height)
        return rect(in: source, size: size, center: center)
    }

    private static func boundedSize(_ size: CGSize, in source: CGSize) -> CGSize? {
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return CGSize(width: min(source.width, size.width), height: min(source.height, size.height))
    }
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

    func rect(in source: CGSize, shape: PIPShape, aspectRatio: Double = 1, zoom: Double = 1) -> CGRect {
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else { return .zero }
        let magnification = zoom.isFinite ? min(3, max(1, zoom)) : 1
        let ratio = shape == .rectangle && aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
        let width = (shape == .original ? source.width : min(source.width, source.height * ratio)) / magnification
        let height = (shape == .original ? source.height : min(source.width, source.height * ratio) / ratio) / magnification
        let horizontal = x.isFinite ? min(1, max(0, x)) : 0.5
        let vertical = y.isFinite ? min(1, max(0, y)) : 0.5
        return ViewportGeometry.rect(in: source, size: CGSize(width: width, height: height),
                                     travelAnchor: CGPoint(x: horizontal, y: vertical))
    }

    /// Move the crop window in oriented source coordinates. UI gestures that
    /// move the image itself should negate their translation before calling.
    func moved(by translation: CGSize, in source: CGSize, shape: PIPShape,
               aspectRatio: Double = 1, zoom: Double = 1) -> PIPCrop {
        guard translation.width.isFinite, translation.height.isFinite else { return self }
        let bounds = rect(in: source, shape: shape, aspectRatio: aspectRatio, zoom: zoom)
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
    var sourceZoom: Double = 1

    init(x: Double = 0.95, y: Double = 0.95, scale: Double = 0.25, visible: Bool = true,
         shape: PIPShape = .original, aspectRatio: Double = 16.0 / 9.0, crop: PIPCrop = PIPCrop(), sourceZoom: Double = 1) {
        self.x = x
        self.y = y
        self.scale = scale
        self.visible = visible
        self.shape = shape
        self.aspectRatio = aspectRatio
        self.crop = crop
        self.sourceZoom = sourceZoom
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, scale, visible, shape, aspectRatio, crop, sourceZoom
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
        sourceZoom = try values.decodeIfPresent(Double.self, forKey: .sourceZoom) ?? 1
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
        return ViewportGeometry.rect(in: canvas, size: CGSize(width: width, height: height),
                                     travelAnchor: CGPoint(x: horizontal, y: vertical))
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
    var easeIn: Double? = nil
    var easeOut: Double? = nil
}

struct ZoomPlacement: Codable, Equatable, Sendable {
    var scale: Double = 1
    /// Normalized source focal point, with a top-left origin.
    var x: Double = 0.5
    var y: Double = 0.5

    var clamped: ZoomPlacement {
        let scale = scale.isFinite ? min(3, max(1, scale)) : 1
        let viewport = ViewportGeometry.rect(in: CGSize(width: 1, height: 1),
            size: CGSize(width: 1 / scale, height: 1 / scale), center: CGPoint(x: x, y: y))
        return ZoomPlacement(scale: scale, x: viewport.midX, y: viewport.midY)
    }

    func viewport(in source: CGSize) -> CGRect {
        let placement = clamped
        return ViewportGeometry.rect(in: source,
            size: CGSize(width: source.width / placement.scale, height: source.height / placement.scale),
            center: CGPoint(x: placement.x, y: placement.y))
    }
}

struct ZoomKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var time: Double
    var scale: Double = 1
    var x: Double = 0.5
    var y: Double = 0.5
    var transition: PIPTransition = .jump
    /// Smooth transitions arrive at `time`, beginning no earlier than the
    /// previous zoom point or the start of the source recording.
    var duration: Double = 0.4
    var easeIn: Double? = nil
    var easeOut: Double? = nil

    var placement: ZoomPlacement { ZoomPlacement(scale: scale, x: x, y: y) }
}

struct CursorStyle: Codable, Equatable, Sendable {
    var visible: Bool = true
    var size: Double = 1.5
    var smoothing: Double = 0.4
    var clickHighlight: Bool = true
}

enum CanvasAspect: String, Codable, CaseIterable, Sendable {
    case source, wide, portrait, square
}

struct CanvasColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    static let black = CanvasColor(red: 0, green: 0, blue: 0)
}

/// Presentation applies to the whole recording. Source-time edits keep their
/// existing screen and camera coordinates when the output canvas changes.
struct CanvasPresentation: Codable, Equatable, Sendable {
    var aspect: CanvasAspect = .source
    /// Inset as a fraction of the output canvas's shorter edge.
    var padding: Double = 0
    /// Screen corner radius as a fraction of the fitted screen's shorter edge.
    var cornerRadius: Double = 0
    var background: CanvasColor = .black
}

/// The common top-left coordinate mapping for rendering and native gestures.
/// The recording always fits in full; aspect changes never crop or stretch it.
struct PresentationGeometry: Equatable, Sendable {
    let outputSize: CGSize
    let contentRect: CGRect
    let cornerRadius: CGFloat

    init(sourceSize: CGSize, presentation: CanvasPresentation) {
        let source = CGSize(width: sourceSize.width.isFinite && sourceSize.width > 0 ? sourceSize.width : 16,
                            height: sourceSize.height.isFinite && sourceSize.height > 0 ? sourceSize.height : 9)
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        let edge = max(source.width, source.height)
        switch presentation.aspect {
        case .source: outputSize = CGSize(width: even(source.width), height: even(source.height))
        case .wide: outputSize = CGSize(width: even(edge), height: even(edge * 9 / 16))
        case .portrait: outputSize = CGSize(width: even(edge * 9 / 16), height: even(edge))
        case .square: outputSize = CGSize(width: even(edge), height: even(edge))
        }
        let padding = presentation.padding.isFinite ? min(0.2, max(0, presentation.padding)) : 0
        let inset = min(outputSize.width, outputSize.height) * padding
        let available = CGRect(origin: .zero, size: outputSize).insetBy(dx: inset, dy: inset)
        let scale = min(available.width / source.width, available.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        contentRect = CGRect(x: (outputSize.width - size.width) / 2,
                             y: (outputSize.height - size.height) / 2,
                             width: size.width, height: size.height)
        let radius = presentation.cornerRadius.isFinite ? min(0.2, max(0, presentation.cornerRadius)) : 0
        cornerRadius = min(size.width, size.height) * radius
    }

    func outputRect(in bounds: CGRect) -> CGRect {
        let scale = max(0, min(bounds.width / outputSize.width, bounds.height / outputSize.height))
        let size = CGSize(width: outputSize.width * scale, height: outputSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func contentRect(in bounds: CGRect) -> CGRect {
        let output = outputRect(in: bounds)
        let scale = output.width / outputSize.width
        return CGRect(x: output.minX + contentRect.minX * scale,
                      y: output.minY + contentRect.minY * scale,
                      width: contentRect.width * scale, height: contentRect.height * scale)
    }
}

struct EditState: Codable, Equatable, Sendable {
    var trimStart: Double
    var trimEnd: Double
    var pipKeyframes: [PIPKeyframe]
    var zoomKeyframes: [ZoomKeyframe] = []
    var cursorStyle: CursorStyle = CursorStyle()
    var presentation: CanvasPresentation = CanvasPresentation()
    var regions: [EditorRegion] = []
    var editAnchors: [EditAnchor] = []

    init(trimStart: Double, trimEnd: Double, pipKeyframes: [PIPKeyframe],
         zoomKeyframes: [ZoomKeyframe] = [], cursorStyle: CursorStyle = CursorStyle(),
         presentation: CanvasPresentation = CanvasPresentation(), regions: [EditorRegion] = [],
         editAnchors: [EditAnchor] = []) {
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.pipKeyframes = pipKeyframes
        self.zoomKeyframes = zoomKeyframes
        self.cursorStyle = cursorStyle
        self.presentation = presentation
        self.regions = regions
        self.editAnchors = editAnchors
    }

    private enum CodingKeys: String, CodingKey {
        case trimStart, trimEnd, pipKeyframes, zoomKeyframes, cursorStyle, presentation, regions, editAnchors
    }

    /// Migration lives on each state so prior undo/redo snapshots also gain
    /// identity zooms and default styling without losing any existing edits.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try values.decode(Double.self, forKey: .trimStart)
        trimEnd = try values.decode(Double.self, forKey: .trimEnd)
        pipKeyframes = try values.decode([PIPKeyframe].self, forKey: .pipKeyframes)
        zoomKeyframes = try values.decodeIfPresent([ZoomKeyframe].self, forKey: .zoomKeyframes) ?? []
        cursorStyle = try values.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? CursorStyle()
        presentation = try values.decodeIfPresent(CanvasPresentation.self, forKey: .presentation) ?? CanvasPresentation()
        regions = try values.decodeIfPresent([EditorRegion].self, forKey: .regions) ?? []
        editAnchors = try values.decodeIfPresent([EditAnchor].self, forKey: .editAnchors) ?? []
    }

    func zoom(at time: Double) -> ZoomPlacement {
        guard time.isFinite, time >= 0 else { return ZoomPlacement() }
        var previous = ZoomPlacement()
        var previousTime = 0.0
        for point in zoomKeyframes.sorted(by: { $0.time < $1.time }) {
            if time >= point.time {
                previous = point.placement.clamped
                previousTime = point.time
                continue
            }
            let progress = MotionInterpolation.progress(at: time, from: previousTime, to: point.time,
                                                        duration: point.duration, transition: point.transition,
                                                        easeIn: point.easeIn, easeOut: point.easeOut)
            let target = point.placement.clamped
            return ZoomPlacement(scale: MotionInterpolation.blend(previous.scale, target.scale, progress: progress),
                x: MotionInterpolation.blend(previous.x, target.x, progress: progress),
                y: MotionInterpolation.blend(previous.y, target.y, progress: progress)).clamped
        }
        return previous.clamped
    }

    func placement(at time: Double) -> PIPPlacement {
        let points = pipKeyframes.sorted { $0.time < $1.time }
        guard var previous = points.first else { return PIPPlacement() }
        guard time.isFinite, time > previous.time else { return previous.placement }
        for point in points.dropFirst() {
            if time >= point.time {
                previous = point
                continue
            }
            let progress = MotionInterpolation.progress(at: time, from: previous.time, to: point.time,
                                                        duration: point.duration, transition: point.transition,
                                                        easeIn: point.easeIn, easeOut: point.easeOut)
            func blend(_ start: Double, _ end: Double) -> Double {
                MotionInterpolation.blend(start, end, progress: progress)
            }
            return PIPPlacement(x: blend(previous.placement.x, point.placement.x),
                                y: blend(previous.placement.y, point.placement.y),
                                scale: blend(previous.placement.scale, point.placement.scale),
                                visible: previous.placement.visible,
                                shape: previous.placement.shape,
                                aspectRatio: blend(previous.placement.aspectRatio, point.placement.aspectRatio),
                                crop: PIPCrop(x: blend(previous.placement.crop.x, point.placement.crop.x),
                                              y: blend(previous.placement.crop.y, point.placement.crop.y)),
                                sourceZoom: blend(previous.placement.sourceZoom, point.placement.sourceZoom))
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

/// A named timeline reference can precede any visual edit. Drawing a box must
/// not insert a zoom or alter an existing interpolation merely to name a time.
struct EditAnchor: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var time: Double
}

/// One selectable moment, combining independently animated screen and camera
/// properties. Existing files retain their independent tracks and interpolation.
struct TimedEdit: Identifiable, Equatable {
    let id: UUID
    let time: Double
    let zoomID: UUID?
    let cameraID: UUID?
    let anchorID: UUID?

    init(id: UUID, time: Double, zoomID: UUID?, cameraID: UUID?, anchorID: UUID? = nil) {
        self.id = id
        self.time = time
        self.zoomID = zoomID
        self.cameraID = cameraID
        self.anchorID = anchorID
    }
}

extension EditState {
    func timedEdits(includeCamera: Bool) -> [TimedEdit] {
        var result = zoomKeyframes.map { TimedEdit(id: $0.id, time: $0.time, zoomID: $0.id, cameraID: nil) }
        if includeCamera {
            for camera in pipKeyframes where camera.time > 0 {
                if let index = result.firstIndex(where: { abs($0.time - camera.time) < 0.000001 }) {
                    let zoom = result[index]
                    result[index] = TimedEdit(id: zoom.id, time: zoom.time, zoomID: zoom.zoomID, cameraID: camera.id)
                } else {
                    result.append(TimedEdit(id: camera.id, time: camera.time, zoomID: nil, cameraID: camera.id))
                }
            }
        }
        for anchor in editAnchors {
            if let index = result.firstIndex(where: { abs($0.time - anchor.time) < 0.000001 }) {
                let combined = result[index]
                result[index] = TimedEdit(id: anchor.id, time: anchor.time, zoomID: combined.zoomID,
                                         cameraID: combined.cameraID, anchorID: anchor.id)
            } else {
                result.append(TimedEdit(id: anchor.id, time: anchor.time, zoomID: nil, cameraID: nil, anchorID: anchor.id))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// A box and its reference mark form one value edit and one undo snapshot.
    /// Additional boxes on this frame reuse its existing selectable moment.
    @discardableResult
    mutating func addRegion(rect: EditorRegionRect, at time: Double, includeCamera: Bool = true) -> EditorRegion {
        let editID: UUID
        if let existing = timedEdits(includeCamera: includeCamera).first(where: { abs($0.time - time) < 0.000001 }) {
            editID = existing.id
        } else {
            let anchor = EditAnchor(time: time)
            editAnchors.append(anchor)
            editAnchors.sort { $0.time < $1.time }
            editID = anchor.id
        }
        let region = EditorRegion(time: time, rect: rect, editID: editID)
        regions.append(region)
        return region
    }

    mutating func remove(_ edit: TimedEdit) {
        zoomKeyframes.removeAll { $0.id == edit.zoomID }
        pipKeyframes.removeAll { $0.id == edit.cameraID && $0.time > 0 }
        editAnchors.removeAll { $0.id == edit.anchorID }
    }

    mutating func move(_ edit: TimedEdit, to time: Double) {
        if let index = zoomKeyframes.firstIndex(where: { $0.id == edit.zoomID }) { zoomKeyframes[index].time = time }
        if let index = pipKeyframes.firstIndex(where: { $0.id == edit.cameraID && $0.time > 0 }) { pipKeyframes[index].time = time }
        if let index = editAnchors.firstIndex(where: { $0.id == edit.anchorID }) { editAnchors[index].time = time }
        zoomKeyframes.sort { $0.time < $1.time }
        pipKeyframes.sort { $0.time < $1.time }
        editAnchors.sort { $0.time < $1.time }
    }
}

struct NamedEditSnapshot: Codable, Equatable, Sendable {
    var name: String
    var state: EditState
    var title: String? = nil
}

/// Next action first, matching the normal Undo/Redo controls and model tools.
struct EditorHistoryState: Codable, Equatable, Sendable {
    var undo: [String] = []
    var redo: [String] = []
}

/// Media filenames are relative to the project. Source media is never opened
/// for writing by the editor, and history survives saving and reopening.
struct RecordingProject: Codable, Equatable, Sendable {
    var version: Int = 1
    var screenFilename: String
    var cameraFilename: String?
    var cursorFilename: String?
    var title: String?
    /// Camera start relative to the first screen frame; negative means the
    /// camera started earlier. This is independent of the editable trim.
    var cameraOffset: Double = 0
    /// Capture policy is independent of sparse source samples and edit history.
    /// Older projects omit it and keep their original 30fps render cadence.
    let captureFrameDuration: Double?
    var duration: Double
    var state: EditState
    var undoHistory: [NamedEditSnapshot] = []
    var redoHistory: [NamedEditSnapshot] = []
    var references = EditorReferences()

    init(version: Int = 1, screenFilename: String, cameraFilename: String? = nil, cursorFilename: String? = nil,
         cameraOffset: Double = 0, duration: Double, state: EditState? = nil,
         undoHistory: [NamedEditSnapshot] = [], redoHistory: [NamedEditSnapshot] = [], title: String? = nil,
         captureFrameDuration: Double? = nil, references: EditorReferences = EditorReferences()) {
        self.version = version
        self.screenFilename = screenFilename
        self.cameraFilename = cameraFilename
        self.cursorFilename = cursorFilename
        self.title = title
        self.cameraOffset = cameraOffset
        self.captureFrameDuration = captureFrameDuration
        self.duration = duration
        self.state = state ?? EditState(trimStart: 0, trimEnd: duration,
                                       pipKeyframes: [PIPKeyframe(time: 0, placement: PIPPlacement())])
        self.undoHistory = undoHistory
        self.redoHistory = redoHistory
        self.references = references
        ensureReferences()
    }

    private enum CodingKeys: String, CodingKey {
        case version, screenFilename, cameraFilename, cursorFilename, title, cameraOffset,
             captureFrameDuration, duration, state, undoHistory, redoHistory, references
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        screenFilename = try values.decode(String.self, forKey: .screenFilename)
        cameraFilename = try values.decodeIfPresent(String.self, forKey: .cameraFilename)
        cursorFilename = try values.decodeIfPresent(String.self, forKey: .cursorFilename)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        cameraOffset = try values.decodeIfPresent(Double.self, forKey: .cameraOffset) ?? 0
        captureFrameDuration = try values.decodeIfPresent(Double.self, forKey: .captureFrameDuration)
        duration = try values.decode(Double.self, forKey: .duration)
        state = try values.decode(EditState.self, forKey: .state)
        undoHistory = try values.decodeIfPresent([NamedEditSnapshot].self, forKey: .undoHistory) ?? []
        redoHistory = try values.decodeIfPresent([NamedEditSnapshot].self, forKey: .redoHistory) ?? []
        references = try values.decodeIfPresent(EditorReferences.self, forKey: .references) ?? EditorReferences()
        try references.validate()
        ensureReferences()
    }

    mutating func ensureReferences(in extraState: EditState? = nil) {
        references.register(state: state, includeCamera: cameraFilename != nil)
        if let extraState { references.register(state: extraState, includeCamera: cameraFilename != nil) }
        for snapshot in undoHistory + redoHistory {
            references.register(state: snapshot.state, includeCamera: cameraFilename != nil)
        }
    }

    func displayName(projectURL: URL) -> String {
        title ?? Self.defaultTitle(screenFilename: screenFilename, projectURL: projectURL)
    }

    static func defaultTitle(screenFilename: String, projectURL: URL) -> String {
        let prefix = "Screencast-"
        if screenFilename.hasPrefix(prefix) {
            let timestamp = String(screenFilename.dropFirst(prefix.count).prefix(15))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.isLenient = false
            if timestamp.count == 15, let date = formatter.date(from: timestamp) {
                return "Recording " + date.formatted(date: .abbreviated, time: .standard)
            }
        }
        return projectURL.deletingPathExtension().lastPathComponent
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
        try references.validate()
        guard version == 1 else { throw ProjectError.invalid("Unsupported project version: \(version).") }
        guard duration.isFinite, duration > 0, cameraOffset.isFinite else {
            throw ProjectError.invalid("The recording has an invalid duration or camera offset.")
        }
        if let captureFrameDuration {
            guard captureFrameDuration.isFinite, (1.0 / 120...1.0).contains(captureFrameDuration) else {
                throw ProjectError.invalid("The recording frame duration must be between 1/120 second and 1 second.")
            }
        }
        try Self.validateTitle(title)
        for filename in [screenFilename, cameraFilename, cursorFilename].compactMap({ $0 }) {
            guard !filename.isEmpty, filename != ".", filename != "..",
                  !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else {
                throw ProjectError.invalid("Project media must be adjacent files with relative filenames.")
            }
        }
        guard cameraFilename != screenFilename else {
            throw ProjectError.invalid("Screen and camera must use separate source files.")
        }
        if let cursorFilename, cursorFilename == screenFilename || cursorFilename == cameraFilename {
            throw ProjectError.invalid("Cursor metadata must use a separate source file.")
        }
        try validate(state)
        for snapshot in undoHistory + redoHistory {
            try validate(snapshot.state)
            try Self.validateTitle(snapshot.title)
        }
    }

    fileprivate static func validateTitle(_ title: String?) throws {
        guard let title else { return }
        guard !title.isEmpty, title.count <= 256,
              title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.contains(where: \.isNewline),
              !title.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw ProjectError.invalid("Use a recording name of 1–256 characters without control characters.")
        }
    }

    private func validate(_ state: EditState) throws {
        guard state.editAnchors.count <= 100_000 else {
            throw ProjectError.invalid("Keep at most 100,000 reference marks in a recording.")
        }
        var priorAnchorTime = -Double.infinity
        var anchorIdentities = Set<UUID>()
        for anchor in state.editAnchors {
            guard anchor.time.isFinite, anchor.time >= 0, anchor.time <= duration,
                  anchor.time - priorAnchorTime >= 0.000001,
                  anchorIdentities.insert(anchor.id).inserted else {
                throw ProjectError.invalid("Reference marks must have unique identities and ordered times inside the recording.")
            }
            let componentTimes = [state.zoomKeyframes.first(where: { $0.id == anchor.id })?.time,
                                  state.pipKeyframes.first(where: { $0.id == anchor.id })?.time].compactMap { $0 }
            guard componentTimes.allSatisfy({ abs($0 - anchor.time) < 0.000001 }) else {
                throw ProjectError.invalid("An edit and its reference mark must share the same time.")
            }
            priorAnchorTime = anchor.time
        }
        guard state.regions.count <= 256, Set(state.regions.map(\.id)).count == state.regions.count else {
            throw ProjectError.invalid("Boxes must have unique identities; keep at most 256 per recording.")
        }
        for region in state.regions { try region.validate(duration: duration) }
        let presentation = state.presentation
        guard presentation.padding.isFinite, (0...0.2).contains(presentation.padding),
              presentation.cornerRadius.isFinite, (0...0.2).contains(presentation.cornerRadius),
              [presentation.background.red, presentation.background.green, presentation.background.blue]
                .allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw ProjectError.invalid("Canvas padding, corners, and background color must stay within their supported ranges.")
        }
        guard state.cursorStyle.size.isFinite, (1...4).contains(state.cursorStyle.size),
              state.cursorStyle.smoothing.isFinite, (0...1).contains(state.cursorStyle.smoothing) else {
            throw ProjectError.invalid("Cursor size and smoothing must stay within their supported ranges.")
        }
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
                  [point.easeIn, point.easeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }),
                  placement.x.isFinite, (0...1).contains(placement.x),
                  placement.y.isFinite, (0...1).contains(placement.y),
                  placement.scale.isFinite, (0.12...0.5).contains(placement.scale),
                  placement.aspectRatio.isFinite, (0.2...5).contains(placement.aspectRatio),
                  placement.crop.x.isFinite, (0...1).contains(placement.crop.x),
                  placement.crop.y.isFinite, (0...1).contains(placement.crop.y),
                  placement.sourceZoom.isFinite, (1...3).contains(placement.sourceZoom) else {
                throw ProjectError.invalid("Camera placements must have unique, ordered times and valid positions and sizes.")
            }
            priorTime = point.time
        }
        priorTime = -Double.infinity
        identities.removeAll()
        for point in state.zoomKeyframes {
            guard point.time.isFinite, point.time >= 0, point.time <= duration,
                  point.time > priorTime, identities.insert(point.id).inserted,
                  point.scale.isFinite, (1...3).contains(point.scale),
                  point.x.isFinite, (0...1).contains(point.x),
                  point.y.isFinite, (0...1).contains(point.y),
                  point.duration.isFinite, point.duration > 0,
                  [point.easeIn, point.easeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw ProjectError.invalid("Zoom points must have unique, ordered times and valid focal positions, scales, and durations.")
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
    @Published private(set) var references: EditorReferences
    @Published private(set) var errorMessage: String?
    @Published private(set) var draftState: EditState?
    @Published private(set) var draftTime: Double?
    @Published private(set) var recoveryRestored = false
    @Published private(set) var mediaRevision = 0
    @Published private(set) var historyNavigationTime: Double?
    @Published private(set) var historyNavigationToken: UUID?
    let url: URL
    private let defaultName: String
    private var savedProjectDigest: String?
    private var recoveryTask: Task<Void, Never>?
    private var ownsRecoveryJournal = false
    private var protectedRecoveryNotice: String?
    private static let maximumRecoveryBytes = 2 * 1024 * 1024

    private struct RecoveryJournal: Codable {
        var version = 1
        let baseSHA256: String
        let state: EditState
        let time: Double
        var references: EditorReferences? = nil
    }

    var recoveryURL: URL { url.appendingPathExtension("recovery") }

    var editingState: EditState { draftState ?? project.state }
    var canUndo: Bool { draftState != nil || !project.undoHistory.isEmpty }
    var canRedo: Bool { draftState == nil && !project.redoHistory.isEmpty }
    var undoName: String { draftState != nil ? "Edit" : project.undoHistory.last?.name ?? "" }
    var redoName: String { draftState == nil ? project.redoHistory.last?.name ?? "" : "" }
    var displayName: String { project.title ?? defaultName }
    var historyState: EditorHistoryState {
        EditorHistoryState(
            undo: (draftState == nil ? [] : ["Edit"]) + project.undoHistory.reversed().map(\.name),
            redo: draftState == nil ? project.redoHistory.reversed().map(\.name) : [])
    }

    init(project: RecordingProject, url: URL) {
        var project = project
        project.ensureReferences()
        self.project = project
        references = project.references
        self.url = url
        defaultName = RecordingProject.defaultTitle(screenFilename: project.screenFilename, projectURL: url)
    }

    deinit { recoveryTask?.cancel() }

    static func open(url: URL) throws -> ProjectEditor {
        let data = try Data(contentsOf: url)
        let project = try JSONDecoder().decode(RecordingProject.self, from: data)
        try project.validate()
        let editor = ProjectEditor(project: project, url: url)
        editor.savedProjectDigest = digest(data)
        editor.restoreRecovery()
        return editor
    }

    func mediaURL(for filename: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(filename)
    }

    func mediaRestored() { mediaRevision &+= 1 }

    /// Finger movements and controls at one source time refine a shared draft.
    /// Original media, the saved project, and its history remain untouched.
    @discardableResult
    func updateDraft(_ state: EditState, at time: Double) -> Bool {
        guard time.isFinite, (0...project.duration).contains(time) else {
            errorMessage = "The edit time must be inside the recording."
            return false
        }
        if let draftTime, draftTime != time, !finishDraft() { return false }
        do {
            var candidate = project
            candidate.state = state
            try candidate.validate()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        guard state != project.state else {
            if draftState != nil, !cancelDraft() { return false }
            errorMessage = protectedRecoveryNotice
            return true
        }
        draftTime = time
        references.register(state: state, includeCamera: project.cameraFilename != nil)
        draftState = state
        errorMessage = protectedRecoveryNotice
        scheduleRecovery()
        return true
    }

    /// Persist one combined edit only when the user leaves this source time.
    /// A failed write retains the draft and both history branches for retry.
    @discardableResult
    func finishDraft(name: String = "Edit") -> Bool {
        guard let draftState else { return true }
        var next = project
        next.undoHistory.append(NamedEditSnapshot(name: name, state: project.state, title: project.title))
        next.redoHistory.removeAll()
        next.state = draftState
        guard persist(next) else { return false }
        self.draftState = nil
        draftTime = nil
        recoveryRestored = false
        return true
    }

    @discardableResult
    func cancelDraft() -> Bool {
        guard draftState != nil else { return false }
        if let message = clearRecovery() { errorMessage = message; return false }
        draftState = nil
        draftTime = nil
        recoveryRestored = false
        errorMessage = protectedRecoveryNotice
        return true
    }

    @discardableResult
    func commit(_ state: EditState, name: String) -> Bool {
        guard finishDraft() else { return false }
        guard state != project.state else { return true }
        var next = project
        next.undoHistory.append(NamedEditSnapshot(name: name, state: project.state, title: project.title))
        next.redoHistory.removeAll()
        next.state = state
        return persist(next)
    }

    @discardableResult
    func rename(to proposedName: String) -> Bool {
        let title = proposedName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        do { try RecordingProject.validateTitle(title) }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
        guard finishDraft() else { return false }
        guard title != displayName else { errorMessage = nil; return true }
        var next = project
        next.undoHistory.append(NamedEditSnapshot(name: "Rename recording", state: project.state, title: project.title))
        next.redoHistory.removeAll()
        next.title = title
        return persist(next)
    }

    @discardableResult
    func undo(count: Int = 1) -> Bool {
        guard count > 0, count <= project.undoHistory.count + (draftState == nil ? 0 : 1) else { return false }
        var next = project
        let previous = editingState
        var remaining = count
        if let draftState {
            // The unfinished gesture is the next stack entry, just as with
            // Command-Z. A failed write retains it and both history branches.
            next.redoHistory = [NamedEditSnapshot(name: "Edit", state: draftState, title: project.title)]
            remaining -= 1
        }
        for _ in 0..<remaining {
            guard let snapshot = next.undoHistory.popLast() else { return false }
            next.redoHistory.append(NamedEditSnapshot(name: snapshot.name, state: next.state, title: next.title))
            next.state = snapshot.state
            next.title = snapshot.title
        }
        let preferredTime = draftState != nil && count == 1 ? draftTime : nil
        guard persist(next) else { return false }
        draftState = nil
        draftTime = nil
        recoveryRestored = false
        navigateHistory(from: previous, to: next.state, preferredTime: preferredTime)
        return true
    }

    @discardableResult
    func redo(count: Int = 1) -> Bool {
        guard draftState == nil, count > 0, count <= project.redoHistory.count else { return false }
        var next = project
        let previous = project.state
        for _ in 0..<count {
            guard let snapshot = next.redoHistory.popLast() else { return false }
            next.undoHistory.append(NamedEditSnapshot(name: snapshot.name, state: next.state, title: next.title))
            next.state = snapshot.state
            next.title = snapshot.title
        }
        guard persist(next) else { return false }
        navigateHistory(from: previous, to: next.state)
        return true
    }

    @discardableResult
    func save() -> Bool {
        if draftState != nil { return finishDraft() }
        return persist(project)
    }

    func dismissError() { errorMessage = nil }

    /// Coalesce samples without postponing protection throughout a long drag.
    /// There is at most one pending write and no more than four writes/second.
    private func scheduleRecovery() {
        guard recoveryTask == nil, protectedRecoveryNotice == nil else { return }
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.recoveryTask = nil
            _ = self.flushRecovery()
        }
    }

    /// Publish the most recent pending edit without changing saved history.
    /// Called explicitly before termination and by the coalesced background job.
    @discardableResult
    func flushRecovery() -> Bool {
        recoveryTask?.cancel()
        recoveryTask = nil
        guard let draftState, let draftTime else { return true }
        guard protectedRecoveryNotice == nil else { errorMessage = protectedRecoveryNotice; return false }
        do {
            try validateRecoveryTarget()
            guard let savedProjectDigest else {
                throw ProjectError.invalid("Save the recording before preserving an unfinished edit.")
            }
            if !ownsRecoveryJournal, FileManager.default.fileExists(atPath: recoveryURL.path) {
                let message = "An existing recovery file was kept at \(recoveryURL.path). It was not replaced by this edit."
                protectedRecoveryNotice = message
                throw ProjectError.invalid(message)
            }
            let journal = RecoveryJournal(baseSHA256: savedProjectDigest, state: draftState, time: draftTime,
                                          references: references)
            let data = try JSONEncoder().encode(journal)
            guard data.count <= Self.maximumRecoveryBytes else {
                throw ProjectError.invalid("The unfinished edit is too large for its recovery file. Save the recording to preserve it.")
            }
            try data.write(to: recoveryURL, options: .atomic)
            ownsRecoveryJournal = true
            return true
        } catch {
            errorMessage = "Couldn't preserve the unfinished edit. " + error.localizedDescription
            return false
        }
    }

    private func restoreRecovery() {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        do {
            try validateRecoveryTarget()
            let attributes = try FileManager.default.attributesOfItem(atPath: recoveryURL.path)
            guard let count = attributes[.size] as? NSNumber, count.intValue <= Self.maximumRecoveryBytes else {
                throw ProjectError.invalid("The recovery file is too large to restore.")
            }
            let journal = try JSONDecoder().decode(RecoveryJournal.self, from: Data(contentsOf: recoveryURL))
            guard journal.version == 1 else { throw ProjectError.invalid("The recovery file has an unsupported version.") }
            guard journal.baseSHA256 == savedProjectDigest else {
                throw ProjectError.invalid("The unfinished edit belongs to a different saved version of this recording.")
            }
            guard journal.time.isFinite, (0...project.duration).contains(journal.time) else {
                throw ProjectError.invalid("The unfinished edit has an invalid time.")
            }
            var candidate = project
            candidate.state = journal.state
            if let references = journal.references { try candidate.references.merge(references) }
            candidate.ensureReferences()
            try candidate.validate()
            ownsRecoveryJournal = true
            guard journal.state != project.state else {
                errorMessage = clearRecovery()
                return
            }
            draftTime = journal.time
            references = candidate.references
            draftState = journal.state
            recoveryRestored = true
        } catch {
            let message = "Couldn't restore an unfinished edit. " + error.localizedDescription +
                " The recovery file was kept at \(recoveryURL.path)."
            protectedRecoveryNotice = message
            errorMessage = message
        }
    }

    /// Never treat an original source or the saved project as a recovery file,
    /// even if an adjacent filename or symlink happens to collide with it.
    private func validateRecoveryTarget() throws {
        let target = recoveryURL.standardizedFileURL.resolvingSymlinksInPath()
        let originals = [url] + [project.screenFilename, project.cameraFilename, project.cursorFilename]
            .compactMap { $0 }.map { mediaURL(for: $0) }
        guard !originals.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == target }) else {
            throw ProjectError.invalid("The recovery file cannot replace original media or the saved project.")
        }
    }

    private func clearRecovery() -> String? {
        recoveryTask?.cancel()
        recoveryTask = nil
        // A stale or corrupt journal can contain unrelated work. Keep it until
        // the person explicitly decides what to do with that separate file.
        guard protectedRecoveryNotice == nil, ownsRecoveryJournal else { return nil }
        do {
            try validateRecoveryTarget()
            if FileManager.default.fileExists(atPath: recoveryURL.path) { try FileManager.default.removeItem(at: recoveryURL) }
            ownsRecoveryJournal = false
            return nil
        } catch { return "The recovery file could not be removed. " + error.localizedDescription }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func navigateHistory(from previous: EditState, to next: EditState, preferredTime: Double? = nil) {
        var times: [Double] = []
        let oldZoom = Dictionary(uniqueKeysWithValues: previous.zoomKeyframes.map { ($0.id, $0) })
        let newZoom = Dictionary(uniqueKeysWithValues: next.zoomKeyframes.map { ($0.id, $0) })
        for id in Set(oldZoom.keys).union(newZoom.keys) where oldZoom[id] != newZoom[id] {
            if let old = oldZoom[id] { times.append(old.time) }
            if let new = newZoom[id] { times.append(new.time) }
        }
        let oldCamera = Dictionary(uniqueKeysWithValues: previous.pipKeyframes.map { ($0.id, $0) })
        let newCamera = Dictionary(uniqueKeysWithValues: next.pipKeyframes.map { ($0.id, $0) })
        for id in Set(oldCamera.keys).union(newCamera.keys) where oldCamera[id] != newCamera[id] {
            if let old = oldCamera[id] { times.append(old.time) }
            if let new = newCamera[id] { times.append(new.time) }
        }
        let oldAnchors = Dictionary(uniqueKeysWithValues: previous.editAnchors.map { ($0.id, $0) })
        let newAnchors = Dictionary(uniqueKeysWithValues: next.editAnchors.map { ($0.id, $0) })
        for id in Set(oldAnchors.keys).union(newAnchors.keys) where oldAnchors[id] != newAnchors[id] {
            if let old = oldAnchors[id] { times.append(old.time) }
            if let new = newAnchors[id] { times.append(new.time) }
        }
        historyNavigationTime = preferredTime ?? times.min()
        if historyNavigationTime != nil { historyNavigationToken = UUID() }
    }

    private func persist(_ candidate: RecordingProject) -> Bool {
        var candidate = candidate
        do {
            try candidate.references.merge(references)
            candidate.ensureReferences(in: draftState)
            try candidate.validate()
            let target = url.standardizedFileURL.resolvingSymlinksInPath()
            for filename in [candidate.screenFilename, candidate.cameraFilename, candidate.cursorFilename].compactMap({ $0 }) {
                guard mediaURL(for: filename).standardizedFileURL.resolvingSymlinksInPath() != target else {
                    throw ProjectError.invalid("The project file cannot replace original media.")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(candidate)
            try data.write(to: url, options: .atomic)
            project = candidate
            references = candidate.references
            savedProjectDigest = Self.digest(data)
            errorMessage = clearRecovery() ?? protectedRecoveryNotice
            return true
        } catch {
            let message = error.localizedDescription
            if draftState != nil { _ = flushRecovery() }
            errorMessage = message
            return false
        }
    }
}
