import Foundation

private struct VideoStorageFailure: Error { let message: String }
@main @MainActor
struct MultiVideoImportChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw VideoStorageFailure(message: message) }
    }
    static func main() async throws {
        try require(MediaProcessing.isSuspended, "video interlock must stay enabled")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-storage-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Library.framethrower")
        let original = root.appendingPathComponent("Fixture.txt")
        let bytes = Data("Metadata-only file fixture, not a media file.\n".utf8)
        try bytes.write(to: original)
        let metadata = VideoImporter.Metadata(duration: 8, frameDuration: 1.0 / 30,
            pixelWidth: 1080, pixelHeight: 1920, hasAudio: true)
        let stored = try ProjectVideoImport.storeSource(at: original, projectURL: projectURL, metadata: metadata)
        let copied = try stored.source.resolvedURL(in: root)
        try require(copied != original && copied.path.hasPrefix(root.appendingPathComponent("Library.media").path + "/"), "copy must be inside managed sidecar")
        try require(try Data(contentsOf: copied) == bytes && Data(contentsOf: original) == bytes, "copy and original bytes changed")
        try require(stored.source.pixelWidth == 1080 && stored.source.pixelHeight == 1920 && stored.source.hasAudio == true, "oriented source metadata lost")
        let source = stored.source
        var project = RecordingProject(screenFilename: "unopened.txt", duration: 14)
        let first = VideoClip(sourceID: source.id, start: 1, end: 5, sourceStart: 1)
        let second = VideoClip(sourceID: source.id, start: 6, end: 10, sourceStart: 2)
        let layer = VideoLayer(name: "Reuse", clips: [first, second])
        var state = project.state; state.videoLayers = [layer]
        let editor = ProjectEditor(project: project, url: projectURL)
        try require(editor.save() && editor.registerVideoSource(source, state: state), "register copied source")
        project = editor.project
        try require(project.videoAssets.count == 1 && project.state.videoLayers?.first?.clips.count == 2, "reuse made multiple assets")
        try require(editor.undo() && FileManager.default.fileExists(atPath: copied.path), "Undo deleted retained source")
        try require(editor.redo() && editor.project.videoAssets.count == 1, "Redo lost source")
        let before = try Data(contentsOf: projectURL)
        do {
            _ = try await ProjectVideoImport.addSources([original], to: editor, at: 0)
            throw VideoStorageFailure(message: "interlock unexpectedly imported video")
        } catch is VideoStorageFailure { throw VideoStorageFailure(message: "interlock unexpectedly imported video") }
        catch { }
        try require(try Data(contentsOf: projectURL) == before, "blocked import mutated project")
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedProject = root.appendingPathComponent("Linked.framethrower")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Linked.media"), withDestinationURL: outside)
        // An internal symlink remains within the project directory and is safe.
        let internalCopy = try ProjectVideoImport.storeSource(at: original, projectURL: linkedProject, metadata: metadata)
        try require(internalCopy.directory.path.hasPrefix(outside.path + "/"), "internal alias resolved incorrectly")
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("video-storage-outside-\(UUID())")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Escape.media"), withDestinationURL: external)
        do {
            _ = try ProjectVideoImport.storeSource(at: original, projectURL: root.appendingPathComponent("Escape.framethrower"), metadata: metadata)
            throw VideoStorageFailure(message: "escaped project directory")
        } catch is VideoStorageFailure { throw VideoStorageFailure(message: "escaped project directory") }
        catch { }
        try require(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty, "rejected import wrote outside project")
        print("Multi-video storage checks passed (text fixtures; no media)")
    }
}
