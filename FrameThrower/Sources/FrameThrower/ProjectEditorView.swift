import AppKit
import Combine
import SwiftUI
import QuickLook

private enum EditorInspector: String, CaseIterable {
    case zoom = "Zoom", pointer = "Pointer", camera = "Camera", speed = "Speed", canvas = "Canvas", audio = "Audio", videos = "Videos", layers = "Layers"
}

private enum PreviewTool: String, CaseIterable {
    case pan = "Pan & zoom", box = "Draw box"
}
private struct SpeedProfileIdentity: Equatable {
    var points: [RecordingSpeedKeyframe]
    var cuts: [RecordingCut]
    var trimStart: Double
    var trimEnd: Double
    var duration: Double
    var source: Bool
}

struct ProjectEditorView: View {
    @ObservedObject var editor: ProjectEditor
    var onDuplicate: ((ProjectEditor) -> Void)?
    var isDuplicateUnavailable: Bool
    @StateObject private var playback: EditorPlayback
    @StateObject private var automation: EditorAutomationHost
    @State private var editorRenameRequest: UUID?
    @State private var selectedInspector: EditorInspector = .zoom
    @State private var selectedVideoLayerID: UUID?
    @State private var selectedVideoClipID: UUID?
    @State private var selectedVideoVolumeID: UUID?
    @State private var videoGestureState: EditState?
    @State private var importingVideos = false
    @State private var videoFramingClipID: UUID?
    @State private var videoFramingTime: Double?
    @State private var selectedContentLayerID: UUID?
    @State private var selectedEditID: UUID?
    @State private var presentationDraft: CanvasPresentation?
    @State private var audioGestureTime: Double?
    @State private var audioRole: RecordingAudioRole = .microphone
    @State private var audioVolumeGesture: AudioVolumeGesture?
    @State private var audioTransition: PIPTransition = .smooth
    @State private var audioDuration = 0.4
    @State private var timelineFitRequest: UUID?
    private let timelineTimeBase: EditorCutTimeBase = .output
    @State private var cutRangeStart: Double?
    @State private var cutSelection: ClosedRange<Double>?
    @State private var selectedCutID: UUID?
    @State private var cutDuration = 0.5
    @State private var cutPopoverAnchor = UnitPoint.center
    @State private var timelineError: String?
    @State private var movingEditState: EditState?
    @State private var selectedAnimationDisplayID: TimelineAnimationID?
    @State private var selectedAnimationID: TimelineAnimationID?
    @State private var animationGesture: AnimationGestureSnapshot?
    @State private var zoomEaseIn: Double?
    @State private var zoomEaseOut: Double?
    @State private var cameraEaseIn: Double?
    @State private var cameraEaseOut: Double?
    @State private var zoomTransition: PIPTransition = .smooth
    @State private var zoomDuration = 0.4
    @State private var speedTransition: PIPTransition = .smooth
    @State private var speedDuration = 0.4
    @State private var speedCurves: [[TimelineSpeedSample]] = []
    @State private var transition: PIPTransition = .jump
    @State private var transitionDuration = 0.6
    @State private var dragTime = 0.0
    @State private var cropRequest: VideoCropRequest?
    @StateObject private var exportSession = VideoExportSession()
    @StateObject private var assistant: EditorAssistantSession
    @State private var directorMode = false
    @State private var propertiesVisible = true
    @State private var propertyScrollRequest = UUID()
    @State private var timelineViewportHeight: CGFloat?
    @State private var timelineHeightFraction: CGFloat?
    @State private var timelineResizeStart: CGFloat?
    @State private var expandedVideoVolumeLayerIDs: Set<UUID> = []
    @State private var originalPreviewURL: URL?
    @State private var previewTool: PreviewTool = .pan
    @State private var selectedRegionID: UUID?
    @State private var referenceFrameTime: Double?
    @State private var comparisonDismissedForManualEdit = false
    @State private var canvasGesture: CanvasGestureSnapshot?
    private struct CanvasGestureSnapshot {
        let id = UUID()
        let state: EditState
        let time: Double
        let hadDraft: Bool
        let playhead: Double
        let outputPlayhead: Double
        var lane: TimelineAnimationLane
    }

    private var state: EditState { editor.editingState }
    private var videoEditingTime: Double {
        guard !playback.isInspectingSource, playback.outputDuration > 0,
              playback.outputTime >= playback.outputDuration,
              let end = playback.outputSamples.last?.sourceTime else { return playback.editingTime }
        return editor.project.editingTime(at: max(0, end.nextDown), frameDuration: frameDuration)
    }
    private var conflictReview: EditorConflictReview? { assistant.conflictReview }
    private var canvasPresentation: CanvasPresentation { presentationDraft ?? state.presentation }
    private var edits: [TimedEdit] { state.timedEdits(includeCamera: editor.project.cameraFilename != nil).filter { state.showsTimedEdit($0) } }
    private var selectedEdit: TimedEdit? { edits.first { $0.id == selectedEditID } }
    private var editTime: Double { selectedAnimationTime ?? selectedEdit?.time ?? editor.draftTime ?? playback.editingTime }
    private var selectedAnimationTime: Double? {
        guard let selectedAnimationID else { return nil }
        let id = selectedAnimationID.componentID
        switch selectedAnimationID.lane {
        case .screen: return state.zoomKeyframes.first { $0.id == id }?.time ?? state.editAnchors.first { $0.id == id }?.time
        case .camera: return state.pipKeyframes.first { $0.id == id }?.time
        case .speed: return state.speedKeyframes.first { $0.id == id }?.time
        case .cameraOpacity: return state.cameraOpacityEvents.first { $0.id == id }?.time
        case .pointer: return nil
        case .audioMicrophone, .audioSystem: return selectedAnimationID.lane.audioRole.flatMap { role in state.audio.channel(role).points.first { $0.id == id }?.time }
        }
    }
    private var point: PIPKeyframe? { state.pipKeyframes.first { abs($0.time - editTime) < 0.000001 } }
    private var usesCameraOpacityTiming: Bool { selectedAnimationID?.lane == .cameraOpacity }
    private var opacityPoint: CameraOpacityKeyframe? { state.cameraOpacityKeyframes.first { abs($0.time - editTime) < 0.000001 } }
    private var cameraTimingPoint: PIPKeyframe? {
        guard usesCameraOpacityTiming else { return point }
        guard let value = opacityPoint else { return nil }
        return PIPKeyframe(id: value.id, time: value.time, placement: PIPPlacement(), transition: value.transition,
            duration: value.duration, easeIn: value.easeIn, easeOut: value.easeOut)
    }
    private var placement: PIPPlacement { state.placement(at: editTime) }
    private var zoom: ZoomPlacement { state.zoom(at: editTime) }
    private var zoomPoint: ZoomKeyframe? { state.zoomKeyframes.first { abs($0.time - editTime) < 0.000001 } }
    private var speedPoint: RecordingSpeedKeyframe? { state.speedKeyframes.first { abs($0.time - editTime) < 0.000001 } }
    private var frameDuration: Double { playback.frameDuration }
    private struct AudioVolumeGesture {
        let state: EditState
        let role: RecordingAudioRole
        let point: RecordingAudioGainPoint
    }
    private struct AnimationGestureSnapshot {
        let id: TimelineAnimationID
        let originalID: TimelineAnimationID
        let state: EditState
        let spans: [TimelineAnimation]
        let replacements: [TimelineAnimationID: UUID]
        let playhead: Double
        let selection: UUID?
        let animationSelection: TimelineAnimationID?
        let name: String
        let timeBase: EditorCutTimeBase
        let map: RecordingTimeMap?
        let outputPlayhead: Double
        var previewSpans: [TimelineAnimation]
    }
    private var timelineAnimations: [TimelineAnimation] {
        EditorAnimationEditing.animations(in: state, references: editor.references, duration: editor.project.duration,
            includeCamera: editor.project.cameraFilename != nil)
            .filter { $0.lane != .pointer || editor.project.cursorFilename != nil }
    }

    private var timeMapResult: Result<RecordingTimeMap, any Error> {
        if let map = animationGesture?.map { return .success(map) }
        return Result { try playback.timingMap(for: state, duration: editor.project.duration) }
    }
    private var timelineMap: RecordingTimeMap? { try? timeMapResult.get() }
    private var timeMapError: String? { if case let .failure(error) = timeMapResult { return error.localizedDescription }; return nil }
    private var isSourceTimeline: Bool { (animationGesture?.timeBase ?? timelineTimeBase) == .source }
    private var timelineDuration: Double { isSourceTimeline ? editor.project.duration : timelineMap?.outputDuration ?? playback.outputDuration }
    private var timelinePosition: Double { isSourceTimeline ? playback.time : playback.outputTime }
    private var timelineIsIdentity: Bool { state.cuts.isEmpty && state.speedKeyframes.isEmpty && state.trimStart == 0 && state.trimEnd == editor.project.duration }
    private var outputProjection: TimelineOutputProjection? {
        if let gesture = animationGesture, let map = gesture.map {
            return TimelineOutputProjection(animations: gesture.previewSpans, map: map)
        }
        guard !isSourceTimeline, !timelineIsIdentity, let map = timelineMap else { return nil }
        return TimelineOutputProjection(animations: timelineAnimations, map: map)
    }
    private var displayedAnimations: [TimelineAnimation] { outputProjection?.animations ?? timelineAnimations }
    private var speedProfileIdentity: SpeedProfileIdentity {
        .init(points: state.speedKeyframes, cuts: state.cuts, trimStart: state.trimStart,
              trimEnd: state.trimEnd, duration: editor.project.duration, source: isSourceTimeline)
    }
    private var displayedAnimationID: TimelineAnimationID? {
        guard let selectedAnimationID else { return nil }
        guard let projection = outputProjection else { return selectedAnimationID }
        if let displayed = animationGesture?.id ?? selectedAnimationDisplayID, projection.sourceIDs[displayed] == selectedAnimationID { return displayed }
        return projection.animations.first { projection.sourceIDs[$0.id] == selectedAnimationID }?.id
    }
    private var canvasOutputSamples: [EditorCanvasSample] {
        guard !isSourceTimeline, conflictReview == nil else { return [] }
        return playback.outputSamples.map {
            EditorCanvasSample(sourceTime: $0.sourceTime, weight: $0.weight,
                zoom: state.zoom(at: $0.sourceTime), placement: state.placement(at: $0.sourceTime))
        }
    }
    private var isBlendedCanvas: Bool { canvasOutputSamples.count > 1 }
    private var hasAmbiguousFramingTarget: Bool { isBlendedCanvas && selectedEdit == nil && selectedAnimationTime == nil && playback.selectedProjectBranch == nil }
    private var timelineClipBands: [TimelineClipBand] {
        if !isSourceTimeline {
            return (timelineMap?.clips ?? []).enumerated().map { index, clip in
                TimelineClipBand(id: "clip-\(index)", start: clip.outputStart, end: clip.outputEnd, excluded: false, label: "Clip \(index + 1)")
            }
        }
        let cuts = state.cuts.sorted { $0.start < $1.start }
        var bands: [TimelineClipBand] = []; var cursor = 0.0
        for cut in cuts {
            if cursor < cut.start { bands.append(TimelineClipBand(id: "source-\(cursor)", start: cursor, end: cut.start, excluded: false, label: "Source")) }
            bands.append(TimelineClipBand(id: cut.id.uuidString, start: cut.start, end: cut.end, excluded: true, label: "Removed")); cursor = cut.end
        }
        if cursor < editor.project.duration { bands.append(TimelineClipBand(id: "source-\(cursor)", start: cursor, end: editor.project.duration, excluded: false, label: "Source")) }
        return bands
    }
    private var timelineCutMarkers: [TimelineCutMarker] {
        if isSourceTimeline {
            return state.cuts.map { cut in
                TimelineCutMarker(id: cut.id, start: cut.start, end: cut.end,
                    help: String(format: "Removed source %.3f–%.3f s. Click to restore or change its join.", cut.start, cut.end),
                    label: cut.crossfade > 0 ? "Fade" : "Cut", showsTransitionSpan: false)
            }
        }
        return (timelineMap?.joins ?? []).map { join in
            TimelineCutMarker(id: join.id, start: join.outputStart, end: join.outputEnd,
                help: String(format: "%@ · requested %.3f s, effective %.3f s. Click to change or restore the section.", join.duration > 0 ? "Crossfade" : "Cut", join.requestedDuration, join.duration))
        }
    }
    private var timelineConflicts: [EditorConflictSpan] {
        let spans = (conflictReview?.existingSpans ?? []) + (conflictReview?.proposedSpans ?? [])
        guard !isSourceTimeline, let map = timelineMap else { return spans }
        return spans.flatMap { span -> [EditorConflictSpan] in
            if span.isInstant {
                guard let time = map.outputTime(for: span.start) else { return [] }
                return [EditorConflictSpan(id: span.id, side: span.side, start: time, end: time, label: span.label, help: span.help)]
            }
            return map.clips.enumerated().compactMap { index, clip in
                let a = max(span.start, clip.sourceStart), b = min(span.end, clip.sourceEnd)
                guard a < b else { return nil }
                return EditorConflictSpan(id: "\(span.id)-\(index)", side: span.side,
                    start: clip.outputTime(for: a), end: clip.outputTime(for: b),
                    label: span.label, help: span.help)
            }
        }
    }
    private var timelineConflictOverlaps: [ClosedRange<Double>] {
        let ranges = conflictReview?.overlapIntervals ?? []
        guard !isSourceTimeline, let map = timelineMap else { return ranges }
        return ranges.flatMap { range in map.clips.compactMap { clip -> ClosedRange<Double>? in
            let a = max(range.lowerBound, clip.sourceStart), b = min(range.upperBound, clip.sourceEnd)
            guard a <= b else { return nil }
            return (clip.outputTime(for: a))...(clip.outputTime(for: b))
        } }
    }

    init(editor: ProjectEditor, directorModeInitiallyEnabled: Bool = false,
         playback: EditorPlayback? = nil,
         assistant: EditorAssistantSession? = nil,
         onDuplicate: ((ProjectEditor) -> Void)? = nil, isDuplicateUnavailable: Bool = false) {
        self.editor = editor
        self.onDuplicate = onDuplicate
        self.isDuplicateUnavailable = isDuplicateUnavailable
        let playback = playback ?? EditorPlayback()
        _playback = StateObject(wrappedValue: playback)
        _automation = StateObject(wrappedValue: EditorAutomationHost(editor: editor, playback: playback))
        _assistant = StateObject(wrappedValue: assistant ?? EditorAssistantSession())
        _directorMode = State(initialValue: directorModeInitiallyEnabled)
        _previewTool = State(initialValue: directorModeInitiallyEnabled ? .box : .pan)
    }


