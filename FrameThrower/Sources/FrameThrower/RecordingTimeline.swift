import AppKit
import SwiftUI
import CryptoKit

struct RecordingTimelineMarker: Identifiable, Equatable {
    let id: UUID
    let time: Double
    let help: String
    var label: String? = nil
    var transitionStart: Double? = nil
    var easeIn: Double = 0
    var easeOut: Double = 0
    var movable: Bool = true
    var minimumTime: Double = 0
    var maximumTime: Double? = nil
}


/// UI-only projection. Source identities remain authoritative; fragments never
/// become new document edits, and their velocity curves keep the source clock.
struct TimelineSourceEnvelope: Equatable {
    let animation: TimelineAnimation
    let sourceOffset: Double
    var clip: RecordingTimeMap.Clip? = nil
    func sourceTime(at output: Double) -> Double { clip?.sourceTime(at: output) ?? output + sourceOffset }
    func outputTime(for source: Double) -> Double { clip?.outputTime(for: source) ?? source - sourceOffset }
}
struct TimelineClipBand: Equatable, Identifiable {
    let id: String
    let start: Double
    let end: Double
    let excluded: Bool
    let label: String
}
struct TimelineCutMarker: Equatable, Identifiable {
    let id: UUID
    let start: Double
    let end: Double
    let help: String
    var label: String? = nil
    var showsTransitionSpan = true
    var badgeLabel: String { label ?? (end > start ? String(format: "%.3gs", end - start) : "Cut") }
}
/// A visible retained fragment maps the shared ruler to clip authoring time.
struct TimelineVideoPart: Equatable {
    var start: Double
    var end: Double
    var authoringStart: Double
    var authoringEnd: Double
    var map: RecordingTimeMap.Clip? = nil
    var timelineMap: RecordingTimeMap? = nil
    var branchIndex: Int? = nil
    func projectTime(at time: Double) -> Double { map?.sourceTime(at: time) ?? time }
    func displayTime(at time: Double) -> Double { map?.outputTime(for: time) ?? time }
}
struct TimelineVideoRow: Equatable {
    var layerID: UUID
    var label: String
    var clip: VideoClip
    var hasAudio: Bool
    var parts: [TimelineVideoPart]
    var editable: Bool
    var layerName: String? = nil
    var sourceName: String? = nil
    var isCamera = false
    static let height: CGFloat = 48
    static func make(project: RecordingProject, state: EditState, map: RecordingTimeMap?) -> [Self] {
        return project.effectiveVideoLayers(in: state).flatMap { layer in
            layer.clips.sorted { $0.start < $1.start }.map { clip in
                let source = project.videoSources.first { $0.id == clip.sourceID }
                let parts: [TimelineVideoPart]
                if let map {
                    parts = map.clips.enumerated().compactMap { index, branch in
                        let a = max(clip.start, branch.sourceStart), b = min(clip.end, branch.sourceEnd)
                        guard a < b else { return nil }
                        return .init(start: branch.outputTime(for: a), end: branch.outputTime(for: b),
                            authoringStart: a, authoringEnd: b, map: branch, timelineMap: map, branchIndex: index)
                    }
                } else { parts = [.init(start: clip.start, end: clip.end, authoringStart: clip.start, authoringEnd: clip.end)] }
                return Self(layerID: layer.id, label: layer.name == source?.name ? layer.name : layer.name + " · " + (source?.name ?? "Missing source"),
                    clip: clip, hasAudio: source?.hasAudio != false, parts: parts, editable: !parts.isEmpty,
                    layerName: layer.name, sourceName: source?.name, isCamera: clip.layout == .camera || source?.role == .camera)
            }
        }
    }
}

/// One ordered row model drives native drawing, hit testing and SwiftUI height.
/// Occurrence projection stays independent: clips in one layer share one row.
struct TimelineTrackLayout: Equatable {
    enum RowID: Hashable { case cuts, media(UUID), volume(UUID), animation(TimelineAnimationLane) }
    struct Row: Equatable {
        var id: RowID
        var title: String
        var help: String
        var depth = 0
        var height: CGFloat = 30
    }
    var rows: [Row]
    static let top: CGFloat = 54
    static let footer: CGFloat = 24
    var contentHeight: CGFloat { Self.top + rows.reduce(0) { $0 + $1.height } + Self.footer }
    func offset(of id: RowID) -> CGFloat? {
        var offset = Self.top
        for row in rows { if row.id == id { return offset }; offset += row.height }
        return nil
    }
    static func make(videoRows: [TimelineVideoRow], animations: [TimelineAnimation],
                     selectedAnimationID: TimelineAnimationID? = nil,
                     pinnedAnimationLanes: Set<TimelineAnimationLane> = [],
                     expandedVideoVolumeLayerIDs: Set<UUID> = [], selectedVideoVolumeID: UUID? = nil,
                     conflictSpans: [EditorConflictSpan] = [], pointerClickTimes: [Double] = [],
                     hasPointerRecording: Bool = false, recordedAudioRoles: Set<RecordingAudioRole> = [],
                     showsClipLane: Bool = false) -> Self {
        var visible = Set(animations.filter { !$0.isPlaceholder }.map(\.lane))
        visible.formUnion(pinnedAnimationLanes)
        if let selected = animations.first(where: { $0.id == selectedAnimationID && !$0.isPlaceholder }) { visible.insert(selected.lane) }
        if !conflictSpans.isEmpty { visible.insert(.screen) }
        if hasPointerRecording || !pointerClickTimes.isEmpty { visible.insert(.pointer) }
        visible.formUnion(recordedAudioRoles.map { $0 == .microphone ? .audioMicrophone : .audioSystem })
        var rows: [Row] = []
        if showsClipLane { rows.append(.init(id: .cuts, title: "Cuts", help: "Select a range to remove it, or select a join to adjust its crossfade or restore footage.")) }
        var layers: [UUID] = []
        for row in videoRows where !layers.contains(row.layerID) { layers.append(row.layerID) }
        var placed = Set<TimelineAnimationLane>()
        func animation(_ lane: TimelineAnimationLane, parent: String? = nil) {
            guard visible.contains(lane), placed.insert(lane).inserted else { return }
            let title: String = switch lane {
            case .screen, .camera: "Framing"
            case .cameraOpacity: "Opacity"
            case .speed: "Speed"
            case .pointer: "Pointer"
            case .audioMicrophone: "Microphone"
            case .audioSystem: "System audio"
            }
            let help: String = switch lane {
            case .screen: "Screen zoom and pan animations. Select a span to change its timing, framing or easing."
            case .camera: "Camera/PIP position, size and crop animations."
            case .cameraOpacity: "Camera/PIP fades. These change camera opacity independently of the screen."
            case .speed: "Recorded-video playback speed animations; review speed is a separate transport preference."
            case .pointer: "Recorded pointer movement and clicks. Select to adjust the pointer's appearance."
            case .audioMicrophone: "Recorded microphone volume automation."
            case .audioSystem: "Recorded system-audio volume automation."
            }
            let name = parent == nil && (lane == .screen || lane == .camera || lane == .cameraOpacity)
                ? (lane == .screen ? "Screen " : "PIP ") + title.lowercased() : title
            rows.append(.init(id: .animation(lane), title: name, help: help, depth: parent == nil ? 0 : 1))
        }
        for layerID in layers {
            let clips = videoRows.filter { $0.layerID == layerID }
            guard let first = clips.first else { continue }
            let name = first.layerName ?? first.label
            let camera = clips.contains(where: \.isCamera)
            let title = camera && !name.localizedCaseInsensitiveContains("PIP") ? name + " / PIP" : name
            rows.append(.init(id: .media(layerID), title: title,
                help: title + ". Clips in this layer play in sequence; overlapping clips crossfade. Drag a clip to move it; select it to trim or edit it."))
            if clips.contains(where: { $0.clip.layout == .screen }) {
                animation(.screen, parent: title); animation(.audioSystem, parent: title)
            }
            if camera { animation(.camera, parent: title); animation(.cameraOpacity, parent: title); animation(.audioMicrophone, parent: title) }
            let hasEnvelope = clips.contains { !$0.clip.volumeKeyframes.isEmpty }
            let selectedVolume = selectedVideoVolumeID.map { selected in clips.contains { $0.clip.volumeKeyframes.contains { $0.id == selected } } } ?? false
            let roleAwareScreen = !recordedAudioRoles.isEmpty && clips.contains { $0.clip.sourceID == VideoSource.legacyScreenID }
            if clips.contains(where: \.hasAudio) && (hasEnvelope || selectedVolume || (!roleAwareScreen && expandedVideoVolumeLayerIDs.contains(layerID))) {
                rows.append(.init(id: .volume(layerID), title: "Clip audio", help: "\(title) source-volume envelope. Click the curve to add a point; drag points to adjust level and time.", depth: 1, height: 26))
            }
        }
        for lane in TimelineAnimationLane.allCases { animation(lane) }
        return Self(rows: rows)
    }
}
enum TimelineVideoHandle: Equatable { case move, start, end, volume(UUID) }
struct TimelineVideoEdit {
    var layerID: UUID
    var clipID: UUID
    var handle: TimelineVideoHandle
    var projectTime: Double
    var gain: Double = 1
}
struct TimelineSpeedSample: Equatable {
    var time: Double
    var rate: Double
}

enum TimelineSpeedProfile {
    /// Draw actual source rates through holds; do not draw the movement's
    /// velocity envelope, which returns to zero at arrival.
    static func curves(points: [RecordingSpeedKeyframe], duration: Double, map: RecordingTimeMap?) -> [[TimelineSpeedSample]] {
        var knots = [0.0, duration], previous = 0.0
        for point in points {
            knots.append(point.time)
            if point.transition == .smooth {
                let start = max(previous, point.time - point.duration)
                let ramps = MotionInterpolation.rampDurations(duration: point.time - start, easeIn: point.easeIn, easeOut: point.easeOut)
                knots += [start, start + ramps.easeIn, point.time - ramps.easeOut]
                for (beginning, length) in [(start, ramps.easeIn), (point.time - ramps.easeOut, ramps.easeOut)] where length > 0 {
                    for index in 1..<16 { knots.append(beginning + length * Double(index) / 16) }
                }
            } else if point.time > 0 { knots.append(point.time.nextDown) }
            previous = point.time
        }
        knots = Array(Set(knots)).sorted()
        func rate(_ time: Double) -> Double {
            var low = 0, high = points.count
            while low < high { let mid = (low + high) / 2; if points[mid].time <= time { low = mid + 1 } else { high = mid } }
            let prior = low > 0 ? points[low - 1] : nil
            guard low < points.count else { return prior?.rate ?? 1 }
            let point = points[low]
            let progress = MotionInterpolation.progress(at: time, from: prior?.time ?? 0, to: point.time,
                duration: point.duration, transition: point.transition, easeIn: point.easeIn, easeOut: point.easeOut)
            return MotionInterpolation.blend(prior?.rate ?? 1, point.rate, progress: progress)
        }
        let ranges: [(Double, Double, RecordingTimeMap.Clip?)] = map.map { $0.clips.map { ($0.sourceStart, $0.sourceEnd, Optional($0)) } } ?? [(0, duration, nil)]
        let resolution = max(2, 512 / max(1, ranges.count))
        return ranges.map { start, end, clip in
            var times = knots.filter { $0 >= start && $0 <= end }
            for index in 0...resolution { times.append(start + (end - start) * Double(index) / Double(resolution)) }
            return Set(times).sorted().map { .init(time: clip?.outputTime(for: $0) ?? $0, rate: rate($0)) }
        }
    }
}

struct TimelineOutputProjection {
    var animations: [TimelineAnimation] = []
    var sourceIDs: [TimelineAnimationID: TimelineAnimationID] = [:]
    var envelopes: [TimelineAnimationID: TimelineSourceEnvelope] = [:]
    var editableBindings: [TimelineAnimationID: FinishedTimelineBinding] = [:]

    init(animations: [TimelineAnimation], map: RecordingTimeMap) {
        for original in animations {
            if original.lane == .pointer {
                var item = original; item.start = 0; item.end = map.outputDuration; item.editable = false
                self.animations.append(item); sourceIDs[item.id] = original.id
                continue
            }
            for (index, clip) in map.clips.enumerated() {
                let first = max(original.start, clip.sourceStart), last = min(original.end, clip.sourceEnd)
                if original.isInstant {
                    guard original.start >= clip.sourceStart,
                          original.start < clip.sourceEnd || (index == map.clips.count - 1 && original.start == clip.sourceEnd) else { continue }
                } else if first >= last { continue }
                var item = original
                let key = "\(original.lane.rawValue):\(original.componentID.uuidString):\(clip.sourceStart.bitPattern):\(clip.sourceEnd.bitPattern)"
                let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
                item.id = TimelineAnimationID(lane: original.lane, componentID: UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])))
                item.start = clip.outputTime(for: first); item.end = clip.outputTime(for: last)
                item.editable = original.editable
                item.showsStartHandle = original.start >= first && original.start <= last
                item.showsEndHandle = original.end >= first && original.end <= last
                let incoming = original.start + original.easeIn, outgoing = original.end - original.easeOut
                item.showsEaseInHandle = incoming >= first && incoming <= last
                item.showsEaseOutHandle = outgoing >= first && outgoing <= last
                item.easeIn = max(0, min(item.duration, clip.outputTime(for: incoming) - item.start))
                item.easeOut = max(0, min(item.duration, item.end - clip.outputTime(for: outgoing)))
                item.help = original.help + " Drag this visible span to retime the edit. Cut edges are not animation endpoints."
                self.animations.append(item); sourceIDs[item.id] = original.id
                envelopes[item.id] = TimelineSourceEnvelope(animation: original, sourceOffset: clip.sourceStart - clip.outputStart, clip: clip)
                if original.editable {
                    editableBindings[item.id] = FinishedTimelineBinding(original: original, clip: clip, branchIndex: index,
                        visibleSourceStart: first, visibleSourceEnd: last)
                }
            }
        }
    }
}

struct FinishedTimelineBinding {
    let original: TimelineAnimation
    let clip: RecordingTimeMap.Clip
    let branchIndex: Int
    let visibleSourceStart: Double
    let visibleSourceEnd: Double
    var sourceBounds: ClosedRange<Double> { clip.sourceStart...clip.sourceEnd }

    static func make(animation: TimelineAnimation, map: RecordingTimeMap) -> Self? {
        guard animation.editable, animation.lane != .pointer else { return nil }
        for (index, clip) in map.clips.enumerated() {
            let first = max(animation.start, clip.sourceStart), last = min(animation.end, clip.sourceEnd)
            if first < last || (animation.isInstant && animation.start >= clip.sourceStart && animation.start < clip.sourceEnd) {
                return Self(original: animation, clip: clip, branchIndex: index, visibleSourceStart: first, visibleSourceEnd: last)
            }
        }
        return nil
    }

    func sourceDrag(_ request: AnimationDrag) -> AnimationDrag {
        let anchor: Double = switch request.handle {
        case .move: visibleSourceStart
        case .start: original.start
        case .end: original.end
        case .easeIn: original.start + original.easeIn
        case .easeOut: original.end - original.easeOut
        }
        let destination = clip.sourceTime(at: clip.outputTime(for: anchor) + request.deltaSeconds)
        return AnimationDrag(id: original.id, handle: request.handle, deltaSeconds: destination - anchor,
            push: request.push, snapTolerance: 0)
    }
}

