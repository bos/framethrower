import Foundation

@main
struct PointerRecoveryChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        guard MediaProcessing.isSuspended else { throw Failure.failed("Requires media suspension") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.json")
        let destination = directory.appendingPathComponent("restored.json")
        let original = CursorRecording(duration: 4, logicalWidth: 160, logicalHeight: 90,
            samples: [CursorSample(time: 0, x: 0.5, y: 0.5)], clicks: [])
        try original.write(to: source)
        let originalBytes = try Data(contentsOf: source)
        var changed = original
        changed.logicalWidth = 180
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let changedBytes = try encoder.encode(changed)
        guard changedBytes.count == originalBytes.count else { throw Failure.failed("Regression requires equal-size valid JSON") }

        // The progress callback runs after opening the input, before the first
        // chunk. Both mutations leave valid JSON of exactly the original size.
        for replacingPath in [false, true] {
            try originalBytes.write(to: source, options: .atomic)
            do {
                try await CoreMediaRelinker.restore(source: source, destination: destination, kind: .cursor) { value in
                    guard value == 0 else { return }
                    if replacingPath { try? changedBytes.write(to: source, options: .atomic) }
                    else {
                        let handle = try? FileHandle(forWritingTo: source)
                        try? handle?.write(contentsOf: changedBytes)
                        try? handle?.close()
                    }
                }
                throw Failure.failed("Published recovery after an equal-size \(replacingPath ? "path replacement" : "in-place source change")")
            } catch CoreMediaRelinker.RecoveryError.changedSource { }
            guard !FileManager.default.fileExists(atPath: destination.path), try Data(contentsOf: source) == changedBytes else {
                throw Failure.failed("Changed-source recovery must preserve the selected file and publish nothing")
            }
            try noStagedFiles(in: directory)
        }

        try originalBytes.write(to: source, options: .atomic)
        try await CoreMediaRelinker.restore(source: source, destination: destination, minimumDuration: 4, kind: .cursor)
        guard try Data(contentsOf: source) == originalBytes, try Data(contentsOf: destination) == originalBytes else {
            throw Failure.failed("Stable pointer data must recover byte for byte")
        }
        do {
            try await CoreMediaRelinker.restore(source: source, destination: destination, kind: .cursor)
            throw Failure.failed("Recovery replaced an existing original")
        } catch CoreMediaRelinker.RecoveryError.destinationExists { }
        guard try Data(contentsOf: destination) == originalBytes else { throw Failure.failed("Existing destination changed") }
        let tooShort = directory.appendingPathComponent("short.json")
        do {
            try await CoreMediaRelinker.restore(source: source, destination: tooShort, minimumDuration: 8, kind: .cursor)
            throw Failure.failed("Short pointer recording accepted")
        } catch CoreMediaRelinker.RecoveryError.tooShort { }
        guard !FileManager.default.fileExists(atPath: tooShort.path) else { throw Failure.failed("Short pointer recording was published") }
        let concurrentDestination = directory.appendingPathComponent("appeared.json")
        let protected = Data("A separate file appeared while restoring pointer data.".utf8)
        do {
            try await CoreMediaRelinker.restore(source: source, destination: concurrentDestination, kind: .cursor) { value in
                if value == 0 { try? protected.write(to: concurrentDestination, options: .withoutOverwriting) }
            }
            throw Failure.failed("Recovery replaced a destination created during copying")
        } catch CoreMediaRelinker.RecoveryError.destinationExists { }
        guard try Data(contentsOf: concurrentDestination) == protected else { throw Failure.failed("Concurrent destination changed") }
        let blocked = directory.appendingPathComponent("never-created.txt")
        do {
            try await CoreMediaRelinker.restore(source: source, destination: blocked, kind: .movie)
            throw Failure.failed("Movie recovery bypassed suspension")
        } catch is MediaProcessing.Suspended { }
        guard !FileManager.default.fileExists(atPath: blocked.path) else { throw Failure.failed("Suspended recovery created a file") }
        try noStagedFiles(in: directory)
        print("Pointer recovery checks passed (equal-size source edits and path replacements rejected, staging cleanup, exact stable copies, no overwrite, duration guard, media interlock preserved).")
    }

    private static func noStagedFiles(in directory: URL) throws {
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy({ !$0.hasPrefix(".framethrower-relink-") }) else {
            throw Failure.failed("Recovery left a staged copy behind")
        }
    }
}
