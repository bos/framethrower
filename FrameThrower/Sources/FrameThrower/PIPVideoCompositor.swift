@preconcurrency import AVFoundation
import CoreImage
import CoreText
import Foundation
import ImageIO

/// An immutable edit snapshot shared by AVPlayer, still previews, and export.
final class PIPCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID?
    let screenGeometry: PIPSourceGeometry
    let cameraGeometry: PIPSourceGeometry?
    let renderSize: CGSize
    let cameraStart: Double
    let cameraEnd: Double
    let state: EditState
    let focusedCapture: FocusedFrameCapture?
    let cursorRecording: CursorRecording?
    let previewFrames: PreviewSourceFrames?
    let contentAssets: [ContentImageAsset]

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?,
         screenGeometry: PIPSourceGeometry, cameraGeometry: PIPSourceGeometry?, renderSize: CGSize,
         cameraStart: Double, cameraEnd: Double, state: EditState, focusedCapture: FocusedFrameCapture? = nil, cursorRecording: CursorRecording? = nil, previewFrames: PreviewSourceFrames? = nil,
         contentAssets: [ContentImageAsset] = []) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.screenGeometry = screenGeometry
        self.cameraGeometry = cameraGeometry
        self.renderSize = renderSize
        self.cameraStart = cameraStart
        self.cameraEnd = cameraEnd
        self.state = state
        self.focusedCapture = focusedCapture
        self.cursorRecording = cursorRecording
        self.previewFrames = previewFrames
        self.contentAssets = contentAssets
        requiredSourceTrackIDs = ([screenTrackID] + [cameraTrackID].compactMap { $0 }).map { NSNumber(value: $0) }
        super.init()
    }
    func applying(_ state: EditState, focusedCapture: FocusedFrameCapture? = nil,
                  preservePreviewFrames: Bool = true, renderSize: CGSize? = nil) -> PIPCompositionInstruction {
        PIPCompositionInstruction(timeRange: timeRange, screenTrackID: screenTrackID, cameraTrackID: cameraTrackID,
                                  screenGeometry: screenGeometry, cameraGeometry: cameraGeometry,
                                  renderSize: renderSize ?? PresentationGeometry(sourceSize: screenGeometry.size,
                                                                                presentation: state.presentation).outputSize,
                                  cameraStart: cameraStart, cameraEnd: cameraEnd, state: state, focusedCapture: focusedCapture,
                                  cursorRecording: cursorRecording,
                                  previewFrames: preservePreviewFrames && focusedCapture == nil ? previewFrames : nil,
                                  contentAssets: contentAssets)
    }

}

/// Cut compositions request at most two simultaneous retained branches. Track
/// IDs alternate between clips; source timestamps still drive every visual edit.
final class CutCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    struct Branch {
        let screenTrackID: CMPersistentTrackID
        let cameraTrackID: CMPersistentTrackID?
    }
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    let timingMap: RecordingTimeMap
    let branches: [Branch]
    let template: PIPCompositionInstruction

    init(timingMap: RecordingTimeMap, branches: [Branch], template: PIPCompositionInstruction) {
        self.timingMap = timingMap; self.branches = branches; self.template = template
        timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: timingMap.outputDuration, preferredTimescale: 60_000))
        requiredSourceTrackIDs = Set(branches.flatMap { [$0.screenTrackID] + [$0.cameraTrackID].compactMap { $0 } })
            .sorted().map { NSNumber(value: $0) }
        super.init()
    }
    func applying(_ state: EditState, renderSize: CGSize? = nil) -> CutCompositionInstruction {
        CutCompositionInstruction(timingMap: timingMap, branches: branches,
            template: template.applying(state, preservePreviewFrames: false, renderSize: renderSize))
    }
}

struct PIPSourceGeometry: Sendable {
    let size: CGSize
    /// Maps source top-left coordinates to oriented, origin-normalized top-left coordinates.
    let transform: CGAffineTransform