enum FinishedTimelineEditing {
    /// Visible fragments name a real source edit and the branch touched by the
    /// gesture. The source solver, not a hidden alternate mode, owns its bounds.
    static func changes(_ request: AnimationDrag, animations: [TimelineAnimation], map: RecordingTimeMap,
                        sourceDuration: Double) -> [TimelineAnimation]? {
        let projection = TimelineOutputProjection(animations: animations, map: map)
        guard let binding = projection.editableBindings[request.id], request.deltaSeconds.isFinite,
              let source = TimelineAnimationSolver.sourceDrag(request, original: binding.original, map: map,
                branchIndex: binding.branchIndex, moveAnchor: binding.visibleSourceStart) else { return nil }
        return TimelineAnimationSolver.solve(source, animations: animations, duration: sourceDuration)
    }

    static func projectedPreview(_ request: AnimationDrag, animations: [TimelineAnimation], map: RecordingTimeMap,
                                 sourceDuration: Double) -> [TimelineAnimation]? {
        guard let changes = changes(request, animations: animations, map: map, sourceDuration: sourceDuration) else { return nil }
        let values = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        return TimelineOutputProjection(animations: animations.map { values[$0.id] ?? $0 }, map: map).animations
    }
}

struct RecordingTimeline: NSViewRepresentable {
    static let animationLaneHeight: CGFloat = 180
    static let clipLaneHeight: CGFloat = 210
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let playhead: Double
    var onInteractionBegan: () -> Void
    var onSeek: (Double) -> Void
    var onScrubBegan: () -> Void = {}
    var onScrubEnded: () -> Void = {}
    var onTrim: (Double, Double) -> Void
    var onTrimPlayhead: (Double) -> Void = { _ in }
    var edits: [RecordingTimelineMarker] = []
    var selectedEditID: UUID?
    var onSelectEdit: (UUID) -> Void = { _ in }
    var frameDuration: Double = 1.0 / 30
    var onMoveEdit: (UUID, Double, Bool) -> Void = { _, _, _ in }
    var onCancelMoveEdit: () -> Void = {}
    var onDeselectEdit: () -> Void = {}
    var onCancelEdit: () -> Void = {}
    var fitRequest: UUID?
    var conflictSpans: [EditorConflictSpan] = []
    var conflictOverlaps: [ClosedRange<Double>] = []
    var showsAnimationLanes = false
    var pointerClickTimes: [Double] = []
    var animations: [TimelineAnimation] = []
    var selectedAnimationID: TimelineAnimationID?
    var onSelectAnimation: (TimelineAnimationID) -> Void = { _ in }
    var onAnimationEdit: (AnimationDrag, Bool) -> Void = { _, _ in }
    var animationDragProjection: ((AnimationDrag) -> [TimelineAnimation]?)? = nil
    var onAnimationCancel: () -> Void = {}
    var onDeleteAnimation: (TimelineAnimationID) -> Void = { _ in }

    var showsClipLane = false
    var showsCameraOpacityLane = false
    var showsTrimHandles = true
    var allowsSeekingOutsideTrim = false
    var clockID = "source"
    var clipBands: [TimelineClipBand] = []
    var cutMarkers: [TimelineCutMarker] = []
    var selectedCutID: UUID?
    var selectedRange: ClosedRange<Double>?
    var onRangeSelection: (ClosedRange<Double>?) -> Void = { _ in }
    var onSelectCut: (UUID) -> Void = { _ in }
    var onCutRange: () -> Void = {}
    var onRestoreCut: (UUID) -> Void = { _ in }
    var onCutAnchor: (UnitPoint) -> Void = { _ in }
    var sourceEnvelopes: [TimelineAnimationID: TimelineSourceEnvelope] = [:]
    var speedCurves: [[TimelineSpeedSample]] = []
    var videoRows: [TimelineVideoRow] = []
    var rowLayout: TimelineTrackLayout? = nil
    var pinnedAnimationLanes: Set<TimelineAnimationLane> = []
    var expandedVideoVolumeLayerIDs: Set<UUID> = []
    var hasPointerRecording = false
    var recordedAudioRoles: Set<RecordingAudioRole> = []
    var onToggleVideoVolume: (UUID) -> Void = { _ in }
    var selectedVideoClipID: UUID? = nil
    var selectedVideoVolumeID: UUID? = nil
    var onSelectVideo: (UUID?, UUID?, UUID?) -> Void = { _, _, _ in }
    var onVideoEdit: (TimelineVideoEdit, Bool) -> Void = { _, _ in }
    var onVideoCancel: () -> Void = {}
    var onDeleteVideo: (UUID, UUID, UUID?) -> Void = { _, _, _ in }

    func makeNSView(context: Context) -> RecordingTimelineView { RecordingTimelineView() }
    func updateNSView(_ view: RecordingTimelineView, context: Context) {
        view.setClock(clockID, duration: duration)
        view.showsClipLane = showsClipLane
        view.showsCameraOpacityLane = showsCameraOpacityLane
        view.showsTrimHandles = showsTrimHandles
        view.allowsSeekingOutsideTrim = allowsSeekingOutsideTrim
        view.clipBands = clipBands
        view.cutMarkers = cutMarkers
        view.selectedCutID = selectedCutID
        view.selectedRange = selectedRange
        view.onRangeSelection = onRangeSelection
        let selectCut = onSelectCut, anchorCut = onCutAnchor
        view.onSelectCut = { [weak view] id in
            if let anchor = view?.cutAnchor(for: id) { anchorCut(anchor) }
            selectCut(id)
        }
        view.onCutRange = onCutRange
        view.onRestoreCut = onRestoreCut
        view.sourceEnvelopes = sourceEnvelopes
        view.speedCurves = speedCurves
        view.videoRows = videoRows
        view.rowLayout = rowLayout
        view.pinnedAnimationLanes = pinnedAnimationLanes
        view.expandedVideoVolumeLayerIDs = expandedVideoVolumeLayerIDs
        view.hasPointerRecording = hasPointerRecording
        view.recordedAudioRoles = recordedAudioRoles
        view.onToggleVideoVolume = onToggleVideoVolume
        view.selectedVideoClipID = selectedVideoClipID
        view.selectedVideoVolumeID = selectedVideoVolumeID
        view.onSelectVideo = onSelectVideo; view.onVideoEdit = onVideoEdit
        view.onVideoCancel = onVideoCancel; view.onDeleteVideo = onDeleteVideo
        view.trimStart = trimStart
        view.trimEnd = trimEnd
        view.playhead = playhead
        view.onInteractionBegan = onInteractionBegan
        view.onScrubBegan = onScrubBegan
        view.onScrubEnded = onScrubEnded
        view.onSeek = onSeek
        view.onTrim = onTrim
        view.onTrimPlayhead = onTrimPlayhead
        view.edits = edits
        view.selectedEditID = selectedEditID
        view.onSelectEdit = onSelectEdit
        view.frameDuration = frameDuration
        view.onMoveEdit = onMoveEdit
        view.onCancelMoveEdit = onCancelMoveEdit
        view.onDeselectEdit = onDeselectEdit
        view.onCancelEdit = onCancelEdit
        view.conflictSpans = conflictSpans
        view.conflictOverlaps = conflictOverlaps
        view.showsAnimationLanes = showsAnimationLanes
        view.pointerClickTimes = pointerClickTimes
        view.animationSpans = animations
        view.selectedAnimationID = selectedAnimationID
        view.onSelectAnimation = onSelectAnimation
        view.onAnimationEdit = onAnimationEdit
        view.animationDragProjection = animationDragProjection
        view.onAnimationCancel = onAnimationCancel
        view.onDeleteAnimation = onDeleteAnimation
        view.fit(request: fitRequest)
        view.installPinnedTimeRuler()
    }
}

/// A single source-time axis for the playhead and both trim boundaries. Native
/// mouse events keep hit-testing explicit when the playhead meets a trim handle.
/// NSScrollView keeps this numeric ruler visible while its document tracks scroll.
@MainActor
final class TimelineTimeRulerView: NSRulerView {
    weak var timeline: RecordingTimelineView?
    override var isFlipped: Bool { true }
    init(scrollView: NSScrollView, timeline: RecordingTimelineView) {
        self.timeline = timeline
        super.init(scrollView: scrollView, orientation: .horizontalRuler)
        ruleThickness = 20
        reservedThicknessForMarkers = 0
        clientView = timeline
        setAccessibilityElement(true)
        setAccessibilityLabel("Timeline time ruler")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let timeline else { return }
        NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: bounds).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]
        for tick in timeline.timeRulerTicks() {
            let position = convert(CGPoint(x: timeline.x(for: tick.time), y: 0), from: timeline).x
            let text = tick.label as NSString, width = text.size(withAttributes: attributes).width
            text.draw(at: CGPoint(x: min(max(position - width / 2, 0), bounds.width - width), y: 2), withAttributes: attributes)
            let path = NSBezierPath(); path.move(to: CGPoint(x: position, y: 15)); path.line(to: CGPoint(x: position, y: 20))
            NSColor.tertiaryLabelColor.setStroke(); path.stroke()
        }
    }
}

