import AVFoundation
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
    private var stillGeneration = 0
    private var observer: Any?
    private var generation = 0
    private var bounds = 0.0...1.0

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600),
                                                   queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.time = time.seconds.isFinite ? time.seconds : 0
                self.isPlaying = self.player.rate > 0
                if self.time >= self.bounds.upperBound {
                    self.pause()
                }
            }
        }
    }

    func rebuild(editor: ProjectEditor) async {
        generation += 1
        let request = generation
        let snapshot = editor.project
        let position = min(max(time, snapshot.state.trimStart), snapshot.state.trimEnd)
        pause()
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
            stillFrame = nil
            seek(position)
            isLoading = false
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            player.replaceCurrentItem(with: nil)
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func seek(_ position: Double) {
        time = min(max(position, bounds.lowerBound), bounds.upperBound)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateStillFrame()
    }

    func togglePlayback() {
        if player.rate > 0 { pause() }
        else {
            if time >= bounds.upperBound - 0.03 { seek(bounds.lowerBound) }
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

    private func updateStillFrame() {
        stillGeneration += 1
        let request = stillGeneration
        guard let renderedProject else { return }
        // The end boundary is exclusive; show the final retained frame there.
        let position = max(bounds.lowerBound, min(time, bounds.upperBound - 1.0 / 30))
        Task { [weak self] in
            guard let self else { return }
            do {
                let imageGenerator = AVAssetImageGenerator(asset: renderedProject.asset)
                imageGenerator.videoComposition = renderedProject.videoComposition
                imageGenerator.requestedTimeToleranceBefore = .zero
                imageGenerator.requestedTimeToleranceAfter = .zero
                imageGenerator.maximumSize = CGSize(width: 1920, height: 1080)
                let frame = try await imageGenerator.image(at: CMTime(seconds: position, preferredTimescale: 600)).image
                guard request == self.stillGeneration, !self.isPlaying else { return }
                self.stillFrame = frame
            } catch { /* AVPlayer remains available if a still cannot be decoded. */ }
        }
    }

    func close() {
        generation += 1
        pause()
        stillGeneration += 1
        renderedProject = nil
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
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