    func orientedImage(_ buffer: CVPixelBuffer) -> CIImage {
        // Core Image uses a bottom-left origin. Preferred video transforms use
        // top-left coordinates; flip both sides of the transform explicitly.
        let inputHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        let ciTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: inputHeight)
            .concatenating(transform)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
        return CIImage(cvPixelBuffer: buffer).transformed(by: ciTransform)
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}

/// All composition requests are rendered on one queue. The instruction is an
/// immutable snapshot; Core Image renders the same pixels in every consumer.
final class PIPVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()]
    }

    private let queue = DispatchQueue(label: "framethrower.pip-compositor")
    private lazy var composer = PIPFrameComposer()
    private let cancellationLock = NSLock()
    private var cancellationGeneration = 0

    private struct PendingRequest: @unchecked Sendable {
        // AVFoundation requests are designed to be completed asynchronously.
        let request: AVAsynchronousVideoCompositionRequest
        let generation: Int
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        guard !MediaProcessing.isSuspended else {
            asyncVideoCompositionRequest.finish(with: MediaProcessing.Suspended())
            return
        }
        cancellationLock.lock()
        let pending = PendingRequest(request: asyncVideoCompositionRequest, generation: cancellationGeneration)
        // Enqueue under the same lock as the epoch snapshot. Otherwise a
        // cancellation could drain the queue before this old request arrives.
        queue.async { [self] in
            autoreleasepool {
                guard isCurrent(pending.generation) else {
                    pending.request.finishCancelledRequest()
                    return
                }
                do {
                    let output = try render(pending.request)
                    if isCurrent(pending.generation) {
                        pending.request.finish(withComposedVideoFrame: output)
                    } else {
                        pending.request.finishCancelledRequest()
                    }
                } catch {
                    if isCurrent(pending.generation) { pending.request.finish(with: error) }
                    else { pending.request.finishCancelledRequest() }
                }
            }
        }
        cancellationLock.unlock()
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancellationLock.lock()
        cancellationGeneration &+= 1
        cancellationLock.unlock()
        // AVVideoCompositing requires every pending request's completion or
        // cancellation callback before this method returns. The serial drain
        // also prevents an old decoder generation finishing into a new seek.
        queue.sync { }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return generation == cancellationGeneration
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let output = request.renderContext.newPixelBuffer() else {
            throw NSError(domain: "FrameThrower.Compositor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A recording frame could not be allocated."])
        }
        if let cut = request.videoCompositionInstruction as? CutCompositionInstruction {
            let canvas = CGRect(origin: .zero, size: cut.template.renderSize)
            var blended: CIImage?
            for sample in cut.timingMap.samples(at: request.compositionTime.seconds) {
                let branch = cut.branches[sample.clipIndex]
                let image = try composer.image(screen: request.sourceFrame(byTrackID: branch.screenTrackID),
                    camera: branch.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) },
                    instruction: cut.template, state: cut.template.state, at: sample.sourceTime,
                    renderSize: cut.template.renderSize)
                if let outgoing = blended {
                    blended = outgoing.applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputTargetImageKey: image, kCIInputTimeKey: sample.weight
                    ]).cropped(to: canvas)
                } else { blended = image }
            }
            let image = blended ?? CIImage(color: .black).cropped(to: canvas)
            composer.context.render(image, to: output, bounds: canvas, colorSpace: composer.colorSpace)
            return output
        }
        guard let instruction = request.videoCompositionInstruction as? PIPCompositionInstruction else {
            throw NSError(domain: "FrameThrower.Compositor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A recording frame could not be rendered."])
        }
        let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID)
        let cameraBuffer = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }
        instruction.focusedCapture?.capture(screen: screenBuffer, camera: cameraBuffer,
                                             at: request.compositionTime, instruction: instruction)
        instruction.previewFrames?.capture(screen: screenBuffer, camera: cameraBuffer,
                                            at: request.compositionTime, instruction: instruction)
        let image = try composer.image(screen: screenBuffer, camera: cameraBuffer,
                                   instruction: instruction, state: instruction.state,
                                   at: request.compositionTime.seconds, renderSize: instruction.renderSize)
        composer.context.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.renderSize),
                                colorSpace: composer.colorSpace)
        return output
    }
}

