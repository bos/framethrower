import AppKit
import SwiftUI

private enum EditorInspector: String, CaseIterable {
    case zoom = "Zoom", pointer = "Pointer", camera = "Camera"
}

struct ProjectEditorView: View {
    @ObservedObject var editor: ProjectEditor
    @StateObject private var playback = EditorPlayback()
    @State private var selectedInspector: EditorInspector = .zoom
    @State private var selectedEditID: UUID?
    @State private var movingEditState: EditState?
    @State private var zoomEaseIn: Double?
    @State private var zoomEaseOut: Double?
    @State private var cameraEaseIn: Double?
    @State private var cameraEaseOut: Double?
    @State private var zoomTransition: PIPTransition = .smooth
    @State private var zoomDuration = 0.4
    @State private var transition: PIPTransition = .jump
    @State private var transitionDuration = 0.6
    @State private var dragTime = 0.0
    @State private var isFramingPresented = false
    @State private var framingTime = 0.0
    @State private var cameraFrame: CGImage?
    @State private var cameraFrameError: String?
    @State private var exportError: String?
    @State private var isExporting = false
    @State private var playAfterRebuild = false

    private var state: EditState { editor.editingState }
    private var edits: [TimedEdit] { state.timedEdits(includeCamera: editor.project.cameraFilename != nil) }
    private var selectedEdit: TimedEdit? { edits.first { $0.id == selectedEditID } }
    private var editTime: Double { selectedEdit?.time ?? editor.draftTime ?? playback.editingTime }
    private var point: PIPKeyframe? { state.pipKeyframes.first { abs($0.time - editTime) < 0.000001 } }
    private var placement: PIPPlacement { state.placement(at: editTime) }
    private var zoom: ZoomPlacement { state.zoom(at: editTime) }
    private var zoomPoint: ZoomKeyframe? { state.zoomKeyframes.first { abs($0.time - editTime) < 0.000001 } }
    private var frameDuration: Double { playback.player.currentItem?.videoComposition?.frameDuration.seconds ?? 1.0 / 30 }


