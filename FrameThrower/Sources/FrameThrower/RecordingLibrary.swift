import Combine
import Foundation

struct RecordingLibraryEntry: Identifiable, Equatable, Sendable {
    var id: URL { projectURL }
    let projectURL: URL
    let sourceURL: URL
    let displayName: String
    let duration: Double
    let fileSize: Int64?
    let createdAt: Date

    fileprivate static func make(project: RecordingProject, at url: URL) -> Self? {
        guard (try? project.validate()) != nil else { return nil }
        let projectURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let sourceURL = projectURL.deletingLastPathComponent()
            .appendingPathComponent(project.screenFilename).standardizedFileURL.resolvingSymlinksInPath()
        guard let projectAttributes = try? FileManager.default.attributesOfItem(atPath: projectURL.path),
              projectAttributes[.type] as? FileAttributeType == .typeRegular,
              let source = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              source[.type] as? FileAttributeType == .typeRegular else { return nil }
        let createdAt = source[.creationDate] as? Date
            ?? projectAttributes[.creationDate] as? Date
            ?? source[.modificationDate] as? Date ?? .distantPast
        return Self(projectURL: projectURL, sourceURL: sourceURL,
                    displayName: project.displayName(projectURL: projectURL), duration: project.duration,
                    fileSize: (source[.size] as? NSNumber)?.int64Value, createdAt: createdAt)
    }
}

/// The index remembers explicitly opened projects. App-created projects are also
/// discovered at the top level of Movies; scanning never decodes media, moves
/// sources, or recursively searches the user's filesystem.
@MainActor
final class RecordingLibrary: ObservableObject {
    typealias Loader = @Sendable ([URL], [URL]) async -> [RecordingLibraryEntry]
    @Published private(set) var entries: [RecordingLibraryEntry] = []
    @Published private(set) var canUndoRemoval = false
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let directories: [URL]
    private static let indexKey = "recordings.recentProjectPaths"
    private static let removalKey = "recordings.removedProjects"
    private let load: Loader
    private var rememberedURLs: [URL]
    private var removedURLs: Set<URL>
    private var removalHistory: [URL]
    private var scanTask: Task<[RecordingLibraryEntry], Never>?
    private var refreshGeneration: UInt64 = 0
    private var mutationRevision: UInt64 = 0
    private var mutations: [URL: (revision: UInt64, entry: RecordingLibraryEntry)] = [:]

