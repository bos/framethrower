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

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID?,
         screenGeometry: PIPSourceGeometry, cameraGeometry: PIPSourceGeometry?, renderSize: CGSize,
         cameraStart: Double, cameraEnd: Double, state: EditState) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.screenGeometry = screenGeometry
        self.cameraGeometry = cameraGeometry
        self.renderSize = renderSize
        self.cameraStart = cameraStart
        self.cameraEnd = cameraEnd
        self.state = state
        requiredSourceTrackIDs = ([screenTrackID] + [cameraTrackID].compactMap { $0 }).map { NSNumber(value: $0) }
        super.init()
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
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
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
              let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID),
              let output = request.renderContext.newPixelBuffer() else {
            throw NSError(domain: "FrameThrower.Compositor", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A recording frame could not be rendered."])
        }
        let canvas = CGRect(origin: .zero, size: instruction.renderSize)
        var image = instruction.screenGeometry.orientedImage(screenBuffer)
            .transformed(by: CGAffineTransform(scaleX: canvas.width / instruction.screenGeometry.size.width,
                                              y: canvas.height / instruction.screenGeometry.size.height))
        let seconds = request.compositionTime.seconds
        let placement = instruction.state.placement(at: seconds)
        if placement.visible, seconds >= instruction.cameraStart, seconds < instruction.cameraEnd,
           let cameraID = instruction.cameraTrackID, let geometry = instruction.cameraGeometry,
           let cameraBuffer = request.sourceFrame(byTrackID: cameraID) {
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
        context.render(image.cropped(to: canvas), to: output, bounds: canvas, colorSpace: colorSpace)
        return output
    }
}
