import Foundation

private enum ImportCheckError: Error { case failed(String) }

/// Supplied metadata and plain text exercise project persistence. No movie
/// fixtures, asset inspection, capture, playback, or decoding run here.
@main @MainActor
struct VideoImportChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ImportCheckError.failed(message) }
    }

    static func main() async throws {
        try require(MediaProcessing.isSuspended, "Checks require the media interlock")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-import-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Existing source.txt")
        let original = Data("Plain text for file persistence checks; not a video fixture.".utf8)
        try original.write(to: source)
        let metadata = VideoImporter.Metadata(duration: 12.75, frameDuration: 1001.0 / 30000)
        let editor = try VideoImporter.createProject(for: source, metadata: metadata)
        try require(editor.url == directory.appendingPathComponent("Existing source.framethrower"), "Sidecar location")
        let project = try ProjectEditor.open(url: editor.url).project
        try require(project.screenFilename == source.lastPathComponent && project.duration == metadata.duration,
                    "Full source is referenced by its relative name")
        try require(project.state.trimStart == 0 && project.state.trimEnd == metadata.duration &&
                    project.captureFrameDuration == metadata.frameDuration, "Duration and fractional cadence survive saving")
        try require(project.cameraFilename == nil && project.cursorFilename == nil && project.sceneFilename == nil &&
                    project.state.audio == RecordingAudio(), "No invented sidecars or changed audio settings")

        let saved = try Data(contentsOf: editor.url)
        let recovery = directory.appendingPathComponent("Existing source 2.framethrower.recovery")
        let recoveryData = Data("Unrelated recovery data".utf8)
        try recoveryData.write(to: recovery)
        let occupied = directory.appendingPathComponent("Existing source 3.framethrower")
        try FileManager.default.createSymbolicLink(at: occupied, withDestinationURL: directory.appendingPathComponent("absent"))
        let copy = try VideoImporter.createProject(for: source, metadata: metadata)
        try require(copy.url.lastPathComponent == "Existing source 4.framethrower", "Preserve projects, recovery files, and dangling links")
        try require(copy.project.automationID != editor.project.automationID, "Independent edit identity")
        try require(try Data(contentsOf: editor.url) == saved && Data(contentsOf: recovery) == recoveryData &&
                    Data(contentsOf: source) == original, "Never overwrite the source or prior work")
        var state = copy.project.state
        state.trimStart = 2
        state.zoomKeyframes = [ZoomKeyframe(time: 3, scale: 2)]
        try require(copy.commit(state, name: "Edit imported source") && copy.undo() && copy.redo(), "Ordinary editing and undo/redo")
        try require(try Data(contentsOf: source) == original, "Editing leaves source bytes intact")

        let alias = directory.appendingPathComponent("Alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let aliased = try VideoImporter.createProject(for: alias, metadata: metadata)
        try require(aliased.project.screenFilename == source.lastPathComponent, "Canonical source beside project")
        let fast = try VideoImporter.createProject(for: source, metadata: .init(duration: 3, frameDuration: 1.0 / 240))
        let slow = try VideoImporter.createProject(for: source, metadata: .init(duration: 3, frameDuration: 2))
        try require(fast.project.captureFrameDuration == 1.0 / 120 && slow.project.captureFrameDuration == 1,
                    "Render cadence respects editor bounds")
        let beforeInvalid = try FileManager.default.contentsOfDirectory(atPath: directory.path).count
        for invalid in [VideoImporter.Metadata(duration: 0, frameDuration: 1.0 / 30),
                        .init(duration: .nan, frameDuration: 1.0 / 30), .init(duration: .infinity, frameDuration: 1.0 / 30),
                        .init(duration: 3, frameDuration: 0), .init(duration: 3, frameDuration: .nan)] {
            do {
                _ = try VideoImporter.createProject(for: source, metadata: invalid)
                throw ImportCheckError.failed("Invalid metadata accepted")
            } catch VideoImporter.ImportError.invalidTiming { }
        }
        for invalid in [directory, directory.appendingPathComponent("missing.txt"), URL(string: "https://example.com/video.mov")!] {
            do {
                _ = try VideoImporter.createProject(for: invalid, metadata: metadata)
                throw ImportCheckError.failed("Invalid source accepted")
            } catch VideoImporter.ImportError.invalidFile { }
        }
        try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == beforeInvalid,
                    "Rejected imports leave no new files")
        for inspectOnly in [false, true] {
            do {
                if inspectOnly { _ = try await VideoImporter.inspect(directory.appendingPathComponent("missing.mov")) }
                else { _ = try await VideoImporter.importVideo(at: directory.appendingPathComponent("missing.mov")) }
                throw ImportCheckError.failed("Media accessed while suspended")
            } catch is MediaProcessing.Suspended { }
        }
        try require(VideoImporter.contentTypes.contains(.movie) && VideoImporter.contentTypes.contains(.video), "Broad chooser types")
        print("PASS: import project creation, timing, edit history, collision/recovery protection, aliases, validation, and media interlock (plain text only; no media access)")
    }
}
