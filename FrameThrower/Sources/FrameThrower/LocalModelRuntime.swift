import CryptoKit
import Darwin
import Foundation

/// Native transport for the optional local text model. The OpenAI-compatible
/// wire format is a local protocol; no provider SDK or remote service is used.
struct LocalModelEndpoint: Sendable {
    let url: URL
    let token: String

    init(url: URL, token: String) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port,
              (1...65_535).contains(port), parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              !token.isEmpty, !token.contains(where: \.isNewline) else {
            throw LocalModelError.invalidEndpoint
        }
        self.url = url
        self.token = token
    }
}

enum LocalModelError: LocalizedError {
    case unavailable
    case invalidModel
    case invalidEndpoint
    case busy
    case startupFailed
    case serverRejected(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Install llama.cpp and the local Qwen model before using the local assistant."
        case .invalidModel: return "The local model does not match the verified Qwen download. Reinstall the model."
        case .invalidEndpoint: return "The local assistant must use an authenticated connection to this Mac."
        case .busy: return "The local assistant is finishing another request. Try again in a moment."
        case .startupFailed: return "The local model could not start. Check the local model installation."
        case let .serverRejected(status): return "The local model rejected the request (HTTP \(status))."
        case .invalidResponse: return "The local model returned an invalid response. Try the request again."
        }
    }
}

private final class LocalModelNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct LocalModelHTTPClient: Sendable {
    let endpoint: LocalModelEndpoint

    func request(path: String, payload: Data? = nil) async throws -> Data {
        guard path == "/health" || path == "/v1/chat/completions" else { throw LocalModelError.invalidEndpoint }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = path == "/health" ? 2 : 120
        configuration.timeoutIntervalForResource = path == "/health" ? 2 : 120
        let session = URLSession(configuration: configuration, delegate: LocalModelNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = endpoint.url.appendingPathComponent(String(path.dropFirst()))
        var request = URLRequest(url: url)
        request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = payload == nil ? "GET" : "POST"
        request.httpBody = payload
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalModelError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw LocalModelError.serverRejected(http.statusCode) }
        guard data.count <= 8 * 1024 * 1024 else { throw LocalModelError.invalidResponse }
        return data
    }
}

/// A single request owns the process and its authentication material. A second
/// window receives a busy state rather than allocating another model. Requests
/// are scoped: completion, errors, and cancellation all terminate that process.
actor LocalModelRuntime {
    static let shared = LocalModelRuntime()
    static let modelFilename = "Qwen3-8B-Q4_K_M.gguf"
    static let modelSHA256 = "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785"
    static let modelBytes = 5_027_783_488

    private var activeRequest: UUID?

    /// Call from the native application termination notification. The process
    /// registry contains only the child launched by this runtime.
    nonisolated static func terminateOwnedProcess() {
        LocalModelProcessRegistry.shared.terminate()
    }

    static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/FrameThrower/LocalModel", isDirectory: true)
    }

    static var modelURL: URL { cacheDirectory.appendingPathComponent("models/" + modelFilename) }

    static var serverURL: URL? {
        ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool {
        serverURL != nil && FileManager.default.fileExists(atPath: modelURL.path)
    }

    func chat(payload: Data) async throws -> Data {
        guard activeRequest == nil else { throw LocalModelError.busy }
        guard let serverURL = Self.serverURL, Self.isInstalled else { throw LocalModelError.unavailable }
        guard payload.count <= 512 * 1024 else { throw LocalModelError.invalidResponse }
        let requestID = UUID()
        activeRequest = requestID
        do {
            let verification = Task.detached(priority: .utility) { try Self.verifyModel(Self.modelURL) }
            try await withTaskCancellationHandler {
                try await verification.value
            } onCancel: { verification.cancel() }
            try Task.checkCancellation()
            let server = try LocalModelProcess(serverURL: serverURL, modelURL: Self.modelURL)
            do {
                try await server.waitUntilReady()
                try Task.checkCancellation()
                let response = try await server.client.request(path: "/v1/chat/completions", payload: payload)
                await server.close()
                activeRequest = nil
                return response
            } catch {
                await server.close()
                throw error
            }
        } catch {
            activeRequest = nil
            throw error
        }
    }

    private static func verifyModel(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == modelBytes else { throw LocalModelError.invalidModel }
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        var digest = SHA256()
        while let chunk = try source.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == modelSHA256 else {
            throw LocalModelError.invalidModel
        }
    }
}

