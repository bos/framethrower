import SwiftUI

struct ProjectEditorView: View {
    @ObservedObject var editor: ProjectEditor
    @StateObject private var playback = EditorPlayback()
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

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                ProjectUndoButtons(editor: editor)
                Spacer()
                Button("Export…") { Task { await export() } }.disabled(isExporting || playback.isLoading)
            }
            player
            timeline
            if editor.project.cameraFilename != nil { cameraControls }
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
            onBegin: { playback.pause(); dragTime = playback.editingTime },
            onPreview: { next in playback.preview(applying(next, at: dragTime)) },
            onCommit: { next, name in setPlacement(next, at: dragTime, name: name) },
            onCancel: { playback.cancelPreview() })
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
                .disabled(playback.isLoading || playback.errorMessage != nil)
                RecordingTimeline(duration: editor.project.duration, trimStart: state.trimStart,
                    trimEnd: state.trimEnd, playhead: playback.time,
                    onInteractionBegan: { playback.pause() },
                    onSeek: { playback.scrub(to: $0) },
                    onScrubBegan: { playback.beginScrubbing() },
                    onScrubEnded: { playback.endScrubbing() },
                    onTrim: { start, end in setTrim(start, end) })
                    .frame(height: 36)
                    .help("Click or drag to scrub. Drag the blue handles to trim.")
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

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Camera").font(.headline)
                Toggle("Visible", isOn: Binding(get: { placement.visible }, set: { value in
                    var next = placement; next.visible = value
                    setPlacement(next, at: playback.time, name: value ? "Show camera" : "Hide camera")
                })).toggleStyle(.checkbox)
                Spacer()
            }
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
                if placement.shape != .original {
                    Button("Framing…") { openFraming() }
                        .popover(isPresented: $isFramingPresented) {
                            CameraFramingPopover(image: cameraFrame, errorMessage: cameraFrameError,
                                placement: state.placement(at: framingTime), preview: { crop in
                                    var next = state.placement(at: framingTime)
                                    next.crop = crop
                                    playback.preview(applying(next, at: framingTime))
                                }) { crop in
                                    var next = state.placement(at: framingTime)
                                    next.crop = crop
                                    setPlacement(next, at: framingTime, name: "Frame camera")
                            }
                        }
                }
                Spacer()
                if placement.shape == .rectangle {
                    Text("Drag the corner to resize freely.").font(.caption).foregroundStyle(.secondary)
                }
            }
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
                    .help(["Top left", "Top right", "Bottom left", "Bottom right"][index])
                    .accessibilityLabel(["Camera top left", "Camera top right", "Camera bottom left", "Camera bottom right"][index])
                }
                CommitSlider(title: "Size", value: placement.scale, range: 0.12...0.5, begin: { playback.pause() }, preview: { value in
                    var next = placement; next.scale = value
                    playback.preview(applying(next, at: playback.editingTime))
                }) { value in
                    var next = placement; next.scale = value
                    setPlacement(next, at: playback.time, name: "Resize camera")
                }.frame(width: 180)
                Picker("Arrive", selection: Binding(get: { point?.transition ?? transition }, set: { value in
                    transition = value
                    updateSelected { $0.transition = value }
                })) {
                    Text("Jump").tag(PIPTransition.jump)
                    Text("Smooth").tag(PIPTransition.smooth)
                }.frame(width: 155)
                CommitSlider(title: "Duration", value: point?.duration ?? transitionDuration, range: 0.1...3, begin: { playback.pause() }) { value in
                    transitionDuration = value
                    updateSelected { $0.duration = value }
                }
                    .frame(width: 170)
                    .opacity((point?.transition ?? transition) == .smooth ? 1 : 0)
                    .disabled((point?.transition ?? transition) != .smooth)
                    .accessibilityHidden((point?.transition ?? transition) != .smooth)
            }
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
                    }
                    if let point, point.time > 0 {
                        Button("Delete point") {
                            var next = state
                            next.pipKeyframes.removeAll { $0.id == point.id }
                            if editor.commit(next, name: "Delete camera point") { selectedPoint = nil }
                        }.font(.caption)
                    }
                }
            }
            .frame(height: 32)
            HStack {
                if let point, point.time > 0 {
                    Text("Point time: \(point.time, specifier: "%.2f") s").font(.caption).monospacedDigit()
                    Button("Move point to playhead") {
                        updateSelected { $0.time = playback.editingTime }
                    }.font(.caption).disabled(playback.editingTime <= 0 || abs(playback.editingTime - point.time) < 0.001)
                    if point.transition == .smooth {
                        Text("Smooth movement ends at this point.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 24)
        }
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
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
        let snapshot = editor.project
        let time = framingTime
        Task {
            do {
                cameraFrame = try await ProjectRenderer.cameraFrame(project: snapshot,
                    directory: editor.url.deletingLastPathComponent(), at: time)
                if cameraFrame == nil { cameraFrameError = "No camera frame is available at this time." }
            } catch { cameraFrameError = error.localizedDescription }
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
        editor.commit(edited, name: "Change camera point")
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
        }
        .onChange(of: draft) { _, next in if editing { preview?(next) } }
        .onAppear { draft = min(max(value, range.lowerBound), range.upperBound) }
        .onChange(of: value) { _, next in if !editing { draft = min(max(next, range.lowerBound), range.upperBound) } }
    }
}

