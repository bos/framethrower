import CryptoKit
import Darwin
import Foundation

enum DirectorNativeError: LocalizedError {
    case unavailable, invalidResponse, timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: "The native Director agent requires its installed provider CLI and Python 3."
        case .invalidResponse: "The native agent did not return a complete response. Check the current editor state before retrying."
        case .timedOut: "The native agent timed out. Any completed edits remain in the editor's Undo stack."
        }
    }
}

/// The provider's native agent owns the conversation. This bridge submits a new
/// turn and actual editor events; it never constructs or truncates model history.
actor DirectorAgentRuntime {
    static let shared = DirectorAgentRuntime()
    private var active: Set<String> = []

    func turn(request: Data, projectURL: URL, provider: DirectorProvider,
              helperURL: URL? = nil, proxyURL: URL? = nil,
              sessionRoot: URL? = nil, timeout: TimeInterval = 240) async throws -> Data {
        guard let input = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let document = input["document_id"] as? String,
              let recording = input["recording_id"] as? String, UUID(uuidString: recording) != nil else {
            throw DirectorNativeError.invalidResponse
        }
        let keyData = Data((projectURL.standardizedFileURL.resolvingSymlinksInPath().path + "\n" + recording + "\n" + (provider.cliProvider ?? "qwen")).utf8)
        let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
        guard !active.contains(key) else { throw DirectorModelError.busy }
        guard let helper = helperURL ?? Bundle.main.url(forResource: "director-agent-client", withExtension: "py"),
              let proxy = proxyURL ?? Bundle.main.url(forResource: "framethrower-mcp", withExtension: "py"),
              let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first(where: {
                  FileManager.default.isExecutableFile(atPath: $0)
              }) else { throw DirectorNativeError.unavailable }
        try Task.checkCancellation()
        active.insert(key)
        defer { active.remove(key) }
        let root = sessionRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FrameThrower/Director/NativeSessions")
        let directory = root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var configuration: [String: Any] = ["provider": provider.cliProvider ?? "qwen", "model": provider.modelID,
            "effort": provider.effort, "cwd": directory.path, "mcp_proxy": proxy.path,
            "mcp_socket": "/tmp/framethrower-\(getuid())/control.sock", "document_id": document,
            "recording_id": recording, "timeout": timeout]
        let lease: LocalModelEndpointLease?
        if provider == .localQwen {
            configuration["effort"] = "off"
            let local = try await LocalModelRuntime.shared.acquireEndpoint()
            lease = local
            configuration["base_url"] = local.baseURL.absoluteString
            configuration["local_token"] = local.token
            configuration["model"] = local.model
            configuration["context_window_size"] = local.contextWindowSize
            let qwen = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/FrameThrower/DirectorAgents/QwenCode/0.27.0/node_modules/.bin/qwen")
            if FileManager.default.isExecutableFile(atPath: qwen.path) { configuration["cli"] = qwen.path }
        } else { lease = nil }
        do {
            let payload = try JSONSerialization.data(withJSONObject: ["request": input, "configuration": configuration])
            let result = try await run(payload, python: python, helper: helper, timeout: timeout)
            if let lease { await LocalModelRuntime.shared.releaseEndpoint(lease) }
            return result
        } catch {
            if let lease { await LocalModelRuntime.shared.releaseEndpoint(lease) }
            throw error
        }
    }

    private func run(_ payload: Data, python: String, helper: URL, timeout: TimeInterval) async throws -> Data {
        let files = FileManager.default, id = UUID()
        let directory = files.temporaryDirectory.appendingPathComponent("framethrower-native-turn-" + id.uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.json"), outputURL = directory.appendingPathComponent("output.json"), errorURL = directory.appendingPathComponent("stderr.txt")
        for (url, contents) in [(inputURL, payload), (outputURL, Data()), (errorURL, Data())] {
            guard files.createFile(atPath: url.path, contents: contents, attributes: [.posixPermissions: 0o600]) else { throw DirectorNativeError.unavailable }
        }
        let input = try FileHandle(forReadingFrom: inputURL), output = try FileHandle(forWritingTo: outputURL), errors = try FileHandle(forWritingTo: errorURL)
        defer { try? input.close(); try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [helper.path]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path, "/usr/bin", "/bin"].joined(separator: ":")
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let exit = NativeAgentExit()
        process.terminationHandler = { exit.set($0.terminationStatus) }
        try process.run()
        DirectorNativeProcesses.shared.insert(process, id: id)
        defer { DirectorNativeProcesses.shared.remove(id: id) }
        do {
            return try await withTaskCancellationHandler {
                let deadline = ContinuousClock.now.advanced(by: .seconds(timeout + 10))
                while exit.status == nil {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else { throw DirectorNativeError.timedOut }
                    for url in [outputURL, errorURL] {
                        guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 32 * 1024 * 1024 else { throw DirectorNativeError.invalidResponse }
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                let result = try Data(contentsOf: outputURL)
                guard exit.status == 0, let object = try JSONSerialization.jsonObject(with: result) as? [String: Any], object["ok"] is Bool else { throw DirectorNativeError.invalidResponse }
                return result
            } onCancel: { DirectorNativeProcesses.shared.cancel(id: id) }
        } catch {
            DirectorNativeProcesses.shared.cancel(id: id)
            for _ in 0..<20 where exit.status == nil { try? await Task.sleep(for: .milliseconds(25)) }
            if exit.status == nil { DirectorNativeProcesses.shared.cancel(id: id, force: true) }
            throw error
        }
    }
}

private final class NativeAgentExit: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var status: Int32? { lock.withLock { value } }
    func set(_ status: Int32) { lock.withLock { value = status } }
}

final class DirectorNativeProcesses: @unchecked Sendable {
    static let shared = DirectorNativeProcesses()
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    func insert(_ process: Process, id: UUID) { lock.withLock { processes[id] = process } }
    func remove(id: UUID) { _ = lock.withLock { processes.removeValue(forKey: id) } }
    func cancel(id: UUID, force: Bool = false) {
        guard let process = lock.withLock({ processes[id] }), process.isRunning else { return }
        let pid = process.processIdentifier
        let signal = force ? SIGKILL : SIGTERM
        if getpgid(pid) == pid { _ = kill(-pid, signal) } else { _ = kill(pid, signal) }
    }
    func terminateAll() { for id in lock.withLock({ Array(processes.keys) }) { cancel(id: id) } }
}