/// Vector/text drawing shared by the suspended canvas and media renderer.
/// The caller supplies a top-left coordinate system. This helper never loads
/// image files, creates video frames, or allocates a bitmap.
enum ContentLayerDrawing {
    static func draw(_ layer: ContentLayer, in context: CGContext, rect: CGRect,
                     canvasSize: CGSize, image: CGImage? = nil, imagePlaceholder: Bool = false) {
        context.saveGState()
        defer { context.restoreGState() }
        let color = CGColor(red: layer.color.red, green: layer.color.green, blue: layer.color.blue, alpha: 1)
        context.setStrokeColor(color); context.setFillColor(color)
        let line = layer.strokeWidth * min(canvasSize.width, canvasSize.height)
        context.setLineWidth(line); context.setLineCap(.round); context.setLineJoin(.round)
        switch layer.kind {
        case .text:
            drawText(layer.text, in: context, rect: rect, size: layer.fontSize * canvasSize.height,
                     bold: layer.bold, color: color)
        case .rectangle, .circle:
            let inset = min(line / 2, min(rect.width, rect.height) / 4)
            let shape = rect.insetBy(dx: inset, dy: inset)
            if layer.kind == .circle { context.addEllipse(in: shape) } else { context.addRect(shape) }
            context.drawPath(using: layer.filled ? .fill : .stroke)
        case .arrow:
            let inset = min(line / 2, rect.width / 8)
            let head = min(rect.height / 2, rect.width / 3)
            context.move(to: CGPoint(x: rect.minX + inset, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.midY))
            context.strokePath()
            context.move(to: CGPoint(x: rect.maxX - inset - head, y: rect.midY - head))
            context.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX - inset - head, y: rect.midY + head))
            context.strokePath()
        case .image:
            if let image {
                let fitted = fittedRect(source: CGSize(width: Double(image.width), height: Double(image.height)), in: rect)
                // CGImage draws in a bottom-left coordinate system.
                context.translateBy(x: fitted.minX, y: fitted.maxY); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: fitted.size))
            } else if imagePlaceholder {
                context.setLineDash(phase: 0, lengths: [5, 4]); context.stroke(rect.insetBy(dx: 1, dy: 1))
                drawText("Image", in: context, rect: rect,
                    size: min(canvasSize.height * 0.035, rect.height * 0.4), bold: false, color: color)
            }
        }
    }

    static func fittedRect(source: CGSize, in bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func drawText(_ text: String, in context: CGContext, rect: CGRect,
                                 size: Double, bold: Bool, color: CGColor) {
        let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, max(1, size), nil)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) {
            CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: $0)], 1)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
            CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}

/// Only the guarded media pipeline calls this raster cache. Static artwork is
/// cached separately from per-frame movement, rotation and fades, with a 64 MiB
/// cap. Image data is decoded lazily; the suspended editor uses vectors only.
private final class ContentLayerRasterCache {
    private struct Entry {
        let layer: ContentLayer
        let asset: ContentImageAsset?
        let canvas: CGSize
        let image: CIImage
        let cost: Int
    }
    private var entries: [UUID: Entry] = [:]
    private var cost = 0

