@preconcurrency import AVFoundation
import CoreImage
import Foundation

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

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?,
         screenGeometry: PIPSourceGeometry, cameraGeometry: PIPSourceGeometry?, renderSize: CGSize,
         cameraStart: Double, cameraEnd: Double, state: EditState, focusedCapture: FocusedFrameCapture? = nil) {
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
        requiredSourceTrackIDs = ([screenTrackID] + [cameraTrackID].compactMap { $0 }).map { NSNumber(value: $0) }
        super.init()
    }
    func applying(_ state: EditState, focusedCapture: FocusedFrameCapture? = nil) -> PIPCompositionInstruction {
        PIPCompositionInstruction(timeRange: timeRange, screenTrackID: screenTrackID, cameraTrackID: cameraTrackID,
                                  screenGeometry: screenGeometry, cameraGeometry: cameraGeometry, renderSize: renderSize,
                                  cameraStart: cameraStart, cameraEnd: cameraEnd, state: state, focusedCapture: focusedCapture)
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
    private let composer = PIPFrameComposer()
    private let cancellationLock = NSLock()
    private var cancellationGeneration = 0

    private struct PendingRequest: @unchecked Sendable {
        // AVFoundation requests are designed to be completed asynchronously.
        let request: AVAsynchronousVideoCompositionRequest
        let generation: Int
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        cancellationLock.lock()
        let pending = PendingRequest(request: asyncVideoCompositionRequest, generation: cancellationGeneration)
        cancellationLock.unlock()
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
                    pending.request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancellationLock.lock()
        cancellationGeneration &+= 1
        cancellationLock.unlock()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return generation == cancellationGeneration
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let instruction = request.videoCompositionInstruction as? PIPCompositionInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            throw NSError(domain: "FrameThrower.Compositor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A recording frame could not be rendered."])
        }
        let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID)
        let cameraBuffer = instruction.cameraTrackID.flatMap { request.sourceFrame(byTrackID: $0) }
        instruction.focusedCapture?.capture(screen: screenBuffer, camera: cameraBuffer,
                                             at: request.compositionTime, instruction: instruction)
        let image = composer.image(screen: screenBuffer, camera: cameraBuffer,
                                   instruction: instruction, state: instruction.state,
                                   at: request.compositionTime.seconds, renderSize: instruction.renderSize)
        composer.context.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.renderSize),
                                colorSpace: composer.colorSpace)
        return output
    }
}

/// The single image graph for decoded playback frames, export, and interactive
/// drafts. Live editing supplies the same unmodified screen/camera buffers.
private final class PIPFrameComposer: @unchecked Sendable {
    let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func image(screen screenBuffer: CVPixelBuffer?, camera cameraBuffer: CVPixelBuffer?,
               instruction: PIPCompositionInstruction, state: EditState, at seconds: Double,
               renderSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: renderSize)
        // A track can legitimately have no sample at the start/end of its
        // declared time range (ScreenCaptureKit often starts a fraction late).
        // Missing source pixels are black, never a fatal compositor error or
        // a held frame from another time; camera timing remains independent.
        var image = screenBuffer.map { instruction.screenGeometry.orientedImage($0)
            .transformed(by: CGAffineTransform(scaleX: canvas.width / instruction.screenGeometry.size.width,
                                              y: canvas.height / instruction.screenGeometry.size.height))
        } ?? CIImage(color: .black).cropped(to: canvas)
        let placement = state.placement(at: seconds)
        if placement.visible, seconds >= instruction.cameraStart, seconds < instruction.cameraEnd,
           let geometry = instruction.cameraGeometry, let cameraBuffer {
            let shape = placement.shape
            let sourceCrop = placement.crop.rect(in: geometry.size, shape: shape, aspectRatio: placement.aspectRatio)
            let ciCrop = CGRect(x: sourceCrop.minX, y: geometry.size.height - sourceCrop.maxY,
                                width: sourceCrop.width, height: sourceCrop.height)
            let frame = placement.frame(in: canvas.size, cameraAspect: geometry.size.width / geometry.size.height)
            let destination = CGRect(x: frame.minX, y: canvas.height - frame.maxY, width: frame.width, height: frame.height)
            var camera = geometry.orientedImage(cameraBuffer)
                .cropped(to: ciCrop)
                .transformed(by: CGAffineTransform(translationX: -ciCrop.minX, y: -ciCrop.minY))
                .transformed(by: CGAffineTransform(scaleX: destination.width / ciCrop.width,
                                                  y: destination.height / ciCrop.height))
                .transformed(by: CGAffineTransform(translationX: destination.minX, y: destination.minY))
            if shape == .circle {
                // A one-output-pixel alpha edge keeps circles smooth at every
                // size, without covering corners with a background-colored box.
                let radius = destination.width / 2
                let mask = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: destination.midX, y: destination.midY),
                    "inputRadius0": max(0, radius - 0.5), "inputRadius1": radius + 0.5,
                    "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0)
                ])!.outputImage!.cropped(to: destination)
                camera = camera.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: destination),
                    kCIInputMaskImageKey: mask
                ])
            }
            image = camera.composited(over: image)
        }
        return image.cropped(to: canvas)
    }
}

/// A single frozen playhead's raw source pair. This object owns at most one
/// screen frame and one camera frame; it never retains composed draft images.
final class LivePreviewSources: @unchecked Sendable {
    let time: CMTime
    private let screen: CVPixelBuffer?
    private let camera: CVPixelBuffer?
    private let instruction: PIPCompositionInstruction
    private let sourceTime: CMTime
    private let composer = PIPFrameComposer()
    private let queue = DispatchQueue(label: "framethrower.live-frame-render")

    fileprivate init(time: CMTime, sourceTime: CMTime, screen: CVPixelBuffer?, camera: CVPixelBuffer?,
                     instruction: PIPCompositionInstruction) {
        self.time = time
        self.sourceTime = sourceTime
        self.screen = screen
        self.camera = camera
        // The retained instruction carries geometry only; it must not keep the
        // temporary capture object and its references alive in a cycle.
        self.instruction = instruction.applying(instruction.state)
    }

    func render(applying state: EditState, maximumSize: CGSize) async throws -> CGImage {
        try Task.checkCancellation()
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                autoreleasepool {
                    let native = instruction.renderSize
                    let limit = maximumSize.width > 0 && maximumSize.height > 0 &&
                        maximumSize.width.isFinite && maximumSize.height.isFinite ? maximumSize : native
                    let scale = min(1, limit.width / native.width, limit.height / native.height)
                    let size = CGSize(width: max(1, (native.width * scale).rounded(.down)),
                                      height: max(1, (native.height * scale).rounded(.down)))
                    let image = composer.image(screen: screen, camera: camera, instruction: instruction,
                                               state: state, at: sourceTime.seconds, renderSize: size)
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
