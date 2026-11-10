import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ContentImageImport {
    /// Read bounded immutable bytes and ImageIO header properties only. Pixel
    /// decoding is deferred to the media renderer; suspended previews stay vector.
    static func read(_ url: URL) throws -> ContentImageAsset {
        guard url.isFileURL else { throw ProjectError.invalid("Choose a local image file.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        let before = try FileManager.default.attributesOfItem(atPath: source.path)
        guard before[.type] as? FileAttributeType == .typeRegular,
              let size = before[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= ContentImageAsset.maximumBytes else {
            throw ProjectError.invalid("Choose a readable image of at most 8 MiB.")
        }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var data = Data()
        while data.count <= ContentImageAsset.maximumBytes {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: min(1_048_576, ContentImageAsset.maximumBytes + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        guard data.count == size.intValue, before[.modificationDate] as? Date == after[.modificationDate] as? Date,
              before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber else {
            throw ProjectError.invalid("The image changed while being imported. Wait for it to finish saving, then try again.")
        }
        guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw ProjectError.invalid("macOS cannot read this image. Choose a supported still image such as PNG, JPEG or HEIC.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let asset = ContentImageAsset(name: source.lastPathComponent, data: data,
            pixelWidth: rotated ? height : width, pixelHeight: rotated ? width : height)
        try asset.validate()
        return asset
    }
}

struct ContentLayersInspector: View {
    @ObservedObject var editor: ProjectEditor
    let sourceTime: Double
    @Binding var selection: UUID?
    var prepare: () -> Void
    var seek: (Double) -> Void
    @State private var editing: ContentLayer?
    @State private var importError: String?
    @State private var isImporting = false
    private var layers: [ContentLayer] { editor.editingState.contentLayers }
    private var selected: ContentLayer? { layers.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(ContentLayerKind.allCases, id: \.self) { kind in
                        Button(kind == .image ? "Image…" : kind.title) { add(kind) }
                    }
                } label: { Label("Add", systemImage: "plus") }
                .fixedSize().disabled(isImporting)
                Picker("Layer", selection: Binding(get: { selection }, set: { next in
                    prepare(); if editor.finishDraft() { selection = next }
                })) {
                    Text(layers.isEmpty ? "No content layers" : "Choose layer").tag(Optional<UUID>.none)
                    ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                        Text("\(index + 1). \(layer.label)").tag(Optional(layer.id))
                    }
                }.frame(maxWidth: 330)
                Button("Edit…") { prepare(); editing = selected }.disabled(selected == nil || isImporting)
                Button("Show") { if let selected { prepare(); seek(selected.start + min(0.5, (selected.end - selected.start) / 2)) } }
                    .disabled(selected == nil)
                Spacer(minLength: 0)
                if isImporting { ProgressView().controlSize(.small) }
                Button { reorder(-1) } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }
                    .help("Move this layer behind the preceding layer").disabled(selected == nil || selection == layers.first?.id)
                Button { reorder(1) } label: { Image(systemName: "square.3.layers.3d.top.filled") }
                    .help("Move this layer in front of the next layer").disabled(selected == nil || selection == layers.last?.id)
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                    .help("Remove this content layer").disabled(selected == nil)
            }
            if let selected {
                HStack(spacing: 16) {
                    Text(String(format: "Source %.2f–%.2f s", selected.start, selected.end)).monospacedDigit()
                    if selected.endRect != nil { Text("Moving") }
                    if selected.kind == .image, MediaProcessing.isSuspended { Text("Image preview suspended") }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .sheet(item: $editing) { original in
            ContentLayerForm(layer: original, duration: editor.project.duration) { next in
                guard editor.editingState.contentLayers.first(where: { $0.id == original.id }) == original else {
                    return "This layer changed while its settings were open. Close and reopen the settings to use the current version."
                }
                var state = editor.editingState
                guard let index = state.contentLayers.firstIndex(where: { $0.id == next.id }) else { return "This layer no longer exists." }
                state.contentLayers[index] = next
                if editor.commit(state, name: "Edit " + next.kind.rawValue) { editing = nil; return nil }
                return editor.errorMessage ?? "The layer could not be saved."
            } cancel: { editing = nil }
        }
        .alert("Could not add image", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    private func add(_ kind: ContentLayerKind) {
        prepare()
        guard editor.finishDraft() else { return }
        let start = max(0, min(sourceTime, editor.project.duration - min(0.1, editor.project.duration / 2)))
        var layer = ContentLayer(kind: kind, start: start, end: min(editor.project.duration, start + 3))
        if kind == .rectangle || kind == .circle || kind == .image { layer.rect = .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
        if kind == .arrow { layer.rect = .init(x: 0.3, y: 0.4, width: 0.4, height: 0.15) }
        guard kind == .image else {
            if editor.addContentLayer(layer) { selection = layer.id; seek(layer.start + min(0.25, (layer.end - layer.start) / 2)); editing = layer }
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Add Image"; panel.prompt = "Add"
        panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        let initial = layer
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let asset = try await Task.detached(priority: .utility) { try ContentImageImport.read(url) }.value
                var imageLayer = initial; imageLayer.assetID = asset.id
                if editor.addContentLayer(imageLayer, image: asset) { selection = imageLayer.id; seek(imageLayer.start + min(0.25, (imageLayer.end - imageLayer.start) / 2)); editing = imageLayer }
                else { importError = editor.errorMessage }
            } catch { importError = error.localizedDescription }
        }
    }

    private func reorder(_ delta: Int) {
        guard let selection, let index = layers.firstIndex(where: { $0.id == selection }), layers.indices.contains(index + delta) else { return }
        prepare()
        var state = editor.editingState
        state.contentLayers.swapAt(index, index + delta)
        _ = editor.commit(state, name: "Reorder layer")
    }
    private func remove() {
        guard let selection else { return }
        prepare()
        var state = editor.editingState; state.contentLayers.removeAll { $0.id == selection }
        if editor.commit(state, name: "Remove layer") { self.selection = nil }
    }
}

struct ContentLayerForm: View {
    @State private var draft: ContentLayer
    @State private var errorMessage: String?
    let duration: Double
    var apply: (ContentLayer) -> String?
    var cancel: () -> Void

    init(layer: ContentLayer, duration: Double, apply: @escaping (ContentLayer) -> String?, cancel: @escaping () -> Void) {
        _draft = State(initialValue: layer); self.duration = duration; self.apply = apply; self.cancel = cancel
    }
    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                Form {
                    if draft.kind == .text { TextEditor(text: $draft.text).frame(height: 70).border(.secondary.opacity(0.3)) }
                    HStack { number("Source start (s)", $draft.start); number("Source end (s)", $draft.end) }
                    HStack { number("X (%)", fraction(\.rect.x)); number("Y (%)", fraction(\.rect.y)) }
                    HStack { number("Width (%)", fraction(\.rect.width)); number("Height (%)", fraction(\.rect.height)) }
                    number("Rotation (°)", $draft.rotation)
                    number("Opacity (%)", fraction(\.opacity))
                    if draft.kind != .image {
                        ColorPicker("Color", selection: Binding(get: { Color(red: draft.color.red, green: draft.color.green, blue: draft.color.blue) }, set: { value in
                            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
                            draft.color = CanvasColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
                        }), supportsOpacity: false)
                    }
                    if draft.kind == .text {
                        HStack { number("Font size (%)", fraction(\.fontSize)); Toggle("Bold", isOn: $draft.bold) }
                    } else if draft.kind != .image {
                        number("Stroke (%)", fraction(\.strokeWidth))
                        if draft.kind != .arrow { Toggle("Fill", isOn: $draft.filled) }
                    }
                    HStack { number("Fade in (s)", $draft.fadeIn); number("Fade out (s)", $draft.fadeOut) }
                    Toggle("Move and resize over this interval", isOn: Binding(get: { draft.endRect != nil }, set: { draft.endRect = $0 ? draft.rect : nil }))
                    if let end = draft.endRect {
                        HStack { number("End X (%)", destination(\.x, fallback: end.x)); number("End Y (%)", destination(\.y, fallback: end.y)) }
                        HStack { number("End width (%)", destination(\.width, fallback: end.width)); number("End height (%)", destination(\.height, fallback: end.height)) }
                    }
                }.formStyle(.grouped)
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    do {
                        // Registry membership is checked by the editor's full
                        // project validation; this form validates local fields.
                        try draft.validate(duration: duration, assets: Set([draft.assetID].compactMap { $0 }))
                        errorMessage = apply(draft)
                    } catch { errorMessage = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 440, height: draft.endRect == nil ? 480 : 580)
    }
    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.caption)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(minWidth: 54)
        }
    }
    private func fraction(_ key: WritableKeyPath<ContentLayer, Double>) -> Binding<Double> {
        Binding(get: { draft[keyPath: key] * 100 }, set: { draft[keyPath: key] = $0 / 100 })
    }
    private func destination(_ key: WritableKeyPath<EditorRegionRect, Double>, fallback: Double) -> Binding<Double> {
        Binding(get: { (draft.endRect?[keyPath: key] ?? fallback) * 100 }, set: {
            guard var end = draft.endRect else { return }; end[keyPath: key] = $0 / 100; draft.endRect = end
        })
    }
}

struct ContentLayersOverlay: NSViewRepresentable {
    var layers: [ContentLayer]
    var sourceSize: CGSize
    var presentation: CanvasPresentation
    var time: Double
    var samples: [EditorCanvasSample]
    var selection: UUID?
    var isEditing: Bool
    var select: (UUID?) -> Void
    var begin: () -> Bool
    var preview: (ContentLayer) -> Void
    var commit: (String) -> Void
    var cancel: () -> Void
    func makeNSView(context: Context) -> ContentLayersOverlayView { ContentLayersOverlayView() }
    func updateNSView(_ view: ContentLayersOverlayView, context: Context) {
        view.layers = layers; view.sourceSize = sourceSize; view.presentation = presentation
        view.time = time; view.samples = samples; view.selection = selection; view.isEditing = isEditing
        view.select = select; view.begin = begin; view.preview = preview; view.commit = commit; view.cancel = cancel
        view.needsDisplay = true
    }
}

@MainActor
final class ContentLayersOverlayView: NSView {
    var layers: [ContentLayer] = []
    var sourceSize = CGSize(width: 1920, height: 1080)
    var presentation = CanvasPresentation()
    var time = 0.0
    var samples: [EditorCanvasSample] = []
    var selection: UUID?
    var isEditing = false
    var select: (UUID?) -> Void = { _ in }
    var begin: () -> Bool = { true }
    var preview: (ContentLayer) -> Void = { _ in }
    var commit: (String) -> Void = { _ in }
    var cancel: () -> Void = {}
    private var gesture: (layer: ContentLayer, point: CGPoint, resize: Bool)?
    private var changed = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var canvas: CGRect { PresentationGeometry(sourceSize: sourceSize, presentation: presentation).outputRect(in: bounds) }
    func frame(for layer: ContentLayer, at time: Double) -> CGRect {
        let rect = layer.frame(at: time), canvas = canvas
        return CGRect(x: canvas.minX + rect.x * canvas.width, y: canvas.minY + rect.y * canvas.height,
                      width: rect.width * canvas.width, height: rect.height * canvas.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.clip(to: canvas)
        if MediaProcessing.isSuspended {
            let moments = samples.isEmpty ? [(time, 1.0)] : samples.map { ($0.sourceTime, $0.weight) }
            for (time, weight) in moments {
                for layer in layers where layer.isActive(at: time) {
                    let frame = frame(for: layer, at: time)
                    context.saveGState(); context.setAlpha(layer.alpha(at: time) * weight)
                    rotate(context, frame: frame, degrees: layer.rotation)
                    // Match the media cache: animate the original artwork's
                    // bounds, including text and strokes, rather than reflowing
                    // text at a different width on every source frame.
                    let base = CGSize(width: layer.rect.width * canvas.width, height: layer.rect.height * canvas.height)
                    context.translateBy(x: frame.minX, y: frame.minY)
                    context.scaleBy(x: frame.width / base.width, y: frame.height / base.height)
                    ContentLayerDrawing.draw(layer, in: context, rect: CGRect(origin: .zero, size: base),
                        canvasSize: canvas.size, imagePlaceholder: true)
                    context.restoreGState()
                }
            }
        }
        if isEditing, let selected = layers.first(where: { $0.id == selection }), selected.isActive(at: time) {
            let frame = frame(for: selected, at: time)
            context.saveGState(); rotate(context, frame: frame, degrees: selected.rotation)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1.5); context.stroke(frame)
            context.setFillColor(NSColor.controlAccentColor.cgColor)
            context.fill(CGRect(x: frame.maxX - 4, y: frame.maxY - 4, width: 8, height: 8))
            context.restoreGState()
        }
        context.restoreGState()
    }
    private func rotate(_ context: CGContext, frame: CGRect, degrees: Double) {
        context.translateBy(x: frame.midX, y: frame.midY); context.rotate(by: degrees * .pi / 180)
        context.translateBy(x: -frame.midX, y: -frame.midY)
    }
    private func unrotated(_ point: CGPoint, frame: CGRect, degrees: Double) -> CGPoint {
        let angle = degrees * .pi / 180, dx = point.x - frame.midX, dy = point.y - frame.midY
        return CGPoint(x: frame.midX + cos(angle) * dx + sin(angle) * dy, y: frame.midY - sin(angle) * dx + cos(angle) * dy)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditing && bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        guard isEditing else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let layer = layers.reversed().first(where: { layer in
            layer.isActive(at: time) && frame(for: layer, at: time).insetBy(dx: -6, dy: -6)
                .contains(unrotated(point, frame: frame(for: layer, at: time), degrees: layer.rotation))
        }) else { select(nil); return }
        let frame = frame(for: layer, at: time)
        let local = unrotated(point, frame: frame, degrees: layer.rotation)
        let resize = CGRect(x: frame.maxX - 8, y: frame.maxY - 8, width: 16, height: 16).contains(local)
        guard begin() else { return }
        select(layer.id); window?.makeFirstResponder(self)
        gesture = (layer, point, resize); changed = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let gesture, canvas.width > 0, canvas.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - gesture.point.x, dy = point.y - gesture.point.y
        let next: ContentLayer
        if gesture.resize {
            let angle = gesture.layer.rotation * .pi / 180
            next = gesture.layer.resized(width: (cos(angle) * dx + sin(angle) * dy) / canvas.width,
                height: (-sin(angle) * dx + cos(angle) * dy) / canvas.height)
        } else { next = gesture.layer.translated(x: dx / canvas.width, y: dy / canvas.height) }
        changed = changed || next != gesture.layer
        preview(next)
    }
    override func mouseUp(with event: NSEvent) {
        if let gesture, changed { commit(gesture.resize ? "Resize layer" : "Move layer") }
        gesture = nil; changed = false
    }
    override func cancelOperation(_ sender: Any?) {
        if gesture != nil { cancel(); gesture = nil; changed = false; needsDisplay = true }
        else { select(nil) }
    }
}

/// Clip operations used by the inspector and timeline share one immutable-source
/// model. Timing changes deliberately leave every source-time envelope untouched.
enum VideoClipEditing {
    static func replacing(_ clip: VideoClip, layerID: UUID, in state: EditState, project: RecordingProject) -> EditState {
        var result = state
        var layers = project.effectiveVideoLayers(in: state)
        guard let layer = layers.firstIndex(where: { $0.id == layerID }),
              let index = layers[layer].clips.firstIndex(where: { $0.id == clip.id }) else { return result }
        layers[layer].clips[index] = clip
        result.videoLayers = layers
        return result
    }

    static func editingSourceTime(_ clip: VideoClip, projectTime: Double) -> Double {
        clip.sourceTime(at: min(clip.end.nextDown, max(clip.start, projectTime)))
    }
    static func framing(_ clip: VideoClip, target: VideoGeometry, at sourceTime: Double) -> VideoClip {
        var next = clip
        if let index = next.geometryKeyframes.firstIndex(where: { abs($0.time - sourceTime) < 0.000001 }) {
            next.geometryKeyframes[index].geometry = target
        } else if sourceTime <= 0.000001 && next.geometryKeyframes.isEmpty { next.geometry = target }
        else {
            next.geometryKeyframes.append(.init(time: sourceTime, geometry: target))
            next.geometryKeyframes.sort { $0.time < $1.time }
        }
        return next
    }
    static func fading(_ clip: VideoClip, target: Double, at sourceTime: Double) -> VideoClip {
        var next = clip
        if let index = next.opacityKeyframes.firstIndex(where: { abs($0.time - sourceTime) < 0.000001 }) {
            next.opacityKeyframes[index].opacity = target
        } else if sourceTime <= 0.000001 && next.opacityKeyframes.isEmpty { next.opacity = target }
        else {
            next.opacityKeyframes.append(.init(time: sourceTime, opacity: target))
            next.opacityKeyframes.sort { $0.time < $1.time }
        }
        return next
    }
    static func adding(_ source: VideoSource, at requested: Double, layerID: UUID?, state: EditState,
                       project: RecordingProject) -> (EditState, UUID, UUID) {
        var next = state, layers = project.effectiveVideoLayers(in: state)
        let start = min(max(0, requested), max(0, project.duration - min(0.1, project.duration)))
        let clip = VideoClip(sourceID: source.id, start: start,
            end: min(project.duration, start + (source.duration ?? project.duration)))
        let id: UUID
        if let layerID, let index = layers.firstIndex(where: { $0.id == layerID }) {
            layers[index].clips.append(clip); id = layerID
        } else {
            let layer = VideoLayer(name: source.name, clips: [clip]); id = layer.id; layers.append(layer)
        }
        next.videoLayers = layers
        return (next, id, clip.id)
    }
}

struct VideoLayersInspector: View {
    @ObservedObject var editor: ProjectEditor
    let sourceTime: Double
    @Binding var layerID: UUID?
    @Binding var clipID: UUID?
    @Binding var volumeID: UUID?
    var prepare: () -> Void
    @State private var importError: String?
    @State private var importing = false
    @State private var editingLayerName = false
    private var layers: [VideoLayer] { editor.project.effectiveVideoLayers(in: editor.editingState) }
    private var layer: VideoLayer? { layers.first { $0.id == layerID } }
    private var clip: VideoClip? { layer?.clips.first { $0.id == clipID } }
    private var volumePoint: VideoVolumeKeyframe? { clip?.volumeKeyframes.first { $0.id == volumeID } }
    private var source: VideoSource? { editor.project.videoSources.first { $0.id == clip?.sourceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button("Import video…") { importVideo() }.disabled(MediaProcessing.isSuspended || importing)
                    Divider()
                    if MediaProcessing.isSuspended {
                        Button("Landscape test pattern") { addPattern(portrait: false) }
                        Button("Portrait test pattern") { addPattern(portrait: true) }
                    }
                    if !editor.project.videoAssets.isEmpty { Divider() }
                    ForEach(editor.project.videoSources) { source in Button(source.name) { add(source, to: nil) } }
                } label: { Label("Add video", systemImage: "plus") }.fixedSize()
                    .help(MediaProcessing.isSuspended ? "Video importing is suspended. Add a vector test pattern or reuse a registered source." : "Import footage or reuse a source in a new layer.")
                Picker("Video layer", selection: Binding(get: { layerID }, set: { id in
                    prepare(); volumeID = nil; layerID = id; clipID = layers.first { $0.id == id }?.clips.first?.id
                })) {
                    Text("Choose layer").tag(Optional<UUID>.none)
                    ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { index, value in
                        Text("\(index + 1). \(value.name)").tag(Optional(value.id))
                    }
                }.frame(maxWidth: 240)
                if let layer {
                    VideoNameField(value: layer.name, editing: { editingLayerName = $0 }) { name in apply(.renameVideoLayer(layerID: layer.id, name: name), "Rename video layer") }
                        .frame(maxWidth: 190)
                    Button { reorder(-1) } label: { Image(systemName: "arrow.down") }
                        .disabled(layer.id == layers.first?.id).help("Move this video layer behind the previous layer")
                    Button { reorder(1) } label: { Image(systemName: "arrow.up") }
                        .disabled(layer.id == layers.last?.id).help("Move this video layer in front of the next layer")
                    Button { apply(.removeVideoLayer(layerID: layer.id), "Remove video layer"); layerID = nil; clipID = nil; volumeID = nil } label: { Image(systemName: "xmark") }
                        .help("Remove this layer and its clips. Source files remain in the library.")
                        .opacity(editingLayerName ? 0 : 1).disabled(editingLayerName).accessibilityHidden(editingLayerName)
                }
                Spacer(minLength: 0)
                if importing { ProgressView().controlSize(.small) }
            }.frame(height: 24)
            if let layer {
                HStack(spacing: 8) {
                    Picker("Clip", selection: Binding(get: { clipID }, set: { prepare(); volumeID = nil; clipID = $0 })) {
                        Text("Choose clip").tag(Optional<UUID>.none)
                        ForEach(layer.clips.sorted { $0.start < $1.start }) { value in
                            Text(clipTitle(value)).tag(Optional(value.id))
                        }
                    }.frame(maxWidth: 260)
                    Menu {
                        ForEach(editor.project.videoSources) { value in Button(value.name) { add(value, to: layer.id) } }
                    } label: { Image(systemName: "plus") }.help("Add a clip at the playhead in this layer. Overlapping clips crossfade; separate layers play together.")
                    if let clip {
                        Button { duplicate(clip, in: layer.id) } label: { Image(systemName: "plus.square.on.square") }
                            .help("Reuse this source in a new layer")
                        Button { apply(.removeVideoClip(layerID: layer.id, clipID: clip.id), "Remove video clip"); clipID = nil; volumeID = nil } label: { Image(systemName: "xmark") }
                            .help("Remove this occurrence. Keep the source file and every other occurrence.")
                        VideoNumberField(title: "Start", value: clip.start) { number in update(clip) { value in let length = value.end - value.start; value.start = number; value.end = number + length } }
                        VideoNumberField(title: "In", value: clip.sourceStart) { number in update(clip) { $0.sourceStart = number } }
                        VideoNumberField(title: "Length", value: clip.end - clip.start) { number in update(clip) { $0.end = $0.start + number } }
                        VideoNumberField(title: "Rate", value: clip.rate, suffix: "×") { number in update(clip) { value in
                            if number > 0 { value.end = value.start + (value.sourceEnd - value.sourceStart) / number; value.rate = number }
                        } }.help("Change clip speed while keeping its source in and out points. The clip length changes.")
                    }
                    Spacer(minLength: 0)
                }.frame(height: 24)
            }
            if let clip {
                HStack(spacing: 10) {
                    Picker("Fit", selection: Binding(get: { clip.geometry(atSourceTime: VideoClipEditing.editingSourceTime(clip, projectTime: sourceTime)).fit }, set: { fit in
                        update(clip) { value in
                            let time = VideoClipEditing.editingSourceTime(value, projectTime: sourceTime)
                            var geometry = value.geometry(atSourceTime: time); geometry.fit = fit
                            value = VideoClipEditing.framing(value, target: geometry, at: time)
                        }
                    })) {
                        Text("Fit").tag(VideoFit.fit); Text("Fill").tag(VideoFit.fill)
                    }.pickerStyle(.segmented).frame(width: 100).disabled(clip.layout != .custom)
                        .help(clip.layout == .custom ? "Fit keeps all cropped footage visible. Fill covers the clip frame." : "Use Zoom or Camera controls for this recorded source, or choose a custom Layout first.")
                    Menu("Layout") {
                        Button("Full frame") { frame(clip, .init(x: 0, y: 0, width: 1, height: 1)) }
                        Button("Left half") { frame(clip, .init(x: 0, y: 0, width: 0.5, height: 1)) }
                        Button("Right half") { frame(clip, .init(x: 0.5, y: 0, width: 0.5, height: 1)) }
                        Button("Picture in picture") { frame(clip, .init(x: 0.67, y: 0.65, width: 0.3, height: 0.3)) }
                    }.fixedSize().help("Set this clip's frame on the canvas; separate video layers can be shown together.")
                    VideoNumberField(title: "Opacity", value: clip.opacity(atSourceTime: VideoClipEditing.editingSourceTime(clip, projectTime: sourceTime)) * 100, suffix: "%") { number in
                        update(clip) { value in value = VideoClipEditing.fading(value, target: number / 100, at: VideoClipEditing.editingSourceTime(value, projectTime: sourceTime)) }
                    }
                    Button { update(clip) { $0.isMuted.toggle() } } label: { Image(systemName: clip.isMuted ? "speaker.slash" : "speaker.wave.2") }
                        .disabled(source?.hasAudio == false).help(clip.isMuted ? "Unmute this clip" : "Mute this clip without changing its volume curve")
                    VideoNumberField(title: "Level", value: clip.volume * 100, suffix: "%") { number in update(clip) { $0.volume = number / 100 } }
                        .disabled(source?.hasAudio == false)
                    Picker("Overlap", selection: Binding(get: { clip.transition }, set: { mode in update(clip) { $0.transition = mode } })) {
                        Text("Cut").tag(VideoClipTransition.cut); Text("Crossfade").tag(VideoClipTransition.crossfade)
                    }.frame(maxWidth: 200).help("How this incoming clip replaces the preceding clip when their footage overlaps.")
                    Spacer(minLength: 0)
                }.frame(height: 24)
                HStack(spacing: 10) {
                    if let point = volumePoint {
                        Picker("Volume change", selection: Binding(get: { point.transition }, set: { mode in updateVolume(point) { $0.transition = mode } })) {
                            Text("Jump").tag(PIPTransition.jump); Text("Smooth").tag(PIPTransition.smooth)
                        }.frame(width: 205)
                        VideoNumberField(title: "Duration", value: point.duration / clip.rate) { number in updateVolume(point) { $0.duration = number * clip.rate } }
                        VideoNumberField(title: "Accelerate", value: (point.easeIn ?? point.duration / 4) / clip.rate) { number in updateVolume(point) { $0.easeIn = number * clip.rate } }
                        VideoNumberField(title: "Decelerate", value: (point.easeOut ?? point.duration / 4) / clip.rate) { number in updateVolume(point) { $0.easeOut = number * clip.rate } }
                        Button { removeVolume(point) } label: { Image(systemName: "xmark") }.help("Remove this clip's volume change")
                    } else {
                    VideoNumberField(title: "Fade in", value: clip.fadeIn) { number in update(clip) { $0.fadeIn = number } }
                    VideoNumberField(title: "Fade out", value: clip.fadeOut) { number in update(clip) { $0.fadeOut = number } }
                    if clip.layout != .custom { Text(clip.layout == .screen ? "Framing: Zoom controls" : "Framing: Camera controls").font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if let source { Text(source.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(source.kind == .testPattern ? "Silent vector test pattern" : source.relativePath ?? source.name) }
                    }
                }.frame(height: 24)
            }
        }.controlSize(.small)
        .alert("Could not add video", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !MediaProcessing.isSuspended else { return false }
            beginImport(urls); return true
        }
    }

    private func updateVolume(_ point: VideoVolumeKeyframe, _ change: (inout VideoVolumeKeyframe) -> Void) {
        guard let clip else { return }
        update(clip) { value in
            guard let index = value.volumeKeyframes.firstIndex(where: { $0.id == point.id }) else { return }
            change(&value.volumeKeyframes[index])
        }
    }
    private func removeVolume(_ point: VideoVolumeKeyframe) {
        guard let layerID, let clipID else { return }
        apply(.removeVideoAnimation(layerID: layerID, clipID: clipID, property: .volume, pointID: point.id), "Remove clip volume change")
        volumeID = nil
    }
    private func clipTitle(_ clip: VideoClip) -> String {
        let name = editor.project.videoSources.first { $0.id == clip.sourceID }?.name ?? "Missing source"
        return String(format: "%@ · %.2f–%.2f s", name, clip.start, clip.end)
    }
    private func update(_ clip: VideoClip, _ change: (inout VideoClip) -> Void) {
        prepare(); guard editor.finishDraft(), let layerID else { return }
        var next = clip; change(&next)
        _ = editor.commit(VideoClipEditing.replacing(next, layerID: layerID, in: editor.editingState, project: editor.project), name: "Edit video clip")
    }
    private func frame(_ clip: VideoClip, _ rect: EditorRegionRect) {
        update(clip) { value in
            let time = VideoClipEditing.editingSourceTime(value, projectTime: sourceTime)
            var target = value.geometry(atSourceTime: time); target.rect = rect
            value.layout = .custom; value = VideoClipEditing.framing(value, target: target, at: time)
        }
    }
    @discardableResult
    private func apply(_ mutation: EditorMutation, _ name: String) -> Bool {
        prepare(); guard editor.finishDraft() else { return false }
        var next = editor.editingState
        do { try mutation.apply(to: &next, project: editor.project); return editor.commit(next, name: name) }
        catch { importError = error.localizedDescription; return false }
    }
    private func reorder(_ delta: Int) {
        guard let layerID, let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        apply(.reorderVideoLayer(layerID: layerID, index: index + delta), "Reorder video layers")
    }
    private func add(_ source: VideoSource, to layer: UUID?) {
        prepare(); guard editor.finishDraft() else { return }
        let (next, selectedLayer, selectedClip) = VideoClipEditing.adding(source, at: sourceTime, layerID: layer, state: editor.editingState, project: editor.project)
        if editor.commit(next, name: "Add video clip") { layerID = selectedLayer; clipID = selectedClip; volumeID = nil }
    }
    private func duplicate(_ clip: VideoClip, in layer: UUID) {
        prepare(); guard editor.finishDraft() else { return }
        var copy = clip; copy.id = UUID()
        copy.geometryKeyframes = copy.geometryKeyframes.map { var point = $0; point.id = UUID(); return point }
        copy.opacityKeyframes = copy.opacityKeyframes.map { var point = $0; point.id = UUID(); return point }
        copy.volumeKeyframes = copy.volumeKeyframes.map { var point = $0; point.id = UUID(); return point }
        let newLayer = VideoLayer(name: source?.name ?? "Video", clips: [copy])
        var next = editor.editingState; next.videoLayers = editor.project.effectiveVideoLayers(in: next) + [newLayer]
        if editor.commit(next, name: "Duplicate video clip") { layerID = newLayer.id; clipID = copy.id; volumeID = nil }
    }
    private func addPattern(portrait: Bool) {
        prepare(); guard editor.finishDraft() else { return }
        let number = editor.project.videoAssets.filter { $0.kind == .testPattern }.count + 1
        let source = VideoSource(name: "\(portrait ? "Portrait" : "Landscape") \(number)", kind: .testPattern,
            duration: editor.project.duration, pixelWidth: portrait ? 1080 : 1920,
            pixelHeight: portrait ? 1920 : 1080, hasAudio: false, patternSeed: number)
        let (next, selectedLayer, selectedClip) = VideoClipEditing.adding(source, at: sourceTime, layerID: nil, state: editor.editingState, project: editor.project)
        if editor.registerVideoSource(source, state: next) { layerID = selectedLayer; clipID = selectedClip; volumeID = nil }
    }
    private func importVideo() {
        let panel = NSOpenPanel(); panel.title = "Add Video"; panel.prompt = "Add"
        panel.allowedContentTypes = VideoImporter.contentTypes; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        beginImport(panel.urls)
    }
    private func beginImport(_ urls: [URL]) {
        guard !importing else { return }
        prepare(); guard editor.finishDraft() else { return }
        importing = true
        let insertion = sourceTime
        Task {
            defer { importing = false }
            do {
                let selected = try await ProjectVideoImport.addSources(urls, to: editor, at: insertion)
                layerID = selected.0; clipID = selected.1; volumeID = nil
            } catch { importError = error.localizedDescription }
        }
    }
}

private struct VideoNumberField: View {
    let title: String
    let value: Double
    var suffix = "s"
    let submit: (Double) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            TextField(title, text: $draft).textFieldStyle(.roundedBorder).frame(width: 52).monospacedDigit()
                .focused($focused)
                .onAppear { restore() }
                .onChange(of: value) { _, _ in if !focused { restore() } }
                .onChange(of: focused) { _, flag in if !flag { restore() } }
                .onSubmit { if let number = Double(draft), number.isFinite { submit(number) }; focused = false; restore() }
                .onExitCommand { focused = false; restore() }
                .help("Press Return to apply. Escape or click outside to cancel.")
            Text(suffix).foregroundStyle(.secondary)
        }.fixedSize()
    }
    private func restore() { draft = String(format: "%.2f", value) }
}

