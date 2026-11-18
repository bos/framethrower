import AppKit
import CoreText

/// A static source-coordinate chart made entirely from native vector/text
/// layers. Its only animation comes from the editor's real framing metadata.
@MainActor
final class EditorTestPattern {
    static let sourceSize = CGSize(width: 1920, height: 1080)
    let layer = CALayer()
    private let screenClip = CALayer()
    private let cameraClip = CALayer()
    private let screen = CALayer()
    private let camera = CALayer()
    private let multiVideoRoot = EditorVideoVectorLayer()
    private(set) var screenViewport = CGRect.zero
    private(set) var cameraViewport = CGRect.zero
    private(set) var screenFrame = CGRect.zero
    private(set) var cameraFrame = CGRect.zero
    struct VideoSnapshot: Equatable {
        var branch: Int
        var layerID: UUID
        var clipID: UUID
        var sourceID: UUID
        var sourceTime: Double
        var weight: Double
        var frame: CGRect
        var viewport: CGRect
        var opacity: Double
        var audioGain: Double
    }
    private(set) var videoSnapshots: [VideoSnapshot] = []

    init() {
        layer.addSublayer(screenClip)
        layer.addSublayer(cameraClip)
        screenClip.masksToBounds = true
        cameraClip.masksToBounds = true
        screenClip.addSublayer(screen)
        cameraClip.addSublayer(camera)
        makeGrid(in: screen, camera: false)
        makeGrid(in: camera, camera: true)
        layer.addSublayer(multiVideoRoot)
        multiVideoRoot.isHidden = true
    }

    func update(in bounds: CGRect, sourceSize: CGSize = EditorTestPattern.sourceSize,
                presentation: CanvasPresentation, zoom: ZoomPlacement,
                placement: PIPPlacement, cameraEnabled: Bool, cameraAspect: Double) {
        multiVideoRoot.isHidden = true
        screenClip.isHidden = false
        videoSnapshots = []
        layer.frame = bounds
        let geometry = PresentationGeometry(sourceSize: sourceSize, presentation: presentation)
        let output = geometry.outputRect(in: bounds)
        screenFrame = geometry.contentRect(in: bounds)
        screenViewport = presentation.viewport(in: sourceSize, zoom: zoom)
        layer.backgroundColor = NSColor(calibratedRed: presentation.background.red,
            green: presentation.background.green, blue: presentation.background.blue, alpha: 1).cgColor
        layer.frame = output
        // Children use local output coordinates, retaining the same screen
        // inset and PIP frame as the normal presentation geometry.
        let localScreen = screenFrame.offsetBy(dx: -output.minX, dy: -output.minY)
        screenClip.frame = localScreen
        screenClip.cornerRadius = min(localScreen.width, localScreen.height) * presentation.cornerRadius
        let chartViewport = CGRect(x: screenViewport.minX / sourceSize.width * Self.sourceSize.width,
            y: screenViewport.minY / sourceSize.height * Self.sourceSize.height,
            width: screenViewport.width / sourceSize.width * Self.sourceSize.width,
            height: screenViewport.height / sourceSize.height * Self.sourceSize.height)
        position(screen, viewport: chartViewport, in: localScreen.size)

        cameraFrame = placement.frame(in: output.size, cameraAspect: cameraAspect)
            .offsetBy(dx: output.minX, dy: output.minY)
        let localCamera = cameraFrame.offsetBy(dx: -output.minX, dy: -output.minY)
        cameraClip.frame = localCamera
        cameraClip.isHidden = !cameraEnabled || placement.renderedOpacity == 0
        cameraClip.opacity = Float(placement.renderedOpacity)
        cameraClip.cornerRadius = placement.cornerRadius(in: localCamera.size)
        let cameraSource = CGSize(width: Self.sourceSize.height * cameraAspect, height: Self.sourceSize.height)
        cameraViewport = placement.sourceViewport(in: cameraSource, canvas: output.size)
        // Both charts have the same fixed source chart coordinates. Normalize
        // camera aspect into that chart before applying its source crop.
        let normalizedCrop = CGRect(x: cameraViewport.minX / cameraSource.width * Self.sourceSize.width,
            y: cameraViewport.minY / cameraSource.height * Self.sourceSize.height,
            width: cameraViewport.width / cameraSource.width * Self.sourceSize.width,
            height: cameraViewport.height / cameraSource.height * Self.sourceSize.height)
        position(camera, viewport: normalizedCrop, in: localCamera.size)
    }