private final class LocalModelProcess: @unchecked Sendable {
    let client: LocalModelHTTPClient
    private let process: Process
    private let logFile: FileHandle
    private let keyURL: URL

    init(serverURL: URL, modelURL: URL) throws {
        let runDirectory = LocalModelRuntime.cacheDirectory.appendingPathComponent("runs/app-" + UUID().uuidString,
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString + UUID().uuidString
        let keyURL = runDirectory.appendingPathComponent("server.key")
        var stagedLog: FileHandle?
        var stagedProcess: Process?
        var initialized = false
        defer {
            if !initialized {
                if let stagedProcess, stagedProcess.isRunning { _ = kill(stagedProcess.processIdentifier, SIGKILL) }
                try? stagedLog?.close()
                try? FileManager.default.removeItem(at: keyURL)
            }
        }
        try Data((token + "\n").utf8).write(to: keyURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        let logURL = runDirectory.appendingPathComponent("server.log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw LocalModelError.startupFailed
        }
        let logFile = try FileHandle(forWritingTo: logURL)
        stagedLog = logFile
        let port = try Self.unusedPort()
        let client = LocalModelHTTPClient(endpoint: try LocalModelEndpoint(url: URL(string: "http://127.0.0.1:\(port)")!,
                                                                         token: token))
        let process = Process()
        stagedProcess = process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "10", serverURL.path,
            "--model", modelURL.path, "--alias", "framethrower-local",
            "--host", "127.0.0.1", "--port", String(port), "--api-key-file", keyURL.path,
            "--offline", "--no-mmproj", "--fit", "off", "--threads", "4", "--threads-batch", "4", "--poll", "0",
            "--ctx-size", "8192", "--parallel", "1", "--cache-ram", "0", "--jinja",
            "--chat-template-kwargs", "{\"enable_thinking\":false}", "--no-webui", "--no-ui-mcp-proxy", "--no-warmup",
            "--device", "MTL0", "--n-gpu-layers", "all", "--op-offload"]
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !["LLAMA_", "GGML_", "OPENAI_", "ANTHROPIC_"].contains(where: key.hasPrefix)
        }
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logFile
        process.standardError = logFile
        do { try process.run() }
        catch { throw LocalModelError.startupFailed }
        self.keyURL = keyURL
        self.logFile = logFile
        self.client = client
        self.process = process
        LocalModelProcessRegistry.shared.register(process, keyURL: keyURL)
        initialized = true
    }

    func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else { throw LocalModelError.startupFailed }
            do {
                let response = try await client.request(path: "/health")
                if let value = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                   value["status"] as? String == "ok" { return }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Loading commonly returns HTTP 503 or connection refused. */ }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw LocalModelError.startupFailed
    }

    func close() async {
        // Cleanup runs independently of request cancellation. It cannot be
        // interrupted before terminating the process and deleting its token.
        await Task.detached(priority: .utility) { [self] in
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            LocalModelProcessRegistry.shared.remove(process)
            try? logFile.close()
            try? FileManager.default.removeItem(at: keyURL)
        }.value
    }

    private static func unusedPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LocalModelError.startupFailed }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw LocalModelError.startupFailed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard found == 0 else { throw LocalModelError.startupFailed }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// Synchronous ownership bridge for AppKit's final termination notification;
/// waiting for an actor task there can leave an orphaned model process.
private final class LocalModelProcessRegistry: @unchecked Sendable {
    static let shared = LocalModelProcessRegistry()
    private let lock = NSLock()
    private var owned: (process: Process, keyURL: URL)?
    private var terminated = false

    func register(_ process: Process, keyURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        if terminated {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            try? FileManager.default.removeItem(at: keyURL)
        } else { owned = (process, keyURL) }
    }

    func remove(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if owned?.process === process { owned = nil }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        terminated = true
        guard let owned else { return }
        if owned.process.isRunning { _ = kill(owned.process.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: owned.keyURL)
        self.owned = nil
    }
}
