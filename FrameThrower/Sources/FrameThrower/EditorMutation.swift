import Foundation

/// All points use a top-left origin. For a screen viewport this is its source
/// focal point; for an overlay it is the UI's fraction of available travel.
struct EditorUnitPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    private enum CodingKeys: String, CodingKey, CaseIterable { case x, y }
    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y)
    }
    var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

enum EditorRectAnchor: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var point: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .top: CGPoint(x: 0.5, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .left: CGPoint(x: 0, y: 0.5)
        case .center: CGPoint(x: 0.5, y: 0.5)
        case .right: CGPoint(x: 1, y: 0.5)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .bottom: CGPoint(x: 0.5, y: 1)
        case .bottomRight: CGPoint(x: 1, y: 1)
        }
    }
    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
}

enum EditorAlignmentAxes: String, Codable, Sendable {
    case horizontal, vertical, both
    var horizontal: Bool { self != .vertical }
    var vertical: Bool { self != .horizontal }
}

enum EditorAlignmentScale: Codable, Equatable, Sendable {
    case preserve
    case absolute(Double)
    /// Contain the raw guide at supported zoom, without implicit padding.
    case fitRegion
    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, scale }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        switch try c.decode(String.self, forKey: .kind) {
        case "preserve": try c.only([.kind]); self = .preserve
        case "fitRegion": try c.only([.kind]); self = .fitRegion
        case "absolute": try c.only([.kind, .scale]); self = .absolute(try c.decode(Double.self, forKey: .scale))
        default: throw EditorMutationError.invalid("Unknown alignment scale policy.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preserve: try c.encode("preserve", forKey: .kind)
        case .fitRegion: try c.encode("fitRegion", forKey: .kind)
        case let .absolute(scale): try c.encode("absolute", forKey: .kind); try c.encode(scale, forKey: .scale)
        }
    }
}

struct EditorMutationTiming: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var transition: PIPTransition = .smooth
    var easeIn: Double? = nil
    var easeOut: Double? = nil
    init(start: Double, end: Double, transition: PIPTransition = .smooth, easeIn: Double? = nil, easeOut: Double? = nil) {
        self.start = start; self.end = end; self.transition = transition; self.easeIn = easeIn; self.easeOut = easeOut
    }
    static func at(_ time: Double) -> Self { Self(start: time, end: time, transition: .jump) }
    private enum CodingKeys: String, CodingKey, CaseIterable { case start, end, transition, easeIn, easeOut }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
        transition = try c.optional(PIPTransition.self, .transition) ?? .smooth
        easeIn = try c.optional(Double.self, .easeIn); easeOut = try c.optional(Double.self, .easeOut)
    }
    var motion: EditorCommandMotion {
        EditorCommandMotion(transition: transition, duration: transition == .smooth ? end - start : 0.4, easeIn: easeIn, easeOut: easeOut)
    }
    func validate(duration: Double) throws {
        guard start.isFinite, end.isFinite, duration.isFinite, start >= 0, start <= end, end < duration,
              transition == .smooth ? end > start : start == end else {
            throw EditorMutationError.invalid("Use an exact source interval before the recording's end; a jump has one timestamp.")
        }
        try motion.validate()
    }
}

struct EditorCameraOverlayPatch: Codable, Equatable, Sendable {
    /// Fractions of available final-canvas travel, exactly as PIPPlacement.x/y.
    var position: EditorUnitPoint? = nil
    /// Fraction of output width (0.12...0.5), not camera-source magnification.
    var scale: Double? = nil
    var shape: PIPShape? = nil
    var aspectRatio: Double? = nil
    var visible: Bool? = nil
    private enum CodingKeys: String, CodingKey, CaseIterable { case position, scale, shape, aspectRatio, visible }
    init(position: EditorUnitPoint? = nil, scale: Double? = nil, shape: PIPShape? = nil, aspectRatio: Double? = nil, visible: Bool? = nil) {
        self.position = position; self.scale = scale; self.shape = shape; self.aspectRatio = aspectRatio; self.visible = visible
    }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        position = try c.optional(EditorUnitPoint.self, .position); scale = try c.optional(Double.self, .scale)
        shape = try c.optional(PIPShape.self, .shape); aspectRatio = try c.optional(Double.self, .aspectRatio); visible = try c.optional(Bool.self, .visible)
    }
    var isEmpty: Bool { position == nil && scale == nil && shape == nil && aspectRatio == nil && visible == nil }
}

struct EditorCameraSourcePatch: Codable, Equatable, Sendable {
    /// Camera-source crop travel; it never moves/resizes the output overlay.
    var crop: PIPCrop? = nil
    var sourceZoom: Double? = nil
    init(crop: PIPCrop? = nil, sourceZoom: Double? = nil) { self.crop = crop; self.sourceZoom = sourceZoom }
    private enum CodingKeys: String, CodingKey, CaseIterable { case crop, sourceZoom }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        if c.contains(.crop) {
            let point = try c.decode(EditorUnitPoint.self, forKey: .crop)
            crop = PIPCrop(x: point.x, y: point.y)
        }
        sourceZoom = try c.optional(Double.self, .sourceZoom)
    }
    var isEmpty: Bool { crop == nil && sourceZoom == nil }
}

