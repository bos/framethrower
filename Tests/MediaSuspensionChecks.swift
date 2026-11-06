import AVFoundation
import Foundation

private enum SuspensionCheckError: Error { case failed(String) }

/// No movie fixtures, pixel buffers, decoders, capture devices, or renderers
/// run here. Nonexistent media paths verify rejection before asset access.
@main
@MainActor
struct MediaSuspensionChecks {
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "media interlock must stay enabled")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov", duration: 10)
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("test.framethrower"))
        try require(editor.save(), "project saves without opening its media")
        let playback = EditorPlayback()
        await playback.rebuild(editor: editor)
        try require(!playback.isLoading && !playback.canPlay && playback.player.currentItem == nil && playback.errorMessage == nil,
                    "stub editor cannot attach a video source or report a missing-video decoder error")
        playback.seek(3)
        try require(playback.time == 3, "source-time selection still works")
        playback.scrub(to: 4)
        try require(playback.time == 4 && playback.stillFrame == nil, "scrubbing changes time without decoding a frame")
        var next = project.state
        next.presentation.aspect = .portrait
        next.zoomKeyframes = [ZoomKeyframe(time: 4, scale: 2, x: 0.3, y: 0.4)]
        next.audio = RecordingAudio(isMuted: true, volume: 0.6, fadeIn: 1, fadeOut: 2)
        try require(editor.updateDraft(next, at: 4), "framing remains editable")
        playback.preview(next)
        try require(playback.screenSize.height > playback.screenSize.width && playback.player.currentItem == nil,
                    "draft canvas geometry updates without media")
        try require(editor.finishDraft() && editor.undo() && editor.project.state == project.state,
                    "stub framing edits retain normal persistence and Undo")
        try require(editor.redo() && editor.project.state == next, "stub edit Redo restores the change")
        playback.cancelPreview()
        playback.togglePlayback()
        try require(!playback.isPlaying && playback.player.currentItem == nil, "Play cannot start a decoder")
        playback.close()

        await expectSuspended {
            _ = try await ProjectRenderer.makePreview(project: project, directory: directory)
        }
        let output = directory.appendingPathComponent("existing.mp4")
        let sentinel = Data("existing output".utf8)
        try sentinel.write(to: output)
        await expectSuspended {
            try await ProjectRenderer.export(project: project, directory: directory, to: output, replaceExisting: true)
        }
        await expectSuspended {
            _ = try await ProjectRenderer.cameraFrame(project: project, directory: directory, at: 1)
        }
        try require(try Data(contentsOf: output) == sentinel, "suspended export leaves existing destinations untouched")
        do {
            _ = try ScreenMasterWriter(url: directory.appendingPathComponent("master.mov"), width: 16, height: 16,
                audioTracks: [], onFirstVideo: { _ in }, onFailure: { _ in })
            throw SuspensionCheckError.failed("master writer opened while suspended")
        } catch is MediaProcessing.Suspended { }

        var decodedThumbnail = false
        let cache = RecordingThumbnailCache(loader: { _ in decodedThumbnail = true; return nil })
        let thumbnail = await cache.thumbnail(for: directory.appendingPathComponent("missing-screen.mov"))
        try require(thumbnail == nil && !decodedThumbnail, "thumbnail loader is never invoked")
        var openedChooser = false
        var rendered = false
        let session = VideoExportSession(requiresProgressPresentation: false,
            chooser: { _, _, _ in openedChooser = true; return nil },
            renderer: { _, _, _, _, _, _ in rendered = true })
        let before = editor.project
        let diskBeforeExport = try Data(contentsOf: editor.url)
        session.begin(editor: editor, sharing: false)
        try require(!session.isBusy && session.errorMessage == MediaProcessing.statusMessage && !openedChooser && !rendered,
                    "export controller rejects before choosing or rendering a video")
        let diskAfterExport = try Data(contentsOf: editor.url)
        try require(editor.project == before && diskAfterExport == diskBeforeExport,
                    "suspended export does not mutate the edited project")
        try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("master.mov").path),
                    "suspended capture cannot create an output")
        print("Media suspension checks passed (no media access; editable timeline/canvas/audio; persistence and Undo/Redo; blocked capture, previews, thumbnails and export).")
    }

    private static func expectSuspended(_ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Media operation ran while suspended") }
        catch is MediaProcessing.Suspended { }
        catch { fatalError("Media was accessed before the interlock: \(error)") }
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw SuspensionCheckError.failed(message) }
    }
}
