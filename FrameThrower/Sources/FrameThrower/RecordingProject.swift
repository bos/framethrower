import Combine
import CoreGraphics
import CryptoKit
import Foundation

enum PIPTransition: String, Codable, CaseIterable, Hashable, Sendable {
    case jump
    case smooth
}

enum MotionInterpolation {
    /// Actual motion velocity relative to its peak, for timeline/inspector
    /// graphs. Time is elapsed within the effective (already clipped) span.
    /// This describes motion only; it does not change timing or audio fades.
    static func normalizedSpeed(at time: Double, duration: Double,
                                easeIn: Double? = nil, easeOut: Double? = nil) -> Double {
        guard time.isFinite, duration.isFinite, duration > 0, time >= 0, time < duration else { return 0 }
        let ramps = rampDurations(duration: duration, easeIn: easeIn, easeOut: easeOut)
        if ramps.easeIn > 0, time < ramps.easeIn {
            let sine = sin(.pi * time / ramps.easeIn / 2)
            return min(1, max(0, sine * sine))
        }
        if ramps.easeOut > 0, time > duration - ramps.easeOut {
            let elapsed = (time - (duration - ramps.easeOut)) / ramps.easeOut
            let remainingSpeed = 1 - elapsed * elapsed
            return min(1, max(0, remainingSpeed * remainingSpeed))
        }
        return 1
    }

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
        // Integrate cosine acceleration and polynomial braking around a
        // constant-speed middle. Braking retains visible late movement instead
        // of spending much of the chosen ramp imperceptibly close to arrival.
        // Normalize distance so velocity/acceleration join continuously and
        // every movement still reaches its target at the requested timestamp.
        let span = targetTime - beginning
        let ramps = rampDurations(duration: span, easeIn: easeIn, easeOut: easeOut)
        let startRamp = ramps.easeIn / span
        let endRamp = ramps.easeOut / span
        let distance = 1 - startRamp / 2 - 7 * endRamp / 15
        func accelerate(_ fraction: Double, ramp: Double) -> Double {
            (fraction / 2 - ramp / (2 * .pi) * sin(.pi * fraction / ramp)) / distance
        }
        let progress: Double
        if fraction < startRamp { progress = accelerate(fraction, ramp: startRamp) }
        else if fraction > 1 - endRamp {
            let remaining = 1 - fraction
            let ratio = remaining / endRamp
            let tail = endRamp * ratio * ratio * ratio * (4.0 / 3 - ratio + ratio * ratio / 5)
            progress = 1 - tail / distance
        } else { progress = (fraction - startRamp / 2) / distance }
        return min(1, max(0, progress))
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
    /// Optional rectangle in the full, oriented source. Nil preserves legacy framing.
    var sourceCrop: EditorRegionRect? = nil
    /// nil/0 retains normal overlay geometry; 1 fills the final output canvas.
    /// Normal placement/shape remain intact so returning to zero restores them.
    var fullscreen: Double? = nil
    var opacity: Double = 1
    var renderedOpacity: Double { visible && opacity.isFinite ? min(1, max(0, opacity)) : 0 }

    init(x: Double = 0.95, y: Double = 0.95, scale: Double = 0.25, visible: Bool = true,
         shape: PIPShape = .original, aspectRatio: Double = 16.0 / 9.0, crop: PIPCrop = PIPCrop(), sourceZoom: Double = 1, sourceCrop: EditorRegionRect? = nil, fullscreen: Double? = nil, opacity: Double = 1) {
        self.x = x
        self.y = y
        self.scale = scale
        self.visible = visible
        self.shape = shape
        self.aspectRatio = aspectRatio
        self.crop = crop
        self.sourceZoom = sourceZoom
        self.sourceCrop = sourceCrop
        self.fullscreen = fullscreen
        self.opacity = opacity
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, scale, visible, shape, aspectRatio, crop, sourceZoom, sourceCrop, fullscreen, opacity
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
        sourceCrop = try values.decodeIfPresent(EditorRegionRect.self, forKey: .sourceCrop)
        fullscreen = try values.decodeIfPresent(Double.self, forKey: .fullscreen)
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(x, forKey: .x); try values.encode(y, forKey: .y)
        try values.encode(scale, forKey: .scale); try values.encode(visible, forKey: .visible)
        try values.encode(shape, forKey: .shape); try values.encode(aspectRatio, forKey: .aspectRatio)
        try values.encode(crop, forKey: .crop); try values.encode(sourceZoom, forKey: .sourceZoom)
        try values.encodeIfPresent(sourceCrop, forKey: .sourceCrop)
        try values.encodeIfPresent(fullscreen, forKey: .fullscreen)
        try values.encode(opacity, forKey: .opacity)
    }

    var fullscreenFraction: Double {
        guard let fullscreen, fullscreen.isFinite else { return 0 }
        return min(1, max(0, fullscreen))
    }

    func frame(in canvas: CGSize, cameraAspect: Double) -> CGRect {
        guard canvas.width.isFinite, canvas.height.isFinite,
              canvas.width > 0, canvas.height > 0 else { return .zero }
        let originalAspect = cameraAspect.isFinite && cameraAspect > 0 ? cameraAspect : 16.0 / 9.0
        let aspect: Double
        switch shape {
        case .original: aspect = originalAspect * (sourceCrop.map { $0.width / $0.height } ?? 1)
        case .square, .circle: aspect = 1
        case .rectangle: aspect = aspectRatio.isFinite && aspectRatio > 0 ? (sourceCrop == nil ? min(5, max(0.2, aspectRatio)) : aspectRatio) : 16.0 / 9.0
        }
        let scaleFraction = scale.isFinite ? min(0.5, max(0.12, scale)) : 0.25
        let width = min(canvas.width * scaleFraction, canvas.height * 0.8 * aspect)
        let height = width / aspect
        let horizontal = x.isFinite ? min(1, max(0, x)) : 0.95
        let vertical = y.isFinite ? min(1, max(0, y)) : 0.95
        let normal = ViewportGeometry.rect(in: canvas, size: CGSize(width: width, height: height),
                                           travelAnchor: CGPoint(x: horizontal, y: vertical))
        let fraction = fullscreenFraction
        guard fraction > 0 else { return normal }
        if fraction == 1 { return CGRect(origin: .zero, size: canvas) }
        return CGRect(x: normal.minX * (1 - fraction), y: normal.minY * (1 - fraction),
            width: MotionInterpolation.blend(normal.width, canvas.width, progress: fraction),
            height: MotionInterpolation.blend(normal.height, canvas.height, progress: fraction))
    }

    /// Aspect-fill the actual interpolated outline, without stretching the
    /// camera image. Crop focus/source zoom remain independent of overlay size.
    func sourceViewport(in source: CGSize, canvas: CGSize) -> CGRect {
        if let sourceCrop {
            let base = CropGeometry.pixels(sourceCrop, in: source)
            let output = frame(in: canvas, cameraAspect: source.width / max(1, source.height))
            let local = crop.rect(in: base.size, shape: fullscreenFraction > 0 ? .rectangle : shape,
                aspectRatio: fullscreenFraction > 0 ? output.width / max(0.000001, output.height) : aspectRatio,
                zoom: sourceZoom)
            return local.offsetBy(dx: base.minX, dy: base.minY)
        }
        guard fullscreenFraction > 0 else {
            return crop.rect(in: source, shape: shape, aspectRatio: aspectRatio, zoom: sourceZoom)
        }
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else { return .zero }
        let output = frame(in: canvas, cameraAspect: source.width / source.height)
        guard output.width > 0, output.height > 0 else { return .zero }
        return crop.rect(in: source, shape: .rectangle, aspectRatio: output.width / output.height, zoom: sourceZoom)
    }

    /// Supply the resolved frame.size, not the entire output canvas.
    func cornerRadius(in frameSize: CGSize) -> Double {
        guard frameSize.width.isFinite, frameSize.height.isFinite, frameSize.width > 0, frameSize.height > 0 else { return 0 }
        return shape == .circle ? min(frameSize.width, frameSize.height) / 2 * (1 - fullscreenFraction) : 0
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
            next.aspectRatio = sourceCrop == nil ? min(5, max(0.2, proposedWidth / proposedHeight)) : proposedWidth / proposedHeight
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

/// Camera alpha owns its source clock independently of placement keyframes.
struct CameraOpacityKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var time: Double
    var opacity: Double
    var transition: PIPTransition = .jump
    var duration: Double = 0.4
    var easeIn: Double? = nil
    var easeOut: Double? = nil
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
    /// The guide explicitly used as this screen target. This is independent
    /// of the guide's drawn-at edit anchor and survives timing/ramp changes.
    var sourceRegionID: UUID? = nil

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

struct CanvasResolution: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var size: CGSize { CGSize(width: width, height: height) }
    var isValid: Bool { (2...8192).contains(width) && (2...8192).contains(height) && width % 2 == 0 && height % 2 == 0 }

    static func matching(aspect: Double, shortEdge: Double) -> Self {
        let ratio = aspect.isFinite && aspect > 0 ? aspect : 1
        let source = CGSize(width: ratio >= 1 ? shortEdge * ratio : shortEdge,
                            height: ratio >= 1 ? shortEdge : shortEdge / ratio)
        return native(source)
    }

    static func native(_ source: CGSize) -> Self {
        let longest = max(source.width, source.height), shortest = min(source.width, source.height)
        guard longest.isFinite, shortest.isFinite, shortest > 0 else { return Self(width: 2, height: 2) }
        let scale = min(8192 / longest, max(1, 2 / shortest))
        func even(_ value: Double) -> Int { min(8192, max(2, Int((value / 2).rounded()) * 2)) }
        return Self(width: even(source.width * scale), height: even(source.height * scale))
    }
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
    /// Whole-recording crop, in normalized oriented main-source coordinates.
    var sourceCrop: EditorRegionRect? = nil
    var outputResolution: CanvasResolution? = nil

    func viewport(in source: CGSize, zoom: ZoomPlacement = ZoomPlacement()) -> CGRect {
        let base = CropGeometry.pixels(sourceCrop ?? CropGeometry.full, in: source)
        return zoom.viewport(in: base.size).offsetBy(dx: base.minX, dy: base.minY)
    }
}

/// The common top-left coordinate mapping for rendering and native gestures.
/// The selected source crop fits in full; aspect choices never stretch it.
struct PresentationGeometry: Equatable, Sendable {
    let outputSize: CGSize
    let contentRect: CGRect
    let cornerRadius: CGFloat

    init(sourceSize: CGSize, presentation: CanvasPresentation) {
        let original = CGSize(width: sourceSize.width.isFinite && sourceSize.width > 0 ? sourceSize.width : 16,
                            height: sourceSize.height.isFinite && sourceSize.height > 0 ? sourceSize.height : 9)
        let source = CropGeometry.pixels(presentation.sourceCrop ?? CropGeometry.full, in: original).size
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded() * 2) }
        let edge = max(source.width, source.height)
        if let resolution = presentation.outputResolution {
            let short = Double(min(resolution.width, resolution.height))
            switch presentation.aspect {
            case .source: outputSize = resolution.size
            case .wide: outputSize = CanvasResolution.matching(aspect: 16.0 / 9, shortEdge: short).size
            case .portrait: outputSize = CanvasResolution.matching(aspect: 9.0 / 16, shortEdge: short).size
            case .square: outputSize = CanvasResolution.matching(aspect: 1, shortEdge: short).size
            }
        } else {
            switch presentation.aspect {
            case .source: outputSize = CGSize(width: even(source.width), height: even(source.height))
            case .wide: outputSize = CGSize(width: even(edge), height: even(edge * 9 / 16))
            case .portrait: outputSize = CGSize(width: even(edge * 9 / 16), height: even(edge))
            case .square: outputSize = CGSize(width: even(edge), height: even(edge))
            }
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

/// Master controls apply to every original audio track, retaining their source
/// offsets and relative levels. Requested fades survive later trim changes.
enum RecordingAudioRole: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone, systemAudio
    var title: String { self == .microphone ? "Microphone" : "System audio" }
    var metadataIdentifier: String { "mdta/com.framethrower.audio.role" }
}

/// Explicit capture-written identity; track order never establishes a role.
struct RecordingAudioSource: Codable, Equatable, Sendable {
    var role: RecordingAudioRole
    var identifier: String
    init(role: RecordingAudioRole) { self.role = role; identifier = role.metadataIdentifier }
    static func resolve(identifier: String?, value: String?, bindings: [RecordingAudioSource]) -> RecordingAudioRole? {
        let matches = bindings.filter { $0.identifier == identifier && $0.role.rawValue == value }
        return matches.count == 1 ? matches[0].role : nil
    }
}
struct RecordingAudioGainPoint: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var time: Double
    var gain: Double
    var transition: PIPTransition = .smooth
    var duration: Double = 0.4
    var easeIn: Double? = nil
    var easeOut: Double? = nil
}
struct RecordingAudioChannel: Codable, Equatable, Sendable {
    var role: RecordingAudioRole
    var isMuted = false
    var volume = 1.0
    var points: [RecordingAudioGainPoint] = []

    func envelopeGain(at time: Double) -> Double {
        var gain = 1.0, previous = 0.0
        for point in points {
            if time >= point.time { gain = point.gain; previous = point.time; continue }
            if point.transition == .smooth {
                let progress = MotionInterpolation.progress(at: time, from: previous, to: point.time,
                    duration: point.duration, transition: .smooth, easeIn: point.easeIn, easeOut: point.easeOut)
                return gain + (point.gain - gain) * progress
            }
            return gain
        }
        return gain
    }
    func gain(at time: Double) -> Double { isMuted ? 0 : volume * envelopeGain(at: time) }
    func validate(duration: Double) throws {
        guard volume.isFinite, (0...1).contains(volume), points.count <= 4096,
              Set(points.map(\.id)).count == points.count else { throw ProjectError.invalid("Audio levels must be 0–100%, with unique volume-change identities.") }
        var previous = -Double.infinity
        for point in points {
            guard point.time.isFinite, point.time >= 0, point.time <= duration, point.time > previous,
                  point.gain.isFinite, (0...1).contains(point.gain), point.duration.isFinite, point.duration > 0,
                  [point.easeIn, point.easeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw ProjectError.invalid("Volume changes need ordered source times, finite ramps and gains of 0–100%.")
            }
            previous = point.time
        }
    }
}