@MainActor
final class RecordingTimelineView: NSView, NSViewToolTipOwner {
    struct MarkerLabel: Equatable {
        let id: UUID
        let text: String
        let frame: CGRect
        let overlaysMarker: Bool
    }
    struct MarkerGroup: Equatable {
        let ids: [UUID]
        let frame: CGRect
        let text: String
        let selectedID: UUID?
        var isCluster: Bool { ids.count > 1 }
    }
    struct ConflictBand: Equatable {
        let span: EditorConflictSpan
        let frame: CGRect
    }
    struct AnimationLaneGeometry: Equatable {
        let lane: TimelineAnimationLane
        let title: String
        let frame: CGRect
        let labelFrame: CGRect
    }
    struct AnimationCrowdGeometry: Equatable {
        let ids: [TimelineAnimationID]
        let frame: CGRect
        let sourceX: CGFloat
        let title: String
    }
    struct PointerClickGeometry: Equatable {
        let time: Double
        let frame: CGRect
    }
    struct AnimationGeometry: Equatable {
        let animation: TimelineAnimation
        let body: CGRect
        var labelFrame: CGRect
        let startHandle: CGRect?
        let endHandle: CGRect?
        let easeInHandle: CGRect?
        let easeOutHandle: CGRect?
        let deleteButton: CGRect?
    }
    var showsAnimationLanes = false {
        didSet {
            guard showsAnimationLanes != oldValue else { return }
            updateRangeScroller()
            cancelAnimationGesture()
            invalidateIntrinsicContentSize()
            needsDisplay = true; updateTooltips()
            setAccessibilityHelp(showsAnimationLanes
                ? "All tracks share the project timeline. Drag a span to move it; selected edge handles resize it and tall bars change its ramps. Option-drag pushes same-lane neighbors. Delete removes the selected animation. Escape cancels a preview. Pinch to reveal fine controls."
                : "Drag the playhead to scrub or the blue handles to trim. Click an edit to select it, or drag to move its time. Pinch to separate nearby edits; scroll to navigate time.")
        }
    }
    var pointerClickTimes: [Double] = [] {
        didSet { if pointerClickTimes != oldValue { needsDisplay = true; updateTooltips() } }
    }
    var animationSpans: [TimelineAnimation] = [] {
        didSet {
            guard animationSpans != oldValue else { return }
            needsDisplay = true; updateTooltips()
        }
    }
    var selectedAnimationID: TimelineAnimationID? { didSet { if selectedAnimationID != oldValue { needsDisplay = true; updateTooltips() } } }
    var onSelectAnimation: ((TimelineAnimationID) -> Void)?
    var onAnimationEdit: ((AnimationDrag, Bool) -> Void)?
    var animationDragProjection: ((AnimationDrag) -> [TimelineAnimation]?)?
    var onAnimationCancel: (() -> Void)?
    var onDeleteAnimation: ((TimelineAnimationID) -> Void)?
    var presentAnimationMenu: ((NSMenu, NSPoint) -> Void)?
    private(set) var blockedAnimationIDs = Set<TimelineAnimationID>()
    private struct AnimationGesture {
        let id: TimelineAnimationID
        let handle: TimelineAnimationHandle
        let origin: CGPoint
        let base: [TimelineAnimation]
        let visibleDuration: Double
        let railWidth: CGFloat
        var hasMoved = false
        var lastRequest: AnimationDrag?
        var valid = true
        var snappedDelta: Double?
    }
    private var animationGesture: AnimationGesture?
    private var animationPreview: [TimelineAnimation]?
    private var blockedAnimation: TimelineAnimation?
    private var animationClickID: TimelineAnimationID?
    private var animationDeleteID: TimelineAnimationID?
    private var animationChooserIDs: [TimelineAnimationID]?
    private var animationEmptyClick = false
    private var animationPointerOrigin: CGPoint?
    private var activeAnimationMenu: NSMenu?
    var conflictSpans: [EditorConflictSpan] = [] {
        didSet { if conflictSpans != oldValue { needsDisplay = true; updateTooltips() } }
    }
    var conflictOverlaps: [ClosedRange<Double>] = [] {
        didSet { if conflictOverlaps != oldValue { needsDisplay = true; updateTooltips() } }
    }
    var showsCameraOpacityLane = false { didSet { if oldValue != showsCameraOpacityLane { invalidateIntrinsicContentSize(); needsDisplay = true; updateTooltips() } } }
    var showsClipLane = false { didSet { if oldValue != showsClipLane { invalidateIntrinsicContentSize(); needsDisplay = true; updateTooltips() } } }
    var showsTrimHandles = true { didSet { needsDisplay = true } }
    var allowsSeekingOutsideTrim = false
    var clipBands: [TimelineClipBand] = [] { didSet { if oldValue != clipBands { needsDisplay = true; updateTooltips() } } }
    var cutMarkers: [TimelineCutMarker] = [] { didSet { if oldValue != cutMarkers { needsDisplay = true; updateTooltips() } } }
    var selectedCutID: UUID? { didSet { needsDisplay = true } }
    var selectedRange: ClosedRange<Double>? { didSet { needsDisplay = true } }
    var onRangeSelection: ((ClosedRange<Double>?) -> Void)?
    var onSelectCut: ((UUID) -> Void)?
    var onCutRange: (() -> Void)?
    var onRestoreCut: ((UUID) -> Void)?
    var sourceEnvelopes: [TimelineAnimationID: TimelineSourceEnvelope] = [:] { didSet { needsDisplay = true } }
    var speedCurves: [[TimelineSpeedSample]] = [] { didSet { if speedCurves != oldValue { needsDisplay = true } } }
    var videoRows: [TimelineVideoRow] = [] { didSet { if videoRows != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; updateTooltips() } } }
    var rowLayout: TimelineTrackLayout? { didSet { if rowLayout != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; updateTooltips() } } }
    var pinnedAnimationLanes: Set<TimelineAnimationLane> = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var expandedVideoVolumeLayerIDs: Set<UUID> = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; updateTooltips() } }
    var hasPointerRecording = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var recordedAudioRoles: Set<RecordingAudioRole> = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onToggleVideoVolume: ((UUID) -> Void)?
    private var frozenRowLayout: TimelineTrackLayout?
    private var frozenVideoRows: [TimelineVideoRow]?
    var trackLayout: TimelineTrackLayout {
        frozenRowLayout ?? rowLayout ?? TimelineTrackLayout.make(videoRows: videoRows, animations: animationSpans,
            selectedAnimationID: selectedAnimationID, pinnedAnimationLanes: pinnedAnimationLanes,
            expandedVideoVolumeLayerIDs: expandedVideoVolumeLayerIDs, selectedVideoVolumeID: selectedVideoVolumeID,
            conflictSpans: conflictSpans, pointerClickTimes: pointerClickTimes, hasPointerRecording: hasPointerRecording,
            recordedAudioRoles: recordedAudioRoles,
            showsClipLane: showsClipLane)
    }
    private func rowFrame(_ id: TimelineTrackLayout.RowID) -> CGRect {
        guard let offset = trackLayout.offset(of: id), let row = trackLayout.rows.first(where: { $0.id == id }) else { return .null }
        return CGRect(x: railOrigin, y: offset, width: railWidth, height: row.height - 3)
    }
    private func freezeRows() { if frozenRowLayout == nil { frozenRowLayout = trackLayout; frozenVideoRows = videoRows } }
    private func thawRows() { frozenRowLayout = nil; frozenVideoRows = nil; invalidateIntrinsicContentSize(); needsDisplay = true; updateTooltips() }
    var selectedVideoClipID: UUID? { didSet { needsDisplay = true } }
    var selectedVideoVolumeID: UUID? { didSet { needsDisplay = true } }
    var onSelectVideo: ((UUID?, UUID?, UUID?) -> Void)?
    var onVideoEdit: ((TimelineVideoEdit, Bool) -> Void)?
    var onVideoCancel: (() -> Void)?
    var onDeleteVideo: ((UUID, UUID, UUID?) -> Void)?
    private struct VideoGesture {
        var row: TimelineVideoRow
        var part: TimelineVideoPart
        var handle: TimelineVideoHandle
        var origin: CGPoint
        var visibleDuration: Double
        var railWidth: CGFloat
        var originDisplay: Double
        var moved = false
        var createsPoint = false
        var request: TimelineVideoEdit?
    }
    private var videoGesture: VideoGesture?
    private var videoEmptyClick = false
    var videoRowsHeight: CGFloat { trackLayout.rows.filter { row in
        switch row.id { case .media, .volume: true; default: false }
    }.reduce(0) { $0 + $1.height } }
    private var videoRowsTop: CGFloat { trackLayout.rows.compactMap { row -> CGFloat? in
        if case .media = row.id { return trackLayout.offset(of: row.id) }; return nil
    }.min() ?? TimelineTrackLayout.top }
    func videoRowFrame(_ index: Int) -> CGRect {
        guard videoRows.indices.contains(index) else { return .null }
        return rowFrame(.media(videoRows[index].layerID))
    }
    private func clipSlot(_ clipID: UUID, layerID: UUID) -> (index: Int, split: Bool) {
        let clips = (frozenVideoRows ?? videoRows).filter { $0.layerID == layerID }.map(\.clip).sorted { $0.start < $1.start }
        var ends: [Double] = [], slots: [UUID: Int] = [:]
        for clip in clips {
            let slot = ends.firstIndex(where: { $0 <= clip.start }) ?? ends.count
            if slot == ends.count { ends.append(clip.end) } else { ends[slot] = clip.end }
            slots[clip.id] = slot
        }
        guard let clip = clips.first(where: { $0.id == clipID }) else { return (0, false) }
        let split = clips.contains { $0.id != clipID && $0.start < clip.end && $0.end > clip.start }
        return (slots[clipID] ?? 0, split)
    }
    private func videoBodyFrame(_ index: Int, part: TimelineVideoPart) -> CGRect {
        let row = videoRows[index], frame = videoRowFrame(index)
        let slot = clipSlot(row.clip.id, layerID: row.layerID)
        return CGRect(x: x(for: part.start), y: frame.minY + 1 + (slot.split ? CGFloat(slot.index % 2) * 12 : 0),
            width: max(1, x(for: part.end) - x(for: part.start)), height: slot.split ? 12 : 24)
    }
    func videoClipFrames() -> [(UUID, UUID, CGRect)] {
        videoRows.enumerated().flatMap { index, row in row.parts.map { part in
            (row.layerID, row.clip.id, videoBodyFrame(index, part: part))
        } }
    }
    func videoDeleteFrames() -> [(UUID, UUID, CGRect)] {
        videoClipFrames().compactMap { layer, clip, frame in
            guard selectedVideoClipID == clip, frame.width > 85,
                  frame.maxX >= railOrigin + 30, frame.maxX <= bounds.maxX - 12 else { return nil }
            return (layer, clip, CGRect(x: frame.maxX - 29, y: frame.midY - 5, width: 10, height: 10))
        }
    }
    func videoVolumeDisclosureFrames() -> [(UUID, CGRect)] {
        var seen = Set<UUID>()
        return videoRows.compactMap { row in
            guard row.hasAudio, !(row.clip.sourceID == VideoSource.legacyScreenID && !recordedAudioRoles.isEmpty), !videoRows.contains(where: { $0.layerID == row.layerID && !$0.clip.volumeKeyframes.isEmpty }),
                  seen.insert(row.layerID).inserted else { return nil }
            let frame = rowFrame(.media(row.layerID))
            return (row.layerID, CGRect(x: railOrigin - 62, y: frame.midY - 10, width: 58, height: 20))
        }
    }
    private func volumeFrame(_ rowIndex: Int, part: TimelineVideoPart) -> CGRect {
        guard videoRows.indices.contains(rowIndex) else { return .null }
        let lane = rowFrame(.volume(videoRows[rowIndex].layerID))
        guard !lane.isNull else { return .null }
        return CGRect(x: x(for: part.start), y: lane.minY + 3,
            width: max(1, x(for: part.end) - x(for: part.start)), height: lane.height - 6)
    }
    func videoVolumePoints() -> [(UUID, UUID, UUID, CGRect)] {
        videoRows.enumerated().flatMap { index, row in row.parts.flatMap { part in
            let frame = volumeFrame(index, part: part)
            guard !frame.isNull, frame.intersects(visibleRect) else { return [(UUID, UUID, UUID, CGRect)]() }
            return row.clip.volumeKeyframes.compactMap { point -> (UUID, UUID, UUID, CGRect)? in
                let project = row.clip.projectTime(atSourceTime: point.time)
                let display = part.displayTime(at: project)
                guard project >= part.authoringStart, project <= part.authoringEnd, display >= visibleStart, display <= visibleStart + visibleDuration else { return nil }
                return (row.layerID, row.clip.id, point.id,
                    CGRect(x: x(for: display) - 4, y: frame.maxY - CGFloat(point.gain) * frame.height - 4, width: 8, height: 8))
            }
        } }
    }
    private func drawVideoRows() {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        for row in trackLayout.rows {
            let isMedia: Bool = switch row.id { case .media, .volume: true; default: false }
            guard isMedia else { continue }
            let frame = rowFrame(row.id)
            guard frame.intersects(visibleRect) else { continue }
            NSColor.black.withAlphaComponent(0.13).setFill(); NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).fill()
            let hasDisclosure = videoVolumeDisclosureFrames().contains { row.id == .media($0.0) }
            (row.title as NSString).draw(in: CGRect(x: 8 + CGFloat(row.depth) * 10, y: frame.minY + 7,
                width: railOrigin - (hasDisclosure ? 76 : 22) - CGFloat(row.depth) * 10, height: 15), withAttributes: [
                .font: NSFont.systemFont(ofSize: row.depth == 0 ? 10 : 9, weight: row.depth == 0 ? .medium : .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
        }
        for (index, row) in videoRows.enumerated() {
            for part in row.parts {
                let body = videoBodyFrame(index, part: part)
                guard body.intersects(visibleRect) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: CGRect(x: railOrigin, y: body.minY, width: railWidth, height: body.height)).addClip()
                let selected = selectedVideoClipID == row.clip.id
                NSColor.systemIndigo.withAlphaComponent(selected ? 0.6 : 0.3).setFill()
                NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3).fill()
                if selected { NSColor.systemIndigo.setStroke(); NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke() }
                let title = row.sourceName ?? row.label
                (title as NSString).draw(in: body.insetBy(dx: 6, dy: body.height > 16 ? 5 : 0), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
                if selected, row.editable {
                    NSColor.systemIndigo.setFill()
                    let edges = (part.authoringStart == row.clip.start ? [body.minX] : []) + (part.authoringEnd == row.clip.end ? [body.maxX] : [])
                    for edge in edges { NSBezierPath(roundedRect: CGRect(x: edge - 2, y: body.minY, width: 4, height: body.height), xRadius: 1.5, yRadius: 1.5).fill() }
                }
                NSGraphicsContext.restoreGraphicsState()
                let volume = volumeFrame(index, part: part)
                guard row.hasAudio, !volume.isNull else { continue }
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rowFrame(.volume(row.layerID))).addClip()
                let curve = NSBezierPath(), count = max(2, Int(min(512, volume.width)))
                for step in 0...count {
                    let time = part.start + (part.end - part.start) * Double(step) / Double(count)
                    let source = row.clip.sourceTime(at: part.projectTime(at: time))
                    let point = CGPoint(x: x(for: time), y: volume.maxY - CGFloat(row.clip.envelopeGain(atSourceTime: source)) * volume.height)
                    if step == 0 { curve.move(to: point) } else { curve.line(to: point) }
                }
                (row.clip.isMuted ? NSColor.secondaryLabelColor : NSColor.systemGreen).setStroke(); curve.lineWidth = 1.5; curve.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        for (layer, frame) in videoVolumeDisclosureFrames() {
            let expanded = trackLayout.rows.contains { $0.id == .volume(layer) }
            ("Clip audio" as NSString).draw(at: CGPoint(x: frame.minX, y: frame.midY - 5), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor])
            let x = frame.maxX - 7, y = frame.midY - 3
            let chevron = NSBezierPath(); chevron.lineWidth = 1.2
            chevron.move(to: CGPoint(x: x, y: y))
            chevron.line(to: CGPoint(x: x + (expanded ? 3 : 4), y: y + 3))
            chevron.line(to: CGPoint(x: x + (expanded ? 6 : 0), y: y + (expanded ? 0 : 6)))
            NSColor.secondaryLabelColor.setStroke(); chevron.stroke()
        }
        for (_, _, frame) in videoDeleteFrames() {
            NSColor.labelColor.setStroke(); let cross = NSBezierPath()
            cross.move(to: CGPoint(x: frame.minX + 2, y: frame.minY + 2)); cross.line(to: CGPoint(x: frame.maxX - 2, y: frame.maxY - 2))
            cross.move(to: CGPoint(x: frame.minX + 2, y: frame.maxY - 2)); cross.line(to: CGPoint(x: frame.minX + 2, y: frame.minY + 2))
            cross.lineWidth = 1.5; cross.stroke()
        }
        for (_, clip, id, frame) in videoVolumePoints() {
            (id == selectedVideoVolumeID ? NSColor.labelColor : NSColor.systemGreen).setFill(); NSBezierPath(ovalIn: frame).fill()
            if clip == selectedVideoClipID { NSColor.systemGreen.setStroke(); NSBezierPath(ovalIn: frame.insetBy(dx: -1, dy: -1)).stroke() }
        }
    }
    private func beginVideo(at point: CGPoint) -> Bool {
        if let (layer, _) = videoVolumeDisclosureFrames().first(where: { $0.1.contains(point) }) {
            onToggleVideoVolume?(layer); return true
        }
        if let (layer, clip, _) = videoDeleteFrames().first(where: { $0.2.insetBy(dx: -4, dy: -4).contains(point) }) {
            onDeleteVideo?(layer, clip, nil); return true
        }
        let candidates = videoRows.enumerated().flatMap { index, row in row.parts.map { (index, row, $0) } }
        let pointTarget = videoVolumePoints().first { $0.3.insetBy(dx: -4, dy: -4).contains(point) }
        let target = pointTarget.flatMap { target in candidates.first { $0.1.clip.id == target.1 && volumeFrame($0.0, part: $0.2).contains(point) } }
            ?? candidates.reversed().first { index, _, part in
                videoBodyFrame(index, part: part).insetBy(dx: -4, dy: 0).contains(point)
                    || volumeFrame(index, part: part).contains(point)
            }
        guard let (index, row, part) = target else {
            if trackLayout.rows.contains(where: { record in
                switch record.id { case .media, .volume: rowFrame(record.id).contains(point); default: false }
            }) { videoEmptyClick = true; return true }
            return false
        }
        let volume = volumeFrame(index, part: part)
        let handle: TimelineVideoHandle
        var creates = false
        if !volume.isNull, volume.insetBy(dx: 0, dy: 3).contains(point), row.hasAudio {
            if let pointTarget { handle = .volume(pointTarget.2) }
            else { handle = .volume(UUID()); creates = true }
        } else if selectedVideoClipID == row.clip.id && part.authoringStart == row.clip.start && abs(point.x - x(for: part.start)) <= 7 { handle = .start }
        else if selectedVideoClipID == row.clip.id && part.authoringEnd == row.clip.end && abs(point.x - x(for: part.end)) <= 7 { handle = .end }
        else { handle = .move }
        let pointID: UUID? = { if case .volume(let id) = handle { return id }; return nil }()
        onSelectVideo?(row.layerID, row.clip.id, pointID)
        guard row.editable else { return true }
        videoGesture = VideoGesture(row: row, part: part, handle: handle, origin: point, visibleDuration: visibleDuration,
            railWidth: railWidth, originDisplay: time(for: point.x), createsPoint: creates)
        return true
    }
    private func updateVideo(at point: CGPoint, final: Bool) {
        guard var gesture = videoGesture else { return }
        gesture.moved = gesture.moved || hypot(point.x - gesture.origin.x, point.y - gesture.origin.y) >= 3
        guard gesture.moved || (final && gesture.createsPoint) else { if final { videoGesture = nil }; return }
        let origin = gesture.part.projectTime(at: gesture.originDisplay)
        let destinationDisplay = gesture.originDisplay + Double((point.x - gesture.origin.x) / gesture.railWidth) * gesture.visibleDuration
        let handle: TimelineAnimationHandle = switch gesture.handle { case .start: .start; case .end: .end; default: .move }
        let sourceDelta: Double
        if let map = gesture.part.timelineMap, let branch = gesture.part.branchIndex {
            let original = TimelineAnimation(id: .init(lane: .screen, componentID: gesture.row.clip.id), editID: gesture.row.clip.id,
                start: gesture.row.clip.start, end: gesture.row.clip.end, easeIn: 0, easeOut: 0, label: "", help: "", editable: true)
            let drag = AnimationDrag(id: original.id, handle: handle, deltaSeconds: destinationDisplay - gesture.originDisplay)
            guard let converted = TimelineAnimationSolver.sourceDrag(drag, original: original, map: map,
                branchIndex: branch, moveAnchor: origin) else { return }
            sourceDelta = converted.deltaSeconds
        } else { sourceDelta = destinationDisplay - gesture.originDisplay }
        let position: Double
        switch gesture.handle {
        case .move, .start: position = gesture.row.clip.start + sourceDelta
        case .end: position = gesture.row.clip.end + sourceDelta
        case .volume: position = min(gesture.row.clip.end.nextDown, max(gesture.row.clip.start, origin + sourceDelta))
        }
        let index = videoRows.firstIndex { $0.clip.id == gesture.row.clip.id } ?? 0
        let frame = volumeFrame(index, part: gesture.part)
        let gain = frame.isNull ? 1 : min(1, max(0, Double((frame.maxY - point.y) / max(1, frame.height))))
        let request = TimelineVideoEdit(layerID: gesture.row.layerID, clipID: gesture.row.clip.id, handle: gesture.handle,
            projectTime: position, gain: gain)
        gesture.request = request; videoGesture = gesture
        onVideoEdit?(request, final)
        if final { videoGesture = nil }
    }
    private var rangeSelectionOnly = false
    private var clipOrigin: CGPoint?
    private var clipRange: ClosedRange<Double>?
    private var clockID = "source"
    private var hasClock = false
    private var savedViewports: [String: (Double, Double)] = [:]

    func setClock(_ id: String, duration value: Double) {
        if !hasClock {
            hasClock = true; clockID = id; duration = value
            setViewport(start: 0, span: min(value, 30)); return
        }
        if id != clockID {
            frozenRowLayout = nil; frozenVideoRows = nil
            savedViewports[clockID] = (visibleStart, visibleDuration)
            cancelAnimationGesture(); drag = nil; scrubTime = nil; clipOrigin = nil; clipRange = nil
            if videoGesture != nil { videoGesture = nil; onVideoCancel?() }; videoEmptyClick = false
            clockID = id
            duration = value
            let saved = savedViewports[id] ?? (0, value)
            setViewport(start: saved.0, span: saved.1)
        } else { duration = value }
    }

    var clipLaneFrame: CGRect { rowFrame(.cuts) }
    func cutMarkerFrames() -> [(TimelineCutMarker, CGRect)] {
        cutMarkers.filter { $0.end >= visibleStart && $0.start <= visibleStart + visibleDuration }.map {
            let left = max(railOrigin, x(for: $0.start)), right = min(bounds.width - 12, x(for: $0.end))
            let textWidth = ($0.badgeLabel as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)]).width
            let width = min(80, max(28, ceil(textWidth) + 10))
            return ($0, CGRect(x: max(railOrigin, min((left + right) / 2 - width / 2, bounds.width - 12 - width)), y: clipLaneFrame.minY + 4, width: width, height: 18))
        }
    }
    func cutAnchor(for id: UUID) -> UnitPoint? {
        guard let frame = cutMarkerFrames().first(where: { $0.0.id == id })?.1 else { return nil }
        return UnitPoint(x: min(1, max(0, (frame.midX - bounds.minX) / max(1, bounds.width))),
            y: min(1, max(0, (frame.midY - bounds.minY) / max(1, bounds.height))))
    }
    func cutTransitionFrames() -> [(TimelineCutMarker, CGRect)] {
        cutMarkers.filter { $0.showsTransitionSpan && $0.end > $0.start && $0.end >= visibleStart && $0.start <= visibleStart + visibleDuration }.map {
            ($0, CGRect(x: x(for: $0.start), y: clipLaneFrame.minY + 2, width: max(1, x(for: $0.end) - x(for: $0.start)), height: 22))
        }
    }
    private func drawClipLane() {
        ("Cuts" as NSString).draw(at: CGPoint(x: 8, y: clipLaneFrame.minY + 6), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        NSColor.black.withAlphaComponent(0.13).setFill(); NSBezierPath(roundedRect: clipLaneFrame, xRadius: 3, yRadius: 3).fill()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: clipLaneFrame).addClip()
        for (_, rect) in cutTransitionFrames() {
            NSColor.systemTeal.withAlphaComponent(0.4).setFill(); NSBezierPath(rect: rect).fill()
            let lines = NSBezierPath(); lines.move(to: CGPoint(x: rect.minX, y: rect.minY)); lines.line(to: CGPoint(x: rect.maxX, y: rect.maxY)); lines.move(to: CGPoint(x: rect.minX, y: rect.maxY)); lines.line(to: CGPoint(x: rect.maxX, y: rect.minY)); NSColor.systemTeal.setStroke(); lines.stroke()
        }
        if let range = clipRange ?? selectedRange {
            let rect = CGRect(x: x(for: range.lowerBound), y: clipLaneFrame.minY + 1, width: max(1, x(for: range.upperBound) - x(for: range.lowerBound)), height: 24)
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).setFill(); NSBezierPath(rect: rect).fill()
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: rect).stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        for (cut, frame) in cutMarkerFrames() {
            (cut.id == selectedCutID ? NSColor.controlAccentColor : NSColor.windowBackgroundColor).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
            let text = cut.badgeLabel as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: cut.id == selectedCutID ? NSColor.white : NSColor.labelColor]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
    }

    var duration = 1.0 {
        didSet {
            guard duration != oldValue else { return }
            clipOrigin = nil; clipRange = nil
            let wasOverview = visibleStart == 0 && abs(visibleDuration - oldValue) < 0.000_001
            constrainViewport(reset: wasOverview)
        }
    }
    private(set) var visibleStart = 0.0
    private(set) var visibleDuration = 1.0
    var trimStart = 0.0 { didSet { needsDisplay = true } }
    var trimEnd = 1.0 { didSet { needsDisplay = true } }
    var playhead = 0.0 { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?
    var onTrim: ((Double, Double) -> Void)?
    var onTrimPlayhead: ((Double) -> Void)?
    var onInteractionBegan: (() -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrubEnded: (() -> Void)?
    var edits: [RecordingTimelineMarker] = [] {
        didSet { if edits != oldValue { needsDisplay = true; updateTooltips() } }
    }
    var selectedEditID: UUID? {
        didSet {
            needsDisplay = true
            if selectedEditID != oldValue { updateTooltips() }
        }
    }
    var onSelectEdit: ((UUID) -> Void)?
    var frameDuration = 1.0 / 30 { didSet { if frameDuration != oldValue { constrainViewport() } } }
    var onMoveEdit: ((UUID, Double, Bool) -> Void)?
    var onCancelMoveEdit: (() -> Void)?
    var onDeselectEdit: (() -> Void)?
    var onCancelEdit: (() -> Void)?
    private var tooltipText: [Int: String] = [:]
    // Tests exercise the real menu items and selectors without showing a menu
    // on the user's desktop. Production always uses the native popup below.
    var presentMarkerMenu: ((NSMenu, NSPoint) -> Void)?
    private var activeMarkerMenu: NSMenu?

    private enum Interaction: Equatable { case start, end, scrub, edit(UUID), cluster, emptyEditLane }
    private struct Drag {
        var interaction: Interaction
        var originX: CGFloat
        var originTime: Double
        var start: Double
        var end: Double
        var editTime = 0.0
        var minimumTime = 0.0
        var maximumTime = 0.0
        var hasMoved = false
        var movable = true
        var chooserIDs: [UUID]? = nil
        var pointerMoved = false
        var originY: CGFloat = 0
        var originalPlayhead: Double? = nil
    }
    private var drag: Drag?
    private var scrubTime: Double?
    private var keyboardFocus = false
    private var lastFitRequest: UUID?
    private(set) weak var pinnedTimeRuler: TimelineTimeRulerView?
    let rangeScroller = NSScroller(frame: CGRect(x: 0, y: 0, width: 100, height: 12))
    private var railOrigin: CGFloat { showsAnimationLanes ? 154 : 12 }
    private var railWidth: CGFloat { max(1, bounds.width - railOrigin - 12) }
    private var minimumLength: Double { min(0.1, duration) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: showsAnimationLanes ? trackLayout.contentHeight : 72) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        rangeScroller.scrollerStyle = .legacy
        rangeScroller.controlSize = .small
        rangeScroller.target = self; rangeScroller.action = #selector(scrollVisibleRange(_:))
        rangeScroller.setAccessibilityLabel("Visible timeline range")
        rangeScroller.toolTip = "Drag to navigate the visible timeline. Pinch the timeline to change its scale."
        addSubview(rangeScroller)
        updateRangeScroller()
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Recording timeline")
        setAccessibilityHelp("Drag the top playhead to scrub or the blue handles to trim. Click an individual edit to select it, or drag to move its time. Count badges contain nearby edits; click to choose one. Dragging a badge moves only its selected edit. Click empty space below the track to clear selection. Escape cancels an unfinished move. Pinch to separate nearby edits; scroll to navigate time.")
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); installPinnedTimeRuler()
    }
    override func layout() {
        super.layout(); installPinnedTimeRuler()
    }
    func installPinnedTimeRuler() {
        guard showsAnimationLanes, let scroll = enclosingScrollView else { return }
        if let ruler = pinnedTimeRuler, scroll.horizontalRulerView === ruler { return }
        let ruler = TimelineTimeRulerView(scrollView: scroll, timeline: self)
        pinnedTimeRuler = ruler
        scroll.horizontalRulerView = ruler
        scroll.hasHorizontalRuler = true
        scroll.rulersVisible = true
        needsDisplay = true
    }
    private func updateRangeScroller() {
        pinnedTimeRuler?.needsDisplay = true
        rangeScroller.isHidden = !showsAnimationLanes
        rangeScroller.frame = CGRect(x: railOrigin, y: 38, width: railWidth, height: 12)
        rangeScroller.knobProportion = min(1, visibleDuration / max(duration, .leastNonzeroMagnitude))
        rangeScroller.doubleValue = visibleStart / max(duration - visibleDuration, .leastNonzeroMagnitude)
    }
    @objc private func scrollVisibleRange(_ sender: NSScroller) {
        guard drag == nil, videoGesture == nil, animationGesture == nil else { return }
        let delta: Double = switch sender.hitPart {
        case .decrementLine: -visibleDuration * 0.1
        case .incrementLine: visibleDuration * 0.1
        case .decrementPage: -visibleDuration * 0.9
        case .incrementPage: visibleDuration * 0.9
        default: 0
        }
        let start = delta == 0 ? sender.doubleValue * max(0, duration - visibleDuration) : visibleStart + delta
        setViewport(start: start, span: visibleDuration)
    }

    func fit(request: UUID?) {
        guard let request, request != lastFitRequest else { return }
        lastFitRequest = request
        setViewport(start: 0, span: duration)
    }

    func x(for time: Double) -> CGFloat {
        railOrigin + CGFloat((min(max(time, 0), max(0, duration)) - visibleStart) / max(visibleDuration, .leastNonzeroMagnitude)) * railWidth
    }

    private func time(for x: CGFloat) -> Double {
        min(max(visibleStart + Double((x - railOrigin) / railWidth) * visibleDuration, 0), duration)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRangeScroller()
        updateTooltips()
    }

    private func updateTooltips() {
        removeAllToolTips()
        tooltipText.removeAll()
        guard duration.isFinite, duration > 0, bounds.width > 0, bounds.height > 0 else { return }
        let base = addToolTip(bounds, owner: self, userData: nil)
        tooltipText[base] = showsAnimationLanes ? "Drag the playhead to scrub; Shift-drag the ruler to select a cut range. Drag spans to move; selected edges and tall bars adjust timing. Pinch for finer controls." : "Drag the playhead to scrub, blue handles to trim, or an individual edit to move its time. Click a count badge to choose among nearby edits before dragging. Pinch to separate edits; scroll to navigate time."
        for row in trackLayout.rows {
            let frame = rowFrame(row.id)
            tooltipText[addToolTip(CGRect(x: 4, y: frame.minY, width: railOrigin - 22, height: frame.height), owner: self, userData: nil)] = row.help
        }
        for (layer, frame) in videoVolumeDisclosureFrames() {
            let title = trackLayout.rows.first { $0.id == .media(layer) }?.title ?? "this layer"
            let verb = trackLayout.rows.contains { $0.id == .volume(layer) } ? "Hide" : "Show"
            tooltipText[addToolTip(frame.insetBy(dx: -3, dy: -3), owner: self, userData: nil)] = "\(verb) the audio volume envelope for \(title)."
        }
        for (layer, clip, frame) in videoClipFrames() {
            if let row = videoRows.first(where: { $0.layerID == layer && $0.clip.id == clip }) {
                tooltipText[addToolTip(frame.intersection(bounds), owner: self, userData: nil)] = row.label + ": drag this visible clip to move its occurrence; real source edges trim. Delete removes this occurrence."
            }
        }
        for (_, _, frame) in videoDeleteFrames() {
            tooltipText[addToolTip(frame.insetBy(dx: -3, dy: -3), owner: self, userData: nil)] = "Remove this clip occurrence. Keep the source and other occurrences."
        }
        for (_, _, _, frame) in videoVolumePoints() {
            tooltipText[addToolTip(frame.insetBy(dx: -4, dy: -4).intersection(bounds), owner: self, userData: nil)] = "Drag to adjust this clip's volume and time. Delete removes this point; Escape cancels."
        }
        if showsClipLane {
            tooltipText[addToolTip(clipLaneFrame, owner: self, userData: nil)] = "Drag a range, then use Cut section or Delete. Click a join to change its transition or restore the excluded source."
            for (cut, frame) in cutMarkerFrames() { tooltipText[addToolTip(frame, owner: self, userData: nil)] = cut.help + " Delete restores this section." }
        }
        for band in conflictBands() {
            let side = band.span.side == .existing ? "Existing" : "Proposed"
            tooltipText[addToolTip(band.frame.insetBy(dx: -2, dy: -2), owner: self, userData: nil)] =
                "\(side): \(band.span.help) Click to review this source time."
        }
        for interval in conflictOverlaps {
            if let frame = conflictFrame(start: interval.lowerBound, end: interval.upperBound, y: 0, height: 12) {
                tooltipText[addToolTip(frame, owner: self, userData: nil)] = String(format:
                    "Existing and proposed framing overlap from %.3f to %.3f seconds. Click to review; no changes are applied.", interval.lowerBound, interval.upperBound)
            }
        }
        if showsAnimationLanes {
            for crowd in animationCrowds() {
                tooltipText[addToolTip(crowd.frame, owner: self, userData: nil)] = "\(crowd.ids.count) changes in this track. Click to choose by name and time."
            }
            for click in pointerClickGeometry() {
                tooltipText[addToolTip(click.frame.insetBy(dx: -2, dy: -2), owner: self, userData: nil)] = String(format: "Recorded click at %.3f seconds.", click.time)
            }
            for item in animationGeometry() {
                tooltipText[addToolTip(item.body.union(item.labelFrame), owner: self, userData: nil)] = item.animation.help
                let handles: [(CGRect?, String)] = [(item.startHandle, item.animation.isInstant ? "Drag left to animate into this target." : "Drag to change the animation start."),
                    (item.endHandle, "Drag to change the animation end."), (item.easeInHandle, "Drag to change the acceleration ramp."),
                    (item.easeOutHandle, "Drag to change the deceleration ramp."), (item.deleteButton, "Delete this animation.")]
                for (frame, help) in handles { if let frame { tooltipText[addToolTip(frame, owner: self, userData: nil)] = help } }
            }
            return
        }
        for group in markerGroups() {
            tooltipText[addToolTip(group.frame, owner: self, userData: nil)] = help(for: group)
        }
        for label in markerLabels() {
            if let marker = edits.first(where: { $0.id == label.id }) {
                tooltipText[addToolTip(label.frame, owner: self, userData: nil)] = marker.label.map { marker.help.hasPrefix($0) ? marker.help : $0 + ": " + marker.help } ?? marker.help
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: Int, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltipText[tag] ?? ""
    }

    override func draw(_ dirtyRect: NSRect) {
        guard duration.isFinite, duration > 0 else { return }
        let start = drag?.start ?? trimStart
        let end = drag?.end ?? trimEnd
        let current = scrubTime ?? playhead
        if !showsAnimationLanes { drawConflictReview(keptStart: start, keptEnd: end) }
        let rail = CGRect(x: railOrigin, y: 21, width: railWidth, height: 6)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 3, yRadius: 3).fill()
        NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
        let retained = CGRect(x: x(for: start), y: 21, width: max(1, x(for: end) - x(for: start)), height: 6).intersection(rail)
        if !retained.isNull { NSBezierPath(rect: retained).fill() }
        for boundary in (showsTrimHandles ? [start, end] : []) where markerIsVisible(boundary) {
            let handle = CGRect(x: x(for: boundary) - 5, y: 14, width: 10, height: 20)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: handle.insetBy(dx: 4, dy: 6), xRadius: 1, yRadius: 1).fill()
        }
        if !trackLayout.rows.contains(where: { $0.id == .cuts }), let range = clipRange ?? selectedRange {
            let selection = CGRect(x: x(for: range.lowerBound), y: 12, width: max(1, x(for: range.upperBound) - x(for: range.lowerBound)), height: 21)
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).setFill(); NSBezierPath(rect: selection).fill()
        }
        let cursorX = x(for: current)
        if markerIsVisible(current) {
        NSColor.labelColor.setStroke()
        let line = playheadLine()
        line.lineWidth = 1
        line.stroke()
        let thumb = NSBezierPath()
        thumb.move(to: CGPoint(x: cursorX - 5, y: 1))
        thumb.line(to: CGPoint(x: cursorX + 5, y: 1))
        thumb.line(to: CGPoint(x: cursorX + 5, y: 5))
        thumb.line(to: CGPoint(x: cursorX, y: 10))
        thumb.line(to: CGPoint(x: cursorX - 5, y: 5))
        thumb.close()
        NSColor.labelColor.setFill()
        thumb.fill()
        }
        if showsAnimationLanes {
            if showsClipLane { drawClipLane() }
            drawAnimationLanes()
            drawVideoRows()
            drawTimeTicks()
            // The time indicator stays visible over every span without adding
            // a hit target or changing any lane interaction.
            NSColor.labelColor.setStroke()
            let line = playheadLine(); line.lineWidth = 1; line.stroke()
            return
        }
        // Edits have their own lane, so the white playhead and trim handles
        // remain independent even when all three share a source time.
        NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setStroke()
        let editRail = NSBezierPath()
        editRail.move(to: CGPoint(x: 12, y: 47))
        editRail.line(to: CGPoint(x: bounds.width - 12, y: 47))
        editRail.lineWidth = 1
        editRail.stroke()
        if let selected = edits.first(where: { $0.id == selectedEditID }) {
            drawTransitionBand(for: selected)
        }
        for group in markerGroups() {
            if group.isCluster { drawCluster(group, start: start, end: end); continue }
            guard let marker = edits.first(where: { $0.id == group.ids[0] }) else { continue }
            let dragged = drag?.interaction == .edit(marker.id)
            let markerTime = dragged ? drag?.editTime ?? marker.time : marker.time
            let center = CGPoint(x: x(for: markerTime), y: 47)
            let selected = marker.id == selectedEditID || (dragged && drag?.hasMoved == true)
            let radius: CGFloat = selected ? 6 : 5
            let diamond = NSBezierPath()
            diamond.move(to: CGPoint(x: center.x, y: center.y - radius))
            diamond.line(to: CGPoint(x: center.x + radius, y: center.y))
            diamond.line(to: CGPoint(x: center.x, y: center.y + radius))
            diamond.line(to: CGPoint(x: center.x - radius, y: center.y))
            diamond.close()
            NSColor.systemPurple.withAlphaComponent(markerTime >= start && markerTime <= end ? 1 : 0.35).setFill()
            diamond.fill()
            if selected {
                NSColor.labelColor.setStroke()
                diamond.lineWidth = 2
                diamond.stroke()
            }
        }
        drawMarkerLabels()
        drawTimeTicks()
        if keyboardFocus, window?.firstResponder === self, markerIsVisible(current) {
            NSColor.keyboardFocusIndicatorColor.setFill()
            NSBezierPath(roundedRect: CGRect(x: cursorX - 7, y: 35, width: 14, height: 2),
                         xRadius: 1, yRadius: 1).fill()
        }
    }

    func animationLanes() -> [AnimationLaneGeometry] {
        trackLayout.rows.compactMap { row in
            guard case .animation(let lane) = row.id else { return nil }
            let frame = rowFrame(row.id)
            return AnimationLaneGeometry(lane: lane, title: row.title, frame: frame,
                labelFrame: CGRect(x: 8 + CGFloat(row.depth) * 10, y: frame.minY + 5,
                    width: railOrigin - 22 - CGFloat(row.depth) * 10, height: 16))
        }
    }

    func pointerClickGeometry() -> [PointerClickGeometry] {
        guard let lane = animationLanes().first(where: { $0.lane == .pointer }) else { return [] }
        let y = lane.frame.maxY - 3
        return pointerClickTimes.filter { $0.isFinite && $0 >= 0 && $0 <= duration && markerIsVisible($0) }.map {
            PointerClickGeometry(time: $0, frame: CGRect(x: x(for: $0) - 1, y: y, width: 2, height: 3))
        }
    }

    private var displayedAnimations: [TimelineAnimation] {
        if let gesture = animationGesture { return animationPreview ?? gesture.base }
        return animationSpans
    }

    private func rawAnimationGeometry() -> [AnimationGeometry] {
        let selected = animationGesture?.id ?? selectedAnimationID
        return displayedAnimations.compactMap { animation in
            guard animation.start.isFinite, animation.end.isFinite, animation.start <= animation.end,
                  animation.end >= visibleStart, animation.start <= visibleStart + visibleDuration,
                  let lane = animationLanes().first(where: { $0.lane == animation.lane }) else { return nil }
            let left = max(railOrigin, x(for: animation.start)), right = min(bounds.width - 12, x(for: animation.end))
            guard right >= left else { return nil }
            let width = max(6, right - left)
            let body = CGRect(x: animation.isInstant ? left - 3 : left, y: lane.frame.minY + 7, width: width, height: 17)
            let textWidth = min(130, ceil((animation.label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium)]).width))
            let editable = animation.id == selected && animation.editable
            let labelX = width >= textWidth + 8 ? body.minX + 4 : body.maxX + (editable ? 18 : 4)
            let label = CGRect(x: min(max(railOrigin, labelX), max(railOrigin, bounds.width - 12 - textWidth)),
                y: body.minY + 5, width: textWidth, height: 11)
            let timing = editable && !animation.isReference
            let wide = width >= 80 && !animation.isInstant
            let start = timing && animation.showsStartHandle ? CGRect(x: left - 4, y: lane.frame.minY + (wide ? 15 : 0), width: 8, height: wide ? 10 : 8) : nil
            let end = timing && !animation.isInstant && animation.showsEndHandle ? CGRect(x: right - 4, y: lane.frame.minY + (wide ? 15 : 18), width: 8, height: wide ? 10 : 8) : nil
            var incomingX = x(for: animation.start + animation.easeIn)
            var outgoingX = x(for: animation.end - animation.easeOut)
            if outgoingX - incomingX < 14 {
                let middle = (incomingX + outgoingX) / 2
                incomingX = middle - 7; outgoingX = middle + 7
            }
            let easeIn = timing && wide && animation.showsEaseInHandle ? CGRect(x: incomingX - 6, y: lane.frame.minY - 4, width: 12, height: 16) : nil
            let easeOut = timing && wide && animation.showsEaseOutHandle ? CGRect(x: outgoingX - 6, y: lane.frame.minY - 4, width: 12, height: 16) : nil
            let deletion = editable ? CGRect(x: min(body.maxX + 4, bounds.width - 24), y: lane.frame.minY + 14, width: 10, height: 10) : nil
            return AnimationGeometry(animation: animation, body: body, labelFrame: label, startHandle: start,
                endHandle: end, easeInHandle: easeIn, easeOutHandle: easeOut, deleteButton: deletion)
        }
    }

    /// Colliding labels are replaced by a chooser in the label gutter, never
    /// over a neighboring curve, its grips, or the following track.
    private func crowdedAnimationIDs(_ geometry: [AnimationGeometry]) -> Set<TimelineAnimationID> {
        var crowded = Set<TimelineAnimationID>()
        for lane in animationLanes() {
            let ordered = geometry.filter { $0.animation.lane == lane.lane }.sorted {
                $0.body.union($0.labelFrame).minX < $1.body.union($1.labelFrame).minX
            }
            var group: [AnimationGeometry] = []
            var right = -CGFloat.infinity
            for item in ordered {
                let frame = item.body.union(item.labelFrame)
                if frame.minX >= right {
                    if group.count > 1 { crowded.formUnion(group.map { $0.animation.id }) }
                    group = []; right = -CGFloat.infinity
                }
                group.append(item); right = max(right, frame.maxX)
            }
            if group.count > 1 { crowded.formUnion(group.map { $0.animation.id }) }
        }
        return crowded
    }
    func animationGeometry() -> [AnimationGeometry] {
        let raw = rawAnimationGeometry(), crowded = crowdedAnimationIDs(raw)
        return raw.map { item in
            var result = item
            if crowded.contains(item.animation.id) { result.labelFrame = .null }
            return result
        }
    }
    func animationCrowds() -> [AnimationCrowdGeometry] {
        let geometry = rawAnimationGeometry(), crowded = crowdedAnimationIDs(geometry)
        return animationLanes().compactMap { lane in
            let members = geometry.filter { $0.animation.lane == lane.lane }
            guard members.contains(where: { crowded.contains($0.animation.id) }) else { return nil }
            return AnimationCrowdGeometry(ids: members.map { $0.animation.id },
                frame: lane.labelFrame.insetBy(dx: -2, dy: -3), sourceX: lane.labelFrame.midX,
                title: "\(lane.title) · \(members.count) ▾")
        }
    }

    private func animationColor(_ lane: TimelineAnimationLane) -> NSColor {
        switch lane { case .screen: .systemPurple; case .camera: .systemTeal; case .cameraOpacity: .systemPink; case .speed: .systemOrange; case .pointer: .secondaryLabelColor; case .audioMicrophone: .systemGreen; case .audioSystem: .systemBlue }
    }

    func playheadLine() -> NSBezierPath {
        let path = NSBezierPath()
        let time = scrubTime ?? playhead
        guard markerIsVisible(time) else { return path }
        let position = x(for: time)
        path.move(to: CGPoint(x: position, y: 8))
        path.line(to: CGPoint(x: position, y: showsAnimationLanes ? trackLayout.contentHeight - TimelineTrackLayout.footer - 3 : 34))
        return path
    }

    /// Use source coordinates before viewport clipping so a partially visible
    /// movement retains its actual ramp shape when the timeline is magnified.
    func animationEnvelope(for item: AnimationGeometry) -> NSBezierPath {
        let animation = item.animation
        guard !animation.isInstant, !animation.isReference, animation.lane != .pointer, animation.lane != .speed else {
            return NSBezierPath(roundedRect: item.body, xRadius: 2, yRadius: 2)
        }
        let profile = sourceEnvelopes[animation.id]
        let source = profile?.animation ?? animation
        let sourceOffset = profile?.sourceOffset ?? 0
        let span = source.duration
        let ramps = MotionInterpolation.rampDurations(duration: span, easeIn: source.easeIn, easeOut: source.easeOut)
        var samples = [0.0, span, ramps.easeIn, span - ramps.easeOut, span / 2]
        for (start, length) in [(0.0, ramps.easeIn), (span - ramps.easeOut, ramps.easeOut)] where length > 0 {
            for index in 0...16 { samples.append(start + length * Double(index) / 16) }
        }
        // Explicit zero ramps are vertical velocity changes. Include the
        // interior limiting values rather than drawing a false gradual ramp.
        if ramps.easeIn == 0 { samples.append(0.0.nextUp) }
        if ramps.easeOut == 0 { samples.append(span.nextDown) }
        let envelope = NSBezierPath()
        envelope.move(to: CGPoint(x: x(for: animation.start), y: item.body.maxY))
        let lower = (profile?.sourceTime(at: animation.start) ?? animation.start + sourceOffset) - source.start
        let upper = (profile?.sourceTime(at: animation.end) ?? animation.end + sourceOffset) - source.start
        samples += [lower, upper]
        for elapsed in Set(samples).sorted() where elapsed >= lower && elapsed <= upper {
            let speed: Double
            if let startGain = source.gainStart, let endGain = source.gainEnd {
                let progress = MotionInterpolation.progress(at: elapsed, from: 0, to: span, duration: span, transition: .smooth,
                    easeIn: source.easeIn, easeOut: source.easeOut)
                speed = startGain + (endGain - startGain) * progress
            } else {
                speed = MotionInterpolation.normalizedSpeed(at: elapsed, duration: span,
                    easeIn: source.easeIn, easeOut: source.easeOut)
            }
            envelope.line(to: CGPoint(x: x(for: profile?.outputTime(for: source.start + elapsed) ?? source.start + elapsed - sourceOffset),
                y: item.body.maxY - CGFloat(speed) * (item.body.height - 3)))
        }
        envelope.line(to: CGPoint(x: x(for: animation.end), y: item.body.maxY))
        envelope.close()
        return envelope
    }

    private func drawAnimationLanes() {
        for lane in animationLanes() {
            NSColor.black.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: lane.frame, xRadius: 3, yRadius: 3).fill()
            if !animationCrowds().contains(where: { $0.frame.intersects(lane.labelFrame) }) {
                (lane.title as NSString).draw(in: lane.labelFrame, withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
            }

        }
        drawConflictReview(keptStart: trimStart, keptEnd: trimEnd)
        NSGraphicsContext.saveGraphicsState()
        let top = TimelineTrackLayout.top
        let bottom = trackLayout.contentHeight - TimelineTrackLayout.footer
        NSBezierPath(rect: CGRect(x: railOrigin, y: top, width: railWidth, height: max(0, bottom - top))).addClip()
        if let lane = animationLanes().first(where: { $0.lane == .speed }) {
            NSColor.systemOrange.withAlphaComponent(0.8).setStroke()
            for curve in speedCurves {
                let path = NSBezierPath(); path.lineWidth = 1.25
                for (index, sample) in curve.enumerated() {
                    let fraction = log(max(0.1, min(8, sample.rate)) / 0.1) / log(80)
                    let point = CGPoint(x: x(for: sample.time), y: lane.frame.maxY - 2 - CGFloat(fraction) * (lane.frame.height - 4))
                    if index == 0 { path.move(to: point) } else { path.line(to: point) }
                }
                path.stroke()
            }
        }
        for item in animationGeometry() {
            let animation = item.animation
            let selected = animation.id == (animationGesture?.id ?? selectedAnimationID)
            let color = blockedAnimationIDs.contains(animation.id) ? NSColor.systemRed : animationColor(animation.lane)
            let envelope = animationEnvelope(for: item)
            color.withAlphaComponent(selected ? 0.68 : 0.53).setFill()
            envelope.fill()
            color.withAlphaComponent(selected ? 1 : 0.85).setStroke()
            envelope.lineWidth = selected ? 1.5 : 1
            envelope.stroke()
            if !item.labelFrame.isNull {
                (animation.label as NSString).draw(in: item.labelFrame, withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.labelColor])
            }
            for handle in [item.startHandle, item.endHandle].compactMap({ $0 }) {
                // Preserve the generous hit regions while painting quiet grips.
                color.setFill()
                let grip = CGRect(x: handle.midX - 1.5, y: handle.midY - 4, width: 3, height: 8)
                NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
            }
            if let button = item.deleteButton {
                NSColor.secondaryLabelColor.setStroke()
                let cross = NSBezierPath(); cross.lineWidth = 1.5
                cross.move(to: CGPoint(x: button.minX + 2, y: button.minY + 2)); cross.line(to: CGPoint(x: button.maxX - 2, y: button.maxY - 2))
                cross.move(to: CGPoint(x: button.maxX - 2, y: button.minY + 2)); cross.line(to: CGPoint(x: button.minX + 2, y: button.maxY - 2)); cross.stroke()
            }
        }
        NSColor.secondaryLabelColor.setFill()
        for click in pointerClickGeometry() { NSBezierPath(rect: click.frame).fill() }
        if let blockedAnimation, let lane = animationLanes().first(where: { $0.lane == blockedAnimation.lane }) {
            let rect = CGRect(x: x(for: blockedAnimation.start), y: lane.frame.minY + 6,
                width: max(6, x(for: blockedAnimation.end) - x(for: blockedAnimation.start)), height: 19)
            NSColor.systemRed.setStroke(); let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            outline.setLineDash([3, 2], count: 2, phase: 0); outline.lineWidth = 2; outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        // Ramp grips intentionally extend above their lane. Paint them after
        // clipping the bodies, preserving the full enlarged hit regions.
        for item in animationGeometry() {
            let color = animationColor(item.animation.lane)
            let grips: [(CGRect?, Double)] = [(item.easeInHandle, item.animation.start + item.animation.easeIn),
                (item.easeOutHandle, item.animation.end - item.animation.easeOut)]
            for (frame, time) in grips {
                guard let frame else { continue }
                let sourceX = x(for: time)
                if abs(frame.midX - sourceX) > 0.5 {
                    color.withAlphaComponent(0.7).setStroke()
                    let leader = NSBezierPath()
                    leader.move(to: CGPoint(x: frame.midX, y: frame.minY + 8))
                    leader.line(to: CGPoint(x: sourceX, y: frame.maxY)); leader.lineWidth = 1; leader.stroke()
                }
                color.setFill()
                NSBezierPath(roundedRect: CGRect(x: frame.midX - 1.75, y: frame.minY, width: 3.5, height: frame.height), xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        for crowd in animationCrowds() {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: crowd.frame, xRadius: 4, yRadius: 4).fill()
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (crowd.title as NSString).draw(in: crowd.frame.insetBy(dx: 3, dy: 3), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
        }
    }

    private func animationTargets(at point: CGPoint) -> [AnimationGeometry] {
        let geometry = animationGeometry()
        let bodies = geometry.filter { $0.body.contains(point) }
        return bodies.isEmpty ? geometry.filter { $0.labelFrame.contains(point) } : bodies
    }

    private func controlHitFrame(_ frame: CGRect, for animation: TimelineAnimation) -> CGRect {
        let lane = rowFrame(.animation(animation.lane))
        let width = max(18, frame.width + 10), height = max(18, frame.height + 8)
        return CGRect(x: frame.midX - width / 2, y: max(lane.minY - 4, frame.midY - height / 2), width: width, height: height)
    }

    private func beginAnimationInteraction(at point: CGPoint) {
        animationPointerOrigin = point
        let geometry = animationGeometry()
        if let selected = geometry.first(where: { $0.animation.id == selectedAnimationID }) {
            let controls: [(CGRect?, TimelineAnimationHandle?)] = [(selected.easeInHandle, .easeIn), (selected.easeOutHandle, .easeOut),
                (selected.startHandle, .start), (selected.endHandle, .end), (selected.deleteButton, nil)]
            let hits = controls.compactMap { frame, handle -> (CGRect, TimelineAnimationHandle?)? in
                guard let frame, controlHitFrame(frame, for: selected.animation).contains(point) else { return nil }
                return (frame, handle)
            }
            if let target = hits.min(by: { hypot($0.0.midX - point.x, $0.0.midY - point.y) < hypot($1.0.midX - point.x, $1.0.midY - point.y) }) {
                guard let handle = target.1 else { animationDeleteID = selected.animation.id; return }
                animationPointerOrigin = point
                animationGesture = AnimationGesture(id: selected.animation.id, handle: handle, origin: point, base: animationSpans,
                    visibleDuration: visibleDuration, railWidth: railWidth); return
            }
        }
        if let crowd = animationCrowds().first(where: { $0.frame.contains(point) }) {
            animationPointerOrigin = point; animationChooserIDs = crowd.ids; return
        }
        guard animationLanes().contains(where: { $0.frame.contains(point) || $0.labelFrame.contains(point) }) else { return }
        if conflictBands().contains(where: { $0.frame.contains(point) }) {
            onScrubBegan?()
            let sourceTime = time(for: point.x)
            seek(sourceTime)
            drag = Drag(interaction: .scrub, originX: point.x, originTime: sourceTime,
                start: trimStart, end: trimEnd, originY: point.y)
            return
        }
        animationPointerOrigin = point
        let targets = animationTargets(at: point)
        if targets.count > 1 { animationChooserIDs = targets.map { $0.animation.id }; return }
        if let target = targets.first {
            animationClickID = target.animation.id
            if target.animation.editable { animationGesture = AnimationGesture(id: target.animation.id, handle: .move, origin: point, base: animationSpans,
                visibleDuration: visibleDuration, railWidth: railWidth) }
        } else if let lane = animationLanes().first(where: { $0.labelFrame.contains(point) }),
                  let animation = animationSpans.first(where: { $0.lane == lane.lane }) {
            animationClickID = animation.id
        } else { animationEmptyClick = true }
    }

    private func snappedAnimationDelta(_ delta: Double, gesture: inout AnimationGesture) -> Double {
        guard gesture.handle == .move || gesture.handle == .start || gesture.handle == .end,
              let target = gesture.base.first(where: { $0.id == gesture.id }) else { return delta }
        let unit = gesture.visibleDuration / Double(gesture.railWidth)
        if let sticky = gesture.snappedDelta, abs(delta - sticky) <= unit * 10 { return sticky }
        gesture.snappedDelta = nil
        let others = gesture.base.filter { $0.id != target.id && $0.lane == target.lane && !$0.isReference }
        let candidates: [Double]
        switch gesture.handle {
        case .start: candidates = [-target.start] + others.map { $0.end - target.start }
        case .end: candidates = [duration - target.end] + others.map { $0.start - target.end }
        default: candidates = [-target.start, duration - target.end] + others.flatMap { [$0.end - target.start, $0.start - target.end] }
        }
        if let closest = candidates.min(by: { abs($0 - delta) < abs($1 - delta) }), abs(closest - delta) <= unit * 6 {
            gesture.snappedDelta = closest; return closest
        }
        return delta
    }

    private func dragAnimation(with event: NSEvent) {
        guard var gesture = animationGesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard gesture.hasMoved || max(abs(point.x - gesture.origin.x), abs(point.y - gesture.origin.y)) >= 3 else { return }
        gesture.hasMoved = true
        animationClickID = nil
        let raw = Double((point.x - gesture.origin.x) / gesture.railWidth) * gesture.visibleDuration
        let delta = snappedAnimationDelta(raw, gesture: &gesture)
        let request = AnimationDrag(id: gesture.id, handle: gesture.handle, deltaSeconds: delta,
            push: event.modifierFlags.contains(.option), snapTolerance: 0)
        let candidate: [TimelineAnimation]?
        if let animationDragProjection { candidate = animationDragProjection(request) }
        else { candidate = TimelineAnimationSolver.solve(request, animations: gesture.base, duration: duration) }
        guard let changed = candidate else {
            if gesture.lastRequest != nil, gesture.valid { onAnimationCancel?() }
            gesture.valid = false; gesture.lastRequest = request
            animationPreview = nil
            if var target = gesture.base.first(where: { $0.id == gesture.id }) {
                switch gesture.handle {
                case .move: target.start += delta; target.end += delta
                case .start: target.start += delta
                case .end: target.end += delta
                case .easeIn, .easeOut: break
                }
                blockedAnimationIDs = collisionIDs(for: target, in: gesture.base)
                blockedAnimation = blockedAnimationIDs.isEmpty ? nil : target
            }
            animationGesture = gesture; needsDisplay = true; return
        }
        blockedAnimation = nil; blockedAnimationIDs.removeAll()
        gesture.valid = true; gesture.lastRequest = request
        let changes = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0) })
        animationPreview = animationDragProjection != nil ? changed : gesture.base.map { changes[$0.id] ?? $0 }
        if animationDragProjection == nil, var wanted = gesture.base.first(where: { $0.id == gesture.id }),
           let projected = animationPreview?.first(where: { $0.id == gesture.id }) {
            switch gesture.handle {
            case .move: wanted.start += delta; wanted.end += delta
            case .start: wanted.start += delta
            case .end: wanted.end += delta
            case .easeIn, .easeOut: break
            }
            if abs(wanted.start - projected.start) > 0.000_001 || abs(wanted.end - projected.end) > 0.000_001 {
                blockedAnimationIDs = collisionIDs(for: wanted, in: gesture.base)
                blockedAnimation = blockedAnimationIDs.isEmpty ? nil : wanted
            }
        }
        animationGesture = gesture
        onAnimationEdit?(request, false)
        needsDisplay = true; updateTooltips()
    }

    private func collisionIDs(for wanted: TimelineAnimation, in base: [TimelineAnimation]) -> Set<TimelineAnimationID> {
        var ids = Set(base.filter { $0.lane == wanted.lane && $0.id != wanted.id && !$0.isReference &&
            $0.start < wanted.end && $0.end > wanted.start }.map(\.id))
        if !ids.isEmpty || wanted.start < 0 || wanted.end > duration || wanted.start > wanted.end { ids.insert(wanted.id) }
        return ids
    }

    private func endAnimationInteraction(at point: CGPoint) {
        let gesture = animationGesture, clicked = animationClickID, deleted = animationDeleteID, chooser = animationChooserIDs, empty = animationEmptyClick
        let origin = animationPointerOrigin; animationPointerOrigin = nil
        animationGesture = nil; animationPreview = nil; blockedAnimation = nil; blockedAnimationIDs.removeAll()
        animationClickID = nil; animationDeleteID = nil; animationChooserIDs = nil; animationEmptyClick = false
        if gesture?.hasMoved != true, let origin, max(abs(point.x - origin.x), abs(point.y - origin.y)) >= 3 { needsDisplay = true; return }
        if let gesture, gesture.hasMoved {
            if gesture.valid, let request = gesture.lastRequest { onAnimationEdit?(request, true) }
            else { onAnimationCancel?() }
        } else if let deleted, animationSpans.contains(where: { $0.id == deleted && $0.editable }) { onDeleteAnimation?(deleted) }
        else if let chooser { chooseAnimations(chooser, at: point) }
        else if let clicked { onSelectAnimation?(clicked) }
        else if empty { onDeselectEdit?() }
        needsDisplay = true; updateTooltips()
    }

    private func cancelAnimationGesture() {
        let hadPreview = animationGesture?.hasMoved == true
        animationPointerOrigin = nil
        animationGesture = nil; animationPreview = nil; blockedAnimation = nil; blockedAnimationIDs.removeAll()
        animationClickID = nil; animationDeleteID = nil; animationChooserIDs = nil; animationEmptyClick = false
        if hadPreview { onAnimationCancel?() }
        needsDisplay = true
    }

    private func animationAccessibilityActions() -> [NSAccessibilityCustomAction] {
        var actions = displayedAnimations.map { animation in
            NSAccessibilityCustomAction(name: "Select \(animation.label) in \(animation.lane.rawValue), \(String(format: "%.3f to %.3f seconds", animation.start, animation.end))") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.animationSpans.contains(where: { $0.id == animation.id }) else { return false }
                    self.onSelectAnimation?(animation.id); return true
                }
            }
        }
        for crowd in animationCrowds() {
            actions.append(NSAccessibilityCustomAction(name: "Choose among \(crowd.ids.count) crowded animations") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    self.chooseAnimations(crowd.ids, at: CGPoint(x: crowd.frame.midX, y: crowd.frame.maxY)); return true
                }
            })
        }
        if let id = selectedAnimationID, let selected = animationSpans.first(where: { $0.id == id && $0.editable }) {
            actions.append(NSAccessibilityCustomAction(name: "Delete \(selected.label)") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.animationSpans.contains(where: { $0.id == id && $0.editable }) else { return false }
                    self.onInteractionBegan?(); self.onDeleteAnimation?(id); return true
                }
            })
        }
        return actions
    }

    private func chooseAnimations(_ ids: [TimelineAnimationID], at point: CGPoint) {
        let menu = NSMenu(title: "Choose animation"); menu.autoenablesItems = false
        for id in ids {
            guard let animation = animationSpans.first(where: { $0.id == id }) else { continue }
            let item = NSMenuItem(title: String(format: "%@ · %.3f–%.3f s", animation.label, animation.start, animation.end),
                action: #selector(chooseAnimation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; item.toolTip = animation.help
            menu.addItem(item)
        }
        guard !menu.items.isEmpty else { return }
        activeAnimationMenu = menu
        if let presentAnimationMenu { presentAnimationMenu(menu, point) }
        else { menu.popUp(positioning: nil, at: point, in: self); activeAnimationMenu = nil }
    }

    @objc private func chooseAnimation(_ item: NSMenuItem) {
        guard item.menu === activeAnimationMenu, let id = item.representedObject as? TimelineAnimationID,
              animationSpans.contains(where: { $0.id == id }) else { return }
        activeAnimationMenu = nil; onSelectAnimation?(id)
    }

    @objc private func deleteAnimation(_ item: NSMenuItem) {
        guard item.menu === activeAnimationMenu, let id = item.representedObject as? TimelineAnimationID,
              animationSpans.contains(where: { $0.id == id && $0.editable }) else { return }
        activeAnimationMenu = nil; onInteractionBegan?(); onDeleteAnimation?(id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard showsAnimationLanes else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let targets = animationTargets(at: point)
        guard let target = targets.first(where: { $0.animation.id == selectedAnimationID }) ?? targets.first else { return nil }
        let menu = NSMenu(title: target.animation.label); menu.autoenablesItems = false
        let select = NSMenuItem(title: "Select \(target.animation.label)", action: #selector(chooseAnimation(_:)), keyEquivalent: "")
        select.target = self; select.representedObject = target.animation.id; menu.addItem(select)
        if target.animation.editable {
            let deletion = NSMenuItem(title: "Delete \(target.animation.label)", action: #selector(deleteAnimation(_:)), keyEquivalent: "")
            deletion.target = self; deletion.representedObject = target.animation.id; menu.addItem(deletion)
        }
        activeAnimationMenu = menu
        return menu
    }

    /// Conflict comparison uses the space above the scrub rail, preserving the
    /// edit lane and the timeline's height. The white playhead draws over it.
    func conflictBands() -> [ConflictBand] {
        conflictSpans.compactMap { span in
            guard let frame = conflictFrame(start: span.start, end: span.end,
                y: showsAnimationLanes ? rowFrame(.animation(.screen)).minY + (span.side == .existing ? 2 : 22) : (span.side == .existing ? 2 : 8), height: 3) else { return nil }
            return ConflictBand(span: span, frame: frame)
        }
    }

    private func conflictFrame(start: Double, end: Double, y: CGFloat, height: CGFloat) -> CGRect? {
        guard start.isFinite, end.isFinite, start <= end,
              end >= visibleStart, start <= visibleStart + visibleDuration,
              end >= 0, start <= duration else { return nil }
        let lower = max(railOrigin, x(for: start)), upper = min(bounds.width - 12, x(for: end))
        let width = max(start == end ? 4 : 2, upper - lower)
        let frame = CGRect(x: start == end ? lower - width / 2 : lower, y: y, width: width, height: height)
            .intersection(CGRect(x: railOrigin, y: y, width: railWidth, height: height))
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    private func drawConflictReview(keptStart: Double, keptEnd: Double) {
        let lane = showsAnimationLanes ? rowFrame(.animation(.screen)) : CGRect(x: railOrigin, y: 0, width: railWidth, height: 12)
        guard !lane.isNull else { return }
        func draw(alpha: CGFloat) {
            for interval in conflictOverlaps {
                guard let frame = conflictFrame(start: interval.lowerBound, end: interval.upperBound, y: lane.minY, height: lane.height) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: frame).addClip()
                NSColor.labelColor.withAlphaComponent(0.25 * alpha).setStroke()
                let hatch = NSBezierPath()
                var position = frame.minX - 12
                while position <= frame.maxX {
                    hatch.move(to: CGPoint(x: position, y: lane.maxY))
                    hatch.line(to: CGPoint(x: position + 12, y: lane.minY))
                    position += 6
                }
                hatch.lineWidth = 1; hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
            for band in conflictBands() {
                let existing = band.span.side == .existing
                let color = (existing ? NSColor.systemOrange : NSColor.systemCyan).withAlphaComponent(alpha)
                color.setStroke(); color.setFill()
                if band.span.isInstant {
                    let tick = CGRect(x: x(for: band.span.start) - 2, y: band.frame.midY - 2, width: 4, height: 4)
                    if existing { NSBezierPath(rect: tick).fill() }
                    else { let ring = NSBezierPath(ovalIn: tick); ring.lineWidth = 1; ring.stroke() }
                    continue
                }
                let line = NSBezierPath()
                line.lineWidth = 3
                if !existing { line.setLineDash([4, 3], count: 2, phase: 0) }
                line.move(to: CGPoint(x: x(for: band.span.start), y: band.frame.midY))
                line.line(to: CGPoint(x: x(for: band.span.end), y: band.frame.midY))
                line.stroke()
            }
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: lane).addClip()
        draw(alpha: 0.28)
        NSBezierPath(rect: CGRect(x: x(for: keptStart), y: lane.minY,
            width: max(0, x(for: keptEnd) - x(for: keptStart)), height: lane.height)).addClip()
        draw(alpha: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A count replaces overlapping hit targets. Recheck the resulting badges,
    /// whose widths depend on their counts/selection, so no two targets overlap.
    func markerGroups() -> [MarkerGroup] {
        if showsAnimationLanes { return [] }
        let visible = edits.filter { markerIsVisible(displayTime(for: $0)) }.sorted {
            let first = displayTime(for: $0), second = displayTime(for: $1)
            return first == second ? $0.id.uuidString < $1.id.uuidString : first < second
        }
        let selectedIndex = visible.firstIndex { $0.id == selectedEditID }
        func layout(_ range: Range<Int>) -> (frame: CGRect, text: String, selectedID: UUID?) {
            let selected = selectedIndex.flatMap { range.contains($0) ? visible[$0] : nil }
            let token = selected?.label.map { label in
                let segment = label.components(separatedBy: " · ").first ?? label
                return String((segment.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? segment).prefix(3))
            }
            let text = range.count > 1 ? token.map { $0 + " · " + String(range.count) } ?? String(range.count) : ""
            let width = range.count > 1 ? max(24, ceil((text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold)]).width) + 12) : 16
            let center = (x(for: displayTime(for: visible[range.lowerBound])) + x(for: displayTime(for: visible[range.upperBound - 1]))) / 2
            return (CGRect(x: min(max(0, center - width / 2), max(0, bounds.width - width)), y: 38, width: width, height: 18),
                    text, selected?.id)
        }
        // A stack of index ranges keeps a dense timeline linear after sorting,
        // rather than repeatedly copying or scanning every collapsed member.
        var ranges: [Range<Int>] = []
        for index in visible.indices {
            ranges.append(index..<(index + 1))
            while ranges.count > 1 {
                let left = ranges[ranges.count - 2], right = ranges[ranges.count - 1]
                guard layout(left).frame.insetBy(dx: -1, dy: 0).intersects(layout(right).frame.insetBy(dx: -1, dy: 0)) else { break }
                ranges.removeLast(2)
                ranges.append(left.lowerBound..<right.upperBound)
            }
        }
        return ranges.map { range in
            let value = layout(range)
            return MarkerGroup(ids: range.map { visible[$0].id }, frame: value.frame, text: value.text, selectedID: value.selectedID)
        }
    }

    private func help(for group: MarkerGroup) -> String {
        guard group.isCluster else {
            guard let marker = edits.first(where: { $0.id == group.ids.first }) else { return "" }
            return marker.label.map { marker.help.hasPrefix($0) ? marker.help : $0 + ": " + marker.help } ?? marker.help
        }
        let selection = group.selectedID.flatMap { id in edits.first { $0.id == id } }
        let selected = selection.map {
            " \($0.label ?? "An edit") is selected." + ($0.movable ? " Drag to move only that edit." : " Its time is fixed.")
        } ?? " Choose an edit before dragging."
        return "\(group.ids.count) nearby edits. Click to choose an action and time; pinch to separate them." + selected
    }

    private func drawCluster(_ group: MarkerGroup, start: Double, end: Double) {
        let ids = Set(group.ids)
        let retained = edits.contains { ids.contains($0.id) && displayTime(for: $0) >= start && displayTime(for: $0) <= end }
        NSColor.systemPurple.withAlphaComponent(retained ? 0.9 : 0.35).setFill()
        let badge = NSBezierPath(roundedRect: group.frame.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5)
        badge.fill()
        if group.selectedID != nil {
            NSColor.labelColor.setStroke(); badge.lineWidth = 2; badge.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white]
        let text = group.text as NSString
        let width = text.size(withAttributes: attributes).width
        text.draw(at: CGPoint(x: group.frame.midX - width / 2, y: group.frame.minY + 3), withAttributes: attributes)
    }

    /// Labels belong only to individually visible targets. Cluster members are
    /// identified by action and time in the native chooser instead.
    func markerLabels() -> [MarkerLabel] {
        let groups = markerGroups()
        let individuals = Set(groups.filter { !$0.isCluster }.flatMap(\.ids))
        let visible = edits.filter { individuals.contains($0.id) }
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        var labels: [MarkerLabel] = []
        let ordered = visible.sorted { ($0.id == selectedEditID ? 0 : 1) < ($1.id == selectedEditID ? 0 : 1) }
        for marker in ordered {
            guard let label = marker.label, !label.isEmpty else { continue }
            let text = label.hasPrefix("Edit ") ? String(label.dropFirst(5)) : label
            let width = min(70, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 6)
            let center = x(for: displayTime(for: marker))
            let candidates = [CGRect(x: center + 8, y: 39, width: width, height: 16),
                              CGRect(x: center - 8 - width, y: 39, width: width, height: 16)]
            let available = candidates.first { candidate in
                candidate.minX >= 0 && candidate.maxX <= bounds.width &&
                    !groups.contains { other in
                        !other.ids.contains(marker.id) && candidate.insetBy(dx: -2, dy: 0).intersects(other.frame)
                    } && !labels.contains { $0.frame.insetBy(dx: -2, dy: 0).intersects(candidate) }
            }
            if let available { labels.append(MarkerLabel(id: marker.id, text: text, frame: available, overlaysMarker: false)) }
            else if marker.id == selectedEditID {
                let frame = CGRect(x: min(max(0, center - width / 2), max(0, bounds.width - width)),
                                   y: 39, width: width, height: 16)
                if !groups.contains(where: { !$0.ids.contains(marker.id) && $0.frame.insetBy(dx: -2, dy: 0).intersects(frame) }) {
                    labels.append(MarkerLabel(id: marker.id, text: text, frame: frame, overlaysMarker: true))
                }
            }
        }
        return labels
    }

    private func displayTime(for marker: RecordingTimelineMarker) -> Double {
        drag?.interaction == .edit(marker.id) ? drag?.editTime ?? marker.time : marker.time
    }

    private func drawMarkerLabels() {
        for label in markerLabels().reversed() {
            let selected = label.id == selectedEditID
            (label.overlaysMarker ? NSColor.systemPurple : NSColor.windowBackgroundColor).setFill()
            NSBezierPath(roundedRect: label.frame, xRadius: 3, yRadius: 3).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: label.overlaysMarker ? NSColor.white : selected ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]
            let text = label.text as NSString
            let width = text.size(withAttributes: attributes).width
            text.draw(at: CGPoint(x: label.frame.midX - width / 2, y: label.frame.minY + 2), withAttributes: attributes)
        }
    }

    private var minimumVisibleDuration: Double {
        let frame = frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30
        return min(max(duration, .leastNonzeroMagnitude), frame * 4)
    }

    private func markerIsVisible(_ time: Double) -> Bool {
        time.isFinite && time >= visibleStart && time <= visibleStart + visibleDuration
    }

    private func constrainViewport(reset: Bool = false) {
        guard duration.isFinite, duration > 0 else { return }
        setViewport(start: reset ? 0 : visibleStart, span: reset ? duration : visibleDuration)
    }

    private func setViewport(start: Double, span: Double) {
        guard animationGesture == nil else { return }
        guard start.isFinite, span.isFinite, duration.isFinite, duration > 0 else { return }
        visibleDuration = min(duration, max(minimumVisibleDuration, span))
        visibleStart = min(max(start, 0), max(0, duration - visibleDuration))
        updateRangeScroller()
        needsDisplay = true
        updateTooltips()
    }

    override func magnify(with event: NSEvent) {
        guard videoGesture == nil else { return }
        guard drag == nil, animationGesture == nil, duration.isFinite, duration > 0, event.magnification.isFinite else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !event.phase.contains(.cancelled) else { return }
        let fraction = min(1, max(0, Double((point.x - railOrigin) / railWidth)))
        let anchor = visibleStart + fraction * visibleDuration
        let nextSpan = min(duration, max(minimumVisibleDuration, visibleDuration / max(0.01, 1 + event.magnification)))
        setViewport(start: anchor - fraction * nextSpan, span: nextSpan)
    }

    override func scrollWheel(with event: NSEvent) {
        guard videoGesture == nil else { return }
        guard drag == nil, animationGesture == nil, duration.isFinite, duration > 0,
              !event.phase.contains(.cancelled), !event.momentumPhase.contains(.cancelled) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) || !event.momentumPhase.isEmpty else { return }
        let shifted = event.modifierFlags.contains(.shift)
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard dx.isFinite, dy.isFinite else { return }
        // A vertical scroll belongs to the enclosing track viewport. Genuine
        // diagonal gestures can scroll tracks and time together.
        if !shifted, abs(dy) > abs(dx) * 0.5 { super.scrollWheel(with: event) }
        let delta = shifted && dx == 0 ? dy : (abs(dx) >= abs(dy) * 0.5 ? dx : 0)
        guard delta != 0 else { return }
        // AppKit already applies the user's natural-scroll preference. Move
        // the time content with the fingers, including inertial scrolling.
        let units = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        setViewport(start: visibleStart - delta * units * visibleDuration / railWidth, span: visibleDuration)
    }

    private func drawTransitionBand(for marker: RecordingTimelineMarker) {
        guard let transitionStart = marker.transitionStart, transitionStart.isFinite,
              marker.time > transitionStart else { return }
        let offset = drag?.interaction == .edit(marker.id) ? (drag?.editTime ?? marker.time) - marker.time : 0
        let from = x(for: transitionStart + offset)
        let to = x(for: marker.time + offset)
        guard to - from >= 20, to >= 12, from <= bounds.width - 12 else { return }
        let duration = marker.time - transitionStart
        let first = min(duration, max(0, marker.easeIn.isFinite ? marker.easeIn : 0))
        let last = min(duration - first, max(0, marker.easeOut.isFinite ? marker.easeOut : 0))
        let riseEnd = x(for: transitionStart + offset + first)
        let fallStart = x(for: marker.time + offset - last)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CGRect(x: 12, y: 38, width: railWidth, height: 18)).addClip()
        let band = NSBezierPath()
        band.move(to: CGPoint(x: from, y: 53))
        band.line(to: CGPoint(x: riseEnd, y: 41))
        band.line(to: CGPoint(x: fallStart, y: 41))
        band.line(to: CGPoint(x: to, y: 53))
        band.close()
        NSColor.systemPurple.withAlphaComponent(0.25).setFill()
        band.fill()
        NSColor.systemPurple.withAlphaComponent(0.75).setStroke()
        band.lineWidth = 1
        band.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func timeRulerTicks() -> [(time: Double, label: String)] {
        let targetStep = visibleDuration / max(1, Double(railWidth / 90))
        let magnitude = pow(10, floor(log10(max(targetStep, .leastNonzeroMagnitude))))
        let step = ([1.0, 2, 5, 10].first { $0 * magnitude >= targetStep } ?? 10) * magnitude
        let decimals = min(3, max(0, Int(-floor(log10(step)))))
        var ticks: [(time: Double, label: String)] = []
        let last = visibleStart + visibleDuration
        var tick = ceil(visibleStart / step) * step
        while tick <= last + step * 0.000_001 {
            ticks.append((tick, String(format: "%.*f s", decimals, tick)))
            tick += step
        }
        return ticks
    }
    private func drawTimeTicks() {
        if showsAnimationLanes, pinnedTimeRuler != nil { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        for tick in timeRulerTicks() {
            let position = x(for: tick.time)
            let path = NSBezierPath()
            let tickY: CGFloat = showsAnimationLanes ? trackLayout.contentHeight - TimelineTrackLayout.footer : 57
            path.move(to: CGPoint(x: position, y: tickY))
            path.line(to: CGPoint(x: position, y: tickY + 3))
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
            let text = tick.label as NSString
            let width = text.size(withAttributes: attributes).width
            let labelX = min(max(position - width / 2, 0), bounds.width - width)
            text.draw(at: CGPoint(x: labelX, y: showsAnimationLanes ? trackLayout.contentHeight - TimelineTrackLayout.footer + 5 : 61), withAttributes: attributes)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            keyboardFocus = NSApplication.shared.currentEvent?.type == .keyDown ||
                (window?.keyViewSelectionDirection ?? .directSelection) != .directSelection
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { keyboardFocus = false; needsDisplay = true }
        return resigned
    }

    private func chooseEdits(_ ids: [UUID], at point: NSPoint) {
        let markers = ids.compactMap { id in edits.first { $0.id == id } }.sorted {
            $0.time == $1.time ? $0.id.uuidString < $1.id.uuidString : $0.time < $1.time
        }
        guard !markers.isEmpty else { return }
        let menu = NSMenu(title: "Choose edit")
        menu.autoenablesItems = false
        for marker in markers {
            let item = NSMenuItem(title: "\(marker.label ?? marker.help) · \(String(format: "%.3f s", marker.time))",
                                 action: #selector(chooseMarker(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = marker.id
            item.toolTip = marker.help
            item.state = marker.id == selectedEditID ? .on : .off
            menu.addItem(item)
        }
        activeMarkerMenu = menu
        if let presentMarkerMenu { presentMarkerMenu(menu, point) }
        else { menu.popUp(positioning: nil, at: point, in: self); activeMarkerMenu = nil }
    }

    @objc private func chooseMarker(_ item: NSMenuItem) {
        guard item.menu === activeMarkerMenu, let id = item.representedObject as? UUID,
              edits.contains(where: { $0.id == id }) else { return }
        activeMarkerMenu = nil
        onSelectEdit?(id)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let markerActions = showsAnimationLanes ? animationAccessibilityActions() : markerGroups().map { group in
            let name: String
            if group.isCluster { name = "Choose among \(group.ids.count) nearby edits" }
            else if let marker = edits.first(where: { $0.id == group.ids[0] }) {
                name = "Select \(marker.label ?? marker.help) at \(String(format: "%.3f", marker.time)) seconds"
            } else { name = "Select edit" }
            return NSAccessibilityCustomAction(name: name) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    if group.isCluster { self.chooseEdits(group.ids, at: NSPoint(x: group.frame.midX, y: group.frame.maxY)) }
                    else if let id = group.ids.first, self.edits.contains(where: { $0.id == id }) { self.onSelectEdit?(id) }
                    return true
                }
            }
        }
        let conflictActions = conflictBands().map { band in
            let side = band.span.side == .existing ? "Existing" : "Proposed"
            let name = String(format: "Review %@: %@, %.3f to %.3f seconds", side, band.span.label, band.span.start, band.span.end)
            return NSAccessibilityCustomAction(name: name) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.conflictSpans.contains(where: { $0 == band.span }) else { return false }
                    self.onInteractionBegan?(); self.onScrubBegan?()
                    self.seek(max(self.visibleStart, band.span.start))
                    self.onScrubEnded?(); self.scrubTime = nil
                    return true
                }
            }
        }
        return markerActions + conflictActions
    }

    override func mouseDown(with event: NSEvent) {
        guard duration.isFinite, duration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        keyboardFocus = false
        needsDisplay = true
        window?.makeFirstResponder(self)
        if showsAnimationLanes { freezeRows() }
        onInteractionBegan?()
        if showsAnimationLanes, event.modifierFlags.contains(.shift), point.x >= railOrigin, point.y <= 34 {
            rangeSelectionOnly = true; clipOrigin = point; clipRange = nil; return
        }
        if showsAnimationLanes, beginVideo(at: point) { return }
        if showsClipLane, clipLaneFrame.contains(point) {
            rangeSelectionOnly = false; clipOrigin = point; clipRange = nil
            return
        }
        let rampHit = showsAnimationLanes && animationGeometry().contains { geometry in
            [geometry.startHandle, geometry.endHandle, geometry.easeInHandle, geometry.easeOutHandle, geometry.deleteButton]
                .compactMap { $0 }.contains { controlHitFrame($0, for: geometry.animation).contains(point) }
        }
        if showsAnimationLanes, point.y >= TimelineTrackLayout.top || rampHit {
            beginAnimationInteraction(at: point)
            return
        }
        guard point.x >= railOrigin else { return }
        if !showsAnimationLanes, point.y >= 38 && point.y < 56 {
            let labelTarget = markerLabels().first { $0.frame.contains(point) }?.id
            let target = markerGroups().first { group in
                if let labelTarget { return group.ids.contains(labelTarget) }
                return group.frame.contains(point)
            }
            if let target, target.isCluster, target.selectedID == nil {
                drag = Drag(interaction: .cluster, originX: point.x, originTime: playhead,
                            start: trimStart, end: trimEnd, chooserIDs: target.ids, originY: point.y)
            } else if let target, let id = target.selectedID ?? target.ids.first,
                      let marker = edits.first(where: { $0.id == id }) {
                let others = edits.filter { $0.id != marker.id && $0.time.isFinite }
                let gap = frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30
                let previous = others.filter { $0.time < marker.time }.map(\.time).max()
                let following = others.filter { $0.time > marker.time }.map(\.time).min()
                // Existing projects may have off-grid or unusually close edits.
                // Preserve the original time while preventing new collisions.
                let requestedMinimum = marker.minimumTime.isFinite ? marker.minimumTime : 0
                let requestedMaximum = marker.maximumTime.flatMap { $0.isFinite ? $0 : nil } ?? duration
                let minimum = max(requestedMinimum, max(0, min(marker.time, previous.map { $0 + gap } ?? 0)))
                let maximum = min(requestedMaximum, min(duration, max(marker.time, following.map { $0 - gap } ?? duration)))
                drag = Drag(interaction: .edit(marker.id), originX: point.x, originTime: marker.time,
                            start: trimStart, end: trimEnd, editTime: marker.time,
                            minimumTime: minimum, maximumTime: maximum, movable: marker.movable && minimum <= maximum,
                            chooserIDs: target.isCluster ? target.ids : nil, originY: point.y)
            } else {
                drag = Drag(interaction: .emptyEditLane, originX: point.x, originTime: playhead,
                            start: trimStart, end: trimEnd)
            }
            return
        }
        guard point.y < 36 else { return }
        let startDistance = markerIsVisible(trimStart) ? abs(point.x - x(for: trimStart)) : .infinity
        let endDistance = markerIsVisible(trimEnd) ? abs(point.x - x(for: trimEnd)) : .infinity
        let interaction: Interaction
        if showsTrimHandles, point.y >= 12, min(startDistance, endDistance) <= 12 {
            interaction = startDistance <= endDistance ? .start : .end
        } else { interaction = .scrub }
        let origin: Double
        if interaction == .scrub {
            onScrubBegan?()
            // Grab the thumb without a jump; a click elsewhere seeks directly.
            origin = point.y < 12 && abs(point.x - x(for: playhead)) <= 10 ? playhead : time(for: point.x)
            seek(origin)
        } else { origin = interaction == .start ? trimStart : trimEnd }
        drag = Drag(interaction: interaction, originX: point.x, originTime: origin, start: trimStart, end: trimEnd)
        if interaction == .start || interaction == .end { drag?.originalPlayhead = playhead }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if videoGesture != nil { updateVideo(at: convert(event.locationInWindow, from: nil), final: false); return }
        if let origin = clipOrigin {
            let point = convert(event.locationInWindow, from: nil)
            if abs(point.x - origin.x) >= 3 {
                let a = time(for: origin.x), b = time(for: point.x)
                clipRange = min(a, b)...max(a, b); onRangeSelection?(clipRange); needsDisplay = true
            }
            return
        }
        if showsAnimationLanes, animationGesture != nil { dragAnimation(with: event); return }
        guard var drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        drag.pointerMoved = drag.pointerMoved || max(abs(point.x - drag.originX), abs(point.y - drag.originY)) >= 3
        self.drag = drag
        let next = drag.originTime + Double((point.x - drag.originX) / railWidth) * visibleDuration
        switch drag.interaction {
        case .emptyEditLane, .cluster: break
        case .scrub: seek(next)
        case .start: drag.start = min(max(next, 0), drag.end - minimumLength)
        case .end: drag.end = max(min(next, duration), drag.start + minimumLength)
        case .edit(let id):
            guard drag.movable, drag.hasMoved || abs(point.x - drag.originX) >= 3 else { return }
            let firstMovement = !drag.hasMoved
            drag.hasMoved = true
            let step = frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30
            drag.editTime = min(max((next / step).rounded() * step, drag.minimumTime), drag.maximumTime)
            self.drag = drag
            if firstMovement, drag.chooserIDs == nil { onSelectEdit?(id) }
            onMoveEdit?(id, drag.editTime, false)
        }
        self.drag = drag
        if drag.interaction == .start || drag.interaction == .end {
            let current = scrubTime ?? playhead
            let clamped = min(max(current, drag.start), drag.end)
            if clamped != current {
                scrubTime = clamped
                onTrimPlayhead?(clamped)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { thawRows(); rangeSelectionOnly = false }
        if videoEmptyClick { videoEmptyClick = false; onSelectVideo?(nil, nil, nil); return }
        if videoGesture != nil { updateVideo(at: convert(event.locationInWindow, from: nil), final: true); return }
        if clipOrigin != nil {
            let point = convert(event.locationInWindow, from: nil)
            clipOrigin = nil
            if let range = clipRange { onRangeSelection?(range) }
            else if rangeSelectionOnly { onRangeSelection?(nil) }
            else if let (cut, _) = cutMarkerFrames().first(where: { $0.1.contains(point) }) { onRangeSelection?(nil); onSelectCut?(cut.id) }
            else { onRangeSelection?(nil); onScrubBegan?(); seek(time(for: point.x)); onScrubEnded?(); scrubTime = nil }
            clipRange = nil; needsDisplay = true; return
        }
        if showsAnimationLanes, animationGesture != nil || animationClickID != nil || animationDeleteID != nil || animationChooserIDs != nil || animationEmptyClick {
            endAnimationInteraction(at: convert(event.locationInWindow, from: nil)); return
        }
        guard let drag else { return }
        self.drag = nil
        scrubTime = nil
        switch drag.interaction {
        case .cluster:
            if !drag.pointerMoved, let ids = drag.chooserIDs {
                chooseEdits(ids, at: convert(event.locationInWindow, from: nil))
            }
        case .emptyEditLane: onDeselectEdit?()
        case .scrub: onScrubEnded?()
        case .start, .end:
            if drag.start != trimStart || drag.end != trimEnd { onTrim?(drag.start, drag.end) }
        case .edit(let id):
            if drag.hasMoved { onMoveEdit?(id, drag.editTime, true) }
            else if !drag.pointerMoved, let ids = drag.chooserIDs {
                chooseEdits(ids, at: convert(event.locationInWindow, from: nil))
            }
            else if drag.chooserIDs == nil { onSelectEdit?(id) }
        }
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        defer { thawRows() }
        if videoGesture != nil { videoGesture = nil; onVideoCancel?(); return }
        if selectedVideoClipID != nil { onSelectVideo?(nil, nil, nil); return }
        if clipOrigin != nil || selectedRange != nil {
            clipOrigin = nil; clipRange = nil; onRangeSelection?(nil); needsDisplay = true; return
        }
        if let activeAnimationMenu { activeAnimationMenu.cancelTracking(); self.activeAnimationMenu = nil; return }
        if showsAnimationLanes, animationGesture != nil || animationClickID != nil || animationDeleteID != nil || animationChooserIDs != nil || animationEmptyClick {
            cancelAnimationGesture(); return
        }
        if let activeMarkerMenu { activeMarkerMenu.cancelTracking(); self.activeMarkerMenu = nil; return }
        let active = drag
        if let original = active?.originalPlayhead, scrubTime != nil {
            onTrimPlayhead?(original)
        }
        drag = nil
        scrubTime = nil
        if let active, case .edit = active.interaction, active.hasMoved {
            onCancelMoveEdit?()
        } else {
            if active?.interaction == .scrub { onScrubEnded?() }
            onCancelEdit?()
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil); return }
        if event.keyCode == 51 || event.keyCode == 117, let id = selectedVideoClipID,
           let row = videoRows.first(where: { $0.clip.id == id }) {
            onDeleteVideo?(row.layerID, id, selectedVideoVolumeID); return
        }
        if showsClipLane, selectedRange != nil, event.keyCode == 51 || event.keyCode == 117 {
            onInteractionBegan?(); onCutRange?(); return
        }
        if showsClipLane, let id = selectedCutID, event.keyCode == 51 || event.keyCode == 117 {
            if cutMarkers.contains(where: { $0.id == id }) { onInteractionBegan?(); onRestoreCut?(id) }
            return
        }
        if showsAnimationLanes, event.keyCode == 51 || event.keyCode == 117 {
            guard let id = selectedAnimationID, animationSpans.contains(where: { $0.id == id && $0.editable }) else { return }
            cancelAnimationGesture(); onInteractionBegan?(); onDeleteAnimation?(id); return
        }
        guard event.keyCode == 123 || event.keyCode == 124 else { super.keyDown(with: event); return }
        keyboardFocus = true
        onInteractionBegan?()
        let step = event.modifierFlags.contains(.shift) ? 1.0 : (frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30)
        onScrubBegan?()
        seek(playhead + (event.keyCode == 123 ? -step : step))
        onScrubEnded?()
        scrubTime = nil
        needsDisplay = true
    }

    override func accessibilityValue() -> Any? { NSNumber(value: playhead) }
    override func accessibilityPerformIncrement() -> Bool { accessibleSeek(frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30) }
    override func accessibilityPerformDecrement() -> Bool { accessibleSeek(-(frameDuration.isFinite && frameDuration > 0 ? frameDuration : 1.0 / 30)) }

    private func accessibleSeek(_ delta: Double) -> Bool {
        keyboardFocus = true
        onInteractionBegan?()
        onScrubBegan?()
        seek(playhead + delta)
        onScrubEnded?()
        scrubTime = nil
        needsDisplay = true
        return true
    }

    private func seek(_ value: Double) {
        let bounded = min(max(value, allowsSeekingOutsideTrim ? 0 : trimStart), allowsSeekingOutsideTrim ? duration : trimEnd)
        scrubTime = bounded
        onSeek?(bounded)
        needsDisplay = true
    }
}