    var body: some View {
        VStack(spacing: 16) {
            HStack {
                RecordingTitleEditor(editor: editor, font: .systemFont(ofSize: 14, weight: .semibold))
                    .frame(minWidth: 140, idealWidth: 240, maxWidth: 300, minHeight: 24, maxHeight: 24)
                ProjectUndoButtons(editor: editor)
                Spacer()
                Button("Export…") { Task { await export() } }.disabled(isExporting || playback.isLoading)
            }.frame(height: 24)
            player
            timeline
            inspector
            if let message = editor.errorMessage ?? playback.errorMessage ?? exportError {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if isExporting { ProgressView("Exporting…") }
        }
        .padding(24)
        .frame(minWidth: 820, idealWidth: 940, maxWidth: .infinity,
               minHeight: 760, idealHeight: 780, maxHeight: .infinity)
        .background(.background)
        .background(EditorDraftLifecycle(editor: editor).frame(width: 0, height: 0))
        .navigationTitle(editor.displayName)
        .task {
            await playback.rebuild(editor: editor)
            if let time = editor.draftTime, let draft = editor.draftState {
                playback.seek(time)
                selectedEditID = edits.first(where: { abs($0.time - time) < 0.000001 })?.id
                playback.preview(draft)
            }
        }
        .onChange(of: editor.project.state) { _, _ in
            Task {
                await playback.rebuild(editor: editor)
                if playAfterRebuild { playAfterRebuild = false; playback.togglePlayback() }
            }
            if let selectedEditID, !edits.contains(where: { $0.id == selectedEditID }) { self.selectedEditID = nil }
        }
        .onChange(of: editor.draftState) { old, next in
            if let next { playback.preview(next) }
            else if let old, old != editor.project.state { playback.cancelPreview() }
        }
        .onChange(of: editor.historyNavigationToken) { _, _ in
            guard let time = editor.historyNavigationTime else { return }
            selectedEditID = edits.first(where: { abs($0.time - time) < 0.000001 })?.id
            playback.pause()
            playback.seek(time)
        }
        .onDisappear { _ = editor.finishDraft(); playback.close() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            _ = editor.finishDraft()
        }
        .onExitCommand { if movingEditState != nil { cancelMove() } else { cancelDraft() } }
        .disabled(isExporting)
    }

    private var player: some View {
        EditorCanvas(player: playback.player, frames: playback.frameStore,
            sourceSize: playback.screenSize, cameraAspect: playback.cameraAspect,
            placement: placement, cameraEnabled: editor.project.cameraFilename != nil && !playback.isScrubbing,
            showsStill: !playback.isPlaying,
            onBegin: { playback.pause(); dragTime = editTime; selectedInspector = .camera },
            onPreview: { next in setPlacement(next, at: dragTime, name: "Edit") },
            onCommit: { next, name in setPlacement(next, at: dragTime, name: name) },
            onCancel: { cancelDraft() },
            zoom: zoom, allowsZoomEditing: !playback.isLoading && !playback.isScrubbing,
            onZoomBegin: { beginZoomGesture() },
            onZoomPreview: { next in setZoom(next, at: dragTime, name: "Edit") },
            onZoomCommit: { next, name in setZoom(next, at: dragTime, name: name) })
            .frame(minHeight: 260, idealHeight: 310, maxHeight: .infinity)
            .overlay { if playback.isLoading { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var timeline: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { togglePlayback() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
                }
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!playback.canPlay)
                RecordingTimeline(duration: editor.project.duration, trimStart: state.trimStart,
                    trimEnd: state.trimEnd, playhead: playback.time,
                    onInteractionBegan: { playback.pause() },
                    onSeek: { if editor.draftState == nil { playback.scrub(to: $0) } },
                    onScrubBegan: {
                        guard editor.finishDraft() else { return }
                        selectedEditID = nil
                        playback.beginScrubbing()
                    },
                    onScrubEnded: { playback.endScrubbing() },
                    onTrim: { start, end in setTrim(start, end) },
                    edits: edits.map { timelineMarker($0) },
                    selectedEditID: selectedEditID,
                    onSelectEdit: { selectEdit($0) },
                    frameDuration: frameDuration,
                    onMoveEdit: { id, time, final in moveEdit(id, to: time, final: final) },
                    onCancelMoveEdit: { cancelMove() },
                    onDeselectEdit: { deselectEdit() },
                    onCancelEdit: { cancelDraft() })
                    .frame(height: 72)
                    .contextMenu {
                        Button("Hold current framing") { holdCurrentFraming() }
                            .help("Keep this view still until the playhead before a later smooth movement.")
                        Divider()
                        Button("Reset trim") { setTrim(0, editor.project.duration) }
                            .disabled(state.trimStart == 0 && state.trimEnd == editor.project.duration)
                    }
                Text("\(playback.time, specifier: "%.2f") / \(editor.project.duration, specifier: "%.2f") s")
                    .monospacedDigit().font(.caption).frame(width: 130, alignment: .trailing)
            }
            editList
        }
    }

