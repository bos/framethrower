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
