import SwiftUI

struct ProjectEditorView: View {
    @ObservedObject var editor: ProjectEditor
    @StateObject private var playback = EditorPlayback()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPoint: UUID?
    @State private var transition: PIPTransition = .jump
    @State private var transitionDuration = 0.6
    @State private var dragOrigin: PIPPlacement?
    @State private var dragPlacement: PIPPlacement?
    @State private var dragTime = 0.0
    @State private var resizeOrigin: PIPPlacement?
    @State private var isFramingPresented = false
    @State private var framingTime = 0.0
    @State private var cameraFrame: CGImage?
    @State private var cameraFrameError: String?
    @State private var exportError: String?
    @State private var isExporting = false

    private var state: EditState { editor.project.state }
    private var point: PIPKeyframe? { state.pipKeyframes.first { $0.id == selectedPoint } }
    private var placement: PIPPlacement { dragPlacement ?? state.placement(at: playback.time) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review your explanation").font(.title2.weight(.semibold))
                    Text("Edits are saved automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProjectUndoButtons(editor: editor)
                Button("Export…") { Task { await export() } }.disabled(isExporting || playback.isLoading)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            player
            timeline
            if editor.project.cameraFilename != nil { cameraControls }
            if let message = editor.errorMessage ?? playback.errorMessage ?? exportError {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if isExporting { ProgressView("Exporting your edit…") }
        }
        .padding(24)
        .frame(minWidth: 820, idealWidth: 940, minHeight: 680)
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
        GeometryReader { proxy in
            let canvas = fittedSize(in: proxy.size)
            ZStack {
                Color.black
                ZStack {
                    EditorPlayerSurface(player: playback.player)
                    if !playback.isPlaying, let frame = playback.stillFrame {
                        Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    }
                }
                    .frame(width: canvas.width, height: canvas.height)
                    .overlay(alignment: .topLeading) {
                        if editor.project.cameraFilename != nil, placement.visible {
                            let rect = placement.frame(in: canvas, cameraAspect: playback.cameraAspect)
                            PIPWindowShape(shape: placement.shape)
                                .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                .background(PIPWindowShape(shape: placement.shape)
                                    .fill(Color.white.opacity(dragPlacement == nil ? 0.001 : 0.12)))
                                .overlay(alignment: .topLeading) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.caption2).padding(4).background(.black.opacity(0.7))
                                }
                                .frame(width: rect.width, height: rect.height)
                                .overlay(alignment: .bottomTrailing) {
                                    resizeHandle(canvas: canvas)
                                }
                                .offset(x: rect.minX, y: rect.minY)
                                .gesture(DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        guard resizeOrigin == nil else { return }
                                        if dragOrigin == nil {
                                            playback.pause()
                                            dragOrigin = state.placement(at: playback.time)
                                            dragTime = playback.time
                                        }
                                        guard var next = dragOrigin else { return }
                                        next.x += value.translation.width / max(1, canvas.width - rect.width)
                                        next.y += value.translation.height / max(1, canvas.height - rect.height)
                                        next.x = snap(next.x)
                                        next.y = snap(next.y)
                                        dragPlacement = next
                                    }
                                    .onEnded { _ in
                                        guard resizeOrigin == nil else { return }
                                        if let dragPlacement { setPlacement(dragPlacement, at: dragTime, name: "Move camera") }
                                        dragOrigin = nil
                                        dragPlacement = nil
                                    })
                                .accessibilityLabel("Camera position. Drag to move, or use the corner buttons below.")
                        }
                    }
                if playback.isLoading { ProgressView().padding().background(.regularMaterial, in: Capsule()) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 310)
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
                    onSeek: { playback.seek($0) },
                    onTrim: { start, end in setTrim(start, end) })
                    .frame(height: 36)
                    .help("Click or drag to scrub. Drag the blue handles to trim.")
                Text("\(playback.time, specifier: "%.2f") / \(editor.project.duration, specifier: "%.2f") s")
                    .monospacedDigit().font(.caption)
            }
            HStack {
                Text("Keep \(state.trimStart, specifier: "%.2f")–\(state.trimEnd, specifier: "%.2f") s")
                    .font(.caption).monospacedDigit()
                Spacer()
                Button("Start here") {
                    setTrim(min(playback.time, state.trimEnd - minimumTrimLength), state.trimEnd)
                }
                Button("End here") {
                    setTrim(state.trimStart, max(playback.time, state.trimStart + minimumTrimLength))
                }
                Button("Restore full recording") { setTrim(0, editor.project.duration) }
            }.controlSize(.small)
        }
    }

    private var minimumTrimLength: Double { min(0.1, editor.project.duration) }

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
                                placement: state.placement(at: framingTime)) { crop in
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
                CommitSlider(title: "Size", value: placement.scale, range: 0.12...0.5, begin: { playback.pause() }) { value in
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
                if (point?.transition ?? transition) == .smooth {
                    CommitSlider(title: "Duration", value: point?.duration ?? transitionDuration, range: 0.1...3, begin: { playback.pause() }) { value in
                        transitionDuration = value
                        updateSelected { $0.duration = value }
                    }.frame(width: 170)
                }
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
            if let point, point.time > 0 {
                HStack {
                    Text("Point time: \(point.time, specifier: "%.2f") s").font(.caption).monospacedDigit()
                    Button("Move point to playhead") {
                        updateSelected { $0.time = playback.time }
                    }.font(.caption).disabled(playback.time < 0.001 || abs(playback.time - point.time) < 0.001)
                    Text("Smooth movement ends at this point.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func resizeHandle(canvas: CGSize) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            .offset(x: 7, y: 7)
            .help(placement.shape == .rectangle ? "Drag to change camera width and height" : "Drag to resize camera")
            .accessibilityLabel("Resize camera")
            .highPriorityGesture(DragGesture(minimumDistance: 1).onChanged { value in
                if resizeOrigin == nil {
                    playback.pause()
                    resizeOrigin = state.placement(at: playback.time)
                    dragTime = playback.time
                }
                guard let origin = resizeOrigin else { return }
                dragPlacement = origin.resized(by: value.translation, in: canvas, cameraAspect: playback.cameraAspect)
            }.onEnded { _ in
                if let dragPlacement { setPlacement(dragPlacement, at: dragTime, name: "Resize camera") }
                resizeOrigin = nil
                dragPlacement = nil
            })
    }

    private func openFraming() {
        playback.pause()
        framingTime = playback.time
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
        var edited = state
        let existing = edited.pipKeyframes.first { abs($0.time - time) < 0.001 }
        let keyframe = PIPKeyframe(id: existing?.id ?? UUID(), time: existing?.time ?? time, placement: next,
            transition: existing?.transition ?? transition, duration: existing?.duration ?? transitionDuration)
        edited.pipKeyframes.removeAll { abs($0.time - time) < 0.001 }
        edited.pipKeyframes.append(keyframe)
        edited.pipKeyframes.sort { $0.time < $1.time }
        if editor.commit(edited, name: name) { selectedPoint = keyframe.id }
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

    private func fittedSize(in space: CGSize) -> CGSize {
        let scale = min(space.width / playback.screenSize.width, space.height / playback.screenSize.height)
        return CGSize(width: playback.screenSize.width * scale, height: playback.screenSize.height * scale)
    }

    private func snap(_ value: Double) -> Double {
        if value < 0.035 { return 0 }
        if value > 0.965 { return 1 }
        return min(max(value, 0), 1)
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
        .onAppear { draft = min(max(value, range.lowerBound), range.upperBound) }
        .onChange(of: value) { _, next in if !editing { draft = min(max(next, range.lowerBound), range.upperBound) } }
    }
}

