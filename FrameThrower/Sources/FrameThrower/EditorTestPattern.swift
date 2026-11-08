import AppKit

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
    private(set) var screenViewport = CGRect.zero
    private(set) var cameraViewport = CGRect.zero
    private(set) var screenFrame = CGRect.zero
    private(set) var cameraFrame = CGRect.zero

    init() {
        layer.addSublayer(screenClip)
        layer.addSublayer(cameraClip)
        screenClip.masksToBounds = true
        cameraClip.masksToBounds = true
        screenClip.addSublayer(screen)
        cameraClip.addSublayer(camera)
        makeGrid(in: screen, camera: false)
        makeGrid(in: camera, camera: true)
    }

    func update(in bounds: CGRect, sourceSize: CGSize = EditorTestPattern.sourceSize,
                presentation: CanvasPresentation, zoom: ZoomPlacement,
                placement: PIPPlacement, cameraEnabled: Bool, cameraAspect: Double) {
        layer.frame = bounds
        let geometry = PresentationGeometry(sourceSize: sourceSize, presentation: presentation)
        let output = geometry.outputRect(in: bounds)
        screenFrame = geometry.contentRect(in: bounds)
        screenViewport = zoom.viewport(in: sourceSize)
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
        cameraClip.isHidden = !cameraEnabled || !placement.visible
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

    private func position(_ chart: CALayer, viewport: CGRect, in size: CGSize) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let scaleX = size.width / viewport.width, scaleY = size.height / viewport.height
        chart.anchorPoint = .zero
        chart.bounds = CGRect(origin: .zero, size: Self.sourceSize)
        chart.position = CGPoint(x: -viewport.minX * scaleX, y: -viewport.minY * scaleY)
        chart.transform = CATransform3DMakeScale(scaleX, scaleY, 1)
    }

    private func makeGrid(in chart: CALayer, camera: Bool) {
        let colors: [NSColor] = camera ? [.systemIndigo, .systemPink, .systemTeal, .systemPurple]
            : [.systemBlue, .systemTeal, .systemOrange, .systemRed]
        for row in 0..<6 {
            for column in 0..<8 {
                let cell = CAShapeLayer()
                let rect = CGRect(x: Double(column) * 240, y: Double(row) * 180, width: 240, height: 180)
                cell.path = CGPath(rect: rect, transform: nil)
                cell.fillColor = colors[(row / 3) * 2 + column / 4].withAlphaComponent((row + column).isMultiple(of: 2) ? 0.68 : 0.48).cgColor
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
