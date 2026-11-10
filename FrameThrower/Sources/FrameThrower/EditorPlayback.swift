@preconcurrency import AVFoundation
import Combine
import SwiftUI

@MainActor
final class EditorFrameStore: ObservableObject {
    @Published var image: CGImage?
}

@MainActor
final class EditorPlayback: ObservableObject {
    static let supportedPlaybackRates = EditorSimulationClock.supportedRates
    private let monotonicTime: @MainActor () -> Double

    private var mediaPlayer: AVPlayer?
    var player: AVPlayer {
        if let mediaPlayer { return mediaPlayer }
        let player = AVPlayer()
        mediaPlayer = player
        return player
    }
    var canvasPlayer: AVPlayer? { MediaProcessing.isSuspended ? nil : player }
    var hasMediaPlayer: Bool { mediaPlayer != nil }
    var supportsSourceAudition: Bool { MediaProcessing.isSuspended || !mediaUsesOutputTime }
    var frameDuration: Double { editFrameDuration }
    @Published private(set) var time = 0.0
    @Published private(set) var outputTime = 0.0
    @Published private(set) var isInspectingSource = false
    private(set) var timingMap: RecordingTimeMap?
    var outputDuration: Double { timingMap?.outputDuration ?? max(0, bounds.upperBound - bounds.lowerBound) }
    var outputSamples: [RecordingTimeMap.Sample] {
        if isInspectingSource || (auditionRange != nil && !auditionUsesOutputTime) { return [] }
        return timingMap?.samples(at: outputTime) ?? []
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackRate = 1.0
    @Published private(set) var auditionRange: EditorPreviewRange?
    private var auditionUsesOutputTime = false
    @Published private(set) var isLoading = false
    @Published private(set) var screenSize = CGSize(width: 16, height: 9)
    @Published private(set) var sourceSize = CGSize(width: 16, height: 9)
    @Published private(set) var cameraAspect = 16.0 / 9.0
    private(set) var videoProject: RecordingProject?
    var videoState: EditState? { draftState ?? committedState }
    /// Authoring seconds are mapped into each occurrence's source clock only
    /// after selecting a Finished branch. Inspection can ask for either branch.
    func videoSamples(at projectTime: Double) -> [VideoLayerSample] {
        guard let videoProject else { return [] }
        return videoProject.videoSamples(at: projectTime, state: videoState)
    }
    @Published private(set) var errorMessage: String?
    let frameStore = EditorFrameStore()
    private(set) var stillFrame: CGImage? {
        get { frameStore.image }
        set { frameStore.image = newValue }
    }
    @Published private(set) var isScrubbing = false
    private var renderedProject: RenderedProject?
    private var mediaUsesOutputTime: Bool { renderedProject?.timingMap != nil }
    private var cachedCursorRecording: CursorRecording?
    private let stillRequests = LatestStillFrameQueue<CGImage>()
    private var committedState: EditState?
    private var liveSources: LiveStillFrameCache?
    private var isClosed = false
    private var observer: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObservation: (any NSObjectProtocol)?
    private var transportGeneration: UInt64 = 0
    private var generation = 0
    private var bounds = 0.0...1.0
    private var sourceDuration = 0.0
    private var sourceBounds: ClosedRange<Double> { 0...max(0, sourceDuration) }
    private var playbackBounds: ClosedRange<Double> {
        if let auditionRange, !auditionUsesOutputTime { return auditionRange.start...auditionRange.end }
        return bounds
    }
    private var outputPlaybackBounds: ClosedRange<Double> {
        if let auditionRange, auditionUsesOutputTime { return auditionRange.start...auditionRange.end }
        return 0...outputDuration
    }
    private var simulationUsesOutputTime: Bool {
        if auditionRange != nil { return auditionUsesOutputTime }
        return committedState.map { !$0.cuts.isEmpty || !$0.speedKeyframes.isEmpty } ?? false
    }
    private var simulationBounds: ClosedRange<Double> { simulationUsesOutputTime ? outputPlaybackBounds : playbackBounds }
    private var simulationPosition: Double { simulationUsesOutputTime ? outputTime : time }
    private var nativePlaybackBounds: ClosedRange<Double> {
        if mediaUsesOutputTime { return outputPlaybackBounds }
        if let auditionRange, auditionUsesOutputTime {
            return sourcePosition(at: auditionRange.start)...sourcePosition(at: auditionRange.end)
        }
        return playbackBounds
    }
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
    private var simulationClock: EditorSimulationClock?
    private var simulationTask: Task<Void, Never>?
    private var simulationGeneration: UInt64 = 0

    private enum NativeFrameError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The paused recording frame could not be prepared." }
    }