struct RecordingAudio: Codable, Equatable, Sendable {
    var isMuted = false
    var volume = 1.0
    var fadeIn = 0.0
    var fadeOut = 0.0
    var channels: [RecordingAudioChannel] = []
    private enum CodingKeys: String, CodingKey { case isMuted, volume, fadeIn, fadeOut, channels }
    init(isMuted: Bool = false, volume: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0,
         channels: [RecordingAudioChannel] = []) {
        self.isMuted = isMuted; self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.channels = channels
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        channels = try c.decodeIfPresent([RecordingAudioChannel].self, forKey: .channels) ?? []
    }
    func gain(role: RecordingAudioRole?, sourceTime: Double, outputTime: Double, outputDuration: Double) -> Double {
        guard outputDuration > 0, outputTime >= 0, outputTime <= outputDuration else { return 0 }
        let fades = effectiveFades(duration: outputDuration)
        var gain = isMuted ? 0 : volume
        if fades.fadeIn > 0 { gain *= min(1, max(0, outputTime / fades.fadeIn)) }
        if fades.fadeOut > 0 { gain *= min(1, max(0, (outputDuration - outputTime) / fades.fadeOut)) }
        if let role { gain *= channel(role).gain(at: sourceTime) }
        return gain
    }
    func channel(_ role: RecordingAudioRole) -> RecordingAudioChannel { channels.first { $0.role == role } ?? .init(role: role) }
    mutating func updateChannel(_ role: RecordingAudioRole, _ change: (inout RecordingAudioChannel) -> Void) {
        var value = channel(role); change(&value)
        channels.removeAll { $0.role == role }; channels.append(value)
        channels.sort { $0.role.rawValue < $1.role.rawValue }
    }

    static let maximumFade = 5.0

    func validate() throws {
        guard volume.isFinite, (0...1).contains(volume),
              [fadeIn, fadeOut].allSatisfy({ $0.isFinite && (0...Self.maximumFade).contains($0) }) else {
            throw ProjectError.invalid("Audio volume must be between 0 and 100%, and fades between 0 and 5 seconds.")
        }
    }

    /// Fades shrink together when a trim leaves less room than requested.
    /// Keeping this calculation separate from metadata avoids destructive edits
    /// when a user shortens a trim and then restores it.
    func effectiveFades(duration: Double) -> (fadeIn: Double, fadeOut: Double) {
        let ramps = MotionInterpolation.rampDurations(duration: duration, easeIn: fadeIn, easeOut: fadeOut)
        return (ramps.easeIn, ramps.easeOut)
    }

    struct Point: Equatable, Sendable {
        var time: Double
        var volume: Double
    }

    /// Adaptive linear projection for AV gain ramps. Quarter samples avoid
    /// missing symmetric S-curves; duplicate-time points retain exact jumps.
    static func sampledEnvelope(knots: [Double], gain: (Double) -> Double) -> [Point] {
        let times = Set(knots.filter(\.isFinite)).sorted()
        guard let first = times.first else { return [] }
        var result = [Point(time: first, volume: gain(first))]
        func append(_ a: Double, _ b: Double, _ ga: Double, _ gb: Double, depth: Int) {
            let middle = a + (b - a) / 2, gm = gain(middle)
            var error = 0.0
            for fraction: Double in [0.25, 0.5, 0.75] {
                let time = a + (b - a) * fraction
                let linear = ga + (gb - ga) * fraction
                error = max(error, abs(gain(time) - linear))
            }
            if error > 0.00005 && depth < 18 && middle > a && middle < b {
                append(a, middle, ga, gm, depth: depth + 1); append(middle, b, gm, gb, depth: depth + 1)
            } else { result.append(Point(time: b, volume: gb)) }
        }
        for (a, b) in zip(times, times.dropFirst()) {
            append(a, b, gain(a), gain(max(a, b.nextDown)), depth: 0)
            let actual = gain(b)
            if actual != result.last!.volume { result.append(Point(time: b, volume: actual)) }
        }
        return result
    }
    func sourceKnots(role: RecordingAudioRole?) -> [Double] {
        guard let role else { return [] }
        var previous = 0.0, result: [Double] = []
        for point in channel(role).points {
            let start = point.transition == .smooth ? max(previous, point.time - point.duration) : point.time
            let ramps = MotionInterpolation.rampDurations(duration: point.time - start, easeIn: point.easeIn, easeOut: point.easeOut)
            result += [start, start + ramps.easeIn, point.time - ramps.easeOut, point.time]
            previous = point.time
        }
        return result
    }
    /// Linear gain points in source seconds, shared by playback and export.
    func envelope(trimStart: Double, trimEnd: Double) -> [Point] {
        guard trimStart.isFinite, trimEnd.isFinite, trimStart >= 0, trimEnd > trimStart else { return [] }
        let level = isMuted ? 0 : (volume.isFinite ? min(1, max(0, volume)) : 1)
        let fades = effectiveFades(duration: trimEnd - trimStart)
        var points = [Point(time: trimStart, volume: fades.fadeIn > 0 ? 0 : level)]
        if fades.fadeIn > 0 { points.append(Point(time: trimStart + fades.fadeIn, volume: level)) }
        let outgoing = trimEnd - fades.fadeOut
        if outgoing > points.last!.time { points.append(Point(time: outgoing, volume: level)) }
        if trimEnd > points.last!.time { points.append(Point(time: trimEnd, volume: fades.fadeOut > 0 ? 0 : level)) }
        return points
    }
}

/// An excluded half-open interval in original source seconds. The requested
/// crossfade is in output seconds and is never rewritten by trimming.
struct RecordingCut: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double
    var crossfade: Double

    init(id: UUID = UUID(), start: Double, end: Double, crossfade: Double = 0) {
        self.id = id; self.start = start; self.end = end; self.crossfade = crossfade
    }
    private enum CodingKeys: String, CodingKey { case id, start, end, crossfade }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        crossfade = try values.decodeIfPresent(Double.self, forKey: .crossfade) ?? 0
    }
}

/// A final-recording playback rate, arriving at an original-source timestamp.
/// It is independent of the editor's temporary review speed.
struct RecordingSpeedKeyframe: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var time: Double
    var rate: Double
    var transition: PIPTransition = .smooth
    var duration = 0.4
    var easeIn: Double? = nil
    var easeOut: Double? = nil

    init(id: UUID = UUID(), time: Double, rate: Double, transition: PIPTransition = .smooth,
         duration: Double = 0.4, easeIn: Double? = nil, easeOut: Double? = nil) {
        self.id = id; self.time = time; self.rate = rate; self.transition = transition
        self.duration = duration; self.easeIn = easeIn; self.easeOut = easeOut
    }
}

enum RecordingRetime {
    static let supportedRates = 0.1...8.0
    /// A tenth of a millisecond of output-clock curvature per linear cell.
    /// Preview, inverse queries, video and every audio track share these cells.
    static let maximumOutputError = 0.0001

    struct Segment: Equatable, Sendable {
        let sourceStart: Double
        let sourceEnd: Double
        let outputStart: Double
        let outputEnd: Double
        var rate: Double { (sourceEnd - sourceStart) / (outputEnd - outputStart) }
        func sourceTime(at outputTime: Double) -> Double {
            sourceStart + min(1, max(0, (outputTime - outputStart) / (outputEnd - outputStart))) * (sourceEnd - sourceStart)
        }
        func outputTime(for sourceTime: Double) -> Double {
            outputStart + min(1, max(0, (sourceTime - sourceStart) / (sourceEnd - sourceStart))) * (outputEnd - outputStart)
        }
        func shifted(by offset: Double) -> Self {
            .init(sourceStart: sourceStart, sourceEnd: sourceEnd, outputStart: outputStart + offset, outputEnd: outputEnd + offset)
        }
    }

    static func validate(points: [RecordingSpeedKeyframe], duration: Double) throws {
        var ids = Set<UUID>(), previous = -Double.infinity
        for point in points {
            guard point.time.isFinite, point.time >= 0, point.time <= duration, point.time > previous,
                  ids.insert(point.id).inserted, point.rate.isFinite, supportedRates.contains(point.rate),
                  point.duration.isFinite, point.duration > 0,
                  [point.easeIn, point.easeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw ProjectError.invalid("Speed changes need unique, ordered source times, rates from 0.1× to 8×, and valid ramp durations.")
            }
            previous = point.time
        }
    }

    static func rate(at time: Double, points: [RecordingSpeedKeyframe]) -> Double {
        guard time.isFinite, time >= 0 else { return 1 }
        var low = 0, high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        let previousRate = low > 0 ? points[low - 1].rate : 1
        let previousTime = low > 0 ? points[low - 1].time : 0
        guard low < points.count else { return previousRate }
        let point = points[low]
        return MotionInterpolation.blend(previousRate, point.rate,
            progress: MotionInterpolation.progress(at: time, from: previousTime, to: point.time,
                duration: point.duration, transition: point.transition, easeIn: point.easeIn, easeOut: point.easeOut))
    }

    /// Integrate ds/rate(s), splitting at every discontinuity and ramp boundary.
    /// Adaptive Simpson quadrature also checks clock curvature; a duration-only
    /// error test would miss a symmetric acceleration/deceleration interval.
    static func segments(start: Double, end: Double, points: [RecordingSpeedKeyframe]) throws -> [Segment] {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return [] }
        var knots = [start, end], previousTime = 0.0
        for point in points {
            knots.append(point.time)
            if point.transition == .smooth {
                let beginning = max(previousTime, point.time - point.duration)
                let ramps = MotionInterpolation.rampDurations(duration: point.time - beginning, easeIn: point.easeIn, easeOut: point.easeOut)
                knots += [beginning, beginning + ramps.easeIn, point.time - ramps.easeOut]
            }
            previousTime = point.time
        }
        knots = Set(knots.filter { $0 >= start && $0 <= end }).sorted()
        var result: [Segment] = [], output = 0.0
        func append(_ a: Double, _ b: Double, _ elapsed: Double) throws {
            guard elapsed.isFinite, elapsed > 0, output + elapsed > output, result.count < 100_000 else {
                throw ProjectError.invalid("This speed curve could not be represented accurately. Shorten the speed ramp or simplify its changes.")
            }
            result.append(.init(sourceStart: a, sourceEnd: b, outputStart: output, outputEnd: output + elapsed))
            output += elapsed
        }
        for (a, b) in zip(knots, knots.dropFirst()) {
            // At a hard speed change the preceding cell must use the left limit.
            func f(_ t: Double) -> Double { 1 / rate(at: t == b ? b.nextDown : t, points: points) }
            func refine(_ left: Double, _ right: Double, _ fl: Double, _ fm: Double, _ fr: Double,
                        _ whole: Double, _ depth: Int) throws {
                if fl == fm && fm == fr {
                    try append(left, right, (right - left) * fm)
                    return
                }
                let mid = left + (right - left) / 2
                let q1 = f(left + (mid - left) / 2), q3 = f(mid + (right - mid) / 2)
                let first = (mid - left) / 6 * (fl + 4 * q1 + fm)
                let second = (right - mid) / 6 * (fm + 4 * q3 + fr)
                let total = first + second
                let curvature = abs(first - total / 2)
                let integralError = abs(total - whole) / 15
                if curvature <= maximumOutputError && integralError <= 1e-10 * max(1, total) {
                    try append(left, right, total + (total - whole) / 15)
                } else {
                    guard depth < 24, mid > left, mid < right else {
                        throw ProjectError.invalid("This speed ramp is too short or too long to represent accurately.")
                    }
                    try refine(left, mid, fl, q1, fm, first, depth + 1)
                    try refine(mid, right, fm, q3, fr, second, depth + 1)
                }
            }
            let middle = a + (b - a) / 2, fa = f(a), fm = f(middle), fb = f(b)
            try refine(a, b, fa, fm, fb, (b - a) / 6 * (fa + 4 * fm + fb), 0)
        }
        return result
    }
}

/// Pure source/output timing. Source edits and observations retain their original
/// timestamps; a transition evaluates two independently composed source moments.
struct RecordingTimeMap: Equatable, Sendable {
    struct Clip: Equatable, Sendable {
        let sourceStart: Double
        let sourceEnd: Double
        let outputStart: Double
        let outputEnd: Double
        let segments: [RecordingRetime.Segment]

        func sourceTime(at outputTime: Double) -> Double {
            var low = 0, high = segments.count
            while low < high {
                let mid = (low + high) / 2
                if segments[mid].outputEnd <= outputTime { low = mid + 1 } else { high = mid }
            }
            guard !segments.isEmpty else { return sourceStart }
            let cell = segments[min(low, segments.count - 1)]
            return cell.sourceTime(at: outputTime)
        }
        func outputTime(for sourceTime: Double) -> Double {
            var low = 0, high = segments.count
            while low < high {
                let mid = (low + high) / 2
                if segments[mid].sourceEnd <= sourceTime { low = mid + 1 } else { high = mid }
            }
            guard !segments.isEmpty else { return outputStart }
            let cell = segments[min(low, segments.count - 1)]
            return cell.outputTime(for: sourceTime)
        }
    }
    struct Join: Equatable, Sendable, Identifiable {
        let id: UUID
        let outputStart: Double
        let outputEnd: Double
        let duration: Double
        let requestedDuration: Double
        let outgoingClipIndex: Int
        let incomingClipIndex: Int
    }
    struct Sample: Equatable, Sendable {
        let clipIndex: Int
        let sourceTime: Double
        let weight: Double
    }
    let clips: [Clip]
    let joins: [Join]
    let outputDuration: Double

