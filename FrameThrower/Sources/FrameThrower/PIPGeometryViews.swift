import SwiftUI

extension PIPShape {
    var title: String {
        switch self {
        case .original: return "Original"
        case .rectangle: return "Rectangle"
        case .square: return "Square"
        case .circle: return "Circle"
        }
    }
}

struct PIPWindowShape: InsettableShape {
    var shape: PIPShape
    var insetAmount: CGFloat = 0
    var cornerRadius: CGFloat? = nil

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        if let cornerRadius { return Path(roundedRect: bounds, cornerRadius: max(0, cornerRadius - insetAmount)) }
        return shape == .circle ? Path(ellipseIn: bounds) : Path(roundedRect: bounds, cornerRadius: 3)
    }
    func inset(by amount: CGFloat) -> PIPWindowShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Displays the full source while moving a crop. This edits framing, never the
/// camera movie, and one drag becomes one placement-point edit.
struct CameraFramingPopover: View {
    let image: CGImage?
    let errorMessage: String?
    let placement: PIPPlacement
    var canvasSize: CGSize? = nil
    var preview: (PIPCrop) -> Void = { _ in }
    var zoomPreview: (Double) -> Void = { _ in }
    var zoomCommit: (Double) -> Void = { _ in }
    var commit: (PIPCrop) -> Void
    @State private var dragOrigin: PIPCrop?
    @State private var draft: PIPCrop?
    @State private var zoomDraft: Double?

    private func framingPlacement(source: CGSize) -> PIPPlacement {
        guard let canvasSize, placement.fullscreenFraction > 0 else { return placement }
        let frame = placement.frame(in: canvasSize, cameraAspect: source.width / source.height)
        var result = placement; result.shape = .rectangle; result.aspectRatio = frame.width / max(1, frame.height)
        return result
    }
    private func cropOutline(source: CGSize, crop: CGRect, scale: Double) -> PIPWindowShape {
        guard let canvasSize else { return PIPWindowShape(shape: placement.shape) }
        let frame = placement.frame(in: canvasSize, cameraAspect: source.width / source.height)
        let radius = placement.cornerRadius(in: frame.size) / max(1, min(frame.width, frame.height))
        return PIPWindowShape(shape: placement.shape, cornerRadius: radius * min(crop.width, crop.height) * scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera framing").font(.headline)
            if let image {
                let source = CGSize(width: image.width, height: image.height)
                let scale = min(360 / source.width, 240 / source.height)
                let size = CGSize(width: source.width * scale, height: source.height * scale)
                let zoom = zoomDraft ?? placement.sourceZoom
                let framing = framingPlacement(source: source)
                let crop = (draft ?? placement.crop).rect(in: source, shape: framing.shape,
                                                        aspectRatio: framing.aspectRatio, zoom: zoom)
                let outline = cropOutline(source: source, crop: crop, scale: scale)
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: size.width, height: size.height)
                    .overlay(alignment: .topLeading) {
                        outline
                            .strokeBorder(.white, lineWidth: 2)
                            .background(outline.fill(.white.opacity(0.08)))
                            .frame(width: crop.width * scale, height: crop.height * scale)
                            .offset(x: crop.minX * scale, y: crop.minY * scale)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("cameraCropSource")).onChanged { value in
                                if dragOrigin == nil { dragOrigin = placement.crop }
                                guard let origin = dragOrigin else { return }
                                draft = origin.moved(
                                    by: CGSize(width: value.translation.width / scale, height: value.translation.height / scale),
                                    in: source, shape: framing.shape, aspectRatio: framing.aspectRatio, zoom: zoom)
                                if let draft { preview(draft) }
                            }.onEnded { _ in
                                if let draft { commit(draft) }
                                draft = nil
                                dragOrigin = nil
                            })
                            .accessibilityLabel("Camera crop. Drag to adjust framing.")
                    }
                    .coordinateSpace(name: "cameraCropSource")
                    .clipped()
                    .background(.black)
                HStack {
                    Text("Drag the outline to frame your camera.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Center") { commit(PIPCrop()) }.controlSize(.small)
                }
                CommitSlider(title: "Zoom", value: placement.sourceZoom, range: 1...3, valueSuffix: "×", preview: { value in
                    zoomDraft = value
                    zoomPreview(value)
                }) { value in
                    zoomCommit(value)
                    zoomDraft = nil
                }
                .frame(height: 24)
                // These controls also make framing available without dragging.
                CommitSlider(title: "Horizontal", value: placement.crop.x, range: 0...1, preview: { value in
                    var next = placement.crop; next.x = value; draft = next; preview(next)
                }) { value in
                    var next = placement.crop; next.x = value; commit(next); draft = nil
                }
                .frame(height: 24)
                .opacity(source.width > crop.width + 0.01 ? 1 : 0)
                .disabled(source.width <= crop.width + 0.01)
                .accessibilityHidden(source.width <= crop.width + 0.01)
                CommitSlider(title: "Vertical", value: placement.crop.y, range: 0...1, preview: { value in
                    var next = placement.crop; next.y = value; draft = next; preview(next)
                }) { value in
                    var next = placement.crop; next.y = value; commit(next); draft = nil
                }
                .frame(height: 24)
                .opacity(source.height > crop.height + 0.01 ? 1 : 0)
                .disabled(source.height <= crop.height + 0.01)
                .accessibilityHidden(source.height <= crop.height + 0.01)
            } else if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.secondary)
            } else { ProgressView("Loading camera…") }
        }
        .padding(16)
        .frame(width: 392)
    }
}