    var isPreviewing: Bool { draftState != nil || pendingDraftState != nil }
    var canPlay: Bool { !isClosed && !isLoading && (MediaProcessing.isSuspended ? simulationClock != nil : renderedProject != nil) }

    var cursorRecording: CursorRecording? { cachedCursorRecording }
    /// Framing/selection/playhead redraws reuse the already compiled clock.
    /// Only a cut/trim change needs another timing plan before the rebuild.
    func timingMap(for state: EditState, duration: Double) throws -> RecordingTimeMap {
        if duration == sourceDuration, let committedState, let timingMap,
           state.trimStart == committedState.trimStart, state.trimEnd == committedState.trimEnd,
           state.cuts == committedState.cuts, state.speedKeyframes == committedState.speedKeyframes { return timingMap }
        return try RecordingTimeMap(duration: duration, trimStart: state.trimStart, trimEnd: state.trimEnd, cuts: state.cuts, speedKeyframes: state.speedKeyframes)
    }
    var previewSourceBounds: ClosedRange<Double> { sourceBounds }
    var keptPreviewRange: EditorPreviewRange { .init(start: bounds.lowerBound, end: bounds.upperBound) }
    var previewSnapshot: EditorPreviewSnapshot {
        .init(time: time, frameTime: editingTime, isPlaying: isPlaying, rate: playbackRate,
              range: auditionRange, canPlay: canPlay, kind: MediaProcessing.isSuspended ? .testPattern : .footage,
              outputTime: outputTime, outputDuration: outputDuration,
              sourceSamples: outputSamples.map { .init(clipIndex: $0.clipIndex, sourceTime: $0.sourceTime, weight: $0.weight) },
              rangeTimeBase: auditionRange == nil ? nil : auditionUsesOutputTime ? "output" : "source",
              inspectionTimeBase: isInspectingSource ? "source" : "output")
    }

