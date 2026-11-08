import Combine
import Darwin
import Foundation

@main
@MainActor
struct RecordingDuplicateChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--duplicate" {
            let editor = try ProjectEditor.open(url: URL(fileURLWithPath: CommandLine.arguments[2]))
            guard let copy = editor.duplicate() else { throw Failure.failed(editor.errorMessage ?? "Duplicate failed") }
            try Data(copy.url.path.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .withoutOverwriting)
            return
        }
        try require(MediaProcessing.isSuspended, "checks require the media interlock")
        try snapshotAndConflict()
        try reservedNames()
        try longNamesAndRecovery()
        try unavailableDirectory()
        try await concurrentCopies()
        print("Recording duplicate checks passed (visible draft/reference snapshot, fresh independent history and title, unchanged original bytes/recovery/conflict, shared source files, reserved names and journals, Unicode/NAME_MAX, copy recovery, unavailable directory, eight-process atomic name race; metadata only).")
    }

    private static func snapshotAndConflict() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = fixture.editor
        var edited = editor.project.state
        let zoom = ZoomKeyframe(time: 2, scale: 1.8)
        edited.zoomKeyframes = [zoom]
        edited.pipKeyframes.append(PIPKeyframe(time: 2, placement: PIPPlacement(x: 0.2, y: 0.3, shape: .circle)))
        edited.regions = [EditorRegion(time: 2, rect: EditorRegionRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3), editID: zoom.id)]
        try require(editor.commit(edited, name: "Framing") && editor.rename(to: "Temporary name") && editor.undo(), "prepare both original history branches")
        var draft = editor.editingState
        draft.audio = RecordingAudio(isMuted: true, volume: 0.6, fadeIn: 2, fadeOut: 3)
        draft.presentation.padding = 0.1
        draft.cursorStyle.smoothing = 0.7
        draft.regions.append(EditorRegion(time: 4, rect: EditorRegionRect(x: 0.5, y: 0.1, width: 0.2, height: 0.3)))
        try require(editor.updateDraft(draft, at: 4) && editor.flushRecovery(), "prepare unsaved visible edits")
        var external = editor.project
        external.state.trimStart = 1
        let externalBytes = try JSONEncoder().encode(external)
        try externalBytes.write(to: editor.url, options: .atomic)
        try require(!editor.save(), "external project edit must prevent overwriting the original")
        let baseline = editor.project
        let originalError = editor.errorMessage
        let journal = try Data(contentsOf: editor.recoveryURL)
        var originalPublications = 0
        let observation = editor.$project.dropFirst().sink { _ in originalPublications += 1 }
        defer { observation.cancel() }
        guard let copy = editor.duplicate() else { throw Failure.failed(editor.errorMessage ?? "Duplicate conflict snapshot") }
        try require(copy.url == fixture.directory.appendingPathComponent("recording copy.framethrower") && copy.displayName == "Planning copy", "copy URL and title")
        try require(copy.automationID != editor.automationID && copy.project.automationID != nil, "a duplicate has a fresh persistent recording identity")
        try require(copy.project.state == draft && copy.references == editor.references && copy.draftState == nil &&
                    copy.project.undoHistory.isEmpty && copy.project.redoHistory.isEmpty && !copy.canUndo && !copy.canRedo,
                    "copy must save the visible draft/reference catalog as a fresh history baseline")
        try require(copy.project.screenFilename == baseline.screenFilename && copy.project.cameraFilename == baseline.cameraFilename &&
                    copy.project.cursorFilename == baseline.cursorFilename && copy.project.cameraOffset == baseline.cameraOffset &&
                    copy.project.captureFrameDuration == baseline.captureFrameDuration && copy.project.duration == baseline.duration,
                    "duplicate must retain source filenames, offsets, cadence and duration")
        try require(try ProjectEditor.open(url: copy.url).project == copy.project, "duplicate is immediately reopenable")
        try require(copy.rename(to: "Independent title") && copy.undo() && copy.displayName == "Planning copy" && copy.redo(), "copy has independent name and Undo/Redo")
        guard let next = editor.duplicate() else { throw Failure.failed("Duplicate a second snapshot") }
        try require(next.displayName == "Planning copy 2" && next.url.lastPathComponent == "recording copy 2.framethrower", "repeated duplication reserves increasing names")
        try require(editor.project == baseline && editor.draftState == draft && editor.draftTime == 4 && editor.errorMessage == originalError && originalPublications == 0,
                    "duplicate cannot commit, cancel, clear the conflict, or publish the original editor")
        try require(try Data(contentsOf: editor.url) == externalBytes && Data(contentsOf: editor.recoveryURL) == journal,
                    "duplicate must preserve original project and recovery bytes even across an external save conflict")
        try fixture.assertSources()
        try noStaging(in: fixture.directory)
    }

    private static func reservedNames() throws {
        let fixture = try Fixture(screen: "RECORDING COPY.framethrower", camera: "recording copy 2.framethrower.recovery")
        defer { fixture.remove() }
        // Missing source names still reserve both their data and journal slots.
        for file in fixture.sources { try FileManager.default.removeItem(at: file) }
        let oldJournal = fixture.directory.appendingPathComponent("recording copy 3.framethrower.recovery")
        let protected = Data("unrelated unfinished work".utf8)
        try protected.write(to: oldJournal)
        try FileManager.default.createDirectory(at: fixture.directory.appendingPathComponent("recording copy 4.framethrower"), withIntermediateDirectories: false)
        let dangling = fixture.directory.appendingPathComponent("recording copy 5.framethrower")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: fixture.directory.appendingPathComponent("not-here.txt"))
        let openButMissing = fixture.directory.appendingPathComponent("recording copy 6.framethrower")
        guard let copy = fixture.editor.duplicate(avoiding: [openButMissing]) else { throw Failure.failed("Duplicate around reserved names") }
        try require(copy.url.lastPathComponent == "recording copy 7.framethrower" && copy.displayName == "Planning copy 7", "source, journal, directory, symlink and open-window names must be reserved")
        try require(try Data(contentsOf: oldJournal) == protected, "duplicate replaced unrelated recovery data")
        try require(try FileManager.default.attributesOfItem(atPath: dangling.path)[.type] as? FileAttributeType == .typeSymbolicLink, "duplicate replaced a dangling link")
        try require(fixture.sources.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "duplicate created or copied missing footage")
        try noStaging(in: fixture.directory)
    }

    private static func longNamesAndRecovery() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stem = String(repeating: "é", count: 119) + "long"
        let originalURL = directory.appendingPathComponent(stem + ".framethrower")
        let project = RecordingProject(screenFilename: "missing.txt", duration: 5, title: String(repeating: "👩‍💻", count: 256))
        let editor = ProjectEditor(project: project, url: originalURL)
        try require(editor.save(), "save a near-NAME_MAX project with a maximum Unicode title")
        guard let copy = editor.duplicate() else { throw Failure.failed(editor.errorMessage ?? "Duplicate long filename") }
        try require(copy.url.lastPathComponent.utf8.count <= 255 && copy.recoveryURL.lastPathComponent.utf8.count <= 255 &&
                    copy.displayName.count <= 256 && copy.displayName.hasSuffix(" copy"), "copy and its future journal must fit filename and title limits")
        var draft = copy.editingState
        draft.audio.volume = 0.5
        try require(copy.updateDraft(draft, at: 1) && copy.flushRecovery(), "long-name copy can preserve unfinished work")
        let restored = try ProjectEditor.open(url: copy.url)
        try require(restored.recoveryRestored && restored.draftState == draft, "long-name copy journal recovers normally")
        let absentOriginal = directory.appendingPathComponent("unsaved.framethrower")
        let unsaved = ProjectEditor(project: project, url: absentOriginal)
        try require(unsaved.duplicate() != nil && !FileManager.default.fileExists(atPath: absentOriginal.path), "duplicate must not save an unsaved original")
    }

    private static func unavailableDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let baseline = fixture.editor.project
        var draft = baseline.state
        draft.audio.volume = 0.4
        try require(fixture.editor.updateDraft(draft, at: 1) && fixture.editor.flushRecovery(), "prepare failed-duplicate fixture")
        let projectBytes = try Data(contentsOf: fixture.editor.url)
        let journalBytes = try Data(contentsOf: fixture.editor.recoveryURL)
        let moved = fixture.directory.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: fixture.directory, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: fixture.directory) }
        try require(fixture.editor.duplicate() == nil && fixture.editor.errorMessage != nil &&
                    fixture.editor.project == baseline && fixture.editor.draftState == draft, "failed duplication must retain draft and history and report an error")
        try require(try Data(contentsOf: moved.appendingPathComponent(fixture.editor.url.lastPathComponent)) == projectBytes &&
                    Data(contentsOf: moved.appendingPathComponent(fixture.editor.recoveryURL.lastPathComponent)) == journalBytes,
                    "failed duplication changed the original project or journal")
        try noStaging(in: moved)
    }

    private static func concurrentCopies() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "missing.txt", duration: 5, title: "Race"),
                                   url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "save concurrent-copy fixture")
        let original = try Data(contentsOf: editor.url)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var children: [(Process, URL)] = []
        defer { for (child, _) in children where child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) } }
        for index in 0..<8 {
            let receipt = directory.appendingPathComponent("result-\(index).txt")
            let child = Process()
            child.executableURL = executable
            child.arguments = ["--duplicate", editor.url.path, receipt.path]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.standardError
            try child.run()
            children.append((child, receipt))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var copies: [URL] = []
        for (child, receipt) in children {
            while child.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try require(!child.isRunning && child.terminationStatus == 0, "concurrent duplicate child failed or hung")
            let path = try String(contentsOf: receipt, encoding: .utf8)
            copies.append(URL(fileURLWithPath: path))
        }
        try require(Set(copies).count == 8, "concurrent processes reused a duplicate URL")
        let titles = try copies.map { try ProjectEditor.open(url: $0).displayName }
        try require(Set(titles) == Set((1...8).map { $0 == 1 ? "Race copy" : "Race copy \($0)" }), "concurrent copies must use independent increasing titles")
        try require(try Data(contentsOf: editor.url) == original && editor.project.undoHistory.isEmpty, "concurrent duplication changed its original")
        try noStaging(in: directory)
    }

    @MainActor private struct Fixture {
        let directory: URL
        let editor: ProjectEditor
        let sources: [URL]
        init(screen: String = "screen.txt", camera: String = "camera.txt") throws {
            let directory = try temporaryDirectory()
            self.directory = directory
            let names = [screen, camera, "pointer.txt"]
            sources = names.map { directory.appendingPathComponent($0) }
            for source in sources { try Data("immutable \(source.lastPathComponent)".utf8).write(to: source) }
            editor = ProjectEditor(project: RecordingProject(screenFilename: screen, cameraFilename: camera, cursorFilename: "pointer.txt",
                cameraOffset: -0.25, duration: 12, title: "Planning", captureFrameDuration: 1.0 / 60),
                url: directory.appendingPathComponent("recording.framethrower"))
            try require(editor.save(), "save duplicate fixture")
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func assertSources() throws {
            for source in sources { try require(try Data(contentsOf: source) == Data("immutable \(source.lastPathComponent)".utf8), "duplicate changed a shared original") }
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private static func noStaging(in directory: URL) throws {
        try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".framethrower-save-") }, "duplicate leaked staged metadata")
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.failed(message) }
    }
}