    func image(for layer: ContentLayer, assets: [ContentImageAsset], canvas: CGSize) throws -> CIImage {
        try MediaProcessing.requireEnabled()
        let asset = layer.assetID.flatMap { id in assets.first { $0.id == id } }
        if let entry = entries[layer.id], entry.layer == layer, entry.asset == asset, entry.canvas == canvas { return entry.image }
        let native = CGSize(width: canvas.width * layer.rect.width, height: canvas.height * layer.rect.height)
        let scale = min(1, 4096 / max(native.width, native.height))
        let width = max(1, Int(ceil(native.width * scale))), height = max(1, Int(ceil(native.height * scale)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProjectError.invalid("The content layer could not be rendered.")
        }
        var decoded: CGImage?
        if layer.kind == .image {
            guard let asset, let source = CGImageSourceCreateWithData(asset.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ProjectError.invalid("A content image cannot be decoded. Replace it in Layers.")
            }
            decoded = image
        }
        context.translateBy(x: 0, y: Double(height)); context.scaleBy(x: 1, y: -1)
        ContentLayerDrawing.draw(layer, in: context, rect: CGRect(x: 0, y: 0, width: Double(width), height: Double(height)),
            canvasSize: CGSize(width: canvas.width * scale, height: canvas.height * scale), image: decoded)
        guard let pixels = context.makeImage() else { throw ProjectError.invalid("The content layer could not be rendered.") }
        let image = CIImage(cgImage: pixels)
        if let old = entries.removeValue(forKey: layer.id) { cost -= old.cost }
        let bytes = pixels.bytesPerRow * pixels.height
        if cost + bytes > 64 * 1024 * 1024 { entries.removeAll(); cost = 0 }
        if bytes <= 64 * 1024 * 1024 {
            entries[layer.id] = Entry(layer: layer, asset: asset, canvas: canvas, image: image, cost: bytes)
            cost += bytes
        }
        return image
    }
}

/// The single image graph for decoded playback frames, export, and interactive
/// drafts. Live editing supplies the same unmodified screen/camera buffers.
private final class PIPFrameComposer: @unchecked Sendable {
    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let layerArtwork = ContentLayerRasterCache()