struct VideoCropRequest: Identifiable {
    let id = UUID()
    var title: String
    var source: VideoSource
    var time: Double
    var sourceSize: CGSize
    var crop: EditorRegionRect
    var sourceBounds = CropGeometry.full
    var setsOutputFrame = false
    var outputResolution: CanvasResolution? = nil
    var apply: (EditorRegionRect, CanvasResolution?) -> Void
}

/// Every target edits a local draft. Cancel and Escape never change the project.
struct VideoCropEditor: View {
    let request: VideoCropRequest
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var selection: EditorRegionRect
    @State private var image: CGImage?
    @State private var size: CGSize
    @State private var error: String?
    @State private var loading = true
    @State private var drawing = true
    @State private var preset = "Freeform"
    @State private var ratioWidth = 9.0
    @State private var ratioHeight = 16.0
    @State private var resolution = "Crop size"
    @State private var customWidth = 1920.0

    init(request: VideoCropRequest, directory: URL) {
        self.request = request; self.directory = directory
        _selection = State(initialValue: CropGeometry.pixelAligned(request.crop, in: request.sourceSize))
        _size = State(initialValue: request.sourceSize)
        _drawing = State(initialValue: request.crop == CropGeometry.full)
        _resolution = State(initialValue: request.outputResolution == nil ? "Crop size" : "Custom")
        _customWidth = State(initialValue: Double(request.outputResolution?.width ?? 1920))
        if let output = request.outputResolution {
            let aspect = Double(output.width) / Double(output.height)
            let known: [(String, Double)] = [("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("Square", 1.0), ("4:3", 4.0 / 3), ("3:2", 3.0 / 2), ("4:5", 4.0 / 5)]
            _preset = State(initialValue: known.first { abs($0.1 - aspect) < 0.0001 }?.0 ?? "Custom")
            var a = output.width, b = output.height
            while b != 0 { let next = a % b; a = b; b = next }
            _ratioWidth = State(initialValue: Double(output.width / max(1, a)))
            _ratioHeight = State(initialValue: Double(output.height / max(1, a)))
            switch min(output.width, output.height) {
            case 720: _resolution = State(initialValue: "720p")
            case 1080: _resolution = State(initialValue: "1080p")
            case 2160: _resolution = State(initialValue: "4K")
            default: break
            }
        }
    }

    private var ratio: Double? {
        switch preset {
        case "Source": size.width / size.height
        case "16:9": 16.0 / 9
        case "9:16": 9.0 / 16
        case "Square": 1
        case "4:3": 4.0 / 3
        case "3:2": 3.0 / 2
        case "4:5": 4.0 / 5
        case "Custom": ratioWidth.isFinite && ratioHeight.isFinite && ratioWidth > 0 && ratioHeight > 0 && (ratioWidth / ratioHeight).isFinite ? ratioWidth / ratioHeight : nil
        default: nil
        }
    }
    private var valid: Bool {
        let r = CropGeometry.pixels(selection, in: size)
        return selection.isValid && r.width >= 2 && r.height >= 2 && (preset != "Custom" || ratio != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.headline)
            aspectControls
            CropSelectionCanvas(image: image, sourceSize: size, selection: $selection, ratio: ratio, drawing: $drawing)
                .frame(height: 400)
                .help("Drag outside the rectangle to draw a crop. Drag inside to move it, or drag a handle to resize it.")
                .accessibilityIdentifier("video-crop-canvas")
            sizeControls
            if loading { ProgressView("Loading video frame…").controlSize(.small) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            if preset == "Custom" && ratio == nil { Text("Enter positive aspect width and height.").font(.callout).foregroundStyle(.red) }
            else if !valid { Text("The crop must be at least 2 × 2 source pixels.").font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply crop") { request.apply(CropGeometry.pixelAligned(selection, in: size), request.setsOutputFrame && resolution != "Crop size" ? outputSize : nil); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid || loading || error != nil)
            }
        }
        .padding(20).frame(width: 720)
        .onChange(of: preset) { _, _ in fitRatio() }
        .onChange(of: ratioWidth) { _, _ in if preset == "Custom" { fitRatio() } }
        .onChange(of: ratioHeight) { _, _ in if preset == "Custom" { fitRatio() } }
        .task(id: request.id) { await loadFrame() }
    }

    private var aspectControls: some View {
            HStack {
                Picker("Aspect", selection: $preset) {
                    ForEach(["Freeform", "Source", "16:9", "9:16", "Square", "4:3", "3:2", "4:5", "Custom"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 210)
                if preset == "Custom" {
                    TextField("Ratio width", value: $ratioWidth, format: .number).frame(width: 70).accessibilityLabel("Aspect width")
                    Text(":")
                    TextField("Ratio height", value: $ratioHeight, format: .number).frame(width: 70).accessibilityLabel("Aspect height")
                }
                if preset == "Freeform" || preset == "Source" { Text(aspectLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                Spacer()
                Button("Draw crop") { drawing = true }.disabled(drawing)
                Button("Reset") { preset = "Freeform"; selection = CropGeometry.full; drawing = true; resolution = "Crop size" }
            }
    }
    private var sizeControls: some View {
            HStack(spacing: 12) {
                if request.setsOutputFrame {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(["Crop size", "720p", "1080p", "4K", "Custom"], id: \.self) { Text($0).tag($0) }
                    }.frame(width: 190)
                    outputField("Width", horizontal: true)
                    outputField("Height", horizontal: false)
                } else {
                    pixelField("Width", key: \.width)
                    pixelField("Height", key: \.height)
                }
                Text("px").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
    }
    private func loadFrame() async {
            if request.source.kind == .testPattern || MediaProcessing.isSuspended { loading = false; return }
            do {
                let frame = try await ProjectRenderer.cropFrame(source: request.source, directory: directory, at: request.time)
                guard !Task.isCancelled else { return }
                if request.sourceBounds == CropGeometry.full { image = frame.image; size = frame.size }
                else {
                    let pixels = CGSize(width: frame.image.width, height: frame.image.height)
                    let bounds = CropGeometry.pixels(request.sourceBounds, in: pixels).integral
                        .intersection(CGRect(origin: .zero, size: pixels))
                    image = frame.image.cropping(to: bounds)
                    size = CropGeometry.pixels(request.sourceBounds, in: frame.size).size
                }
                selection = CropGeometry.pixelAligned(selection, in: size)
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Could not load the video frame: \(error.localizedDescription)"; loading = false
            }
    }

    private var selectedAspect: Double { ratio ?? (selection.width * size.width / max(0.000001, selection.height * size.height)) }
    private var aspectLabel: String {
        let aspect = selectedAspect
        let known: [(String, Double)] = [("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("1:1", 1.0), ("4:3", 4.0 / 3), ("3:2", 3.0 / 2), ("4:5", 4.0 / 5)]
        for (label, value) in known {
            if abs(aspect - value) < 0.0001 { return label }
        }
        return String(format: "%.3f:1", aspect)
    }
    private var outputSize: CanvasResolution {
        switch resolution {
        case "720p": return .matching(aspect: selectedAspect, shortEdge: 720)
        case "1080p": return .matching(aspect: selectedAspect, shortEdge: 1080)
        case "4K": return .matching(aspect: selectedAspect, shortEdge: 2160)
        case "Custom": return .matching(aspect: selectedAspect, shortEdge: selectedAspect >= 1 ? customWidth / selectedAspect : customWidth)
        default: return .native(CropGeometry.pixels(selection, in: size).size)
        }
    }
    private func outputField(_ title: String, horizontal: Bool) -> some View {
        let value = Binding<Int>(get: { horizontal ? outputSize.width : outputSize.height }, set: { pixels in
            customWidth = Double(max(2, pixels)) * (horizontal ? 1 : selectedAspect)
            resolution = "Custom"
        })
        return HStack(spacing: 4) {
            Text(title).font(.caption)
            TextField(title, value: value, format: .number).frame(width: 80)
                .accessibilityLabel("Output \(title.lowercased()) in pixels")
        }
    }

    private func fitRatio() {
        selection = CropGeometry.pixelAligned(CropGeometry.fitted(selection, ratio: ratio, source: size), in: size)
    }

    private func pixelField(_ title: String, key: WritableKeyPath<EditorRegionRect, Double>) -> some View {
        let horizontal = key == \.x || key == \.width
        let extent = horizontal ? size.width : size.height
        return HStack(spacing: 4) {
            Text(title).font(.caption)
            TextField(title, value: Binding(get: { Int((selection[keyPath: key] * extent).rounded()) }, set: { value in
                guard extent > 0 else { return }
                let value = CGFloat(value)
                var r = CropGeometry.pixels(selection, in: size)
                if key == \.x { r.origin.x = min(size.width - r.width, max(0, value)) }
                else if key == \.y { r.origin.y = min(size.height - r.height, max(0, value)) }
                else if key == \.width {
                    r.size.width = min(size.width - r.minX, max(2, value))
                    if let ratio { r.size.height = r.width / ratio }
                } else {
                    r.size.height = min(size.height - r.minY, max(2, value))
                    if let ratio { r.size.width = r.height * ratio }
                }
                selection = CropGeometry.pixelAligned(CropGeometry.fitted(CropGeometry.normalized(r, in: size), ratio: ratio, source: size), in: size)
            }), format: .number)
            .frame(width: 75).accessibilityLabel("Crop \(title.lowercased()) in pixels")
        }
    }
}

struct CropSelectionCanvas: NSViewRepresentable {
    var image: CGImage?
    var sourceSize: CGSize
    @Binding var selection: EditorRegionRect
    var ratio: Double?
    @Binding var drawing: Bool

    func makeNSView(context: Context) -> CropSelectionView { CropSelectionView() }
    func updateNSView(_ view: CropSelectionView, context: Context) {
        view.image = image; view.sourceSize = sourceSize; view.selection = selection; view.ratio = ratio
        view.drawNew = drawing; view.finishedDrawing = { drawing = false }
        view.changed = { selection = $0 }; view.needsDisplay = true
    }
}

final class CropSelectionView: NSView {
    var image: CGImage?
    var sourceSize = CGSize(width: 1920, height: 1080)
    var selection = CropGeometry.full
    var ratio: Double?
    var changed: ((EditorRegionRect) -> Void)?
    var drawNew = true
    var finishedDrawing: (() -> Void)?
    private var origin: CGPoint?
    private var original = CropGeometry.full
    private var handle: Int?
    private var moving = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageRect: CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private var cropRect: CGRect {
        let r = CropGeometry.pixels(selection, in: imageRect.size)
        return r.offsetBy(dx: imageRect.minX, dy: imageRect.minY)
    }
    private func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = imageRect
        if let image {
            context.saveGState(); context.translateBy(x: frame.minX, y: frame.maxY); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: frame.size)); context.restoreGState()
        } else {
            for row in 0..<6 { for column in 0..<10 {
                NSColor(calibratedHue: CGFloat(row + column) / 16, saturation: 0.45, brightness: 0.65, alpha: 1).setFill()
                CGRect(x: frame.minX + CGFloat(column) * frame.width / 10, y: frame.minY + CGFloat(row) * frame.height / 6,
                       width: frame.width / 10, height: frame.height / 6).fill()
            } }
        }
        let crop = cropRect
        let mask = NSBezierPath(rect: frame); mask.appendRect(crop); mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill(); mask.fill()
        NSColor.white.setStroke(); let outline = NSBezierPath(rect: crop); outline.lineWidth = 1.5; outline.stroke()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor); context.setLineWidth(0.5)
        for fraction in [1.0 / 3, 2.0 / 3] {
            context.move(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.minY)); context.addLine(to: CGPoint(x: crop.minX + crop.width * fraction, y: crop.maxY))
            context.move(to: CGPoint(x: crop.minX, y: crop.minY + crop.height * fraction)); context.addLine(to: CGPoint(x: crop.maxX, y: crop.minY + crop.height * fraction))
        }
        context.strokePath(); NSColor.white.setFill()
        for p in handles(crop) { CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8).fill() }
    }
    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: .crosshair)
        if !drawNew && cropRect.width > 12 && cropRect.height > 12 { addCursorRect(cropRect.insetBy(dx: 6, dy: 6), cursor: .openHand) }
        for (index, point) in handles(cropRect).enumerated() {
            addCursorRect(CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14),
                          cursor: index == 1 || index == 5 ? .resizeUpDown : index == 3 || index == 7 ? .resizeLeftRight : .crosshair)
        }
    }
    override func keyDown(with event: NSEvent) {
        let amount = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        let delta: CGSize
        switch event.keyCode {
        case 123: delta = CGSize(width: -amount / sourceSize.width, height: 0)
        case 124: delta = CGSize(width: amount / sourceSize.width, height: 0)
        case 125: delta = CGSize(width: 0, height: amount / sourceSize.height)
        case 126: delta = CGSize(width: 0, height: -amount / sourceSize.height)
        default: super.keyDown(with: event); return
        }
        selection = CropGeometry.pixelAligned(CropGeometry.moved(selection, by: delta), in: sourceSize)
        changed?(selection); needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.insetBy(dx: -6, dy: -6).contains(point) else { return }
        window?.makeFirstResponder(self)
        origin = point; original = selection
        handle = handles(cropRect).firstIndex { abs($0.x - point.x) <= 8 && abs($0.y - point.y) <= 8 }
        moving = !drawNew && handle == nil && cropRect.contains(point)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin, imageRect.width > 0, imageRect.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        if moving {
            selection = CropGeometry.moved(original, by: CGSize(width: (point.x - origin.x) / imageRect.width, height: (point.y - origin.y) / imageRect.height))
        } else {
            let local = CGPoint(x: (point.x - imageRect.minX) / imageRect.width * sourceSize.width,
                                y: (point.y - imageRect.minY) / imageRect.height * sourceSize.height)
            let start = CGPoint(x: (origin.x - imageRect.minX) / imageRect.width * sourceSize.width,
                                y: (origin.y - imageRect.minY) / imageRect.height * sourceSize.height)
            let next: EditorRegionRect?
            if let handle { next = CropGeometry.resized(original, handle: handle, to: local, source: sourceSize, ratio: ratio) }
            else { next = CropGeometry.drawn(from: start, to: local, source: sourceSize, ratio: ratio) }
            if let next { selection = next }
        }
        selection = CropGeometry.pixelAligned(selection, in: sourceSize)
        changed?(selection); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if origin != nil { drawNew = false; finishedDrawing?() }
        origin = nil; handle = nil; moving = false; window?.invalidateCursorRects(for: self)
    }
    override func cancelOperation(_ sender: Any?) {
        guard origin != nil else { super.cancelOperation(sender); return }
        selection = original; changed?(selection); origin = nil; handle = nil; moving = false; needsDisplay = true
    }
}
