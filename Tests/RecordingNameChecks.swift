import Foundation

private enum NameCheckError: Error { case failed(String) }

@main
@MainActor
struct RecordingNameChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFiles = ["screen.mp4", "camera.mov", "cursor.json"]
        let sources = sourceFiles.map { Data("immutable source \($0)".utf8) }
        for (name, bytes) in zip(sourceFiles, sources) {
            try bytes.write(to: directory.appendingPathComponent(name))
        }
        let url = directory.appendingPathComponent("My recording.framethrower")
        let initial = RecordingProject(screenFilename: "screen.mp4", cameraFilename: "camera.mov", cursorFilename: "cursor.json", duration: 10)
        let editor = ProjectEditor(project: initial, url: url)
        try require(editor.displayName == "My recording" && initial.displayName(projectURL: url) == editor.displayName,
                    "library and editor fallback names must match")
        try require(editor.save(), "save initial project")
        let legacy = try ProjectEditor.open(url: url)
        try require(legacy.project.title == nil && legacy.displayName == editor.displayName, "legacy project must open without title metadata")

        try require(editor.rename(to: "  Dinner\t demo \n"), "rename normalizes whitespace")
        try require(editor.project.title == "Dinner demo" && editor.displayName == "Dinner demo", "rename must produce a single-line name")
        try require(editor.undoName == "Rename recording" && editor.project.undoHistory.count == 1, "rename is one undo step")
        var trimmed = initial.state
        trimmed.trimEnd = 8
        try require(editor.commit(trimmed, name: "Trim"), "trim named recording")
        try require(editor.rename(to: "Review 📷"), "second rename")
        let reopened = try ProjectEditor.open(url: url)
        try require(reopened.project == editor.project && reopened.displayName == "Review 📷", "names and mixed history survive reopening")
        try require(reopened.undo() && reopened.displayName == "Dinner demo" && reopened.project.state == trimmed,
                    "undo rename must preserve video edits")
        try require(reopened.undo() && reopened.displayName == "Dinner demo" && reopened.project.state == initial.state,
                    "undo video edit must retain its recording name")
        try require(reopened.undo() && reopened.project.title == nil && reopened.displayName == "My recording",
                    "undo first rename restores the original fallback name")
        let withRedo = try ProjectEditor.open(url: url)
        try require(withRedo.redo() && withRedo.displayName == "Dinner demo", "persisted redo restores first name")
        try require(withRedo.redo() && withRedo.project.state == trimmed && withRedo.displayName == "Dinner demo", "redo trim preserves name")
        try require(withRedo.redo() && withRedo.displayName == "Review 📷", "redo restores second name")

        let beforeNoOp = withRedo.project
        try require(withRedo.rename(to: " \nReview 📷\t") && withRedo.project == beforeNoOp, "same normalized name must not add undo")
        let bytesBeforeInvalid = try Data(contentsOf: url)
        for invalid in ["", " \t\n", "bad\0name", "bad\u{7}name", String(repeating: "x", count: 257)] {
            try require(!withRedo.rename(to: invalid) && withRedo.project == beforeNoOp && withRedo.errorMessage != nil,
                        "invalid rename must preserve project and history")
            try require(try Data(contentsOf: url) == bytesBeforeInvalid, "invalid rename must preserve durable project")
        }
        try require(withRedo.rename(to: withRedo.displayName) && withRedo.errorMessage == nil, "correcting a rename clears the error")
        try require(withRedo.rename(to: String(repeating: "👩‍💻", count: 256)), "256 Unicode characters, including joined emoji, are valid")
        try require(withRedo.undo() && withRedo.displayName == "Review 📷", "large Unicode title remains reversible")
        try require(withRedo.rename(to: "../A / B"), "display names are metadata, not filesystem paths")
        try require(withRedo.project.screenFilename == initial.screenFilename && withRedo.project.cameraFilename == initial.cameraFilename && withRedo.project.cursorFilename == initial.cursorFilename,
                    "renaming must not alter media filenames")

        let otherURL = directory.appendingPathComponent("Other.framethrower")
        let other = ProjectEditor(project: initial, url: otherURL)
        try require(other.save() && other.rename(to: "Other take"), "name a second project")
        try require(withRedo.displayName == "../A / B" && other.displayName == "Other take", "different recording names must remain independent")

        let beforeFailure = withRedo.project
        let movedDirectory = directory.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: directory, to: movedDirectory)
        try require(!withRedo.rename(to: "Cannot save yet") && withRedo.project == beforeFailure,
                    "write failure cannot change the visible name or consume history")
        try FileManager.default.moveItem(at: movedDirectory, to: directory)
        try require(withRedo.rename(to: "Saved again") && withRedo.errorMessage == nil, "rename can retry after a write failure")

        for (name, bytes) in zip(sourceFiles, sources) {
            try require(try Data(contentsOf: directory.appendingPathComponent(name)) == bytes, "renaming and history must preserve every source byte")
        }
        var invalidHistory = initial
        invalidHistory.undoHistory = [NamedEditSnapshot(name: "Rename", state: initial.state, title: "bad\nname")]
        do { try invalidHistory.validate(); throw NameCheckError.failed("invalid title in history was accepted") }
        catch is ProjectError { }

        let timestamped = RecordingProject(screenFilename: "Screencast-20261105-215029-abcdef.mp4", duration: 1)
        let timestampURL = directory.appendingPathComponent("Screencast-20261105-215029-abcdef.framethrower")
        let timestampEditor = ProjectEditor(project: timestamped, url: timestampURL)
        try require(timestampEditor.displayName.hasPrefix("Recording ") && !timestampEditor.displayName.contains("abcdef") && timestampEditor.displayName == timestamped.displayName(projectURL: timestampURL),
                    "generated capture names use the same friendly timestamp in library and editor")
        print("Recording name checks passed (legacy names, normalized Unicode titles, mixed edit/name undo and redo, reopening, failed-write recovery, independent projects, and immutable sources).")
    }

    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NameCheckError.failed(message) }
    }
}