    private func setTrim(_ start: Double, _ end: Double) {
        playback.pause()
        guard editor.finishDraft() else { return }
        selectedEditID = nil
        var edited = state
        edited.trimStart = start
        edited.trimEnd = end
        editor.commit(edited, name: "Trim")
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Edit", selection: $selectedInspector) {
                ForEach(EditorInspector.allCases.filter { $0 != .camera || editor.project.cameraFilename != nil }, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300, height: 24)
            Group {
                switch selectedInspector {
                case .zoom: zoomControls
                case .pointer: pointerControls
                case .camera: cameraControls
                }
            }
            // Each inspector keeps the same allocation. Controls cannot take
            // space from the preview when playback updates their values.
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 176, alignment: .top)
        }
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var zoomControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CommitSlider(title: "Zoom", value: zoom.scale, range: 1...3, valueSuffix: "×", begin: { beginZoomGesture() }, preview: { value in
                    var next = zoom; next.scale = value
                    setZoom(next, at: dragTime, name: "Edit")
                }) { value in
                    var next = zoom; next.scale = value
                    setZoom(next, at: dragTime, name: "Zoom recording")
                }
                .frame(width: 285)
                .help("Change the magnification at the current video time. Pinch to zoom; use two fingers to pan. Double-click also zooms where you click.")
                Button("Full frame") { setZoom(ZoomPlacement(), at: editTime, name: "Zoom out") }
                    .help("Show the whole recording at this time, without zooming or panning.")
                Button("Center view") {
                    var next = zoom; next.x = 0.5; next.y = 0.5
                    setZoom(next, at: editTime, name: "Center zoom")
                }
                .help("Keep the current magnification and move the view to the center of the recording.")
                Menu("Suggest zooms") {
                    ForEach([CursorZoomSuggestions.Preset.subtle, .focused], id: \.self) { preset in
                        Button("\(preset.title) (\(String(format: "%.1f", preset.scale))×)") { suggestZooms(preset) }
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
            }.frame(height: 24)
            transitionControls(camera: false)
        }
    }

    private var editList: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(edits) { edit in
                        HStack(spacing: 6) {
                            Button { selectEdit(edit.id) } label: {
                                Label("\(edit.time, specifier: "%.2f") s · \(editSummary(edit))", systemImage: "diamond.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Select this edit and show its frame. Drag its diamond on the timeline to change its time.")
                            Button { removeEdit(edit) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove edit at \(String(format: "%.2f", edit.time)) seconds")
                                .help("Remove this edit's view and camera changes. Undo restores them.")
                        }
                        .font(.caption).padding(.leading, 10).padding(.trailing, 4).frame(height: 28)
                        .foregroundStyle(selectedEditID == edit.id ? Color.primary : Color.secondary)
                        .background(selectedEditID == edit.id ? Color.purple.opacity(0.25) : Color.primary.opacity(0.04), in: Capsule())
                        .overlay(Capsule().strokeBorder(selectedEditID == edit.id ? Color.purple : Color.clear, lineWidth: 2))
                        .id(edit.id)
                    }
                }
            }
            .onChange(of: selectedEditID) { _, id in if let id { reader.scrollTo(id, anchor: .center) } }
        }
        .frame(height: 34)
    }

    private func editSummary(_ edit: TimedEdit) -> String {
        let view = state.zoomKeyframes.first { $0.id == edit.zoomID }
        if let view { return String(format: "%.2f×", view.scale) + (edit.cameraID == nil ? "" : " · Camera") }
        return "Camera"
    }

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
            help: "Edit at \(String(format: "%.2f", edit.time)) seconds: \(editSummary(edit)). Click to select; drag to move.",
            transitionStart: transition == .smooth ? start : nil, easeIn: ramps.easeIn, easeOut: ramps.easeOut,
            minimumTime: edit.cameraID == nil ? 0 : frameDuration,
            maximumTime: editor.project.editingTime(at: editor.project.duration, frameDuration: frameDuration))
    }

    private func selectEdit(_ id: UUID) {
        if id == selectedEditID { playback.pause(); return }
        guard editor.finishDraft(), let edit = edits.first(where: { $0.id == id }) else { return }
        selectedEditID = id
        if edit.zoomID == nil { selectedInspector = .camera }
        else if edit.cameraID == nil { selectedInspector = .zoom }
        playback.pause()
        playback.seek(edit.time)
    }

    private func deselectEdit() {
        playback.pause()
        guard editor.finishDraft() else { return }
        selectedEditID = nil
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
            playback.seek(time)
        } else {
            _ = editor.updateDraft(next, at: edit.time)
            playback.seek(time)
        }
    }

    private func cancelMove() {
        movingEditState = nil
        _ = editor.cancelDraft()
        if let selectedEdit { playback.seek(selectedEdit.time) }
        selectedEditID = nil
        playback.cancelPreview()
    }

    private func cancelDraft() {
        _ = editor.cancelDraft()
        selectedEditID = nil
        playback.cancelPreview()
    }

    private func togglePlayback() {
        if playback.isPlaying { playback.pause(); return }
        let hasDraft = editor.draftState != nil
        playAfterRebuild = hasDraft
        guard editor.finishDraft() else { playAfterRebuild = false; return }
        selectedEditID = nil
        if !hasDraft { playback.togglePlayback() }
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
                CommitSlider(title: "Size", value: state.cursorStyle.size, range: 1...4, valueSuffix: "×", begin: { playback.pause() }, preview: { value in
                    var next = state; next.cursorStyle.size = value; playback.preview(next)
                }) { value in
                    var next = state.cursorStyle; next.size = value
                    setCursorStyle(next, name: "Resize pointer")
                }.frame(width: 300)
                Spacer()
            }.frame(height: 24)
            CommitSlider(title: "Smoothing", value: state.cursorStyle.smoothing, range: 0...1, begin: { playback.pause() }, preview: { value in
                var next = state; next.cursorStyle.smoothing = value; playback.preview(next)
            }) { value in
                var next = state.cursorStyle; next.smoothing = value
                setCursorStyle(next, name: "Smooth pointer")
            }.frame(width: 300, height: 24)
        }
        .disabled(editor.project.cursorFilename == nil)
        .help(editor.project.cursorFilename == nil ? "Record a new clip to edit its pointer." : "Size and smoothing affect the recorded pointer. Click highlights mark mouse presses.")
    }

    private func suggestZooms(_ preset: CursorZoomSuggestions.Preset) {
        guard let recording = playback.cursorRecording else { return }
        playback.pause()
        var next = state
        next.zoomKeyframes = CursorZoomSuggestions.points(in: recording,
            range: state.trimStart...state.trimEnd, preset: preset,
            frameDuration: playback.player.currentItem?.videoComposition?.frameDuration.seconds ?? 1.0 / 30)
        if editor.commit(next, name: "Suggest zooms") { selectedEditID = nil }
    }

    private func beginZoomGesture() {
        playback.pause()
        dragTime = editTime
        selectedInspector = .zoom
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
            easeOut: existing == nil ? zoomEaseOut : existing?.easeOut))
        next.zoomKeyframes.sort { $0.time < $1.time }
        return next
    }

    private func setZoom(_ placement: ZoomPlacement, at time: Double, name: String) {
        playback.pause()
        let next = applyingZoom(placement, at: time)
        guard next != state else { return }
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
        _ = editor.updateDraft(next, at: point.time)
    }

    private func setCursorStyle(_ style: CursorStyle, name: String) {
        playback.pause()
        var next = state
        next.cursorStyle = style
        if !editor.commit(next, name: name) { playback.cancelPreview() }
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Visible", isOn: Binding(get: { placement.visible }, set: { value in
                    var next = placement; next.visible = value
                    setPlacement(next, at: editTime, name: value ? "Show camera" : "Hide camera")
                })).toggleStyle(.checkbox)
                    .help("Show or hide the camera at the current video time.")
                Spacer()
            }
            .frame(height: 24)
            HStack(spacing: 12) {
                Picker("Shape", selection: Binding(get: { placement.shape }, set: { shape in
                    var next = placement
                    if shape == .rectangle {
                        let frame = placement.frame(in: playback.screenSize, cameraAspect: playback.cameraAspect)
                        next.aspectRatio = min(5, max(0.2, frame.width / frame.height))
                    }
                    next.shape = shape
                    setPlacement(next, at: editTime, name: "Change camera shape")
                })) {
                    ForEach(PIPShape.allCases, id: \.rawValue) { shape in Text(shape.title).tag(shape) }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
                .help("Change the camera's outline at the current video time. Square and Circle crop the source without stretching it.")
                Group {
                    Button("Framing…") { openFraming() }
                        .help("Zoom or reposition the original camera image inside its outline.")
                        .popover(isPresented: $isFramingPresented) {
                            CameraFramingPopover(image: cameraFrame, errorMessage: cameraFrameError,
                                placement: state.placement(at: framingTime), preview: { crop in
                                    var next = state.placement(at: framingTime)
                                    next.crop = crop
                                    setPlacement(next, at: framingTime, name: "Edit")
                                }, zoomPreview: { value in
                                    var next = state.placement(at: framingTime)
                                    next.sourceZoom = value
                                    setPlacement(next, at: framingTime, name: "Edit")
                                }, zoomCommit: { value in
                                    var next = state.placement(at: framingTime)
                                    next.sourceZoom = value
                                    setPlacement(next, at: framingTime, name: "Zoom camera")
                                }) { crop in
                                    var next = state.placement(at: framingTime)
                                    next.crop = crop
                                    setPlacement(next, at: framingTime, name: "Frame camera")
                            }
                            .task(id: framingTime) { await loadCameraFrame(at: framingTime) }
                        }
                }
                Spacer()
            }
            .frame(height: 24)
            HStack(spacing: 12) {
                ForEach(0..<4) { index in
                    Button {
                        var next = placement
                        next.x = index % 2 == 0 ? 0.04 : 0.96
                        next.y = index < 2 ? 0.04 : 0.96
                        setPlacement(next, at: editTime, name: "Move camera")
                    } label: {
                        Image(systemName: ["arrow.up.left", "arrow.up.right", "arrow.down.left", "arrow.down.right"][index])
                    }
                    .help(["Move camera to the top left", "Move camera to the top right", "Move camera to the bottom left", "Move camera to the bottom right"][index])
                    .accessibilityLabel(["Camera top left", "Camera top right", "Camera bottom left", "Camera bottom right"][index])
                }
                CommitSlider(title: "Size", value: placement.scale, range: 0.12...0.5, begin: { playback.pause() }, preview: { value in
                    var next = placement; next.scale = value
                    setPlacement(next, at: editTime, name: "Edit")
                }) { value in
                    var next = placement; next.scale = value
                    setPlacement(next, at: editTime, name: "Resize camera")
                }.frame(width: 180)
                    .help("Resize the camera overlay at the current video time. Drag any camera corner to resize it directly.")

            }
            .frame(height: 24)
            transitionControls(camera: true)
        }
    }

    private func applying(_ next: PIPPlacement, at position: Double) -> EditState {
        var edited = state
        let time = targetTime(position)
        let existing = edited.pipKeyframes.first { abs($0.time - time) < 0.000001 }
        let group = edits.first { abs($0.time - time) < 0.000001 }
        let keyframe = PIPKeyframe(id: existing?.id ?? group?.id ?? UUID(), time: time, placement: next,
            transition: existing?.transition ?? transition, duration: existing?.duration ?? transitionDuration,
            easeIn: existing == nil ? cameraEaseIn : existing?.easeIn,
            easeOut: existing == nil ? cameraEaseOut : existing?.easeOut)
        edited.pipKeyframes.removeAll { abs($0.time - time) < 0.000001 }
        edited.pipKeyframes.append(keyframe)
        edited.pipKeyframes.sort { $0.time < $1.time }
        return edited
    }

    private func openFraming() {
        playback.pause()
        framingTime = editTime
        cameraFrame = nil
        cameraFrameError = nil
        isFramingPresented = true
    }

    private func loadCameraFrame(at time: Double) async {
        do {
            let image = try await playback.cameraFrame(at: time)
            guard !Task.isCancelled, isFramingPresented, time == framingTime else { return }
            cameraFrame = image
            if image == nil { cameraFrameError = "No camera frame is available at this time." }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, isFramingPresented, time == framingTime else { return }
            cameraFrameError = error.localizedDescription
        }
    }

    private func setPlacement(_ next: PIPPlacement, at time: Double, name: String) {
        playback.pause()
        let edited = applying(next, at: time)
        guard edited != state else { return }
        if editor.updateDraft(edited, at: targetTime(time)) {
            selectedEditID = edited.timedEdits(includeCamera: editor.project.cameraFilename != nil).first { abs($0.time - targetTime(time)) < 0.000001 }?.id
        }
    }

    private func updateSelected(_ update: (inout PIPKeyframe) -> Void) {
        guard var selected = point else { return }
        playback.pause()
        update(&selected)
        var edited = state
        if let index = edited.pipKeyframes.firstIndex(where: { $0.id == selected.id }) { edited.pipKeyframes[index] = selected }
        _ = editor.updateDraft(edited, at: selected.time)
    }

    private func transitionControls(camera: Bool) -> some View {
        let mode = camera ? point?.transition ?? transition : zoomPoint?.transition ?? zoomTransition
        let requested = camera ? point?.duration ?? transitionDuration : zoomPoint?.duration ?? zoomDuration
        let previous = camera ? state.pipKeyframes.last(where: { $0.time < editTime })?.time ?? 0
                              : state.zoomKeyframes.last(where: { $0.time < editTime })?.time ?? 0
        let span = max(0, min(requested, editTime - previous))
        let hasComponent = camera ? point != nil : zoomPoint != nil
        let easeIn = camera ? point?.easeIn : zoomPoint?.easeIn
        let easeOut = camera ? point?.easeOut : zoomPoint?.easeOut
        let ramps = MotionInterpolation.rampDurations(duration: span, easeIn: easeIn, easeOut: easeOut)
        return Group {
            if selectedEdit != nil && hasComponent && editTime > previous {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Picker("Movement", selection: Binding(get: { mode }, set: { value in
                            if camera { transition = value; updateSelected { $0.transition = value } }
                            else { zoomTransition = value; updateZoomPoint { $0.transition = value } }
                        })) {
                            Text("Jump").tag(PIPTransition.jump)
                            Text("Smooth").tag(PIPTransition.smooth)
                        }
                        .frame(width: 185)
                        .help("Jump applies this edit instantly. Smooth accelerates, moves at steady speed, and decelerates to arrive at this edit.")
                        if mode == .smooth {
                            Text("Duration").font(.caption)
                            MotionDurationField(value: requested, maximum: max(editor.project.duration, requested), change: { value in
                                if camera { transitionDuration = value; updateSelected { $0.duration = value } }
                                else { zoomDuration = value; updateZoomPoint { $0.duration = value } }
                            }, cancel: { cancelDraft() })
                                .frame(width: 64, height: 24)
                                .help("Total movement time in seconds. The previous edit limits how much of this time is available.")
                            Text("s").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.frame(height: 24)
                    if mode == .smooth {
                        MotionRampStrip(duration: span, easeIn: ramps.easeIn, easeOut: ramps.easeOut,
                            change: { incoming, value in setRamp(value, camera: camera, incoming: incoming, span: span, other: incoming ? ramps.easeOut : ramps.easeIn) })
                            .frame(width: 526, height: 32)
                            .help("Drag the left boundary to adjust acceleration, or the right boundary to adjust deceleration. The middle moves at steady speed. The strip shows the time available before this edit.")
                    }
                }
            }
        }
        // Keep selection changes from moving the recording or timeline.
        .frame(height: 64, alignment: .topLeading)
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

    private func export() async {
        playback.pause()
        guard editor.finishDraft() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Explanation.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            guard editor.save() else { return }
            try await ProjectRenderer.export(project: editor.project,
                directory: editor.url.deletingLastPathComponent(), to: url)
        } catch { exportError = error.localizedDescription }
    }
}