    init(defaults: UserDefaults = .standard, directories: [URL]? = nil, load: Loader? = nil) {
        self.defaults = defaults
        self.directories = directories ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)
        var seen = Set<URL>()
        self.load = load ?? { Self.scan(indexed: $0, directories: $1) }
        rememberedURLs = (defaults.stringArray(forKey: Self.indexKey) ?? []).compactMap { path in
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(url).inserted ? url : nil
        }
        rememberedURLs = Array(rememberedURLs.prefix(200))
        let removal = defaults.dictionary(forKey: Self.removalKey) ?? [:]
        let removed = Set(Self.urls(from: removal["hidden"] as? [String] ?? []))
        removedURLs = removed
        var seenRemovals = Set<URL>()
        let history = Self.urls(from: removal["history"] as? [String] ?? []).reversed().filter {
            removed.contains($0) && seenRemovals.insert($0).inserted
        }
        removalHistory = Array(history.reversed().suffix(200))
        canUndoRemoval = !removalHistory.isEmpty
    }

    /// Upsert the already-loaded shared editor snapshot after saving or undo.
    /// Reading file attributes is bounded; video decoding never runs here.
    func register(project: RecordingProject, at url: URL, restoreRemoved: Bool = false) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        // Changes from an already-open editor must not silently put a dismissed
        // recording back in the list. Only an explicit Open or undo may do that.
        guard restoreRemoved || !removedURLs.contains(canonical) else { return }
        guard let entry = RecordingLibraryEntry.make(project: project, at: url) else { return }
        errorMessage = nil
        if restoreRemoved, removedURLs.remove(canonical) != nil {
            removalHistory.removeAll { $0 == canonical }
            persistRemovals()
        }
        rememberedURLs.removeAll { $0 == entry.projectURL }
        rememberedURLs.insert(entry.projectURL, at: 0)
        rememberedURLs = Array(rememberedURLs.prefix(200))
        defaults.set(rememberedURLs.map(\.path), forKey: Self.indexKey)
        mutationRevision &+= 1
        mutations[entry.projectURL] = (mutationRevision, entry)
        var updated = entries.filter { $0.projectURL != entry.projectURL }
        updated.append(entry)
        entries = Self.sorted(updated)
    }

    /// Remove from this list only. Project and source files are never changed.
    func remove(at url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard entries.contains(where: { $0.projectURL == canonical }) else { return }
        errorMessage = nil
        removedURLs.insert(canonical)
        removalHistory.removeAll { $0 == canonical }
        removalHistory.append(canonical)
        removalHistory = Array(removalHistory.suffix(200))
        persistRemovals()
        mutationRevision &+= 1
        mutations.removeValue(forKey: canonical)
        entries.removeAll { $0.projectURL == canonical }
    }

    /// Leave an unavailable removal in history so reconnecting its disk permits
    /// undo later. Explicitly reopening a removed project also restores its row.
    @discardableResult
    func restoreLastRemoved() -> Bool {
        guard let url = removalHistory.last,
              let data = try? Data(contentsOf: url),
              let project = try? JSONDecoder().decode(RecordingProject.self, from: data),
              RecordingLibraryEntry.make(project: project, at: url) != nil else {
            errorMessage = "The recording files aren't available. Reconnect their disk or open the project from its current location."
            return false
        }
        register(project: project, at: url, restoreRemoved: true)
        return entries.contains { $0.projectURL == url }
    }

    private func persistRemovals() {
        defaults.set(["hidden": removedURLs.map(\.path).sorted(), "history": removalHistory.map(\.path)],
                     forKey: Self.removalKey)
        canUndoRemoval = !removalHistory.isEmpty
    }

    func refresh() async {
        refreshGeneration &+= 1
        let request = refreshGeneration
        let revision = mutationRevision
        let paths = rememberedURLs
        let directories = directories
        let load = load
        scanTask?.cancel()
        let task = Task.detached(priority: .utility) { await load(paths, directories) }
        scanTask = task
        let scanned = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        guard !Task.isCancelled, request == refreshGeneration else { return }
        scanTask = nil
        var result = Dictionary(uniqueKeysWithValues: scanned.map { ($0.projectURL, $0) })
        // A refresh begun before an editor save must not publish an older name,
        // erase a new recording, or revert an undo that completed while scanning.
        for (url, mutation) in mutations where mutation.revision > revision {
            result[url] = mutation.entry
        }
        entries = Self.sorted(result.values.filter { !removedURLs.contains($0.projectURL) })
        mutations = mutations.filter { $0.value.revision > revision }
    }

    deinit { scanTask?.cancel() }

    private nonisolated static func urls(from paths: [String]) -> [URL] {
        paths.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    private nonisolated static func scan(indexed: [URL], directories: [URL]) -> [RecordingLibraryEntry] {
        var candidates = indexed
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            candidates.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "framethrower" })
        }
        var seen = Set<URL>()
        var result: [RecordingLibraryEntry] = []
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            let url = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(url).inserted,
                  let data = try? Data(contentsOf: url),
                  let project = try? JSONDecoder().decode(RecordingProject.self, from: data),
                  let entry = RecordingLibraryEntry.make(project: project, at: url) else { continue }
            result.append(entry)
        }
        return result
    }

    private nonisolated static func sorted(_ entries: [RecordingLibraryEntry]) -> [RecordingLibraryEntry] {
        entries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.projectURL.path < $1.projectURL.path
        }
    }
}