    func image(screen screenBuffer: CVPixelBuffer?, camera cameraBuffer: CVPixelBuffer?,
               instruction: PIPCompositionInstruction, state: EditState, at seconds: Double,
               renderSize: CGSize) throws -> CIImage {
        let canvas = CGRect(origin: .zero, size: renderSize)
        let presentation = PresentationGeometry(sourceSize: instruction.screenGeometry.size,
                                                presentation: state.presentation)
        let content = presentation.contentRect(in: canvas)
        let sourceCanvas = CGRect(origin: .zero, size: content.size)
        // A track can legitimately have no sample at the start/end of its
        // declared time range (ScreenCaptureKit often starts a fraction late).
        // Missing source pixels are black, never a fatal compositor error or
        // a held frame from another time; camera timing remains independent.
        var image = screenBuffer.map { instruction.screenGeometry.orientedImage($0)
            .transformed(by: CGAffineTransform(scaleX: content.width / instruction.screenGeometry.size.width,
                                              y: content.height / instruction.screenGeometry.size.height))
        } ?? CIImage(color: .black).cropped(to: sourceCanvas)
        let zoom = state.zoom(at: seconds).clamped
        let zoomScale = zoom.scale
        if zoomScale > 1 {
            // The same source viewport helper drives native focus/pan controls.
            // Clamp the viewport rather than exposing empty space at an edge.
            let topLeftViewport = zoom.viewport(in: sourceCanvas.size)
            let viewport = CGRect(x: topLeftViewport.minX, y: sourceCanvas.height - topLeftViewport.maxY,
                                  width: topLeftViewport.width, height: topLeftViewport.height)
            image = image.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -viewport.minX, y: -viewport.minY))
                .transformed(by: CGAffineTransform(scaleX: zoomScale, y: zoomScale))
                .cropped(to: sourceCanvas)
        }
        if let recording = instruction.cursorRecording, state.cursorStyle.visible {
            image = cursor(over: image, recording: recording, style: state.cursorStyle,
                           zoom: zoom, at: seconds, canvas: sourceCanvas)
        }
        // Zoom and pointer coordinates remain attached to the full screen
        // source. Presentation frames that source only after its edits render.
        image = image.cropped(to: sourceCanvas)
        if presentation.cornerRadius > 0 {
            let scale = min(canvas.width / presentation.outputSize.width,
                            canvas.height / presentation.outputSize.height)
            if let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: sourceCanvas),
                "inputRadius": presentation.cornerRadius * scale,
                "inputColor": CIColor.white
            ])?.outputImage?.cropped(to: sourceCanvas) {
                image = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: sourceCanvas),
                    kCIInputMaskImageKey: mask
                ])
            }
        }
        image = image.transformed(by: CGAffineTransform(translationX: content.minX,
                                                       y: canvas.height - content.maxY))
        let background = state.presentation.background
        image = image.composited(over: CIImage(color: CIColor(red: background.red, green: background.green,
                                                             blue: background.blue)).cropped(to: canvas))
        // Camera placement is in the final output canvas, so it stays steady
        // while the screen content zooms or pans underneath it.
        let placement = state.placement(at: seconds)
        if placement.renderedOpacity > 0, seconds >= instruction.cameraStart, seconds < instruction.cameraEnd,
           let geometry = instruction.cameraGeometry, let cameraBuffer {
            let sourceCrop = placement.sourceViewport(in: geometry.size, canvas: canvas.size)
            let ciCrop = CGRect(x: sourceCrop.minX, y: geometry.size.height - sourceCrop.maxY,
                                width: sourceCrop.width, height: sourceCrop.height)
            let frame = placement.frame(in: canvas.size, cameraAspect: geometry.size.width / geometry.size.height)
            let destination = CGRect(x: frame.minX, y: canvas.height - frame.maxY, width: frame.width, height: frame.height)
            var camera = geometry.orientedImage(cameraBuffer).clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
                .transformed(by: CGAffineTransform(scaleX: destination.width / ciCrop.width,
                                                  y: destination.height / ciCrop.height))
                .transformed(by: CGAffineTransform(translationX: destination.minX, y: destination.minY))
                .cropped(to: destination)
            let radius = placement.cornerRadius(in: destination.size)
            if radius > 0, let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: destination), "inputRadius": radius, "inputColor": CIColor.white
            ])?.outputImage?.cropped(to: destination) {
                camera = camera.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: destination),
                    kCIInputMaskImageKey: mask
                ])
            }
            if placement.renderedOpacity < 1 {
                camera = camera.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: placement.renderedOpacity)
                ])
            }
            image = camera.composited(over: image)
        }
        for layer in state.contentLayers {
            let alpha = layer.alpha(at: seconds)
            guard alpha > 0 else { continue }
            let artwork = try layerArtwork.image(for: layer, assets: instruction.contentAssets, canvas: renderSize)
            let rect = layer.frame(at: seconds)
            let frame = CGRect(x: rect.x * canvas.width, y: rect.y * canvas.height,
                               width: rect.width * canvas.width, height: rect.height * canvas.height)
            var overlay = artwork.transformed(by: CGAffineTransform(scaleX: frame.width / artwork.extent.width,
                                                                    y: frame.height / artwork.extent.height))
                .transformed(by: CGAffineTransform(translationX: -frame.width / 2, y: -frame.height / 2))
                .transformed(by: CGAffineTransform(rotationAngle: -layer.rotation * .pi / 180))
                .transformed(by: CGAffineTransform(translationX: frame.midX, y: canvas.height - frame.midY))
            if alpha < 1 {
                overlay = overlay.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
            }
            image = overlay.composited(over: image)
        }
        return image.cropped(to: canvas)
    }

    private func cursor(over background: CIImage, recording: CursorRecording, style: CursorStyle,
                        zoom: ZoomPlacement, at seconds: Double, canvas: CGRect) -> CIImage {
        let size = style.size.isFinite ? min(4, max(1, style.size)) : 1.5
        let pointScale = canvas.width / max(1, recording.logicalSize.width) * size * zoom.scale
        let viewport = zoom.viewport(in: canvas.size)
        func position(x: Double, y: Double) -> CGPoint {
            CGPoint(x: (x * canvas.width - viewport.minX) * zoom.scale,
                    y: canvas.height - (y * canvas.height - viewport.minY) * zoom.scale)
        }
        var image = background
        if style.clickHighlight {
            for click in recording.clicks {
                let age = seconds - click.time
                guard age >= 0, age < 0.45, (0...1).contains(click.x), (0...1).contains(click.y) else { continue }
                let progress = age / 0.45
                let center = position(x: click.x, y: click.y)
                let radius = (9 + 16 * progress) * pointScale
                let bounds = CGRect(x: center.x - radius - 2, y: center.y - radius - 2,
                                    width: radius * 2 + 4, height: radius * 2 + 4)
                let outer = disk(center: center, radius: radius + 1)
                let inner = disk(center: center, radius: max(0, radius - 1))
                let ring = outer.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: inner])
                    .cropped(to: bounds)
                let color = click.button == 0 ? CIColor(red: 0.18, green: 0.65, blue: 1, alpha: 0.8 * (1 - progress))
                    : CIColor(red: 1, green: 0.62, blue: 0.15, alpha: 0.8 * (1 - progress))
                let pulse = CIImage(color: color).cropped(to: bounds).applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: bounds),
                    kCIInputMaskImageKey: ring
                ])
                image = pulse.composited(over: image)
            }
        }
        if let pointer = recording.pointer(at: seconds, smoothing: style.smoothing), pointer.visible,
           (0...1).contains(pointer.x), (0...1).contains(pointer.y) {
            let hotspot = position(x: pointer.x, y: pointer.y)
            let scale = pointScale / CursorArtwork.rasterScale
            let glyph = CIImage(cgImage: CursorArtwork.arrow)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: hotspot.x - CursorArtwork.hotspot.x * pointScale,
                    y: hotspot.y - (CursorArtwork.logicalSize.height - CursorArtwork.hotspot.y) * pointScale
                ))
            image = glyph.composited(over: image)
        }
        return image.cropped(to: canvas)
    }

    private func disk(center: CGPoint, radius: Double) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(cgPoint: center),
            "inputRadius0": max(0, radius - 0.5), "inputRadius1": radius + 0.5,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0)
        ])!.outputImage!
    }
}