    init(duration: Double, trimStart: Double, trimEnd: Double, cuts: [RecordingCut],
         speedKeyframes: [RecordingSpeedKeyframe] = []) throws {
        guard duration.isFinite, duration > 0, trimStart.isFinite, trimEnd.isFinite,
              trimStart >= 0, trimEnd <= duration, trimStart < trimEnd else {
            throw ProjectError.invalid("Keep a nonempty trim range inside the original recording.")
        }
        try RecordingRetime.validate(points: speedKeyframes, duration: duration)
        let ordered = cuts.sorted { $0.start < $1.start }
        var identities = Set<UUID>()
        var priorEnd: Double?
        for cut in ordered {
            guard cut.start.isFinite, cut.end.isFinite, cut.crossfade.isFinite,
                  cut.start >= 0, cut.end <= duration, cut.start < cut.end, cut.crossfade >= 0,
                  identities.insert(cut.id).inserted else {
                throw ProjectError.invalid("Cuts need unique identities, a nonempty source range inside the recording, and a finite nonnegative crossfade.")
            }
            if let priorEnd, cut.start <= priorEnd {
                throw ProjectError.invalid("Combine touching or overlapping cuts into one excluded range.")
            }
            priorEnd = cut.end
        }
        var ranges: [(start: Double, end: Double)] = []
        var position = trimStart
        for cut in ordered where cut.end > trimStart && cut.start < trimEnd {
            let start = max(trimStart, cut.start), end = min(trimEnd, cut.end)
            if start > position { ranges.append((position, start)) }
            position = end
        }
        if position < trimEnd { ranges.append((position, trimEnd)) }
        guard !ranges.isEmpty else { throw ProjectError.invalid("Cuts must leave some footage inside the trim range.") }
        let byStart = Dictionary(uniqueKeysWithValues: ordered.map { ($0.start, $0) })
        let boundaries: [RecordingCut] = try ranges.dropLast().map { range in
            guard let cut = byStart[range.end] else { throw ProjectError.invalid("A cut boundary could not be resolved.") }
            return cut
        }
        let cells = try ranges.map { try RecordingRetime.segments(start: $0.start, end: $0.end, points: speedKeyframes) }
        let lengths = cells.map { $0.last!.outputEnd }
        let effective = Self.effectiveFades(requested: boundaries.map(\.crossfade), lengths: lengths)
        var mapped: [Clip] = []
        var mappedJoins: [Join] = []
        for (index, range) in ranges.enumerated() {
            let start = index == 0 ? 0 : mapped[index - 1].outputEnd - effective[index - 1]
            mapped.append(Clip(sourceStart: range.start, sourceEnd: range.end,
                               outputStart: start, outputEnd: start + lengths[index],
                               segments: cells[index].map { $0.shifted(by: start) }))
            if index > 0 {
                let cut = boundaries[index - 1], fade = effective[index - 1]
                mappedJoins.append(Join(id: cut.id, outputStart: start, outputEnd: start + fade,
                    duration: fade, requestedDuration: cut.crossfade,
                    outgoingClipIndex: index - 1, incomingClipIndex: index))
            }
        }
        clips = mapped; joins = mappedJoins; outputDuration = mapped.last!.outputEnd
    }

    private struct FadeEvent {
        let level: Double
        let clip: Int
        let version: Int
    }
    private struct FadeHeap {
        private var events: [FadeEvent] = []
        private func precedes(_ a: FadeEvent, _ b: FadeEvent) -> Bool {
            a.level < b.level || (a.level == b.level && a.clip < b.clip)
        }
        mutating func push(_ event: FadeEvent) {
            events.append(event)
            var index = events.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard precedes(events[index], events[parent]) else { break }
                events.swapAt(index, parent); index = parent
            }
        }
        mutating func pop() -> FadeEvent? {
            guard let first = events.first, let last = events.popLast() else { return nil }
            guard !events.isEmpty else { return first }
            events[0] = last
            var index = 0
            while index * 2 + 1 < events.count {
                var child = index * 2 + 1
                if child + 1 < events.count && precedes(events[child + 1], events[child]) { child += 1 }
                guard precedes(events[child], events[index]) else { break }
                events.swapAt(index, child); index = child
            }
            return first
        }
    }

    /// Max-min proportional allocation in O(n log n). Active fades grow as
    /// weight*level; a saturated clip freezes its incident fades. Versioned heap
    /// events avoid rescanning every clip after each exhausted handle budget.
    private static func effectiveFades(requested: [Double], lengths: [Double]) -> [Double] {
        guard let largest = requested.max(), largest > 0 else { return requested }
        let weights = requested.map { $0 / largest }
        var values = Array(repeating: 0.0, count: requested.count)
        var active = weights.map { $0 > 0 }
        var fixed = Array(repeating: 0.0, count: lengths.count)
        var slopes = lengths.indices.map { clip in
            [clip - 1, clip].filter { weights.indices.contains($0) }.reduce(0.0) { $0 + weights[$1] }
        }
        var versions = Array(repeating: 0, count: lengths.count)
        var heap = FadeHeap()
        for clip in lengths.indices where slopes[clip] > 0 {
            heap.push(FadeEvent(level: min(largest, lengths[clip] / slopes[clip]), clip: clip, version: 0))
        }
        var level = 0.0
        while let event = heap.pop() {
            guard event.version == versions[event.clip], slopes[event.clip] > 0 else { continue }
            level = max(level, min(largest, event.level))
            if level >= largest {
                for edge in requested.indices where active[edge] { values[edge] = requested[edge] }
                break
            }
            let edges = [event.clip - 1, event.clip].filter { active.indices.contains($0) && active[$0] }
            for edge in edges {
                active[edge] = false
                values[edge] = min(requested[edge], weights[edge] * level)
                for clip in [edge, edge + 1] {
                    let incident = [clip - 1, clip].filter { active.indices.contains($0) }
                    fixed[clip] = incident.filter { !active[$0] }.reduce(0.0) { $0 + values[$1] }
                    slopes[clip] = incident.filter { active[$0] }.reduce(0.0) { $0 + weights[$1] }
                    versions[clip] += 1
                    if slopes[clip] > 0 {
                        let next = max(level, min(largest, max(0, lengths[clip] - fixed[clip]) / slopes[clip]))
                        heap.push(FadeEvent(level: next, clip: clip, version: versions[clip]))
                    }
                }
            }
        }
        // Floating-point addition at a saturated shared boundary can overshoot
        // by an ulp. A conservative proportional correction only decreases fades.
        for clip in lengths.indices {
            let edges = [clip - 1, clip].filter { values.indices.contains($0) }
            let left = edges.first.map { values[$0] } ?? 0
            let right = edges.count == 2 ? values[edges[1]] : 0
            if left > lengths[clip] - right {
                let factor = (1 / (left / lengths[clip] + right / lengths[clip])).nextDown
                for edge in edges { values[edge] *= max(0, factor) }
            }
        }
        return values
    }

    /// Half-open output samples, with an explicit final endpoint for inspection.
    /// Invisible zero-weight branches are omitted; positive weights sum to one.
    func samples(at outputTime: Double) -> [Sample] {
        guard outputTime.isFinite, outputTime >= 0, outputTime <= outputDuration else { return [] }
        if outputTime == outputDuration, let last = clips.last {
            return [Sample(clipIndex: clips.count - 1, sourceTime: last.sourceEnd, weight: 1)]
        }
        var result: [Sample] = []
        for (index, clip) in clips.enumerated() where outputTime >= clip.outputStart && outputTime < clip.outputEnd {
            var weight = 1.0
            if index > 0 {
                let join = joins[index - 1]
                if join.duration > 0 && outputTime < join.outputEnd {
                    weight = min(1, max(0, (outputTime - join.outputStart) / join.duration))
                }
            }
            if index < joins.count {
                let join = joins[index]
                if join.duration > 0 && outputTime >= join.outputStart {
                    weight = min(weight, max(0, (join.outputEnd - outputTime) / join.duration))
                }
            }
            if weight > 0 {
                result.append(Sample(clipIndex: index,
                    sourceTime: clip.sourceTime(at: outputTime), weight: weight))
            }
        }
        let sum = result.reduce(0.0) { $0 + $1.weight }
        guard sum > 0 else { return [] }
        return result.map { Sample(clipIndex: $0.clipIndex, sourceTime: $0.sourceTime, weight: $0.weight / sum) }
    }

    /// Excluded source instants have no output position. During a crossfade two
    /// distinct retained source instants intentionally map to the same output time.
    func outputTime(for sourceTime: Double) -> Double? {
        guard sourceTime.isFinite else { return nil }
        if sourceTime == clips.last?.sourceEnd { return outputDuration }
        guard let clip = clips.first(where: { sourceTime >= $0.sourceStart && sourceTime < $0.sourceEnd }) else { return nil }
        return clip.outputTime(for: sourceTime)
    }
}

// Immutable source descriptors are kept outside history; clips are occurrences.
enum VideoSourceRole: String, Codable, CaseIterable, Sendable { case screen, camera, footage }
enum VideoSourceKind: String, Codable, CaseIterable, Sendable { case file, testPattern }
enum VideoClipLayout: String, Codable, CaseIterable, Sendable { case screen, camera, custom }
enum VideoFit: String, Codable, CaseIterable, Sendable { case fit, fill }
enum VideoClipTransition: String, Codable, CaseIterable, Sendable { case cut, crossfade }

struct VideoSource: Codable, Equatable, Identifiable, Sendable {
    static let legacyScreenID = UUID(uuidString: "56494445-4F00-4000-8000-000000000001")!
    static let legacyCameraID = UUID(uuidString: "56494445-4F00-4000-8000-000000000002")!
    var id: UUID = UUID()
    var name: String
    var role: VideoSourceRole = .footage
    var kind: VideoSourceKind
    var relativePath: String? = nil
    var duration: Double? = nil
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var hasAudio: Bool? = nil
    var patternSeed: Int = 0

    var pixelSize: CGSize? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return CGSize(width: pixelWidth, height: pixelHeight)
    }
    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
        !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    func resolvedURL(in directory: URL) throws -> URL {
        guard kind == .file, let relativePath, Self.isSafeRelativePath(relativePath) else {
            throw ProjectError.invalid("This video source has no safe relative file path.")
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var target = root
        // Foundation may leave a missing leaf unresolved even when its parent
        // is a symlink. Resolve each existing ancestor before appending a leaf.
        for component in relativePath.split(separator: "/") {
            target = target.appendingPathComponent(String(component)).standardizedFileURL.resolvingSymlinksInPath()
            guard target.path.hasPrefix(prefix) else {
                throw ProjectError.invalid("A video source cannot follow a symbolic link outside the project folder.")
            }
        }
        return target
    }
    func validate(isExtra: Bool = true) throws {
        try RecordingProject.validateTitle(name)
        guard duration.map({ $0.isFinite && $0 > 0 }) ?? (!isExtra && role == .camera),
              (pixelWidth == nil) == (pixelHeight == nil),
              pixelWidth.map({ (1...131_072).contains($0) }) ?? true,
              pixelHeight.map({ (1...131_072).contains($0) }) ?? true else {
            throw ProjectError.invalid("A video source needs a positive duration and paired positive pixel dimensions.")
        }
        if isExtra, hasAudio == nil { throw ProjectError.invalid("Registered video sources need explicit audio availability.") }
        if isExtra, role != .footage { throw ProjectError.invalid("Imported video sources use the footage role.") }
        switch kind {
        case .file:
            guard let relativePath, Self.isSafeRelativePath(relativePath) else {
                throw ProjectError.invalid("Video source paths must be relative and cannot contain traversal or control characters.")
            }
        case .testPattern:
            guard relativePath == nil, pixelSize != nil, hasAudio == false else {
                throw ProjectError.invalid("Test patterns need dimensions and must not refer to a file or audio.")
            }
        }
    }
}

struct VideoGeometry: Codable, Equatable, Sendable {
    static let fullRect = EditorRegionRect(x: 0, y: 0, width: 1, height: 1)
    var rect: EditorRegionRect = fullRect
    var crop: EditorRegionRect = fullRect
    var fit: VideoFit = .fit

    func sourceRect(in size: CGSize) -> CGRect {
        CGRect(x: crop.x * size.width, y: crop.y * size.height,
               width: crop.width * size.width, height: crop.height * size.height)
    }
    func frame(in canvas: CGSize, sourceSize: CGSize) -> CGRect {
        let target = CGRect(x: rect.x * canvas.width, y: rect.y * canvas.height,
                            width: rect.width * canvas.width, height: rect.height * canvas.height)
        let source = sourceRect(in: sourceSize)
        guard fit == .fit, source.width > 0, source.height > 0 else { return target }
        let scale = min(target.width / source.width, target.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    func viewport(in sourceSize: CGSize, canvas: CGSize) -> CGRect {
        let source = sourceRect(in: sourceSize)
        let target = frame(in: canvas, sourceSize: sourceSize)
        guard fit == .fill, source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return source }
        let scale = max(target.width / source.width, target.height / source.height)
        let width = target.width / scale, height = target.height / scale
        return CGRect(x: source.midX - width / 2, y: source.midY - height / 2, width: width, height: height)
    }
    fileprivate static func blend(_ first: Self, _ last: Self, progress: Double) -> Self {
        func rect(_ a: EditorRegionRect, _ b: EditorRegionRect) -> EditorRegionRect {
            EditorRegionRect(x: MotionInterpolation.blend(a.x, b.x, progress: progress),
                y: MotionInterpolation.blend(a.y, b.y, progress: progress),
                width: MotionInterpolation.blend(a.width, b.width, progress: progress),
                height: MotionInterpolation.blend(a.height, b.height, progress: progress))
        }
        return Self(rect: rect(first.rect, last.rect), crop: rect(first.crop, last.crop),
                    fit: progress >= 1 ? last.fit : first.fit)
    }
}

/// All per-clip keyframe times and ramp durations are original asset seconds.
/// Trimming, moving, and retiming an occurrence never rewrites these points.
struct VideoGeometryKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var time: Double
    var geometry: VideoGeometry
    var transition: PIPTransition = .smooth
    var duration: Double = 0.4
    var easeIn: Double? = nil
    var easeOut: Double? = nil
}
struct VideoOpacityKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var time: Double
    var opacity: Double
    var transition: PIPTransition = .smooth
    var duration: Double = 0.4
    var easeIn: Double? = nil
    var easeOut: Double? = nil
}
struct VideoVolumeKeyframe: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var time: Double
    var gain: Double
    var transition: PIPTransition = .smooth
    var duration: Double = 0.4
    var easeIn: Double? = nil
    var easeOut: Double? = nil
}

struct VideoClip: Codable, Equatable, Identifiable, Sendable {
    static let legacyScreenID = UUID(uuidString: "56494445-4F00-4000-8000-000000000005")!
    static let legacyCameraID = UUID(uuidString: "56494445-4F00-4000-8000-000000000006")!
    var id: UUID = UUID()
    var sourceID: UUID
    var start: Double
    var end: Double
    var sourceStart: Double = 0
    var rate: Double = 1
    var layout: VideoClipLayout = .custom
    var geometry = VideoGeometry()
    var geometryKeyframes: [VideoGeometryKeyframe] = []
    var opacity: Double = 1
    var opacityKeyframes: [VideoOpacityKeyframe] = []
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var volume: Double = 1
    var isMuted = false
    var transition: VideoClipTransition = .crossfade
    var volumeKeyframes: [VideoVolumeKeyframe] = []