    var body: some View {
        GeometryReader { geometry in
            let timelineHeight = EditorWorkspaceAllocation.timeline(height: geometry.size.height,
                content: videoTimelineHeight + 20 + (geometry.size.width < 850 ? 68 : 36),
                fraction: timelineHeightFraction, dragHeight: timelineViewportHeight)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 8) {
                    previewWorkspace.accessibilityIdentifier("editor-preview")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                    EditorTimelineDivider(onBegin: {
                        timelineResizeStart = timelineHeight
                    }, onDrag: { delta in
                        timelineViewportHeight = min(max(100, (timelineResizeStart ?? timelineHeight) + delta), max(100, geometry.size.height - 186))
                    }, onEnd: { cancelled in
                        if !cancelled, let height = timelineViewportHeight {
                            timelineHeightFraction = height / max(1, geometry.size.height)
                        }
                        timelineViewportHeight = nil; timelineResizeStart = nil
                    })
                        .frame(height: 10)
                        .accessibilityLabel("Resize timeline")
                        .help("Drag up to reveal more tracks, or down to give the preview more space.")
                    timeline.frame(height: timelineHeight).accessibilityIdentifier("editor-timeline")
                    if let message = timelineError ?? timeMapError ?? editor.errorMessage ?? playback.errorMessage ?? automation.errorMessage {
                        Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                if propertiesVisible || directorMode {
                    VStack(spacing: 10) {
                        if propertiesVisible {
                            inspector.frame(maxHeight: directorMode ? min(250, geometry.size.height * 0.34) : .infinity)
                        }
                        if directorMode {
                            if propertiesVisible { Divider() }
                            directorPanel.frame(minHeight: 160, maxHeight: .infinity)
                        }
                    }
                    .frame(width: min(320, max(280, geometry.size.width * 0.27))).frame(maxHeight: .infinity)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 720, idealWidth: 1100, maxWidth: .infinity,
               minHeight: 540, idealHeight: 780, maxHeight: .infinity)
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            guard !MediaProcessing.isSuspended, !urls.isEmpty, !importingVideos else { return false }
            playback.pause(); assistant.cancel(); importingVideos = true
            let time = playback.editingTime
            Task {
                defer { importingVideos = false }
                do {
                    let selected = try await ProjectVideoImport.addSources(urls, to: editor, at: time)
                    selectedVideoLayerID = selected.0; selectedVideoClipID = selected.1; selectedVideoVolumeID = nil
                    selectedInspector = .videos
                } catch { timelineError = error.localizedDescription }
            }
            return true
        }
        .background(EditorDraftLifecycle(editor: editor).frame(width: 0, height: 0))
        .sheet(item: $cropRequest) { request in VideoCropEditor(request: request, directory: editor.url.deletingLastPathComponent()) }
        .navigationTitle(editor.displayName)
        .focusedSceneObject(editor)
        .task {
            await automation.rebuildPreview()
            if conflictReview != nil { reviewConflict() }
            if let time = editor.draftTime, let draft = editor.draftState {
                playback.seekProjectTime(time)
                selectedEditID = edits.first(where: { abs($0.time - time) < 0.000001 })?.id
                playback.preview(draft)
            }
        }
        .onChange(of: assistant.conflictReviewID) { _, _ in reviewConflict() }
        .onReceive(automation.$pendingFramingProposal) { proposal in
            guard let proposal else { assistant.clearNativeConflict(); return }
            let host = automation
            assistant.presentNativeConflict(id: proposal.id, conflict: proposal.conflict, context: proposal.context,
                preparedState: proposal.preparedState) { [weak host] choice in
                    guard let host else { throw EditorAutomationError.unavailable }
                    return try host.resolveFramingProposal(id: proposal.id, choice: choice)
                }
        }
        .onChange(of: playback.time) { _, _ in refreshConflictFrame() }
        .onChange(of: selectedEditID) { _, _ in if conflictReview == nil { automation.recordEvent("selection_changed") } }
        .onChange(of: selectedRegionID) { _, _ in if conflictReview == nil { automation.recordEvent("selection_changed") } }
        .onChange(of: selectedVideoLayerID) { _, _ in if conflictReview == nil { automation.recordEvent("selection_changed") } }
        .onChange(of: selectedVideoClipID) { _, _ in if conflictReview == nil { automation.recordEvent("selection_changed") } }
        .onChange(of: selectedVideoVolumeID) { _, _ in if conflictReview == nil { automation.recordEvent("selection_changed") } }
        .onChange(of: playback.isScrubbing) { _, scrubbing in if !scrubbing { refreshConflictFrame(); automation.recordEvent("preview_seek") } }
        .onChange(of: playback.isLoading) { _, loading in if !loading { refreshConflictFrame() } }
        .onChange(of: speedProfileIdentity, initial: true) { _, _ in
            speedCurves = TimelineSpeedProfile.curves(points: state.speedKeyframes, duration: editor.project.duration,
                map: isSourceTimeline ? nil : timelineMap)
        }
        .onChange(of: editor.project.state) { old, next in
            let videoLayers = editor.project.effectiveVideoLayers(in: next)
            if let selectedVideoLayerID, !videoLayers.contains(where: { $0.id == selectedVideoLayerID }) {
                self.selectedVideoLayerID = nil; selectedVideoClipID = nil; selectedVideoVolumeID = nil
            }
            if let selectedVideoClipID, let clip = videoLayers.flatMap(\.clips).first(where: { $0.id == selectedVideoClipID }) {
                if let selectedVideoVolumeID, !clip.volumeKeyframes.contains(where: { $0.id == selectedVideoVolumeID }) { self.selectedVideoVolumeID = nil }
            } else { selectedVideoClipID = nil; selectedVideoVolumeID = nil }
            if let selectedContentLayerID, !next.contentLayers.contains(where: { $0.id == selectedContentLayerID }) { self.selectedContentLayerID = nil }
            animationGesture = nil; videoGestureState = nil; videoFramingClipID = nil; videoFramingTime = nil
            if let selectedRegionID, !next.regions.contains(where: { $0.id == selectedRegionID }) { self.selectedRegionID = nil }
            if let selectedEditID, !edits.contains(where: { $0.id == selectedEditID }) { self.selectedEditID = nil }
            if let selectedAnimationID, !timelineAnimations.contains(where: { $0.id == selectedAnimationID }) {
                self.selectedAnimationID = nil
                self.selectedEditID = nil
            }
            var oldVisual = old; oldVisual.regions = []
            var nextVisual = next; nextVisual.regions = []
            oldVisual.editAnchors = []; nextVisual.editAnchors = []
            guard oldVisual != nextVisual else { return }
            Task {
                await automation.rebuildPreview()
            }
        }
        .onChange(of: editor.draftState) { old, next in
            if let next {
                // As with a direct preview gesture, starting a manual edit
                // leaves comparison mode before showing that edit's pixels.
                leaveConflictForManualEdit()
                playback.preview(next)
                if animationGesture == nil { synchronizeAnimationSelection() }
            }
            else if let old, old != editor.project.state { playback.cancelPreview() }
        }
        .onChange(of: editor.historyNavigationToken) { _, _ in
            guard let time = editor.historyNavigationTime else { return }
            selectedEditID = edits.first(where: { abs($0.time - time) < 0.000001 })?.id
            playback.pause()
            playback.selectEditingBranch(nearProjectTime: selectedEdit?.time)
            synchronizeAnimationSelection()
        }
        .onChange(of: playback.isInspectingSource) { _, _ in
            automation.timelineTimeBase = "output"
        }
        .onChange(of: state.trimStart) { _, _ in cutSelection = nil }
        .onChange(of: state.trimEnd) { _, _ in cutSelection = nil }
        .onChange(of: state.cuts) { _, _ in
            cutSelection = nil
            if let selectedCutID, !state.cuts.contains(where: { $0.id == selectedCutID }) { self.selectedCutID = nil }
        }
        .onChange(of: selectedInspector) { _, next in
            propertyScrollRequest = UUID()
            if next != .videos {
                let clip = editor.project.effectiveVideoLayers(in: state).flatMap(\.clips).first { $0.id == selectedVideoClipID }
                let keepsClip = (clip?.layout == .screen && next == .zoom) || (clip?.layout == .camera && next == .camera)
                if !keepsClip { selectedVideoClipID = nil; selectedVideoVolumeID = nil }
            }
            if next == .videos { selectedEditID = nil; selectedAnimationID = nil; previewTool = .pan }
            else if next == .layers { selectedEditID = nil; selectedAnimationID = nil }
            else if animationGesture == nil { synchronizeAnimationSelection() }
        }
        .onAppear {
            assistant.attach(to: editor)
            configureAutomation()
            assistant.attachAutomation(automation)
            EditorAutomationRegistry.shared.register(automation)
        }
        .onDisappear { assistant.suspend(); EditorAutomationRegistry.shared.unregister(automation); automation.navigate = nil; automation.conversationPage = nil; automation.selection = { (nil, nil, nil, nil) }; automation.videoSelection = { (nil, nil, nil) }; exportSession.cancel(); _ = editor.finishDraft(); playback.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            assistant.suspend()
            LocalModelRuntime.terminateOwnedProcess()
            DirectorModelTransport.terminateOwnedProcesses()
            _ = editor.finishDraft()
        }
        .onExitCommand { cancelEditorInteraction() }
        .onDeleteCommand {
            if cutSelection != nil { cutSelectedSection() }
            else if let selectedCutID { applyCutMutation(.restoreCut(cutID: selectedCutID), name: "Restore section") }
            else if let layer = selectedVideoLayerID, let clip = selectedVideoClipID { deleteVideo(layer: layer, clip: clip, point: selectedVideoVolumeID) }
            else { deleteSelectedBox() }
        }
        .toolbarRole(.editor)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ProjectUndoButtons(editor: editor)
            }
            recordingTitleToolbar
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { directorMode }, set: { value in
                    if value != directorMode { toggleDirectorMode() }
                })) {
                    HStack(alignment: .center, spacing: 6) {
                        Text("🎬").accessibilityHidden(true)
                        Text("Director")
                    }
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .frame(minHeight: 24, alignment: .center)
                }
                    .toggleStyle(.button)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Director mode")
                    .help(directorMode ? "Close the Director conversation and reference boxes." : "Show reference boxes and type or dictate editing instructions.")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $propertiesVisible) { Label("Properties", systemImage: "sidebar.right") }
                    .toggleStyle(.button).labelStyle(.iconOnly)
                    .accessibilityLabel("Properties")
                    .help(propertiesVisible ? "Hide the selected object's properties." : "Show the selected object's properties.")
            }
            ToolbarItem(placement: .primaryAction) {
                VideoActionsMenu(editor: editor, session: exportSession,
                    isUnavailable: playback.isLoading, onSelect: { playback.pause() })
                    .frame(width: 28, height: 24)
            }
        }
        .onChange(of: directorMode) { _, active in
            if active { playback.pause(); if !editor.finishDraft() { directorMode = false } }
            else { assistant.cancel() }
        }
        .modifier(VideoExportPresentation(session: exportSession))
        .focusedSceneValue(\.editorFileActions, EditorFileActions(
            saveProject: { EditorSaveRouting.save(editor: editor, window: exportSession.window) },
            saveVideo: { beginExport(sharing: false) }, shareVideo: { beginExport(sharing: true) },
            rename: { editorRenameRequest = UUID() }, fitTimeline: { timelineFitRequest = UUID() },
            duplicate: isDuplicateUnavailable || assistant.isBusy ? nil : onDuplicate.map { callback in
                { playback.pause(); callback(editor) }
            },
            isBusy: exportSession.isBusy || playback.isLoading))
    }

    private func configureAutomation() {
        automation.timelineTimeBase = timelineTimeBase.rawValue
        let edit = $selectedEditID, box = $selectedRegionID, animation = $selectedAnimationID
        let inspector = $selectedInspector, director = $directorMode
        let videoLayer = $selectedVideoLayerID, videoClip = $selectedVideoClipID, videoVolume = $selectedVideoVolumeID
        automation.conversationPage = { [weak assistant] offset, limit in
            guard let assistant else { throw EditorAutomationError.unavailable }
            return try assistant.conversationPage(offset: offset, limit: limit)
        }
        automation.selection = {
            (edit.wrappedValue, box.wrappedValue,
             animation.wrappedValue.map { "\($0.lane.rawValue):\($0.componentID.uuidString)" }, inspector.wrappedValue.rawValue)
        }
        automation.videoSelection = { (videoLayer.wrappedValue, videoClip.wrappedValue, videoVolume.wrappedValue) }
        automation.navigate = { [weak editor, weak playback] operation, id, name in
            guard let editor, let playback else { throw EditorAutomationError.unavailable }
            // Match native boundaries: changing inspectors or selecting a
            // guide preserves a draft; selecting another edit/explicit seeking
            // finishes it. Selection itself never moves source time.
            let sameEdit = operation == "select_edit" && id.flatMap {
                editor.references.edit(in: editor.editingState, id: $0, includeCamera: editor.project.cameraFilename != nil)?.id
            } == edit.wrappedValue
            if ["clear_selection", "select_edit", "go_to_edit", "go_to_box"].contains(operation) && !sameEdit {
                guard editor.finishDraft() else { throw EditorCommandError.saveFailed(editor.errorMessage ?? "Couldn't save the current edit.") }
            }
            switch operation {
            case "clear_selection": edit.wrappedValue = nil; box.wrappedValue = nil; animation.wrappedValue = nil
                videoLayer.wrappedValue = nil; videoClip.wrappedValue = nil; videoVolume.wrappedValue = nil
            case "show_inspector":
                guard let name, let value = EditorInspector(rawValue: name) else { throw EditorAutomationError.invalid("Unknown inspector.") }
                inspector.wrappedValue = value
            case "select_edit", "go_to_edit":
                guard let id, let target = editor.references.edit(in: editor.editingState, id: id, includeCamera: editor.project.cameraFilename != nil) else { throw EditorAutomationError.invalid("That edit is no longer present.") }
                playback.pause()
                if sameEdit { return }
                edit.wrappedValue = target.id; animation.wrappedValue = nil
                if (target.speedID == id && target.zoomID != id && target.cameraID != id && target.cameraOpacityID != id) || (target.speedID != nil && target.cameraID == nil && target.zoomID == nil && target.cameraOpacityID == nil) { inspector.wrappedValue = .speed }
                else if (target.cameraID != nil || target.cameraOpacityID != nil) && target.zoomID == nil { inspector.wrappedValue = .camera }
                else if target.zoomID != nil && target.cameraID == nil { inspector.wrappedValue = .zoom }
                let lane: TimelineAnimationLane = inspector.wrappedValue == .camera
                    ? ((target.cameraOpacityID == id && target.cameraID != id) || (target.cameraID == nil && target.cameraOpacityID != nil) ? .cameraOpacity : .camera)
                    : inspector.wrappedValue == .speed ? .speed : inspector.wrappedValue == .pointer ? .pointer : .screen
                animation.wrappedValue = EditorAnimationEditing.animations(in: editor.editingState, references: editor.references,
                    duration: editor.project.duration, includeCamera: editor.project.cameraFilename != nil)
                    .first { $0.lane == lane && (lane == .pointer || $0.editID == target.id) }?.id
                if operation == "go_to_edit" { playback.seekProjectTime(target.time) }
            case "select_box", "go_to_box":
                guard let target = editor.editingState.regions.first(where: { $0.id == id }) else { throw EditorAutomationError.invalid("That box is no longer present.") }
                playback.pause(); box.wrappedValue = target.id; director.wrappedValue = true
                if operation == "go_to_box" {
                    let associated = target.editID.flatMap {
                        editor.references.edit(in: editor.editingState, id: $0, includeCamera: editor.project.cameraFilename != nil)
                    }
                    edit.wrappedValue = associated.flatMap { abs($0.time - target.time) < 0.000001 ? $0.id : nil }
                    animation.wrappedValue = nil
                    playback.seekProjectTime(target.time)
                }
            default: throw EditorAutomationError.invalid("Unknown navigation action.")
            }
        }
    }

    @ToolbarContentBuilder
    private var recordingTitleToolbar: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .principal) { recordingTitle }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { recordingTitle }
        }
    }

    private var directorPanel: some View {
            EditorAssistantPanel(editor: editor, session: assistant,
                selectedRegionID: selectedRegionID, selectedEditID: selectedEditID,
                onSelectEdit: { inspectEdit($0) }, onReviewConflict: { reviewConflict() }, onSelectRegion: { selectRegion($0) },
                onRemoveRegion: { removeRegion($0) }, onShowOriginalFrame: { showOriginalFrame($0) }, onSubmit: {
                    assistant.submit(editor: editor, playhead: playback.time,
                        regionID: selectedRegionID, editID: selectedEditID)
                }, onVoiceBegin: { playback.pause() }, onCancel: { cancelEditorInteraction() })
    }

    private var recordingTitle: some View {
        RecordingTitleEditor(editor: editor, renameRequest: editorRenameRequest,
            font: .systemFont(ofSize: 13, weight: .semibold))
            .frame(minWidth: 140, idealWidth: 240, maxWidth: 320, minHeight: 28, maxHeight: 28)
    }

    private var previewWorkspace: some View {
        GeometryReader { geometry in
            let output = PresentationGeometry(sourceSize: playback.sourceSize, presentation: canvasPresentation)
            let rect = output.outputRect(in: CGRect(origin: .zero, size: geometry.size))
            player.frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .frame(minHeight: 160)
        .background(EditorPreviewRegionMarker())
    }

    private var player: some View {
        EditorCanvas(player: playback.canvasPlayer, frames: playback.frameStore,
            sourceSize: playback.screenSize, cameraAspect: playback.cameraAspect,
            placement: state.placement(at: playback.time), cameraEnabled: selectedInspector != .videos && editor.project.effectiveVideoLayers(in: state).contains(where: { $0.clips.contains(where: { $0.layout == .camera && playback.time >= $0.start && playback.time < $0.end }) }) && editor.project.cameraFilename != nil && !playback.isScrubbing && !playback.isPlaying && conflictReview == nil && !hasAmbiguousFramingTarget,
            showsCameraPattern: editor.project.cameraFilename != nil && conflictReview == nil,
            showsStill: !playback.isPlaying,
            onBegin: { beginCameraGesture() },
            onPreview: { next in setPlacement(next, at: dragTime, name: "Edit") },
            onCommit: { next, name in setPlacement(next, at: dragTime, name: name); canvasGesture = nil },
            onCancel: {
                if let snapshot = canvasGesture { restoreCanvasGesture(snapshot) }
                else { cancelEditorInteraction() }
            },
            onToolCancel: {
                let snapshot = canvasGesture
                let expectedProject = editor.project
                let expectedDraft = editor.draftState
                // Native tool cancellation runs during a representable update.
                // Restore next turn only if no newer work has superseded it.
                Task { @MainActor in
                    guard canvasGesture?.id == snapshot?.id, editor.project == expectedProject,
                          editor.draftState == expectedDraft else { return }
                    restoreCanvasGesture(snapshot)
                }
            },
            prepareEditingPose: { EditorCanvasEditingPose(zoom: state.zoom(at: dragTime), placement: state.placement(at: dragTime)) },
            onEditingEnded: { canvasGesture = nil },
            zoom: conflictReview == nil ? state.zoom(at: playback.time) : ZoomPlacement(),
            allowsZoomEditing: selectedInspector != .videos && !playback.isLoading && !playback.isScrubbing && conflictReview == nil && !hasAmbiguousFramingTarget,
            panEditingScale: zoom.scale,
            onZoomBegin: { beginZoomGesture() },
            onZoomPreview: { next in setZoom(next, at: dragTime, name: "Edit") },
            onZoomCommit: { next, name in setZoom(next, at: dragTime, name: name); canvasGesture = nil },
            presentation: canvasPresentation, nativeSourceSize: playback.sourceSize,
            scribbleMode: directorMode && conflictReview == nil && !isBlendedCanvas,
            drawsReferenceBoxes: previewTool == .box,
            regions: conflictReview == nil && !isBlendedCanvas ? state.regions : [],
            regionLabels: Dictionary(uniqueKeysWithValues: state.regions.compactMap { region in
                editor.references.boxLabel(for: region.id).map { (region.id, $0) }
            }),
            selectedRegionID: selectedRegionID,
            onReferenceBegin: {
                cutSelection = nil; selectedCutID = nil
                assistant.cancel()
                if playback.isPlaying { selectedEditID = nil; selectedAnimationID = nil }
                playback.pause()
                referenceFrameTime = playback.editingTime
            },
            onDrawRegion: { addRegion($0) }, onSelectRegion: { selectRegion($0) },
            onDeleteRegion: { removeRegion($0) },
            conflictOutlines: conflictReview?.outlines(at: playback.time), outputSamples: canvasOutputSamples,
            videoProject: editor.project, videoState: state, videoTime: playback.time)
            .overlay {
                ContentLayersOverlay(layers: state.contentLayers, sourceSize: playback.sourceSize,
                    presentation: canvasPresentation, time: playback.time, samples: canvasOutputSamples,
                    selection: selectedContentLayerID,
                    isEditing: selectedInspector == .layers && conflictReview == nil && !isBlendedCanvas && !playback.isPlaying,
                    select: { selectedContentLayerID = $0 }, begin: {
                        assistant.cancel(); leaveConflictForManualEdit(); playback.pause()
                        return editor.finishDraft()
                    }, preview: { layer in
                        var next = state
                        guard let index = next.contentLayers.firstIndex(where: { $0.id == layer.id }) else { return }
                        next.contentLayers[index] = layer
                        _ = editor.updateDraft(next, at: playback.editingTime)
                    }, commit: { name in _ = editor.finishDraft(name: name) }, cancel: { _ = editor.cancelDraft() })
                .allowsHitTesting(selectedInspector == .layers && conflictReview == nil && !isBlendedCanvas && !playback.isPlaying)
            }
            .overlay {
                VideoClipOverlay(project: editor.project, state: state, sourceSize: playback.sourceSize, time: videoEditingTime,
                    selection: selectedVideoClipID,
                    isEditing: selectedInspector == .videos && !(directorMode && previewTool == .box) && !playback.isPlaying && !hasAmbiguousFramingTarget && conflictReview == nil,
                    select: { layer, clip in
                        if clip != selectedVideoClipID { guard editor.finishDraft() else { return } }
                        selectedVideoLayerID = layer; selectedVideoClipID = clip; selectedVideoVolumeID = nil
                        if clip != nil { selectedEditID = nil; selectedAnimationID = nil; selectedRegionID = nil }
                    },
                    begin: {
                        assistant.cancel(); playback.pause()
                        if videoFramingClipID != selectedVideoClipID || videoFramingTime != videoEditingTime {
                            guard editor.finishDraft() else { return false }
                        }
                        videoFramingClipID = selectedVideoClipID; videoFramingTime = videoEditingTime
                        videoGestureState = state; return true
                    },
                    preview: { layer, clip in
                        guard videoGestureState != nil else { return }
                        let next = VideoClipEditing.replacing(clip, layerID: layer, in: state, project: editor.project)
                        _ = editor.updateDraft(next, at: videoEditingTime)
                    }, commit: { videoGestureState = nil }, cancel: {
                        if let before = videoGestureState, before != editor.project.state { _ = editor.updateDraft(before, at: videoEditingTime) }
                        else { _ = editor.cancelDraft() }
                        videoGestureState = nil
                    })
                .allowsHitTesting(selectedInspector == .videos && !(directorMode && previewTool == .box) && !playback.isPlaying && !hasAmbiguousFramingTarget && conflictReview == nil)
            }
            .overlay(alignment: .topTrailing) { previewTools.padding(10) }
            .overlay(alignment: .bottomLeading) {
                if MediaProcessing.isSuspended {
                    Text("Test pattern").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.black.opacity(0.65), in: Capsule()).padding(10)
                        .allowsHitTesting(false)
                }
            }
            .overlay { if playback.isLoading { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
            .overlay {
                if playback.errorMessage != nil {
                    MissingMediaRecoveryView(editor: editor) {
                        editor.mediaRestored()
                        Task { await automation.rebuildPreview() }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let selectedEdit {
                    Text(editLabel(selectedEdit)).font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(10).allowsHitTesting(false)
                }
            }
    }

    private var previewTools: some View {
        Picker("Preview tool", selection: Binding(get: { directorMode ? previewTool : .pan }, set: { setPreviewTool($0) })) {
            Label("Pan & zoom", systemImage: "hand.raised")
                .help("Drag to change the video framing. Pinch or double-click to zoom; two fingers pan. These are reversible edits.")
                .tag(PreviewTool.pan)
            Label("Draw box", systemImage: "rectangle.dashed")
                .help("Drag a reference box with the video's aspect ratio. Opens Director if needed.")
                .tag(PreviewTool.box)
                .disabled(isBlendedCanvas)
        }
        .pickerStyle(.segmented).labelsHidden().labelStyle(.titleAndIcon).controlSize(.small)
        .frame(width: 230, height: 24)
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .disabled(playback.isLoading || playback.isScrubbing || conflictReview != nil || selectedInspector == .videos || hasAmbiguousFramingTarget)
        .accessibilityLabel("Preview tool")
        .help(selectedInspector == .videos ? "Drag the selected clip or its corners to move and resize it. Reference boxes target the screen recording; choose Main video to draw one." : "Pan & zoom edits the screen framing. Draw box marks a reference for Director. Each completed gesture can be undone.")
    }

    private func setPreviewTool(_ tool: PreviewTool) {
        guard !playback.isLoading, !playback.isScrubbing, conflictReview == nil else { return }
        if playback.isPlaying { selectedEditID = nil; selectedAnimationID = nil }
        playback.pause()
        if tool == .box, !directorMode {
            guard editor.finishDraft() else { return }
            directorMode = true
        }
        previewTool = tool
    }

    private func reviewConflict() {
        playback.pause()
        guard let review = conflictReview else {
            if comparisonDismissedForManualEdit { comparisonDismissedForManualEdit = false; return }
            if let draft = editor.draftState { playback.preview(draft) }
            else { playback.cancelPreview() }
            return
        }
        directorMode = true
        guard !playback.isLoading else { return }
        selectedEditID = nil; selectedAnimationID = nil; selectedRegionID = nil
        playback.seekProjectTime(review.inspectionTime)
        playback.preview(review.previewState)
    }

    private func leaveConflictForManualEdit() {
        guard conflictReview != nil else { return }
        comparisonDismissedForManualEdit = true
        assistant.cancel()
    }

    private func refreshConflictFrame() {
        guard let review = conflictReview else { return }
        playback.preview(review.previewState)
    }

    private func toggleDirectorMode() {
        if !directorMode {
            playback.pause()
            guard editor.finishDraft() else { return }
        }
        directorMode.toggle()
        previewTool = directorMode ? .box : .pan
    }

    private func addRegion(_ rect: EditorRegionRect) {
        let sourceTime = referenceFrameTime ?? playback.editingTime
        referenceFrameTime = nil
        guard editor.finishDraft() else { return }
        var next = editor.project.state
        let region = next.addRegion(rect: rect, at: sourceTime, includeCamera: editor.project.cameraFilename != nil)
        if editor.commit(next, name: "Draw box") {
            selectedRegionID = region.id
            selectedEditID = region.editID
            synchronizeAnimationSelection()
        }
    }

    private func selectRegion(_ id: UUID?) {
        selectedVideoClipID = nil; selectedVideoVolumeID = nil
        cutSelection = nil; selectedCutID = nil
        guard id == nil || state.regions.contains(where: { $0.id == id }) else { return }
        playback.pause()
        selectedRegionID = selectedRegionID == id ? nil : id
        directorMode = true
    }

    private func cancelEditorInteraction() {
        if cutSelection != nil || selectedCutID != nil { cutSelection = nil; selectedCutID = nil; return }
        if conflictReview != nil { assistant.cancel(); return }
        if let snapshot = canvasGesture { restoreCanvasGesture(snapshot); return }
        if videoGestureState != nil { videoGestureState = nil; _ = editor.cancelDraft(); return }
        if selectedVideoClipID != nil {
            if editor.draftState != nil { _ = editor.cancelDraft() }
            else { selectedVideoClipID = nil; selectedVideoVolumeID = nil }
            return
        }
        if animationGesture != nil { cancelAnimationGesture() }
        else if movingEditState != nil { cancelMove() }
        else if editor.draftState != nil || presentationDraft != nil { cancelDraft() }
        else if selectedContentLayerID != nil { selectedContentLayerID = nil }
        else if selectedRegionID != nil { selectedRegionID = nil }
        else if directorMode { directorMode = false }
        else { cancelDraft() }
    }

    private func showOriginalFrame(_ id: UUID) {
        guard editor.finishDraft(), let region = state.regions.first(where: { $0.id == id }) else { return }
        playback.pause()
        let associated = region.editID.flatMap {
            editor.references.edit(in: state, id: $0, includeCamera: editor.project.cameraFilename != nil)
        }
        selectedEditID = associated.flatMap { abs($0.time - region.time) < 0.000001 ? $0.id : nil }
        selectedRegionID = id; directorMode = true
        playback.seekProjectTime(region.time)
    }

    private func removeRegion(_ id: UUID) {
        guard editor.finishDraft() else { return }
        let next = EditorBoxConnections.removing(regionID: id, from: editor.project.state)
        if editor.commit(next, name: "Remove box"), selectedRegionID == id { selectedRegionID = nil }
    }

    private func deleteSelectedBox() {
        if let text = NSApplication.shared.keyWindow?.firstResponder as? NSTextView, text.isEditable { return }
        if selectedInspector == .layers, let selectedContentLayerID,
           state.contentLayers.contains(where: { $0.id == selectedContentLayerID }) {
            var next = state; next.contentLayers.removeAll { $0.id == selectedContentLayerID }
            if editor.commit(next, name: "Remove layer") { self.selectedContentLayerID = nil }
            return
        }
        guard directorMode, let selectedRegionID, state.regions.contains(where: { $0.id == selectedRegionID }) else { return }
        removeRegion(selectedRegionID)
    }

    private var timeline: some View {
        VStack(spacing: 8) {
            EditorControlFlow(spacing: 10) {
                Button { togglePlayback() } label: {
                    Image(systemName: playback.isPlaying || automation.isPlaybackPending ? "pause.fill" : "play.fill").frame(width: 22, height: 18)
                }
                .accessibilityLabel(playback.isPlaying || automation.isPlaybackPending ? "Pause" : "Play")
                .keyboardShortcut(.space, modifiers: [])
                .disabled((!playback.canPlay && !automation.isPlaybackPending) || (conflictReview != nil && !MediaProcessing.isSuspended))
                .help(conflictReview != nil
                    ? (MediaProcessing.isSuspended ? "Play or pause the Existing and Proposed outlines over the test pattern." : "Scrub the highlighted timeline spans to compare the pending framings.")
                    : (MediaProcessing.isSuspended ? "Play or pause edits over a drawn test pattern. Video processing stays disabled." : "Play or pause the recording."))
                Picker("Review speed", selection: Binding(get: { playback.playbackRate }, set: { _ = playback.setPlaybackRate($0); automation.recordEvent("preview_rate") })) {
                    ForEach(EditorPlayback.supportedPlaybackRates, id: \.self) { rate in
                        Text(rate == 0.5 ? "0.5×" : "\(Int(rate))×").tag(rate)
                    }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .frame(width: 170)
                .accessibilityLabel("Review speed")
                .help("Review playback multiplier. Export speed is edited separately in Speed; this control adds no saved edit.")
                Menu {
                    Button("Mark section start at playhead") {
                        playback.pause(); cutRangeStart = playback.outputTime; cutSelection = nil
                    }
                    Button("Mark section end at playhead") {
                        playback.pause()
                        if let start = cutRangeStart, abs(start - playback.outputTime) > frameDuration / 2 {
                            cutSelection = min(start, playback.outputTime)...max(start, playback.outputTime)
                        }
                    }.disabled(cutRangeStart == nil)
                    Button("Cut selected section") { cutSelectedSection(); cutRangeStart = nil }
                        .disabled(cutSelection == nil || playback.isLoading)
                    Button("Clear section selection") { cutSelection = nil; cutRangeStart = nil }
                        .disabled(cutSelection == nil && cutRangeStart == nil)
                    Divider()
                    Button("Trim start to playhead") { setTrim(playback.editingTime, state.trimEnd) }
                        .disabled(hasAmbiguousFramingTarget || playback.editingTime >= state.trimEnd - frameDuration)
                    Button("Trim end to playhead") { setTrim(state.trimStart, playback.editingTime) }
                        .disabled(hasAmbiguousFramingTarget || playback.editingTime <= state.trimStart + frameDuration)
                    Button("Reset trim") { setTrim(0, editor.project.duration) }
                        .disabled(state.trimStart == 0 && state.trimEnd == editor.project.duration)
                } label: { Image(systemName: "scissors") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Cut and trim")
                .help("Mark a section's start and end, or Shift-drag the ruler to select it. Cuts and trims preserve the original footage.")
                Spacer(minLength: 0)
                Text("\(timelinePosition, specifier: "%.2f") / \(timelineDuration, specifier: "%.2f") s")
                    .monospacedDigit().font(.caption).frame(width: 130, alignment: .trailing)
            }
            ScrollView(.vertical) {
            RecordingTimeline(duration: timelineDuration, trimStart: state.trimStart,
                trimEnd: state.trimEnd, playhead: timelinePosition,
                onInteractionBegan: { playback.pause() },
                onSeek: { if editor.draftState == nil { if isSourceTimeline { playback.scrubSource(to: $0) } else { playback.scrubOutput(to: $0) } } },
                onScrubBegan: {
                    guard editor.finishDraft() else { return }
                    selectedCutID = nil
                    selectedEditID = nil
                    selectedAnimationID = nil
                    playback.beginScrubbing()
                },
                onScrubEnded: { playback.endScrubbing() },
                onTrim: { start, end in setTrim(start, end) },
                onTrimPlayhead: { position in selectedEditID = nil; selectedAnimationID = nil; playback.seekProjectTime(position) },
                edits: isSourceTimeline ? edits.map { timelineMarker($0) } : [],
                selectedEditID: selectedEditID,
                onSelectEdit: { selectEdit($0) },
                frameDuration: frameDuration,
                onMoveEdit: { id, time, final in moveEdit(id, to: time, final: final) },
                onCancelMoveEdit: { cancelMove() },
                onDeselectEdit: { deselectEdit() },
                onCancelEdit: { cancelDraft() }, fitRequest: timelineFitRequest,
                conflictSpans: timelineConflicts,
                conflictOverlaps: timelineConflictOverlaps,
                showsAnimationLanes: true,
                pointerClickTimes: (playback.cursorRecording?.clicks.map(\.time) ?? []).compactMap { isSourceTimeline ? $0 : timelineMap?.outputTime(for: $0) },
                animations: displayedAnimations, selectedAnimationID: displayedAnimationID,
                onSelectAnimation: { displayed in
                    let original = outputProjection?.sourceIDs[displayed] ?? displayed
                    selectAnimation(original)
                    selectedAnimationDisplayID = displayed
                    let anchor = outputProjection?.editableBindings[displayed]?.visibleSourceStart ?? selectedAnimationTime
                    playback.selectEditingBranch(nearProjectTime: anchor)
                },
                onAnimationEdit: { editAnimation($0, final: $1) },
                animationDragProjection: !isSourceTimeline && outputProjection != nil ? { request in
                    projectFinishedAnimation(request)
                } : nil,
                onAnimationCancel: { cancelAnimationGesture() },
                onDeleteAnimation: { id in
                    if timelineIsIdentity || outputProjection?.editableBindings[id] != nil { deleteAnimation(outputProjection?.sourceIDs[id] ?? id) }
                },
                showsClipLane: showsCutLane, showsCameraOpacityLane: editor.project.cameraFilename != nil,
                sourceTrimDuration: isSourceTimeline ? nil : editor.project.duration,
                allowsSeekingOutsideTrim: isSourceTimeline, clockID: timelineTimeBase.rawValue,
                clipBands: timelineClipBands, cutMarkers: timelineCutMarkers,
                selectedCutID: selectedCutID, selectedRange: cutSelection,
                onRangeSelection: { range in
                    cutSelection = range; selectedCutID = nil
                    if let range { cutRangeStart = range.lowerBound }
                    if range != nil { clearEditingSelectionForCut() }
                },
                onSelectCut: { id in
                    clearEditingSelectionForCut()
                    cutSelection = nil; selectedCutID = id
                    let requested = state.cuts.first(where: { $0.id == id })?.crossfade ?? 0
                    cutDuration = requested > 0 ? requested : 0.5
                }, onCutRange: { cutSelectedSection() },
                onRestoreCut: { applyCutMutation(.restoreCut(cutID: $0), name: "Restore section") },
                onCutAnchor: { cutPopoverAnchor = $0 }, sourceEnvelopes: outputProjection?.envelopes ?? [:], speedCurves: speedCurves,
                videoRows: videoTimelineRows,
                rowLayout: timelineRowLayout, pinnedAnimationLanes: pinnedAnimationLanes,
                expandedVideoVolumeLayerIDs: expandedVideoVolumeLayerIDs,
                hasPointerRecording: playback.cursorRecording != nil, recordedAudioRoles: Set(editor.project.audioSources.map(\.role)),
                onToggleVideoVolume: { layer in
                    if !expandedVideoVolumeLayerIDs.insert(layer).inserted { expandedVideoVolumeLayerIDs.remove(layer) }
                },
                selectedVideoClipID: selectedVideoClipID, selectedVideoVolumeID: selectedVideoVolumeID,
                onSelectVideo: { layer, clip, point in
                    guard editor.finishDraft() else { return }
                    selectedVideoLayerID = layer; selectedVideoClipID = clip; selectedVideoVolumeID = point
                    selectedAnimationID = nil; selectedEditID = nil; selectedContentLayerID = nil; selectedCutID = nil; cutSelection = nil
                    if let clip = editor.project.effectiveVideoLayers(in: state).flatMap(\.clips).first(where: { $0.id == clip }) {
                        selectedInspector = point != nil ? .videos : clip.layout == .screen ? .zoom : clip.layout == .camera ? .camera : .videos
                    }
                }, onVideoEdit: { request, final in editVideo(request, final: final) },
                onVideoCancel: { videoGestureState = nil; _ = editor.cancelDraft() },
                onDeleteVideo: { layer, clip, point in deleteVideo(layer: layer, clip: clip, point: point) })
                .frame(height: videoTimelineHeight)
                // SwiftUI positions its scroll document independently of the
                // native ruler. Reserve its strip so it cannot cover controls.
                .padding(.top, 20)
                .popover(isPresented: Binding(get: { selectedCutID != nil }, set: { if !$0 { selectedCutID = nil } }),
                    attachmentAnchor: .point(cutPopoverAnchor)) { cutControls }
                .contextMenu {
                    Button("Hold current framing") { holdCurrentFraming() }
                        .disabled(isBlendedCanvas)
                        .help("Keep this view still until the playhead before a later smooth movement.")
                    Divider()
                    Button("Fit Timeline") { timelineFitRequest = UUID() }
                    Button("Reset trim") { setTrim(0, editor.project.duration) }
                        .disabled(state.trimStart == 0 && state.trimEnd == editor.project.duration)
                    if !state.cuts.isEmpty {
                        Menu("Restore section") {
                            ForEach(state.cuts) { cut in
                                Button(String(format: "Source %.3f–%.3f s", cut.start, cut.end)) { applyCutMutation(.restoreCut(cutID: cut.id), name: "Restore section") }
                            }
                        }
                    }
                }
            }.frame(maxHeight: .infinity)
        }
    }

    private var showsCutLane: Bool { !state.cuts.isEmpty || cutSelection != nil || cutRangeStart != nil || conflictReview != nil }
    private var pinnedAnimationLanes: Set<TimelineAnimationLane> {
        var result: Set<TimelineAnimationLane> = []
        if let gesture = animationGesture { result.insert(gesture.originalID.lane) }
        if let gesture = canvasGesture { result.insert(gesture.lane) }
        return result
    }
    private var timelineRowLayout: TimelineTrackLayout {
        let stable = videoGestureState ?? animationGesture?.state ?? editor.project.state
        let rows = TimelineVideoRow.make(project: editor.project, state: stable, map: timelineMap)
        let sourceAnimations = animationGesture?.spans ?? EditorAnimationEditing.animations(in: stable, references: editor.references,
            duration: editor.project.duration, includeCamera: editor.project.cameraFilename != nil)
        let visibleAnimations = timelineMap.map { TimelineOutputProjection(animations: sourceAnimations, map: $0).animations } ?? sourceAnimations
        return TimelineTrackLayout.make(videoRows: rows,
            animations: visibleAnimations,
            selectedAnimationID: selectedAnimationID, pinnedAnimationLanes: pinnedAnimationLanes,
            expandedVideoVolumeLayerIDs: expandedVideoVolumeLayerIDs, selectedVideoVolumeID: selectedVideoVolumeID,
            conflictSpans: timelineConflicts, pointerClickTimes: playback.cursorRecording?.clicks.map(\.time) ?? [],
            hasPointerRecording: playback.cursorRecording != nil, recordedAudioRoles: Set(editor.project.audioSources.map(\.role)), showsClipLane: showsCutLane)
    }
    private var videoTimelineHeight: CGFloat { timelineRowLayout.contentHeight }

    private var videoTimelineRows: [TimelineVideoRow] {
        TimelineVideoRow.make(project: editor.project, state: state, map: isSourceTimeline ? nil : timelineMap)
    }

    private func editVideo(_ request: TimelineVideoEdit, final: Bool) {
        assistant.cancel(); playback.pause()
        if videoGestureState == nil {
            guard editor.finishDraft() else { return }
            videoGestureState = editor.editingState
        }
        guard let base = videoGestureState,
              let original = editor.project.effectiveVideoLayers(in: base).first(where: { $0.id == request.layerID })?.clips.first(where: { $0.id == request.clipID }) else { return }
        let source = editor.project.videoSources.first { $0.id == original.sourceID }
        var clip = original
        switch request.handle {
        case .move:
            let length = original.end - original.start
            clip.start = min(max(0, request.projectTime), editor.project.duration - length)
            clip.end = clip.start + length
        case .start:
            let earliest = max(0, original.start - original.sourceStart / original.rate)
            clip.start = min(max(earliest, request.projectTime), original.end - min(0.01, (original.end - original.start) / 2))
            clip.sourceStart = max(0, original.sourceStart + (clip.start - original.start) * original.rate)
        case .end:
            let latest = min(editor.project.duration, original.start + ((source?.duration ?? .greatestFiniteMagnitude) - original.sourceStart) / original.rate)
            clip.end = min(latest, max(original.start + min(0.01, (original.end - original.start) / 2), request.projectTime))
        case .volume(let id):
            let time = min(original.sourceEnd.nextDown, max(original.sourceStart, original.sourceTime(at: request.projectTime)))
            var point = original.volumeKeyframes.first { $0.id == id }
                ?? original.volumeKeyframes.first { abs($0.time - time) < 0.000001 && !original.volumeKeyframes.contains(where: { $0.id == id }) }
                ?? VideoVolumeKeyframe(id: id, time: time, gain: request.gain, transition: time == 0 ? .jump : .smooth)
            point.time = time; point.gain = request.gain
            clip.volumeKeyframes.removeAll { $0.id == point.id }
            clip.volumeKeyframes.append(point); clip.volumeKeyframes.sort { $0.time < $1.time }
            selectedVideoVolumeID = point.id
        }
        let next = VideoClipEditing.replacing(clip, layerID: request.layerID, in: base, project: editor.project)
        var check = editor.project; check.state = next
        if (try? check.validate()) == nil {
            // Stop at the last valid preview rather than saving an overlap or
            // discarding an entire valid drag when its final event is blocked.
            if final { _ = editor.finishDraft(name: "Adjust video clip"); videoGestureState = nil }
            return
        }
        if final {
            if editor.draftState != nil { _ = editor.updateDraft(next, at: playback.editingTime); _ = editor.finishDraft(name: "Adjust video clip") }
            else { _ = editor.commit(next, name: "Adjust video clip") }
            videoGestureState = nil
        } else { _ = editor.updateDraft(next, at: playback.editingTime) }
    }

    private func deleteVideo(layer: UUID, clip: UUID, point: UUID?) {
        playback.pause(); assistant.cancel(); videoGestureState = nil
        guard editor.finishDraft() else { return }
        let mutation: EditorMutation = point.map { .removeVideoAnimation(layerID: layer, clipID: clip, property: .volume, pointID: $0) }
            ?? .removeVideoClip(layerID: layer, clipID: clip)
        var next = editor.editingState
        do {
            try mutation.apply(to: &next, project: editor.project)
            if editor.commit(next, name: point == nil ? "Remove video clip" : "Remove clip volume change") {
                if point == nil { selectedVideoClipID = nil }
                selectedVideoVolumeID = nil
            }
        } catch { timelineError = error.localizedDescription }
    }

    @ViewBuilder
    private var cutControls: some View {
        if let id = selectedCutID, let cut = state.cuts.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(format: "Removed source %.3f–%.3f s", cut.start, cut.end)).font(.caption).monospacedDigit()
                Picker("Join", selection: Binding(get: { cut.crossfade > 0 }, set: { fade in
                    applyCutMutation(.cutTransition(cutID: id, duration: fade ? (cutDuration > 0 ? cutDuration : 0.5) : 0), name: "Change transition")
                })) {
                    Text("Cut").tag(false); Text("Crossfade").tag(true)
                }.pickerStyle(.segmented)
                if cut.crossfade > 0 {
                    Slider(value: $cutDuration, in: 0...max(1, editor.project.duration, cut.crossfade), onEditingChanged: { editing in
                        if !editing { setCutDuration(id) }
                    }).accessibilityLabel("Crossfade duration")
                    HStack {
                        Text("Duration")
                        TextField("Seconds", value: $cutDuration, format: .number.precision(.fractionLength(0...3)))
                            .frame(width: 80).onSubmit { setCutDuration(id) }
                            .help("Press Return to apply. Dismiss to cancel the typed value.")
                        Text("s")
                    }
                    if let join = timelineMap?.joins.first(where: { $0.id == id }) {
                        if join.duration + 0.000001 < cut.crossfade {
                            Text(String(format: "Only %.3f s fits in the adjacent sections.", join.duration)).font(.caption).monospacedDigit()
                                .help("The requested duration is retained when trims change.")
                        }
                    } else { Text("A crossfade needs kept footage on both sides.").font(.caption).foregroundStyle(.secondary) }
                }
                Button("Restore section") { applyCutMutation(.restoreCut(cutID: id), name: "Restore section") }
            }.padding(16).frame(width: 310)
        }
    }

    private func clearEditingSelectionForCut() {
        selectedEditID = nil; selectedAnimationID = nil; selectedRegionID = nil
    }

    private func setCutDuration(_ id: UUID) {
        guard cutDuration.isFinite, cutDuration >= 0 else { timelineError = "Enter a finite transition duration of zero or more seconds."; return }
        applyCutMutation(.cutTransition(cutID: id, duration: cutDuration), name: "Change transition")
    }

    private func cutSelectedSection() {
        guard let range = cutSelection, range.lowerBound < range.upperBound else { return }
        applyCutMutation(.cutSection(start: range.lowerBound, end: range.upperBound, timeBase: timelineTimeBase), name: "Cut section")
    }

    private func applyCutMutation(_ mutation: EditorMutation, name: String) {
        playback.pause(); assistant.cancel()
        guard editor.finishDraft() else { return }
        var edited = state
        do {
            try mutation.apply(to: &edited, project: editor.project)
            guard editor.commit(edited, name: name) else { return }
            timelineError = nil; cutSelection = nil
            if let selectedCutID, !edited.cuts.contains(where: { $0.id == selectedCutID }) { self.selectedCutID = nil }

        } catch { timelineError = error.localizedDescription }
    }

    private func setTrim(_ start: Double, _ end: Double) {
        playback.pause()
        guard editor.finishDraft() else { return }
        selectedEditID = nil
        var edited = state
        edited.trimStart = start
        edited.trimEnd = end
        if editor.commit(edited, name: "Trim") {
            let position = min(max(playback.time, start), end)
            if position != playback.time { playback.seekProjectTime(position) }
        }
    }

    private func inspectorTitle(_ value: EditorInspector) -> String {
        switch value {
        case .zoom: return "Main video"
        case .pointer: return "Mouse pointer"
        case .camera: return "PIP camera"
        case .speed: return "Playback speed"
        case .canvas: return "Project canvas"
        case .audio: return "Audio mix"
        case .videos:
            if let layer = editor.project.effectiveVideoLayers(in: state).first(where: { $0.id == selectedVideoLayerID }) { return layer.name }
            return "Video clips"
        case .layers: return "Graphics & text"
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Properties", selection: $selectedInspector) {
                        ForEach(EditorInspector.allCases.filter { $0 != .camera || editor.project.cameraFilename != nil }, id: \.self) { target in
                            Text(inspectorTitle(target)).tag(target)
                        }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .accessibilityIdentifier("editor-property-target")
                    .help("Choose an object to edit. Selecting a clip or animation in the timeline also shows its properties here.")
                    if originalSourceURL != nil {
                        Button { playback.pause(); originalPreviewURL = originalSourceURL } label: { Image(systemName: "eye") }
                            .buttonStyle(.borderless).accessibilityLabel("Preview original clip")
                            .help("Quick Look the selected original clip without changing the project timeline or its playhead.")
                    }
                }
                if isBlendedCanvas {
                    Picker("Edit crossfade side", selection: Binding(get: { playback.selectedProjectBranch }, set: { branch in
                        playback.selectEditingBranch(nearProjectTime: branch.flatMap { wanted in playback.outputSamples.first { $0.clipIndex == wanted }?.sourceTime })
                    })) {
                        Text("Choose crossfade side…").tag(Optional<Int>.none)
                        ForEach(Array(playback.outputSamples.enumerated()), id: \.element.clipIndex) { index, sample in
                            Text(index == 0 ? "Outgoing clip" : "Incoming clip").tag(Optional(sample.clipIndex))
                        }
                    }
                    .help("Choose which side of this crossfade receives the edit. The project playhead stays in place.")
                }
                if let selectedEdit {
                    HStack {
                        Text(editLabel(selectedEdit)).fontWeight(.medium)
                        Spacer()
                        Text("\(playback.outputPosition(forProjectTime: selectedEdit.time), specifier: "%.2f") s").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                }
            ScrollViewReader { scroll in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                switch selectedInspector {
                case .zoom:
                    zoomControls.disabled(hasAmbiguousFramingTarget)
                        .help(hasAmbiguousFramingTarget ? "Choose the outgoing or incoming clip above before editing this crossfade." : "Adjust screen framing.")
                case .pointer: pointerControls
                case .camera:
                    cameraControls.disabled(hasAmbiguousFramingTarget)
                        .help(hasAmbiguousFramingTarget ? "Choose the outgoing or incoming clip above before editing this crossfade." : "Adjust the camera overlay.")
                    if hasRecordedMicrophone {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            microphoneControls
                            if selectedAnimationID?.lane == .audioMicrophone { audioEnvelopeControls }
                        }.id("microphone-properties")
                    }
                case .audio: audioControls
                case .speed: speedControls
                case .videos:
                    VideoLayersInspector(editor: editor, sourceTime: videoEditingTime, layerID: $selectedVideoLayerID, clipID: $selectedVideoClipID, volumeID: $selectedVideoVolumeID,
                        prepare: { assistant.cancel(); leaveConflictForManualEdit(); playback.pause() })
                case .layers:
                    ContentLayersInspector(editor: editor, sourceTime: playback.time, selection: $selectedContentLayerID,
                        prepare: { assistant.cancel(); leaveConflictForManualEdit(); playback.pause() }, seek: { playback.seekProjectTime($0) })
                case .canvas:
                    Button("Crop main video…") { openMainCrop() }
                        .help("Draw the main video crop and use it as the output frame for the whole recording.")
                    PresentationControls(presentation: canvasPresentation,
                        onBegin: {
                            leaveConflictForManualEdit()
                            playback.pause()
                            if editor.finishDraft() { selectedEditID = nil }
                        }, onPreview: { value in
                            guard editor.draftState == nil else { return }
                            presentationDraft = value
                            var next = state; next.presentation = value
                            playback.preview(next)
                        }, onCommit: { value, name in
                            guard editor.finishDraft() else { return }
                            var next = editor.project.state; next.presentation = value
                            if editor.commit(next, name: name) { presentationDraft = nil }
                        })
                }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id("properties-top")
            }
            .task(id: propertyScrollRequest) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                scroll.scrollTo(selectedInspector == .camera && selectedAnimationID?.lane == .audioMicrophone
                    ? "microphone-properties" : "properties-top", anchor: .top)
            }
            }
        }
        .controlSize(.small)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("editor-properties")
        .quickLookPreview($originalPreviewURL)
    }

    private var originalSourceURL: URL? {
        guard !MediaProcessing.isSuspended else { return nil }
        let id: UUID
        if selectedInspector == .camera { id = VideoSource.legacyCameraID }
        else if selectedInspector == .videos,
                let clip = editor.project.effectiveVideoLayers(in: state).flatMap(\.clips).first(where: { $0.id == selectedVideoClipID }) { id = clip.sourceID }
        else if selectedInspector == .zoom || selectedInspector == .pointer || selectedInspector == .speed { id = VideoSource.legacyScreenID }
        else { return nil }
        guard let source = editor.project.videoSources.first(where: { $0.id == id }), source.kind != .testPattern,
              let url = try? source.resolvedURL(in: editor.url.deletingLastPathComponent()),
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    private var originalTimingHelp: String {
        "Seconds in the original recording, before cuts and saved speed changes. Drag the timeline handles to adjust timing on the project ruler."
    }

    private var speedControls: some View {
        let point = speedPoint
        let mode = point?.transition ?? speedTransition
        let duration = point?.duration ?? speedDuration
        let previous = state.speedKeyframes.last { $0.time < editTime }?.time ?? 0
        let span = max(0, min(duration, editTime - previous))
        let ramps = MotionInterpolation.rampDurations(duration: span, easeIn: point?.easeIn, easeOut: point?.easeOut)
        return VStack(alignment: .leading, spacing: 8) {
            EditorControlFlow(spacing: 12) {
                CommitSlider(title: "Export speed", value: state.speed(at: editTime), range: RecordingRetime.supportedRates,
                    valueSuffix: "×", valueFormat: "%.2f", begin: {
                        leaveConflictForManualEdit(); assistant.cancel(); playback.pause()
                        dragTime = targetTime(editTime); inspectEditingTarget(at: dragTime)
                    }, preview: { setSpeed($0, at: dragTime) }, commit: { setSpeed($0, at: dragTime) })
                    .frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true)
                    .help("Change saved playback speed at this source mark. The target rate continues until the next speed change. Preview speed only changes review playback.")
                Button { setSpeed(1, at: editTime) } label: { Image(systemName: "arrow.counterclockwise") }
                    .accessibilityLabel("Restore 1× export speed")
                    .help("Set normal export speed at this source mark.")
                Toggle("Preserve audio pitch", isOn: Binding(get: { state.preservesAudioPitch }, set: { value in
                    playback.pause(); assistant.cancel()
                    guard editor.finishDraft() else { return }
                    var next = editor.project.state; next.preservesAudioPitch = value
                    _ = editor.commit(next, name: "Change audio pitch policy")
                }))
                    .help("Keep voices at their original pitch while exported speed changes.")
                Spacer(minLength: 0)
            }
            EditorControlFlow(spacing: 12) {
                Picker("Rate change", selection: Binding(get: { mode }, set: { value in
                    speedTransition = value; updateSpeedPoint { $0.transition = value }
                })) { Text("Jump").tag(PIPTransition.jump); Text("Smooth").tag(PIPTransition.smooth) }
                    .frame(width: 185)
                    .help("Jump changes rate instantly. Smooth ramps to the selected rate, which then continues.")
                if mode == .smooth {
                    HStack(spacing: 6) {
                    Text(timelineIsIdentity ? "Duration" : "Duration (original)").font(.caption)
                    MotionDurationField(value: duration, maximum: max(editor.project.duration, duration), change: { value in
                        speedDuration = value; updateSpeedPoint { $0.duration = value }
                    }, cancel: { cancelDraft() }).frame(width: 64, height: 24)
                        .help(originalTimingHelp)
                    Text("s").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if point != nil && mode == .smooth && span > 0 {
                    MotionRampStrip(duration: span, easeIn: ramps.easeIn, easeOut: ramps.easeOut,
                    timeUnits: timelineIsIdentity ? "seconds" : "original-recording seconds", change: { incoming, value in
                        updateSpeedPoint { if incoming { $0.easeIn = value } else { $0.easeOut = value } }
                    }).frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true).frame(height: 32)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func setSpeed(_ rate: Double, at position: Double) {
        guard rate.isFinite, RecordingRetime.supportedRates.contains(rate) else { return }
        playback.pause()
        let time = selectedAnimationID?.lane == .speed ? (selectedAnimationTime ?? targetTime(position)) : targetTime(position)
        var next = state
        let existing = next.speedKeyframes.first { abs($0.time - time) < 0.000001 }
        guard existing?.rate != rate, existing != nil || rate != state.speed(at: time) else { return }
        let group = edits.first { abs($0.time - time) < 0.000001 }
        let point = RecordingSpeedKeyframe(id: existing?.id ?? group?.id ?? UUID(), time: time, rate: rate,
            transition: time == 0 ? .jump : existing?.transition ?? speedTransition,
            duration: existing?.duration ?? speedDuration, easeIn: existing?.easeIn, easeOut: existing?.easeOut)
        next.speedKeyframes.removeAll { abs($0.time - time) < 0.000001 }
        next.speedKeyframes.append(point); next.speedKeyframes.sort { $0.time < $1.time }
        inspectEditingTarget(at: time)
        if editor.updateDraft(next, at: time) {
            selectedEditID = next.timedEdits(includeCamera: editor.project.cameraFilename != nil).first { $0.speedID == point.id }?.id
            selectedAnimationID = TimelineAnimationID(lane: .speed, componentID: point.id)
        }
    }

    private func updateSpeedPoint(_ change: (inout RecordingSpeedKeyframe) -> Void) {
        guard var point = speedPoint else { return }
        playback.pause(); change(&point)
        var next = state
        if let index = next.speedKeyframes.firstIndex(where: { $0.id == point.id }) { next.speedKeyframes[index] = point }
        if next != state { inspectEditingTarget(at: point.time) }
        _ = editor.updateDraft(next, at: point.time)
    }

    private var audioControls: some View {
        let fades = state.audio.effectiveFades(duration: timelineMap?.outputDuration ?? (state.trimEnd - state.trimStart))
        return VStack(alignment: .leading, spacing: 8) {
            EditorControlFlow(spacing: 12) {
                Toggle("Mute", isOn: Binding(get: { state.audio.isMuted }, set: { muted in
                    commitAudio(name: muted ? "Mute recording" : "Unmute recording") { $0.isMuted = muted }
                }))
                    .toggleStyle(.checkbox)
                    .help("Mute all recorded audio. The original tracks and volume setting are preserved.")
                CommitSlider(title: "Master volume", value: state.audio.volume * 100, range: 0...100, valueSuffix: "%", valueFormat: "%.0f",
                    begin: beginAudioGesture,
                    preview: { value in previewAudio { $0.volume = value / 100 } }) { value in
                        finishAudioGesture(name: "Change recording volume") { $0.volume = value / 100 }
                    }
                    .frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true)
                    .help("Adjust every recorded audio track together, keeping their relative levels.")
                Button("Reset audio") { commitAudio(name: "Reset recording audio") { $0 = RecordingAudio(channels: editor.project.audioSources.map { .init(role: $0.role) }) } }
                    .disabled(state.audio == RecordingAudio(channels: editor.project.audioSources.map { .init(role: $0.role) }))
                    .help("Restore master and track levels, unmute, and remove fades and timed volume changes.")
                Spacer(minLength: 0)
            }
            EditorControlFlow(spacing: 16) {
                CommitSlider(title: "Fade in", value: state.audio.fadeIn, range: 0...RecordingAudio.maximumFade,
                    valueSuffix: " s", begin: beginAudioGesture,
                    preview: { value in previewAudio { $0.fadeIn = value } }) { value in
                        finishAudioGesture(name: "Change audio fade in") { $0.fadeIn = value }
                    }
                    .frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true)
                    .help("Fade from silence at the kept trim start. Fades shorten together when the kept recording is shorter than their combined duration.")
                CommitSlider(title: "Fade out", value: state.audio.fadeOut, range: 0...RecordingAudio.maximumFade,
                    valueSuffix: " s", begin: beginAudioGesture,
                    preview: { value in previewAudio { $0.fadeOut = value } }) { value in
                        finishAudioGesture(name: "Change audio fade out") { $0.fadeOut = value }
                    }
                    .frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true)
                    .help("Fade to silence at the kept trim end. Restoring a longer trim restores the requested fade lengths.")
                Spacer(minLength: 0)
            }
            if !editor.project.audioSources.isEmpty { audioTrackControls; audioEnvelopeControls }
            else if abs(fades.fadeIn - state.audio.fadeIn) < 0.000001 && abs(fades.fadeOut - state.audio.fadeOut) < 0.000001 { Text("Combined or unidentified audio").font(.caption).foregroundStyle(.secondary)
                .help("The recording has no explicit microphone/system track identities. Master controls apply to all original tracks.") }
            if abs(fades.fadeIn - state.audio.fadeIn) > 0.000001 || abs(fades.fadeOut - state.audio.fadeOut) > 0.000001 {
                Text("Fades in kept output: \(fades.fadeIn, specifier: "%.2f") s in, \(fades.fadeOut, specifier: "%.2f") s out")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var activeAudioRole: RecordingAudioRole {
        if selectedInspector == .camera && hasRecordedMicrophone { return .microphone }
        return editor.project.audioSources.contains(where: { $0.role == audioRole }) ? audioRole : editor.project.audioSources.first?.role ?? .microphone
    }
    private var selectedAudioPoint: RecordingAudioGainPoint? {
        guard let id = selectedAnimationID, id.lane.audioRole == activeAudioRole else { return nil }
        return state.audio.channel(activeAudioRole).points.first { $0.id == id.componentID }
    }
    private var audioTrackControls: some View {
        let role = activeAudioRole
        return EditorControlFlow(spacing: 12) {
            Picker("Track", selection: Binding(get: { role }, set: { value in
                guard editor.finishDraft() else { return }
                audioVolumeGesture = nil; audioRole = value; selectedAnimationID = nil; selectedEditID = nil
            })) {
                ForEach(editor.project.audioSources, id: \.role) { source in Text(source.role.title).tag(source.role) }
            }.frame(width: 190).help("Choose the recorded audio track to change. Other tracks are preserved.")
            Toggle("Mute track", isOn: Binding(get: { state.audio.channel(role).isMuted }, set: { muted in
                commitAudio(name: muted ? "Mute \(role.title)" : "Unmute \(role.title)") { audio in audio.updateChannel(role) { $0.isMuted = muted } }
            })).toggleStyle(.checkbox)
            CommitSlider(title: "Track level", value: state.audio.channel(role).volume * 100, range: 0...100,
                valueSuffix: "%", valueFormat: "%.0f", begin: beginAudioGesture,
                preview: { value in previewAudio { audio in audio.updateChannel(role) { $0.volume = value / 100 } } }) { value in
                    finishAudioGesture(name: "Change \(role.title) level") { audio in audio.updateChannel(role) { $0.volume = value / 100 } }
                }.frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true).help("Overall level for this track throughout the recording. Timed volume changes are applied after this level.")
            Spacer(minLength: 0)
        }
    }
    private var audioEnvelopeControls: some View {
        let role = activeAudioRole, point = selectedAudioPoint
        let mode = point?.transition ?? audioTransition
        let value = point?.gain ?? state.audio.channel(role).envelopeGain(at: playback.editingTime)
        return EditorControlFlow(spacing: 12) {
            CommitSlider(title: point == nil ? "Volume at playhead" : "Volume at selection", value: value * 100, range: 0...100,
                valueSuffix: "%", valueFormat: "%.0f", begin: beginAudioVolumeGesture,
                preview: { value in setAudioVolume(value / 100, final: false) }) { value in
                    setAudioVolume(value / 100, final: true)
                }.frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true)
                .help(point == nil ? "Changing this value creates or updates a volume change arriving at the source playhead. 100% leaves Track level unchanged."
                    : "Changes the selected volume mark without moving the playhead. 100% leaves Track level unchanged.")
                .disabled(isBlendedCanvas && point == nil)
            Picker("Fade", selection: Binding(get: { mode }, set: { value in
                audioTransition = value
                updateAudioTiming { $0.transition = value }
            })) { Text("Jump").tag(PIPTransition.jump); Text("Smooth").tag(PIPTransition.smooth) }
                .frame(width: 160).help("Jump changes volume at arrival. Smooth uses the duration and timeline ramps.")
            if mode == .smooth {
                HStack(spacing: 6) {
                    Text(timelineIsIdentity ? "Duration" : "Duration (original)").font(.caption)
                    MotionDurationField(value: point?.duration ?? audioDuration, maximum: max(editor.project.duration, point?.duration ?? audioDuration), change: { value in
                        audioDuration = value; updateAudioTiming { $0.duration = value }
                    }, cancel: { cancelDraft() }).frame(width: 64, height: 24).help(originalTimingHelp)
                    Text("s").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
    private func beginAudioVolumeGesture() {
        leaveConflictForManualEdit(); assistant.cancel(); playback.pause()
        guard editor.finishDraft() else { audioVolumeGesture = nil; return }
        let role = activeAudioRole, channel = editor.project.state.audio.channel(activeAudioRole)
        let selected = selectedAudioPoint
        let time = selected?.time ?? playback.editingTime
        let existing = selected ?? channel.points.first { abs($0.time - time) < 0.000001 }
        let point = existing ?? RecordingAudioGainPoint(time: time, gain: channel.envelopeGain(at: time),
            transition: time == 0 ? .jump : audioTransition, duration: audioDuration)
        audioVolumeGesture = AudioVolumeGesture(state: editor.project.state, role: role, point: point)
    }
    private func setAudioVolume(_ gain: Double, final: Bool) {
        guard let gesture = audioVolumeGesture else { return }
        if abs(gain - gesture.point.gain) < 0.000000001 {
            if editor.draftState != nil { _ = editor.cancelDraft() }
            if final { audioVolumeGesture = nil }
            return
        }
        var next = gesture.state, point = gesture.point
        point.gain = gain
        next.audio.updateChannel(gesture.role) { channel in
            channel.points.removeAll { $0.id == point.id }; channel.points.append(point); channel.points.sort { $0.time < $1.time }
        }
        guard editor.updateDraft(next, at: point.time) else { return }
        if final, editor.finishDraft(name: "Change \(gesture.role.title) timed volume") {
            selectedAnimationID = .init(lane: gesture.role.lane, componentID: point.id)
            audioVolumeGesture = nil
        }
    }
    private func updateAudioTiming(_ change: (inout RecordingAudioGainPoint) -> Void) {
        guard let selected = selectedAudioPoint else { return }
        assistant.cancel(); playback.pause()
        var next = state
        next.audio.updateChannel(activeAudioRole) { channel in
            if let index = channel.points.firstIndex(where: { $0.id == selected.id }) { change(&channel.points[index]) }
        }
        _ = editor.updateDraft(next, at: selected.time)
    }

    private func beginAudioGesture() {
        leaveConflictForManualEdit()
        assistant.cancel()
        playback.pause()
        audioGestureTime = editor.finishDraft() ? playback.editingTime : nil
    }

    private func previewAudio(_ change: (inout RecordingAudio) -> Void) {
        guard let time = audioGestureTime else { return }
        var next = state
        change(&next.audio)
        _ = editor.updateDraft(next, at: time)
    }

    private func finishAudioGesture(name: String, change: (inout RecordingAudio) -> Void) {
        guard audioGestureTime != nil else { return }
        previewAudio(change)
        _ = editor.finishDraft(name: name)
        audioGestureTime = nil
    }

    private func commitAudio(name: String, change: (inout RecordingAudio) -> Void) {
        assistant.cancel()
        playback.pause()
        guard editor.finishDraft() else { return }
        var next = editor.project.state
        change(&next.audio)
        _ = editor.commit(next, name: name)
    }

    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Crop main video…") { openMainCrop() }
                .help("Draw a source crop and use it as the output frame for the whole recording.")
            EditorControlFlow(spacing: 12) {
                CommitSlider(title: "Zoom", value: zoom.scale, range: 1...3, valueSuffix: "×", begin: { beginZoomGesture() }, preview: { value in
                    var next = zoom; next.scale = value
                    setZoom(next, at: dragTime, name: "Edit")
                }) { value in
                    var next = zoom; next.scale = value
                    setZoom(next, at: dragTime, name: "Zoom recording")
                    canvasGesture = nil
                }
                .frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true)
                .help("Change the magnification at the current video time. Pinch to zoom; use two fingers to pan. Double-click also zooms where you click.")
                Button("Full frame") { setZoom(ZoomPlacement(), at: editTime, name: "Zoom out") }
                    .help("Show the whole recording at this time, without zooming or panning.")
                Button("Center view") {
                    var next = zoom; next.x = 0.5; next.y = 0.5
                    setZoom(next, at: editTime, name: "Center zoom")
                }
                .help("Keep the current magnification and move the view to the center of the recording.")
                Menu("Zoom at clicks") {
                    ForEach([CursorZoomSuggestions.Preset.subtle, .focused], id: \.self) { preset in
                        Button(preset.title) { suggestZooms(preset) }
                            .disabled(playback.cursorRecording?.clicks.isEmpty != false)
                            .help("Replace existing zoom changes with editable views centered on recorded mouse clicks.")
                    }
                    Divider()
                    Button("Remove all zoom changes") {
                        playback.pause()
                        var next = state; next.zoomKeyframes = []
                        if editor.commit(next, name: "Remove zooms") { selectedEditID = nil }
                    }
                    .disabled(state.zoomKeyframes.isEmpty)
                    .help("Show the full recording throughout. Undo restores the removed zoom changes.")
                }
                .fixedSize()
                .help(playback.cursorRecording == nil ? "Zoom suggestions need a new recording with pointer tracking." : "Suggest editable zoom changes around recorded mouse clicks. Replaces existing changes; Undo restores them.")
                Spacer(minLength: 0)
            }
            transitionControls(camera: false)
        }
    }

    private func actionDescription(_ edit: TimedEdit) -> EditorActionDescription {
        EditorActionDescription.describe(edit, in: state, references: editor.references)
    }

    private func editLabel(_ edit: TimedEdit) -> String { actionDescription(edit).shortLabel }

    private func timelineMarker(_ edit: TimedEdit) -> RecordingTimelineMarker {
        let view = state.zoomKeyframes.first { $0.id == edit.zoomID }
        let camera = state.pipKeyframes.first { $0.id == edit.cameraID }
        let useCamera = selectedInspector == .camera && camera != nil || view == nil
        let duration = useCamera ? camera?.duration ?? 0.6 : view?.duration ?? 0.4
        let transition = useCamera ? camera?.transition : view?.transition
        let previous = useCamera ? state.pipKeyframes.last(where: { $0.time < edit.time })?.time ?? 0
                                 : state.zoomKeyframes.last(where: { $0.time < edit.time })?.time ?? 0
        let start = max(previous, edit.time - duration)
        let ramps = MotionInterpolation.rampDurations(duration: edit.time - start,
            easeIn: useCamera ? camera?.easeIn : view?.easeIn, easeOut: useCamera ? camera?.easeOut : view?.easeOut)
        return RecordingTimelineMarker(id: edit.id, time: edit.time,
            help: actionDescription(edit).tooltip + " Click to select; drag to move.",
            label: editLabel(edit),
            transitionStart: transition == .smooth ? start : nil, easeIn: ramps.easeIn, easeOut: ramps.easeOut,
            minimumTime: edit.cameraID == nil ? 0 : frameDuration,
            maximumTime: editor.project.editingTime(at: editor.project.duration, frameDuration: frameDuration))
    }

    private func selectEdit(_ id: UUID) {
        propertyScrollRequest = UUID()
        selectedVideoClipID = nil; selectedVideoVolumeID = nil
        cutSelection = nil; selectedCutID = nil
        if id == selectedEditID { playback.pause(); return }
        guard editor.finishDraft(), let edit = edits.first(where: { $0.id == id }) else { return }
        selectedEditID = id
        if edit.zoomID == nil && edit.cameraID == nil && edit.cameraOpacityID == nil && edit.speedID != nil { selectedInspector = .speed }
        else if edit.zoomID == nil && (edit.cameraID != nil || edit.cameraOpacityID != nil) { selectedInspector = .camera }
        else if edit.cameraID == nil { selectedInspector = .zoom }
        playback.pause()
        synchronizeAnimationSelection()
    }

    /// Conversation cards explicitly inspect an edit; lane clicks only select.
    private func inspectEdit(_ id: UUID) {
        selectEdit(id)
        guard selectedEditID == id, let selectedEdit else { return }
        playback.seekProjectTime(selectedEdit.time)
    }

    private func synchronizeAnimationSelection() {
        if selectedInspector == .camera, selectedAnimationID?.lane == .audioMicrophone { selectedEditID = nil; return }
        if selectedInspector == .audio {
            if let id = selectedAnimationID, let role = id.lane.audioRole,
               timelineAnimations.contains(where: { $0.id == id }) {
                audioRole = role
            } else { selectedAnimationID = nil }
            selectedEditID = nil
            return
        }
        if selectedInspector == .camera, let selectedAnimationID, selectedAnimationID.lane == .cameraOpacity,
           let selected = timelineAnimations.first(where: { $0.id == selectedAnimationID }),
           selected.editID == selectedEditID || (selectedEditID == nil && !state.cameraOpacityKeyframes.contains(where: { $0.id == selectedAnimationID.componentID })) { return }
        if selectedInspector == .pointer {
            selectedAnimationID = timelineAnimations.first(where: { $0.lane == .pointer })?.id
        } else if let edit = selectedEdit {
            let lane: TimelineAnimationLane = selectedInspector == .camera
                ? (edit.cameraID == nil && edit.cameraOpacityID != nil ? .cameraOpacity : .camera)
                : selectedInspector == .speed ? .speed : .screen
            selectedAnimationID = timelineAnimations.first(where: { $0.editID == edit.id && $0.lane == lane })?.id
        } else if selectedInspector == .camera, selectedAnimationID?.lane == .camera,
                  selectedAnimationID?.componentID == state.pipKeyframes.first?.id {
            // The fixed initial camera target has no grouped TimedEdit.
            return
        } else { selectedAnimationID = nil }
    }

    private func deselectEdit() {
        playback.pause()
        guard editor.finishDraft() else { return }
        selectedEditID = nil
        selectedAnimationID = nil
        selectedAnimationDisplayID = nil
        playback.selectEditingBranch(nearProjectTime: nil)
    }

    private func selectAnimation(_ id: TimelineAnimationID) {
        propertyScrollRequest = UUID()
        selectedVideoClipID = nil; selectedVideoVolumeID = nil
        cutSelection = nil; selectedCutID = nil
        playback.pause()
        if selectedAnimationID == id { return }
        guard editor.finishDraft(), let span = timelineAnimations.first(where: { $0.id == id }) else { return }
        selectedAnimationID = id
        if id.lane == .pointer { selectedInspector = .pointer; selectedEditID = nil; return }
        if let role = id.lane.audioRole {
            selectedInspector = role == .microphone && editor.project.cameraFilename != nil ? .camera : .audio
            audioRole = role; selectedEditID = nil; return
        }
        selectedEditID = edits.first(where: { edit in
            span.isReference ? edit.anchorID == id.componentID : id.lane == .screen ? edit.zoomID == id.componentID :
                id.lane == .speed ? edit.speedID == id.componentID : id.lane == .cameraOpacity ? edit.cameraOpacityID == id.componentID : edit.cameraID == id.componentID
        })?.id
        selectedInspector = id.lane == .camera || id.lane == .cameraOpacity ? .camera : id.lane == .speed ? .speed : .zoom
    }

    private func projectFinishedAnimation(_ request: AnimationDrag) -> [TimelineAnimation]? {
        guard !isSourceTimeline, let map = animationGesture?.map ?? timelineMap else { return nil }
        return FinishedTimelineEditing.projectedPreview(request, animations: animationGesture?.spans ?? timelineAnimations,
            map: map, sourceDuration: editor.project.duration)
    }

    private func editAnimation(_ request: AnimationDrag, final: Bool) {
        if animationGesture == nil {
            assistant.cancel(); playback.pause()
            guard editor.finishDraft() else { return }
            let spans = timelineAnimations
            let originalID = outputProjection?.sourceIDs[request.id] ?? request.id
            guard spans.contains(where: { $0.id == originalID && $0.editable }) else { return }
            let verb: String = switch request.handle { case .move: "Move"; case .start, .end: "Resize"; case .easeIn, .easeOut: "Adjust ramps for" }
            animationGesture = AnimationGestureSnapshot(id: request.id, originalID: originalID, state: editor.project.state, spans: spans,
                replacements: EditorAnimationEditing.replacementIDs(for: spans), playhead: playback.time,
                selection: selectedEditID, animationSelection: selectedAnimationID,
                name: "\(verb) \(request.id.lane == .cameraOpacity ? "camera opacity" : request.id.lane.rawValue) animation", timeBase: isSourceTimeline ? .source : .output,
                map: timelineIsIdentity ? nil : timelineMap, outputPlayhead: playback.outputTime, previewSpans: spans)
        }
        guard let gesture = animationGesture, gesture.id == request.id,
              let original = gesture.spans.first(where: { $0.id == gesture.originalID }) else { return }
        let changes: [TimelineAnimation]?
        if let map = gesture.map {
            changes = FinishedTimelineEditing.changes(request, animations: gesture.spans, map: map, sourceDuration: editor.project.duration)
        } else { changes = TimelineAnimationSolver.solve(request, animations: gesture.spans, duration: editor.project.duration) }
        guard let changes,
              let edit = EditorAnimationEditing.applying(changes, to: gesture.state, duration: editor.project.duration,
                replacementIDs: gesture.replacements) else { return }
        let aliases = Dictionary(uniqueKeysWithValues: edit.aliases.map { ($0.replacementID, $0.originalID) })
        // Every sample uses the same draft time. A moving endpoint must not
        // turn individual pointer samples into separate Undo entries.
        guard editor.updateDraft(edit.state, at: original.end, editAliases: aliases) else { return }
        let preview = Dictionary(uniqueKeysWithValues: changes.map { ($0.id, $0) })
        animationGesture?.previewSpans = gesture.spans.map { preview[$0.id] ?? $0 }
        let component = edit.aliases.first(where: { $0.lane == request.id.lane && $0.originalID == gesture.originalID.componentID })?.replacementID ?? gesture.originalID.componentID
        selectedEditID = edits.first(where: { value in
            original.isReference ? value.anchorID == component : request.id.lane == .screen ? value.zoomID == component :
                request.id.lane == .speed ? value.speedID == component : request.id.lane == .cameraOpacity ? value.cameraOpacityID == component : value.cameraID == component
        })?.id
        selectedInspector = request.id.lane.audioRole != nil ? .audio : (request.id.lane == .camera || request.id.lane == .cameraOpacity) ? .camera : request.id.lane == .speed ? .speed : .zoom
        if let role = request.id.lane.audioRole { audioRole = role; selectedEditID = nil }
        selectedAnimationID = gesture.originalID
        let current = changes.first(where: { $0.id == gesture.originalID }) ?? original
        playback.selectEditingBranch(nearProjectTime: current.end)
        if final {
            guard editor.finishDraft(name: gesture.name) else { return }
            selectedAnimationID = TimelineAnimationID(lane: request.id.lane, componentID: component)
            animationGesture = nil
        }
    }

    private func cancelAnimationGesture() {
        guard let gesture = animationGesture else { return }
        guard editor.draftState == nil || editor.cancelDraft() else { return }
        animationGesture = nil
        selectedEditID = gesture.selection
        selectedAnimationID = gesture.animationSelection
        playback.cancelPreview()
        if gesture.timeBase == .output { playback.seekOutput(gesture.outputPlayhead) }
        else { playback.seekProjectTime(gesture.playhead) }
    }

    private func deleteAnimation(_ id: TimelineAnimationID) {
        playback.pause(); assistant.cancel()
        guard editor.finishDraft(), let span = timelineAnimations.first(where: { $0.id == id && $0.editable }) else { return }
        var next = state
        if span.isReference { next.editAnchors.removeAll { $0.id == id.componentID } }
        else if let role = id.lane.audioRole { next.audio.updateChannel(role) { $0.points.removeAll { $0.id == id.componentID } } }
        else {
            do { try EditorMutation.removeAnimation(animationID: "\(id.lane.rawValue):\(id.componentID.uuidString)").apply(to: &next, project: editor.project) }
            catch { timelineError = error.localizedDescription; return }
        }
        if editor.commit(next, name: "Remove \(id.lane.rawValue) animation") { selectedAnimationID = nil; selectedEditID = nil }
    }

    private func holdCurrentFraming() {
        let time = editTime
        let screen = zoom
        let camera = placement
        setZoom(screen, at: time, name: "Edit")
        if editor.project.cameraFilename != nil { setPlacement(camera, at: time, name: "Edit") }
    }

    private func removeEdit(_ edit: TimedEdit) {
        playback.pause()
        guard editor.finishDraft() else { return }
        var next = editor.project.state
        next.remove(edit)
        if editor.commit(next, name: "Remove edit") { selectedEditID = nil }
    }

    private func moveEdit(_ id: UUID, to time: Double, final: Bool) {
        if movingEditState == nil {
            guard editor.finishDraft() else { return }
            movingEditState = editor.project.state
        }
        guard let base = movingEditState, let edit = base.timedEdits(includeCamera: editor.project.cameraFilename != nil).first(where: { $0.id == id }) else { return }
        var next = base
        next.move(edit, to: time)
        if final {
            guard editor.updateDraft(next, at: edit.time), editor.finishDraft(name: "Move edit") else { return }
            movingEditState = nil
            selectedEditID = id
            playback.seekProjectTime(time)
        } else {
            _ = editor.updateDraft(next, at: edit.time)
            playback.seekProjectTime(time)
        }
    }

    private func cancelMove() {
        movingEditState = nil
        _ = editor.cancelDraft()
        if let selectedEdit { playback.seekProjectTime(selectedEdit.time) }
        selectedEditID = nil
        playback.cancelPreview()
    }

    private func cancelDraft() {
        presentationDraft = nil
        audioGestureTime = nil
        audioVolumeGesture = nil
        _ = editor.cancelDraft()
        selectedEditID = nil
        playback.cancelPreview()
    }

    private func togglePlayback() {
        automation.togglePlayback()
    }

    private var pointerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Toggle("Show pointer", isOn: Binding(get: { state.cursorStyle.visible }, set: { value in
                    var next = state.cursorStyle; next.visible = value
                    setCursorStyle(next, name: value ? "Show pointer" : "Hide pointer")
                }))
                Toggle("Click highlights", isOn: Binding(get: { state.cursorStyle.clickHighlight }, set: { value in
                    var next = state.cursorStyle; next.clickHighlight = value
                    setCursorStyle(next, name: "Change click highlights")
                }))
                Spacer()
            }.toggleStyle(.checkbox).frame(height: 24)
            HStack {
                CommitSlider(title: "Size", value: state.cursorStyle.size, range: 1...4, valueSuffix: "×", begin: { leaveConflictForManualEdit(); playback.pause() }, preview: { value in
                    var next = state; next.cursorStyle.size = value; playback.preview(next)
                }) { value in
                    var next = state.cursorStyle; next.size = value
                    setCursorStyle(next, name: "Resize pointer")
                }.frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true)
                Spacer()
            }.frame(height: 24)
            CommitSlider(title: "Smoothing", value: state.cursorStyle.smoothing, range: 0...1, begin: { leaveConflictForManualEdit(); playback.pause() }, preview: { value in
                var next = state; next.cursorStyle.smoothing = value; playback.preview(next)
            }) { value in
                var next = state.cursorStyle; next.smoothing = value
                setCursorStyle(next, name: "Smooth pointer")
            }.frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true).frame(height: 24)
        }
        .disabled(editor.project.cursorFilename == nil)
        .help(editor.project.cursorFilename == nil ? "Record a new clip to edit its pointer." : "Pointer settings apply throughout the recording. Click highlights mark mouse presses.")
    }

    private func suggestZooms(_ preset: CursorZoomSuggestions.Preset) {
        guard let recording = playback.cursorRecording else { return }
        playback.pause()
        var next = state
        next.zoomKeyframes = CursorZoomSuggestions.points(in: recording,
            range: state.trimStart...state.trimEnd, preset: preset,
            frameDuration: playback.frameDuration)
        if editor.commit(next, name: "Create click zooms") { selectedEditID = nil }
    }

    private func beginZoomGesture() {
        selectedVideoClipID = nil; selectedVideoVolumeID = nil
        assistant.cancel()
        let originalTime = playback.time
        if playback.isPlaying { selectedEditID = nil; selectedAnimationID = nil }
        playback.pause()
        dragTime = targetTime(editTime)
        canvasGesture = CanvasGestureSnapshot(state: state, time: dragTime, hadDraft: editor.draftState != nil, playhead: originalTime, outputPlayhead: playback.outputTime, lane: .screen)
        inspectEditingTarget(at: dragTime)
        selectedInspector = .zoom
    }

    private func beginOpacityGesture() {
        beginCameraGesture()
        canvasGesture?.lane = .cameraOpacity
        selectedAnimationID = state.cameraOpacityKeyframes.first { abs($0.time - dragTime) < 0.000001 }
            .map { TimelineAnimationID(lane: .cameraOpacity, componentID: $0.id) }
    }

    private func beginCameraGesture() {
        selectedVideoClipID = nil; selectedVideoVolumeID = nil
        assistant.cancel()
        dragTime = targetTime(editTime)
        canvasGesture = CanvasGestureSnapshot(state: state, time: dragTime, hadDraft: editor.draftState != nil, playhead: playback.time, outputPlayhead: playback.outputTime, lane: .camera)
        inspectEditingTarget(at: dragTime)
        selectedInspector = .camera
        selectedAnimationID = state.pipKeyframes.first { abs($0.time - dragTime) < 0.000001 }
            .map { TimelineAnimationID(lane: .camera, componentID: $0.id) }
    }

    private func inspectEditingTarget(at time: Double) {
        playback.pause()
        playback.selectEditingBranch(nearProjectTime: time)
    }

    private func restoreCanvasGesture(_ snapshot: CanvasGestureSnapshot?) {
        guard let snapshot else { return }
        if snapshot.hadDraft, snapshot.state != editor.project.state {
            guard editor.updateDraft(snapshot.state, at: snapshot.time) else { return }
        } else {
            guard editor.cancelDraft() else { return }
        }
        canvasGesture = nil
        playback.preview(editor.editingState)
        playback.selectEditingBranch(nearProjectTime: snapshot.playhead)
        if playback.outputTime != snapshot.outputPlayhead { playback.seekOutput(snapshot.outputPlayhead) }
    }

    private func targetTime(_ position: Double) -> Double {
        if let selectedEdit, abs(selectedEdit.time - position) < 0.000001 { return selectedEdit.time }
        if let draftTime = editor.draftTime, abs(draftTime - position) < 0.000001 { return draftTime }
        return editor.project.editingTime(at: position, frameDuration: frameDuration)
    }

    private func applyingZoom(_ placement: ZoomPlacement, at position: Double) -> EditState {
        let time = targetTime(position)
        var next = state
        let existing = next.zoomKeyframes.first { abs($0.time - time) < 0.000001 }
        let group = edits.first { abs($0.time - time) < 0.000001 }
        let placement = placement.clamped
        next.zoomKeyframes.removeAll { abs($0.time - time) < 0.000001 }
        next.zoomKeyframes.append(ZoomKeyframe(id: existing?.id ?? group?.id ?? UUID(), time: time,
            scale: placement.scale, x: placement.x, y: placement.y,
            transition: existing?.transition ?? zoomTransition, duration: existing?.duration ?? zoomDuration,
            easeIn: existing == nil ? zoomEaseIn : existing?.easeIn,
            easeOut: existing == nil ? zoomEaseOut : existing?.easeOut,
            sourceRegionID: existing?.placement.clamped == placement ? existing?.sourceRegionID : nil))
        next.zoomKeyframes.sort { $0.time < $1.time }
        return next
    }

    private func setZoom(_ placement: ZoomPlacement, at time: Double, name: String) {
        playback.pause()
        let next = applyingZoom(placement, at: time)
        guard next != state else { return }
        inspectEditingTarget(at: targetTime(time))
        if editor.updateDraft(next, at: targetTime(time)) {
            selectedEditID = next.timedEdits(includeCamera: editor.project.cameraFilename != nil).first { abs($0.time - targetTime(time)) < 0.000001 }?.id
        }
    }

    private func updateZoomPoint(_ change: (inout ZoomKeyframe) -> Void) {
        guard var point = zoomPoint else { return }
        playback.pause()
        change(&point)
        var next = state
        if let index = next.zoomKeyframes.firstIndex(where: { $0.id == point.id }) { next.zoomKeyframes[index] = point }
        if next != state { inspectEditingTarget(at: point.time) }
        _ = editor.updateDraft(next, at: point.time)
    }

    private func setCursorStyle(_ style: CursorStyle, name: String) {
        playback.pause()
        var next = state
        next.cursorStyle = style
        if !editor.commit(next, name: name) { playback.cancelPreview() }
    }

    private var cameraVisibility: some View {
        HStack(spacing: 8) {
            CommitSlider(title: "Opacity", value: placement.renderedOpacity * 100, range: 0...100,
                valueSuffix: "%", valueFormat: "%.0f", begin: { beginOpacityGesture() }, preview: { value in
                    guard canvasGesture != nil else { return }
                    setCameraOpacity(value / 100)
                }) { value in
                    guard canvasGesture != nil else { return }
                    setCameraOpacity(value / 100)
                    if editor.finishDraft(name: EditorActionDescription.cameraOpacityLabel(value / 100)) { canvasGesture = nil }
                }.frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true)
                .help("Camera transparency at this edit. Smooth fades using the Camera duration and ramps; Jump changes opacity instantly.")
            Button {
                let value = placement.renderedOpacity > 0 ? 0.0 : 1.0
                beginOpacityGesture()
                setCameraOpacity(value)
                if editor.finishDraft(name: EditorActionDescription.cameraOpacityLabel(value)) { canvasGesture = nil }
            } label: { Image(systemName: placement.renderedOpacity > 0 ? "eye" : "eye.slash") }
                .buttonStyle(.borderless)
                .accessibilityLabel(placement.renderedOpacity > 0 ? "Hide camera" : "Show camera")
                .help("Toggle camera opacity between 0% and 100%. Smooth uses the Camera duration and ramps to fade.")
        }
    }

    private func setCameraOpacity(_ value: Double) {
        guard value.isFinite, abs(state.cameraOpacity(at: editTime) - value) > 0.000000001 else { return }
        playback.pause()
        let time = targetTime(editTime), existing = opacityPoint
        var edited = state
        let keyframe = CameraOpacityKeyframe(id: existing?.id ?? UUID(), time: time, opacity: min(1, max(0, value)),
            transition: existing?.transition ?? transition, duration: existing?.duration ?? transitionDuration,
            easeIn: existing == nil ? cameraEaseIn : existing?.easeIn, easeOut: existing == nil ? cameraEaseOut : existing?.easeOut)
        edited.cameraOpacityKeyframes.removeAll { abs($0.time - time) < 0.000001 }
        edited.cameraOpacityKeyframes.append(keyframe)
        edited.cameraOpacityKeyframes.sort { $0.time < $1.time }
        if editor.updateDraft(edited, at: time) {
            selectedAnimationID = TimelineAnimationID(lane: .cameraOpacity, componentID: keyframe.id)
            selectedEditID = edited.timedEdits(includeCamera: true).first { $0.cameraOpacityID == keyframe.id }?.id
        }
    }

    private var cameraCanvasSize: CGSize {
        PresentationGeometry(sourceSize: playback.sourceSize, presentation: canvasPresentation).outputSize
    }
    private var cameraWidthPercent: Double {
        EditorCameraSizing.fraction(placement, in: cameraCanvasSize, cameraAspect: playback.cameraAspect) * 100
    }
    private var cameraMinimumWidthPercent: Double {
        EditorCameraSizing.minimumFraction(placement, in: cameraCanvasSize, cameraAspect: playback.cameraAspect) * 100
    }
    private func cameraSized(to percent: Double) -> PIPPlacement {
        EditorCameraSizing.sized(placement, to: percent / 100, in: cameraCanvasSize, cameraAspect: playback.cameraAspect)
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorControlFlow(spacing: 12) {
                Picker("Shape", selection: Binding(get: { placement.shape }, set: { shape in
                    var next = placement
                    if shape == .rectangle {
                        let output = PresentationGeometry(sourceSize: playback.sourceSize, presentation: canvasPresentation).outputSize
                        let frame = placement.frame(in: output, cameraAspect: playback.cameraAspect)
                        next.aspectRatio = min(5, max(0.2, frame.width / frame.height))
                    }
                    next.shape = shape
                    next.fullscreen = nil
                    setPlacement(next, at: editTime, name: "Change camera shape")
                })) {
                    ForEach(PIPShape.allCases, id: \.rawValue) { shape in Text(shape.title).tag(shape) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading).layoutValue(key: EditorFlowFullWidth.self, value: true)
                .help("Change the camera's overlay outline at the selected edit or playhead. Changing Shape returns a fullscreen camera to its overlay.")
                Button("Crop…") { openCameraCrop() }
                    .help("Draw a crop in the original camera video. The output canvas stays the same.")
                CommitSlider(title: "Size", value: cameraWidthPercent, range: cameraMinimumWidthPercent...100,
                    valueSuffix: "%", valueFormat: "%.0f", begin: { beginCameraGesture() }, preview: { value in
                    setPlacement(cameraSized(to: value), at: editTime, name: "Edit")
                }) { value in
                    setPlacement(cameraSized(to: value), at: editTime, name: "Resize camera")
                    canvasGesture = nil
                }.frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true)
                    .help("Camera width as a percentage of the final canvas. 100% fills the canvas. Drag a corner to resize directly.")
                Spacer(minLength: 0)
            }
            cameraVisibility.disabled(hasAmbiguousFramingTarget)
            transitionControls(camera: true)
        }
    }

    private var hasRecordedMicrophone: Bool { editor.project.audioSources.contains { $0.role == .microphone } }
    private var microphoneControls: some View {
        HStack(spacing: 8) {
            CommitSlider(title: "Microphone", value: state.audio.channel(.microphone).volume * 100, range: 0...100,
                valueSuffix: "%", valueFormat: "%.0f", begin: beginAudioGesture,
                preview: { value in previewAudio { audio in audio.updateChannel(.microphone) { $0.volume = value / 100 } } }) { value in
                    finishAudioGesture(name: "Change microphone level") { audio in audio.updateChannel(.microphone) { $0.volume = value / 100 } }
                }
                .help("Recorded microphone level. Camera visibility and opacity leave this audio unchanged. Select the Microphone lane to edit timed volume changes.")
            Button {
                let muted = !state.audio.channel(.microphone).isMuted
                commitAudio(name: muted ? "Mute microphone" : "Unmute microphone") { audio in audio.updateChannel(.microphone) { $0.isMuted = muted } }
            } label: { Image(systemName: state.audio.channel(.microphone).isMuted ? "mic.slash" : "mic") }
                .accessibilityLabel(state.audio.channel(.microphone).isMuted ? "Unmute microphone" : "Mute microphone")
                .help(state.audio.channel(.microphone).isMuted ? "Unmute the recorded microphone." : "Mute the recorded microphone.")
        }
    }

    private var cameraCornerControls: some View {
        HStack(spacing: 8) {
            ForEach(0..<4) { index in
                Button {
                    var next = placement
                    next.x = index % 2 == 0 ? 0.04 : 0.96
                    next.y = index < 2 ? 0.04 : 0.96
                    setPlacement(next, at: editTime, name: "Move camera")
                } label: {
                    Image(systemName: ["arrow.up.left", "arrow.up.right", "arrow.down.left", "arrow.down.right"][index])
                }
                .help(placement.fullscreenFraction == 1 ? "A fullscreen camera has no position to move. Resize it to make room."
                    : ["Move camera to the top left", "Move camera to the top right", "Move camera to the bottom left", "Move camera to the bottom right"][index])
                .accessibilityLabel(["Camera top left", "Camera top right", "Camera bottom left", "Camera bottom right"][index])
                .disabled(placement.fullscreenFraction == 1)
            }
        }
    }

    private func applying(_ next: PIPPlacement, at position: Double) -> EditState {
        var edited = state
        let time = targetTime(position)
        let existing = edited.pipKeyframes.first { abs($0.time - time) < 0.000001 }
        let group = edits.first { abs($0.time - time) < 0.000001 }
        var geometry = next
        let legacy = state.cameraGeometry(at: time)
        geometry.visible = legacy.visible; geometry.opacity = legacy.opacity
        let keyframe = PIPKeyframe(id: existing?.id ?? group?.id ?? UUID(), time: time, placement: geometry,
            transition: existing?.transition ?? transition, duration: existing?.duration ?? transitionDuration,
            easeIn: existing == nil ? cameraEaseIn : existing?.easeIn,
            easeOut: existing == nil ? cameraEaseOut : existing?.easeOut)
        edited.pipKeyframes.removeAll { abs($0.time - time) < 0.000001 }
        edited.pipKeyframes.append(keyframe)
        edited.pipKeyframes.sort { $0.time < $1.time }
        return edited
    }

    private func openMainCrop() {
        assistant.cancel(); leaveConflictForManualEdit(); playback.pause()
        guard editor.finishDraft(), let source = editor.project.videoSources.first(where: { $0.id == VideoSource.legacyScreenID }) else { return }
        let crop = state.presentation.sourceCrop ?? CropGeometry.full
        cropRequest = VideoCropRequest(title: "Crop main video", source: source, time: playback.editingTime,
            sourceSize: playback.sourceSize, crop: crop, setsOutputFrame: true, outputResolution: state.presentation.outputResolution) { rect, resolution in
                var next = editor.editingState
                next.presentation.sourceCrop = rect == CropGeometry.full ? nil : rect
                next.presentation.aspect = .source
                next.presentation.padding = 0
                next.presentation.outputResolution = resolution
                if editor.commit(next, name: "Crop main video") { presentationDraft = nil }
            }
    }

    private func openCameraCrop() {
        assistant.cancel(); leaveConflictForManualEdit(); playback.pause()
        guard editor.finishDraft(), let source = editor.project.videoSources.first(where: { $0.id == VideoSource.legacyCameraID }) else { return }
        let time = editTime
        let size = CGSize(width: 1080 * playback.cameraAspect, height: 1080)
        let current = state.placement(at: time)
        let crop = CropGeometry.normalized(current.sourceViewport(in: size, canvas: cameraCanvasSize), in: size)
        cropRequest = VideoCropRequest(title: "Crop camera", source: source, time: time - editor.project.cameraOffset,
            sourceSize: size, crop: crop) { rect, _ in
                var next = editor.editingState.placement(at: time)
                next.sourceCrop = rect == CropGeometry.full ? nil : rect
                next.shape = rect == CropGeometry.full ? .original : .rectangle
                // The normalized rectangle's ratio is multiplied by the oriented source aspect.
                next.aspectRatio = rect.width / rect.height * playback.cameraAspect
                next.crop = PIPCrop(); next.sourceZoom = 1; next.fullscreen = nil
                setPlacement(next, at: time, name: "Crop camera")
                _ = editor.finishDraft(name: "Crop camera")
            }
    }

    private func setPlacement(_ next: PIPPlacement, at time: Double, name: String) {
        playback.pause()
        let edited = applying(next, at: time)
        guard edited != state else { return }
        inspectEditingTarget(at: targetTime(time))
        if editor.updateDraft(edited, at: targetTime(time)) {
            selectedEditID = edited.timedEdits(includeCamera: editor.project.cameraFilename != nil).first { abs($0.time - targetTime(time)) < 0.000001 }?.id
            selectedAnimationID = edited.pipKeyframes.first { abs($0.time - targetTime(time)) < 0.000001 }
                .map { TimelineAnimationID(lane: .camera, componentID: $0.id) }
        }
    }

    private func updateSelected(_ update: (inout PIPKeyframe) -> Void) {
        guard var selected = cameraTimingPoint else { return }
        playback.pause()
        update(&selected)
        var edited = state
        if usesCameraOpacityTiming {
            if let index = edited.cameraOpacityKeyframes.firstIndex(where: { $0.id == selected.id }) {
                edited.cameraOpacityKeyframes[index].transition = selected.transition
                edited.cameraOpacityKeyframes[index].duration = selected.duration
                edited.cameraOpacityKeyframes[index].easeIn = selected.easeIn
                edited.cameraOpacityKeyframes[index].easeOut = selected.easeOut
            }
        } else if let index = edited.pipKeyframes.firstIndex(where: { $0.id == selected.id }) { edited.pipKeyframes[index] = selected }
        if edited != state { inspectEditingTarget(at: selected.time) }
        _ = editor.updateDraft(edited, at: selected.time)
    }

    private func transitionControls(camera: Bool) -> some View {
        let mode = camera ? cameraTimingPoint?.transition ?? transition : zoomPoint?.transition ?? zoomTransition
        let requested = camera ? cameraTimingPoint?.duration ?? transitionDuration : zoomPoint?.duration ?? zoomDuration
        let previous = camera ? (usesCameraOpacityTiming ? state.cameraOpacityEvents.last(where: { $0.time < editTime })?.time ?? 0
            : state.pipKeyframes.last(where: { $0.time < editTime })?.time ?? 0)
                              : state.zoomKeyframes.last(where: { $0.time < editTime })?.time ?? 0
        let span = max(0, min(requested, editTime - previous))
        let hasComponent = camera ? cameraTimingPoint != nil : zoomPoint != nil
        let easeIn = camera ? cameraTimingPoint?.easeIn : zoomPoint?.easeIn
        let easeOut = camera ? cameraTimingPoint?.easeOut : zoomPoint?.easeOut
        let ramps = MotionInterpolation.rampDurations(duration: span, easeIn: easeIn, easeOut: easeOut)
        let showsMovement = selectedEdit != nil && hasComponent && editTime > previous
        return VStack(alignment: .leading, spacing: 8) {
            EditorControlFlow(spacing: 12) {
                if camera && !usesCameraOpacityTiming { cameraCornerControls }
                if showsMovement {
                    Picker(camera && usesCameraOpacityTiming ? "Fade" : "Movement", selection: Binding(get: { mode }, set: { value in
                        if camera { transition = value; updateSelected { $0.transition = value } }
                        else { zoomTransition = value; updateZoomPoint { $0.transition = value } }
                    })) {
                        Text("Jump").tag(PIPTransition.jump)
                        Text("Smooth").tag(PIPTransition.smooth)
                    }
                    .frame(width: 185)
                    .help("Jump applies this edit instantly. Smooth accelerates, moves at steady speed, and decelerates to arrive at this edit.")
                    if mode == .smooth {
                        HStack(spacing: 6) {
                        Text(timelineIsIdentity ? "Duration" : "Duration (original)").font(.caption)
                        MotionDurationField(value: requested, maximum: max(editor.project.duration, requested), change: { value in
                            if camera { transitionDuration = value; updateSelected { $0.duration = value } }
                            else { zoomDuration = value; updateZoomPoint { $0.duration = value } }
                        }, cancel: { cancelDraft() })
                            .frame(width: 64, height: 24)
                            .help(timelineIsIdentity ? "Total movement time in seconds. The previous edit limits the available time." : originalTimingHelp)
                        Text("s").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if showsMovement && mode == .smooth {
                MotionRampStrip(duration: span, easeIn: ramps.easeIn, easeOut: ramps.easeOut,
                    timeUnits: timelineIsIdentity ? "seconds" : "original-recording seconds",
                    change: { incoming, value in setRamp(value, camera: camera, incoming: incoming, span: span, other: incoming ? ramps.easeOut : ramps.easeIn) })
                    .frame(maxWidth: .infinity).layoutValue(key: EditorFlowFullWidth.self, value: true).frame(height: 32)
                    .help("Drag the left boundary to adjust acceleration, or the right boundary to adjust deceleration. The middle moves at steady speed. The strip shows the time available before this edit.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setRamp(_ value: Double, camera: Bool, incoming: Bool, span: Double, other: Double) {
        let other = min(span, max(0, other))
        let value = min(max(0, span - other), max(0, value))
        if camera {
            cameraEaseIn = incoming ? value : other
            cameraEaseOut = incoming ? other : value
            updateSelected { $0.easeIn = cameraEaseIn; $0.easeOut = cameraEaseOut }
        } else {
            zoomEaseIn = incoming ? value : other
            zoomEaseOut = incoming ? other : value
            updateZoomPoint { $0.easeIn = zoomEaseIn; $0.easeOut = zoomEaseOut }
        }
    }

    private func beginExport(sharing: Bool) {
        playback.pause()
        exportSession.begin(editor: editor, sharing: sharing)
    }

}

struct ProjectUndoButtons: View {
    @ObservedObject var editor: ProjectEditor
    @State private var textRevision = 0
    private var window: NSWindow? {
        NSApplication.shared.windows.first { ($0.delegate as? EditorDraftWindowDelegate)?.editor === editor }
    }
    var body: some View {
        let _ = textRevision
        Group {
            Button { EditorUndoRouting.undo(editor: editor, window: window) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .labelStyle(.iconOnly).disabled(!EditorUndoRouting.canUndo(editor: editor, window: window))
                .help("Undo \(EditorUndoRouting.undoName(editor: editor, window: window)) (⌘Z)")
                .background(EditorTextUndoTarget())
            Button { EditorUndoRouting.redo(editor: editor, window: window) } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .labelStyle(.iconOnly).disabled(!EditorUndoRouting.canRedo(editor: editor, window: window))
                .help("Redo \(EditorUndoRouting.redoName(editor: editor, window: window)) (⇧⌘Z)")
                .background(EditorTextUndoTarget())
        }
        .onReceive(Publishers.MergeMany([
            NSControl.textDidBeginEditingNotification, NSControl.textDidChangeNotification,
            NSControl.textDidEndEditingNotification, Notification.Name.NSUndoManagerDidUndoChange,
            Notification.Name.NSUndoManagerDidRedoChange, Notification.Name.NSUndoManagerDidCloseUndoGroup
        ].map { NotificationCenter.default.publisher(for: $0) })) { _ in textRevision &+= 1 }
    }
}

/// The two boundaries divide acceleration, constant speed, and deceleration.
private struct MotionRampStrip: View {
    let duration: Double
    let easeIn: Double
    let easeOut: Double
    var timeUnits = "seconds"
    var change: (Bool, Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 12)
            let span = max(0.001, duration)
            let incoming = CGFloat(easeIn / span) * width
            let outgoing = CGFloat(1 - easeOut / span) * width
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 6, y: 26))
                    for sample in 0...100 {
                        let time = Double(sample) / 100 * span
                        let speed = MotionInterpolation.normalizedSpeed(at: time, duration: span,
                            easeIn: easeIn, easeOut: easeOut)
                        path.addLine(to: CGPoint(x: 6 + CGFloat(sample) / 100 * width, y: 26 - 20 * speed))
                    }
                    path.addLine(to: CGPoint(x: width + 6, y: 26))
                    path.closeSubpath()
                }.fill(Color.purple.opacity(0.3))
                ForEach([true, false], id: \.self) { incomingHandle in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.purple)
                        .frame(width: 4, height: 24)
                        .frame(width: 20, height: 32)
                        .contentShape(Rectangle())
                        .position(x: 6 + (incomingHandle ? incoming : outgoing), y: 16)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("motionRamp")).onChanged { value in
                            let fraction = min(1, max(0, (value.location.x - 6) / width))
                            change(incomingHandle, Double(incomingHandle ? fraction : 1 - fraction) * duration)
                        })
                        .help("\(incomingHandle ? "Acceleration" : "Deceleration"): \(String(format: "%.2f", incomingHandle ? easeIn : easeOut)) \(timeUnits). Drag to adjust.")
                        .accessibilityElement()
                        .accessibilityLabel(incomingHandle ? "Acceleration" : "Deceleration")
                        .accessibilityValue("\(String(format: "%.2f", incomingHandle ? easeIn : easeOut)) \(timeUnits)")
                        .accessibilityAdjustableAction { direction in
                            let value = incomingHandle ? easeIn : easeOut
                            switch direction {
                            case .increment: change(incomingHandle, min(duration, value + 0.01))
                            case .decrement: change(incomingHandle, max(0, value - 0.01))
                            @unknown default: break
                            }
                        }
                }
            }
            .coordinateSpace(name: "motionRamp")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transition speed: acceleration, constant speed, deceleration")
    }
}