/// Rasterized once at 4× logical resolution; every view size shares this
/// vector silhouette, preserving a precise tip hotspot and a readable border.
private enum CursorArtwork {
    static let rasterScale = 4.0
    static let logicalSize = CGSize(width: 24, height: 32)
    static let hotspot = CGPoint(x: 3, y: 3)
    static let arrow: CGImage = {
        let context = CGContext(data: nil, width: 96, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: rasterScale, y: rasterScale)
        context.translateBy(x: 0, y: logicalSize.height)
        context.scaleBy(x: 1, y: -1)
        let path = CGMutablePath()
        path.move(to: hotspot)
        for point in [CGPoint(x: 3, y: 25), CGPoint(x: 8.4, y: 20.4), CGPoint(x: 12.7, y: 29),
                      CGPoint(x: 17.2, y: 26.8), CGPoint(x: 13, y: 18.5), CGPoint(x: 21, y: 18.5)] {
            path.addLine(to: point)
        }
        path.closeSubpath()
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.5,
                          color: CGColor(gray: 0, alpha: 0.6))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0.05, alpha: 1))
        context.setLineWidth(1.4)
        context.setLineJoin(.round)
        context.addPath(path)
        context.drawPath(using: .fillStroke)
        return context.makeImage()!
    }()
}

