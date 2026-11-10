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
    /// 0 restores normal geometry; 1 fills the output with an aspect-fill crop.
    var fullscreen: Double? = nil
    /// Independent camera alpha; visible is compatibility shorthand for 0/1.
    var opacity: Double? = nil
    private enum CodingKeys: String, CodingKey, CaseIterable { case position, scale, shape, aspectRatio, visible, fullscreen, opacity }
    init(position: EditorUnitPoint? = nil, scale: Double? = nil, shape: PIPShape? = nil, aspectRatio: Double? = nil, visible: Bool? = nil, fullscreen: Double? = nil, opacity: Double? = nil) {
        self.position = position; self.scale = scale; self.shape = shape; self.aspectRatio = aspectRatio; self.visible = visible; self.fullscreen = fullscreen; self.opacity = opacity
    }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        position = try c.optional(EditorUnitPoint.self, .position); scale = try c.optional(Double.self, .scale)
        shape = try c.optional(PIPShape.self, .shape); aspectRatio = try c.optional(Double.self, .aspectRatio); visible = try c.optional(Bool.self, .visible)
        fullscreen = try c.optional(Double.self, .fullscreen)
        opacity = try c.optional(Double.self, .opacity)
    }
    var hasGeometry: Bool { position != nil || scale != nil || shape != nil || aspectRatio != nil || fullscreen != nil }
    var hasOpacity: Bool { opacity != nil || visible != nil }
    var opacityTarget: Double? { opacity ?? visible.map { $0 ? 1 : 0 } }
    var isEmpty: Bool { !hasGeometry && !hasOpacity }
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

struct EditorAudioTrackPatch: Codable, Equatable, Sendable {
    var isMuted: Bool? = nil
    var volume: Double? = nil
    init(isMuted: Bool? = nil, volume: Double? = nil) { self.isMuted = isMuted; self.volume = volume }
    private enum CodingKeys: String, CodingKey, CaseIterable { case isMuted, volume }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        isMuted = try c.optional(Bool.self, .isMuted); volume = try c.optional(Double.self, .volume)
    }
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

/// Clip placement uses project seconds; its independent automation uses the
/// registered source clock so moving or trimming a clip never erases animation.
enum EditorVideoTimeBase: String, Codable, Sendable { case source, project }
enum EditorVideoProperty: String, Codable, Sendable { case geometry, opacity, volume }

struct EditorVideoClipPatch: Codable, Equatable, Sendable {
    var sourceID: UUID? = nil
    var start: Double? = nil
    var end: Double? = nil
    var sourceStart: Double? = nil
    var rate: Double? = nil
    var layout: VideoClipLayout? = nil
    var geometry: VideoGeometry? = nil
    var opacity: Double? = nil
    var fadeIn: Double? = nil
    var fadeOut: Double? = nil
    var volume: Double? = nil
    var isMuted: Bool? = nil
    var transition: VideoClipTransition? = nil
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceID, start, end, sourceStart, rate, layout, geometry, opacity, fadeIn, fadeOut, volume, isMuted, transition
    }
    init(sourceID: UUID? = nil, start: Double? = nil, end: Double? = nil, sourceStart: Double? = nil,
         rate: Double? = nil, layout: VideoClipLayout? = nil, geometry: VideoGeometry? = nil, opacity: Double? = nil,
         fadeIn: Double? = nil, fadeOut: Double? = nil, volume: Double? = nil, isMuted: Bool? = nil,
         transition: VideoClipTransition? = nil) {
        self.sourceID = sourceID; self.start = start; self.end = end; self.sourceStart = sourceStart; self.rate = rate
        self.layout = layout; self.geometry = geometry; self.opacity = opacity; self.fadeIn = fadeIn; self.fadeOut = fadeOut
        self.volume = volume; self.isMuted = isMuted; self.transition = transition
    }
    init(from decoder: any Decoder) throws {
        let c = try mutationContainer(CodingKeys.self, decoder)
        sourceID = try c.optional(UUID.self, .sourceID); start = try c.optional(Double.self, .start)
        end = try c.optional(Double.self, .end); sourceStart = try c.optional(Double.self, .sourceStart)
        rate = try c.optional(Double.self, .rate); layout = try c.optional(VideoClipLayout.self, .layout)
        if c.contains(.geometry) { geometry = try decodeVideoGeometry(c.superDecoder(forKey: .geometry)) }
        opacity = try c.optional(Double.self, .opacity); fadeIn = try c.optional(Double.self, .fadeIn)
        fadeOut = try c.optional(Double.self, .fadeOut); volume = try c.optional(Double.self, .volume)
        isMuted = try c.optional(Bool.self, .isMuted); transition = try c.optional(VideoClipTransition.self, .transition)
    }
    var isEmpty: Bool { self == Self() }
    func apply(to clip: inout VideoClip) {
        if let sourceID { clip.sourceID = sourceID }; if let start { clip.start = start }; if let end { clip.end = end }
        if let sourceStart { clip.sourceStart = sourceStart }; if let rate { clip.rate = rate }; if let layout { clip.layout = layout }
        if let geometry { clip.geometry = geometry }; if let opacity { clip.opacity = opacity }
        if let fadeIn { clip.fadeIn = fadeIn }; if let fadeOut { clip.fadeOut = fadeOut }; if let volume { clip.volume = volume }
        if let isMuted { clip.isMuted = isMuted }; if let transition { clip.transition = transition }
    }
}

private enum VideoGeometryKey: String, CodingKey, CaseIterable { case rect, crop, fit }
private enum VideoRectKey: String, CodingKey, CaseIterable { case x, y, width, height }
private func decodeVideoGeometry(_ decoder: any Decoder) throws -> VideoGeometry {
    let c = try mutationContainer(VideoGeometryKey.self, decoder)
    func rect(_ key: VideoGeometryKey) throws -> EditorRegionRect {
        let r = try mutationContainer(VideoRectKey.self, c.superDecoder(forKey: key))
        return EditorRegionRect(x: try r.decode(Double.self, forKey: .x), y: try r.decode(Double.self, forKey: .y),
            width: try r.decode(Double.self, forKey: .width), height: try r.decode(Double.self, forKey: .height))
    }
    return VideoGeometry(rect: try rect(.rect), crop: try rect(.crop), fit: try c.decode(VideoFit.self, forKey: .fit))
}

/// Host-only verified recording geometry. Never decoded from a model command.
struct EditorMutationGeometry: Equatable, Sendable {
    var sourceSize: CGSize
    var cameraAspect: Double?
}