/// A numeric duration updates the current edit's draft, never its undo history.
struct MotionDurationField: NSViewRepresentable {
    let value: Double
    let maximum: Double
    var change: (Double) -> Void
    var cancel: () -> Void

    func makeNSView(context: Context) -> MotionDurationTextField { MotionDurationTextField() }
    func updateNSView(_ field: MotionDurationTextField, context: Context) {
        field.configure(value: value, maximum: maximum, change: change, cancel: cancel)
    }
}

@MainActor
final class MotionDurationTextField: NSTextField, NSTextFieldDelegate {
    private var value = 0.4
    private var maximum = 3.0
    private var change: ((Double) -> Void)?
    private var cancel: (() -> Void)?
    private var separator: String { Locale.current.decimalSeparator ?? "." }

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        alignment = .right
        font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        isBezeled = true
        bezelStyle = .roundedBezel
        setAccessibilityLabel("Duration")
        setAccessibilityHelp("Movement duration in seconds. Return accepts the number; Escape cancels the unfinished edit.")
    }
    required init?(coder: NSCoder) { nil }

    func configure(value: Double, maximum: Double, change: @escaping (Double) -> Void, cancel: @escaping () -> Void) {
        self.value = value
        self.maximum = maximum
        self.change = change
        self.cancel = cancel
        if currentEditor() == nil { restoreNumber() }
    }

    private func restoreNumber() {
        stringValue = String(format: "%.2f", value).replacingOccurrences(of: ".", with: separator)
    }

    func controlTextDidChange(_ notification: Notification) {
        let draft = (currentEditor() as? NSTextView)?.string ?? stringValue
        guard let next = Double(draft.replacingOccurrences(of: separator, with: ".")),
              next.isFinite, next >= 0.01, next <= maximum else { return }
        value = next
        change?(next)
    }

    func controlTextDidEndEditing(_ notification: Notification) { restoreNumber() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancel?()
            window?.makeFirstResponder(nil)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: self))
            window?.makeFirstResponder(nil)
            restoreNumber()
            return true
        }
        return false
    }
}