/// A single frozen playhead's raw source pair. This object owns at most one
/// screen frame and one camera frame; it never retains composed draft images.
final class LivePreviewSources: @unchecked Sendable {
    let time: CMTime
    private let screen: CVPixelBuffer?
    private let camera: CVPixelBuffer?
    private let instruction: PIPCompositionInstruction
    private let sourceTime: CMTime
    private lazy var composer = PIPFrameComposer()
    private let queue = DispatchQueue(label: "framethrower.live-frame-render")

    fileprivate init(time: CMTime, sourceTime: CMTime, screen: CVPixelBuffer?, camera: CVPixelBuffer?,
                     instruction: PIPCompositionInstruction) {
        self.time = time
        self.sourceTime = sourceTime
        self.screen = screen
        self.camera = camera
        // The retained instruction carries geometry only; it must not keep the
        // temporary capture object and its references alive in a cycle.
        self.instruction = instruction.applying(instruction.state, preservePreviewFrames: false)
    }

    /// Full, oriented camera source for the framing editor. It shares the
    /// frozen native decode and GPU queue; no independent decoder is opened.
    func cameraImage(maximumSize: CGSize = CGSize(width: 1920, height: 1080)) async throws -> CGImage? {
        try MediaProcessing.requireEnabled()
        try Task.checkCancellation()
        guard camera != nil, let geometry = instruction.cameraGeometry,
              sourceTime.seconds >= instruction.cameraStart, sourceTime.seconds < instruction.cameraEnd else { return nil }
        let image: CGImage? = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                autoreleasepool {
                    guard let camera else { continuation.resume(returning: nil); return }
                    let native = geometry.size
                    let limit = maximumSize.width > 0 && maximumSize.height > 0 &&
                        maximumSize.width.isFinite && maximumSize.height.isFinite ? maximumSize : native
                    let scale = min(1, limit.width / native.width, limit.height / native.height)
                    let size = CGSize(width: max(1, (native.width * scale).rounded(.down)),
                                      height: max(1, (native.height * scale).rounded(.down)))
                    let image = geometry.orientedImage(camera)
                        .transformed(by: CGAffineTransform(scaleX: size.width / native.width, y: size.height / native.height))
                    if let result = composer.context.createCGImage(image, from: CGRect(origin: .zero, size: size),
                                                                   format: .RGBA8, colorSpace: composer.colorSpace) {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: NSError(domain: "FrameThrower.Compositor", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "The camera framing preview could not be rendered."]))
                    }
                }
            }
        }
        try Task.checkCancellation()
        return image
    }

    func render(applying state: EditState, maximumSize: CGSize) async throws -> CGImage {
        try MediaProcessing.requireEnabled()
        try Task.checkCancellation()
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                autoreleasepool {
                    let native = PresentationGeometry(sourceSize: instruction.screenGeometry.size,
                                                      presentation: state.presentation).outputSize
                    let limit = maximumSize.width > 0 && maximumSize.height > 0 &&
                        maximumSize.width.isFinite && maximumSize.height.isFinite ? maximumSize : native
                    let scale = min(1, limit.width / native.width, limit.height / native.height)
                    let size = CGSize(width: max(1, (native.width * scale).rounded(.down)),
                                      height: max(1, (native.height * scale).rounded(.down)))
                    let image: CIImage
                    do {
                        image = try composer.image(screen: screen, camera: camera, instruction: instruction,
                                                   state: state, at: sourceTime.seconds, renderSize: size)
                    } catch { continuation.resume(throwing: error); return }
                    if let result = composer.context.createCGImage(image, from: CGRect(origin: .zero, size: size),
                                                                   format: .RGBA8, colorSpace: composer.colorSpace) {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: NSError(domain: "FrameThrower.Compositor", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "The live recording preview could not be rendered."]))
                    }
                }
            }
        }
        try Task.checkCancellation()
        return image
    }
}