struct EditorPointerPatch: Codable, Equatable, Sendable {
    var visible: Bool? = nil
    var size: Double? = nil
    var smoothing: Double? = nil
    var clickHighlight: Bool? = nil
    init(visible: Bool? = nil, size: Double? = nil, smoothing: Double? = nil, clickHighlight: Bool? = nil) {
        self.visible = visible; self.size = size; self.smoothing = smoothing; self.clickHighlight = clickHighlight
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case visible, size, smoothing, clickHighlight }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        visible = try c.optional(Bool.self, .visible); size = try c.optional(Double.self, .size)
        smoothing = try c.optional(Double.self, .smoothing); clickHighlight = try c.optional(Bool.self, .clickHighlight)
    }
    var isEmpty: Bool { visible == nil && size == nil && smoothing == nil && clickHighlight == nil }
}

struct EditorAudioPatch: Codable, Equatable, Sendable {
    var isMuted: Bool? = nil
    var volume: Double? = nil
    var fadeIn: Double? = nil
    var fadeOut: Double? = nil
    init(isMuted: Bool? = nil, volume: Double? = nil, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        self.isMuted = isMuted; self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case isMuted, volume, fadeIn, fadeOut }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        isMuted = try c.optional(Bool.self, .isMuted); volume = try c.optional(Double.self, .volume)
        fadeIn = try c.optional(Double.self, .fadeIn); fadeOut = try c.optional(Double.self, .fadeOut)
    }
    var isEmpty: Bool { isMuted == nil && volume == nil && fadeIn == nil && fadeOut == nil }
}

struct EditorCanvasPatch: Codable, Equatable, Sendable {
    var aspect: CanvasAspect? = nil
    var padding: Double? = nil
    var cornerRadius: Double? = nil
    var background: CanvasColor? = nil
    init(aspect: CanvasAspect? = nil, padding: Double? = nil, cornerRadius: Double? = nil, background: CanvasColor? = nil) {
        self.aspect = aspect; self.padding = padding; self.cornerRadius = cornerRadius; self.background = background
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case aspect, padding, cornerRadius, background }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        aspect = try c.optional(CanvasAspect.self, .aspect); padding = try c.optional(Double.self, .padding)
        cornerRadius = try c.optional(Double.self, .cornerRadius)
        if c.contains(.background) {
            let rgb = try mutationContainer(EditorRGBKey.self, c.superDecoder(forKey: .background))
            background = CanvasColor(red: try rgb.decode(Double.self, forKey: .red), green: try rgb.decode(Double.self, forKey: .green), blue: try rgb.decode(Double.self, forKey: .blue))
        }
    }
    var isEmpty: Bool { aspect == nil && padding == nil && cornerRadius == nil && background == nil }
}

/// Host-only verified recording geometry. Never decoded from a model command.
struct EditorMutationGeometry: Equatable, Sendable {
    var sourceSize: CGSize
    var cameraAspect: Double?
}

enum EditorMutationLane: String, Codable, Sendable { case screen, camera, pointer, audio, canvas, trim }
enum EditorMutationSubject: String, Codable, Sendable { case screenViewport, cameraOverlay, cameraSource }

struct EditorMutationEffect: Equatable, Sendable {
    var lane: EditorMutationLane
    var start: Double
    var end: Double
    var subject: EditorMutationSubject? = nil
}

struct EditorMutationConflict: Equatable, Sendable {
    var lane: EditorMutationLane
    var componentID: UUID
    var start: Double
    var end: Double
}

enum EditorMutationError: LocalizedError {
    case invalid(String)
    case geometryUnavailable
    case unreachableAlignment
    case conflicts([EditorMutationConflict])
    var errorDescription: String? {
        switch self {
        case let .invalid(message): message
        case .geometryUnavailable: "Exact camera-to-box alignment requires verified original screen and camera geometry. No source file was opened."
        case .unreachableAlignment: "That exact alignment cannot fit inside the recording at the requested size. Choose another zoom or alignment; nothing was changed."
        case let .conflicts(items): "The requested movement overlaps \(items.count) existing \(items.first?.lane.rawValue ?? "") animation(s). Resolve those movements explicitly before applying this interval."
        }
    }
}

