@preconcurrency import AVFoundation
import CryptoKit
import Foundation

private final class RecoveryProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    private var onMain: [Bool] = []
    private var task: Task<Void, any Error>?
    private var cancellationRequested = false
    let cancelAfter: Double?
    init(cancelAfter: Double? = nil) { self.cancelAfter = cancelAfter }
    func install(_ task: Task<Void, any Error>) {
        lock.lock(); self.task = task; let cancel = cancellationRequested; lock.unlock()
        if cancel { task.cancel() }
    }
    func record(_ value: Double) {
        lock.lock()
        values.append(value); onMain.append(Thread.isMainThread)
        let cancel = cancelAfter.map { value >= $0 && value < 1 } ?? false
        if cancel { cancellationRequested = true }
        let task = task
        lock.unlock()
        if cancel { task?.cancel() }
    }
    var snapshot: ([Double], [Bool]) { lock.lock(); defer { lock.unlock() }; return (values, onMain) }
}

@main
@MainActor
struct MediaRecoveryChecks {
    enum Failure: Error { case failed(String) }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-recovery-\(UUID().uuidString)")
        let sources = directory.appendingPathComponent("chosen")
        let projectFolder = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = sources.appendingPathComponent("a-different-name.mp4")
        try await EditorMovieFixtures.make(at: source, width: 160, height: 90, duration: 1, camera: false)
        let original = try Data(contentsOf: source)
        var project = RecordingProject(screenFilename: "missing-screen.mov", cameraFilename: "missing-camera.mov",
            cursorFilename: "missing-cursor.json", duration: 1)
        project.state.pipKeyframes[0].placement.visible = false
        let projectURL = projectFolder.appendingPathComponent("test.framethrower")
        let projectBytes = try JSONEncoder().encode(project)
        try projectBytes.write(to: projectURL)
        try require(MissingMediaReference.missing(project: project, directory: projectFolder).map(\.role) == [.screen, .camera, .cursor],
                    "missing media identifies each expected source role and filename")
        let destination = projectFolder.appendingPathComponent(project.screenFilename)
        let probe = RecoveryProgressProbe()
        try await CoreMediaRelinker.restore(source: source, destination: destination, minimumDuration: 1, progress: { probe.record($0) })
        try require(try Data(contentsOf: destination) == original && Data(contentsOf: source) == original,
                    "choosing a differently named original copies exact bytes into the expected adjacent filename")
        try require(try Data(contentsOf: projectURL) == projectBytes, "recovery changes no project state or undo history")
        let (progress, threads) = probe.snapshot
        try require(progress.first == 0 && progress.last == 1 && zip(progress, progress.dropFirst()).allSatisfy({ $0 <= $1 }),
                    "copy progress is monotonic and completes only after publication")
        try require(threads.first == false, "copying and its first progress callback happen off the main thread")
        try require(MissingMediaReference.missing(project: project, directory: projectFolder).map(\.role) == [.camera, .cursor],
                    "restored files leave the missing list without rewriting the project")
        let cameraDestination = projectFolder.appendingPathComponent(project.cameraFilename!)
        try FileManager.default.createDirectory(at: cameraDestination, withIntermediateDirectories: false)
        let protectedChild = cameraDestination.appendingPathComponent("keep.txt")
        try Data("keep this folder".utf8).write(to: protectedChild)
        try require(MissingMediaReference.missing(project: project, directory: projectFolder).map(\.role) == [.cursor] &&
                    MissingMediaReference.unusableMessages(project: project, directory: projectFolder).contains(where: { $0.contains(project.cameraFilename!) }),
                    "an existing directory gets an actionable error instead of a misleading Locate replacement")
        do {
            try await CoreMediaRelinker.restore(source: source, destination: cameraDestination)
            throw Failure.failed("existing directory replaced")
        } catch CoreMediaRelinker.RecoveryError.destinationExists { }
        try require(FileManager.default.fileExists(atPath: protectedChild.path), "existing unusable paths and their contents are preserved")
        try FileManager.default.removeItem(at: cameraDestination)
        try await CoreMediaRelinker.restore(source: source, destination: cameraDestination)
        do {
            try await CoreMediaRelinker.restore(source: source, destination: destination)
            throw Failure.failed("existing media replaced")
        } catch CoreMediaRelinker.RecoveryError.destinationExists { }
        do {
            try await CoreMediaRelinker.restore(source: source, destination: projectURL)
            throw Failure.failed("project replaced")
        } catch CoreMediaRelinker.RecoveryError.destinationExists { }
        try require(try Data(contentsOf: projectURL) == projectBytes && Data(contentsOf: destination) == original,
                    "existing originals and project files cannot be overwritten")