    /// No media objects are involved: each registered source is represented by
    /// named vector artwork. The same sampled crop, opacity and source clock
    /// drive real rendering when media processing is enabled again.
    func update(project: RecordingProject, state: EditState, at seconds: Double,
                outputSamples: [EditorCanvasSample], in bounds: CGRect) {
        let sources = Dictionary(uniqueKeysWithValues: project.videoSources.map { ($0.id, $0) })
        let primarySize = sources[VideoSource.legacyScreenID]?.pixelSize ?? Self.sourceSize
        let presentation = PresentationGeometry(sourceSize: primarySize, presentation: state.presentation)
        let output = presentation.outputRect(in: bounds)
        layer.frame = output
        screenClip.isHidden = true; cameraClip.isHidden = true
        multiVideoRoot.isHidden = false
        multiVideoRoot.frame = CGRect(origin: .zero, size: output.size)
        let branches: [(time: Double, weight: Double)] = outputSamples.isEmpty
            ? [(seconds, 1)] : outputSamples.map { ($0.sourceTime, $0.weight) }
        videoSnapshots = []
        var drawingBranches: [EditorVideoVectorDrawing.Branch] = []
        for (index, branch) in branches.enumerated() {
            // Transport exposes the exact final boundary for inspection; a
            // preview still shows its last frame, rather than the empty instant
            // immediately after a half-open clip. Interior cut boundaries keep
            // their ordinary incoming-frame semantics.
            let isFinal = branch.time == project.duration || (!outputSamples.isEmpty && branch.time == state.trimEnd)
            let displayTime = isFinal ? max(0, branch.time - 1e-8) : branch.time
            let samples = project.videoSamples(at: displayTime, state: state)
            var layers: [[EditorVideoVectorDrawing.Clip]] = []
            for videoLayer in project.effectiveVideoLayers(in: state) {
                var clips: [EditorVideoVectorDrawing.Clip] = []
                for sample in samples where sample.layerID == videoLayer.id {
                    guard let source = sources[sample.sourceID] else { continue }
                    let size = source.pixelSize ?? Self.sourceSize
                    let drawing = VideoSampleDrawingGeometry(sample: sample, state: state, at: displayTime,
                        sourceSize: size, primarySize: primarySize, canvas: output.size)
                    clips.append(.init(source: source, sourceSize: size, geometry: drawing, weight: sample.weight))
                    videoSnapshots.append(.init(branch: index, layerID: sample.layerID, clipID: sample.clipID,
                        sourceID: sample.sourceID, sourceTime: sample.sourceTime, weight: sample.weight * branch.weight,
                        frame: drawing.frame, viewport: drawing.viewport, opacity: drawing.opacity, audioGain: sample.audioGain * branch.weight))
                }
                layers.append(clips)
            }
            drawingBranches.append(.init(weight: index == 0 ? 1 : branch.weight, layers: layers))
        }
        multiVideoRoot.update(.init(size: output.size, background: state.presentation.background, branches: drawingBranches))
    }

    private func position(_ chart: CALayer, viewport: CGRect, in size: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let scaleX = size.width / viewport.width, scaleY = size.height / viewport.height
        chart.anchorPoint = .zero
        chart.bounds = CGRect(origin: .zero, size: Self.sourceSize)
        chart.position = CGPoint(x: -viewport.minX * scaleX, y: -viewport.minY * scaleY)
        chart.transform = CATransform3DMakeScale(scaleX, scaleY, 1)
    }

    private func makeGrid(in chart: CALayer, camera: Bool, seed: Int = 0) {
        let colors: [NSColor] = camera ? [.systemIndigo, .systemPink, .systemTeal, .systemPurple]
            : [.systemBlue, .systemTeal, .systemOrange, .systemRed]
        for row in 0..<6 {
            for column in 0..<8 {
                let cell = CAShapeLayer()
                let rect = CGRect(x: Double(column) * 240, y: Double(row) * 180, width: 240, height: 180)
                cell.path = CGPath(rect: rect, transform: nil)
                let paletteIndex = (((row / 3) * 2 + column / 4 + seed) % colors.count + colors.count) % colors.count
                cell.fillColor = colors[paletteIndex].withAlphaComponent((row + column).isMultiple(of: 2) ? 0.68 : 0.48).cgColor
                cell.strokeColor = NSColor.white.withAlphaComponent(0.4).cgColor
                cell.lineWidth = 2
                chart.addSublayer(cell)
                let label = CATextLayer()
                label.string = "\(camera ? "C" : "")\(Character(UnicodeScalar(65 + column)!))\(row + 1)"
                label.font = NSFont.monospacedSystemFont(ofSize: 38, weight: .medium)
                label.fontSize = 38
                label.foregroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
                label.alignmentMode = .center
                label.frame = CGRect(x: rect.minX, y: rect.midY - 25, width: rect.width, height: 50)
                label.contentsScale = 2
                chart.addSublayer(label)
            }
        }
    }
}