struct ProjectUndoButtons: View {
    @ObservedObject var editor: ProjectEditor
    var body: some View {
        Group {
            Button("Undo") { editor.undo() }.disabled(!editor.canUndo)
            Button("Redo") { editor.redo() }.disabled(!editor.canRedo)
        }
    }
}

/// The two boundaries divide acceleration, constant speed, and deceleration.
private struct MotionRampStrip: View {
    let duration: Double
    let easeIn: Double
    let easeOut: Double
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
                        let speed: Double
                        if easeIn > 0 && time < easeIn { speed = (1 - cos(.pi * time / easeIn)) / 2 }
                        else if easeOut > 0 && time > span - easeOut { speed = (1 - cos(.pi * (span - time) / easeOut)) / 2 }
                        else { speed = 1 }
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
                        .help("\(incomingHandle ? "Acceleration" : "Deceleration"): \(String(format: "%.2f", incomingHandle ? easeIn : easeOut)) seconds. Drag to adjust.")
                        .accessibilityElement()
                        .accessibilityLabel(incomingHandle ? "Acceleration" : "Deceleration")
                        .accessibilityValue("\(String(format: "%.2f", incomingHandle ? easeIn : easeOut)) seconds")
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

/// Slider release finishes a gesture; the editor decides its undo boundary.
struct CommitSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var valueSuffix: String? = nil
    var begin: () -> Void = {}
    var preview: ((Double) -> Void)? = nil
    var commit: (Double) -> Void
    @State private var draft = 0.0
    @State private var editing = false
    var body: some View {
        HStack {
            Text(title).font(.caption)
            Slider(value: $draft, in: range) { active in
                editing = active
                if active { begin() } else { commit(draft) }
            }.accessibilityLabel(title)
            if let valueSuffix {
                Text("\(editing ? draft : value, specifier: "%.2f")\(valueSuffix)")
                    .font(.caption).monospacedDigit().frame(width: 45, alignment: .trailing)
            }
        }
        .onChange(of: draft) { _, next in if editing { preview?(next) } }
        .onAppear { draft = min(max(value, range.lowerBound), range.upperBound) }
        .onChange(of: value) { _, next in if !editing { draft = min(max(next, range.lowerBound), range.upperBound) } }
    }
}