        let short = projectFolder.appendingPathComponent("too-short.mov")
        do {
            try await CoreMediaRelinker.restore(source: source, destination: short, minimumDuration: 2)
            throw Failure.failed("short screen video accepted")
        } catch CoreMediaRelinker.RecoveryError.tooShort { }
        try require(!FileManager.default.fileExists(atPath: short.path), "short replacements are rejected before copying")
        let invalid = sources.appendingPathComponent("not-video.mp4")
        try Data("not a video".utf8).write(to: invalid)
        let invalidDestination = projectFolder.appendingPathComponent("invalid.mov")
        do {
            try await CoreMediaRelinker.restore(source: invalid, destination: invalidDestination)
            throw Failure.failed("invalid video accepted")
        } catch is Failure { throw Failure.failed("invalid video accepted") }
        catch { }
        try require(!FileManager.default.fileExists(atPath: invalidDestination.path), "invalid media creates no destination")

        let cursorURL = sources.appendingPathComponent("selected-pointer.json")
        let cursor = CursorRecording(duration: 1, logicalWidth: 160, logicalHeight: 90,
            samples: [CursorSample(time: 0, x: 0.5, y: 0.5)], clicks: [])
        try cursor.write(to: cursorURL)
        let cursorBytes = try Data(contentsOf: cursorURL)
        let cursorDestination = projectFolder.appendingPathComponent(project.cursorFilename!)
        try await CoreMediaRelinker.restore(source: cursorURL, destination: cursorDestination)
        try require(try Data(contentsOf: cursorDestination) == cursorBytes && Data(contentsOf: cursorURL) == cursorBytes,
                    "pointer metadata is validated and copied without changing the selected source")
        let badCursor = projectFolder.appendingPathComponent("bad-cursor.json")
        do {
            try await CoreMediaRelinker.restore(source: invalid, destination: badCursor)
            throw Failure.failed("invalid pointer JSON accepted")
        } catch CoreMediaRelinker.RecoveryError.invalidCursor { }

        // A sparse extension makes a larger, still-valid movie without a large
        // fixture allocation. Hashes also stream in small chunks.
        let large = sources.appendingPathComponent("large-original.mp4")
        try FileManager.default.copyItem(at: source, to: large)
        let extensionHandle = try FileHandle(forWritingTo: large)
        let originalSize = try extensionHandle.seekToEnd()
        // A valid MP4 free atom is skipped by metadata readers. Arbitrary
        // trailing zeros instead make AVFoundation materialize an unknown atom.
        var paddingSize = UInt32(64 * 1_048_576 - originalSize).bigEndian
        try withUnsafeBytes(of: &paddingSize) { try extensionHandle.write(contentsOf: Data($0)) }
        try extensionHandle.write(contentsOf: Data("free".utf8))
        try extensionHandle.truncate(atOffset: 64 * 1_048_576)
        try extensionHandle.close()
        let largeHash = try hash(large)
        let largeDestination = projectFolder.appendingPathComponent("large-copy.mov")
        let beforeMemory = maximumResidentMemory()
        try await CoreMediaRelinker.restore(source: large, destination: largeDestination, minimumDuration: 1)
        let memoryGrowth = maximumResidentMemory() - beforeMemory
        try require(try hash(largeDestination) == largeHash && hash(large) == largeHash,
                    "large movies stream to an exact copy without modifying the original")
        try require(memoryGrowth < 48 * 1_048_576,
                    "a64MiB movie must not be materialized as one in-memory copy (growth \(memoryGrowth) bytes)")
        let cancelledDestination = projectFolder.appendingPathComponent("cancelled.mov")
        let cancellation = RecoveryProgressProbe(cancelAfter: 0)
        let copy = Task { try await CoreMediaRelinker.restore(source: large, destination: cancelledDestination, progress: { cancellation.record($0) }) }
        cancellation.install(copy)
        do { try await copy.value; throw Failure.failed("cancelled copy published") }
        catch is CancellationError { }
        try require(!FileManager.default.fileExists(atPath: cancelledDestination.path), "Cancel never publishes a partial movie")
        let raceDestination = projectFolder.appendingPathComponent("appeared-during-copy.mov")
        let protected = Data("another file appeared".utf8)
        do {
            try await CoreMediaRelinker.restore(source: source, destination: raceDestination) { value in
                if value == 0 { try? protected.write(to: raceDestination, options: .withoutOverwriting) }
            }
            throw Failure.failed("concurrent destination was replaced")
        } catch CoreMediaRelinker.RecoveryError.destinationExists { }
        try require(try Data(contentsOf: raceDestination) == protected, "atomic publication cannot replace a destination that appears during copying")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: projectFolder.path)
        try require(!remaining.contains(where: { $0.hasPrefix(".framethrower-relink-") }), "success, cancellation, and publication failures clean up their own staged files")
        try require(try Data(contentsOf: projectURL) == projectBytes && Data(contentsOf: source) == original,
                    "all recovery paths preserve project history and selected original bytes")
        print("Media recovery checks passed (movie/pointer validation, duration guard, byte-identical copies, no overwrite including races, off-main bounded streaming, progress, cancellation cleanup, and unchanged project/history).")
    }

    private static func hash(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while true {
            let count: Int = try autoreleasepool {
                guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { return 0 }
                digest.update(data: chunk)
                return chunk.count
            }
            if count == 0 { break }
        }
        return digest.finalize()
    }
    private static func maximumResidentMemory() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
}