    /// The host finishes drafts at its normal navigation boundaries. This
    /// engine owns only transport state and never reaches into a ProjectEditor.
    func applyPreviewCommand(_ command: EditorPreviewCommand) async throws -> EditorPreviewSnapshot {
        try Task.checkCancellation()
        guard !isClosed else { throw EditorPreviewError.unavailable }
        switch command {
        case .play:
            guard canPlay else { throw EditorPreviewError.unavailable }
            play()
        case .pause:
            pause()
        case let .setRate(rate):
            guard setPlaybackRate(rate) else { throw EditorPreviewError.unsupportedRate }
        case let .seek(position):
            guard canPlay else { throw EditorPreviewError.unavailable }
            guard position.isFinite, sourceBounds.contains(position) else { throw EditorPreviewError.invalidTime }
            guard supportsSourceAudition else { throw EditorPreviewError.sourceAuditionUnavailable }
            seek(position)
        case let .seekOutput(position):
            guard canPlay else { throw EditorPreviewError.unavailable }
            guard position.isFinite, (0...outputDuration).contains(position) else { throw EditorPreviewError.invalidTime }
            seekOutput(position)
        case let .stepFrames(count):
            guard canPlay else { throw EditorPreviewError.unavailable }
            if count != 0 {
                pause()
                let frame = (editingTime / editFrameDuration).rounded()
                let lastFrame = max(0, ceil(sourceDuration / editFrameDuration) - 1)
                let target = min(lastFrame, max(0, frame + Double(count))) * editFrameDuration
                seek(target)
            }
        case let .stepOutputFrames(count):
            guard canPlay else { throw EditorPreviewError.unavailable }
            if count != 0 {
                pause()
                let frame = (outputTime / editFrameDuration).rounded()
                let target = min(outputDuration, max(0, frame + Double(count)) * editFrameDuration)
                seekOutput(target)
            }
        case let .playRange(start, end):
            guard canPlay else { throw EditorPreviewError.unavailable }
            guard start.isFinite, end.isFinite, sourceBounds.contains(start), sourceBounds.contains(end), start < end else {
                throw EditorPreviewError.invalidRange
            }
            guard supportsSourceAudition else { throw EditorPreviewError.sourceAuditionUnavailable }
            pause()
            auditionRange = .init(start: start, end: end)
            auditionUsesOutputTime = false
            time = start; outputTime = outputPosition(for: start)
            play()
        case let .playOutputRange(start, end):
            guard canPlay else { throw EditorPreviewError.unavailable }
            guard start.isFinite, end.isFinite, start >= 0, end <= outputDuration, start < end else { throw EditorPreviewError.invalidRange }
            pause()
            auditionRange = .init(start: start, end: end)
            auditionUsesOutputTime = true
            updateSimulationPosition(start)
            play()
        }
        return previewSnapshot
    }


    var editingTime: Double {
        // A mathematically exact frame multiple can divide to N−1ulp. A
        // sub-picosecond tolerance prevents repeated single-frame steps from
        // sticking there, without crossing a nanosecond source timestamp.
        RecordingProject.editingTime(at: time + min(1e-12, editFrameDuration * 1e-10),
            duration: sourceDuration, frameDuration: editFrameDuration)
    }