/// Transport-independent edit vocabulary shared by UI, Director and RPC. Units
/// match the existing models; no command opens media, files, or a live desktop.
enum EditorMutation: Codable, Equatable, Sendable {
    case panScreen(center: EditorUnitPoint, timing: EditorMutationTiming)
    case zoomScreen(scale: Double, center: EditorUnitPoint?, timing: EditorMutationTiming)
    case alignScreen(regionID: UUID, subjectAnchor: EditorRectAnchor, targetAnchor: EditorRectAnchor,
                     axes: EditorAlignmentAxes, scalePolicy: EditorAlignmentScale, timing: EditorMutationTiming)
    case cameraOverlay(EditorCameraOverlayPatch, timing: EditorMutationTiming)
    case alignCameraOverlay(regionID: UUID, subjectAnchor: EditorRectAnchor, targetAnchor: EditorRectAnchor,
                            axes: EditorAlignmentAxes, timing: EditorMutationTiming)
    case cameraSource(EditorCameraSourcePatch, timing: EditorMutationTiming)
    case pointer(EditorPointerPatch)
    case audio(EditorAudioPatch)
    case canvas(EditorCanvasPatch)
    case trim(start: Double, end: Double)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operation, center, timing, scale, regionID, subjectAnchor, targetAnchor, axes, scalePolicy, patch, start, end
    }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        switch try c.decode(String.self, forKey: .operation) {
        case "panScreen":
            try c.only([.operation, .center, .timing]); self = .panScreen(center: try c.decode(EditorUnitPoint.self, forKey: .center), timing: try c.decode(EditorMutationTiming.self, forKey: .timing))
        case "zoomScreen":
            try c.only([.operation, .scale, .center, .timing]); self = .zoomScreen(scale: try c.decode(Double.self, forKey: .scale), center: try c.optional(EditorUnitPoint.self, .center), timing: try c.decode(EditorMutationTiming.self, forKey: .timing))
        case "alignScreen":
            try c.only([.operation, .regionID, .subjectAnchor, .targetAnchor, .axes, .scalePolicy, .timing])
            self = .alignScreen(regionID: try c.decode(UUID.self, forKey: .regionID), subjectAnchor: try c.decode(EditorRectAnchor.self, forKey: .subjectAnchor),
                targetAnchor: try c.decode(EditorRectAnchor.self, forKey: .targetAnchor), axes: try c.decode(EditorAlignmentAxes.self, forKey: .axes),
                scalePolicy: try c.decode(EditorAlignmentScale.self, forKey: .scalePolicy), timing: try c.decode(EditorMutationTiming.self, forKey: .timing))
        case "cameraOverlay":
            try c.only([.operation, .patch, .timing]); self = .cameraOverlay(try c.decode(EditorCameraOverlayPatch.self, forKey: .patch), timing: try c.decode(EditorMutationTiming.self, forKey: .timing))
        case "alignCameraOverlay":
            try c.only([.operation, .regionID, .subjectAnchor, .targetAnchor, .axes, .timing])
            self = .alignCameraOverlay(regionID: try c.decode(UUID.self, forKey: .regionID), subjectAnchor: try c.decode(EditorRectAnchor.self, forKey: .subjectAnchor),
                targetAnchor: try c.decode(EditorRectAnchor.self, forKey: .targetAnchor), axes: try c.decode(EditorAlignmentAxes.self, forKey: .axes), timing: try c.decode(EditorMutationTiming.self, forKey: .timing))
        case "cameraSource":
            try c.only([.operation, .patch, .timing]); self = .cameraSource(try c.decode(EditorCameraSourcePatch.self, forKey: .patch), timing: try c.decode(EditorMutationTiming.self, forKey: .timing))
        case "pointer": try c.only([.operation, .patch]); self = .pointer(try c.decode(EditorPointerPatch.self, forKey: .patch))
        case "audio": try c.only([.operation, .patch]); self = .audio(try c.decode(EditorAudioPatch.self, forKey: .patch))
        case "canvas": try c.only([.operation, .patch]); self = .canvas(try c.decode(EditorCanvasPatch.self, forKey: .patch))
        case "trim": try c.only([.operation, .start, .end]); self = .trim(start: try c.decode(Double.self, forKey: .start), end: try c.decode(Double.self, forKey: .end))
        default: throw EditorMutationError.invalid("The requested mutation operation is not supported.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .panScreen(center, timing):
            try c.encode("panScreen", forKey: .operation); try c.encode(center, forKey: .center); try c.encode(timing, forKey: .timing)
        case let .zoomScreen(scale, center, timing):
            try c.encode("zoomScreen", forKey: .operation); try c.encode(scale, forKey: .scale); try c.encodeIfPresent(center, forKey: .center); try c.encode(timing, forKey: .timing)
        case let .alignScreen(id, own, target, axes, scale, timing):
            try c.encode("alignScreen", forKey: .operation); try c.encode(id, forKey: .regionID); try c.encode(own, forKey: .subjectAnchor); try c.encode(target, forKey: .targetAnchor)
            try c.encode(axes, forKey: .axes); try c.encode(scale, forKey: .scalePolicy); try c.encode(timing, forKey: .timing)
        case let .cameraOverlay(patch, timing):
            try c.encode("cameraOverlay", forKey: .operation); try c.encode(patch, forKey: .patch); try c.encode(timing, forKey: .timing)
        case let .alignCameraOverlay(id, own, target, axes, timing):
            try c.encode("alignCameraOverlay", forKey: .operation); try c.encode(id, forKey: .regionID); try c.encode(own, forKey: .subjectAnchor); try c.encode(target, forKey: .targetAnchor)
            try c.encode(axes, forKey: .axes); try c.encode(timing, forKey: .timing)
        case let .cameraSource(patch, timing):
            try c.encode("cameraSource", forKey: .operation); try c.encode(patch, forKey: .patch); try c.encode(timing, forKey: .timing)
        case let .pointer(patch): try c.encode("pointer", forKey: .operation); try c.encode(patch, forKey: .patch)
        case let .audio(patch): try c.encode("audio", forKey: .operation); try c.encode(patch, forKey: .patch)
        case let .canvas(patch): try c.encode("canvas", forKey: .operation); try c.encode(patch, forKey: .patch)
        case let .trim(start, end): try c.encode("trim", forKey: .operation); try c.encode(start, forKey: .start); try c.encode(end, forKey: .end)
        }
    }

    var timing: EditorMutationTiming? {
        switch self {
        case let .panScreen(_, value), let .zoomScreen(_, _, value), let .alignScreen(_, _, _, _, _, value),
             let .cameraOverlay(_, value), let .alignCameraOverlay(_, _, _, _, value), let .cameraSource(_, value): value
        default: nil
        }
    }
    var lane: EditorMutationLane {
        switch self {
        case .panScreen, .zoomScreen, .alignScreen: .screen
        case .cameraOverlay, .alignCameraOverlay, .cameraSource: .camera
        case .pointer: .pointer
        case .audio: .audio
        case .canvas: .canvas
        case .trim: .trim
        }
    }
    func effects(duration: Double) -> [EditorMutationEffect] {
        let subject: EditorMutationSubject?
        switch self {
        case .panScreen, .zoomScreen, .alignScreen: subject = .screenViewport
        case .cameraOverlay, .alignCameraOverlay: subject = .cameraOverlay
        case .cameraSource: subject = .cameraSource
        default: subject = nil
        }
        return [EditorMutationEffect(lane: lane, start: timing?.start ?? 0, end: timing?.end ?? duration, subject: subject)]
    }

    /// New motion never silently crosses/replaces an existing same-lane point.
    /// The fixed time-zero camera appearance is not an incoming animation.
    func conflicts(in state: EditState) -> [EditorMutationConflict] {
        guard let timing else { return [] }
        var result: [EditorMutationConflict] = []
        var previous = 0.0
        func check(id: UUID, time: Double, transition: PIPTransition, duration: Double) {
            defer { previous = time }
            guard time > 0 else { return }
            let begins = transition == .smooth ? max(previous, time - duration) : time
            let intersects = timing.start == timing.end
                ? (begins < timing.end && time >= timing.end) || abs(time - timing.end) < 0.000_001
                : time > timing.start + 0.000_001 && (begins < timing.end - 0.000_001 || abs(time - timing.end) < 0.000_001)
            if intersects { result.append(EditorMutationConflict(lane: lane, componentID: id, start: begins, end: time)) }
        }
        if lane == .screen {
            for point in state.zoomKeyframes { check(id: point.id, time: point.time, transition: point.transition, duration: point.duration) }
        } else if lane == .camera {
            for point in state.pipKeyframes { check(id: point.id, time: point.time, transition: point.transition, duration: point.duration) }
        }
        return result
    }

    /// Atomic even for direct callers: errors leave the inout state untouched.
    func apply(to state: inout EditState, project: RecordingProject, geometry: EditorMutationGeometry? = nil) throws {
        var next = state
        try applyUnchecked(to: &next, project: project, geometry: geometry)
        var candidate = project; candidate.state = next
        try candidate.validate()
        state = next
    }

    private func applyUnchecked(to state: inout EditState, project: RecordingProject, geometry: EditorMutationGeometry?) throws {
        if let timing { try timing.validate(duration: project.duration) }
        switch self {
        case let .panScreen(center, timing):
            guard center.isValid else { throw EditorMutationError.invalid("Use a normalized source focal point inside the recording.") }
            let origin = state.zoom(at: timing.start)
            let desired = ZoomPlacement(scale: origin.scale, x: center.x, y: center.y)
            try exact(desired)
            try screen(desired, timing: timing, regionID: nil, state: &state)
        case let .zoomScreen(scale, center, timing):
            guard scale.isFinite, (1...3).contains(scale), center?.isValid ?? true else { throw EditorMutationError.invalid("Screen zoom must be between 1× and 3× with a valid source focal point.") }
            let baseline = state.zoom(at: timing.start)
            let desired = ZoomPlacement(scale: scale, x: center?.x ?? baseline.x, y: center?.y ?? baseline.y)
            if center != nil { try exact(desired) }
            try screen(desired.clamped, timing: timing, regionID: nil, state: &state)
        case let .alignScreen(id, own, target, axes, policy, timing):
            let guide = try region(id, in: state)
            let baseline = state.zoom(at: timing.start)
            let scale: Double
            switch policy {
            case .preserve: scale = baseline.scale
            case let .absolute(value): scale = value
            case .fitRegion: scale = min(3, max(1, 1 / max(guide.rect.width, guide.rect.height)))
            }
            guard scale.isFinite, (1...3).contains(scale) else { throw EditorMutationError.invalid("Screen alignment zoom must be between 1× and 3×.") }
            let destination = target.point(in: guide.rect.cgRect), size = 1 / scale
            let base = ZoomPlacement(scale: scale, x: baseline.x, y: baseline.y).clamped.viewport(in: CGSize(width: 1, height: 1))
            let x = axes.horizontal ? destination.x - own.point.x * size : base.minX
            let y = axes.vertical ? destination.y - own.point.y * size : base.minY
            let desired = ZoomPlacement(scale: scale, x: x + size / 2, y: y + size / 2)
            try exact(desired)
            try screen(desired, timing: timing, regionID: id, state: &state)
        case let .cameraOverlay(patch, timing):
            try requireCamera(project)
            guard !patch.isEmpty, patch.position?.isValid ?? true else { throw EditorMutationError.invalid("Supply at least one valid camera overlay property.") }
            var target = state.placement(at: timing.start)
            if let position = patch.position { target.x = position.x; target.y = position.y }
            if let value = patch.scale { target.scale = value }
            if let value = patch.shape { target.shape = value }
            if let value = patch.aspectRatio { target.aspectRatio = value }
            if let value = patch.visible { target.visible = value }
            try camera(target, timing: timing, state: &state)
        case let .cameraSource(patch, timing):
            try requireCamera(project)
            guard !patch.isEmpty else { throw EditorMutationError.invalid("Supply a camera crop or source zoom.") }
            var target = state.placement(at: timing.start)
            if let value = patch.crop { target.crop = value }
            if let value = patch.sourceZoom { target.sourceZoom = value }
            try camera(target, timing: timing, state: &state)
        case let .alignCameraOverlay(id, own, targetAnchor, axes, timing):
            try requireCamera(project)
            guard let geometry, geometry.sourceSize.width.isFinite, geometry.sourceSize.height.isFinite,
                  geometry.sourceSize.width > 0, geometry.sourceSize.height > 0,
                  geometry.sourceSize.width <= 32768, geometry.sourceSize.height <= 32768 else { throw EditorMutationError.geometryUnavailable }
            var target = state.placement(at: timing.start)
            let aspect: Double
            if target.shape == .original {
                guard let value = geometry.cameraAspect, value.isFinite, value > 0 else { throw EditorMutationError.geometryUnavailable }
                aspect = value
            } else { aspect = geometry.cameraAspect ?? 1 }
            let presentation = PresentationGeometry(sourceSize: geometry.sourceSize, presentation: state.presentation)
            let output = CGRect(origin: .zero, size: presentation.outputSize)
            let guide = try region(id, in: state)
            let point = targetAnchor.point(in: guide.rect.cgRect)
            let viewport = state.zoom(at: timing.end).viewport(in: CGSize(width: 1, height: 1))
            let destination = CGPoint(x: presentation.contentRect.minX + (point.x - viewport.minX) / viewport.width * presentation.contentRect.width,
                y: presentation.contentRect.minY + (point.y - viewport.minY) / viewport.height * presentation.contentRect.height)
            let frame = target.frame(in: output.size, cameraAspect: aspect)
            let x = axes.horizontal ? destination.x - own.point.x * frame.width : frame.minX
            let y = axes.vertical ? destination.y - own.point.y * frame.height : frame.minY
            guard x >= -0.000_000_001, y >= -0.000_000_001,
                  x + frame.width <= output.width + 0.000_000_001, y + frame.height <= output.height + 0.000_000_001 else { throw EditorMutationError.unreachableAlignment }
            target.x = min(1, max(0, x / (output.width - frame.width))); target.y = min(1, max(0, y / (output.height - frame.height)))
            let resolved = target.frame(in: output.size, cameraAspect: aspect)
            guard abs(resolved.minX - x) < 0.000_000_1, abs(resolved.minY - y) < 0.000_000_1 else { throw EditorMutationError.unreachableAlignment }
            try camera(target, timing: timing, state: &state)
        case let .pointer(patch):
            guard !patch.isEmpty else { throw EditorMutationError.invalid("Supply at least one pointer style property.") }
            if let value = patch.visible { state.cursorStyle.visible = value }
            if let value = patch.size { state.cursorStyle.size = value }
            if let value = patch.smoothing { state.cursorStyle.smoothing = value }
            if let value = patch.clickHighlight { state.cursorStyle.clickHighlight = value }
        case let .audio(patch):
            guard !patch.isEmpty else { throw EditorMutationError.invalid("Supply at least one audio property.") }
            if let value = patch.isMuted { state.audio.isMuted = value }
            if let value = patch.volume { state.audio.volume = value }
            if let value = patch.fadeIn { state.audio.fadeIn = value }
            if let value = patch.fadeOut { state.audio.fadeOut = value }
        case let .canvas(patch):
            guard !patch.isEmpty else { throw EditorMutationError.invalid("Supply at least one canvas property.") }
            if let value = patch.aspect { state.presentation.aspect = value }
            if let value = patch.padding { state.presentation.padding = value }
            if let value = patch.cornerRadius { state.presentation.cornerRadius = value }
            if let value = patch.background { state.presentation.background = value }
        case let .trim(start, end): state.trimStart = start; state.trimEnd = end
        }
    }

    private func region(_ id: UUID, in state: EditState) throws -> EditorRegion {
        guard let region = state.regions.first(where: { $0.id == id }) else { throw EditorMutationError.invalid("That reference box no longer exists.") }
        return region
    }
    private func requireCamera(_ project: RecordingProject) throws {
        guard project.cameraFilename != nil else { throw EditorMutationError.invalid("This recording has no camera source.") }
    }
    private func exact(_ desired: ZoomPlacement) throws {
        let actual = desired.clamped
        guard abs(desired.x - actual.x) < 0.000_000_001, abs(desired.y - actual.y) < 0.000_000_001 else { throw EditorMutationError.unreachableAlignment }
    }
    private func screen(_ target: ZoomPlacement, timing: EditorMutationTiming, regionID: UUID?, state: inout EditState) throws {
        let baseline = state.zoom(at: timing.start)
        guard target != baseline else { return }
        let overlaps = conflicts(in: state)
        guard overlaps.isEmpty else { throw EditorMutationError.conflicts(overlaps) }
        if timing.transition == .smooth {
            if !state.zoomKeyframes.contains(where: { abs($0.time - timing.start) < 0.000_001 }) {
                let prior = state.zoomKeyframes.last { $0.time <= timing.start }
                let source = prior?.placement.clamped == baseline ? prior?.sourceRegionID : nil
                state.zoomKeyframes.append(ZoomKeyframe(time: timing.start, scale: baseline.scale, x: baseline.x, y: baseline.y,
                    transition: .jump, sourceRegionID: source))
            }
        }
        let existing = state.zoomKeyframes.first { abs($0.time - timing.end) < 0.000_001 }
        state.zoomKeyframes.removeAll { abs($0.time - timing.end) < 0.000_001 }
        let motion = timing.motion
        state.zoomKeyframes.append(ZoomKeyframe(id: existing?.id ?? UUID(), time: existing?.time ?? timing.end,
            scale: target.scale, x: target.x, y: target.y, transition: motion.transition, duration: motion.duration,
            easeIn: motion.easeIn, easeOut: motion.easeOut, sourceRegionID: regionID))
        state.zoomKeyframes.sort { $0.time < $1.time }
    }
    private func camera(_ target: PIPPlacement, timing: EditorMutationTiming, state: inout EditState) throws {
        let baseline = state.placement(at: timing.start)
        guard target != baseline else { return }
        let overlaps = conflicts(in: state)
        guard overlaps.isEmpty else { throw EditorMutationError.conflicts(overlaps) }
        if timing.transition == .smooth, !state.pipKeyframes.contains(where: { abs($0.time - timing.start) < 0.000_001 }) {
            state.upsert(PIPKeyframe(time: timing.start, placement: baseline, transition: .jump))
        }
        let motion = timing.motion
        state.upsert(PIPKeyframe(time: timing.end, placement: target, transition: motion.transition,
            duration: motion.duration, easeIn: motion.easeIn, easeOut: motion.easeOut))
    }

    /// Lazy catalog schema: callers need not put this in every model request.
    static var schemaDescriptors: [[String: Any]] {
        func object(_ fields: [String: Any], optional: Set<String> = []) -> [String: Any] {
            ["type": "object", "properties": fields, "required": fields.keys.filter { !optional.contains($0) }.sorted(), "additionalProperties": false]
        }
        func number(_ lower: Double, _ upper: Double) -> [String: Any] { ["type": "number", "minimum": lower, "maximum": upper] }
        func enumeration(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
        let point = object(["x": number(0, 1), "y": number(0, 1)])
        let timing = object(["start": ["type": "number", "minimum": 0], "end": ["type": "number", "minimum": 0],
            "transition": enumeration(["jump", "smooth"]), "easeIn": number(0, 60), "easeOut": number(0, 60)], optional: ["transition", "easeIn", "easeOut"])
        let anchors = enumeration(EditorRectAnchor.allCases.map(\.rawValue)), axes = enumeration(["horizontal", "vertical", "both"])
        let policy: [String: Any] = ["oneOf": [object(["kind": ["type": "string", "const": "preserve"]]),
            object(["kind": ["type": "string", "const": "fitRegion"]]), object(["kind": ["type": "string", "const": "absolute"], "scale": number(1, 3)])]]
        func operation(_ name: String, _ description: String, _ fields: [String: Any], optional: Set<String> = []) -> [String: Any] {
            var fields = fields; fields["operation"] = ["type": "string", "const": name]
            var value = object(fields, optional: optional); value["description"] = description
            return value
        }
        let overlay = object(["position": point, "scale": number(0.12, 0.5), "shape": enumeration(["original", "rectangle", "square", "circle"]),
            "aspectRatio": number(0.2, 5), "visible": ["type": "boolean"]], optional: ["position", "scale", "shape", "aspectRatio", "visible"])
        let source = object(["crop": point, "sourceZoom": number(1, 3)], optional: ["crop", "sourceZoom"])
        let pointer = object(["visible": ["type": "boolean"], "size": number(1, 4), "smoothing": number(0, 1), "clickHighlight": ["type": "boolean"]],
            optional: ["visible", "size", "smoothing", "clickHighlight"])
        let audio = object(["isMuted": ["type": "boolean"], "volume": number(0, 1), "fadeIn": number(0, 5), "fadeOut": number(0, 5)], optional: ["isMuted", "volume", "fadeIn", "fadeOut"])
        let canvas = object(["aspect": enumeration(["source", "wide", "portrait", "square"]), "padding": number(0, 0.2), "cornerRadius": number(0, 0.2),
            "background": object(["red": number(0, 1), "green": number(0, 1), "blue": number(0, 1)])], optional: ["aspect", "padding", "cornerRadius", "background"])
        return [
            operation("panScreen", "Move the original-source viewport center while preserving its zoom. Exact normalized focal coordinates; impossible bounds reject. Timing uses absolute source seconds.", ["center": point, "timing": timing]),
            operation("zoomScreen", "Set screen magnification1...3. Optional center is exact source-normalized focal point; omission retains current focus with normal bounds clamping.", ["scale": number(1, 3), "center": point, "timing": timing], optional: ["center"]),
            operation("alignScreen", "Align an exact viewport anchor to a raw Box anchor. Preserve scale for pan; explicit absolute/fitRegion permits zoom. No implicit10% padding. Unreachable alignment rejects.", ["regionID": ["type": "string"], "subjectAnchor": anchors, "targetAnchor": anchors, "axes": axes, "scalePolicy": policy, "timing": timing]),
            operation("cameraOverlay", "Patch only output-camera overlay fields. Position is fraction of AVAILABLE travel, scale is fraction of output width0.12...0.5. Shape/visibility switch at arrival; this is not opacity.", ["patch": overlay, "timing": timing]),
            operation("alignCameraOverlay", "Move the camera outline without resizing or changing its source crop. Align to displayed Box using verified host geometry; unavailable geometry rejects. Source boxes project through arrival screen framing into final canvas.", ["regionID": ["type": "string"], "subjectAnchor": anchors, "targetAnchor": anchors, "axes": axes, "timing": timing]),
            operation("cameraSource", "Patch the camera image INSIDE its unchanged outline. Crop x/y are fractions of available oriented camera-source travel; sourceZoom1...3 is not overlay size.", ["patch": source, "timing": timing]),
            operation("pointer", "Patch whole-recording pointer style only; does not invent or retime captured pointer motion. Supply at least one field.", ["patch": pointer]),
            operation("audio", "Patch master recorded audio: volume0...1, mute, fade seconds0...5 relative to kept trim. Preserves source offsets and relative levels. Supply at least one field.", ["patch": audio]),
            operation("canvas", "Patch whole-recording output presentation. Padding/corner radius are fractions0...0.2; background RGB0...1. Source coordinates and PIP travel remain unchanged.", ["patch": canvas]),
            operation("trim", "Keep a nonempty original-source interval. Does not retime keyframes or overwrite requested audio fades.", ["start": ["type": "number", "minimum": 0], "end": ["type": "number", "minimum": 0]])]
    }
    static func schemaData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["oneOf": schemaDescriptors], options: [.sortedKeys])
    }
    static var documentation: [String: Any] {
        ["mutation_schema": ["oneOf": schemaDescriptors],
         "legacy_command_schema": ["oneOf": legacySchemas],
         "units": ["screen": "Original source-normalized focal center; top-left origin. Zoom1...3.",
                   "cameraOverlay": "Position fractions of available output-canvas travel; scale fraction of output width0.12...0.5.",
                   "cameraSource": "Oriented camera crop travel fractions0...1; sourceZoom1...3.",
                   "timing": "Absolute original-source seconds. Smooth start<end; jump start=end. End precedes recording end.",
                   "alignment": "Exact raw Box anchors; no implicit padding or silent clamp. PIP-to-Box needs verified host geometry.",
                   "partial_updates": "Unspecified patch fields remain unchanged. Shape and visible are discrete arrival changes, not opacity.",
                   "conflicts": "Existing same-lane movements must be resolved explicitly. Screen and camera are independent lanes."],
         "examples": [
            ["action": "mutate", "mutation": ["operation": "zoomScreen", "scale": 2,
                "timing": ["start": 2, "end": 5, "transition": "smooth"]]],
            ["action": "mutate", "mutation": ["operation": "cameraOverlay", "patch": ["position": ["x": 0, "y": 0]],
                "timing": ["start": 2, "end": 5, "transition": "smooth"]]],
            ["action": "mutate", "mutation": ["operation": "audio", "patch": ["volume": 0.5, "fadeOut": 1]]]]]
    }

    /// nil discovers names only; '*' explicitly requests the full reference.
    /// An exact operation returns one complete command schema, not every track.
    static func describe(operation: String?) throws -> [String: Any] {
        guard let operation else {
            return ["operations": [
                "screen": ["panScreen", "zoomScreen", "alignScreen", "frameRegion", "fullFrame", "holdFraming", "reviseFraming", "moveBetweenEdits", "moveForDuration"],
                "camera": ["cameraOverlay", "alignCameraOverlay", "cameraSource"],
                "global": ["pointer", "audio", "canvas", "trim"],
                "boxes": ["addRegion", "labelRegion", "removeRegion"],
                "edit_marks": ["createEdit", "moveEdit", "removeEdit", "removeScreenFraming"]],
                "units": "Seconds are original source time. Screen points are normalized source focal centers; camera positions are fractions of available OUTPUT travel. Pan preserves size. Exact alignment rejects unreachable bounds. Get one operation's schema before apply_edits; unknown camera/screen intent requires clarification.",
                "query": "Specify operation by exact name; '*' returns all schemas explicitly."]
        }
        if operation == "*" { return documentation }
        if let schema = schemaDescriptors.first(where: {
            (($0["properties"] as? [String: Any])?["operation"] as? [String: Any])?["const"] as? String == operation
        }) {
            let command: [String: Any] = ["type": "object", "properties": ["action": ["type": "string", "const": "mutate"], "mutation": schema],
                "required": ["action", "mutation"], "additionalProperties": false]
            return ["operation": operation, "command_schema": command,
                "units": "Absolute original-source start/end; duration=end-start. Smooth start<end; jump start=end. Unspecified patch fields stay unchanged; null is unsupported. Camera overlay, camera source crop, and screen viewport are different subjects. Bounds/overlaps fail atomically."]
        }
        if let schema = legacySchemas.first(where: {
            (($0["properties"] as? [String: Any])?["action"] as? [String: Any])?["const"] as? String == operation
        }) {
            return ["operation": operation, "command_schema": schema,
                "units": "Use actual UUIDs from inspect_editor. Time is absolute original-source seconds, before the exclusive recording end. Motion arrives at time. All commands join the same validated one-Undo batch."]
        }
        throw EditorMutationError.invalid("Unknown editing operation. Discover available operation names first.")
    }

    private static var legacySchemas: [[String: Any]] {
        func object(_ fields: [String: Any], optional: Set<String> = []) -> [String: Any] {
            ["type": "object", "properties": fields, "required": fields.keys.filter { !optional.contains($0) }.sorted(), "additionalProperties": false]
        }
        let uuid: [String: Any] = ["type": "string", "description": "Actual UUID from inspect_editor; new Box IDs must be unique UUIDs."]
        let time: [String: Any] = ["type": "number", "minimum": 0, "description": "Original-source timestamp before recording end."]
        let duration: [String: Any] = ["type": "number", "exclusiveMinimum": 0, "maximum": 60]
        let motion = object(["transition": ["type": "string", "enum": ["jump", "smooth"]], "duration": duration,
            "easeIn": ["type": "number", "minimum": 0], "easeOut": ["type": "number", "minimum": 0]], optional: ["easeIn", "easeOut"])
        let rect = object(["x": ["type": "number", "minimum": 0, "maximum": 1], "y": ["type": "number", "minimum": 0, "maximum": 1],
            "width": ["type": "number", "exclusiveMinimum": 0, "maximum": 1], "height": ["type": "number", "exclusiveMinimum": 0, "maximum": 1]])
        let region = object(["id": uuid, "time": time, "rect": rect, "note": ["type": "string", "maxLength": 4096], "editID": uuid,
            "framingPadding": ["type": "number", "minimum": 0, "maximum": 1]], optional: ["editID", "framingPadding"])
        func action(_ name: String, _ description: String, _ fields: [String: Any], optional: Set<String> = []) -> [String: Any] {
            var fields = fields; fields["action"] = ["type": "string", "const": name]
            var schema = object(fields, optional: optional); schema["description"] = description
            return schema
        }
        return [
            action("addRegion", "Add a source-normalized reference Box; does not itself change framing. Its timestamp is the original guide source frame, not a movement's start.", ["region": region]),
            action("frameRegion", "Legacy centered fit to a Box, including its configured breathing room. Not an exact corner-alignment or preserve-scale pan operation.", ["regionID": uuid, "time": time, "motion": motion], optional: ["motion"]),
            action("fullFrame", "Return the screen to1× whole-source framing.", ["time": time, "motion": motion], optional: ["motion"]),
            action("holdFraming", "Keep the evaluated screen view at this timestamp with a hold boundary.", ["time": time]),
            action("reviseFraming", "Refit the screen at an existing timed edit to a Box, preserving that edit's incoming motion settings.", ["editID": uuid, "regionID": uuid]),
            action("moveBetweenEdits", "Move through full frame between two named edits, then fit the destination Box.", ["fromEditID": uuid, "toEditID": uuid, "regionID": uuid]),
            action("moveForDuration", "Start at an existing edit/from-Box and fit a to-Box after the duration; optional full-frame waypoint.", ["startEditID": uuid, "fromRegionID": uuid, "toRegionID": uuid, "duration": duration, "viaFullFrame": ["type": "boolean"]], optional: ["viaFullFrame"]),
            action("createEdit", "Add a reference mark without changing screen or camera appearance.", ["time": time]),
            action("moveEdit", "Move the entire timed edit, including its current screen/camera components. This is not a lane-specific animation resize.", ["editID": uuid, "time": time]),
            action("removeEdit", "Remove the entire timed edit's screen/camera/reference components; guide source timestamps remain.", ["editID": uuid]),
            action("removeScreenFraming", "Remove only the screen keyframe UUID, preserving independent camera and the named source moment.", ["editID": uuid]),
            action("labelRegion", "Update a Box's optional note, never its stable Box number.", ["regionID": uuid, "note": ["type": "string", "maxLength": 4096]]),
            action("removeRegion", "Remove a Box and explicitly linked screen targets, joining the remaining route; preserve independent camera and other marks.", ["regionID": uuid])]
    }
}

private struct EditorMutationAnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private enum EditorRGBKey: String, CodingKey, CaseIterable { case red, green, blue }

private func mutationContainer<Key: CodingKey & CaseIterable>(_ type: Key.Type, _ decoder: any Decoder) throws -> KeyedDecodingContainer<Key> {
    let actual = Set(try decoder.container(keyedBy: EditorMutationAnyKey.self).allKeys.map(\.stringValue))
    guard actual.isSubset(of: Set(Key.allCases.map(\.stringValue))) else { throw EditorMutationError.invalid("The mutation contains unsupported fields.") }
    return try decoder.container(keyedBy: Key.self)
}
private extension KeyedDecodingContainer {
    func only(_ allowed: [Key]) throws {
        guard Set(allKeys.map(\.stringValue)).isSubset(of: Set(allowed.map(\.stringValue))) else { throw EditorMutationError.invalid("This mutation operation contains unrelated fields.") }
    }
    func optional<Value: Decodable>(_ type: Value.Type, _ key: Key) throws -> Value? {
        guard contains(key) else { return nil }
        guard try !decodeNil(forKey: key) else { throw EditorMutationError.invalid("Omit unspecified mutation fields instead of using null.") }
        return try decode(Value.self, forKey: key)
    }
}
