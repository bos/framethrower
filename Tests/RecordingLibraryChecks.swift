import Foundation

private enum LibraryCheckError: Error { case failed(String) }

private actor ScanGate {
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<[RecordingLibraryEntry], Never>] = [:]
    var count: Int { nextID }

    func load() async -> [RecordingLibraryEntry] {
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { waiting[id] = $0 }
    }

    func finish(_ id: Int, with entries: [RecordingLibraryEntry]) {
        waiting.removeValue(forKey: id)?.resume(returning: entries)
    }
}

@main
@MainActor
struct RecordingLibraryChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-library-\(UUID().uuidString)")
        let movies = directory.appendingPathComponent("Movies")
        let imported = directory.appendingPathComponent("Imported")
        let suite = "FrameThrower.RecordingLibraryChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        let first = try fixture(at: movies.appendingPathComponent("first.framethrower"), source: "one.mp4", title: "Planning", duration: 12)
        let second = try fixture(at: movies.appendingPathComponent("second.framethrower"), source: "two.mp4", title: nil, duration: 3)
        let outside = try fixture(at: imported.appendingPathComponent("first.framethrower"), source: "one.mp4", title: "Planning", duration: 7)
        let nested = movies.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try fixture(at: nested.appendingPathComponent("hidden.framethrower"), source: "nested.mp4", title: "Nested", duration: 5)
        try Data("invalid project".utf8).write(to: movies.appendingPathComponent("broken.framethrower"))
        let missing = RecordingProject(screenFilename: "not-here.mp4", duration: 5)
        try JSONEncoder().encode(missing).write(to: movies.appendingPathComponent("missing.framethrower"))
        var unsupported = first.project
        unsupported.version = 99
        try JSONEncoder().encode(unsupported).write(to: movies.appendingPathComponent("future.framethrower"))
        try FileManager.default.createSymbolicLink(at: movies.appendingPathComponent("alias.framethrower"),
                                                 withDestinationURL: first.url)
        let sources = [first.source, second.source, outside.source]
        let sourceBytes = try sources.map { try Data(contentsOf: $0) }

        let library = RecordingLibrary(defaults: defaults, directories: [movies])
        await library.refresh()
        try require(library.entries.count == 2, "discover every valid top-level recording, deduplicate aliases, skip invalid/missing/nested projects")
        try require(Set(library.entries.map(\.projectURL)) == Set([first.url, second.url]), "discovery returned the wrong projects")
        let fallback = ProjectEditor(project: second.project, url: second.url).displayName
        try require(library.entries.first(where: { $0.id == second.url })?.displayName == fallback,
                    "an unnamed library row must use the same name as its editor")
        try require(library.entries.first(where: { $0.id == first.url })?.fileSize == Int64(sourceBytes[0].count),
                    "library metadata should show source size without decoding video")

        library.register(project: outside.project, at: outside.url)
        library.register(project: first.project, at: movies.appendingPathComponent("alias.framethrower"))
        try require(library.entries.count == 3, "same-named projects in different folders remain separate, canonical aliases do not duplicate")
        let reopened = RecordingLibrary(defaults: defaults, directories: [movies])
        await reopened.refresh()
        try require(Set(reopened.entries.map(\.id)) == Set(library.entries.map(\.id)), "explicitly opened recording outside Movies survives restart")

        let editor = try ProjectEditor.open(url: first.url)
        try require(editor.rename(to: "Roadmap"), "rename fixture")
        reopened.register(project: editor.project, at: editor.url)
        try require(reopened.entries.first(where: { $0.id == first.url })?.displayName == "Roadmap", "rename updates existing row without replacing other recordings")
        try require(editor.undo(), "undo fixture rename")
        reopened.register(project: editor.project, at: editor.url)
        try require(reopened.entries.first(where: { $0.id == first.url })?.displayName == "Planning", "undo synchronizes the library name")

        // Hold an old filesystem result while the UI saves a new name and a
        // separate recording. Publishing that result must preserve both edits.
        let oldEntries = reopened.entries
        let gate = ScanGate()
        let racing = RecordingLibrary(defaults: defaults, directories: [], load: { _, _ in await gate.load() })
        let scan = Task { await racing.refresh() }
        try await wait { await gate.count == 1 }
        try require(editor.rename(to: "Newer title"), "rename during a suspended scan")
        racing.register(project: editor.project, at: editor.url)
        racing.register(project: outside.project, at: outside.url)
        await gate.finish(0, with: oldEntries.filter { $0.id != outside.url })
        await scan.value
        try require(racing.entries.first(where: { $0.id == first.url })?.displayName == "Newer title",
                    "stale scan overwrote a newly saved recording name")
        try require(racing.entries.contains(where: { $0.id == outside.url }), "stale scan erased a newly registered recording")

        let cancelled = Task { await racing.refresh() }
        try await wait { await gate.count == 2 }
        cancelled.cancel()
        await gate.finish(1, with: [])
        await cancelled.value
        try require(racing.entries.count == 3, "cancelled scan published its obsolete result")

        let newerEntries = racing.entries
        let olderScan = Task { await racing.refresh() }
        try await wait { await gate.count == 3 }
        let newerScan = Task { await racing.refresh() }
        try await wait { await gate.count == 4 }
        await gate.finish(3, with: newerEntries)
        await newerScan.value
        await gate.finish(2, with: oldEntries)
        await olderScan.value
        try require(racing.entries == newerEntries, "an older refresh replaced a newer refresh that completed first")

        let projectBytes = try Data(contentsOf: first.url)
        let dismissed = RecordingLibrary(defaults: defaults, directories: [movies])
        await dismissed.refresh()
        dismissed.remove(at: first.url)
        try require(dismissed.entries.count == 2 && dismissed.canUndoRemoval, "remove must dismiss only its row and offer undo")
        try require(try Data(contentsOf: first.url) == projectBytes, "removing a row changed its project file")
        dismissed.register(project: editor.project, at: editor.url)
        try require(!dismissed.entries.contains(where: { $0.id == first.url }), "an existing editor update resurrected a removed row")
        await dismissed.refresh()
        try require(!dismissed.entries.contains(where: { $0.id == first.url }), "Movies discovery resurrected a removed row")
        let afterRemovalRestart = RecordingLibrary(defaults: defaults, directories: [movies])
        await afterRemovalRestart.refresh()
        try require(afterRemovalRestart.entries.count == 2 && afterRemovalRestart.canUndoRemoval,
                    "dismissal and its undo must survive app restart")
        try require(afterRemovalRestart.restoreLastRemoved(), "undo removal after restarting")
        try require(afterRemovalRestart.entries.count == 3 && !afterRemovalRestart.canUndoRemoval,
                    "undo must restore the row without duplicating it")
        afterRemovalRestart.remove(at: first.url)
        afterRemovalRestart.register(project: editor.project, at: editor.url, restoreRemoved: true)
        try require(afterRemovalRestart.entries.count == 3 && !afterRemovalRestart.canUndoRemoval,
                    "explicitly opening a removed project must restore it and clear its pending removal")

        let dismissalGate = ScanGate()
        let dismissalRace = RecordingLibrary(defaults: defaults, directories: [], load: { _, _ in await dismissalGate.load() })
        dismissalRace.register(project: editor.project, at: editor.url)
        let beforeRemovalScan = Task { await dismissalRace.refresh() }
        try await wait { await dismissalGate.count == 1 }
        dismissalRace.remove(at: first.url)
        await dismissalGate.finish(0, with: newerEntries)
        await beforeRemovalScan.value
        try require(!dismissalRace.entries.contains(where: { $0.id == first.url }),
                    "an in-flight scan resurrected a row removed while it was running")
        try require(dismissalRace.restoreLastRemoved(), "restore after an in-flight scan")

        // Unavailable files keep their removal history so reconnecting/recovering
        // the originals permits Undo instead of silently losing the dismissal.
        dismissalRace.remove(at: first.url)
        try FileManager.default.moveItem(at: first.url, to: first.url.appendingPathExtension("temporary"))
        try require(!dismissalRace.restoreLastRemoved() && dismissalRace.canUndoRemoval,
                    "an unavailable project should not lose its removal history")
        try FileManager.default.moveItem(at: first.url.appendingPathExtension("temporary"), to: first.url)
        try require(dismissalRace.restoreLastRemoved(), "undo should work after a removed project becomes available again")
        for (url, original) in zip(sources, sourceBytes) {
            try require(try Data(contentsOf: url) == original, "library operations modified original source bytes")
        }
        print("Recording library checks passed (discovery, persistence, canonical identity, name/undo updates, removal/restore across restart, stale-scan isolation, cancellation, and immutable sources).")
    }

    private static func fixture(at url: URL, source: String, title: String?, duration: Double) throws
        -> (url: URL, source: URL, project: RecordingProject) {
        let media = url.deletingLastPathComponent().appendingPathComponent(source)
        try Data("original source \(duration)".utf8).write(to: media)
        var project = RecordingProject(screenFilename: source, duration: duration)
        project.title = title
        try JSONEncoder().encode(project).write(to: url)
        return (url.standardizedFileURL.resolvingSymlinksInPath(), media, project)
    }

    private static func wait(until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw LibraryCheckError.failed("test scan did not start") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw LibraryCheckError.failed(message) }
    }
}
