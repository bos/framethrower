import AppKit
import Foundation

private enum WindowCheckError: Error { case failed(String) }

/// Exercises the actual window-session registry without activating capture or
/// requiring a camera, screen permission, account, or SwiftUI app lifecycle.
@main
@MainActor
struct EditorWindowChecks {
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "framethrower-window-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstURL = try fixture(in: directory.appendingPathComponent("one"), duration: 10)
        let secondURL = try fixture(in: directory.appendingPathComponent("two"), duration: 20)
        let model = CaptureViewModel(userDefaults: defaults)
        model.requestProjectEditor()
        try require(model.editorOpenRequest == nil, "no project must mean no editor window request")

        let first = try model.editor(for: firstURL)
        let firstAgain = try model.editor(for: firstURL)
        try require(first === firstAgain, "reopening one project must reuse its existing editor session")
        let equivalentPath = firstURL.deletingLastPathComponent().appendingPathComponent("../one/recording.framethrower")
        try require(try model.editor(for: equivalentPath) === first,
                    "equivalent paths must not create conflicting editors for one project")
        let alias = directory.appendingPathComponent("alias.framethrower")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstURL)
        try require(try model.editor(for: alias) === first,
                    "a project symlink must reuse the canonical editor and original media directory")
        let second = try model.editor(for: secondURL)
        try require(first !== second, "different project paths need independent editor sessions")
        try require(first.project.duration == 10 && second.project.duration == 20,
                    "same-named project files in different folders must not collide")

        model.projectEditor = first
        model.requestProjectEditor()
        guard let firstRequest = model.editorOpenRequest else {
            throw WindowCheckError.failed("requesting the current project must publish a window request")
        }
        model.requestProjectEditor()
        guard let repeatedRequest = model.editorOpenRequest else {
            throw WindowCheckError.failed("reopening the current editor must publish another request")
        }
        try require(firstRequest.id != repeatedRequest.id && firstRequest.url == repeatedRequest.url,
                    "repeated opens must have fresh request identities while targeting the same window")
        try require(repeatedRequest.url == firstURL.standardizedFileURL.resolvingSymlinksInPath(),
                    "window identity must use the canonical project URL")
        let firstWindowSession = first
        model.projectEditor = second
        try require(firstWindowSession === first && firstWindowSession.project.duration == 10,
                    "changing the recorder's current project must not retarget an existing editor window")
        var trimmed = first.project.state
        trimmed.trimStart = 1
        trimmed.trimEnd = 9
        try require(first.commit(trimmed, name: "Trim first recording"), "edit first window")
        try require(second.project.state.trimStart == 0 && !second.canUndo,
                    "editing one window must not affect another window's state or undo stack")
        var camera = second.project.state
        camera.pipKeyframes[0].placement = PIPPlacement(x: 0.1, y: 0.2, shape: .circle,
                                                        crop: PIPCrop(x: 0.8, y: 0.5))
        try require(second.commit(camera, name: "Frame second camera"), "edit second window")
        try require(first.project.state == trimmed && first.undoName == "Trim first recording",
                    "second-window geometry must not replace the first window's history")
        try require(first.undo(), "undo in first window")
        try require(second.project.state == camera && second.undoName == "Frame second camera",
                    "undo must remain local to its project session")
        let returnedFirst = try model.editor(for: firstURL)
        try require(returnedFirst === first && returnedFirst.canRedo,
                    "reopening an active editor preserves its current redo branch")
        try require(returnedFirst.redo() && first.project.state == trimmed,
                    "redo after reopening a window restores that project's edit")
        try require(model.projectEditor === second,
                    "resolving an old editor window must not switch the recorder's sharing project")

        // A fresh app model must reconstruct durable history from disk rather
        // than inheriting another session's object references.
        let relaunched = CaptureViewModel(userDefaults: defaults)
        let restoredFirst = try relaunched.editor(for: firstURL)
        let restoredSecond = try relaunched.editor(for: secondURL)
        try require(restoredFirst !== first && restoredSecond !== second,
                    "a fresh app session creates fresh in-memory editors")
        try require(restoredFirst.project == first.project && restoredSecond.project == second.project,
                    "both windows' independent histories survive app restart")
        try require(restoredSecond.undo(), "undo second window after restart")
        try require(restoredFirst.project.state == trimmed,
                    "restored second-window undo must not alter the restored first window")

        try require(model.recordingLibrary.entries.count == 2,
                    "resolving multiple saved recordings must retain every library row")
        let movedCamera = directory.appendingPathComponent("temporarily-moved-camera.mov")
        let cameraURL = first.mediaURL(for: first.project.cameraFilename!)
        try FileManager.default.moveItem(at: cameraURL, to: movedCamera)
        first.mediaRestored()
        try require(model.recordingLibrary.entries.first(where: { $0.projectURL == firstURL })?.mediaUnavailable == true,
                    "an unavailable original remains visible in the recording library")
        model.openRecording(at: firstURL)
        try require(model.projectEditor === first, "a missing-media project still opens for repair")
        try FileManager.default.moveItem(at: movedCamera, to: cameraURL)
        let historyBeforeRepair = first.project
        first.mediaRestored()
        try require(model.recordingLibrary.entries.first(where: { $0.projectURL == firstURL })?.mediaUnavailable == false,
                    "restoring media immediately refreshes the library without reopening or changing edits")
        try require(first.project == historyBeforeRepair, "media restoration does not create an edit or rewrite history")
        try require(first.rename(to: "First demonstration"), "rename through shared editor")
        try require(model.recordingLibrary.entries.first(where: { $0.projectURL == firstURL })?.displayName == first.displayName,
                    "renaming an open editor must immediately update its library row")
        try require(first.undo(), "undo shared recording name")
        try require(model.recordingLibrary.entries.first(where: { $0.projectURL == firstURL })?.displayName == first.displayName,
                    "undoing rename must update the library without reopening it")
        let requestBeforeShare = model.editorOpenRequest
        try require(model.selectRecordingForSharing(at: firstURL) && model.projectEditor === first
                    && model.lastRecordingURL == first.mediaURL(for: first.project.screenFilename),
                    "sharing a library row must select that recording rather than the latest clip")
        try require(model.editorOpenRequest == requestBeforeShare, "sharing must not open an editor window")
        model.openRecording(at: secondURL)
        try require(model.projectEditor === second && model.editorOpenRequest?.url == secondURL,
                    "opening a library row must target its independent editor")
        try require(!model.selectRecordingForSharing(at: directory.appendingPathComponent("absent.framethrower"))
                    && model.projectEditor === second,
                    "a failed row selection must not replace the current sharing target")
        let restartedLibrary = RecordingLibrary(defaults: defaults, directories: [])
        await restartedLibrary.refresh()
        try require(Set(restartedLibrary.entries.map(\.projectURL)) == Set([firstURL, secondURL]),
                    "the recorder's imported library must survive restart independently of Movies discovery")
        model.recordingLibrary.remove(at: secondURL)
        try require(second.rename(to: "Second while hidden"), "edit name in an already-open removed recording")
        try require(!model.recordingLibrary.entries.contains(where: { $0.projectURL == secondURL }),
                    "an open editor must not silently restore a removed library row")
        let afterRemoval = CaptureViewModel(userDefaults: defaults, recordingDirectories: [])
        afterRemoval.restoreLastProject()
        await afterRemoval.recordingLibrary.refresh()
        try require(!afterRemoval.recordingLibrary.entries.contains(where: { $0.projectURL == secondURL }),
                    "restoring the last editor on launch must respect list removal")
        try require(afterRemoval.recordingLibrary.restoreLastRemoved()
                    && afterRemoval.recordingLibrary.entries.contains(where: { $0.projectURL == secondURL && $0.displayName == "Second while hidden" }),
                    "undo removal after restart must restore the latest saved name")
        model.openRecording(at: secondURL)
        try require(model.recordingLibrary.entries.contains(where: { $0.projectURL == secondURL }),
                    "explicitly reopening a removed project must return it to the list")

        let brokenURL = directory.appendingPathComponent("broken.framethrower")
        try Data("broken project".utf8).write(to: brokenURL)
        try expectFailure("broken project must not enter the session registry") {
            _ = try model.editor(for: brokenURL)
        }
        let repaired = RecordingProject(screenFilename: "screen.mp4", duration: 5)
        try Data("original repaired source".utf8).write(to: directory.appendingPathComponent("screen.mp4"))
        try JSONEncoder().encode(repaired).write(to: brokenURL)
        let repairedEditor = try model.editor(for: brokenURL)
        try require(repairedEditor.project == repaired,
                    "a failed open must not poison future opens after the project is repaired")
        try expectFailure("missing project must fail cleanly") {
            _ = try model.editor(for: directory.appendingPathComponent("missing.framethrower"))
        }
        try require(!model.isRecording && !model.camera.isPreparing,
                    "opening editor sessions must not activate screen or camera capture")
        print("Editor window checks passed (canonical session identity, independent windows and undo histories, restart recovery, and failed-open recovery).")
    }

    private static func fixture(in directory: URL, duration: Double) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("immutable original screen \(duration)".utf8).write(to: directory.appendingPathComponent("screen.mp4"))
        try Data("immutable original camera \(duration)".utf8).write(to: directory.appendingPathComponent("camera.mov"))
        let url = directory.appendingPathComponent("recording.framethrower")
        let project = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mov", duration: duration)
        try JSONEncoder().encode(project).write(to: url)
        return url
    }

    private static func expectFailure(_ message: String, operation: () throws -> Void) throws {
        do { try operation() }
        catch { return }
        throw WindowCheckError.failed(message)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw WindowCheckError.failed(message) }
    }
}