/// Retains only the closest native-decoded source pair for one explicitly
/// requested playhead. Exports never request a playhead, so they retain nothing.
/// Capture stores raw buffers and immutable geometry only; the Core Image
/// context is constructed lazily when an editor freezes this pair for editing.
final class PreviewSourceFrames: @unchecked Sendable {
    private struct Snapshot {
        let sourceTime: CMTime
        let screen: CVPixelBuffer?
        let camera: CVPixelBuffer?
        let instruction: PIPCompositionInstruction
    }

    private let lock = NSLock()
    private let tolerance: Double
    private var target: CMTime?
    private var closestDistance = Double.infinity
    private var snapshot: Snapshot?
    private var frozenSources: LivePreviewSources?

    init(frameDuration: CMTime = CMTime(value: 1, timescale: 30)) {
        let seconds = frameDuration.seconds
        tolerance = seconds.isFinite && seconds > 0 ? seconds + 0.000_001 : 1.0 / 30 + 0.000_001
    }

    func request(at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard time.seconds.isFinite, time >= .zero else {
            target = nil
            closestDistance = .infinity
            snapshot = nil
            frozenSources = nil
            return
        }
        // AVPlayer can finish an exact zero-distance seek without rendering a
        // new frame. Preserve the already-frozen source for that same target.
        if let target, CMTimeCompare(target, time) == 0 { return }
        target = time
        closestDistance = .infinity
        snapshot = nil
        frozenSources = nil
    }

    func capture(screen: CVPixelBuffer?, camera: CVPixelBuffer?, at time: CMTime,
                 instruction: PIPCompositionInstruction) {
        guard time.seconds.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let target else { return }
        let distance = abs(time.seconds - target.seconds)
        guard distance <= tolerance, distance < closestDistance else { return }
        closestDistance = distance
        // Detaching both sinks prevents store→instruction→store cycles and
        // keeps generator-local capture state out of the retained source pair.
        snapshot = Snapshot(sourceTime: time, screen: screen, camera: camera,
            instruction: instruction.applying(instruction.state, preservePreviewFrames: false))
        frozenSources = nil
    }

    func sources(at time: CMTime) -> LivePreviewSources? {
        guard time.seconds.isFinite else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let target, CMTimeCompare(target, time) == 0, let snapshot,
              abs(snapshot.sourceTime.seconds - time.seconds) <= tolerance else { return nil }
        if let frozenSources { return frozenSources }
        let sources = LivePreviewSources(time: target, sourceTime: snapshot.sourceTime,
            screen: snapshot.screen, camera: snapshot.camera, instruction: snapshot.instruction)
        frozenSources = sources
        return sources
    }
}

/// A preparation-local sink. AVFoundation may prefetch adjacent frames; only
/// the closest frame to this frozen playhead is retained, and cancellation
/// permanently rejects late decoder callbacks.
final class FocusedFrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let target: CMTime
    private let tolerance: Double
    private var active = true
    private var closestDistance = Double.infinity
    private var sources: LivePreviewSources?

    init(target: CMTime, frameDuration: CMTime) {
        self.target = target
        tolerance = max(0.000_001, frameDuration.seconds)
    }

    func capture(screen: CVPixelBuffer?, camera: CVPixelBuffer?, at time: CMTime,
                 instruction: PIPCompositionInstruction) {
        let distance = abs(time.seconds - target.seconds)
        guard distance.isFinite, distance <= tolerance else { return }
        lock.lock()
        defer { lock.unlock() }
        guard active, distance < closestDistance else { return }
        closestDistance = distance
        sources = LivePreviewSources(time: target, sourceTime: time, screen: screen, camera: camera, instruction: instruction)
    }

    func finish() -> LivePreviewSources? {
        lock.lock()
        defer { lock.unlock() }
        active = false
        let result = sources
        sources = nil
        return result
    }

    func invalidate() {
        lock.lock()
        active = false
        sources = nil
        lock.unlock()
    }
}