    var sourceEnd: Double { sourceStart + (end - start) * rate }
    func sourceTime(at projectTime: Double) -> Double { sourceStart + (projectTime - start) * rate }
    func projectTime(atSourceTime time: Double) -> Double { start + (time - sourceStart) / rate }
    func geometry(atSourceTime time: Double) -> VideoGeometry {
        var previous = geometry, previousTime = 0.0
        for point in geometryKeyframes {
            if time >= point.time { previous = point.geometry; previousTime = point.time; continue }
            let progress = MotionInterpolation.progress(at: time, from: previousTime, to: point.time,
                duration: point.duration, transition: point.transition, easeIn: point.easeIn, easeOut: point.easeOut)
            return VideoGeometry.blend(previous, point.geometry, progress: progress)
        }
        return previous
    }
    func opacity(atSourceTime time: Double) -> Double {
        Self.scalar(at: time, initial: opacity, points: opacityKeyframes) {
            ($0.time, $0.opacity, $0.transition, $0.duration, $0.easeIn, $0.easeOut)
        }
    }
    func envelopeGain(atSourceTime time: Double) -> Double {
        Self.scalar(at: time, initial: 1, points: volumeKeyframes) {
            ($0.time, $0.gain, $0.transition, $0.duration, $0.easeIn, $0.easeOut)
        }
    }
    private static func scalar<Point>(at time: Double, initial: Double, points: [Point],
        values: (Point) -> (Double, Double, PIPTransition, Double, Double?, Double?)) -> Double {
        var previous = initial, previousTime = 0.0
        for sourcePoint in points {
            let point = values(sourcePoint)
            if time >= point.0 { previous = point.1; previousTime = point.0; continue }
            let progress = MotionInterpolation.progress(at: time, from: previousTime, to: point.0,
                duration: point.3, transition: point.2, easeIn: point.4, easeOut: point.5)
            return MotionInterpolation.blend(previous, point.1, progress: progress)
        }
        return previous
    }
    func alpha(at projectTime: Double) -> Double {
        guard projectTime >= start, projectTime < end else { return 0 }
        let fades = MotionInterpolation.rampDurations(duration: end - start, easeIn: fadeIn, easeOut: fadeOut)
        let incoming = fades.easeIn > 0 ? MotionInterpolation.progress(at: projectTime, from: start,
            to: start + fades.easeIn, duration: fades.easeIn, transition: .smooth) : 1
        let outgoing = fades.easeOut > 0 ? 1 - MotionInterpolation.progress(at: projectTime,
            from: end - fades.easeOut, to: end, duration: fades.easeOut, transition: .smooth) : 1
        return opacity(atSourceTime: sourceTime(at: projectTime)) * incoming * outgoing
    }
}

struct VideoLayer: Codable, Equatable, Identifiable, Sendable {
    static let legacyScreenID = UUID(uuidString: "56494445-4F00-4000-8000-000000000003")!
    static let legacyCameraID = UUID(uuidString: "56494445-4F00-4000-8000-000000000004")!
    var id: UUID = UUID()
    var name: String
    var clips: [VideoClip] = []
}

/// Same-layer weights form a weighted image sum before source-over compositing
/// the layer. Independent source-over operations would darken a crossdissolve.
struct VideoLayerSample: Equatable, Sendable {
    var layerID: UUID
    var clipID: UUID
    var sourceID: UUID
    var sourceTime: Double
    var weight: Double
    var geometry: VideoGeometry
    var opacity: Double
    var layout: VideoClipLayout
    var volume: Double
    var isMuted: Bool
    var audioGain: Double
}

extension VideoSource {
    private enum DecodingKeys: String, CodingKey { case id, name, role, kind, relativePath, duration, pixelWidth, pixelHeight, hasAudio, patternSeed }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DecodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try values.decode(String.self, forKey: .name),
            role: try values.decodeIfPresent(VideoSourceRole.self, forKey: .role) ?? .footage,
            kind: try values.decode(VideoSourceKind.self, forKey: .kind),
            relativePath: try values.decodeIfPresent(String.self, forKey: .relativePath),
            duration: try values.decodeIfPresent(Double.self, forKey: .duration),
            pixelWidth: try values.decodeIfPresent(Int.self, forKey: .pixelWidth),
            pixelHeight: try values.decodeIfPresent(Int.self, forKey: .pixelHeight),
            hasAudio: try values.decodeIfPresent(Bool.self, forKey: .hasAudio),
            patternSeed: try values.decodeIfPresent(Int.self, forKey: .patternSeed) ?? 0)
    }
}

extension VideoGeometry {
    private enum DecodingKeys: String, CodingKey { case rect, crop, fit }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DecodingKeys.self)
        self.init(
            rect: try values.decodeIfPresent(EditorRegionRect.self, forKey: .rect) ?? VideoGeometry.fullRect,
            crop: try values.decodeIfPresent(EditorRegionRect.self, forKey: .crop) ?? VideoGeometry.fullRect,
            fit: try values.decodeIfPresent(VideoFit.self, forKey: .fit) ?? .fit)
    }
}

extension VideoClip {
    private enum DecodingKeys: String, CodingKey { case id, sourceID, start, end, sourceStart, rate, layout, geometry, geometryKeyframes, opacity, opacityKeyframes, fadeIn, fadeOut, volume, isMuted, transition, volumeKeyframes }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DecodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            sourceID: try values.decode(UUID.self, forKey: .sourceID),
            start: try values.decode(Double.self, forKey: .start),
            end: try values.decode(Double.self, forKey: .end),
            sourceStart: try values.decodeIfPresent(Double.self, forKey: .sourceStart) ?? 0,
            rate: try values.decodeIfPresent(Double.self, forKey: .rate) ?? 1,
            layout: try values.decodeIfPresent(VideoClipLayout.self, forKey: .layout) ?? .custom,
            geometry: try values.decodeIfPresent(VideoGeometry.self, forKey: .geometry) ?? VideoGeometry(),
            geometryKeyframes: try values.decodeIfPresent([VideoGeometryKeyframe].self, forKey: .geometryKeyframes) ?? [],
            opacity: try values.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
            opacityKeyframes: try values.decodeIfPresent([VideoOpacityKeyframe].self, forKey: .opacityKeyframes) ?? [],
            fadeIn: try values.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0,
            fadeOut: try values.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0,
            volume: try values.decodeIfPresent(Double.self, forKey: .volume) ?? 1,
            isMuted: try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            transition: try values.decodeIfPresent(VideoClipTransition.self, forKey: .transition) ?? .crossfade,
            volumeKeyframes: try values.decodeIfPresent([VideoVolumeKeyframe].self, forKey: .volumeKeyframes) ?? [])
    }
}

extension VideoLayer {
    private enum DecodingKeys: String, CodingKey { case id, name, clips }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DecodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try values.decode(String.self, forKey: .name),
            clips: try values.decodeIfPresent([VideoClip].self, forKey: .clips) ?? [])
    }
}

extension VideoGeometryKeyframe {
    private enum DecodingKeys: String, CodingKey { case id, time, geometry, transition, duration, easeIn, easeOut }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DecodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            time: try values.decode(Double.self, forKey: .time),
            geometry: try values.decode(VideoGeometry.self, forKey: .geometry),
            transition: try values.decodeIfPresent(PIPTransition.self, forKey: .transition) ?? .smooth,
            duration: try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0.4,
            easeIn: try values.decodeIfPresent(Double.self, forKey: .easeIn),
            easeOut: try values.decodeIfPresent(Double.self, forKey: .easeOut))
    }
}

extension VideoOpacityKeyframe {
    private enum DecodingKeys: String, CodingKey { case id, time, opacity, transition, duration, easeIn, easeOut }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DecodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            time: try values.decode(Double.self, forKey: .time),
            opacity: try values.decode(Double.self, forKey: .opacity),
            transition: try values.decodeIfPresent(PIPTransition.self, forKey: .transition) ?? .smooth,
            duration: try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0.4,
            easeIn: try values.decodeIfPresent(Double.self, forKey: .easeIn),
            easeOut: try values.decodeIfPresent(Double.self, forKey: .easeOut))
    }
}

extension VideoVolumeKeyframe {
    private enum DecodingKeys: String, CodingKey { case id, time, gain, transition, duration, easeIn, easeOut }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: DecodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            time: try values.decode(Double.self, forKey: .time),
            gain: try values.decode(Double.self, forKey: .gain),
            transition: try values.decodeIfPresent(PIPTransition.self, forKey: .transition) ?? .smooth,
            duration: try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0.4,
            easeIn: try values.decodeIfPresent(Double.self, forKey: .easeIn),
            easeOut: try values.decodeIfPresent(Double.self, forKey: .easeOut))
    }
}

enum ContentLayerKind: String, Codable, CaseIterable, Sendable {
    case text, arrow, rectangle, circle, image
    var title: String { rawValue.capitalized }
}

/// Immutable image bytes are stored once per project, outside undo snapshots.
/// Model commands can refer to these IDs but cannot supply files or image data.
struct ContentImageAsset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    let name: String
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
    static let maximumBytes = 8 * 1024 * 1024

    func validate() throws {
        guard !name.isEmpty, name.count <= 256, !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !data.isEmpty, data.count <= Self.maximumBytes,
              (1...16_384).contains(pixelWidth), (1...16_384).contains(pixelHeight),
              Int64(pixelWidth) * Int64(pixelHeight) <= 32_000_000 else {
            throw ProjectError.invalid("Use an image of at most 8 MiB and 32 megapixels, with a name of 1–256 characters.")
        }
    }
}

/// Visible content uses final-canvas normalized coordinates with a top-left
/// origin. Array order is back to front, above screen and camera. Times refer
/// to the original source; trims/cuts never rewrite or destroy these objects.
struct ContentLayer: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: ContentLayerKind
    var start: Double
    var end: Double
    var rect = EditorRegionRect(x: 0.25, y: 0.1, width: 0.5, height: 0.15)
    var endRect: EditorRegionRect? = nil
    var text = "Text"
    var assetID: UUID? = nil
    var color = CanvasColor(red: 1, green: 1, blue: 1)
    var opacity = 1.0
    /// Font size is a fraction of canvas height; line width uses its short edge.
    var fontSize = 0.045
    var bold = true
    var strokeWidth = 0.004
    var filled = false
    var rotation = 0.0
    var fadeIn = 0.2
    var fadeOut = 0.2

    init(id: UUID = UUID(), kind: ContentLayerKind, start: Double, end: Double) {
        self.id = id; self.kind = kind; self.start = start; self.end = end
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, kind, start, end, rect, endRect, text, assetID, color, opacity, fontSize, bold, strokeWidth, filled, rotation, fadeIn, fadeOut
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: any Decoder) throws {
        let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw ProjectError.invalid("The content layer contains unsupported fields.")
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            kind: try values.decode(ContentLayerKind.self, forKey: .kind),
            start: try values.decode(Double.self, forKey: .start), end: try values.decode(Double.self, forKey: .end))
        rect = try values.decodeIfPresent(EditorRegionRect.self, forKey: .rect) ?? rect
        endRect = try values.decodeIfPresent(EditorRegionRect.self, forKey: .endRect)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? text
        assetID = try values.decodeIfPresent(UUID.self, forKey: .assetID)
        color = try values.decodeIfPresent(CanvasColor.self, forKey: .color) ?? color
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? bold
        strokeWidth = try values.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? strokeWidth
        filled = try values.decodeIfPresent(Bool.self, forKey: .filled) ?? filled
        rotation = try values.decodeIfPresent(Double.self, forKey: .rotation) ?? rotation
        fadeIn = try values.decodeIfPresent(Double.self, forKey: .fadeIn) ?? fadeIn
        fadeOut = try values.decodeIfPresent(Double.self, forKey: .fadeOut) ?? fadeOut
    }

    var label: String { kind == .text ? String(text.prefix(48)) : kind.title }
    func isActive(at time: Double) -> Bool { time.isFinite && time >= start && time < end }
    func frame(at time: Double) -> EditorRegionRect {
        guard let endRect else { return rect }
        let progress = MotionInterpolation.progress(at: time, from: start, to: end,
            duration: end - start, transition: .smooth)
        func value(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        return EditorRegionRect(x: value(rect.x, endRect.x), y: value(rect.y, endRect.y),
            width: value(rect.width, endRect.width), height: value(rect.height, endRect.height))
    }
    func alpha(at time: Double) -> Double {
        guard isActive(at: time) else { return 0 }
        let fades = MotionInterpolation.rampDurations(duration: end - start, easeIn: fadeIn, easeOut: fadeOut)
        let incoming = fades.easeIn > 0 ? min(1, (time - start) / fades.easeIn) : 1
        let outgoing = fades.easeOut > 0 ? min(1, (end - time) / fades.easeOut) : 1
        return opacity * max(0, min(incoming, outgoing))
    }
    func translated(x: Double, y: Double) -> Self {
        guard x.isFinite, y.isFinite else { return self }
        let frames = [rect] + (endRect.map { [$0] } ?? [])
        let dx = min(frames.map { 1 - $0.x - $0.width }.min()!, max(-frames.map(\.x).min()!, x))
        let dy = min(frames.map { 1 - $0.y - $0.height }.min()!, max(-frames.map(\.y).min()!, y))
        var next = self
        next.rect.x = min(1 - rect.width, max(0, rect.x + dx)); next.rect.y = min(1 - rect.height, max(0, rect.y + dy))
        if var end = endRect { end.x = min(1 - end.width, max(0, end.x + dx)); end.y = min(1 - end.height, max(0, end.y + dy)); next.endRect = end }
        return next
    }
    func resized(width: Double, height: Double) -> Self {
        guard width.isFinite, height.isFinite else { return self }
        let frames = [rect] + (endRect.map { [$0] } ?? [])
        let dw = min(frames.map { 1 - $0.x - $0.width }.min()!, max(frames.map { 0.001 - $0.width }.max()!, width))
        let dh = min(frames.map { 1 - $0.y - $0.height }.min()!, max(frames.map { 0.001 - $0.height }.max()!, height))
        var next = self
        next.rect.width = min(1 - rect.x, max(0.001, rect.width + dw)); next.rect.height = min(1 - rect.y, max(0.001, rect.height + dh))
        if var end = endRect { end.width = min(1 - end.x, max(0.001, end.width + dw)); end.height = min(1 - end.y, max(0.001, end.height + dh)); next.endRect = end }
        return next
    }
    func validate(duration: Double, assets: Set<UUID>) throws {
        guard start.isFinite, end.isFinite, start >= 0, start < end, end <= duration,
              rect.isValid, rect.width >= 0.001, rect.height >= 0.001,
              endRect.map({ $0.isValid && $0.width >= 0.001 && $0.height >= 0.001 }) ?? true,
              [color.red, color.green, color.blue, opacity].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              fontSize.isFinite, (0.005...0.5).contains(fontSize), strokeWidth.isFinite, (0.0005...0.05).contains(strokeWidth),
              rotation.isFinite, (-180...180).contains(rotation),
              [fadeIn, fadeOut].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 60 }),
              text.count <= 4_096, !text.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
              }), kind != .text || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              kind == .image ? assetID.map(assets.contains) == true : assetID == nil else {
            throw ProjectError.invalid("A content layer needs a valid source-time range, canvas bounds, style, and registered image when applicable.")
        }
    }
}