/// Native vector drawing only: no CI filters, image inputs, video buffers or
/// codecs. Transparency groups make weighted clip sums an explicit documented
/// CGContext operation rather than depending on private layer filter names.
enum EditorVideoVectorDrawing {
    enum ContextCoordinates { case bottomLeft, topLeft }
    struct Clip: Sendable {
        var source: VideoSource
        var sourceSize: CGSize
        var geometry: VideoSampleDrawingGeometry
        var weight: Double
    }
    struct Branch: Sendable { var weight: Double; var layers: [[Clip]] }
    struct Snapshot: Sendable {
        var size: CGSize
        var background: CanvasColor
        var branches: [Branch]
    }
    static func draw(_ snapshot: Snapshot, in context: CGContext, coordinates: ContextCoordinates) {
        let bounds = CGRect(origin: .zero, size: snapshot.size)
        context.saveGState()
        if coordinates == .bottomLeft {
            context.translateBy(x: 0, y: snapshot.size.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.clip(to: bounds)
        for branch in snapshot.branches {
            group(in: context, alpha: branch.weight, blend: .normal) {
                let background = snapshot.background
                context.setFillColor(CGColor(red: background.red, green: background.green, blue: background.blue, alpha: 1))
                context.fill(bounds)
                for layer in branch.layers {
                    group(in: context, alpha: 1, blend: .normal) {
                        for clip in layer {
                            group(in: context, alpha: clip.weight * clip.geometry.opacity, blend: .plusLighter) {
                                draw(clip, in: context)
                            }
                        }
                    }
                }
            }
        }
        context.restoreGState()
    }
    private static func group(in context: CGContext, alpha: Double, blend: CGBlendMode, draw: () -> Void) {
        context.saveGState()
        context.setAlpha(min(1, max(0, alpha)))
        context.setBlendMode(blend)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        draw()
        context.endTransparencyLayer()
        context.restoreGState()
    }
    private static func draw(_ clip: Clip, in context: CGContext) {
        let frame = clip.geometry.frame, viewport = clip.geometry.viewport, size = clip.sourceSize
        guard frame.width > 0, frame.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        context.saveGState()
        context.addPath(CGPath(roundedRect: frame, cornerWidth: clip.geometry.cornerRadius,
            cornerHeight: clip.geometry.cornerRadius, transform: nil))
        context.clip()
        context.translateBy(x: frame.minX, y: frame.minY)
        context.scaleBy(x: frame.width / viewport.width, y: frame.height / viewport.height)
        context.translateBy(x: -viewport.minX, y: -viewport.minY)
        // Source charts are opaque, like ordinary footage. The occurrence's
        // alpha is applied once around the whole source, including its labels.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let palette: [(Double, Double, Double)] = clip.source.role == .camera
            ? [(0.35, 0.3, 0.85), (0.85, 0.25, 0.55), (0.15, 0.65, 0.7), (0.6, 0.25, 0.8)]
            : [(0.15, 0.45, 0.85), (0.15, 0.65, 0.7), (0.85, 0.45, 0.1), (0.85, 0.2, 0.2)]
        let cellSize = CGSize(width: size.width / 8, height: size.height / 6)
        for row in 0..<6 {
            for column in 0..<8 {
                let cell = CGRect(x: Double(column) * cellSize.width, y: Double(row) * cellSize.height,
                    width: cellSize.width, height: cellSize.height)
                let index = (((row / 3) * 2 + column / 4 + clip.source.patternSeed) % 4 + 4) % 4
                let color = palette[index], brightness = (row + column).isMultiple(of: 2) ? 0.68 : 0.48
                context.setFillColor(CGColor(red: color.0 * brightness, green: color.1 * brightness,
                    blue: color.2 * brightness, alpha: 1))
                context.fill(cell)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.4)); context.setLineWidth(size.width / 960)
                context.stroke(cell)
                text("\(Character(UnicodeScalar(65 + column)!))\(row + 1)", center: CGPoint(x: cell.midX, y: cell.midY),
                    size: min(cellSize.width, cellSize.height) * 0.22, in: context)
            }
        }
        let banner = CGRect(x: 0, y: size.height / 2 - size.height / 30, width: size.width, height: size.height / 15)
        context.setFillColor(CGColor(gray: 0, alpha: 0.5)); context.fill(banner)
        text(clip.source.name, center: CGPoint(x: banner.midX, y: banner.midY), size: min(size.width / 24, size.height / 22), in: context)
        context.restoreGState()
    }
    private static func text(_ text: String, center: CGPoint, size: Double, in context: CGContext) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.9)
        ])
        let line = CTLineCreateWithAttributedString(string)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: center.x - width / 2, y: center.y + size * 0.34)
        CTLineDraw(line, context)
    }
}

private final class EditorVideoVectorLayer: CALayer, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = EditorVideoVectorDrawing.Snapshot(size: .zero, background: .black, branches: [])
    override init() {
        super.init()
        contentsScale = 2
        needsDisplayOnBoundsChange = true
    }
    override init(layer: Any) {
        super.init(layer: layer)
        if let original = layer as? EditorVideoVectorLayer { snapshot = original.currentSnapshot() }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    func update(_ snapshot: EditorVideoVectorDrawing.Snapshot) {
        lock.lock(); self.snapshot = snapshot; lock.unlock()
        setNeedsDisplay()
    }
    private func currentSnapshot() -> EditorVideoVectorDrawing.Snapshot {
        lock.lock(); defer { lock.unlock() }; return snapshot
    }
    override func draw(in context: CGContext) {
        // AppKit supplies this layer-backed flipped view's context in top-left
        // coordinates already. Flipping it again inverts both framing and text.
        EditorVideoVectorDrawing.draw(currentSnapshot(), in: context, coordinates: .topLeft)
    }
}