    init(monotonicTime: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.monotonicTime = monotonicTime
        guard !MediaProcessing.isSuspended else { return }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600),
                                                   queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed, self.draftState == nil,
                      self.isPlaying, !self.isLoading,
                      !self.isScrubbing, !self.seekInFlight, self.pendingSeek == nil else { return }
                let end = self.nativePlaybackBounds.upperBound
                let position = time.seconds.isFinite ? min(time.seconds, end) : 0
                self.updateMediaPosition(position)
                if position >= end {
                    self.finishPlaybackAtBoundary()
                }
            }
        }
    }

    func rebuild(editor: ProjectEditor) async {
        guard !isClosed else { return }
        generation += 1
        clearEndObservation()
        auditionRange = nil
        itemStatusObservation = nil
        invalidateSeeks()
        let request = generation
        let snapshot = editor.project
        // Cursor recordings are validated JSON metadata, independent of all
        // movie/decoder objects. Read once per rebuild, including suspended
        // previews; missing or corrupt metadata simply produces no click ticks.
        cachedCursorRecording = nil
        if let filename = snapshot.cursorFilename, !filename.isEmpty, filename != ".", filename != "..",
           !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") {
            cachedCursorRecording = try? CursorRecording.load(from: editor.mediaURL(for: filename))
        }
        stopSimulation()
        sourceDuration = snapshot.duration
        bounds = snapshot.state.trimStart...snapshot.state.trimEnd
        do {
            timingMap = try RecordingTimeMap(duration: snapshot.duration, trimStart: snapshot.state.trimStart,
                trimEnd: snapshot.state.trimEnd, cuts: snapshot.state.cuts, speedKeyframes: snapshot.state.speedKeyframes)
        } catch {
            stopSimulation(); isPlaying = false; isLoading = false
            errorMessage = error.localizedDescription
            return
        }
        time = bounded(time, to: sourceBounds)
        outputTime = outputPosition(for: time)
        if !isInspectingSource { time = sourcePosition(at: outputTime) }
        mediaPlayer?.pause()
        isPlaying = false
        // A successful gesture commits this exact draft next. Keep its last
        // displayed pixels across the rebuild so release never flashes back to
        // the old player's camera position; pending draft work is invalidated.
        let retainedDraftFrame = isPreviewing ? stillFrame : nil
        invalidateStillFrames()
        videoProject = snapshot
        stillFrame = retainedDraftFrame
        renderedProject = nil
        isLoading = true
        errorMessage = nil
        if MediaProcessing.isSuspended {
            // Keep source-time editing and geometry usable without opening a
            // movie, constructing a composition, or attaching a decoder.
            mediaPlayer?.replaceCurrentItem(with: nil)
            sourceSize = CGSize(width: 1920, height: 1080)
            screenSize = PresentationGeometry(sourceSize: sourceSize, presentation: snapshot.state.presentation).outputSize
            editFrameDuration = snapshot.captureFrameDuration ?? 1.0 / 30
            committedState = snapshot.state
            simulationClock = EditorSimulationClock(bounds: simulationBounds, time: simulationPosition)
            simulationClock?.setRate(playbackRate, at: monotonicTime())
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
            if rendered.supportsDirectSourcePreview {
                rendered.previewFrames.request(at: Self.frameTime(at: position, bounds: sourceBounds))
            }
            player.replaceCurrentItem(with: item)
            screenSize = rendered.screenSize
            sourceSize = rendered.sourceSize
            cameraAspect = rendered.cameraAspect
            bounds = snapshot.state.trimStart...snapshot.state.trimEnd
            renderedProject = rendered
            editFrameDuration = rendered.videoComposition.frameDuration.seconds
            committedState = snapshot.state
            isLoading = false
            if isInspectingSource { seek(position) }
            else { seekOutput(outputPosition(for: position)) }
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

    private func observePlaybackEnd(of item: AVPlayerItem) {
        clearEndObservation()
        let request = generation, transport = transportGeneration
        endObservation = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isClosed, request == self.generation,
                          transport == self.transportGeneration,
                          self.mediaPlayer?.currentItem === item, self.isPlaying else { return }
                    self.finishPlaybackAtBoundary()
                }
            }
    }

    /// A normal seek uses the same chasing pipeline as scrubbing, and restores
    /// the isolated paused frame only after its final native seek completes.
    func seek(_ position: Double) {
        guard !isClosed else { return }
        guard supportsSourceAudition else { errorMessage = EditorPreviewError.sourceAuditionUnavailable.localizedDescription; return }
        pause()
        clearAudition()
        isInspectingSource = true
        scrubGestureActive = false
        if MediaProcessing.isSuspended { isScrubbing = false }
        seekSource(position)
    }

    /// Output inspection can contain two source moments. Preserve its exact
    /// position instead of round-tripping through the currently dominant one.
    func seekOutput(_ position: Double) {
        guard !isClosed, position.isFinite else { return }
        pause(); clearAudition(); scrubGestureActive = false
        isInspectingSource = false
        let requested = bounded(position, to: 0...outputDuration)
        if MediaProcessing.isSuspended {
            isScrubbing = false
            seekOutputSimulation(requested)
        } else {
            guard renderedProject != nil else { return }
            if mediaUsesOutputTime { requestCompositionSeek(requested) }
            else { seekSource(sourcePosition(at: requested)) }
        }
    }

    func scrubOutput(to position: Double) {
        guard !isClosed, position.isFinite else { return }
        isInspectingSource = false
        if MediaProcessing.isSuspended { seekOutputSimulation(bounded(position, to: 0...outputDuration)) }
        else if mediaUsesOutputTime {
            if !scrubGestureActive { beginScrubbing() }
            requestCompositionSeek(bounded(position, to: 0...outputDuration))
        } else { scrub(to: sourcePosition(at: bounded(position, to: 0...outputDuration))) }
    }

    private func seekSource(_ position: Double) {
        if MediaProcessing.isSuspended { seekSimulation(position, within: sourceBounds); return }
        if isLoading {
            time = bounded(position, to: sourceBounds)
            return
        }
        guard renderedProject != nil else { return }
        scrubGestureActive = false
        requestSeek(position)
    }

    func beginScrubbing() {
        clearAudition()
        if MediaProcessing.isSuspended {
            guard canPlay else { return }
            pause()
            scrubGestureActive = true
            isScrubbing = true
            return
        }
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
        clearAudition()
        isInspectingSource = true
        if MediaProcessing.isSuspended { seekSimulation(position, within: bounds); return }
        let position = bounded(position, to: bounds)
        if isLoading { time = position; return }
        guard renderedProject != nil else { return }
        if !scrubGestureActive { beginScrubbing() }
        requestSeek(position)
    }

    func scrubSource(to position: Double) {
        guard !isClosed else { return }
        clearAudition()
        isInspectingSource = true
        if MediaProcessing.isSuspended { seekSimulation(position, within: sourceBounds) }
        else if !mediaUsesOutputTime { requestSeek(bounded(position, to: sourceBounds)) }
    }

    func endScrubbing() {
        guard !isClosed, isScrubbing else { return }
        scrubGestureActive = false
        if MediaProcessing.isSuspended { isScrubbing = false; return }
        finishSeekIfSettled()
    }

    private func requestSeek(_ position: Double) {
        discardPreview(restoringFrame: false)
        let requested = bounded(position, to: sourceBounds)
        if mediaUsesOutputTime {
            requestCompositionSeek(outputPosition(for: requested))
            return
        }
        clearPausedFrameForSeek()
        time = requested; outputTime = outputPosition(for: requested)
        pendingSeek = Self.frameTime(at: requested, bounds: sourceBounds)
        chaseSeek()
    }

    private func requestCompositionSeek(_ position: Double) {
        clearPausedFrameForSeek()
        updateSimulationPosition(bounded(position, to: 0...outputDuration))
        pendingSeek = Self.frameTime(at: outputTime, bounds: 0...outputDuration)
        chaseSeek()
    }

    private func updateMediaPosition(_ position: Double) {
        if mediaUsesOutputTime { updateSimulationPosition(position) }
        else { time = position; outputTime = outputPosition(for: position) }
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
        if renderedProject?.supportsDirectSourcePreview == false {
            // AVPlayerLayer already holds the completed mixed frame. A cut
            // composition has two source pairs, so the single-pair still
            // cache must never decode or pretend one branch is the result.
            isScrubbing = false
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
        guard renderedProject.supportsDirectSourcePreview else { throw NativeFrameError.unavailable }
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
        mediaPlayer?.currentItem?.cancelPendingSeeks()
    }

    func togglePlayback() {
        if isPlaying { pause() }
        else { play() }
    }

    /// Idempotent transport action, unlike a UI toggle.
    func play() {
        guard canPlay, !isPlaying else { return }
        isInspectingSource = auditionRange != nil && !auditionUsesOutputTime
        if MediaProcessing.isSuspended {
            var clock = EditorSimulationClock(bounds: simulationBounds, time: simulationPosition)
            clock.play(at: monotonicTime(), rate: playbackRate)
            simulationClock = clock
            updateClockPosition(clock.time)
            isPlaying = clock.isPlaying
            isScrubbing = false
            scrubGestureActive = false
            startSimulation()
            return
        }
        guard renderedProject != nil else { return }
        let activeMediaBounds = nativePlaybackBounds
        let currentPosition = mediaUsesOutputTime ? outputTime : time
        let position = currentPosition < activeMediaBounds.lowerBound || currentPosition >= activeMediaBounds.upperBound
            ? activeMediaBounds.lowerBound : currentPosition
        invalidateSeeks()
        discardPreview(restoringFrame: false)
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: activeMediaBounds.upperBound, preferredTimescale: 600)
        if mediaUsesOutputTime { requestCompositionSeek(position) }
        else { requestSeek(position) }
        transportGeneration &+= 1
        if let item = mediaPlayer?.currentItem { observePlaybackEnd(of: item) }
        stillRequests.invalidate()
        liveSources = nil
        stillFrame = nil
        player.playImmediately(atRate: Float(playbackRate))
        isPlaying = true
    }

    func pause() {
        transportGeneration &+= 1
        clearEndObservation()
        if MediaProcessing.isSuspended {
            if var clock = simulationClock {
                let wasPlaying = clock.isPlaying
                clock.pause(at: monotonicTime())
                simulationClock = clock
                if wasPlaying { updateClockPosition(clock.time) }
            }
            stopSimulation()
            isPlaying = false
            finishAuditionIfNeeded()
            return
        }
        let wasPlaying = isPlaying
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = .invalid
        isPlaying = false
        if wasPlaying, mediaUsesOutputTime {
            let current = player.currentTime().seconds
            updateMediaPosition(bounded(current, to: outputPlaybackBounds))
            finishAuditionIfNeeded()
            return
        }
        guard wasPlaying, !seekInFlight, pendingSeek == nil, !isScrubbing,
              let renderedProject else { return }
        let current = player.currentTime().seconds
        let activeBounds = nativePlaybackBounds
        let position = current.isFinite ? min(max(current, activeBounds.lowerBound), activeBounds.upperBound) : time
        let target = Self.frameTime(at: position, bounds: sourceBounds)
        if renderedProject.previewFrames.sources(at: target) != nil {
            if time != position { time = position }
            updateStillFrame()
        } else {
            // Freeze a native frame at the actual paused playhead, instead of
            // opening an independent image-generator decoder behind the player.
            requestSeek(position)
        }
        finishAuditionIfNeeded()
    }

    /// Preview transport preference only; never persisted in project/history
    /// or applied to exported media. A paused player stays paused.
    @discardableResult
    func setPlaybackRate(_ rate: Double) -> Bool {
        guard !isClosed, Self.supportedPlaybackRates.contains(rate) else { return false }
        if MediaProcessing.isSuspended {
            if var clock = simulationClock {
                let wasPlaying = clock.isPlaying
                clock.setRate(rate, at: monotonicTime())
                simulationClock = clock
                if wasPlaying { updateClockPosition(clock.time) }
                isPlaying = clock.isPlaying
                if !isPlaying { stopSimulation(); finishAuditionIfNeeded() }
            }
        } else if isPlaying {
            player.playImmediately(atRate: Float(rate))
        }
        playbackRate = rate
        return true
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
        if let renderedProject, !renderedProject.supportsDirectSourcePreview {
            guard !isClosed, !isLoading else { return }
            pause()
            draftState = state
            let draft = ProjectRenderer.preview(renderedProject, applying: state)
            screenSize = draft.screenSize
            mediaPlayer?.currentItem?.videoComposition = draft.videoComposition
            mediaPlayer?.currentItem?.audioMix = draft.audioMix
            requestCompositionSeek(outputTime)
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
        if let renderedProject, !renderedProject.supportsDirectSourcePreview {
            draftState = nil; pendingDraftState = nil
            screenSize = renderedProject.screenSize
            mediaPlayer?.currentItem?.videoComposition = renderedProject.videoComposition
            mediaPlayer?.currentItem?.audioMix = renderedProject.audioMix
            requestCompositionSeek(outputTime)
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

    private func seekSimulation(_ position: Double, within range: ClosedRange<Double>) {
        stopSimulation()
        isPlaying = false
        time = bounded(position, to: range)
        outputTime = outputPosition(for: time)
        var clock = EditorSimulationClock(bounds: simulationBounds, time: simulationPosition)
        _ = clock.setRate(playbackRate, at: monotonicTime())
        simulationClock = clock
    }

    private func seekOutputSimulation(_ position: Double) {
        stopSimulation(); isPlaying = false
        updateSimulationPosition(position)
        var clock = EditorSimulationClock(bounds: simulationBounds, time: simulationPosition)
        _ = clock.setRate(playbackRate, at: monotonicTime())
        simulationClock = clock
    }

    private func outputPosition(for sourceTime: Double) -> Double {
        guard let timingMap else { return min(outputDuration, max(0, sourceTime - bounds.lowerBound)) }
        if let exact = timingMap.outputTime(for: sourceTime) { return exact }
        // Source inspection inside removed/trimmed footage is still allowed.
        // Its output cursor sits at the next retained section's join.
        return timingMap.clips.first(where: { $0.sourceStart > sourceTime })?.outputStart ?? timingMap.outputDuration
    }

    private func sourcePosition(at outputTime: Double) -> Double {
        timingMap?.samples(at: outputTime).max(by: { $0.weight < $1.weight })?.sourceTime ?? bounds.lowerBound
    }

    private func updateSimulationPosition(_ position: Double) {
        outputTime = position
        time = sourcePosition(at: position)
    }

    private func updateClockPosition(_ position: Double) {
        if simulationUsesOutputTime { updateSimulationPosition(position) }
        else { time = position; outputTime = outputPosition(for: position) }
    }

    private func startSimulation() {
        stopSimulation()
        guard isPlaying else { return }
        let request = simulationGeneration
        simulationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard let self, !self.isClosed, self.simulationGeneration == request,
                      var clock = self.simulationClock, self.isPlaying else { return }
                clock.advance(to: self.monotonicTime())
                self.simulationClock = clock
                self.updateClockPosition(clock.time)
                self.isPlaying = clock.isPlaying
                if !clock.isPlaying { self.stopSimulation(); self.finishAuditionIfNeeded(); return }
            }
        }
    }

    private func stopSimulation() {
        simulationGeneration &+= 1
        simulationTask?.cancel()
        simulationTask = nil
    }

    private func finishAuditionIfNeeded() {
        if let auditionRange, (auditionUsesOutputTime ? outputTime : time) >= auditionRange.end { clearAudition() }
    }

    private func finishPlaybackAtBoundary() {
        let end = nativePlaybackBounds.upperBound
        let outputEnd = outputPlaybackBounds.upperBound
        pause()
        if mediaUsesOutputTime { updateSimulationPosition(outputEnd) }
        else { time = end; outputTime = outputPosition(for: end) }
        finishAuditionIfNeeded()
    }

    private func clearAudition() {
        guard auditionRange != nil else { return }
        auditionRange = nil
        auditionUsesOutputTime = false
        mediaPlayer?.currentItem?.forwardPlaybackEndTime = .invalid
        if MediaProcessing.isSuspended, simulationClock != nil {
            var clock = EditorSimulationClock(bounds: simulationBounds, time: simulationPosition)
            _ = clock.setRate(playbackRate, at: monotonicTime())
            simulationClock = clock
        }
    }

    private func clearEndObservation() {
        if let endObservation { NotificationCenter.default.removeObserver(endObservation) }
        endObservation = nil
    }

    private func updateStillFrame() {
        guard !isClosed, !isPlaying, !isScrubbing, !seekInFlight, pendingSeek == nil,
              draftState == nil, let renderedProject, renderedProject.supportsDirectSourcePreview, let committedState else { return }
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
        videoProject = nil
        cachedCursorRecording = nil
        stopSimulation()
        simulationClock = nil
        auditionRange = nil
        clearEndObservation()
        generation += 1
        itemStatusObservation = nil
        invalidateSeeks()
        isClosed = true
        mediaPlayer?.pause()
        isPlaying = false
        isLoading = false
        invalidateStillFrames()
        renderedProject = nil
        if let observer { mediaPlayer?.removeTimeObserver(observer); self.observer = nil }
        mediaPlayer?.replaceCurrentItem(with: nil)
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