/// Keep a native drag local until release, then reconcile with the owning
/// value. The owner may have rolled back an unfinished edit while tracking.
struct CommitSliderGesture {
    var draft = 0.0
    private(set) var isEditing = false

    mutating func synchronize(_ value: Double, in range: ClosedRange<Double>) {
        guard !isEditing else { return }
        draft = min(max(value, range.lowerBound), range.upperBound)
    }

    mutating func begin() {
        // Native controls may already have supplied a click's first sample.
        // Preserve it; idle owner changes and the previous release reconcile.
        isEditing = true
    }

    mutating func finish(restoring value: Double, in range: ClosedRange<Double>) -> Double {
        let proposed = draft
        isEditing = false
        synchronize(value, in: range)
        return proposed
    }
}

/// Slider release finishes a gesture; the editor decides its undo boundary.
struct CommitSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var valueSuffix: String? = nil
    var valueFormat = "%.2f"
    var begin: () -> Void = {}
    var preview: ((Double) -> Void)? = nil
    var commit: (Double) -> Void
    @State private var gesture = CommitSliderGesture()
    var body: some View {
        HStack {
            Text(title).font(.caption)
            Slider(value: $gesture.draft, in: range) { active in
                if active {
                    gesture.begin()
                    begin()
                } else {
                    let proposed = gesture.finish(restoring: value, in: range)
                    commit(proposed)
                }
            }.accessibilityLabel(title)
            if let valueSuffix {
                Text("\(gesture.isEditing ? gesture.draft : value, specifier: valueFormat)\(valueSuffix)")
                    .font(.caption).monospacedDigit().frame(width: 45, alignment: .trailing)
            }
        }
        .onChange(of: gesture.draft) { _, next in if gesture.isEditing { preview?(next) } }
        .onAppear { gesture.synchronize(value, in: range) }
        .onChange(of: value) { _, next in gesture.synchronize(next, in: range) }
    }
}


