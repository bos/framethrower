import Foundation

@main
@MainActor
struct ProjectSaveConflictChecks {
    enum Failure: Error { case failed(String) }
    enum Operation: CaseIterable { case save, rename, commit, undo, redo, saveDraft }

    static func main() throws {
        try changedBaselines()
        try missingAndReplacedBaselines()
        try firstSave()
        try unchangedSaves()
        print("Project save conflict checks passed (same-size external edits block Save/Rename/commit/Undo/Redo/draft save, original disk and pending history preserved, missing/replaced baselines rejected, first-save collisions protected, restored baselines retry, unchanged saves succeed; metadata only).")
    }

    private static func changedBaselines() throws {
        for operation in Operation.allCases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let editor = fixture.editor
            if operation == .saveDraft {
                var draft = editor.project.state
                draft.zoomKeyframes = [ZoomKeyframe(time: 3, scale: 2)]
                try require(editor.updateDraft(draft, at: 3) && editor.flushRecovery(), "preserve pending draft before outside edit")
            }
            let baseline = editor.project
            let saved = try Data(contentsOf: editor.url)
            let pending = editor.draftState
            let pendingTime = editor.draftTime
            let references = editor.references
            var outside = baseline
            outside.state.trimStart = 2
            let external = try encode(outside)
            try require(external.count == saved.count && external != saved, "regression must exercise the digest beyond a size check")
            try external.write(to: editor.url, options: .atomic)
            try require(!perform(operation, editor: editor), "outside changes must block \(operation)")
            try require(try Data(contentsOf: editor.url) == external, "\(operation) overwrote the outside project")
            try require(editor.project == baseline && editor.draftState == pending && editor.draftTime == pendingTime && editor.references == references,
                        "\(operation) consumed local state, history or unfinished work")
            try require(editor.errorMessage?.contains("Restore") == true && editor.errorMessage?.contains(editor.url.path) == true,
                        "conflict must identify its file and explain how to retry")
            if operation == .saveDraft {
                let recovered = try ProjectEditor.open(url: editor.url)
                try require(recovered.project == outside && recovered.draftState == nil && recovered.errorMessage != nil &&
                            FileManager.default.fileExists(atPath: editor.recoveryURL.path),
                            "a conflicting recovery journal must remain protected beside the external project")
            }
            try saved.write(to: editor.url, options: .atomic)
            try require(perform(operation, editor: editor) && editor.errorMessage == nil, "restoring the exact saved baseline must permit \(operation) retry")
            try fixture.assertSource()
            try noStagedFiles(in: fixture.directory)
        }
    }

    private static func missingAndReplacedBaselines() throws {
        for replacement in ["missing", "directory", "symlink", "corrupt"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let editor = fixture.editor
            let baseline = editor.project
            let saved = try Data(contentsOf: editor.url)
            let protected = fixture.directory.appendingPathComponent("protected.txt")
            let protectedBytes = Data("an unrelated original".utf8)
            try protectedBytes.write(to: protected)
            try FileManager.default.removeItem(at: editor.url)
            switch replacement {
            case "directory": try FileManager.default.createDirectory(at: editor.url, withIntermediateDirectories: false)
            case "symlink": try FileManager.default.createSymbolicLink(at: editor.url, withDestinationURL: protected)
            case "corrupt": try Data(repeating: 65, count: saved.count).write(to: editor.url)
            default: break
            }
            let before = try? Data(contentsOf: editor.url)
            try require(!editor.save() && editor.project == baseline && editor.errorMessage != nil,
                        "\(replacement) baseline cannot be silently recreated or replaced")
            try require((try? Data(contentsOf: editor.url)) == before && Data(contentsOf: protected) == protectedBytes,
                        "\(replacement) baseline guard changed existing bytes")
            if replacement == "missing" {
                try require(!FileManager.default.fileExists(atPath: editor.url.path), "Save recreated a deleted project")
            } else { try FileManager.default.removeItem(at: editor.url) }
            try saved.write(to: editor.url, options: .atomic)
            try require(editor.save(), "restored \(replacement) baseline must be retryable")
            try fixture.assertSource()
        }
    }

    private static func firstSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = RecordingProject(screenFilename: "missing.txt", duration: 12)
        for existing in ["valid", "corrupt", "directory", "dangling symlink", "appeared later"] {
            let url = directory.appendingPathComponent(UUID().uuidString + ".framethrower")
            let editor = ProjectEditor(project: project, url: url)
            switch existing {
            case "valid": try encode(project).write(to: url)
            case "directory": try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            case "dangling symlink": try FileManager.default.createSymbolicLink(at: url, withDestinationURL: directory.appendingPathComponent("absent.txt"))
            default: try Data("unrelated file".utf8).write(to: url)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = try? Data(contentsOf: url)
            try require(!editor.save() && editor.project == project && editor.errorMessage?.contains("Open") == true,
                        "first save must reject an existing \(existing) destination")
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            try require((attributes[.type] as? FileAttributeType) == (after[.type] as? FileAttributeType) &&
                        (try? Data(contentsOf: url)) == bytes, "first save changed an existing \(existing) item")
            try noStagedFiles(in: directory)
        }
        let url = directory.appendingPathComponent("new.framethrower")
        let editor = ProjectEditor(project: project, url: url)
        try require(editor.save() && editor.save() && editor.project.undoHistory.isEmpty, "fresh first save and repeated unchanged saves must succeed")
        try require(try ProjectEditor.open(url: url).project == project, "first save must publish a complete decodable project")
        try noStagedFiles(in: directory)
    }

    private static func unchangedSaves() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let editor = try ProjectEditor.open(url: fixture.editor.url)
        let baseline = editor.project
        try require(editor.save() && editor.project == baseline, "unchanged open/save must preserve history")
        try require(editor.rename(to: "Local title") && editor.undo() && editor.redo() && editor.save(),
                    "successful writes must advance the expected baseline for subsequent history operations")
        try require(try ProjectEditor.open(url: editor.url).project == editor.project, "successful changes persist normally")
        let aliasDirectory = fixture.directory.appendingPathComponent("Aliases")
        try FileManager.default.createDirectory(at: aliasDirectory, withIntermediateDirectories: false)
        let alias = aliasDirectory.appendingPathComponent("project.framethrower")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: editor.url)
        let throughAlias = try ProjectEditor.open(url: alias)
        try require(throughAlias.url == editor.url && throughAlias.rename(to: "Through alias"),
                    "opening a stable project alias must save to its canonical project")
        try require(try FileManager.default.attributesOfItem(atPath: alias.path)[.type] as? FileAttributeType == .typeSymbolicLink,
                    "saving through an opened alias must preserve the alias")
        try fixture.assertSource()
    }

    private static func perform(_ operation: Operation, editor: ProjectEditor) -> Bool {
        switch operation {
        case .save, .saveDraft: return editor.save()
        case .rename: return editor.rename(to: "Local title")
        case .commit:
            var state = editor.project.state
            state.audio.isMuted = true
            return editor.commit(state, name: "Mute recording")
        case .undo: return editor.undo()
        case .redo: return editor.redo()
        }
    }

    private static func encode(_ project: RecordingProject) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    @MainActor private struct Fixture {
        let directory: URL
        let source: URL
        let editor: ProjectEditor
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            source = directory.appendingPathComponent("untouched.txt")
            try Data("immutable original text".utf8).write(to: source)
            editor = ProjectEditor(project: RecordingProject(screenFilename: source.lastPathComponent, duration: 12),
                                   url: directory.appendingPathComponent("recording.framethrower"))
            try require(editor.save(), "save fixture")
            var first = editor.project.state
            first.trimStart = 1
            try require(editor.commit(first, name: "Trim"), "prepare saved Undo entry")
            var second = first
            second.audio.volume = 0.8
            try require(editor.commit(second, name: "Volume") && editor.undo(), "prepare independent Undo and Redo branches")
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func assertSource() throws {
            try require(try Data(contentsOf: source) == Data("immutable original text".utf8), "project saving changed original bytes")
        }
    }

    private static func noStagedFiles(in directory: URL) throws {
        try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".framethrower-save-") },
                    "first-save publishing leaked its staged file")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.failed(message) }
    }
}