struct EditState: Codable, Equatable, Sendable {
    var trimStart: Double
    var trimEnd: Double
    var pipKeyframes: [PIPKeyframe]
    var cameraOpacityKeyframes: [CameraOpacityKeyframe] = []
    var zoomKeyframes: [ZoomKeyframe] = []
    var cursorStyle: CursorStyle = CursorStyle()
    var presentation: CanvasPresentation = CanvasPresentation()
    var regions: [EditorRegion] = []
    var editAnchors: [EditAnchor] = []
    var audio = RecordingAudio()
    var cuts: [RecordingCut] = []
    var contentLayers: [ContentLayer] = []
    var speedKeyframes: [RecordingSpeedKeyframe] = []
    var videoLayers: [VideoLayer]? = nil
    var preservesAudioPitch = true
    /// Missing only in legacy states. A persisted version prevents a manually
    /// detached target from being inferred again after a later save/reopen.
    var boxConnectionsVersion = 1

    init(trimStart: Double, trimEnd: Double, pipKeyframes: [PIPKeyframe],
         zoomKeyframes: [ZoomKeyframe] = [], cursorStyle: CursorStyle = CursorStyle(),
         presentation: CanvasPresentation = CanvasPresentation(), regions: [EditorRegion] = [],
         editAnchors: [EditAnchor] = [], audio: RecordingAudio = RecordingAudio(), cuts: [RecordingCut] = [],
         contentLayers: [ContentLayer] = [], speedKeyframes: [RecordingSpeedKeyframe] = [], preservesAudioPitch: Bool = true, cameraOpacityKeyframes: [CameraOpacityKeyframe] = [], videoLayers: [VideoLayer]? = nil) {
        self.videoLayers = videoLayers
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.pipKeyframes = pipKeyframes
        self.zoomKeyframes = zoomKeyframes
        self.cursorStyle = cursorStyle
        self.presentation = presentation
        self.regions = regions
        self.editAnchors = editAnchors
        self.audio = audio
        self.cuts = cuts
        self.contentLayers = contentLayers
        self.speedKeyframes = speedKeyframes
        self.preservesAudioPitch = preservesAudioPitch
        self.cameraOpacityKeyframes = cameraOpacityKeyframes
    }

    private enum CodingKeys: String, CodingKey {
        case trimStart, trimEnd, pipKeyframes, cameraOpacityKeyframes, zoomKeyframes, cursorStyle, presentation, regions, editAnchors, audio, cuts, contentLayers, boxConnectionsVersion,
             speedKeyframes, preservesAudioPitch, videoLayers
    }

    /// Migration lives on each state so prior undo/redo snapshots also gain
    /// identity zooms and default styling without losing any existing edits.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trimStart = try values.decode(Double.self, forKey: .trimStart)
        trimEnd = try values.decode(Double.self, forKey: .trimEnd)
        pipKeyframes = try values.decode([PIPKeyframe].self, forKey: .pipKeyframes)
        cameraOpacityKeyframes = try values.decodeIfPresent([CameraOpacityKeyframe].self, forKey: .cameraOpacityKeyframes) ?? []
        zoomKeyframes = try values.decodeIfPresent([ZoomKeyframe].self, forKey: .zoomKeyframes) ?? []
        cursorStyle = try values.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? CursorStyle()
        presentation = try values.decodeIfPresent(CanvasPresentation.self, forKey: .presentation) ?? CanvasPresentation()
        regions = try values.decodeIfPresent([EditorRegion].self, forKey: .regions) ?? []
        editAnchors = try values.decodeIfPresent([EditAnchor].self, forKey: .editAnchors) ?? []
        audio = try values.decodeIfPresent(RecordingAudio.self, forKey: .audio) ?? RecordingAudio()
        cuts = try values.decodeIfPresent([RecordingCut].self, forKey: .cuts) ?? []
        contentLayers = try values.decodeIfPresent([ContentLayer].self, forKey: .contentLayers) ?? []
        speedKeyframes = try values.decodeIfPresent([RecordingSpeedKeyframe].self, forKey: .speedKeyframes) ?? []
        videoLayers = try values.decodeIfPresent([VideoLayer].self, forKey: .videoLayers)
        preservesAudioPitch = try values.decodeIfPresent(Bool.self, forKey: .preservesAudioPitch) ?? true
        if values.contains(.boxConnectionsVersion) {
            boxConnectionsVersion = try values.decode(Int.self, forKey: .boxConnectionsVersion)
            guard boxConnectionsVersion == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .boxConnectionsVersion, in: values,
                    debugDescription: "Unsupported box connection version.")
            }
        } else {
            boxConnectionsVersion = 1
            self = EditorBoxConnections.migratingLegacy(self)
        }
    }

    mutating func materializeVideoLayers(project: RecordingProject) {
        if videoLayers == nil { videoLayers = project.effectiveVideoLayers(in: self) }
    }

    func speed(at time: Double) -> Double { RecordingRetime.rate(at: time, points: speedKeyframes) }

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
        var result = cameraGeometry(at: time)
        if !cameraOpacityKeyframes.isEmpty {
            result.visible = true
            result.opacity = cameraOpacity(at: time)
        }
        return result
    }

    /// Only real legacy visibility/alpha changes enter this clock. Geometry
    /// targets that retain appearance never truncate or restart a fade.
    var cameraOpacityEvents: [CameraOpacityKeyframe] {
        let geometry = pipKeyframes.sorted { $0.time < $1.time }
        let initial = geometry.first
        var events = [CameraOpacityKeyframe(id: initial?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, time: 0,
            opacity: initial?.placement.renderedOpacity ?? 1)]
        var previous = events[0].opacity
        var previousGeometry = initial
        for point in geometry.dropFirst() {
            let opacity = point.placement.renderedOpacity
            if opacity != previous {
                let visibilityChanged = previousGeometry?.placement.visible != point.placement.visible
                let start = max(previousGeometry?.time ?? 0, point.time - point.duration)
                events.append(CameraOpacityKeyframe(id: point.id, time: point.time, opacity: opacity,
                    transition: visibilityChanged ? .jump : point.transition,
                    duration: max(0.000001, point.time - start), easeIn: point.easeIn, easeOut: point.easeOut))
            }
            previous = opacity; previousGeometry = point
        }
        let independent = cameraOpacityKeyframes.sorted { $0.time < $1.time }
        var merged: [CameraOpacityKeyframe] = [], legacyIndex = 0, ownIndex = 0
        while legacyIndex < events.count || ownIndex < independent.count {
            if ownIndex == independent.count { merged.append(events[legacyIndex]); legacyIndex += 1 }
            else if legacyIndex == events.count { merged.append(independent[ownIndex]); ownIndex += 1 }
            else if abs(events[legacyIndex].time - independent[ownIndex].time) < 0.000001 {
                merged.append(independent[ownIndex]); ownIndex += 1; legacyIndex += 1
            } else if events[legacyIndex].time < independent[ownIndex].time {
                merged.append(events[legacyIndex]); legacyIndex += 1
            } else { merged.append(independent[ownIndex]); ownIndex += 1 }
        }
        return merged
    }

    func cameraOpacity(at time: Double) -> Double {
        let events = cameraOpacityEvents
        guard var previous = events.first else { return 1 }
        guard time.isFinite, time > previous.time else { return previous.opacity }
        for point in events.dropFirst() {
            if time >= point.time { previous = point; continue }
            let progress = MotionInterpolation.progress(at: time, from: previous.time, to: point.time,
                duration: point.duration, transition: point.transition, easeIn: point.easeIn, easeOut: point.easeOut)
            return MotionInterpolation.blend(previous.opacity, point.opacity, progress: progress)
        }
        return previous.opacity
    }

    func cameraGeometry(at time: Double) -> PIPPlacement {
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
                                sourceZoom: blend(previous.placement.sourceZoom, point.placement.sourceZoom),
                                sourceCrop: CropGeometry.interpolate(previous.placement.sourceCrop, point.placement.sourceCrop, progress: progress),
                                fullscreen: previous.placement.fullscreen == nil && point.placement.fullscreen == nil ? nil :
                                    blend(previous.placement.fullscreen ?? 0, point.placement.fullscreen ?? 0),
                                opacity: blend(previous.placement.opacity, point.placement.opacity))
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

/// Persistent guide-to-target relationships. Only explicit links participate
/// in deletion; identical placements and drawn-at anchors are not ownership.
enum EditorBoxConnections {
    static func linkedRegion(for point: ZoomKeyframe, in state: EditState) -> EditorRegion? {
        guard let id = point.sourceRegionID else { return nil }
        return state.regions.first { $0.id == id }
    }

    fileprivate static func migratingLegacy(_ state: EditState) -> EditState {
        var result = state
        for index in result.zoomKeyframes.indices where result.zoomKeyframes[index].sourceRegionID == nil {
            // This is precisely the previous label inference criterion. Only a
            // unique match is safe; a guide's editID says where it was drawn.
            let target = result.zoomKeyframes[index].placement.clamped
            // Legacy return-to-full-frame points had no box destination label.
            // A large guide fitting at 1× must not claim those context points.
            guard target.scale > 1 else { continue }
            let matches = state.regions.filter { $0.framing == target }
            if matches.count == 1 { result.zoomKeyframes[index].sourceRegionID = matches[0].id }
        }
        result.boxConnectionsVersion = 1
        return result
    }

    /// Removes every target explicitly connected to this guide. A smooth
    /// successor bridges the removed motion chain, keeping its own arrival and
    /// target. Jumps/holds alone never create a new earlier motion interval.
    static func removing(regionID: UUID, from state: EditState) -> EditState {
        removing(regionIDs: [regionID], from: state)
    }

    /// A simultaneous deletion uses the original chain once, so removing an
    /// excursion and its return cannot lose motion provenance between calls.
    static func removing(regionIDs: Set<UUID>, from state: EditState) -> EditState {
        let removedIDs = regionIDs.intersection(Set(state.regions.map(\.id)))
        guard !removedIDs.isEmpty else { return state }
        var result = state
        // Legacy files omitted anchor provenance. Preserve the inferred box
        // role when its last guide is explicitly deleted, so it cannot turn
        // into an unrequested visible bookmark after that operation.
        for region in state.regions where removedIDs.contains(region.id) {
            if let index = result.editAnchors.firstIndex(where: {
                $0.id == region.editID && $0.origin == nil && abs($0.time - region.time) < 0.000001
            }) { result.editAnchors[index].origin = .box }
        }
        result.regions.removeAll { removedIDs.contains($0.id) }
        func isRemoved(_ point: ZoomKeyframe) -> Bool {
            point.sourceRegionID.map { removedIDs.contains($0) } ?? false
        }
        let points = state.zoomKeyframes.sorted { $0.time < $1.time }
        var kept: [ZoomKeyframe] = []
        var previousTime = 0.0
        var previousPlacement = ZoomPlacement()
        var removedBlock = false
        var firstMotion: (start: Double, easeIn: Double)?
        for original in points {
            let smooth = original.transition == .smooth && original.duration.isFinite && original.duration > 0
            let start = smooth ? max(previousTime, original.time - original.duration) : original.time
            let span = max(0, original.time - start)
            let ramps = MotionInterpolation.rampDurations(duration: span, easeIn: original.easeIn, easeOut: original.easeOut)
            if isRemoved(original) {
                removedBlock = true
                if firstMotion == nil, smooth, span > 0, previousPlacement.clamped != original.placement.clamped {
                    firstMotion = (start, ramps.easeIn)
                }
            } else {
                var survivor = original
                if removedBlock, smooth {
                    let beginning = firstMotion?.start ?? start
                    survivor.duration = max(0, original.time - beginning)
                    if let firstMotion {
                        let joined = MotionInterpolation.rampDurations(duration: survivor.duration,
                            easeIn: firstMotion.easeIn, easeOut: ramps.easeOut)
                        survivor.easeIn = joined.easeIn
                        survivor.easeOut = joined.easeOut
                    }
                }
                kept.append(survivor)
                removedBlock = false; firstMotion = nil
            }
            previousTime = original.time
            previousPlacement = original.placement
        }
        // Keep unrelated array ordering byte-for-byte where possible. Timing
        // relationships above use source order, not the storage order.
        var replacements: [UUID: ZoomKeyframe] = [:]
        for point in kept { replacements[point.id] = point }
        result.zoomKeyframes = state.zoomKeyframes.compactMap { point in
            isRemoved(point) ? nil : replacements[point.id]
        }
        return result
    }
}

/// A named timeline reference can precede any visual edit. Drawing a box must
/// not insert a zoom or alter an existing interpolation merely to name a time.
struct EditAnchor: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        case reference, box, generated
    }
    var id: UUID = UUID()
    var time: Double
    /// Missing in older files: infer box-only presentation without rewriting
    /// their metadata. New intentional bookmarks are explicit references.
    var origin: Origin? = .reference
}

/// One selectable moment, combining independently animated screen and camera
/// properties. Existing files retain their independent tracks and interpolation.
struct TimedEdit: Identifiable, Equatable {
    let id: UUID
    let time: Double
    let zoomID: UUID?
    let cameraID: UUID?
    let anchorID: UUID?
    let speedID: UUID?
    let cameraOpacityID: UUID?