/// Use the same native rename control as recording titles, including its clear
/// target, text Undo, Return, Escape and outside-click cancellation.
private struct VideoNameField: NSViewRepresentable {
    let value: String
    var editing: (Bool) -> Void = { _ in }
    let submit: (String) -> Bool
    func makeNSView(context: Context) -> RecordingTitleField {
        let field = RecordingTitleField(); configure(field); return field
    }
    func updateNSView(_ field: RecordingTitleField, context: Context) { configure(field) }
    private func configure(_ field: RecordingTitleField) {
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        field.setTitle(value); field.onEditingChanged = editing
        field.onRename = { proposed in submit(proposed) ? proposed : nil }
        field.setAccessibilityLabel("Video layer name")
        field.clearButton.setAccessibilityLabel("Clear layer name")
        field.clearButton.toolTip = "Clear the layer name"
        field.toolTip = "Click to rename this video layer. Return saves; Escape or clicking outside cancels."
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecordingTitleField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 190, height: 24)
    }
}

struct VideoClipOverlay: NSViewRepresentable {
    let project: RecordingProject
    let state: EditState
    let sourceSize: CGSize
    let time: Double
    let selection: UUID?
    var isEditing: Bool
    var select: (UUID?, UUID?) -> Void
    var begin: () -> Bool
    var preview: (UUID, VideoClip) -> Void
    var commit: () -> Void
    var cancel: () -> Void
    func makeNSView(context: Context) -> VideoClipOverlayView { VideoClipOverlayView() }
    func updateNSView(_ view: VideoClipOverlayView, context: Context) {
        view.project = project; view.state = state; view.sourceSize = sourceSize; view.time = time
        view.selection = selection; view.isEditing = isEditing; view.select = select; view.begin = begin
        view.preview = preview; view.commit = commit; view.cancel = cancel; view.needsDisplay = true
    }
}

