import SwiftUI

private enum EditorInspector: String, CaseIterable {
    case zoom = "Zoom", pointer = "Pointer", camera = "Camera"
}

struct ProjectEditorView: View {
    @ObservedObject var editor: ProjectEditor
    @StateObject private var playback = EditorPlayback()
    @State private var selectedInspector: EditorInspector = .zoom
    @State private var selectedZoomPoint: UUID?
    @State private var zoomTransition: PIPTransition = .smooth
    @State private var zoomDuration = 0.4
    @State private var selectedPoint: UUID?
    @State private var transition: PIPTransition = .jump
    @State private var transitionDuration = 0.6
    @State private var dragTime = 0.0
    @State private var isFramingPresented = false
    @State private var framingTime = 0.0
    @State private var cameraFrame: CGImage?
    @State private var cameraFrameError: String?
    @State private var exportError: String?
    @State private var isExporting = false

    private var state: EditState { editor.project.state }
    private var point: PIPKeyframe? { state.pipKeyframes.first { $0.id == selectedPoint } }
    private var placement: PIPPlacement { state.placement(at: playback.editingTime) }
    private var zoom: ZoomPlacement { state.zoom(at: playback.editingTime) }
    private var zoomPoint: ZoomKeyframe? { state.zoomKeyframes.first { $0.id == selectedZoomPoint } }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                ProjectUndoButtons(editor: editor)
                Spacer()
                Button("Export…") { Task { await export() } }.disabled(isExporting || playback.isLoading)
            }
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
        .task { await playback.rebuild(editor: editor) }
        .onChange(of: editor.project.state) { _, _ in
            Task { await playback.rebuild(editor: editor) }
            if let selectedZoomPoint, !state.zoomKeyframes.contains(where: { $0.id == selectedZoomPoint }) {
                self.selectedZoomPoint = nil
            }
            if let selectedPoint, !state.pipKeyframes.contains(where: { $0.id == selectedPoint }) {
                self.selectedPoint = nil
            }
        }
        .onDisappear { playback.close() }
        .disabled(isExporting)
    }

    private var player: some View {
        EditorCanvas(player: playback.player, frames: playback.frameStore,
            sourceSize: playback.screenSize, cameraAspect: playback.cameraAspect,
            placement: placement, cameraEnabled: editor.project.cameraFilename != nil && !playback.isScrubbing,
            showsStill: !playback.isPlaying,
            onBegin: { playback.pause(); dragTime = playback.editingTime; selectedInspector = .camera },
            onPreview: { next in playback.preview(applying(next, at: dragTime)) },
            onCommit: { next, name in setPlacement(next, at: dragTime, name: name) },
            onCancel: { playback.cancelPreview() },
            zoom: zoom, allowsZoomEditing: !playback.isLoading && !playback.isScrubbing,
            onZoomBegin: { beginZoomGesture() },
            onZoomPreview: { next in playback.preview(applyingZoom(next, at: dragTime)) },
            onZoomCommit: { next, name in setZoom(next, at: dragTime, name: name) })
            .frame(minHeight: 260, idealHeight: 310, maxHeight: .infinity)
            .overlay { if playback.isLoading { ProgressView().padding().background(.regularMaterial, in: Capsule()) } }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var timeline: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { playback.togglePlayback() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
                }
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!playback.canPlay)
                RecordingTimeline(duration: editor.project.duration, trimStart: state.trimStart,
                    trimEnd: state.trimEnd, playhead: playback.time,
                    onInteractionBegan: { playback.pause() },
                    onSeek: { playback.scrub(to: $0) },
                    onScrubBegan: { playback.beginScrubbing() },
                    onScrubEnded: { playback.endScrubbing() },
                    onTrim: { start, end in setTrim(start, end) },
                    zoomChanges: state.zoomKeyframes.map { RecordingTimelineMarker(id: $0.id, time: $0.time, help: zoomChangeHelp($0)) },
                    selectedZoomChangeID: selectedZoomPoint,
                    onSelectZoomChange: { selectZoomChange($0) })
                    .frame(height: 36)
                    .contextMenu {
                        Button("Reset trim") { setTrim(0, editor.project.duration) }
                            .disabled(state.trimStart == 0 && state.trimEnd == editor.project.duration)
                    }
                Text("\(playback.time, specifier: "%.2f") / \(editor.project.duration, specifier: "%.2f") s")
                    .monospacedDigit().font(.caption).frame(width: 130, alignment: .trailing)
            }
        }
    }

    private func setTrim(_ start: Double, _ end: Double) {
        playback.pause()
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
                    playback.preview(applyingZoom(next, at: dragTime))
                }) { value in
                    var next = zoom; next.scale = value
                    setZoom(next, at: dragTime, name: "Zoom recording")
                }
                .frame(width: 285)
                .help("Change the magnification at the current video time. Double-click the video to zoom where you click; drag a zoomed view to pan.")
                Button("Full frame") { setZoom(ZoomPlacement(), at: playback.editingTime, name: "Zoom out") }
                    .help("Show the whole recording at this time, without zooming or panning.")
                Button("Center view") {
                    var next = zoom; next.x = 0.5; next.y = 0.5
                    setZoom(next, at: playback.editingTime, name: "Center zoom")
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
                        if editor.commit(next, name: "Remove zooms") { selectedZoomPoint = nil }
                    }
                    .disabled(state.zoomKeyframes.isEmpty)
                    .help("Show the full recording throughout. Undo restores the removed zoom changes.")
                }
                .fixedSize()
                .help(playback.cursorRecording == nil ? "Zoom suggestions need a new recording with pointer tracking." : "Suggest editable zoom changes around recorded mouse clicks. Replaces existing changes; Undo restores them.")
                Spacer(minLength: 0)
            }.frame(height: 24)
            HStack(spacing: 12) {
                Picker("Movement", selection: Binding(get: { zoomPoint?.transition ?? zoomTransition }, set: { value in
                    zoomTransition = value
                    updateZoomPoint { $0.transition = value }
                })) {
                    Text("Jump").tag(PIPTransition.jump)
                    Text("Smooth").tag(PIPTransition.smooth)
                }
                .frame(width: 185)
                .help("Jump switches instantly at the change's time. Smooth moves into that view over the chosen duration. Without a selection, this sets the movement for new changes.")
                CommitSlider(title: "Duration", value: zoomPoint?.duration ?? zoomDuration, range: 0.1...3, valueSuffix: " s",
                    begin: { playback.pause() }) { value in
                    zoomDuration = value
                    updateZoomPoint { $0.duration = value }
                }
                .frame(width: 240)
                .opacity((zoomPoint?.transition ?? zoomTransition) == .smooth ? 1 : 0)
                .disabled((zoomPoint?.transition ?? zoomTransition) != .smooth)
                .accessibilityHidden((zoomPoint?.transition ?? zoomTransition) != .smooth)
                .help("How many seconds the view takes to reach this zoom change. The movement finishes at the change's time.")
                Button("Add zoom change") { setZoom(zoom, at: playback.editingTime, name: "Add zoom change") }
                    .help("Remember the current magnification and framing at the current video time. Later smooth movements can start from this view.")
                Spacer(minLength: 0)
            }.frame(height: 24)
            HStack(spacing: 12) {
                Label("Zoom changes", systemImage: "diamond.fill")
                    .font(.caption).foregroundStyle(.purple).fixedSize()
                    .help("Each purple diamond remembers a zoomed view at a particular time. Matching diamonds appear on the timeline.")
                if state.zoomKeyframes.isEmpty {
                    Text("Double-click the video to zoom; drag a zoomed view to pan.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(state.zoomKeyframes) { change in
                                Button { selectZoomChange(change.id) } label: {
                                    Label {
                                        Text("\(change.time, specifier: "%.2f") s · \(change.scale, specifier: "%.2f")×")
                                    } icon: {
                                        Image(systemName: "diamond.fill").foregroundStyle(.purple)
                                    }
                                    .font(.caption).padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(selectedZoomPoint == change.id ? Color.purple.opacity(0.2) : Color.primary.opacity(0.05), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(zoomChangeHelp(change))
                            }
                        }
                    }
                }
            }.frame(height: 32)
            HStack(spacing: 12) {
                if let zoomPoint {
                    Text("At \(zoomPoint.time, specifier: "%.2f") s").font(.caption).monospacedDigit()
                    Button("Use current time") { updateZoomPoint { $0.time = playback.editingTime } }
                        .disabled(abs(playback.editingTime - zoomPoint.time) < 0.001)
                        .help("Move this zoom change to the current video time. Its magnification and framing stay the same.")
                    Button("Remove zoom change") {
                        playback.pause()
                        var next = state
                        next.zoomKeyframes.removeAll { $0.id == zoomPoint.id }
                        if editor.commit(next, name: "Remove zoom change") { selectedZoomPoint = nil }
                    }
                    .help("Remove the selected zoom change. Undo restores it.")
                }
                Spacer(minLength: 0)
            }.font(.caption).frame(height: 24)
        }
    }

    private func zoomChangeHelp(_ change: ZoomKeyframe) -> String {
        "Zoom change at \(String(format: "%.2f", change.time)) seconds: \(String(format: "%.2f", change.scale))×. Click to visit and edit this view."
    }

    private func selectZoomChange(_ id: UUID) {
        guard let change = state.zoomKeyframes.first(where: { $0.id == id }) else { return }
        selectedInspector = .zoom
        selectedZoomPoint = change.id
        zoomTransition = change.transition
        zoomDuration = change.duration
        playback.pause()
        playback.seek(change.time)
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
        if editor.commit(next, name: "Suggest zooms") { selectedZoomPoint = nil }
    }

    private func beginZoomGesture() {
        playback.pause()
        dragTime = playback.editingTime
        selectedInspector = .zoom
    }

    private func applyingZoom(_ placement: ZoomPlacement, at position: Double) -> EditState {
        let time = editor.project.editingTime(at: position,
            frameDuration: playback.player.currentItem?.videoComposition?.frameDuration.seconds ?? 1.0 / 30)
        var next = state
        let existing = next.zoomKeyframes.first { abs($0.time - time) < 0.001 }
        let placement = placement.clamped
        next.zoomKeyframes.removeAll { abs($0.time - time) < 0.001 }
        next.zoomKeyframes.append(ZoomKeyframe(id: existing?.id ?? UUID(), time: existing?.time ?? time,
            scale: placement.scale, x: placement.x, y: placement.y,
            transition: existing?.transition ?? zoomTransition, duration: existing?.duration ?? zoomDuration))
        next.zoomKeyframes.sort { $0.time < $1.time }
        return next
    }

    private func setZoom(_ placement: ZoomPlacement, at time: Double, name: String) {
        playback.pause()
        let next = applyingZoom(placement, at: time)
        if next == state { playback.cancelPreview(); return }
        if editor.commit(next, name: name) {
            let normalized = editor.project.editingTime(at: time,
                frameDuration: playback.player.currentItem?.videoComposition?.frameDuration.seconds ?? 1.0 / 30)
            selectedZoomPoint = next.zoomKeyframes.first { abs($0.time - normalized) < 0.001 }?.id
        } else { playback.cancelPreview() }
    }

    private func updateZoomPoint(_ change: (inout ZoomKeyframe) -> Void) {
        guard var point = zoomPoint else { return }
        playback.pause()
        change(&point)
        var next = state
        next.zoomKeyframes.removeAll { $0.id == point.id || abs($0.time - point.time) < 0.001 }
        next.zoomKeyframes.append(point)
        next.zoomKeyframes.sort { $0.time < $1.time }
        editor.commit(next, name: "Edit zoom change")
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
                    setPlacement(next, at: playback.time, name: value ? "Show camera" : "Hide camera")
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
                    setPlacement(next, at: playback.time, name: "Change camera shape")
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
                                    playback.preview(applying(next, at: framingTime))
                                }, zoomPreview: { value in
                                    var next = state.placement(at: framingTime)
                                    next.sourceZoom = value
                                    playback.preview(applying(next, at: framingTime))
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
                            .onDisappear { playback.cancelPreview() }
                        }
                }
                Spacer()
                if placement.shape == .rectangle {
                    Text("Drag the corner to resize freely.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 24)
            HStack(spacing: 12) {
                ForEach(0..<4) { index in
                    Button {
                        var next = placement
                        next.x = index % 2 == 0 ? 0.04 : 0.96
                        next.y = index < 2 ? 0.04 : 0.96
                        setPlacement(next, at: playback.time, name: "Move camera")
                    } label: {
                        Image(systemName: ["arrow.up.left", "arrow.up.right", "arrow.down.left", "arrow.down.right"][index])
                    }
                    .help(["Move camera to the top left", "Move camera to the top right", "Move camera to the bottom left", "Move camera to the bottom right"][index])
                    .accessibilityLabel(["Camera top left", "Camera top right", "Camera bottom left", "Camera bottom right"][index])
                }
                CommitSlider(title: "Size", value: placement.scale, range: 0.12...0.5, begin: { playback.pause() }, preview: { value in
                    var next = placement; next.scale = value
                    playback.preview(applying(next, at: playback.editingTime))
                }) { value in
                    var next = placement; next.scale = value
                    setPlacement(next, at: playback.time, name: "Resize camera")
                }.frame(width: 180)
                    .help("Resize the camera overlay at the current video time. Drag any camera corner to resize it directly.")
                Picker("Movement", selection: Binding(get: { point?.transition ?? transition }, set: { value in
                    transition = value
                    updateSelected { $0.transition = value }
                })) {
                    Text("Jump").tag(PIPTransition.jump)
                    Text("Smooth").tag(PIPTransition.smooth)
                }.frame(width: 155)
                    .help("Jump switches instantly at the camera change's time. Smooth moves and resizes the camera into that view over the chosen duration.")
                CommitSlider(title: "Duration", value: point?.duration ?? transitionDuration, range: 0.1...3, valueSuffix: " s", begin: { playback.pause() }) { value in
                    transitionDuration = value
                    updateSelected { $0.duration = value }
                }
                    .frame(width: 170)
                    .opacity((point?.transition ?? transition) == .smooth ? 1 : 0)
                    .disabled((point?.transition ?? transition) != .smooth)
                    .accessibilityHidden((point?.transition ?? transition) != .smooth)
                    .help("How many seconds the camera takes to reach this change. The movement finishes at the change's time.")
            }
            .frame(height: 24)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(state.pipKeyframes) { keyframe in
                        Button {
                            selectedPoint = keyframe.id
                            transition = keyframe.transition
                            transitionDuration = keyframe.duration
                            playback.pause(); playback.seek(keyframe.time)
                        } label: {
                            Text("\(keyframe.time, specifier: "%.2f")s · \(keyframe.placement.shape.title) · \(keyframe.time == 0 ? "Initial" : keyframe.transition.rawValue.capitalized)")
                                .font(.caption).padding(.horizontal, 9).padding(.vertical, 6)
                                .background(selectedPoint == keyframe.id ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05),
                                            in: Capsule())
                        }.buttonStyle(.plain)
                            .help("Camera change at \(String(format: "%.2f", keyframe.time)) seconds. Click to visit and edit its position, size, shape, and framing.")
                    }
                    if let point, point.time > 0 {
                        Button("Remove camera change") {
                            var next = state
                            next.pipKeyframes.removeAll { $0.id == point.id }
                            if editor.commit(next, name: "Remove camera change") { selectedPoint = nil }
                        }.font(.caption)
                            .help("Remove this camera change. Undo restores it.")
                    }
                }
            }
            .frame(height: 32)
            HStack {
                if let point, point.time > 0 {
                    Text("At \(point.time, specifier: "%.2f") s").font(.caption).monospacedDigit()
                    Button("Use current time") {
                        updateSelected { $0.time = playback.editingTime }
                    }.font(.caption).disabled(playback.editingTime <= 0 || abs(playback.editingTime - point.time) < 0.001)
                        .help("Move the selected camera change to the current video time, keeping its position, size, shape, and framing.")
                    if point.transition == .smooth {
                        Text("Movement finishes at this time.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24)
        }
    }

    private func applying(_ next: PIPPlacement, at time: Double) -> EditState {
        var edited = state
        let time = editor.project.editingTime(at: time,
            frameDuration: playback.player.currentItem?.videoComposition?.frameDuration.seconds ?? 1.0 / 30)
        let existing = edited.pipKeyframes.first { abs($0.time - time) < 0.001 }
        let keyframe = PIPKeyframe(id: existing?.id ?? UUID(), time: existing?.time ?? time, placement: next,
            transition: existing?.transition ?? transition, duration: existing?.duration ?? transitionDuration)
        edited.pipKeyframes.removeAll { abs($0.time - time) < 0.001 }
        edited.pipKeyframes.append(keyframe)
        edited.pipKeyframes.sort { $0.time < $1.time }
        return edited
    }

    private func openFraming() {
        playback.pause()
        framingTime = playback.editingTime
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
        guard edited != state else { playback.cancelPreview(); return }
        if editor.commit(edited, name: name) {
            let normalized = editor.project.editingTime(at: time,
                frameDuration: playback.player.currentItem?.videoComposition?.frameDuration.seconds ?? 1.0 / 30)
            selectedPoint = edited.pipKeyframes.first { abs($0.time - normalized) < 0.001 }?.id
        } else { playback.cancelPreview() }
    }

    private func updateSelected(_ update: (inout PIPKeyframe) -> Void) {
        guard var selected = point else { return }
        playback.pause()
        update(&selected)
        var edited = state
        edited.pipKeyframes.removeAll { $0.id == selected.id || abs($0.time - selected.time) < 0.001 }
        edited.pipKeyframes.append(selected)
        edited.pipKeyframes.sort { $0.time < $1.time }
        editor.commit(edited, name: "Edit camera change")
    }

    private func export() async {
        playback.pause()
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

/// Slider mutations are committed only on release, so one gesture is one undo.
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