    init(id: UUID, time: Double, zoomID: UUID?, cameraID: UUID?, anchorID: UUID? = nil, speedID: UUID? = nil, cameraOpacityID: UUID? = nil) {
        self.id = id
        self.time = time
        self.zoomID = zoomID
        self.cameraID = cameraID
        self.anchorID = anchorID
        self.speedID = speedID
        self.cameraOpacityID = cameraOpacityID
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
        for speed in speedKeyframes {
            if let index = result.firstIndex(where: { abs($0.time - speed.time) < 0.000001 }) {
                let combined = result[index]
                result[index] = TimedEdit(id: combined.id, time: combined.time, zoomID: combined.zoomID,
                    cameraID: combined.cameraID, anchorID: combined.anchorID, speedID: speed.id, cameraOpacityID: combined.cameraOpacityID)
            } else {
                result.append(TimedEdit(id: speed.id, time: speed.time, zoomID: nil, cameraID: nil, speedID: speed.id))
            }
        }
        if includeCamera {
            for opacity in cameraOpacityKeyframes {
                if let index = result.firstIndex(where: { abs($0.time - opacity.time) < 0.000001 }) {
                    let combined = result[index]
                    result[index] = TimedEdit(id: combined.id, time: combined.time, zoomID: combined.zoomID,
                        cameraID: combined.cameraID, anchorID: combined.anchorID, speedID: combined.speedID, cameraOpacityID: opacity.id)
                } else { result.append(TimedEdit(id: opacity.id, time: opacity.time, zoomID: nil, cameraID: nil, cameraOpacityID: opacity.id)) }
            }
        }
        for anchor in editAnchors {
            if let index = result.firstIndex(where: { abs($0.time - anchor.time) < 0.000001 }) {
                let combined = result[index]
                result[index] = TimedEdit(id: anchor.id, time: anchor.time, zoomID: combined.zoomID,
                                         cameraID: combined.cameraID, anchorID: anchor.id, speedID: combined.speedID, cameraOpacityID: combined.cameraOpacityID)
            } else {
                result.append(TimedEdit(id: anchor.id, time: anchor.time, zoomID: nil, cameraID: nil, anchorID: anchor.id))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// Director can still address every anchor. Only deliberate bookmarks
    /// belong in animation lanes; a box's naming identity is not an animation.
    func showsReference(_ anchor: EditAnchor) -> Bool {
        switch anchor.origin {
        case .reference: return true
        case .box, .generated: return false
        case nil:
            return !regions.contains { $0.editID == anchor.id && abs($0.time - anchor.time) < 0.000001 }
        }
    }

    /// Visible edit navigation/cards exclude internal naming anchors while
    /// raw timedEdits remains the complete addressable Director catalog.
    func showsTimedEdit(_ edit: TimedEdit) -> Bool {
        if edit.zoomID != nil || edit.cameraID != nil || edit.speedID != nil || edit.cameraOpacityID != nil { return true }
        guard let anchor = editAnchors.first(where: { $0.id == edit.anchorID }) else { return true }
        return showsReference(anchor)
    }

    /// An explicit bookmark request promotes an implicit identity in place,
    /// preserving boxes, spoken references and the ordinary Undo snapshot.
    mutating func createReference(at time: Double, includeCamera: Bool = true) {
        if let index = editAnchors.firstIndex(where: { abs($0.time - time) < 0.000001 }) {
            editAnchors[index].origin = .reference
        } else if !timedEdits(includeCamera: includeCamera).contains(where: { abs($0.time - time) < 0.000001 }) {
            editAnchors.append(EditAnchor(time: time))
            editAnchors.sort { $0.time < $1.time }
        }
    }

    /// A box and its reference mark form one value edit and one undo snapshot.
    /// Additional boxes on this frame reuse its existing selectable moment.
    @discardableResult
    mutating func addRegion(rect: EditorRegionRect, at time: Double, includeCamera: Bool = true) -> EditorRegion {
        let editID: UUID
        if let existing = timedEdits(includeCamera: includeCamera).first(where: { abs($0.time - time) < 0.000001 }) {
            editID = existing.id
        } else {
            let anchor = EditAnchor(time: time, origin: .box)
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
        speedKeyframes.removeAll { $0.id == edit.speedID }
        cameraOpacityKeyframes.removeAll { $0.id == edit.cameraOpacityID }
        editAnchors.removeAll { $0.id == edit.anchorID }
    }

    mutating func move(_ edit: TimedEdit, to time: Double) {
        if let index = zoomKeyframes.firstIndex(where: { $0.id == edit.zoomID }) { zoomKeyframes[index].time = time }
        if let index = pipKeyframes.firstIndex(where: { $0.id == edit.cameraID && $0.time > 0 }) { pipKeyframes[index].time = time }
        if let index = speedKeyframes.firstIndex(where: { $0.id == edit.speedID }) { speedKeyframes[index].time = time }
        if let index = editAnchors.firstIndex(where: { $0.id == edit.anchorID }) { editAnchors[index].time = time }
        if let index = cameraOpacityKeyframes.firstIndex(where: { $0.id == edit.cameraOpacityID }) { cameraOpacityKeyframes[index].time = time }
        zoomKeyframes.sort { $0.time < $1.time }
        pipKeyframes.sort { $0.time < $1.time }
        speedKeyframes.sort { $0.time < $1.time }
        cameraOpacityKeyframes.sort { $0.time < $1.time }
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

/// The action publishing a saved project, with names in execution order.
/// This describes the current notification only and is not project data.
struct ProjectHistoryOperation: Equatable, Sendable {
    enum Kind: String, Sendable { case edit, undo, redo }
    var kind: Kind
    var names: [String]
}

/// Media filenames are relative to the project. Source media is never opened
/// for writing by the editor, and history survives saving and reopening.
struct RecordingProject: Codable, Equatable, Sendable {
    var version: Int = 1
    var screenFilename: String
    var cameraFilename: String?
    var cursorFilename: String?
    var sceneFilename: String?
    var title: String?
    /// Stable entity identity, independent of its title and transport.
    var automationID: UUID?
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
    var contentAssets: [ContentImageAsset] = []
    var audioSources: [RecordingAudioSource] = []
    var videoAssets: [VideoSource] = []

    init(version: Int = 1, screenFilename: String, cameraFilename: String? = nil, cursorFilename: String? = nil,
         sceneFilename: String? = nil,
         cameraOffset: Double = 0, duration: Double, state: EditState? = nil,
         undoHistory: [NamedEditSnapshot] = [], redoHistory: [NamedEditSnapshot] = [], title: String? = nil,
         captureFrameDuration: Double? = nil, references: EditorReferences = EditorReferences(),
         automationID: UUID? = UUID(), audioSources: [RecordingAudioSource] = [], videoAssets: [VideoSource] = []) {
        self.version = version
        self.screenFilename = screenFilename
        self.cameraFilename = cameraFilename
        self.cursorFilename = cursorFilename
        self.sceneFilename = sceneFilename
        self.title = title
        self.automationID = automationID
        self.cameraOffset = cameraOffset
        self.captureFrameDuration = captureFrameDuration
        self.duration = duration
        self.state = state ?? EditState(trimStart: 0, trimEnd: duration,
                                       pipKeyframes: [PIPKeyframe(time: 0, placement: PIPPlacement())])
        self.undoHistory = undoHistory
        self.redoHistory = redoHistory
        self.references = references
        self.videoAssets = videoAssets
        self.audioSources = audioSources
        for source in audioSources where !self.state.audio.channels.contains(where: { $0.role == source.role }) {
            self.state.audio.channels.append(.init(role: source.role))
        }
        ensureReferences()
    }

    private enum CodingKeys: String, CodingKey {
        case version, screenFilename, cameraFilename, cursorFilename, sceneFilename, title, automationID, cameraOffset,
             captureFrameDuration, duration, state, undoHistory, redoHistory, references, contentAssets, audioSources, videoAssets
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        screenFilename = try values.decode(String.self, forKey: .screenFilename)
        cameraFilename = try values.decodeIfPresent(String.self, forKey: .cameraFilename)
        cursorFilename = try values.decodeIfPresent(String.self, forKey: .cursorFilename)
        sceneFilename = try values.decodeIfPresent(String.self, forKey: .sceneFilename)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        automationID = try values.decodeIfPresent(UUID.self, forKey: .automationID)
        cameraOffset = try values.decodeIfPresent(Double.self, forKey: .cameraOffset) ?? 0
        captureFrameDuration = try values.decodeIfPresent(Double.self, forKey: .captureFrameDuration)
        duration = try values.decode(Double.self, forKey: .duration)
        state = try values.decode(EditState.self, forKey: .state)
        undoHistory = try values.decodeIfPresent([NamedEditSnapshot].self, forKey: .undoHistory) ?? []
        redoHistory = try values.decodeIfPresent([NamedEditSnapshot].self, forKey: .redoHistory) ?? []
        references = try values.decodeIfPresent(EditorReferences.self, forKey: .references) ?? EditorReferences()
        contentAssets = try values.decodeIfPresent([ContentImageAsset].self, forKey: .contentAssets) ?? []
        videoAssets = try values.decodeIfPresent([VideoSource].self, forKey: .videoAssets) ?? []
        audioSources = try values.decodeIfPresent([RecordingAudioSource].self, forKey: .audioSources) ?? []
        try references.validate()
        ensureReferences()
    }

    /// The two legacy identities never change on reload or Undo/Redo. Registered
    /// footage is immutable and remains available after occurrences are removed.
    var videoSources: [VideoSource] {
        var result = [VideoSource(id: VideoSource.legacyScreenID, name: "Screen", role: .screen, kind: .file,
            relativePath: screenFilename, duration: duration)]
        if let cameraFilename {
            result.append(VideoSource(id: VideoSource.legacyCameraID, name: "Camera", role: .camera, kind: .file,
                relativePath: cameraFilename, duration: nil, hasAudio: false))
        }
        return result + videoAssets
    }

    func effectiveVideoLayers(in state: EditState? = nil) -> [VideoLayer] {
        if let layers = (state ?? self.state).videoLayers { return layers }
        var result = [VideoLayer(id: VideoLayer.legacyScreenID, name: "Screen", clips: [
            VideoClip(id: VideoClip.legacyScreenID, sourceID: VideoSource.legacyScreenID, start: 0,
                      end: duration, layout: .screen)
        ])]
        if cameraFilename != nil {
            let beginning = max(0, cameraOffset)
            let clips: [VideoClip] = beginning < duration ? [VideoClip(id: VideoClip.legacyCameraID,
                sourceID: VideoSource.legacyCameraID, start: beginning, end: duration,
                sourceStart: max(0, -cameraOffset), layout: .camera, isMuted: true)] : []
            result.append(VideoLayer(id: VideoLayer.legacyCameraID, name: "Camera", clips: clips))
        }
        return result
    }

    func videoSamples(at time: Double, state: EditState? = nil) -> [VideoLayerSample] {
        guard time.isFinite, time >= 0, time < duration else { return [] }
        let sources = Dictionary(videoSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var samples: [VideoLayerSample] = []
        for layer in effectiveVideoLayers(in: state) {
            let active = layer.clips.filter { time >= $0.start && time < $0.end }.sorted {
                $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
            }
            for (index, clip) in active.enumerated() {
                guard let source = sources[clip.sourceID] else { continue }
                let sourceTime = clip.sourceTime(at: time)
                guard sourceTime.isFinite, sourceTime >= 0,
                      source.duration.map({ sourceTime < $0 }) ?? true else { continue }
                var weight = 1.0
                if active.count == 2 {
                    let outgoing = active[0], incoming = active[1]
                    if incoming.transition == .cut { weight = index == 1 ? 1 : 0 }
                    else {
                        let span = min(outgoing.end, incoming.end) - incoming.start
                        let fraction = span > 0 ? min(1, max(0, (time - incoming.start) / span)) : 1
                        weight = index == 0 ? 1 - fraction : fraction
                    }
                }
                guard weight > 0 else { continue }
                samples.append(VideoLayerSample(layerID: layer.id, clipID: clip.id, sourceID: source.id,
                    sourceTime: sourceTime, weight: weight, geometry: clip.geometry(atSourceTime: sourceTime),
                    opacity: clip.alpha(at: time), layout: clip.layout, volume: clip.volume, isMuted: clip.isMuted,
                    audioGain: clip.isMuted ? 0 : clip.volume * clip.envelopeGain(atSourceTime: sourceTime) * weight))
            }
        }
        return samples
    }

    private func validateVideoLayers(_ layers: [VideoLayer]?) throws {
        guard let layers else { return }
        guard layers.count <= 128, Set(layers.map(\.id)).count == layers.count else {
            throw ProjectError.invalid("Use at most 128 video layers with unique identities.")
        }
        let sources = Dictionary(uniqueKeysWithValues: videoSources.map { ($0.id, $0) })
        var clipIDs = Set<UUID>(), pointIDs = Set<UUID>()
        for layer in layers {
            try Self.validateTitle(layer.name)
            guard layer.clips.count <= 4096 else { throw ProjectError.invalid("A video layer has too many clips.") }
            let ordered = layer.clips.sorted { $0.start < $1.start }
            for (index, clip) in ordered.enumerated() {
                guard clipIDs.insert(clip.id).inserted, let source = sources[clip.sourceID] else {
                    throw ProjectError.invalid("Video clips need unique identities and registered source IDs.")
                }
                guard [clip.start, clip.end, clip.sourceStart, clip.rate, clip.opacity, clip.fadeIn, clip.fadeOut, clip.volume].allSatisfy(\.isFinite),
                      clip.start >= 0, clip.end > clip.start, clip.end <= duration,
                      clip.sourceStart >= 0, (0.1...8).contains(clip.rate), clip.sourceEnd.isFinite,
                      source.duration.map({ clip.sourceEnd <= $0 + max(1, $0) * 1e-12 }) ?? true,
                      (0...1).contains(clip.opacity), (0...1).contains(clip.volume), clip.fadeIn >= 0, clip.fadeOut >= 0,
                      clip.geometry.rect.isValid, clip.geometry.crop.isValid else {
                    throw ProjectError.invalid("Video clip timing, source trim, framing, opacity, or audio level is invalid.")
                }
                // Contained clips would dissolve in and then pop back out. A
                // sequence advances both boundaries; overlays use another layer.
                if index > 0 {
                    let previous = ordered[index - 1]
                    guard clip.start > previous.start, clip.end > previous.end else {
                        throw ProjectError.invalid("Clips in one video layer must advance in time; put overlays in another layer.")
                    }
                }
                if index > 1, ordered[index - 2].end > clip.start {
                    throw ProjectError.invalid("Only two clips may overlap in a video layer.")
                }
                func points(_ values: [(UUID, Double, Double, Double?, Double?)]) throws {
                    var previous = -Double.infinity
                    for (id, time, ramp, easeIn, easeOut) in values {
                        guard pointIDs.insert(id).inserted, time.isFinite, time >= 0, time > previous,
                              source.duration.map({ time <= $0 }) ?? true,
                              ramp.isFinite, ramp >= 0,
                              [easeIn, easeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                            throw ProjectError.invalid("Video animation points need unique identities, increasing source times, and finite ramps inside the source.")
                        }
                        previous = time
                    }
                }
                try points(clip.geometryKeyframes.map { ($0.id, $0.time, $0.duration, $0.easeIn, $0.easeOut) })
                try points(clip.opacityKeyframes.map { ($0.id, $0.time, $0.duration, $0.easeIn, $0.easeOut) })
                try points(clip.volumeKeyframes.map { ($0.id, $0.time, $0.duration, $0.easeIn, $0.easeOut) })
                guard clip.geometryKeyframes.allSatisfy({ $0.geometry.rect.isValid && $0.geometry.crop.isValid }),
                      clip.opacityKeyframes.allSatisfy({ $0.opacity.isFinite && (0...1).contains($0.opacity) }),
                      clip.volumeKeyframes.allSatisfy({ $0.gain.isFinite && (0...1).contains($0.gain) }) else {
                    throw ProjectError.invalid("Video animation targets must use valid framing and levels between zero and one.")
                }
            }
        }
    }

    mutating func ensureReferences(in extraState: EditState? = nil) {
        references.register(state: state, includeCamera: cameraFilename != nil)
        if let extraState { references.register(state: extraState, includeCamera: cameraFilename != nil) }
        for snapshot in undoHistory + redoHistory {
            references.register(state: snapshot.state, includeCamera: cameraFilename != nil)
        }
        let states = [state] + (extraState.map { [$0] } ?? []) + (undoHistory + redoHistory).map(\.state)
        let usedAssets = Set(states.flatMap { $0.contentLayers.compactMap(\.assetID) })
        contentAssets.removeAll { !usedAssets.contains($0.id) }
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
        guard contentAssets.count <= 32, Set(contentAssets.map(\.id)).count == contentAssets.count,
              contentAssets.reduce(0, { $0 + $1.data.count }) <= 32 * 1024 * 1024 else {
            throw ProjectError.invalid("Keep at most 32 content images and 32 MiB of image data in a project.")
        }
        for asset in contentAssets { try asset.validate() }
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
        for filename in [screenFilename, cameraFilename, cursorFilename, sceneFilename].compactMap({ $0 }) {
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
        if let sceneFilename, [screenFilename, cameraFilename, cursorFilename].compactMap({ $0 }).contains(sceneFilename) {
            throw ProjectError.invalid("Scene metadata must use a separate source file.")
        }
        guard Set(audioSources.map(\.role)).count == audioSources.count,
              audioSources.allSatisfy({ $0.identifier == $0.role.metadataIdentifier }) else {
            throw ProjectError.invalid("Audio source roles require unique explicit capture metadata bindings.")
        }
        guard Set(videoSources.map(\.id)).count == videoSources.count, videoAssets.count <= 4096 else {
            throw ProjectError.invalid("Video sources need unique identities and a bounded source library.")
        }
        for source in videoAssets { try source.validate() }
        // Visual-only history commonly repeats the same timing. Compile each
        // distinct plan once per validation, without retaining global state or
        // skipping validation of any other snapshot properties.
        var timingPlans = Set<TimingSignature>()
        try validate(state, timingPlans: &timingPlans)
        for snapshot in undoHistory + redoHistory {
            try validate(snapshot.state, timingPlans: &timingPlans)
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

    private struct TimingSignature: Hashable {
        let trimStart: Double
        let trimEnd: Double
        let cuts: [RecordingCut]
        let speed: [RecordingSpeedKeyframe]
    }

    private func validate(_ state: EditState, timingPlans: inout Set<TimingSignature>) throws {
        try validateVideoLayers(state.videoLayers)
        guard state.contentLayers.count <= 256, Set(state.contentLayers.map(\.id)).count == state.contentLayers.count else {
            throw ProjectError.invalid("Keep at most 256 content layers with unique identities.")
        }
        let assets = Set(contentAssets.map(\.id))
        for layer in state.contentLayers { try layer.validate(duration: duration, assets: assets) }
        guard state.boxConnectionsVersion == 1 else {
            throw ProjectError.invalid("This recording uses an unsupported box connection version.")
        }
        try state.audio.validate()
        guard Set(state.audio.channels.map(\.role)).count == state.audio.channels.count else { throw ProjectError.invalid("Audio roles must be unique.") }
        for channel in state.audio.channels {
            guard audioSources.contains(where: { $0.role == channel.role }) else { throw ProjectError.invalid("This recording has no identified \(channel.role.title.lowercased()) track.") }
            try channel.validate(duration: duration)
        }
        let timing = TimingSignature(trimStart: state.trimStart, trimEnd: state.trimEnd, cuts: state.cuts, speed: state.speedKeyframes)
        if !timingPlans.contains(timing) {
            _ = try RecordingTimeMap(duration: duration, trimStart: state.trimStart, trimEnd: state.trimEnd, cuts: state.cuts,
                speedKeyframes: state.speedKeyframes)
            timingPlans.insert(timing)
        }
        guard state.editAnchors.count <= 100_000 else {
            throw ProjectError.invalid("Keep at most 100,000 reference marks in a recording.")
        }
        guard state.cameraOpacityKeyframes.count <= 100_000 else { throw ProjectError.invalid("Keep at most 100,000 camera opacity points.") }
        var priorOpacityTime = -Double.infinity, opacityIDs = Set<UUID>()
        for point in state.cameraOpacityKeyframes {
            guard point.time.isFinite, point.time >= 0, point.time <= duration, point.time - priorOpacityTime >= 0.000001,
                  opacityIDs.insert(point.id).inserted, point.opacity.isFinite, (0...1).contains(point.opacity),
                  point.duration.isFinite, point.duration > 0,
                  [point.easeIn, point.easeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw ProjectError.invalid("Camera opacity points need unique ordered times, opacity from 0 to 1, and valid ramps.")
            }
            priorOpacityTime = point.time
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
                                  state.pipKeyframes.first(where: { $0.id == anchor.id })?.time,
                                  state.speedKeyframes.first(where: { $0.id == anchor.id })?.time,
                                  state.cameraOpacityKeyframes.first(where: { $0.id == anchor.id })?.time].compactMap { $0 }
            guard componentTimes.allSatisfy({ abs($0 - anchor.time) < 0.000001 }) else {
                throw ProjectError.invalid("An edit and its reference mark must share the same time.")
            }
            priorAnchorTime = anchor.time
        }
        guard state.regions.count <= 256, Set(state.regions.map(\.id)).count == state.regions.count else {
            throw ProjectError.invalid("Boxes must have unique identities; keep at most 256 per recording.")
        }
        for region in state.regions { try region.validate(duration: duration) }
        let regionIDs = Set(state.regions.map(\.id))
        let presentation = state.presentation
        guard presentation.outputResolution.map(\.isValid) ?? true else { throw ProjectError.invalid("Output dimensions must be even numbers from 2 to 8192 pixels.") }
        guard presentation.sourceCrop.map(\.isValid) ?? true else { throw ProjectError.invalid("The main crop must be a nonempty rectangle inside the source.") }
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
                  placement.aspectRatio.isFinite, placement.aspectRatio > 0,
                  (placement.sourceCrop != nil || (0.2...5).contains(placement.aspectRatio)),
                  placement.sourceCrop.map(\.isValid) ?? true,
                  placement.crop.x.isFinite, (0...1).contains(placement.crop.x),
                  placement.crop.y.isFinite, (0...1).contains(placement.crop.y),
                  placement.sourceZoom.isFinite, (1...3).contains(placement.sourceZoom),
                  placement.opacity.isFinite, (0...1).contains(placement.opacity),
                  placement.fullscreen.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
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
                  point.sourceRegionID.map({ regionIDs.contains($0) }) ?? true,
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
    /// Read inside a synchronous `$project` subscriber; nil outside publication.
    private(set) var publishingHistoryOperation: ProjectHistoryOperation?
    private(set) var publishingActor: String?
    func withPublishingActor<T>(_ actor: String, action: () throws -> T) rethrows -> T {
        let previous = publishingActor; publishingActor = actor
        defer { publishingActor = previous }
        return try action()
    }
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
    /// Legacy files acquire this deterministic identity on their next ordinary
    /// save; opening/querying an editor never rewrites the user's project.
    var automationID: UUID {
        if let id = project.automationID { return id }
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let a = Array(hex)
        return UUID(uuidString: String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-" + String(a[16..<20]) + "-" + String(a[20..<32]))!
    }
    private var savedProjectDigest: String?
    private var savedProjectByteCount: Int?
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
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let data = try Data(contentsOf: url)
        let project = try JSONDecoder().decode(RecordingProject.self, from: data)
        try project.validate()
        for source in project.videoAssets where source.kind == .file {
            _ = try source.resolvedURL(in: url.deletingLastPathComponent())
        }
        let editor = ProjectEditor(project: project, url: url)
        editor.savedProjectDigest = digest(data)
        editor.savedProjectByteCount = data.count
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
    func updateDraft(_ state: EditState, at time: Double, editAliases: [UUID: UUID] = [:]) -> Bool {
        guard time.isFinite, (0...project.duration).contains(time) else {
            errorMessage = "The edit time must be inside the recording."
            return false
        }
        if let draftTime, draftTime != time, !finishDraft() { return false }
        var nextReferences = references
        do {
            for (replacement, original) in editAliases {
                guard let number = references.edits[original.uuidString],
                      nextReferences.edits[replacement.uuidString] == nil || nextReferences.edits[replacement.uuidString] == number else {
                    throw ProjectError.invalid("The edit reference could not be preserved.")
                }
                nextReferences.edits[replacement.uuidString] = number
            }
            nextReferences.register(state: state, includeCamera: project.cameraFilename != nil)
            var candidate = project
            candidate.state = state
            candidate.references = nextReferences
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
        references = nextReferences
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
        guard persist(next, operation: ProjectHistoryOperation(kind: .edit, names: [name])) else { return false }
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
        commitDocument(state: state, title: nil, name: name)
    }

    /// Registers immutable bytes/metadata and their initial occurrences as one
    /// edit. Undo removes occurrences but retains the source for Redo and reuse.
    @discardableResult
    func registerVideoSource(_ source: VideoSource, state: EditState, name: String = "Add video") -> Bool {
        registerVideoSources([source], state: state, name: name)
    }

    /// A multi-file import is one document transaction. Validate every source
    /// before publishing any of their descriptors or occurrences.
    @discardableResult
    func registerVideoSources(_ sources: [VideoSource], state: EditState, name: String = "Add videos") -> Bool {
        guard !sources.isEmpty else { return commit(state, name: name) }
        var candidate = project
        candidate.videoAssets.append(contentsOf: sources)
        candidate.state = state
        do {
            try candidate.validate()
            for source in sources where source.kind == .file {
                _ = try source.resolvedURL(in: url.deletingLastPathComponent())
            }
        } catch { errorMessage = error.localizedDescription; return false }
        guard finishDraft() else { return false }
        candidate = project
        candidate.videoAssets.append(contentsOf: sources)
        candidate.undoHistory.append(NamedEditSnapshot(name: name, state: project.state, title: project.title))
        candidate.redoHistory.removeAll()
        candidate.state = state
        return persist(candidate, operation: ProjectHistoryOperation(kind: .edit, names: [name]))
    }

    func videoSourceURL(for sourceID: UUID) throws -> URL {
        guard let source = project.videoSources.first(where: { $0.id == sourceID }) else {
            throw ProjectError.invalid("The video source is no longer registered.")
        }
        return try source.resolvedURL(in: url.deletingLastPathComponent())
    }

    /// Adding an image and its layer is one saved edit. Immutable assets remain
    /// available to every undo/redo state; no source image is written or linked.
    @discardableResult
    func addContentLayer(_ layer: ContentLayer, image: ContentImageAsset? = nil) -> Bool {
        var candidate = project
        candidate.state = editingState
        if let image { candidate.contentAssets.append(image) }
        candidate.state.contentLayers.append(layer)
        do { try candidate.validate() }
        catch { errorMessage = error.localizedDescription; return false }
        guard finishDraft() else { return false }
        var next = project
        if let image { next.contentAssets.append(image) }
        next.undoHistory.append(NamedEditSnapshot(name: "Add " + layer.kind.rawValue, state: project.state, title: project.title))
        next.redoHistory.removeAll()
        next.state.contentLayers.append(layer)
        return persist(next, operation: ProjectHistoryOperation(kind: .edit, names: ["Add " + layer.kind.rawValue]))
    }

    /// One document transaction, including an optional title, on the normal
    /// history stack. Callers validate their entire batch before reaching here.
    @discardableResult
    func commitDocument(state: EditState, title: String?, name: String) -> Bool {
        let normalized = title.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var candidate = project
        candidate.state = state
        if let normalized { candidate.title = normalized }
        do { try candidate.validate() }
        catch { errorMessage = error.localizedDescription; return false }
        guard finishDraft() else { return false }
        guard state != project.state || (normalized != nil && normalized != project.title) else { return true }
        var next = project
        next.undoHistory.append(NamedEditSnapshot(name: name, state: project.state, title: project.title))
        next.redoHistory.removeAll()
        next.state = state
        if let normalized { next.title = normalized }
        return persist(next, operation: ProjectHistoryOperation(kind: .edit, names: [name]))
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
        return persist(next, operation: ProjectHistoryOperation(kind: .edit, names: ["Rename recording"]))
    }

    @discardableResult
    func undo(count: Int = 1) -> Bool {
        guard count > 0, count <= project.undoHistory.count + (draftState == nil ? 0 : 1) else { return false }
        var next = project
        let previous = editingState
        var remaining = count
        var names: [String] = []
        if let draftState {
            // The unfinished gesture is the next stack entry, just as with
            // Command-Z. A failed write retains it and both history branches.
            next.redoHistory = [NamedEditSnapshot(name: "Edit", state: draftState, title: project.title)]
            names.append("Edit")
            remaining -= 1
        }
        for _ in 0..<remaining {
            guard let snapshot = next.undoHistory.popLast() else { return false }
            names.append(snapshot.name)
            next.redoHistory.append(NamedEditSnapshot(name: snapshot.name, state: next.state, title: next.title))
            next.state = snapshot.state
            next.title = snapshot.title
        }
        let preferredTime = draftState != nil && count == 1 ? draftTime : nil
        guard persist(next, operation: ProjectHistoryOperation(kind: .undo, names: names)) else { return false }
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
        var names: [String] = []
        for _ in 0..<count {
            guard let snapshot = next.redoHistory.popLast() else { return false }
            names.append(snapshot.name)
            next.undoHistory.append(NamedEditSnapshot(name: snapshot.name, state: next.state, title: next.title))
            next.state = snapshot.state
            next.title = snapshot.title
        }
        guard persist(next, operation: ProjectHistoryOperation(kind: .redo, names: names)) else { return false }
        navigateHistory(from: previous, to: next.state)
        return true
    }

    @discardableResult
    func save() -> Bool {
        if draftState != nil { return finishDraft() }
        return persist(project)
    }

    /// Duplicate the visible edit without saving, finishing, or cancelling any
    /// work in this editor. Originals remain adjacent shared source files.
    func duplicate(avoiding projectURLs: [URL] = []) -> ProjectEditor? {
        do {
            var snapshot = project
            snapshot.state = editingState
            snapshot.automationID = UUID()
            snapshot.undoHistory = []
            snapshot.redoHistory = []
            snapshot.references = references
            snapshot.ensureReferences()
            try snapshot.validate()
            let directory = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            let stem = url.deletingPathExtension().lastPathComponent
            let normalizedTitle = String(displayName.unicodeScalars.filter { $0.properties.generalCategory != .control })
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let title = normalizedTitle.isEmpty ? "Recording" : normalizedTitle
            // Reserve original names even when their files are currently
            // missing. A copy or its future journal must never become a source.
            var reserved = [url.lastPathComponent, recoveryURL.lastPathComponent] +
                [project.screenFilename, project.cameraFilename, project.cursorFilename, project.sceneFilename].compactMap { $0 } +
                project.videoAssets.compactMap(\.relativePath)
            // A deleted project can still own an open window and journal.
            // Its URL must not be reused for a new independent document.
            reserved += projectURLs.filter {
                $0.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == directory
            }.flatMap { [$0.lastPathComponent, $0.appendingPathExtension("recovery").lastPathComponent] }
            for index in 1...10_000 {
                let suffix = index == 1 ? " copy" : " copy \(index)"
                let filename = Self.filenamePrefix(stem, bytes: 255 - ".recovery".utf8.count - suffix.utf8.count - ".framethrower".utf8.count)
                    + suffix + ".framethrower"
                let destination = directory.appendingPathComponent(filename)
                let journal = destination.appendingPathExtension("recovery")
                guard !reserved.contains(where: {
                    filename.compare($0, options: .caseInsensitive) == .orderedSame ||
                    journal.lastPathComponent.compare($0, options: .caseInsensitive) == .orderedSame
                }), (try? FileManager.default.attributesOfItem(atPath: journal.path)) == nil,
                (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil else { continue }
                snapshot.title = String(title.prefix(256 - suffix.count)).trimmingCharacters(in: .whitespaces) + suffix
                try RecordingProject.validateTitle(snapshot.title)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                do { try Self.publishNewProject(data, at: destination) }
                catch ProjectCreationError.destinationExists { continue }
                let copy = ProjectEditor(project: snapshot, url: destination)
                copy.savedProjectDigest = Self.digest(data)
                copy.savedProjectByteCount = data.count
                return copy
            }
            throw ProjectError.invalid("Too many copies already exist beside this recording. Rename or move an older copy, then try again.")
        } catch {
            errorMessage = "The recording could not be duplicated. " + error.localizedDescription
            return nil
        }
    }

    private static func filenamePrefix(_ value: String, bytes maximum: Int) -> String {
        var result = ""
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= maximum else { break }
            result.append(character)
            bytes += count
        }
        return result.isEmpty || result == "." || result == ".." ? "Recording" : result
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
        let originals = [url] + [project.screenFilename, project.cameraFilename, project.cursorFilename, project.sceneFilename]
            .compactMap { $0 }.map { mediaURL(for: $0) } + project.videoAssets.compactMap {
                $0.relativePath.map { mediaURL(for: $0) }
            }
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
        let oldSpeed = Dictionary(uniqueKeysWithValues: previous.speedKeyframes.map { ($0.id, $0) })
        let newSpeed = Dictionary(uniqueKeysWithValues: next.speedKeyframes.map { ($0.id, $0) })
        for id in Set(oldSpeed.keys).union(newSpeed.keys) where oldSpeed[id] != newSpeed[id] {
            if let old = oldSpeed[id] { times.append(old.time) }
            if let new = newSpeed[id] { times.append(new.time) }
        }
        let oldAnchors = Dictionary(uniqueKeysWithValues: previous.editAnchors.map { ($0.id, $0) })
        let newAnchors = Dictionary(uniqueKeysWithValues: next.editAnchors.map { ($0.id, $0) })
        for id in Set(oldAnchors.keys).union(newAnchors.keys) where oldAnchors[id] != newAnchors[id] {
            if let old = oldAnchors[id] { times.append(old.time) }
            if let new = newAnchors[id] { times.append(new.time) }
        }
        let oldLayers = Dictionary(uniqueKeysWithValues: previous.contentLayers.map { ($0.id, $0) })
        let newLayers = Dictionary(uniqueKeysWithValues: next.contentLayers.map { ($0.id, $0) })
        for id in Set(oldLayers.keys).union(newLayers.keys) where oldLayers[id] != newLayers[id] {
            if let layer = newLayers[id] ?? oldLayers[id] { times.append(layer.start) }
        }
        let oldVideos = Dictionary(uniqueKeysWithValues: project.effectiveVideoLayers(in: previous).flatMap(\.clips).map { ($0.id, $0) })
        let newVideos = Dictionary(uniqueKeysWithValues: project.effectiveVideoLayers(in: next).flatMap(\.clips).map { ($0.id, $0) })
        for id in Set(oldVideos.keys).union(newVideos.keys) where oldVideos[id] != newVideos[id] {
            if let clip = newVideos[id] ?? oldVideos[id] { times.append(clip.start) }
        }
        historyNavigationTime = preferredTime ?? times.min()
        if historyNavigationTime != nil { historyNavigationToken = UUID() }
    }

    private func persist(_ candidate: RecordingProject, operation: ProjectHistoryOperation? = nil) -> Bool {
        var candidate = candidate
        if candidate.automationID == nil { candidate.automationID = automationID }
        do {
            try candidate.references.merge(references)
            candidate.ensureReferences(in: draftState)
            try candidate.validate()
            let target = url.standardizedFileURL.resolvingSymlinksInPath()
            for filename in [candidate.screenFilename, candidate.cameraFilename, candidate.cursorFilename, candidate.sceneFilename].compactMap({ $0 }) {
                guard mediaURL(for: filename).standardizedFileURL.resolvingSymlinksInPath() != target else {
                    throw ProjectError.invalid("The project file cannot replace original media.")
                }
            }
            for source in candidate.videoAssets where source.kind == .file {
                let sourceURL = try source.resolvedURL(in: url.deletingLastPathComponent())
                guard sourceURL != target else {
                    throw ProjectError.invalid("The project file cannot replace original video media.")
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(candidate)
            try writeProject(data)
            do {
                publishingHistoryOperation = operation
                defer { publishingHistoryOperation = nil }
                project = candidate
            }
            references = candidate.references
            savedProjectDigest = Self.digest(data)
            savedProjectByteCount = data.count
            errorMessage = clearRecovery() ?? protectedRecoveryNotice
            return true
        } catch {
            let message = error.localizedDescription
            if draftState != nil { _ = flushRecovery() }
            errorMessage = message
            return false
        }
    }

    /// An open editor owns only the exact saved version it read or wrote.
    /// Missing or externally replaced projects must not become silent resets
    /// of another editor's changes, even for Rename, Undo, or an ordinary Save.
    private func writeProject(_ data: Data) throws {
        if let savedProjectDigest {
            guard let savedProjectByteCount,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == Int64(savedProjectByteCount),
                  let existing = try? Data(contentsOf: url), Self.digest(existing) == savedProjectDigest else {
                throw ProjectError.invalid("The saved project changed or is unavailable at \(url.path). It was not overwritten. Restore the version opened in this editor, then try again.")
            }
            try data.write(to: url, options: .atomic)
        } else {
            // A new recording has no saved baseline. Publish a staged sibling
            // exclusively, so even a destination appearing during the write
            // cannot be replaced by this first save.
            do { try Self.publishNewProject(data, at: url) }
            catch ProjectCreationError.destinationExists {
                throw ProjectError.invalid("A file or folder already exists at \(url.path). Open the existing project or choose a different project location.")
            }
        }
    }

    private enum ProjectCreationError: Error { case destinationExists }

    private static func publishNewProject(_ data: Data, at url: URL) throws {
        let staged = url.deletingLastPathComponent().appendingPathComponent(".framethrower-save-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .withoutOverwriting)
        do { try FileManager.default.linkItem(at: staged, to: url) }
        catch {
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil { throw ProjectCreationError.destinationExists }
            throw error
        }
    }
}

/// Shared source-space geometry for drawing and applying video crops.
enum CropGeometry {
    static let full = EditorRegionRect(x: 0, y: 0, width: 1, height: 1)

    /// Crop editing uses whole source pixels. Keep normalized storage, but snap
    /// both the size and position before displaying or applying an authored crop.
    static func pixelAligned(_ rect: EditorRegionRect, in size: CGSize) -> EditorRegionRect {
        guard rect.isValid, size.width.isFinite, size.height.isFinite,
              size.width >= 2, size.height >= 2 else { return full }
        let r = pixels(rect, in: size)
        let width = min(size.width.rounded(.down), max(2, r.width.rounded()))
        let height = min(size.height.rounded(.down), max(2, r.height.rounded()))
        return normalized(CGRect(x: min(size.width.rounded(.down) - width, max(0, r.minX.rounded())),
                                 y: min(size.height.rounded(.down) - height, max(0, r.minY.rounded())),
                                 width: width, height: height), in: size)
    }

    static func pixels(_ rect: EditorRegionRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.x * size.width, y: rect.y * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    static func normalized(_ rect: CGRect, in size: CGSize) -> EditorRegionRect {
        guard size.width > 0, size.height > 0 else { return full }
        let r = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard !r.isNull, r.width > 0, r.height > 0 else { return full }
        let x = max(0, min(1, r.minX / size.width)), y = max(0, min(1, r.minY / size.height))
        return EditorRegionRect(x: x, y: y, width: min(1 - x, r.width / size.width),
                                height: min(1 - y, r.height / size.height))
    }

    static func fitted(_ rect: EditorRegionRect, ratio: Double?, source: CGSize) -> EditorRegionRect {
        guard let ratio, ratio.isFinite, ratio > 0 else { return rect }
        let r = pixels(rect, in: source)
        let w = min(r.width, r.height * ratio), h = min(r.height, r.width / ratio)
        return normalized(CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), in: source)
    }

    /// The second point is clamped to the source before locking the aspect.
    static func drawn(from start: CGPoint, to end: CGPoint, source: CGSize, ratio: Double?) -> EditorRegionRect? {
        guard source.width > 0, source.height > 0 else { return nil }
        let a = CGPoint(x: min(source.width, max(0, start.x)), y: min(source.height, max(0, start.y)))
        let b = CGPoint(x: min(source.width, max(0, end.x)), y: min(source.height, max(0, end.y)))
        var w = abs(b.x - a.x), h = abs(b.y - a.y)
        if let ratio, ratio.isFinite, ratio > 0 {
            let maxW = b.x >= a.x ? source.width - a.x : a.x
            let maxH = b.y >= a.y ? source.height - a.y : a.y
            w = min(max(w, h * ratio), maxW, maxH * ratio); h = w / ratio
        }
        guard w >= 2, h >= 2 else { return nil }
        return normalized(CGRect(x: b.x >= a.x ? a.x : a.x - w,
                                 y: b.y >= a.y ? a.y : a.y - h, width: w, height: h), in: source)
    }

    /// Handles run clockwise from the top-left; odd handles are edge centers.
    static func resized(_ rect: EditorRegionRect, handle: Int, to point: CGPoint, source: CGSize, ratio: Double?) -> EditorRegionRect? {
        let r = pixels(rect, in: source)
        if handle % 2 == 0 {
            let opposite = CGPoint(x: handle == 0 || handle == 6 ? r.maxX : r.minX,
                                   y: handle == 0 || handle == 2 ? r.maxY : r.minY)
            return drawn(from: opposite, to: point, source: source, ratio: ratio)
        }
        var target = r
        if handle == 1 || handle == 5 {
            let anchor = handle == 1 ? r.maxY : r.minY
            var h = min(source.height, max(0, point.y)) - anchor
            let sign = h < 0 ? -1.0 : 1.0
            h = abs(h)
            if let ratio, ratio.isFinite, ratio > 0 {
                h = min(h, 2 * min(r.midX, source.width - r.midX) / ratio)
                target.size.width = h * ratio; target.origin.x = r.midX - target.width / 2
            }
            target.origin.y = sign < 0 ? anchor - h : anchor; target.size.height = h
        } else {
            let anchor = handle == 7 ? r.maxX : r.minX
            var w = min(source.width, max(0, point.x)) - anchor
            let sign = w < 0 ? -1.0 : 1.0
            w = abs(w)
            if let ratio, ratio.isFinite, ratio > 0 {
                w = min(w, 2 * min(r.midY, source.height - r.midY) * ratio)
                target.size.height = w / ratio; target.origin.y = r.midY - target.height / 2
            }
            target.origin.x = sign < 0 ? anchor - w : anchor; target.size.width = w
        }
        guard target.width >= 2, target.height >= 2 else { return nil }
        return normalized(target, in: source)
    }

    static func moved(_ rect: EditorRegionRect, by delta: CGSize) -> EditorRegionRect {
        var r = rect
        r.x = min(1 - r.width, max(0, r.x + delta.width))
        r.y = min(1 - r.height, max(0, r.y + delta.height))
        return r
    }

    static func interpolate(_ a: EditorRegionRect?, _ b: EditorRegionRect?, progress: Double) -> EditorRegionRect? {
        guard a != nil || b != nil else { return nil }
        let first = a ?? full, last = b ?? full
        func blend(_ x: Double, _ y: Double) -> Double { x + (y - x) * progress }
        let x = blend(first.x, last.x), y = blend(first.y, last.y)
        return EditorRegionRect(x: x, y: y, width: min(1 - x, blend(first.width, last.width)),
                                height: min(1 - y, blend(first.height, last.height)))
    }
}