@MainActor
final class VideoClipOverlayView: NSView {
    var project: RecordingProject?
    var state = EditState(trimStart: 0, trimEnd: 1, pipKeyframes: [])
    var sourceSize = CGSize(width: 1920, height: 1080)
    var time = 0.0
    var selection: UUID?
    var isEditing = false
    var select: (UUID?, UUID?) -> Void = { _, _ in }
    var begin: () -> Bool = { true }
    var preview: (UUID, VideoClip) -> Void = { _, _ in }
    var commit: () -> Void = {}
    var cancel: () -> Void = {}
    private struct Gesture {
        var layerID: UUID
        var clip: VideoClip
        var geometry: VideoGeometry
        var sourceTime: Double
        var point: CGPoint
        var corner: Int?
        var changed = false
    }
    private var gesture: Gesture?
    private var trackpadTimer: Timer?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var canvas: CGRect { PresentationGeometry(sourceSize: sourceSize, presentation: state.presentation).outputRect(in: bounds) }
    private var visible: [(UUID, VideoClip)] {
        guard let project else { return [] }
        let active = Set(project.videoSamples(at: time, state: state).filter { $0.weight > 0 && $0.opacity > 0 }.map(\.clipID))
        return project.effectiveVideoLayers(in: state).flatMap { layer in layer.clips.filter {
            $0.layout == .custom && active.contains($0.id)
        }.map { (layer.id, $0) } }
    }
    private func geometry(_ clip: VideoClip) -> VideoGeometry { clip.geometry(atSourceTime: clip.sourceTime(at: time)) }
    func frame(_ clip: VideoClip) -> CGRect {
        let rect = geometry(clip).rect
        return CGRect(x: canvas.minX + rect.x * canvas.width, y: canvas.minY + rect.y * canvas.height,
            width: rect.width * canvas.width, height: rect.height * canvas.height)
    }
    private func corners(_ rect: CGRect) -> [CGPoint] {
        [.init(x: rect.minX, y: rect.minY), .init(x: rect.maxX, y: rect.minY),
         .init(x: rect.minX, y: rect.maxY), .init(x: rect.maxX, y: rect.maxY)]
    }
    override func hitTest(_ point: NSPoint) -> NSView? { isEditing && bounds.contains(convert(point, from: superview)) ? self : nil }
    override func draw(_ dirtyRect: NSRect) {
        guard isEditing, let clip = visible.first(where: { $0.1.id == selection })?.1 else { return }
        let rect = frame(clip)
        NSColor.controlAccentColor.setStroke(); let outline = NSBezierPath(rect: rect); outline.lineWidth = 1.5; outline.stroke()
        NSColor.white.setFill()
        for corner in corners(rect) {
            let path = NSBezierPath(ovalIn: CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8))
            path.fill(); path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        finishTrackpad()
        let point = convert(event.locationInWindow, from: nil)
        guard let (layer, clip) = visible.reversed().first(where: { frame($0.1).insetBy(dx: -7, dy: -7).contains(point) }) else { select(nil, nil); return }
        let corner = clip.id == selection ? corners(frame(clip)).firstIndex { hypot($0.x - point.x, $0.y - point.y) < 10 } : nil
        select(layer, clip.id)
        guard begin() else { return }
        window?.makeFirstResponder(self)
        gesture = Gesture(layerID: layer, clip: clip, geometry: geometry(clip), sourceTime: clip.sourceTime(at: time), point: point, corner: corner)
    }
    override func mouseDragged(with event: NSEvent) {
        guard var gesture, canvas.width > 0, canvas.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = (point.x - gesture.point.x) / canvas.width, dy = (point.y - gesture.point.y) / canvas.height
        var target = gesture.geometry, rect = target.rect
        if let corner = gesture.corner {
            let right = corner % 2 == 1, bottom = corner >= 2
            let fixedX = right ? rect.x : rect.x + rect.width, fixedY = bottom ? rect.y : rect.y + rect.height
            let movingX = min(1, max(0, (right ? rect.x + rect.width : rect.x) + dx))
            let movingY = min(1, max(0, (bottom ? rect.y + rect.height : rect.y) + dy))
            rect.x = right ? fixedX : min(movingX, fixedX - 0.02)
            rect.y = bottom ? fixedY : min(movingY, fixedY - 0.02)
            rect.width = max(0.02, right ? movingX - fixedX : fixedX - rect.x)
            rect.height = max(0.02, bottom ? movingY - fixedY : fixedY - rect.y)
        } else {
            rect.x = min(1 - rect.width, max(0, rect.x + dx)); rect.y = min(1 - rect.height, max(0, rect.y + dy))
        }
        target.rect = rect
        if target == gesture.geometry {
            if gesture.changed { preview(gesture.layerID, gesture.clip) }
            return
        }
        gesture.changed = true; self.gesture = gesture
        apply(target)
    }
    private func apply(_ target: VideoGeometry) {
        guard let gesture else { return }
        let clip = VideoClipEditing.framing(gesture.clip, target: target, at: gesture.sourceTime)
        preview(gesture.layerID, clip)
    }
    override func mouseUp(with event: NSEvent) {
        if gesture != nil { commit() }
        gesture = nil
    }
    private func prepareTrackpad() -> Bool {
        if gesture != nil { return true }
        guard let (layer, clip) = visible.first(where: { $0.1.id == selection }), begin() else { return false }
        gesture = Gesture(layerID: layer, clip: clip, geometry: geometry(clip), sourceTime: clip.sourceTime(at: time), point: .zero)
        window?.makeFirstResponder(self); return true
    }
    override func magnify(with event: NSEvent) {
        guard prepareTrackpad(), var gesture else { return }
        let factor = max(0.1, 1 + event.magnification)
        var target = gesture.geometry, crop = target.crop
        let width = min(1, max(0.025, crop.width / factor)), height = min(1, max(0.025, crop.height / factor))
        crop.x = min(1 - width, max(0, crop.x + (crop.width - width) / 2))
        crop.y = min(1 - height, max(0, crop.y + (crop.height - height) / 2)); crop.width = width; crop.height = height
        target.crop = crop
        if target != gesture.geometry {
            gesture.geometry = target; gesture.changed = true; self.gesture = gesture
            apply(target)
        }
        scheduleTrackpad(event)
    }
    override func scrollWheel(with event: NSEvent) {
        guard prepareTrackpad(), var gesture, canvas.width > 0, canvas.height > 0 else { return }
        var target = gesture.geometry, crop = target.crop
        crop.x = min(1 - crop.width, max(0, crop.x - event.scrollingDeltaX / canvas.width * crop.width))
        crop.y = min(1 - crop.height, max(0, crop.y - event.scrollingDeltaY / canvas.height * crop.height))
        target.crop = crop
        if target != gesture.geometry {
            gesture.geometry = target; gesture.changed = true; self.gesture = gesture
            apply(target)
        }
        scheduleTrackpad(event)
    }
    private func scheduleTrackpad(_ event: NSEvent) {
        trackpadTimer?.invalidate()
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled) { cancelOperation(nil); return }
        if event.momentumPhase.contains(.ended) || (event.phase.contains(.ended) && event.momentumPhase.isEmpty) { finishTrackpad(); return }
        // Native phase boundaries define a gesture. Only mice/legacy events
        // without phases need the inactivity fallback.
        guard event.phase.isEmpty, event.momentumPhase.isEmpty else { return }
        trackpadTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishTrackpad() }
        }
    }
    private func finishTrackpad() {
        trackpadTimer?.invalidate(); trackpadTimer = nil
        if gesture != nil { commit() }
        gesture = nil
    }
    override func cancelOperation(_ sender: Any?) {
        trackpadTimer?.invalidate(); trackpadTimer = nil
        if gesture != nil { gesture = nil; cancel() } else { cancel(); select(nil, nil) }
    }
}
