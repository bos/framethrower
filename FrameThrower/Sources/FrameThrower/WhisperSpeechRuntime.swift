import CryptoKit
import Darwin
import Foundation

struct LocalSpeechModel: Sendable {
    let filename: String
    let bytes: Int64
    let sha256: String
    static let turbo = Self(filename: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
    static var cache: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/FrameThrower")
    }
}

enum WhisperSpeechError: LocalizedError {
    case modelUnavailable, invalidModel, runtimeUnavailable, runtimeFailed(String), invalidResponse, tooLong, busy
    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "The verified local speech model is not installed."
        case .invalidModel: "The local speech model failed its integrity check. Reinstall the verified model."
        case .runtimeUnavailable: "The bundled Metal speech runtime is unavailable on this Mac."
        case let .runtimeFailed(message): message
        case .invalidResponse: "The local speech runtime returned an invalid response."
        case .tooLong: "Dictation is limited to two minutes. Stop and start another instruction."
        case .busy: "Local speech recognition is already preparing or processing an utterance."
        }
    }
}

/// Only imports verified local weights. The app never downloads or compiles a
/// runtime, sends audio over a network, or accepts arbitrary executable paths.
actor LocalSpeechModelStore {
    static let shared = LocalSpeechModelStore()
    let directory: URL
    let importURL: URL?
    let model: LocalSpeechModel

    init(directory: URL = LocalSpeechModel.cache.appendingPathComponent("LocalSpeech/models"),
         importURL: URL? = LocalSpeechModel.cache.appendingPathComponent("ASRBenchmark/ggml-large-v3-turbo-q5_0.bin"),
         model: LocalSpeechModel = .turbo) {
        self.directory = directory; self.importURL = importURL; self.model = model
    }

    nonisolated static var hasLocalCandidate: Bool {
        let fm = FileManager.default
        return ["LocalSpeech/models", "ASRBenchmark"].contains {
            fm.fileExists(atPath: LocalSpeechModel.cache.appendingPathComponent($0).appendingPathComponent(LocalSpeechModel.turbo.filename).path)
        }
    }

    func prepare() throws -> URL {
        let destination = directory.appendingPathComponent(model.filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            do { try verify(destination); return destination }
            catch is CancellationError { throw CancellationError() }
            catch {
                // An incomplete/corrupt file is never passed to the runtime.
                // Keep it for diagnosis; only an independently verified import
                // can atomically replace this known application cache path.
                guard let importURL else { throw WhisperSpeechError.invalidModel }
                return try install(from: importURL)
            }
        }
        guard let importURL else { throw WhisperSpeechError.modelUnavailable }
        return try install(from: importURL)
    }

    func verify(_ url: URL) throws {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(model.bytes) else { throw WhisperSpeechError.invalidModel }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var digest = SHA256()
        while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation(); digest.update(data: block)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == model.sha256 else { throw WhisperSpeechError.invalidModel }
    }

    func install(from source: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: source.path) else { throw WhisperSpeechError.modelUnavailable }
        let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(model.bytes) else { throw WhisperSpeechError.invalidModel }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".\(model.filename).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw WhisperSpeechError.invalidModel }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let output = try FileHandle(forWritingTo: partial); defer { try? output.close() }
        var digest = SHA256(); var total: Int64 = 0
        while let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation(); total += Int64(block.count)
            guard total <= model.bytes else { throw WhisperSpeechError.invalidModel }
            digest.update(data: block); try output.write(contentsOf: block)
        }
        guard total == model.bytes, digest.finalize().map({ String(format: "%02x", $0) }).joined() == model.sha256 else {
            throw WhisperSpeechError.invalidModel
        }
        try output.synchronize(); try output.close(); try Task.checkCancellation()
        let destination = directory.appendingPathComponent(model.filename)
        guard rename(partial.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }
}

