import Foundation

private enum OpenRoutingFailure: Error { case failed(String) }

/// Actual model request routing with project JSON only. No NSApplication,
/// windows, open panels, source media, capture, playback, or rendering.
@main @MainActor
struct EditorOpenRoutingChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw OpenRoutingFailure.failed(message) }
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "routing check requires suspended media")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-open-routing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "framethrower-open-routing-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstURL = directory.appendingPathComponent("first.framethrower")
        let secondURL = directory.appendingPathComponent("second.framethrower")
        let fixture = RecordingProject(screenFilename: "absent-screen.mp4", duration: 12)
        try JSONEncoder().encode(fixture).write(to: firstURL)
        try JSONEncoder().encode(fixture).write(to: secondURL)
        let model = CaptureViewModel(userDefaults: defaults, recordingDirectories: [])
        model.openRecording(at: firstURL)
        guard let first = model.editorOpenRequest else { throw OpenRoutingFailure.failed("missing first request") }
        // File Open's direct presenter, recorder observer, and existing editor
        // observers all see the very same request in one UI update.
        let menuAndObservers = (0..<5).compactMap { _ in model.consumeEditorOpenRequest(first) }
        try require(menuAndObservers == [firstURL], "one broadcast could present multiple editor windows")
        let editor = try model.editor(for: firstURL)
        try require(editor.rename(to: "Director interaction check — renamed"), "metadata rename")
        try require(editor.url == firstURL && model.editorOpenRequest == first && model.consumeEditorOpenRequest(first) == nil,
                    "title rename changed route identity or re-presented a consumed request")
        try require(try model.editor(for: firstURL) === editor, "renaming replaced the canonical editor session")

        // Every consumer ordering must still result in exactly one presenter.
        for consumer in 0..<5 {
            model.requestProjectEditor()
            guard let request = model.editorOpenRequest else { throw OpenRoutingFailure.failed("missing repeated request") }
            try require(request.id != first.id && request.url == firstURL, "later Open lost its fresh focus request")
            let winner = model.consumeEditorOpenRequest(request)
            try require(winner == firstURL, "consumer \(consumer) could not present the latest request")
            for _ in 0..<4 { try require(model.consumeEditorOpenRequest(request) == nil, "another observer could present the same request") }
        }
        model.openRecording(at: secondURL)
        guard let second = model.editorOpenRequest else { throw OpenRoutingFailure.failed("missing second project request") }
        try require(model.consumeEditorOpenRequest(first) == nil, "a delayed observer reopened an obsolete project")
        let forged = CaptureViewModel.EditorOpenRequest(url: firstURL)
        try require(model.consumeEditorOpenRequest(forged) == nil && model.consumeEditorOpenRequest(second) == secondURL,
                    "an unrelated request stole or redirected the current presentation")
        try require(model.consumeEditorOpenRequest(second) == nil && model.projectEditor?.url == secondURL,
                    "one-time consumption changed the recorder's active project")

        let alias = directory.appendingPathComponent("alias.framethrower")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstURL)
        model.openRecording(at: alias)
        guard let canonical = model.editorOpenRequest else { throw OpenRoutingFailure.failed("missing alias request") }
        try require(model.consumeEditorOpenRequest(canonical) == firstURL && model.projectEditor === editor,
                    "equivalent file paths created a different route or editor")
        try require(!model.isRecording && !model.camera.isPreparing && !model.camera.isRecording,
                    "window routing activated capture")
        print("PASS: single presentation across menu/recorder/editor observers, fresh reopen requests, stale request rejection, rename-stable identity and canonical aliases (project metadata only; no UI/media)")
    }
}
