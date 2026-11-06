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

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
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
    var preview: (PIPCrop) -> Void = { _ in }
    var zoomPreview: (Double) -> Void = { _ in }
    var zoomCommit: (Double) -> Void = { _ in }
    var commit: (PIPCrop) -> Void
    @State private var dragOrigin: PIPCrop?
    @State private var draft: PIPCrop?
    @State private var zoomDraft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Camera framing").font(.headline)
            if let image {
                let source = CGSize(width: image.width, height: image.height)
                let scale = min(360 / source.width, 240 / source.height)
                let size = CGSize(width: source.width * scale, height: source.height * scale)
                let zoom = zoomDraft ?? placement.sourceZoom
                let crop = (draft ?? placement.crop).rect(in: source, shape: placement.shape,
                                                        aspectRatio: placement.aspectRatio, zoom: zoom)
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: size.width, height: size.height)
                    .overlay(alignment: .topLeading) {
                        PIPWindowShape(shape: placement.shape)
                            .strokeBorder(.white, lineWidth: 2)
                            .background(PIPWindowShape(shape: placement.shape).fill(.white.opacity(0.08)))
                            .frame(width: crop.width * scale, height: crop.height * scale)
                            .offset(x: crop.minX * scale, y: crop.minY * scale)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("cameraCropSource")).onChanged { value in
                                if dragOrigin == nil { dragOrigin = placement.crop }
                                guard let origin = dragOrigin else { return }
                                draft = origin.moved(
                                    by: CGSize(width: value.translation.width / scale, height: value.translation.height / scale),
                                    in: source, shape: placement.shape, aspectRatio: placement.aspectRatio, zoom: zoom)
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