/// A process isolates tensor inference and provides actual cancellation: killing
/// this utterance's helper interrupts native inference as well as Swift waiting.
final class WhisperSpeechWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let termination = NSCondition()
    private var exitStatus: Int32?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var cancelled = false
    private var abortMessage: String?
    private let startupTimeout: Double
    private let inferenceTimeout: Double
    let executable: URL
    init(executable: URL, startupTimeout: Double = 30, inferenceTimeout: Double = 45) {
        self.executable = executable; self.startupTimeout = startupTimeout; self.inferenceTimeout = inferenceTimeout
    }
    deinit { cancel() }

    static var bundledExecutable: URL? {
        #if arch(arm64)
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalSpeech/FrameThrowerSpeech")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        #else
        return nil
        #endif
    }

    func prepare(model: URL) async throws {
        try await withTaskCancellationHandler {
            try await Task.detached { try self.startBlocking(model: model) }.value
        } onCancel: { self.cancel() }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard samples.count <= 120 * 16000 else { throw WhisperSpeechError.tooLong }
        return try await withTaskCancellationHandler {
            try await Task.detached { try self.transcribeBlocking(samples) }.value
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock(); cancelled = true; let previous = process; let writer = input; input = nil; lock.unlock()
        termination.lock(); termination.broadcast(); termination.unlock()
        // Stop the reader before closing the writer. A large PCM write may be
        // blocked on a full socket; terminating the child releases that write.
        if let previous, previous.isRunning {
            previous.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if previous.isRunning { kill(previous.processIdentifier, SIGKILL) }
            }
        }
        try? writer?.close()
    }

    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; let message = abortMessage; lock.unlock()
        if let message { throw WhisperSpeechError.runtimeFailed(message) }
        if value { throw CancellationError() }
    }

    private func abort(_ message: String) {
        lock.lock(); abortMessage = message; lock.unlock(); cancel()
    }
    private func startBlocking(model: URL) throws {
        let timeout = DispatchWorkItem { [weak self] in self?.abort("The local speech model took too long to prepare.") }
        DispatchQueue.global().asyncAfter(deadline: .now() + startupTimeout, execute: timeout)
        defer { timeout.cancel() }
        let next = Process(); let outgoing = Pipe()
        // A local socket pair gives the writer SO_NOSIGPIPE. A helper crash must
        // throw an I/O error, never deliver SIGPIPE to the application process.
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw WhisperSpeechError.runtimeUnavailable }
        let childInput = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        var enabled: Int32 = 1
        guard setsockopt(descriptors[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            try? childInput.close(); try? writer.close(); throw WhisperSpeechError.runtimeUnavailable
        }
        defer { try? childInput.close() }
        next.executableURL = executable; next.arguments = ["--model", model.path]
        next.standardInput = childInput; next.standardOutput = outgoing; next.standardError = FileHandle.nullDevice
        next.terminationHandler = { [weak self] child in
            guard let self else { return }
            self.termination.lock()
            self.exitStatus = child.terminationStatus
            self.termination.broadcast()
            self.termination.unlock()
        }
        lock.lock()
        guard !cancelled, process == nil else { lock.unlock(); throw CancellationError() }
        process = next; input = writer; output = outgoing.fileHandleForReading
        do { try next.run(); lock.unlock() }
        catch { lock.unlock(); throw WhisperSpeechError.runtimeUnavailable }
        do {
            let response = try readResponse()
            guard response.ready == true, response.protocolVersion == 1, response.backend == "metal" else { throw WhisperSpeechError.invalidResponse }
        } catch { cancel(); throw error }
    }

    private func transcribeBlocking(_ samples: [Float]) throws -> String {
        try checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(inferenceTimeout))
        let timeout = DispatchWorkItem { [weak self] in self?.abort("The local speech model took too long to finish dictation.") }
        DispatchQueue.global().asyncAfter(deadline: .now() + inferenceTimeout, execute: timeout)
        defer { timeout.cancel() }
        lock.lock(); let writer = input; let previous = process; lock.unlock()
        guard let writer, previous != nil else { throw WhisperSpeechError.runtimeUnavailable }
        do {
            var count = UInt32(samples.count).littleEndian
            try withUnsafeBytes(of: &count) { try writer.write(contentsOf: Data($0)) }
            try samples.withUnsafeBytes { try writer.write(contentsOf: Data($0)) }
            try writer.close()
            lock.lock(); input = nil; lock.unlock()
            let result = try readResponse()
            let status = try waitForCompletion(through: deadline)
            try checkCancellation()
            guard status == 0, let text = result.text else { throw WhisperSpeechError.invalidResponse }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let original = error
            do { try checkCancellation() } catch { cancel(); throw error }
            cancel(); throw original
        }
    }

    /// A JSON result is not the end of the operation: the helper must also
    /// exit successfully. Foundation's waitUntilExit can spin its run loop even
    /// after the OS child is gone. This condition wait never enters that API,
    /// wakes on cancellation, and shares the whole inference deadline.
    private func waitForCompletion(through deadline: ContinuousClock.Instant) throws -> Int32 {
        while true {
            try checkCancellation()
            if ContinuousClock.now >= deadline {
                abort("The local speech model took too long to finish dictation.")
                try checkCancellation()
            }
            termination.lock()
            if let exitStatus { termination.unlock(); return exitStatus }
            _ = termination.wait(until: Date(timeIntervalSinceNow: 0.02))
            termination.unlock()
        }
    }

    private struct Response: Decodable {
        var ready: Bool?; var protocolVersion: Int?; var backend: String?; var text: String?; var error: String?
        enum CodingKeys: String, CodingKey { case ready, protocolVersion = "protocol", backend, text, error }
    }
    private func readResponse() throws -> Response {
        lock.lock(); let reader = output; lock.unlock()
        guard let reader else { throw WhisperSpeechError.runtimeUnavailable }
        var data = Data()
        while data.count < 65_536 {
            guard let byte = try reader.read(upToCount: 1), !byte.isEmpty else {
                try checkCancellation(); throw WhisperSpeechError.runtimeFailed("The local speech runtime stopped before returning a result.")
            }
            if byte[0] == 10 { break }; data.append(byte)
        }
        try checkCancellation()
        guard data.count < 65_536, let response = try? JSONDecoder().decode(Response.self, from: data) else { throw WhisperSpeechError.invalidResponse }
        if let message = response.error { throw WhisperSpeechError.runtimeFailed(message) }
        return response
    }
}
