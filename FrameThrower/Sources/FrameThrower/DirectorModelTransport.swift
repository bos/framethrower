import Darwin
import Foundation

enum DirectorProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case localQwen, claudeHaiku, claudeSonnet, openAIFast, openAIBalanced

    var id: String { rawValue }
    var title: String {
        switch self {
        case .localQwen: return "Qwen 3 8B (local)"
        case .claudeHaiku: return "Claude Haiku 5.5"
        case .claudeSonnet: return "Claude Sonnet 5.5"
        case .openAIFast: return "GPT-6 Luna"
        case .openAIBalanced: return "GPT-6.1 Sol"
        }
    }
    var modelID: String {
        switch self {
        case .localQwen: return "Qwen3-8B-Q4_K_M"
        case .claudeHaiku: return "claude-haiku-5-5"
        case .claudeSonnet: return "claude-sonnet-5-5"
        case .openAIFast: return "gpt-6-luna"
        case .openAIBalanced: return "gpt-6.1-sol"
        }
    }
    var cliProvider: String? {
        switch self {
        case .localQwen: return nil
        case .claudeHaiku, .claudeSonnet: return "claude"
        case .openAIFast, .openAIBalanced: return "codex"
        }
    }
    var effort: String { self == .claudeHaiku ? "low" : "medium" }
    var supportsImages: Bool { self != .localQwen }
    var help: String {
        switch self {
        case .localQwen: return "Interpret instructions on this Mac using Qwen."
        case .claudeHaiku, .claudeSonnet:
            return "Use your signed-in Claude Code account. Instructions, editing metadata, and requested frame images go to Anthropic; voice recognition stays on this Mac."
        case .openAIFast, .openAIBalanced:
            return "Use your signed-in Codex account. Instructions, editing metadata, and requested frame images go to OpenAI; voice recognition stays on this Mac."
        }
    }
    static let preferenceKey = "director.modelProvider"
    static var preferred: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .localQwen
    }
}

enum DirectorModelError: LocalizedError {
    case busy, unavailable, invalidResponse, timedOut
    case rejected(String)
    var errorDescription: String? {
        switch self {
        case .busy: return "Another Director request is still finishing. Try again in a moment."
        case .unavailable: return "The Director CLI helper requires Python 3 and the selected provider’s installed CLI."
        case .invalidResponse: return "The selected model returned an invalid response. No changes were applied."
        case .timedOut: return "The selected model took too long to respond. No changes were applied."
        case let .rejected(message): return message
        }
    }
}

/// Every provider returns the same typed planner response. Credentials remain
/// inside the installed provider CLI; this bridge never opens credential files.
enum DirectorModelTransport {
    static func chat(payload: Data, provider: DirectorProvider, helperURL: URL? = nil,
                     timeout: TimeInterval = 90) async throws -> Data {
        if provider == .localQwen { return try await LocalModelRuntime.shared.chat(payload: payload) }
        return try await DirectorCLIRuntime.shared.chat(payload: payload, provider: provider,
            helperURL: helperURL ?? Bundle.main.url(forResource: "director-cli-client", withExtension: "py"), timeout: timeout)
    }

    static func terminateOwnedProcesses() { DirectorCLIProcessRegistry.shared.terminateAll(); DirectorNativeProcesses.shared.terminateAll() }
}

private actor DirectorCLIRuntime {
    static let shared = DirectorCLIRuntime()
    private var active: UUID?

    func chat(payload: Data, provider: DirectorProvider, helperURL: URL?, timeout: TimeInterval) async throws -> Data {
        guard active == nil else { throw DirectorModelError.busy }
        guard payload.count <= 24 * 1024 * 1024, timeout.isFinite, timeout > 0, timeout <= 180,
              let family = provider.cliProvider, let helperURL,
              FileManager.default.isReadableFile(atPath: helperURL.path),
              let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw DirectorModelError.unavailable
        }
        try Task.checkCancellation()
        let id = UUID()
        active = id
        defer { active = nil }
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("framethrower-director-" + id.uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("request.json")
        let outputURL = directory.appendingPathComponent("response.json")
        let errorURL = directory.appendingPathComponent("error.json")
        guard files.createFile(atPath: inputURL.path, contents: payload, attributes: [.posixPermissions: 0o600]),
              files.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              files.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DirectorModelError.unavailable
        }
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? input.close(); try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [helperURL.path, "--provider", family, "--model", provider.modelID,
            "--effort", provider.effort, "--timeout", String(timeout)]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/usr/bin", "/bin"].joined(separator: ":")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let exit = DirectorCLIExit()
        process.terminationHandler = { child in exit.set(child.terminationStatus) }
        do { try process.run() } catch { throw DirectorModelError.unavailable }
        DirectorCLIProcessRegistry.shared.insert(process, for: id)
        defer { DirectorCLIProcessRegistry.shared.remove(id) }
        do {
            return try await withTaskCancellationHandler {
                let deadline = ContinuousClock.now.advanced(by: .seconds(timeout + 5))
                while exit.status == nil {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw DirectorModelError.timedOut }
                    for url in [outputURL, errorURL] {
                        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        guard size <= 8 * 1024 * 1024 else { throw DirectorModelError.invalidResponse }
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                guard exit.status == 0 else {
                    let data = (try? Data(contentsOf: errorURL)) ?? Data()
                    if data.count <= 64 * 1024,
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = object["error"] as? [String: Any], let message = error["message"] as? String,
                       !message.isEmpty, message.count <= 800 {
                        throw DirectorModelError.rejected(message)
                    }
                    throw DirectorModelError.invalidResponse
                }
                let response = try Data(contentsOf: outputURL)
                guard response.count <= 8 * 1024 * 1024,
                      let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                      object["choices"] is [[String: Any]] else { throw DirectorModelError.invalidResponse }
                return response
            } onCancel: { DirectorCLIProcessRegistry.shared.cancel(id) }
        } catch {
            DirectorCLIProcessRegistry.shared.cancel(id)
            await waitForExit(exit, seconds: 3)
            if exit.status == nil {
                DirectorCLIProcessRegistry.shared.cancel(id, force: true)
                await waitForExit(exit, seconds: 0.5)
            }
            throw error
        }
    }

    /// Cleanup has a bounded grace period even when its parent task has already
    /// been cancelled. A cancellable sleep here would spin instead of waiting.
    private func waitForExit(_ exit: DirectorCLIExit, seconds: Double) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while exit.status == nil && ContinuousClock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(20)) {
                    continuation.resume()
                }
            }
        }
    }
}

private final class DirectorCLIExit: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var status: Int32? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ status: Int32) { lock.lock(); defer { lock.unlock() }; value = status }
}

private final class DirectorCLIProcessRegistry: @unchecked Sendable {
    static let shared = DirectorCLIProcessRegistry()
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var isTerminating = false
    func insert(_ process: Process, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if isTerminating { if process.isRunning { _ = kill(process.processIdentifier, SIGTERM) } }
        else { processes[id] = process }
    }
    func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; processes[id] = nil }
    func cancel(_ id: UUID, force: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        if let process = processes[id], process.isRunning { _ = kill(process.processIdentifier, force ? SIGKILL : SIGTERM) }
    }
    func terminateAll() {
        lock.lock(); defer { lock.unlock() }
        isTerminating = true
        for process in processes.values where process.isRunning { _ = kill(process.processIdentifier, SIGTERM) }
    }
}
