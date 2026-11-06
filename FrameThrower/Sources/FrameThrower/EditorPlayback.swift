@preconcurrency import AVFoundation
import Combine
import SwiftUI

@MainActor
final class EditorPlayback: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var time = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var screenSize = CGSize(width: 16, height: 9)
    @Published private(set) var cameraAspect = 16.0 / 9.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var stillFrame: CGImage?
    private var renderedProject: RenderedProject?
    private let stillRequests = LatestStillFrameQueue<CGImage>()
    private var imageGenerator: AVAssetImageGenerator?
    private var isClosed = false
    private var observer: Any?
    private var generation = 0
    private var bounds = 0.0...1.0
    private var sourceDuration = 0.0
    private var editFrameDuration = 1.0 / 30.0

    var editingTime: Double {
        RecordingProject.editingTime(at: time, duration: sourceDuration, frameDuration: editFrameDuration)
    }

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600),
                                                   queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                self.time = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player.rate > 0
                if self.time >= self.bounds.upperBound {
                    self.pause()
                }
            }
        }
    }

    func rebuild(editor: ProjectEditor) async {
        guard !isClosed else { return }
        generation += 1
        let request = generation
        let snapshot = editor.project
        sourceDuration = snapshot.duration
        let position = min(max(time, snapshot.state.trimStart), snapshot.state.trimEnd)
        player.pause()
        isPlaying = false
        invalidateStillFrames()
        renderedProject = nil
        isLoading = true
        errorMessage = nil
        do {
            let rendered = try await ProjectRenderer.makePreview(project: snapshot,
                directory: editor.url.deletingLastPathComponent())
            guard request == generation, !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: rendered.asset)
            item.videoComposition = rendered.videoComposition
            item.forwardPlaybackEndTime = CMTime(seconds: snapshot.state.trimEnd, preferredTimescale: 600)
            player.replaceCurrentItem(with: item)
            screenSize = rendered.screenSize
            cameraAspect = rendered.cameraAspect
            bounds = snapshot.state.trimStart...snapshot.state.trimEnd
            renderedProject = rendered
            editFrameDuration = rendered.videoComposition.frameDuration.seconds
            let generator = AVAssetImageGenerator(asset: rendered.asset)
            generator.videoComposition = rendered.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 1920, height: 1080)
            imageGenerator = generator
            isLoading = false
            seek(position)
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            invalidateStillFrames()
            renderedProject = nil
            player.replaceCurrentItem(with: nil)
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func seek(_ position: Double) {
        guard !isClosed, !isLoading || renderedProject != nil else { return }
        time = position.isFinite ? min(max(position, bounds.lowerBound), bounds.upperBound) : bounds.lowerBound
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: Self.frameTime(at: time, bounds: bounds), toleranceBefore: .zero, toleranceAfter: .zero)
        updateStillFrame()
    }

    func togglePlayback() {
        guard !isClosed, !isLoading, renderedProject != nil else { return }
        if player.rate > 0 { pause() }
        else {
            if time >= bounds.upperBound - 0.03 { seek(bounds.lowerBound) }
            stillRequests.invalidate()
            imageGenerator?.cancelAllCGImageGeneration()
            stillFrame = nil
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        let wasPlaying = isPlaying
        player.pause()
        isPlaying = false
        if wasPlaying { updateStillFrame() }
    }

    /// CMTime's nanosecond scale keeps the seek strictly inside the retained
    /// interval, even when that interval is shorter than one video frame.
    static func frameTime(at position: Double, bounds: ClosedRange<Double>) -> CMTime {
        let scale: CMTimeScale = 1_000_000_000
        let lower = CMTime(seconds: bounds.lowerBound, preferredTimescale: scale)
        let upper = CMTime(seconds: bounds.upperBound, preferredTimescale: scale)
        let last = CMTimeSubtract(upper, CMTime(value: 1, timescale: scale))
        let requested = CMTime(seconds: position.isFinite ? position : bounds.lowerBound,
                               preferredTimescale: scale)
        return CMTimeMaximum(lower, CMTimeMinimum(requested, last))
    }

    private func updateStillFrame() {
        guard !isClosed, !isPlaying, let imageGenerator else { return }
        let position = Self.frameTime(at: time, bounds: bounds)
        stillRequests.request(
            generate: { try await imageGenerator.image(at: position).image },
            cancel: { imageGenerator.cancelAllCGImageGeneration() },
            receive: { [weak self] image in
                guard let self, !self.isClosed, !self.isPlaying else { return }
                self.stillFrame = image
            },
            failure: { [weak self] in self?.stillFrame = nil }
        )
    }

    private func invalidateStillFrames() {
        stillRequests.invalidate()
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        stillFrame = nil
    }

    func close() {
        generation += 1
        isClosed = true
        player.pause()
        isPlaying = false
        isLoading = false
        invalidateStillFrames()
        renderedProject = nil
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
    }
}

/// There is at most one active decoder operation and one replaceable pending
/// request. Cancellation alone does not bound work: the next operation begins
/// only after the active one actually returns. Invalidated results never arrive.
@MainActor
final class LatestStillFrameQueue<Output> {
    private struct Request {
        let generation: UInt64
        let generate: @MainActor () async throws -> Output
        let cancel: @MainActor () -> Void
        let receive: @MainActor (Output) -> Void
        let failure: @MainActor () -> Void
    }

    private var generation: UInt64 = 0
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var cancelActive: (@MainActor () -> Void)?

    func request(generate: @escaping @MainActor () async throws -> Output,
                 cancel: @escaping @MainActor () -> Void,
                 receive: @escaping @MainActor (Output) -> Void,
                 failure: @escaping @MainActor () -> Void = {}) {
        generation &+= 1
        pending = Request(generation: generation, generate: generate, cancel: cancel,
                          receive: receive, failure: failure)
        cancelCurrentOperation()
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    func invalidate() {
        generation &+= 1
        pending = nil
        cancelCurrentOperation()
    }

    private func cancelCurrentOperation() {
        let cancel = cancelActive
        cancelActive = nil
        cancel?()
    }

    private func run() async {
        defer { worker = nil }
        while let request = pending {
            pending = nil
            cancelActive = request.cancel
            do {
                let output = try await request.generate()
                cancelActive = nil
                if request.generation == generation { request.receive(output) }
            } catch {
                cancelActive = nil
                // Remove an obsolete overlay if the current frame cannot be
                // decoded, leaving AVPlayer visible as the fallback.
                if request.generation == generation { request.failure() }
            }
        }
    }
}

struct EditorPlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ view: PlayerSurface, context: Context) { view.playerLayer.player = player }

    final class PlayerSurface: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
