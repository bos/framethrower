@preconcurrency import AVFoundation
import Combine
import SwiftUI

@MainActor
final class EditorFrameStore: ObservableObject {
    @Published var image: CGImage?
}

@MainActor
final class EditorPlayback: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var time = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var screenSize = CGSize(width: 16, height: 9)
    @Published private(set) var sourceSize = CGSize(width: 16, height: 9)
    @Published private(set) var cameraAspect = 16.0 / 9.0
    @Published private(set) var errorMessage: String?
    let frameStore = EditorFrameStore()
    private(set) var stillFrame: CGImage? {
        get { frameStore.image }
        set { frameStore.image = newValue }
    }
    @Published private(set) var isScrubbing = false
    private var renderedProject: RenderedProject?
    private let stillRequests = LatestStillFrameQueue<CGImage>()
    private var committedState: EditState?
    private var liveSources: LiveStillFrameCache?
    private var isClosed = false
    private var observer: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var generation = 0
    private var bounds = 0.0...1.0
    private var sourceDuration = 0.0
    private var sourceBounds: ClosedRange<Double> { 0...max(0, sourceDuration) }
    private var editFrameDuration = 1.0 / 30.0
    private var draftState: EditState?
    private var pendingDraftState: EditState?
    private var draftGeneration: UInt64 = 0
    private var committedStillFrame: CGImage?
    private var committedStillTime: Double?
    private var seekGeneration: UInt64 = 0
    private var seekInFlight = false
    private var pendingSeek: CMTime?
    private var scrubGestureActive = false
    private var nativeFrameTask: Task<Void, Never>?

    private enum NativeFrameError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The paused recording frame could not be prepared." }
    }

    var isPreviewing: Bool { draftState != nil || pendingDraftState != nil }
    var canPlay: Bool { !isClosed && !isLoading && renderedProject != nil }

    var cursorRecording: CursorRecording? {
        renderedProject?.videoComposition.instructions
            .compactMap { $0 as? PIPCompositionInstruction }.first?.cursorRecording
    }


    var editingTime: Double {
        RecordingProject.editingTime(at: time, duration: sourceDuration, frameDuration: editFrameDuration)
    }

    init() {
        guard !MediaProcessing.isSuspended else { return }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600),
                                                   queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, self.draftState == nil,
                      self.isPlaying, !self.isLoading,
                      !self.isScrubbing, !self.seekInFlight, self.pendingSeek == nil else { return }
                self.time = time.seconds.isFinite ? time.seconds : 0
                if self.time >= self.bounds.upperBound {
                    self.pause()
                }
            }
        }
    }

    func rebuild(editor: ProjectEditor) async {
        guard !isClosed else { return }
        generation += 1
        itemStatusObservation = nil
        invalidateSeeks()
        let request = generation
        let snapshot = editor.project
        sourceDuration = snapshot.duration
        bounds = snapshot.state.trimStart...snapshot.state.trimEnd
        time = bounded(time, to: sourceBounds)
        player.pause()
        isPlaying = false
        // A successful gesture commits this exact draft next. Keep its last
        // displayed pixels across the rebuild so release never flashes back to
        // the old player's camera position; pending draft work is invalidated.
        let retainedDraftFrame = isPreviewing ? stillFrame : nil
        invalidateStillFrames()
        stillFrame = retainedDraftFrame
        renderedProject = nil
        isLoading = true
        errorMessage = nil
        if MediaProcessing.isSuspended {
            // Keep source-time editing and geometry usable without opening a
            // movie, constructing a composition, or attaching a decoder.
            player.replaceCurrentItem(with: nil)
            sourceSize = CGSize(width: 1920, height: 1080)
            screenSize = PresentationGeometry(sourceSize: sourceSize, presentation: snapshot.state.presentation).outputSize
            editFrameDuration = snapshot.captureFrameDuration ?? 1.0 / 30
            committedState = snapshot.state
            stillFrame = nil
            isLoading = false
            return
        }
        do {
            let rendered = try await ProjectRenderer.makePreview(project: snapshot,
                directory: editor.url.deletingLastPathComponent())
            guard request == generation, !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: rendered.asset)
            item.videoComposition = rendered.videoComposition
            item.audioMix = rendered.audioMix
            // A seek is not visually complete until the custom compositor has
            // produced its frame. Otherwise the next chase can starve display.
            item.seekingWaitsForVideoCompositionRendering = true
            // Trimming restricts playback/export, not inspection of source-time
            // edits. Set a playback end only while actually playing.
            item.forwardPlaybackEndTime = .invalid
            observeStatus(of: item, generation: request)
            // A user can select/scrub another time while makePreview awaits
            // media metadata. Honor that newest request instead of a position
            // captured before the rebuild started.
            let position = bounded(time, to: sourceBounds)
            // The player may preroll its first frame as soon as the item is
            // attached, before a zero-distance seek asks it to render again.
            rendered.previewFrames.request(at: Self.frameTime(at: position,
                bounds: sourceBounds))
            player.replaceCurrentItem(with: item)
            screenSize = rendered.screenSize
            sourceSize = rendered.sourceSize
            cameraAspect = rendered.cameraAspect
            bounds = snapshot.state.trimStart...snapshot.state.trimEnd
            renderedProject = rendered
            editFrameDuration = rendered.videoComposition.frameDuration.seconds
            committedState = snapshot.state
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

    private func observeStatus(of item: AVPlayerItem, generation request: Int) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, request == self.generation,
                      self.player.currentItem === item, item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "The recording could not be played."
                guard self.errorMessage != message else { return }
                self.player.pause()
                if self.isPlaying { self.isPlaying = false }
                self.isLoading = false
                self.invalidateSeeks()
                self.invalidateStillFrames()
                self.renderedProject = nil
                self.errorMessage = message
            }
        }
    }

    /// A normal seek uses the same chasing pipeline as scrubbing, and restores
    /// the isolated paused frame only after its final native seek completes.
    func seek(_ position: Double) {
        guard !isClosed else { return }
        if MediaProcessing.isSuspended { time = bounded(position, to: sourceBounds); return }
        if isLoading {
            time = bounded(position, to: sourceBounds)
            return
        }
        guard renderedProject != nil else { return }
        scrubGestureActive = false
        requestSeek(position)
    }

    func beginScrubbing() {
        guard !isClosed, !isLoading, renderedProject != nil else { return }
        player.pause()
        if isPlaying { isPlaying = false }
        discardPreview(restoringFrame: false)
        scrubGestureActive = true
        if !isScrubbing { isScrubbing = true }
        clearPausedFrameForSeek()
    }

    func scrub(to position: Double) {
        guard !isClosed else { return }
        if MediaProcessing.isSuspended { time = bounded(position, to: bounds); return }
        let position = bounded(position, to: bounds)
        if isLoading { time = position; return }
        guard renderedProject != nil else { return }
        if !scrubGestureActive { beginScrubbing() }
        requestSeek(position)
    }

    func endScrubbing() {
        guard !isClosed, isScrubbing else { return }
        scrubGestureActive = false
        finishSeekIfSettled()
    }

    private func requestSeek(_ position: Double) {
        discardPreview(restoringFrame: false)
        clearPausedFrameForSeek()
        let requested = bounded(position, to: sourceBounds)
        if time != requested { time = requested }
        pendingSeek = Self.frameTime(at: requested, bounds: sourceBounds)
        chaseSeek()
    }

    private func clearPausedFrameForSeek() {
        nativeFrameTask?.cancel()
        nativeFrameTask = nil
        stillRequests.invalidate()
        liveSources = nil
        if stillFrame != nil { stillFrame = nil }
    }

    private func chaseSeek() {
        guard !seekInFlight, let target = pendingSeek, let item = player.currentItem else { return }
        pendingSeek = nil
        seekInFlight = true
        let request = seekGeneration
        renderedProject?.previewFrames.request(at: target)
        // Do not cancel an in-flight seek for each mouse event. Let its frame
        // reach AVPlayerLayer, then chase only the newest requested position.
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, request == self.seekGeneration,
                      self.player.currentItem === item else { return }
                self.seekInFlight = false
                if let next = self.pendingSeek, CMTimeCompare(next, target) == 0 { self.pendingSeek = nil }
                if self.pendingSeek != nil { self.chaseSeek() }
                else { self.finishSeekIfSettled() }
            }
        }
    }

    private func finishSeekIfSettled() {
        guard !seekInFlight, pendingSeek == nil, !scrubGestureActive else { return }
        guard !isPlaying else {
            if isScrubbing { isScrubbing = false }
            return
        }
        let target = Self.frameTime(at: time, bounds: sourceBounds)
        let sourceRequest = generation
        let seekRequest = seekGeneration
        nativeFrameTask?.cancel()
        nativeFrameTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.nativeSource(at: target, generation: sourceRequest, seekGeneration: seekRequest)
                guard !Task.isCancelled else { return }
                if self.isScrubbing { self.isScrubbing = false }
                if self.errorMessage == NativeFrameError.unavailable.localizedDescription { self.errorMessage = nil }
                if let draft = self.pendingDraftState {
                    self.pendingDraftState = nil
                    self.preview(draft)
                } else { self.updateStillFrame() }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, sourceRequest == self.generation, seekRequest == self.seekGeneration else { return }
                if self.isScrubbing { self.isScrubbing = false }
                self.pendingDraftState = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func nativeSource(at target: CMTime, generation request: Int,
                              seekGeneration seekRequest: UInt64) async throws -> LivePreviewSources {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !isClosed, request == generation, seekRequest == seekGeneration,
                  CMTimeCompare(Self.frameTime(at: time, bounds: sourceBounds), target) == 0,
                  let renderedProject else { throw CancellationError() }
            if let source = renderedProject.previewFrames.sources(at: target) { return source }
            // A layer may attach/preroll just after an otherwise zero-distance
            // seek completes. Wait for that native capture, never open a decoder.
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NativeFrameError.unavailable
    }

    /// Full unmodified camera pixels at the frozen playhead for the framing
    /// tool. Camera gaps return nil; lifecycle/source changes cancel the request.
    func cameraFrame(at position: Double) async throws -> CGImage? {
        guard !isClosed, !isLoading, let renderedProject else { throw CancellationError() }
        pause()
        let requested = position.isFinite ? bounded(position, to: sourceBounds) : time
        let target = Self.frameTime(at: requested, bounds: sourceBounds)
        let request = generation
        if renderedProject.previewFrames.sources(at: target) == nil { seek(requested) }
        let seekRequest = seekGeneration
        let source = try await nativeSource(at: target, generation: request, seekGeneration: seekRequest)
        let image = try await source.cameraImage()
        guard !isClosed, request == generation, seekRequest == seekGeneration else { throw CancellationError() }
        return image
    }

    private func invalidateSeeks() {
        nativeFrameTask?.cancel()
        nativeFrameTask = nil
        seekGeneration &+= 1
        pendingSeek = nil
        seekInFlight = false
        scrubGestureActive = false
        if isScrubbing { isScrubbing = false }
        // Cancellation is a lifecycle operation, never a mouse-drag operation.
        player.currentItem?.cancelPendingSeeks()
    }

    func togglePlayback() {
        guard !isClosed, !isLoading, renderedProject != nil else { return }
        if player.rate > 0 || isPlaying { pause() }
        else {
            let position = time < bounds.lowerBound || time >= bounds.upperBound - 0.03 ? bounds.lowerBound : time
            invalidateSeeks()
            discardPreview(restoringFrame: false)
            player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: bounds.upperBound, preferredTimescale: 600)
            requestSeek(position)
            stillRequests.invalidate()
            liveSources = nil
            stillFrame = nil
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        let wasPlaying = isPlaying
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = .invalid
        isPlaying = false
        guard wasPlaying, !seekInFlight, pendingSeek == nil, !isScrubbing,
              let renderedProject else { return }
        let current = player.currentTime().seconds
        let position = current.isFinite ? min(max(current, bounds.lowerBound), bounds.upperBound) : time
        let target = Self.frameTime(at: position, bounds: sourceBounds)
        if renderedProject.previewFrames.sources(at: target) != nil {
            if time != position { time = position }
            updateStillFrame()
        } else {
            // Freeze a native frame at the actual paused playhead, instead of
            // opening an independent image-generator decoder behind the player.
            requestSeek(position)
        }
    }

    /// Transient paused composition used while a gesture is in progress. The
    /// durable project, AVPlayerItem, playhead, and source geometry stay intact.
    func preview(_ state: EditState) {
        if MediaProcessing.isSuspended {
            guard !isClosed else { return }
            draftState = state
            screenSize = PresentationGeometry(sourceSize: sourceSize, presentation: state.presentation).outputSize
            return
        }
        guard !isClosed, !isLoading, !isScrubbing,
              let renderedProject, draftState != state else { return }
        if seekInFlight || pendingSeek != nil {
            pendingDraftState = state
            return
        }
        let position = Self.frameTime(at: time, bounds: sourceBounds)
        guard let source = sourceCache(for: renderedProject, at: position) else {
            // A gesture can begin in the same turn as Pause. Preserve its most
            // recent state while the native exact seek supplies the source pair.
            requestSeek(time)
            pendingDraftState = state
            return
        }
        pendingDraftState = nil
        if draftState == nil {
            player.pause()
            isPlaying = false
            stillRequests.invalidate()
            committedStillFrame = stillFrame
            committedStillTime = time
            draftGeneration &+= 1
        }
        draftState = state
        let request = draftGeneration
        stillRequests.request(
            generate: { try await source.image(applying: state) },
            cancel: {},
            receive: { [weak self] image in
                guard let self, self.draftGeneration == request, self.draftState != nil,
                      !self.isClosed, !self.isPlaying else { return }
                self.stillFrame = image
            },
            failure: { [weak self] in
                guard let self, self.draftGeneration == request else { return }
                self.stillFrame = nil
            },
            policy: .coalesced
        )
    }

    /// Restore the committed frame immediately when available, then refresh it
    /// through the same renderer. Any in-flight draft becomes ineligible.
    func cancelPreview() {
        if MediaProcessing.isSuspended {
            draftState = nil
            pendingDraftState = nil
            if let committedState {
                screenSize = PresentationGeometry(sourceSize: sourceSize, presentation: committedState.presentation).outputSize
            }
            return
        }
        guard !isClosed, isPreviewing else { return }
        discardPreview(restoringFrame: true)
        updateStillFrame()
    }

    private func discardPreview(restoringFrame: Bool) {
        guard isPreviewing else { return }
        draftState = nil
        pendingDraftState = nil
        draftGeneration &+= 1
        stillRequests.invalidate()
        if restoringFrame, committedStillTime == time { stillFrame = committedStillFrame }
        else { stillFrame = nil }
        committedStillFrame = nil
        committedStillTime = nil
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

    private func bounded(_ position: Double, to range: ClosedRange<Double>) -> Double {
        position.isFinite ? min(max(position, range.lowerBound), range.upperBound) : range.lowerBound
    }

    private func updateStillFrame() {
        guard !isClosed, !isPlaying, !isScrubbing, !seekInFlight, pendingSeek == nil,
              draftState == nil, let renderedProject, let committedState else { return }
        let position = Self.frameTime(at: time, bounds: sourceBounds)
        guard let source = sourceCache(for: renderedProject, at: position) else {
            if errorMessage == nil { errorMessage = "The paused recording frame could not be prepared." }
            return
        }
        stillRequests.request(
            generate: { try await source.image(applying: committedState) },
            cancel: {},
            receive: { [weak self] image in
                guard let self, !self.isClosed, !self.isPlaying, !self.isScrubbing,
                      !self.seekInFlight, self.pendingSeek == nil else { return }
                self.stillFrame = image
            },
            failure: { [weak self] in self?.stillFrame = nil }
        )
    }

    private func sourceCache(for rendered: RenderedProject, at position: CMTime) -> LiveStillFrameCache? {
        let source: LiveStillFrameCache
        if let liveSources, liveSources.rendered.asset === rendered.asset,
           CMTimeCompare(liveSources.position, position) == 0 {
            source = liveSources
        } else {
            guard let sources = rendered.previewFrames.sources(at: position) else { return nil }
            source = LiveStillFrameCache(rendered: rendered, position: position, sources: sources)
            liveSources = source
        }
        if errorMessage == NativeFrameError.unavailable.localizedDescription { errorMessage = nil }
        return source
    }

    private func invalidateStillFrames() {
        draftState = nil
        pendingDraftState = nil
        draftGeneration &+= 1
        committedStillFrame = nil
        committedStillTime = nil
        stillRequests.invalidate()
        liveSources = nil
        committedState = nil
        stillFrame = nil
    }

    func close() {
        generation += 1
        itemStatusObservation = nil
        invalidateSeeks()
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
    enum Policy {
        /// Scrubbing must show only the newest requested time.
        case latestOnly
        /// During a stationary-playhead gesture, show completed intermediate
        /// positions in order while replacing the next pending position.
        case coalesced
    }

    private struct Request {
        let generation: UInt64
        let epoch: UInt64
        let policy: Policy
        let generate: @MainActor () async throws -> Output
        let cancel: @MainActor () -> Void
        let receive: @MainActor (Output) -> Void
        let failure: @MainActor () -> Void
    }

    private var generation: UInt64 = 0
    private var epoch: UInt64 = 0
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var cancelActive: (@MainActor () -> Void)?

    func request(generate: @escaping @MainActor () async throws -> Output,
                 cancel: @escaping @MainActor () -> Void,
                 receive: @escaping @MainActor (Output) -> Void,
                 failure: @escaping @MainActor () -> Void = {},
                 policy: Policy = .latestOnly) {
        generation &+= 1
        if policy == .latestOnly { epoch &+= 1 }
        pending = Request(generation: generation, epoch: epoch, policy: policy,
                          generate: generate, cancel: cancel, receive: receive, failure: failure)
        if policy == .latestOnly { cancelCurrentOperation() }
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    func invalidate() {
        generation &+= 1
        epoch &+= 1
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
                if request.epoch == epoch,
                   request.policy == .coalesced || request.generation == generation {
                    request.receive(output)
                }
            } catch {
                cancelActive = nil
                // Remove an obsolete overlay if the current frame cannot be
                // decoded, leaving AVPlayer visible as the fallback.
                if request.epoch == epoch, request.generation == generation { request.failure() }
            }
        }
    }
}

/// The fixed playhead's source pair is decoded once. Both committed paused
/// frames and live gestures reuse it, with the same compositor graph as export.
/// The bounded worker serializes access; invalidation discards results without
/// reopening a decoder for each mouse event.
@MainActor
private final class LiveStillFrameCache {
    let rendered: RenderedProject
    let position: CMTime
    private let sources: LivePreviewSources

    init(rendered: RenderedProject, position: CMTime, sources: LivePreviewSources) {
        self.rendered = rendered
        self.position = position
        self.sources = sources
    }

    func image(applying state: EditState) async throws -> CGImage {
        try await ProjectRenderer.renderLivePreview(sources, applying: state)
    }
}