enum EditorCutTimeBase: String, Codable, Sendable { case source, output }
enum EditorMutationLane: String, Codable, Sendable { case screen, camera, cameraOpacity, pointer, audio, canvas, trim, timing, content, speed }
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
    var layerID: UUID? = nil
    var clipID: UUID? = nil
    var property: EditorVideoProperty? = nil
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
        case let .conflicts(items):
            if let property = items.first?.property {
                "This clip's \(property.rawValue) change overlaps \(items.count) existing animation(s). Revise or remove those changes first."
            } else {
                "The requested movement overlaps \(items.count) existing \(items.first?.lane.rawValue ?? "") animation(s). Resolve those movements explicitly before applying this interval."
            }
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
    case audioTrack(role: RecordingAudioRole, patch: EditorAudioTrackPatch)
    case audioGain(role: RecordingAudioRole, gain: Double, timing: EditorMutationTiming, id: UUID? = nil)
    case removeAudioGain(role: RecordingAudioRole, pointID: UUID)
    case canvas(EditorCanvasPatch)
    case trim(start: Double, end: Double)
    case cutSection(start: Double, end: Double, timeBase: EditorCutTimeBase, crossfade: Double? = nil)
    case restoreCut(cutID: UUID)
    case cutTransition(cutID: UUID, duration: Double)
    case speed(rate: Double, timing: EditorMutationTiming, timeBase: EditorCutTimeBase = .source, preservesPitch: Bool? = nil)
    case removeAnimation(animationID: String)
    case addContentLayer(ContentLayer)
    case updateContentLayer(ContentLayer)
    case removeContentLayer(layerID: UUID)
    case reorderContentLayer(layerID: UUID, index: Int)
    case addVideoLayer(id: UUID, name: String)
    case renameVideoLayer(layerID: UUID, name: String)
    case removeVideoLayer(layerID: UUID)
    case reorderVideoLayer(layerID: UUID, index: Int)
    case addVideoClip(layerID: UUID, clipID: UUID, patch: EditorVideoClipPatch)
    case updateVideoClip(layerID: UUID, clipID: UUID, patch: EditorVideoClipPatch)
    case removeVideoClip(layerID: UUID, clipID: UUID)
    case videoGeometry(layerID: UUID, clipID: UUID, target: VideoGeometry, timing: EditorMutationTiming, timeBase: EditorVideoTimeBase = .source, id: UUID? = nil)
    case videoOpacity(layerID: UUID, clipID: UUID, opacity: Double, timing: EditorMutationTiming, timeBase: EditorVideoTimeBase = .source, id: UUID? = nil)
    case videoVolume(layerID: UUID, clipID: UUID, gain: Double, timing: EditorMutationTiming, timeBase: EditorVideoTimeBase = .source, id: UUID? = nil)
    case removeVideoAnimation(layerID: UUID, clipID: UUID, property: EditorVideoProperty, pointID: UUID)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operation, center, timing, scale, regionID, subjectAnchor, targetAnchor, axes, scalePolicy, patch, start, end,
             timeBase, crossfade, cutID, duration, layer, layerID, index, rate, preservesPitch, animationID, role, gain, id, pointID, name, clipID, target, opacity, property
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
        case "audioTrack":
            try c.only([.operation, .role, .patch]); self = .audioTrack(role: try c.decode(RecordingAudioRole.self, forKey: .role), patch: try c.decode(EditorAudioTrackPatch.self, forKey: .patch))
        case "audioGain":
            try c.only([.operation, .role, .gain, .timing, .id]); self = .audioGain(role: try c.decode(RecordingAudioRole.self, forKey: .role), gain: try c.decode(Double.self, forKey: .gain), timing: try c.decode(EditorMutationTiming.self, forKey: .timing), id: try c.optional(UUID.self, .id))
        case "removeAudioGain":
            try c.only([.operation, .role, .pointID]); self = .removeAudioGain(role: try c.decode(RecordingAudioRole.self, forKey: .role), pointID: try c.decode(UUID.self, forKey: .pointID))
        case "canvas": try c.only([.operation, .patch]); self = .canvas(try c.decode(EditorCanvasPatch.self, forKey: .patch))
        case "trim": try c.only([.operation, .start, .end]); self = .trim(start: try c.decode(Double.self, forKey: .start), end: try c.decode(Double.self, forKey: .end))
        case "cutSection":
            try c.only([.operation, .start, .end, .timeBase, .crossfade])
            self = .cutSection(start: try c.decode(Double.self, forKey: .start), end: try c.decode(Double.self, forKey: .end),
                timeBase: try c.decode(EditorCutTimeBase.self, forKey: .timeBase), crossfade: try c.optional(Double.self, .crossfade))
        case "restoreCut":
            try c.only([.operation, .cutID]); self = .restoreCut(cutID: try c.decode(UUID.self, forKey: .cutID))
        case "cutTransition":
            try c.only([.operation, .cutID, .duration])
            self = .cutTransition(cutID: try c.decode(UUID.self, forKey: .cutID), duration: try c.decode(Double.self, forKey: .duration))
        case "speed":
            try c.only([.operation, .rate, .timing, .timeBase, .preservesPitch])
            self = .speed(rate: try c.decode(Double.self, forKey: .rate), timing: try c.decode(EditorMutationTiming.self, forKey: .timing),
                timeBase: try c.optional(EditorCutTimeBase.self, .timeBase) ?? .source,
                preservesPitch: try c.optional(Bool.self, .preservesPitch))
        case "removeAnimation":
            try c.only([.operation, .animationID]); self = .removeAnimation(animationID: try c.decode(String.self, forKey: .animationID))
        case "addContentLayer":
            try c.only([.operation, .layer]); self = .addContentLayer(try c.decode(ContentLayer.self, forKey: .layer))
        case "updateContentLayer":
            try c.only([.operation, .layer]); self = .updateContentLayer(try c.decode(ContentLayer.self, forKey: .layer))
        case "removeContentLayer":
            try c.only([.operation, .layerID]); self = .removeContentLayer(layerID: try c.decode(UUID.self, forKey: .layerID))
        case "reorderContentLayer":
            try c.only([.operation, .layerID, .index])
            self = .reorderContentLayer(layerID: try c.decode(UUID.self, forKey: .layerID), index: try c.decode(Int.self, forKey: .index))
        case "addVideoLayer":
            try c.only([.operation, .id, .name]); self = .addVideoLayer(id: try c.optional(UUID.self, .id) ?? UUID(), name: try c.decode(String.self, forKey: .name))
        case "renameVideoLayer":
            try c.only([.operation, .layerID, .name]); self = .renameVideoLayer(layerID: try c.decode(UUID.self, forKey: .layerID), name: try c.decode(String.self, forKey: .name))
        case "removeVideoLayer":
            try c.only([.operation, .layerID]); self = .removeVideoLayer(layerID: try c.decode(UUID.self, forKey: .layerID))
        case "reorderVideoLayer":
            try c.only([.operation, .layerID, .index]); self = .reorderVideoLayer(layerID: try c.decode(UUID.self, forKey: .layerID), index: try c.decode(Int.self, forKey: .index))
        case "addVideoClip", "updateVideoClip":
            try c.only([.operation, .layerID, .clipID, .patch])
            let layer = try c.decode(UUID.self, forKey: .layerID), patch = try c.decode(EditorVideoClipPatch.self, forKey: .patch)
            if try c.decode(String.self, forKey: .operation) == "addVideoClip" {
                self = .addVideoClip(layerID: layer, clipID: try c.optional(UUID.self, .clipID) ?? UUID(), patch: patch)
            } else { self = .updateVideoClip(layerID: layer, clipID: try c.decode(UUID.self, forKey: .clipID), patch: patch) }
        case "removeVideoClip":
            try c.only([.operation, .layerID, .clipID]); self = .removeVideoClip(layerID: try c.decode(UUID.self, forKey: .layerID), clipID: try c.decode(UUID.self, forKey: .clipID))
        case "videoGeometry", "videoOpacity", "videoVolume":
            let op = try c.decode(String.self, forKey: .operation)
            try c.only([.operation, .layerID, .clipID, .timing, .timeBase, .id, op == "videoGeometry" ? .target : op == "videoOpacity" ? .opacity : .gain])
            let layer = try c.decode(UUID.self, forKey: .layerID), clip = try c.decode(UUID.self, forKey: .clipID)
            let timing = try c.decode(EditorMutationTiming.self, forKey: .timing), base = try c.optional(EditorVideoTimeBase.self, .timeBase) ?? .source
            let id = try c.optional(UUID.self, .id)
            if op == "videoGeometry" { self = .videoGeometry(layerID: layer, clipID: clip, target: try decodeVideoGeometry(c.superDecoder(forKey: .target)), timing: timing, timeBase: base, id: id) }
            else if op == "videoOpacity" { self = .videoOpacity(layerID: layer, clipID: clip, opacity: try c.decode(Double.self, forKey: .opacity), timing: timing, timeBase: base, id: id) }
            else { self = .videoVolume(layerID: layer, clipID: clip, gain: try c.decode(Double.self, forKey: .gain), timing: timing, timeBase: base, id: id) }
        case "removeVideoAnimation":
            try c.only([.operation, .layerID, .clipID, .property, .pointID])
            self = .removeVideoAnimation(layerID: try c.decode(UUID.self, forKey: .layerID), clipID: try c.decode(UUID.self, forKey: .clipID), property: try c.decode(EditorVideoProperty.self, forKey: .property), pointID: try c.decode(UUID.self, forKey: .pointID))
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
        case let .audioTrack(role, patch):
            try c.encode("audioTrack", forKey: .operation); try c.encode(role, forKey: .role); try c.encode(patch, forKey: .patch)
        case let .audioGain(role, gain, timing, id):
            try c.encode("audioGain", forKey: .operation); try c.encode(role, forKey: .role); try c.encode(gain, forKey: .gain); try c.encode(timing, forKey: .timing); try c.encodeIfPresent(id, forKey: .id)
        case let .removeAudioGain(role, id):
            try c.encode("removeAudioGain", forKey: .operation); try c.encode(role, forKey: .role); try c.encode(id, forKey: .pointID)
        case let .canvas(patch): try c.encode("canvas", forKey: .operation); try c.encode(patch, forKey: .patch)
        case let .trim(start, end): try c.encode("trim", forKey: .operation); try c.encode(start, forKey: .start); try c.encode(end, forKey: .end)
        case let .cutSection(start, end, timeBase, crossfade):
            try c.encode("cutSection", forKey: .operation); try c.encode(start, forKey: .start); try c.encode(end, forKey: .end)
            try c.encode(timeBase, forKey: .timeBase); try c.encodeIfPresent(crossfade, forKey: .crossfade)
        case let .restoreCut(id): try c.encode("restoreCut", forKey: .operation); try c.encode(id, forKey: .cutID)
        case let .cutTransition(id, duration):
            try c.encode("cutTransition", forKey: .operation); try c.encode(id, forKey: .cutID); try c.encode(duration, forKey: .duration)
        case let .speed(rate, timing, base, pitch):
            try c.encode("speed", forKey: .operation); try c.encode(rate, forKey: .rate); try c.encode(timing, forKey: .timing)
            try c.encode(base, forKey: .timeBase)
            try c.encodeIfPresent(pitch, forKey: .preservesPitch)
        case let .removeAnimation(id): try c.encode("removeAnimation", forKey: .operation); try c.encode(id, forKey: .animationID)
        case let .addContentLayer(layer): try c.encode("addContentLayer", forKey: .operation); try c.encode(layer, forKey: .layer)
        case let .updateContentLayer(layer): try c.encode("updateContentLayer", forKey: .operation); try c.encode(layer, forKey: .layer)
        case let .removeContentLayer(id): try c.encode("removeContentLayer", forKey: .operation); try c.encode(id, forKey: .layerID)
        case let .reorderContentLayer(id, index):
            try c.encode("reorderContentLayer", forKey: .operation); try c.encode(id, forKey: .layerID); try c.encode(index, forKey: .index)
        case let .addVideoLayer(id, name):
            try c.encode("addVideoLayer", forKey: .operation); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        case let .renameVideoLayer(id, name):
            try c.encode("renameVideoLayer", forKey: .operation); try c.encode(id, forKey: .layerID); try c.encode(name, forKey: .name)
        case let .removeVideoLayer(id):
            try c.encode("removeVideoLayer", forKey: .operation); try c.encode(id, forKey: .layerID)
        case let .reorderVideoLayer(id, index):
            try c.encode("reorderVideoLayer", forKey: .operation); try c.encode(id, forKey: .layerID); try c.encode(index, forKey: .index)
        case let .addVideoClip(layer, clip, patch), let .updateVideoClip(layer, clip, patch):
            let op: String; if case .addVideoClip = self { op = "addVideoClip" } else { op = "updateVideoClip" }
            try c.encode(op, forKey: .operation); try c.encode(layer, forKey: .layerID); try c.encode(clip, forKey: .clipID); try c.encode(patch, forKey: .patch)
        case let .removeVideoClip(layer, clip):
            try c.encode("removeVideoClip", forKey: .operation); try c.encode(layer, forKey: .layerID); try c.encode(clip, forKey: .clipID)
        case let .videoGeometry(layer, clip, target, timing, base, id):
            try c.encode("videoGeometry", forKey: .operation); try c.encode(layer, forKey: .layerID); try c.encode(clip, forKey: .clipID)
            try c.encode(target, forKey: .target); try c.encode(timing, forKey: .timing); try c.encode(base, forKey: .timeBase); try c.encodeIfPresent(id, forKey: .id)
        case let .videoOpacity(layer, clip, value, timing, base, id), let .videoVolume(layer, clip, value, timing, base, id):
            let op: String, key: CodingKeys; if case .videoOpacity = self { op = "videoOpacity"; key = .opacity } else { op = "videoVolume"; key = .gain }
            try c.encode(op, forKey: .operation); try c.encode(layer, forKey: .layerID); try c.encode(clip, forKey: .clipID)
            try c.encode(value, forKey: key); try c.encode(timing, forKey: .timing); try c.encode(base, forKey: .timeBase); try c.encodeIfPresent(id, forKey: .id)
        case let .removeVideoAnimation(layer, clip, property, point):
            try c.encode("removeVideoAnimation", forKey: .operation); try c.encode(layer, forKey: .layerID); try c.encode(clip, forKey: .clipID)
            try c.encode(property, forKey: .property); try c.encode(point, forKey: .pointID)
        }
    }

    var timing: EditorMutationTiming? {
        switch self {
        case let .panScreen(_, value), let .zoomScreen(_, _, value), let .alignScreen(_, _, _, _, _, value),
             let .cameraOverlay(_, value), let .alignCameraOverlay(_, _, _, _, value), let .cameraSource(_, value), let .audioGain(_, _, value, _): value
        case let .speed(_, value, base, _): base == .source ? value : nil
        default: nil
        }
    }
    var lane: EditorMutationLane {
        switch self {
        case .panScreen, .zoomScreen, .alignScreen: .screen
        case let .cameraOverlay(patch, _): patch.hasGeometry ? .camera : .cameraOpacity
        case .alignCameraOverlay, .cameraSource: .camera
        case .pointer: .pointer
        case .audio, .audioTrack, .audioGain, .removeAudioGain: .audio
        case .canvas: .canvas
        case .trim: .trim
        case .cutSection, .restoreCut, .cutTransition: .timing
        case .speed: .speed
        case let .removeAnimation(id):
            id.hasPrefix("audioMicrophone:") || id.hasPrefix("audioSystem:") ? .audio :
                EditorMutationLane(rawValue: String(id.split(separator: ":").first ?? "")) ?? .timing
        case .addContentLayer, .updateContentLayer, .removeContentLayer, .reorderContentLayer,
             .addVideoLayer, .renameVideoLayer, .removeVideoLayer, .reorderVideoLayer,
             .addVideoClip, .updateVideoClip, .removeVideoClip, .videoGeometry, .videoOpacity, .videoVolume, .removeVideoAnimation: .content
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
        if case let .cameraOverlay(patch, _) = self, patch.hasGeometry, patch.hasOpacity {
            return [.init(lane: .camera, start: timing?.start ?? 0, end: timing?.end ?? duration, subject: subject),
                    .init(lane: .cameraOpacity, start: timing?.start ?? 0, end: timing?.end ?? duration, subject: subject)]
        }
        return [EditorMutationEffect(lane: lane, start: timing?.start ?? 0, end: timing?.end ?? duration, subject: subject)]
    }

    /// New motion never silently crosses/replaces an existing same-lane point.
    /// The fixed time-zero camera appearance is not an incoming animation.
    func conflicts(in state: EditState) -> [EditorMutationConflict] {
        guard let timing else { return [] }
        var result: [EditorMutationConflict] = []
        var previous = 0.0
        var checkingLane = lane
        func check(id: UUID, time: Double, transition: PIPTransition, duration: Double) {
            defer { previous = time }
            guard time > 0 else { return }
            let begins = transition == .smooth ? max(previous, time - duration) : time
            let intersects = timing.start == timing.end
                ? (begins < timing.end && time >= timing.end) || abs(time - timing.end) < 0.000_001
                : time > timing.start + 0.000_001 && (begins < timing.end - 0.000_001 || abs(time - timing.end) < 0.000_001)
            if intersects { result.append(EditorMutationConflict(lane: checkingLane, componentID: id, start: begins, end: time)) }
        }
        if lane == .screen {
            for point in state.zoomKeyframes { check(id: point.id, time: point.time, transition: point.transition, duration: point.duration) }
        } else if lane == .speed {
            for point in state.speedKeyframes { check(id: point.id, time: point.time, transition: point.transition, duration: point.duration) }
        } else {
            let geometry: Bool, opacity: Bool
            if case let .cameraOverlay(patch, _) = self { geometry = patch.hasGeometry; opacity = patch.hasOpacity }
            else { geometry = lane == .camera; opacity = lane == .cameraOpacity }
            if geometry {
                checkingLane = .camera
                for point in state.pipKeyframes { check(id: point.id, time: point.time, transition: point.transition, duration: point.duration) }
            }
            if opacity {
                previous = 0; checkingLane = .cameraOpacity
                for point in state.cameraOpacityEvents { check(id: point.id, time: point.time, transition: point.transition, duration: point.duration) }
            }
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
        // Speed envelopes may arrive at the exclusive footage end and can span
        // the full source; their own validation follows below.
        if lane != .speed, let timing { try timing.validate(duration: project.duration) }
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
            var target = state.cameraGeometry(at: timing.start)
            if let position = patch.position { target.x = position.x; target.y = position.y }
            if let value = patch.scale { target.scale = value }
            if let value = patch.shape { target.shape = value }
            if let value = patch.aspectRatio { target.aspectRatio = value }
            if let value = patch.fullscreen { target.fullscreen = value == 0 ? nil : value }
            if let value = patch.opacity, !value.isFinite || !(0...1).contains(value) {
                throw EditorMutationError.invalid("Camera opacity must be a finite value between 0 and 1.")
            }
            if patch.visible == false, let opacity = patch.opacity, opacity > 0 {
                throw EditorMutationError.invalid("A hidden camera cannot have nonzero opacity. Omit visible and use opacity for fades.")
            }
            let overlaps = conflicts(in: state).filter { conflict in
                conflict.lane == .camera ? patch.hasGeometry && target != state.cameraGeometry(at: timing.start)
                    : patch.opacityTarget.map { $0 != state.cameraOpacity(at: timing.start) } ?? false
            }
            guard overlaps.isEmpty else { throw EditorMutationError.conflicts(overlaps) }
            if patch.hasGeometry { try camera(target, timing: timing, state: &state, checkConflicts: false) }
            if let opacity = patch.opacityTarget { cameraOpacity(opacity, timing: timing, state: &state) }
        case let .cameraSource(patch, timing):
            try requireCamera(project)
            guard !patch.isEmpty else { throw EditorMutationError.invalid("Supply a camera crop or source zoom.") }
            var target = state.cameraGeometry(at: timing.start)
            if let value = patch.crop { target.crop = value }
            if let value = patch.sourceZoom { target.sourceZoom = value }
            try camera(target, timing: timing, state: &state)
        case let .alignCameraOverlay(id, own, targetAnchor, axes, timing):
            try requireCamera(project)
            guard let geometry, geometry.sourceSize.width.isFinite, geometry.sourceSize.height.isFinite,
                  geometry.sourceSize.width > 0, geometry.sourceSize.height > 0,
                  geometry.sourceSize.width <= 32768, geometry.sourceSize.height <= 32768 else { throw EditorMutationError.geometryUnavailable }
            var target = state.cameraGeometry(at: timing.start)
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
            if output.width - frame.width > 0.000_000_001 { target.x = min(1, max(0, x / (output.width - frame.width))) }
            if output.height - frame.height > 0.000_000_001 { target.y = min(1, max(0, y / (output.height - frame.height))) }
            let resolved = target.frame(in: output.size, cameraAspect: aspect)
            guard abs(resolved.minX - x) < 0.000_000_1, abs(resolved.minY - y) < 0.000_000_1 else { throw EditorMutationError.unreachableAlignment }
            try camera(target, timing: timing, state: &state)
        case let .pointer(patch):
            guard !patch.isEmpty else { throw EditorMutationError.invalid("Supply at least one pointer style property.") }
            if let value = patch.visible { state.cursorStyle.visible = value }
            if let value = patch.size { state.cursorStyle.size = value }
            if let value = patch.smoothing { state.cursorStyle.smoothing = value }
            if let value = patch.clickHighlight { state.cursorStyle.clickHighlight = value }
        case let .audioTrack(role, patch):
            guard project.audioSources.contains(where: { $0.role == role }) else { throw EditorMutationError.invalid("This recording has no identified \(role.title.lowercased()) track.") }
            guard patch.isMuted != nil || patch.volume != nil else { throw EditorMutationError.invalid("Supply a track mute or volume value.") }
            state.audio.updateChannel(role) { channel in
                if let value = patch.isMuted { channel.isMuted = value }
                if let value = patch.volume { channel.volume = value }
            }
        case let .audioGain(role, gain, timing, id):
            guard project.audioSources.contains(where: { $0.role == role }) else { throw EditorMutationError.invalid("This recording has no identified \(role.title.lowercased()) track.") }
            var channel = state.audio.channel(role)
            if let id, !channel.points.contains(where: { $0.id == id }) { throw EditorMutationError.invalid("The volume change no longer exists.") }
            var previous = 0.0
            for point in channel.points {
                let beginning = point.transition == .smooth ? max(previous, point.time - point.duration) : point.time
                if point.id != id && point.time > timing.start && beginning < timing.end {
                    throw EditorMutationError.invalid("This volume change overlaps another change on the same audio track.")
                }
                if point.id != id && abs(point.time - timing.end) < 0.000001 { throw EditorMutationError.invalid("Another volume change already arrives at that source time.") }
                previous = point.time
            }
            let point = RecordingAudioGainPoint(id: id ?? UUID(), time: timing.end, gain: gain,
                transition: timing.start == timing.end ? .jump : .smooth, duration: max(0.000001, timing.end - timing.start),
                easeIn: timing.easeIn, easeOut: timing.easeOut)
            channel.points.removeAll { $0.id == point.id }; channel.points.append(point); channel.points.sort { $0.time < $1.time }
            state.audio.updateChannel(role) { $0 = channel }
        case let .removeAudioGain(role, id):
            guard state.audio.channel(role).points.contains(where: { $0.id == id }) else { throw EditorMutationError.invalid("The volume change no longer exists.") }
            state.audio.updateChannel(role) { $0.points.removeAll { $0.id == id } }
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
        case let .cutSection(start, end, timeBase, crossfade):
            state = try EditorCutEditing.cutting(start: start, end: end, timeBase: timeBase,
                crossfade: crossfade, state: state, duration: project.duration)
        case let .restoreCut(id):
            guard state.cuts.contains(where: { $0.id == id }) else { throw EditorMutationError.invalid("That cut no longer exists.") }
            state.cuts.removeAll { $0.id == id }
        case let .cutTransition(id, duration):
            guard duration.isFinite, duration >= 0 else { throw EditorMutationError.invalid("Crossfade duration must be a finite, nonnegative number of output seconds.") }
            guard let index = state.cuts.firstIndex(where: { $0.id == id }) else { throw EditorMutationError.invalid("That cut no longer exists.") }
            state.cuts[index].crossfade = duration
        case let .speed(rate, requestedTiming, base, pitch):
            guard rate.isFinite, RecordingRetime.supportedRates.contains(rate) else {
                throw EditorMutationError.invalid("Export speed must be between 0.1× and 8×.")
            }
            var timing = requestedTiming
            if base == .output {
                let original = project.state
                let map = try RecordingTimeMap(duration: project.duration, trimStart: original.trimStart,
                    trimEnd: original.trimEnd, cuts: original.cuts, speedKeyframes: original.speedKeyframes)
                func source(_ time: Double) throws -> Double {
                    guard time.isFinite, time >= 0, time <= map.outputDuration else {
                        throw EditorMutationError.invalid("The speed change must use times inside the pre-edit output timeline.")
                    }
                    let samples = map.samples(at: time)
                    guard let first = samples.first, samples.allSatisfy({ abs($0.sourceTime - first.sourceTime) <= 0.000000001 }) else {
                        throw EditorMutationError.invalid("That speed boundary has two source frames in a crossfade. Use explicit source times.")
                    }
                    return first.sourceTime
                }
                timing.start = try source(requestedTiming.start); timing.end = try source(requestedTiming.end)
                if let ease = requestedTiming.easeIn { timing.easeIn = try source(requestedTiming.start + ease) - timing.start }
                if let ease = requestedTiming.easeOut { timing.easeOut = timing.end - (try source(requestedTiming.end - ease)) }
            }
            guard timing.start.isFinite, timing.end.isFinite, timing.start >= 0, timing.end <= project.duration,
                  timing.transition == .smooth ? timing.start < timing.end : timing.start == timing.end,
                  [timing.easeIn, timing.easeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw EditorMutationError.invalid("A speed ramp needs an ordered source interval inside the recording; a jump uses one source time.")
            }
            if let pitch { state.preservesAudioPitch = pitch }
            let baseline = state.speed(at: timing.start)
            guard rate != baseline else { return }
            let overlaps = EditorMutation.speed(rate: rate, timing: timing).conflicts(in: state)
            guard overlaps.isEmpty else { throw EditorMutationError.conflicts(overlaps) }
            if timing.transition == .smooth, !state.speedKeyframes.contains(where: { abs($0.time - timing.start) < 0.000001 }) {
                state.speedKeyframes.append(RecordingSpeedKeyframe(time: timing.start, rate: baseline, transition: .jump))
            }
            let existing = state.speedKeyframes.first { abs($0.time - timing.end) < 0.000001 }
            state.speedKeyframes.removeAll { abs($0.time - timing.end) < 0.000001 }
            state.speedKeyframes.append(RecordingSpeedKeyframe(id: existing?.id ?? UUID(), time: existing?.time ?? timing.end,
                rate: rate, transition: timing.transition, duration: timing.motion.duration, easeIn: timing.easeIn, easeOut: timing.easeOut))
            state.speedKeyframes.sort { $0.time < $1.time }
        case let .removeAnimation(id):
            let pieces = id.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2, let component = UUID(uuidString: String(pieces[1])) else {
                throw EditorMutationError.invalid("Use an actual lane-qualified animation identity from inspect_editor edits.")
            }
            switch pieces[0] {
            case "screen":
                guard state.zoomKeyframes.contains(where: { $0.id == component }) else { throw EditorMutationError.invalid("That screen animation no longer exists.") }
                state.zoomKeyframes.removeAll { $0.id == component }
            case "camera":
                guard state.pipKeyframes.contains(where: { $0.id == component && $0.time > 0 }) else { throw EditorMutationError.invalid("That camera animation cannot be removed.") }
                state.pipKeyframes.removeAll { $0.id == component && $0.time > 0 }
            case "speed":
                guard state.speedKeyframes.contains(where: { $0.id == component }) else { throw EditorMutationError.invalid("That speed animation no longer exists.") }
                state.speedKeyframes.removeAll { $0.id == component }
            case "cameraOpacity":
                guard state.cameraOpacityKeyframes.contains(where: { $0.id == component }) else { throw EditorMutationError.invalid("That independent opacity change no longer exists.") }
                state.cameraOpacityKeyframes.removeAll { $0.id == component }
            case "audioMicrophone", "audioSystem":
                let role: RecordingAudioRole = pieces[0] == "audioMicrophone" ? .microphone : .systemAudio
                guard state.audio.channel(role).points.contains(where: { $0.id == component }) else { throw EditorMutationError.invalid("That volume change no longer exists.") }
                state.audio.updateChannel(role) { $0.points.removeAll { $0.id == component } }
            default: throw EditorMutationError.invalid("Choose a screen, camera, opacity, speed or audio animation; pointer styling is not a removable animation.")
            }
        case let .addContentLayer(layer):
            guard !state.contentLayers.contains(where: { $0.id == layer.id }) else { throw EditorMutationError.invalid("That content layer identity is already in use.") }
            state.contentLayers.append(layer)
        case let .updateContentLayer(layer):
            guard let index = state.contentLayers.firstIndex(where: { $0.id == layer.id }) else { throw EditorMutationError.invalid("That content layer no longer exists.") }
            state.contentLayers[index] = layer
        case let .removeContentLayer(id):
            guard state.contentLayers.contains(where: { $0.id == id }) else { throw EditorMutationError.invalid("That content layer no longer exists.") }
            state.contentLayers.removeAll { $0.id == id }
        case let .reorderContentLayer(id, index):
            guard state.contentLayers.indices.contains(index), let current = state.contentLayers.firstIndex(where: { $0.id == id }) else {
                throw EditorMutationError.invalid("Choose an existing layer and an index inside the layer stack.")
            }
            let layer = state.contentLayers.remove(at: current)
            state.contentLayers.insert(layer, at: index)
        case .addVideoLayer, .renameVideoLayer, .removeVideoLayer, .reorderVideoLayer,
             .addVideoClip, .updateVideoClip, .removeVideoClip, .videoGeometry, .videoOpacity, .videoVolume, .removeVideoAnimation:
            try applyVideo(to: &state, project: project)
        }
    }

    private func applyVideo(to state: inout EditState, project: RecordingProject) throws {
        var layers = project.effectiveVideoLayers(in: state)
        func layerIndex(_ id: UUID) throws -> Int {
            guard let i = layers.firstIndex(where: { $0.id == id }) else { throw EditorMutationError.invalid("That video layer no longer exists.") }; return i
        }
        func clipIndex(_ id: UUID, in layer: Int) throws -> Int {
            guard let i = layers[layer].clips.firstIndex(where: { $0.id == id }) else { throw EditorMutationError.invalid("That video clip no longer exists.") }; return i
        }
        func sourceTiming(_ timing: EditorMutationTiming, _ base: EditorVideoTimeBase, _ clip: VideoClip) throws -> EditorMutationTiming {
            var result = timing
            if base == .project {
                guard timing.start >= clip.start, timing.end <= clip.end else { throw EditorMutationError.invalid("Animation project times must be inside this clip.") }
                result.start = clip.sourceTime(at: timing.start); result.end = clip.sourceTime(at: timing.end)
                result.easeIn = timing.easeIn.map { $0 * clip.rate }; result.easeOut = timing.easeOut.map { $0 * clip.rate }
            }
            let source = project.videoSources.first { $0.id == clip.sourceID }
            if base == .project, let limit = source?.duration {
                // Valid clip edges may differ by an ulp after rate conversion.
                let tolerance = max(1, limit) * 1e-12
                if result.start > limit, result.start - limit <= tolerance { result.start = limit }
                if result.end > limit, result.end - limit <= tolerance { result.end = limit }
            }
            guard result.start.isFinite, result.end.isFinite, result.start >= 0, result.end >= result.start,
                  source?.duration.map({ result.end <= $0 }) ?? true,
                  result.transition == .smooth ? result.end > result.start : result.end == result.start else {
                throw EditorMutationError.invalid("Use a valid source interval for this clip; a jump has one timestamp.")
            }
            guard [result.easeIn, result.easeOut].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw EditorMutationError.invalid("Clip animation ramps must be finite, nonnegative source durations.")
            }
            return result
        }
        func check(_ points: [(UUID, Double, PIPTransition, Double)], _ timing: EditorMutationTiming, excluding id: UUID?, layerID: UUID, clipID: UUID, property: EditorVideoProperty) throws {
            var prior = 0.0
            var conflicts: [EditorMutationConflict] = []
            for (pointID, time, transition, duration) in points.sorted(by: { $0.1 < $1.1 }) {
                let start = transition == .smooth ? max(prior, time - duration) : time
                defer { prior = time }
                guard pointID != id else { continue }
                let overlap = timing.start == timing.end ? start < timing.end && time >= timing.end || abs(time - timing.end) < 1e-6
                    : time > timing.start + 1e-6 && start < timing.end - 1e-6
                if overlap { conflicts.append(.init(lane: .content, componentID: pointID, start: start, end: time, layerID: layerID, clipID: clipID, property: property)) }
            }
            guard conflicts.isEmpty else { throw EditorMutationError.conflicts(conflicts) }
        }
        switch self {
        case let .addVideoLayer(id, name):
            guard !layers.contains(where: { $0.id == id }) else { throw EditorMutationError.invalid("That video layer identity is already in use.") }
            layers.append(VideoLayer(id: id, name: name))
        case let .renameVideoLayer(id, name): layers[try layerIndex(id)].name = name
        case let .removeVideoLayer(id): layers.remove(at: try layerIndex(id))
        case let .reorderVideoLayer(id, index):
            guard layers.indices.contains(index) else { throw EditorMutationError.invalid("Choose an index inside the video layer stack.") }
            let layer = layers.remove(at: try layerIndex(id)); layers.insert(layer, at: index)
        case let .addVideoClip(layerID, clipID, patch):
            let l = try layerIndex(layerID)
            guard !layers.flatMap(\.clips).contains(where: { $0.id == clipID }), let source = patch.sourceID, let start = patch.start, let end = patch.end else {
                throw EditorMutationError.invalid("A new clip needs a unique identity, registered sourceID, project start and end.")
            }
            var clip = VideoClip(id: clipID, sourceID: source, start: start, end: end); patch.apply(to: &clip); layers[l].clips.append(clip)
        case let .updateVideoClip(layerID, clipID, patch):
            guard !patch.isEmpty else { throw EditorMutationError.invalid("Supply at least one clip property.") }
            let l = try layerIndex(layerID), c = try clipIndex(clipID, in: l)
            if let source = patch.sourceID, source != layers[l].clips[c].sourceID {
                throw EditorMutationError.invalid("To use different footage, add a new clip. Existing source-anchored animations stay with their footage.")
            }
            patch.apply(to: &layers[l].clips[c])
        case let .removeVideoClip(layerID, clipID):
            let l = try layerIndex(layerID); layers[l].clips.remove(at: try clipIndex(clipID, in: l))
        case let .videoGeometry(layerID, clipID, target, timing, base, id):
            let l = try layerIndex(layerID), c = try clipIndex(clipID, in: l); var clip = layers[l].clips[c]
            guard clip.layout == .custom else { throw EditorMutationError.invalid("Use screen or camera controls for this legacy layout, or explicitly choose a custom clip layout first.") }
            let t = try sourceTiming(timing, base, clip), baseline = clip.geometry(atSourceTime: t.start)
            try check(clip.geometryKeyframes.map { ($0.id, $0.time, $0.transition, $0.duration) }, t, excluding: id, layerID: layerID, clipID: clipID, property: .geometry)
            if t.transition == .smooth, !clip.geometryKeyframes.contains(where: { abs($0.time - t.start) < 1e-6 }) {
                clip.geometryKeyframes.append(VideoGeometryKeyframe(time: t.start, geometry: baseline, transition: .jump))
            }
            clip.geometryKeyframes.removeAll { $0.id == id || abs($0.time - t.end) < 1e-6 }
            clip.geometryKeyframes.append(VideoGeometryKeyframe(id: id ?? UUID(), time: t.end, geometry: target, transition: t.transition, duration: t.motion.duration, easeIn: t.easeIn, easeOut: t.easeOut))
            clip.geometryKeyframes.sort { $0.time < $1.time }; layers[l].clips[c] = clip
        case let .videoOpacity(layerID, clipID, value, timing, base, id):
            let l = try layerIndex(layerID), c = try clipIndex(clipID, in: l); var clip = layers[l].clips[c]
            let t = try sourceTiming(timing, base, clip), baseline = clip.opacity(atSourceTime: t.start)
            try check(clip.opacityKeyframes.map { ($0.id, $0.time, $0.transition, $0.duration) }, t, excluding: id, layerID: layerID, clipID: clipID, property: .opacity)
            if t.transition == .smooth, !clip.opacityKeyframes.contains(where: { abs($0.time - t.start) < 1e-6 }) {
                clip.opacityKeyframes.append(VideoOpacityKeyframe(time: t.start, opacity: baseline, transition: .jump))
            }
            clip.opacityKeyframes.removeAll { $0.id == id || abs($0.time - t.end) < 1e-6 }
            clip.opacityKeyframes.append(VideoOpacityKeyframe(id: id ?? UUID(), time: t.end, opacity: value, transition: t.transition, duration: t.motion.duration, easeIn: t.easeIn, easeOut: t.easeOut))
            clip.opacityKeyframes.sort { $0.time < $1.time }; layers[l].clips[c] = clip
        case let .videoVolume(layerID, clipID, value, timing, base, id):
            let l = try layerIndex(layerID), c = try clipIndex(clipID, in: l); var clip = layers[l].clips[c]
            let t = try sourceTiming(timing, base, clip), baseline = clip.envelopeGain(atSourceTime: t.start)
            try check(clip.volumeKeyframes.map { ($0.id, $0.time, $0.transition, $0.duration) }, t, excluding: id, layerID: layerID, clipID: clipID, property: .volume)
            if t.transition == .smooth, !clip.volumeKeyframes.contains(where: { abs($0.time - t.start) < 1e-6 }) {
                clip.volumeKeyframes.append(VideoVolumeKeyframe(time: t.start, gain: baseline, transition: .jump))
            }
            clip.volumeKeyframes.removeAll { $0.id == id || abs($0.time - t.end) < 1e-6 }
            clip.volumeKeyframes.append(VideoVolumeKeyframe(id: id ?? UUID(), time: t.end, gain: value, transition: t.transition, duration: t.motion.duration, easeIn: t.easeIn, easeOut: t.easeOut))
            clip.volumeKeyframes.sort { $0.time < $1.time }; layers[l].clips[c] = clip
        case let .removeVideoAnimation(layerID, clipID, property, pointID):
            let l = try layerIndex(layerID), c = try clipIndex(clipID, in: l)
            let count: Int
            switch property {
            case .geometry: count = layers[l].clips[c].geometryKeyframes.count; layers[l].clips[c].geometryKeyframes.removeAll { $0.id == pointID }; guard count != layers[l].clips[c].geometryKeyframes.count else { throw EditorMutationError.invalid("That geometry change no longer exists.") }
            case .opacity: count = layers[l].clips[c].opacityKeyframes.count; layers[l].clips[c].opacityKeyframes.removeAll { $0.id == pointID }; guard count != layers[l].clips[c].opacityKeyframes.count else { throw EditorMutationError.invalid("That opacity change no longer exists.") }
            case .volume: count = layers[l].clips[c].volumeKeyframes.count; layers[l].clips[c].volumeKeyframes.removeAll { $0.id == pointID }; guard count != layers[l].clips[c].volumeKeyframes.count else { throw EditorMutationError.invalid("That volume change no longer exists.") }
            }
        default: throw EditorMutationError.invalid("Unsupported video operation.")
        }
        state.videoLayers = layers
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
    private func camera(_ requested: PIPPlacement, timing: EditorMutationTiming, state: inout EditState, checkConflicts: Bool = true) throws {
        var target = requested
        var baseline = state.cameraGeometry(at: timing.start)
        // Explicit zero and absent legacy metadata describe the same geometry.
        if target.fullscreen == 0 { target.fullscreen = nil }
        if baseline.fullscreen == 0 { baseline.fullscreen = nil }
        guard target != baseline else { return }
        if checkConflicts {
            let overlaps = conflicts(in: state).filter { $0.lane == .camera }
            guard overlaps.isEmpty else { throw EditorMutationError.conflicts(overlaps) }
        }
        if timing.transition == .smooth, !state.pipKeyframes.contains(where: { abs($0.time - timing.start) < 0.000_001 }) {
            state.upsert(PIPKeyframe(time: timing.start, placement: baseline, transition: .jump))
        }
        let motion = timing.motion
        state.upsert(PIPKeyframe(time: timing.end, placement: target, transition: motion.transition,
            duration: motion.duration, easeIn: motion.easeIn, easeOut: motion.easeOut))
    }

    private func cameraOpacity(_ opacity: Double, timing: EditorMutationTiming, state: inout EditState) {
        let baseline = state.cameraOpacity(at: timing.start)
        guard opacity != baseline else { return }
        if timing.transition == .smooth, !state.cameraOpacityKeyframes.contains(where: { abs($0.time - timing.start) < 0.000001 }) {
            state.cameraOpacityKeyframes.append(CameraOpacityKeyframe(time: timing.start, opacity: baseline))
        }
        let existing = state.cameraOpacityKeyframes.first { abs($0.time - timing.end) < 0.000001 }
        state.cameraOpacityKeyframes.removeAll { abs($0.time - timing.end) < 0.000001 }
        state.cameraOpacityKeyframes.append(CameraOpacityKeyframe(id: existing?.id ?? UUID(), time: timing.end, opacity: opacity,
            transition: timing.transition, duration: timing.motion.duration, easeIn: timing.easeIn, easeOut: timing.easeOut))
        state.cameraOpacityKeyframes.sort { $0.time < $1.time }
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
        let speedTiming = object(["start": ["type": "number", "minimum": 0], "end": ["type": "number", "minimum": 0],
            "transition": enumeration(["jump", "smooth"]), "easeIn": ["type": "number", "minimum": 0],
            "easeOut": ["type": "number", "minimum": 0]], optional: ["transition", "easeIn", "easeOut"])
        let anchors = enumeration(EditorRectAnchor.allCases.map(\.rawValue)), axes = enumeration(["horizontal", "vertical", "both"])
        let policy: [String: Any] = ["oneOf": [object(["kind": ["type": "string", "const": "preserve"]]),
            object(["kind": ["type": "string", "const": "fitRegion"]]), object(["kind": ["type": "string", "const": "absolute"], "scale": number(1, 3)])]]
        func operation(_ name: String, _ description: String, _ fields: [String: Any], optional: Set<String> = []) -> [String: Any] {
            var fields = fields; fields["operation"] = ["type": "string", "const": name]
            var value = object(fields, optional: optional); value["description"] = description
            return value
        }
        let overlay = object(["position": point, "scale": number(0.12, 0.5), "shape": enumeration(["original", "rectangle", "square", "circle"]),
            "aspectRatio": number(0.2, 5), "visible": ["type": "boolean"], "fullscreen": number(0, 1), "opacity": number(0, 1)], optional: ["position", "scale", "shape", "aspectRatio", "visible", "fullscreen", "opacity"])
        let source = object(["crop": point, "sourceZoom": number(1, 3)], optional: ["crop", "sourceZoom"])
        let pointer = object(["visible": ["type": "boolean"], "size": number(1, 4), "smoothing": number(0, 1), "clickHighlight": ["type": "boolean"]],
            optional: ["visible", "size", "smoothing", "clickHighlight"])
        let audio = object(["isMuted": ["type": "boolean"], "volume": number(0, 1), "fadeIn": number(0, 5), "fadeOut": number(0, 5)], optional: ["isMuted", "volume", "fadeIn", "fadeOut"])
        let canvas = object(["aspect": enumeration(["source", "wide", "portrait", "square"]), "padding": number(0, 0.2), "cornerRadius": number(0, 0.2),
            "background": object(["red": number(0, 1), "green": number(0, 1), "blue": number(0, 1)])], optional: ["aspect", "padding", "cornerRadius", "background"])
        let rectangle = object(["x": number(0, 1), "y": number(0, 1), "width": number(0.001, 1), "height": number(0.001, 1)])
        let videoGeometry = object(["rect": rectangle, "crop": rectangle, "fit": enumeration(["fit", "fill"])])
        let uuid: [String: Any] = ["type": "string", "format": "uuid"]
        let videoPatchFields: [String: Any] = ["sourceID": uuid, "start": ["type": "number", "minimum": 0],
            "end": ["type": "number", "minimum": 0], "sourceStart": ["type": "number", "minimum": 0], "rate": number(0.1, 8),
            "layout": enumeration(["screen", "camera", "custom"]), "geometry": videoGeometry, "opacity": number(0, 1),
            "volume": number(0, 1), "isMuted": ["type": "boolean"], "fadeIn": ["type": "number", "minimum": 0],
            "fadeOut": ["type": "number", "minimum": 0], "transition": enumeration(["cut", "crossfade"])]
        let videoAnimationFields: [String: Any] = ["layerID": uuid, "clipID": uuid, "timing": speedTiming,
            "timeBase": enumeration(["source", "project"]), "id": uuid]
        let videoAnimationHelp = "Independent source-anchored clip animation. timing defaults to SOURCE seconds of that clip's registered footage; timeBase=project converts through this clip's sourceStart/start/rate, including ease durations. It does not use Finished/output seconds. Translate Finished times with section=timing first. Smooth inserts a source baseline and arrives at end; jump start=end. Same-property overlaps reject. Optional id creates a stable new animation identity or revises that actual clip-scoped animation; different properties may overlap. Moving, trimming or changing clip rate preserves source automation, including hidden points."
        let layerFields: [String: Any] = ["id": ["type": "string", "format": "uuid"],
            "kind": enumeration(ContentLayerKind.allCases.map(\.rawValue)), "start": ["type": "number", "minimum": 0],
            "end": ["type": "number", "minimum": 0], "rect": rectangle, "endRect": rectangle,
            "text": ["type": "string", "maxLength": 4096], "assetID": ["type": "string", "format": "uuid"],
            "color": object(["red": number(0, 1), "green": number(0, 1), "blue": number(0, 1)]),
            "opacity": number(0, 1), "fontSize": number(0.005, 0.5), "bold": ["type": "boolean"],
            "strokeWidth": number(0.0005, 0.05), "filled": ["type": "boolean"], "rotation": number(-180, 180),
            "fadeIn": number(0, 60), "fadeOut": number(0, 60)]
        let layerOptional = Set(layerFields.keys).subtracting(["kind", "start", "end", "rect"])
        return [
            operation("addVideoLayer", "Add a named video layer above existing video layers, below graphic content. Optional id permits later commands in the SAME atomic batch to refer to it. Materializes legacy screen/camera without changing their adapters. Never imports media or deletes source bytes.", ["id": uuid, "name": ["type": "string", "minLength": 1, "maxLength": 128]], optional: ["id"]),
            operation("renameVideoLayer", "Rename an existing video layer without changing clips or source names.", ["layerID": uuid, "name": ["type": "string", "minLength": 1, "maxLength": 128]]),
            operation("removeVideoLayer", "Remove a video layer and its clips from this composition only. Registered sources and Undo references are retained; no file is deleted.", ["layerID": uuid]),
            operation("reorderVideoLayer", "Move a video layer to zero-based back-to-front stack index. Separate layers appear simultaneously; content graphics remain above the video stack.", ["layerID": uuid, "index": ["type": "integer", "minimum": 0]]),
            operation("addVideoClip", "Add registered footage to an existing video layer. patch requires sourceID and half-open PROJECT start/end within project duration. sourceStart is footage seconds; rate is source seconds per project second. Inspect video_sources for valid IDs; paths/URLs are forbidden. Defaults: sourceStart0, rate1, custom full-canvas fit, opacity1, volume1, unmuted, fades0, incoming crossfade. Same-layer overlap with incoming crossfade blends across the intersection; max two active clips. Separate layers stack simultaneous footage. Optional clipID supports same-batch references.", ["layerID": uuid, "clipID": uuid, "patch": object(videoPatchFields, optional: Set(videoPatchFields.keys).subtracting(["sourceID", "start", "end"]))], optional: ["clipID"]),
            operation("updateVideoClip", "Patch an existing clip; omitted values and all source-anchored automation remain unchanged. start/end use PROJECT seconds; sourceStart uses footage seconds. Source identity cannot change; add a new clip for different footage. Trim/rate changes never discard hidden automation. Layout screen/camera uses legacy screen/PIP animation; custom uses this clip's geometry.", ["layerID": uuid, "clipID": uuid, "patch": object(videoPatchFields, optional: Set(videoPatchFields.keys))]),
            operation("removeVideoClip", "Remove one clip only; keep source media registered and every historical reference available to Undo/Redo.", ["layerID": uuid, "clipID": uuid]),
            operation("videoGeometry", "Animate final-canvas normalized rect and source-normalized crop/fit on a custom-layout clip. " + videoAnimationHelp, videoAnimationFields.merging(["target": videoGeometry]) { _, b in b }, optional: ["timeBase", "id"]),
            operation("videoOpacity", "Animate clip opacity0...1 independently of geometry and volume. " + videoAnimationHelp, videoAnimationFields.merging(["opacity": number(0, 1)]) { _, b in b }, optional: ["timeBase", "id"]),
            operation("videoVolume", "Animate source-anchored volume multiplier0...1 on this clip, independently of its overall volume/mute and other clips. " + videoAnimationHelp, videoAnimationFields.merging(["gain": number(0, 1)]) { _, b in b }, optional: ["timeBase", "id"]),
            operation("removeVideoAnimation", "Delete one geometry/opacity/volume point by actual clip-scoped UUID, preserving other properties, sources and clips.", ["layerID": uuid, "clipID": uuid, "property": enumeration(["geometry", "opacity", "volume"]), "pointID": uuid]),
            operation("addContentLayer", "Add visible text, arrow, rectangle, circle or image above screen and camera. Times are half-open original-source seconds; rect is final-canvas normalized top-left bounds. Omitted id is allocated by the host. Default white, opacity1, fontSize0.045 of canvas height, bold, strokeWidth0.004 of short edge, outline shapes, fades0.2s. Arrow points right; rotation degrees is clockwise. Optional endRect animates smoothly across the entire layer interval. Image requires an existing assetID from inspect_editor section=layers; no paths or image bytes are accepted.",
                ["layer": object(layerFields, optional: layerOptional)]),
            operation("updateContentLayer", "Replace one existing content layer by its actual id, preserving stack position. Inspect section=layers first and include all fields to retain; omitted optional fields revert to documented defaults. Omitting endRect removes movement. Validation is atomic.",
                ["layer": object(layerFields, optional: layerOptional.subtracting(["id"]))]),
            operation("removeContentLayer", "Remove a visible content layer by id. Source media, images used by history, and reference boxes stay intact.", ["layerID": ["type": "string", "format": "uuid"]]),
            operation("reorderContentLayer", "Move a layer to a zero-based stack index; index0 is backmost, final index is frontmost. All content remains above screen and camera.",
                ["layerID": ["type": "string", "format": "uuid"], "index": ["type": "integer", "minimum": 0]]),
            operation("panScreen", "Move the original-source viewport center while preserving its zoom. Exact normalized focal coordinates; impossible bounds reject. Timing uses absolute source seconds.", ["center": point, "timing": timing]),
            operation("zoomScreen", "Set screen magnification1...3. Optional center is exact source-normalized focal point; omission retains current focus with normal bounds clamping.", ["scale": number(1, 3), "center": point, "timing": timing], optional: ["center"]),
            operation("alignScreen", "Align an exact viewport anchor to a raw Box anchor. Preserve scale for pan; explicit absolute/fitRegion permits zoom. No implicit10% padding. Unreachable alignment rejects.", ["regionID": ["type": "string"], "subjectAnchor": anchors, "targetAnchor": anchors, "axes": axes, "scalePolicy": policy, "timing": timing]),
            operation("cameraOverlay", "Patch only output-camera overlay fields. Position is fraction of AVAILABLE travel, scale is fraction of output width0.12...0.5. fullscreen0...1 animates preserved normal placement to exact output fill, with aspect-fill cropping;0restores normal shape/size. opacity0...1 fades only the camera using the same source-time motion/easing;0is transparent,1opaque. Opacity is an independent source-anchored track: it can overlap geometry animation and does not insert camera placement points. It overrides same-time saved legacy visibility events; unchanged geometry targets never bound fades. visible maps to independent opacity0/1 when opacity is omitted; visible=true permits explicit opacity, but visible=false with nonzero opacity rejects. Saved legacy visible-only events and Shape still switch at arrival.", ["patch": overlay, "timing": timing]),
            operation("alignCameraOverlay", "Move the camera outline without resizing or changing its source crop. Align to displayed Box using verified host geometry; unavailable geometry rejects. Source boxes project through arrival screen framing into final canvas.", ["regionID": ["type": "string"], "subjectAnchor": anchors, "targetAnchor": anchors, "axes": axes, "timing": timing]),
            operation("cameraSource", "Patch the camera image INSIDE its unchanged outline. Crop x/y are fractions of available oriented camera-source travel; sourceZoom1...3 is not overlay size.", ["patch": source, "timing": timing]),
            operation("pointer", "Patch whole-recording pointer style only; does not invent or retime captured pointer motion. Supply at least one field.", ["patch": pointer]),
            operation("speed", "Change exported recording speed, not transient preview speed. rate0.1...8 is source-seconds per output-second. timeBase defaults to source; output endpoints and ramps resolve through the PRE-EDIT timing map (ambiguous crossfades reject). timing arrives at end; smooth inserts the evaluated baseline at start and ramps to the target, which persists afterward. Jump has start=end. Keep source anchors unchanged. Optional preservesPitch changes the whole recording's audio-pitch policy (defaulttrue); an unchanged rate changes only that policy without creating a point. For a constant-speed section use jumps to the requested rate at its source start and back to the prior rate at its source end. Translate output references using the PRE-EDIT timing map before this batch; never recompute later command times midway through the same requested range.",
                ["rate": number(0.1, 8), "timing": speedTiming, "timeBase": enumeration(["source", "output"]),
                 "preservesPitch": ["type": "boolean"]], optional: ["timeBase", "preservesPitch"]),
            operation("removeAnimation", "Remove one lane-qualified screen, camera, cameraOpacity, speed, audioMicrophone or audioSystem component from inspect_editor edits (animationID=lane:UUID). Independent components at the same time remain. Initial camera, inherited opacity and whole-recording pointer style cannot be removed this way.",
                ["animationID": ["type": "string"]]),
            operation("audioTrack", "Patch one explicitly identified source role only. volume0...1 is its overall level; isMuted preserves its envelope. Unknown/mixed legacy tracks use master audio.", ["role": enumeration(RecordingAudioRole.allCases.map(\.rawValue)), "patch": object(["isMuted": ["type": "boolean"], "volume": number(0, 1)], optional: ["isMuted", "volume"])]),
            operation("audioGain", "Source-anchored volume envelope multiplier0...1 on one role, using shared timing/easing. Separate role changes may overlap. Optional id updates an existing change.", ["role": enumeration(RecordingAudioRole.allCases.map(\.rawValue)), "gain": number(0, 1), "timing": timing, "id": ["type": "string", "format": "uuid"]], optional: ["id"]),
            operation("removeAudioGain", "Remove one role volume change by its actual UUID.", ["role": enumeration(RecordingAudioRole.allCases.map(\.rawValue)), "pointID": ["type": "string", "format": "uuid"]]),
            operation("audio", "Patch master recorded audio: volume0...1, mute, fade seconds0...5 relative to kept trim. Preserves source offsets and relative levels. Supply at least one field.", ["patch": audio]),
            operation("canvas", "Patch whole-recording output presentation. Padding/corner radius are fractions0...0.2; background RGB0...1. Source coordinates and PIP travel remain unchanged.", ["patch": canvas]),
            operation("trim", "Keep a nonempty original-source interval. Does not retime keyframes or overwrite requested audio fades.", ["start": ["type": "number", "minimum": 0], "end": ["type": "number", "minimum": 0]]),
            operation("cutSection", "Exclude a half-open interval without deleting source edits. timeBase is required: source uses original seconds; output resolves against the current edited timeline and rejects endpoints inside an ambiguous crossfade. Touching/overlapping cuts merge, retaining the earliest existing cut identity and requested fade unless crossfade is supplied. New cuts default to a hard cut. crossfade is requested output seconds; effective overlap may be shorter when neighboring clips lack room.",
                ["start": ["type": "number", "minimum": 0], "end": ["type": "number", "minimum": 0],
                 "timeBase": enumeration(["source", "output"]), "crossfade": ["type": "number", "minimum": 0]], optional: ["crossfade"]),
            operation("restoreCut", "Restore an excluded source section by its actual cutID. Keeps source animations, boxes and identities unchanged; removes that cut's join. Later output coordinates change.", ["cutID": ["type": "string", "format": "uuid"]]),
            operation("cutTransition", "Set the requested crossfade at a cutID in output seconds; zero is a hard cut. Retains requested duration even if effective overlap must shrink to fit neighboring clips. Inspect the time map for requested and effective durations.",
                ["cutID": ["type": "string", "format": "uuid"], "duration": ["type": "number", "minimum": 0]])]
    }
    static func schemaData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["oneOf": schemaDescriptors], options: [.sortedKeys])
    }
    static var documentation: [String: Any] {
        ["mutation_schema": ["oneOf": schemaDescriptors],
         "legacy_command_schema": ["oneOf": legacySchemas],
         "units": ["screen": "Original source-normalized focal center; top-left origin. Zoom1...3.",
                   "content": "Visible content layers use original-source start/end seconds and final-canvas normalized rect bounds. They are independent of reference boxes and screen zoom. Inspect section=layers for IDs, z-order and registered image metadata; image bytes are never returned.",
                   "cameraOverlay": "Position fractions of available output-canvas travel; normal scale fraction of output width0.12...0.5. fullscreen0...1 blends normal outline to exact canvas fill without erasing normal shape/placement. opacity0...1 continuously fades only the camera; legacy absence defaults to1.",
                   "cameraSource": "Oriented camera crop travel fractions0...1; sourceZoom1...3.",
                   "timing": "Absolute original-source seconds. Smooth start<end; jump start=end. End precedes recording end.",
                   "cuts": "cutSection requires timeBase source or output, with a half-open start<end range. Crossfade duration is output seconds; inspect requested/effective duration. Cuts preserve every source-time edit.",
                   "alignment": "Exact raw Box anchors; no implicit padding or silent clamp. PIP-to-Box needs verified host geometry.",
                   "partial_updates": "Unspecified patch fields remain unchanged. Shape and saved legacy visibility events are discrete arrival changes. New visible patches map to independent camera opacity0/1. Opacity is continuous0...1 and uses its own source timing/easing, independent of geometry.",
                   "conflicts": "Existing same-lane movements must be resolved explicitly. Screen, camera geometry and camera opacity are independent lanes."],
         "examples": [
            ["action": "mutate", "mutation": ["operation": "zoomScreen", "scale": 2,
                "timing": ["start": 2, "end": 5, "transition": "smooth"]]],
            ["action": "mutate", "mutation": ["operation": "cameraOverlay", "patch": ["position": ["x": 0, "y": 0]],
                "timing": ["start": 2, "end": 5, "transition": "smooth"]]],
            ["action": "mutate", "mutation": ["operation": "audio", "patch": ["volume": 0.5, "fadeOut": 1]]]]]
    }

    /// nil discovers operation groups/subjects; '*' requests the full reference.
    /// An exact operation returns one complete command schema, not every track.
    static func describe(operation: String?) throws -> [String: Any] {
        guard let operation else {
            return ["operations": [
                "screen": ["panScreen", "zoomScreen", "alignScreen", "frameRegion", "fullFrame", "holdFraming", "reviseFraming", "moveBetweenEdits", "moveForDuration"],
                "camera": ["cameraOverlay", "alignCameraOverlay", "cameraSource"],
                "content": ["addContentLayer", "updateContentLayer", "removeContentLayer", "reorderContentLayer"],
                "video": ["addVideoLayer", "renameVideoLayer", "removeVideoLayer", "reorderVideoLayer", "addVideoClip", "updateVideoClip", "removeVideoClip", "videoGeometry", "videoOpacity", "videoVolume", "removeVideoAnimation"],
                "global": ["pointer", "audio", "audioTrack", "audioGain", "removeAudioGain", "canvas", "trim"],
                "timing": ["cutSection", "restoreCut", "cutTransition", "speed"],
                "boxes": ["addRegion", "labelRegion", "removeRegion"],
                "edit_marks": ["createEdit", "moveEdit", "removeEdit", "removeScreenFraming", "removeAnimation"]],
                "subjects": [
                    "videoClip": "One occurrence of registered footage in a named video layer. Placement is project-authoring time; independent geometry/opacity/volume animation is footage-source time. Layer order is back-to-front and same-layer overlapping clips crossfade. Inspect video_sources/video_layers/video_clips on demand.",
                    "screen": "Main recorded screen viewport. panScreen preserves zoom; zoomScreen changes screen magnification; alignScreen matches Box anchors. These do not resize the PIP camera.",
                    "cameraOverlay": "PIP camera outline on the final canvas. cameraOverlay moves, resizes, reshapes or fades it with opacity0...1; fullscreen=1 fills the canvas and 0 restores normal placement. alignCameraOverlay aligns its outline to a Box.",
                    "cameraSource": "Camera image inside the unchanged PIP outline. cameraSource changes sourceZoom or crop, preserving the overlay size/position and main screen framing."],
                "units": "Animation seconds are original source time. cutSection requires explicit timeBase source/output; crossfade duration is output seconds. Screen points are normalized source focal centers; camera positions are fractions of available OUTPUT travel. Pan preserves size. Exact alignment rejects unreachable bounds. Get one operation's schema before apply_edits; unknown camera/screen intent requires clarification.",
                "query": "Specify operation by exact name; '*' returns all schemas explicitly."]
        }
        if operation == "*" { return documentation }
        if let schema = schemaDescriptors.first(where: {
            (($0["properties"] as? [String: Any])?["operation"] as? [String: Any])?["const"] as? String == operation
        }) {
            let command: [String: Any] = ["type": "object", "properties": ["action": ["type": "string", "const": "mutate"], "mutation": schema],
                "required": ["action", "mutation"], "additionalProperties": false]
            let units = operation.contains("Video") || ["videoGeometry", "videoOpacity", "videoVolume"].contains(operation)
                ? "Video clip start/end are project-authoring seconds before global cuts/speed. sourceStart and automation are footage-source seconds. Automation timeBase=project converts through the selected clip; Finished/output requires explicit timing-map translation. Inspect video_sources/video_layers/video_clips on demand. Stack is back-to-front; same-layer max-two overlaps crossfade when incoming transition=crossfade. No operation accepts arbitrary paths or deletes media."
                : operation == "speed"
                ? "rate is source seconds per output second (0.1...8). timeBase defaults to source; output times/ramps resolve through the original batch map and reject ambiguous crossfades. Smooth start<end; jump start=end; arrival may equal recording end. The target persists until the next speed point. preservesPitch is a whole-recording policy. This changes exported timing; control_preview.set_rate does not."
                : ["cutSection", "restoreCut", "cutTransition"].contains(operation)
                ? "Cut ranges require explicit timeBase source/output and start<end. Output endpoints with two different contributing source instants reject; choose source coordinates explicitly. Crossfade duration is requested output seconds, with effective overlap reported by the time map. Omitted crossfade preserves an existing merged cut's fade and defaults to zero only for a new cut. null is unsupported. Source edits are preserved."
                : "Absolute original-source start/end; duration=end-start. Smooth start<end; jump start=end. Unspecified patch fields stay unchanged; null is unsupported. Camera overlay, camera source crop, and screen viewport are different subjects. Bounds/overlaps fail atomically."
            return ["operation": operation, "command_schema": command, "units": units]
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

/// Shared pure timing edit boundary for native UI and command adapters. Source
/// keyframes/guides are deliberately not rewritten when footage is omitted.
enum EditorCutEditing {
    static func sourceRange(start: Double, end: Double, timeBase: EditorCutTimeBase,
                            state: EditState, duration: Double) throws -> Range<Double> {
        guard start.isFinite, end.isFinite, start >= 0, start < end else {
            throw EditorMutationError.invalid("Choose a nonempty, finite cut interval with start before end.")
        }
        let map = try RecordingTimeMap(duration: duration, trimStart: state.trimStart, trimEnd: state.trimEnd, cuts: state.cuts,
            speedKeyframes: state.speedKeyframes)
        if timeBase == .source {
            guard end <= duration else { throw EditorMutationError.invalid("The source cut must be inside the original recording.") }
            return start..<end
        }
        guard end <= map.outputDuration else { throw EditorMutationError.invalid("The output cut must be inside the edited recording.") }
        func source(_ output: Double) throws -> Double {
            let samples = map.samples(at: output).filter { $0.weight > 0 }
            guard let first = samples.first else {
                throw EditorMutationError.invalid("That output cut boundary has no source frame.")
            }
            guard samples.allSatisfy({ abs($0.sourceTime - first.sourceTime) <= 0.000_000_001 }) else {
                throw EditorMutationError.invalid("That output cut boundary is inside a crossfade with two different source frames. Use explicit source coordinates or move the boundary outside the crossfade.")
            }
            return first.sourceTime
        }
        let sourceStart = try source(start), sourceEnd = try source(end)
        guard sourceStart < sourceEnd else {
            throw EditorMutationError.invalid("Those output boundaries do not define an ordered source interval.")
        }
        return sourceStart..<sourceEnd
    }

    static func cutting(start: Double, end: Double, timeBase: EditorCutTimeBase,
                        crossfade: Double? = nil, state: EditState, duration: Double) throws -> EditState {
        if let crossfade, !crossfade.isFinite || crossfade < 0 {
            throw EditorMutationError.invalid("Crossfade duration must be a finite, nonnegative number of output seconds.")
        }
        let range = try sourceRange(start: start, end: end, timeBase: timeBase, state: state, duration: duration)
        var lower = range.lowerBound, upper = range.upperBound
        var merged: [RecordingCut] = []
        var remaining: [RecordingCut] = []
        for cut in state.cuts.sorted(by: { $0.start < $1.start }) {
            if cut.end >= lower && cut.start <= upper {
                lower = min(lower, cut.start); upper = max(upper, cut.end)
                merged.append(cut)
            } else { remaining.append(cut) }
        }
        let first = merged.first
        remaining.append(RecordingCut(id: first?.id ?? UUID(), start: lower, end: upper,
            crossfade: crossfade ?? first?.crossfade ?? 0))
        var next = state
        next.cuts = remaining.sorted { $0.start < $1.start }
        // Reject removing the complete trim; effective fades are derived while
        // their requested values stay intact for future restore/trim changes.
        _ = try RecordingTimeMap(duration: duration, trimStart: next.trimStart, trimEnd: next.trimEnd, cuts: next.cuts,
            speedKeyframes: next.speedKeyframes)
        return next
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
