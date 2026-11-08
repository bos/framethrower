import CoreFoundation
import CryptoKit
import Darwin
import Foundation

/// JSON-only boundary. Host closures hop to MainActor themselves and must check
/// cancellation before committing changes. Neither transport nor protocol owns UI.
struct FrameThrowerMCPBackend: Sendable {
    var listTools: @Sendable () async throws -> Data
    var callTool: @Sendable (String, Data) async throws -> Data
    var listResources: @Sendable () async throws -> Data
    var readResource: @Sendable (String) async throws -> Data
}

struct FrameThrowerMCPError: Error, LocalizedError, Sendable {
    let code: Int
    let message: String
    var errorDescription: String? { message }
}

private enum MCPJSON {
    static let maximumBytes = 1_048_576
    static func data(_ value: Any) throws -> Data {
        let result = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        guard result.count <= maximumBytes else { throw FrameThrowerMCPError(code: -32603, message: "MCP result exceeds the 1 MiB limit.") }
        return result
    }
    static func object(_ data: Data) throws -> Any {
        guard data.count <= maximumBytes else { throw FrameThrowerMCPError(code: -32600, message: "MCP message exceeds the 1 MiB limit.") }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    static func identifier(_ value: Any?) -> Data? {
        guard let value else { return nil }
        if value is String { return try? data(value) }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
           n.doubleValue.rounded() == n.doubleValue { return try? data(n) }
        return nil
    }
    static func error(_ code: Int, _ message: String, id: Data? = nil, details: [String: Any]? = nil) -> Data {
        var error: [String: Any] = ["code": code, "message": String(message.prefix(1000))]
        if let details { error["data"] = details }
        return (try? data(["jsonrpc": "2.0", "id": id.flatMap { try? object($0) } ?? NSNull(), "error": error]))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Request ID exceeds response limit."}}"#.utf8)
    }
}

/// Canceled/uncooperative backend work continues to consume a global permit until
/// it actually finishes. Reconnecting cannot create unlimited abandoned tasks.
private final class MCPWorkBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func acquire() -> Bool { lock.withLock { guard count < 16 else { return false }; count += 1; return true } }
    func release() { lock.withLock { count -= 1 } }
}

/// MCP 2025-11-25 legacy handshake and 2026-07-28 stateless metadata.
/// Official wire schemas: modelcontextprotocol/modelcontextprotocol/schema/.
/// A connection-local legacy handshake plus modern stateless request handling.
/// Public to the isolated protocol runner; only Data crosses actor boundaries.
actor FrameThrowerMCPProtocol {
    private struct Work: Sendable {
        let id: Data
        let key: String
        let token: UUID
        let method: String
        let params: Data
        let modern: Bool
    }
    private struct Pending {
        let token: UUID
        let operation: Task<Void, Never>
        let timeout: Task<Void, Never>
    }
    private let backend: FrameThrowerMCPBackend
    private let budget: MCPWorkBudget
    private let timeout: Duration
    private let reply: @Sendable (Data) -> Void
    private var initialized = false
    private var initializing = false
    private var closed = false
    private var pending: [String: Pending] = [:]
    private static let legacy = "2025-11-25", modern = "2026-07-28"
    private static let identity = ["name": "FrameThrower", "version": "1.0"]
    private static let capabilities: [String: [String: Bool]] = ["tools": [:], "resources": [:]]

    init(backend: FrameThrowerMCPBackend, timeout: Duration = .seconds(30), reply: @escaping @Sendable (Data) -> Void) {
        self.backend = backend; self.budget = MCPWorkBudget(); self.timeout = timeout; self.reply = reply
    }
    fileprivate init(backend: FrameThrowerMCPBackend, budget: MCPWorkBudget, reply: @escaping @Sendable (Data) -> Void) {
        self.backend = backend; self.budget = budget; self.timeout = .seconds(30); self.reply = reply
    }
    func close() {
        closed = true
        for entry in pending.values { entry.operation.cancel(); entry.timeout.cancel() }
        pending.removeAll()
    }
    func receive(_ data: Data) {
        guard !closed else { return }
        let value: Any
        do { value = try MCPJSON.object(data) }
        catch { reply(MCPJSON.error(-32700, "Invalid JSON.")); return }
        guard let message = value as? [String: Any], message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else {
            reply(MCPJSON.error(-32600, "Expected one JSON-RPC 2.0 request or notification.")); return
        }
        let id = MCPJSON.identifier(message["id"])
        if message["id"] != nil && id == nil { reply(MCPJSON.error(-32600, "Request ID must be a string or integer.")); return }
        guard message["params"] == nil || message["params"] is [String: Any] else {
            if let id { reply(MCPJSON.error(-32602, "Parameters must be an object.", id: id)) }; return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let id else {
            if method == "notifications/initialized", initializing { initialized = true; initializing = false }
            if method == "notifications/cancelled", let target = MCPJSON.identifier(params["requestId"]) {
                let key = String(decoding: target, as: UTF8.self)
                if let entry = pending.removeValue(forKey: key) { entry.operation.cancel(); entry.timeout.cancel() }
            }
            return // Notifications, including unknown ones, never receive replies.
        }
        let key = String(decoding: id, as: UTF8.self)
        guard pending[key] == nil else { reply(MCPJSON.error(-32600, "Request ID is already in flight.", id: id)); return }
        let meta = params["_meta"] as? [String: Any]
        let version = meta?["io.modelcontextprotocol/protocolVersion"] as? String
        let modern = version != nil
        if modern {
            guard version == Self.modern else {
                reply(MCPJSON.error(-32022, "Unsupported protocol version", id: id,
                    details: ["requested": version ?? "", "supported": [Self.modern]])); return
            }
            guard meta?["io.modelcontextprotocol/clientCapabilities"] is [String: Any] else {
                reply(MCPJSON.error(-32602, "Modern requests require clientCapabilities metadata.", id: id)); return
            }
            if let info = meta?["io.modelcontextprotocol/clientInfo"],
               !Self.validIdentity(info) { reply(MCPJSON.error(-32602, "Invalid clientInfo metadata.", id: id)); return }
        } else if method == "initialize" {
            guard !initializing && !initialized, params["protocolVersion"] is String,
                  params["capabilities"] is [String: Any], Self.validIdentity(params["clientInfo"]) else {
                reply(MCPJSON.error(-32602, "Invalid or repeated initialize request.", id: id)); return
            }
            initializing = true
            send(["protocolVersion": Self.legacy, "capabilities": Self.capabilities, "serverInfo": Self.identity], id: id, modern: false)
            return
        } else if method != "ping" && !initialized {
            reply(MCPJSON.error(-32000, "Initialize first, or supply modern per-request metadata.", id: id)); return
        }
        if method == "ping" { send([:], id: id, modern: modern); return }
        if method == "server/discover", modern {
            send(["supportedVersions": [Self.modern], "capabilities": Self.capabilities,
                  "ttlMs": 0, "cacheScope": "private"], id: id, modern: true); return
        }
        guard ["tools/list", "tools/call", "resources/list", "resources/read", "resources/templates/list"].contains(method) else {
            reply(MCPJSON.error(-32601, "Method not found: \(method)", id: id)); return
        }
        guard pending.count < 4, budget.acquire() else {
            reply(MCPJSON.error(-32000, "Too many in-flight requests; retry after current work completes.", id: id)); return
        }
        let work = Work(id: id, key: key, token: UUID(), method: method, params: (try? MCPJSON.data(params)) ?? Data(), modern: modern)
        let backend = self.backend, budget = self.budget
        let operation = Task.detached(priority: .utility) { [weak self] in
            defer { budget.release() }
            let result = await Self.execute(work, backend: backend)
            await self?.finish(work, result: result)
        }
        let timeout = Task.detached(priority: .utility) { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.expire(work)
        }
        pending[key] = Pending(token: work.token, operation: operation, timeout: timeout)
    }
    private static func validIdentity(_ value: Any?) -> Bool {
        guard let fields = value as? [String: Any] else { return false }
        return fields["name"] is String && fields["version"] is String
    }
    private func finish(_ work: Work, result: Data) {
        guard !closed, let entry = pending[work.key], entry.token == work.token else { return }
        pending.removeValue(forKey: work.key); entry.timeout.cancel(); reply(result)
    }
    private func expire(_ work: Work) {
        guard let entry = pending[work.key], entry.token == work.token else { return }
        pending.removeValue(forKey: work.key); entry.operation.cancel()
        reply(MCPJSON.error(-32000, "Request timed out; completion is unknown. Inspect current state before retrying a mutation.", id: work.id))
    }
    private func send(_ result: [String: Any], id: Data, modern: Bool) {
        reply(Self.response(result, id: id, modern: modern))
    }
    private static func response(_ value: [String: Any], id: Data, modern: Bool) -> Data {
        var result = value
        if modern { result["resultType"] = "complete"; result["_meta"] = ["io.modelcontextprotocol/serverInfo": identity] }
        do { return try MCPJSON.data(["jsonrpc": "2.0", "id": MCPJSON.object(id), "result": result]) }
        catch { return MCPJSON.error(-32603, "Backend produced an invalid or oversized result.", id: id) }
    }
    private static func listing(_ data: Data, kind: String, params: [String: Any], modern: Bool) throws -> [String: Any] {
        guard let items = try MCPJSON.object(data) as? [[String: Any]], items.count <= 1024 else {
            throw FrameThrowerMCPError(code: -32603, message: "Invalid backend catalog.")
        }
        var names = Set<String>()
        for item in items {
            let identifier = item[kind == "tools" ? "name" : "uri"] as? String
            guard let identifier, !identifier.isEmpty, names.insert(identifier).inserted,
                  kind != "tools" || (item["inputSchema"] as? [String: Any])?["type"] as? String == "object",
                  kind != "resources" || item["name"] is String else {
                throw FrameThrowerMCPError(code: -32603, message: "Invalid backend catalog descriptor.")
            }
        }
        let digest = SHA256.hash(data: try MCPJSON.data(items)).map { String(format: "%02x", $0) }.joined()
        var offset = 0
        if let cursor = params["cursor"] {
            guard let string = cursor as? String, let decoded = Data(base64Encoded: string),
                  let fields = try MCPJSON.object(decoded) as? [String: Any], fields["kind"] as? String == kind,
                  fields["digest"] as? String == digest, let position = fields["offset"] as? Int,
                  position > 0, position < items.count, position % 32 == 0 else {
                throw FrameThrowerMCPError(code: -32602, message: "Invalid or obsolete pagination cursor.")
            }
            offset = position
        }
        let end = min(items.count, offset + 32)
        var result: [String: Any] = [kind: Array(items[offset..<end])]
        if end < items.count { result["nextCursor"] = try MCPJSON.data(["kind": kind, "offset": end, "digest": digest]).base64EncodedString() }
        if modern { result["ttlMs"] = 0; result["cacheScope"] = "private" }
        return result
    }
    private static func execute(_ work: Work, backend: FrameThrowerMCPBackend) async -> Data {
        do {
            try Task.checkCancellation()
            let params = try MCPJSON.object(work.params) as? [String: Any] ?? [:]
            var result: [String: Any]
            switch work.method {
            case "tools/list":
                result = try listing(await backend.listTools(), kind: "tools", params: params, modern: work.modern)
            case "resources/list":
                result = try listing(await backend.listResources(), kind: "resources", params: params, modern: work.modern)
            case "resources/templates/list":
                result = ["resourceTemplates": []]
                if work.modern { result["ttlMs"] = 0; result["cacheScope"] = "private" }
            case "tools/call":
                guard let name = params["name"] as? String, !name.isEmpty,
                      params["arguments"] == nil || params["arguments"] is [String: Any] else {
                    throw FrameThrowerMCPError(code: -32602, message: "Expected tool name and object arguments.")
                }
                let catalog = try MCPJSON.object(await backend.listTools()) as? [[String: Any]] ?? []
                guard catalog.contains(where: { $0["name"] as? String == name }) else {
                    throw FrameThrowerMCPError(code: -32602, message: "Unknown tool: \(name)")
                }
                let arguments = try MCPJSON.data(params["arguments"] ?? [:])
                do {
                    try Task.checkCancellation()
                    let data = try await backend.callTool(name, arguments)
                    guard let object = try MCPJSON.object(data) as? [String: Any] else {
                        throw FrameThrowerMCPError(code: -32603, message: "Tool backend must return a JSON object.")
                    }
                    result = ["content": [["type": "text", "text": String(decoding: try MCPJSON.data(object), as: UTF8.self)]],
                              "structuredContent": object,
                              "isError": object["ok"] as? Bool == false || object["isError"] as? Bool == true || object["status"] as? String == "error" || (object["error"] != nil && !(object["error"] is NSNull))]
                } catch {
                    result = ["content": [["type": "text", "text": String(error.localizedDescription.prefix(1000))]], "isError": true]
                }
            case "resources/read":
                guard let uri = params["uri"] as? String, !uri.isEmpty else { throw FrameThrowerMCPError(code: -32602, message: "Expected resource URI.") }
                let catalog = try MCPJSON.object(await backend.listResources()) as? [[String: Any]] ?? []
                guard catalog.contains(where: { $0["uri"] as? String == uri }) else { throw FrameThrowerMCPError(code: -32602, message: "Resource not found.") }
                let data = try await backend.readResource(uri)
                let object = try MCPJSON.object(data)
                result = ["contents": [["uri": uri, "mimeType": "application/json", "text": String(decoding: try MCPJSON.data(object), as: UTF8.self)]]]
                if work.modern { result["ttlMs"] = 0; result["cacheScope"] = "private" }
            default: throw FrameThrowerMCPError(code: -32601, message: "Method not found.")
            }
            try Task.checkCancellation()
            return response(result, id: work.id, modern: work.modern)
        } catch let error as FrameThrowerMCPError { return MCPJSON.error(error.code, error.message, id: work.id) }
        catch { return MCPJSON.error(-32603, String(error.localizedDescription.prefix(1000)), id: work.id) }
    }
}

private func mcpAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw FrameThrowerMCPError(code: -32603, message: "Control socket path is too long.") }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    return address
}
private func mcpWithAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
}
private func mcpStat(_ path: String) -> stat? { var value = stat(); return lstat(path, &value) == 0 ? value : nil }
private func mcpSame(_ a: stat, _ b: stat?) -> Bool { b.map { a.st_ino == $0.st_ino && a.st_dev == $0.st_dev } ?? false }

private final class MCPChannel: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var closed = false, writing = false
    private var output = [Data]()
    private var bytes = 0
    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var yes: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { Darwin.close(descriptor) }
    var isClosed: Bool { lock.withLock { closed } }
    func close() { lock.withLock { if !closed { closed = true; _ = shutdown(descriptor, SHUT_RDWR) }; output.removeAll(); bytes = 0 } }
    func enqueue(_ data: Data) {
        let start = lock.withLock { () -> Bool in
            guard !closed else { return false }
            guard bytes + data.count + 1 <= 2 * MCPJSON.maximumBytes else { closed = true; _ = shutdown(descriptor, SHUT_RDWR); return false }
            var line = data; line.append(10); output.append(line); bytes += line.count
            guard !writing else { return false }; writing = true; return true
        }
        if start { DispatchQueue.global(qos: .utility).async { self.writeLoop() } }
    }
    private func writeLoop() {
        while true {
            let data = lock.withLock { () -> Data? in
                guard !closed, !output.isEmpty else { writing = false; return nil }
                let data = output.removeFirst(); bytes -= data.count; return data
            }
            guard let data else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var offset = 0
            while offset < data.count, !isClosed {
                var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                guard ProcessInfo.processInfo.systemUptime < deadline, poll(&event, 1, 250) >= 0 else { close(); return }
                if event.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { close(); return }
                if event.revents & Int16(POLLOUT) == 0 { continue }
                let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
                if count > 0 { offset += count }
                else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                else { close(); return }
            }
        }
    }
}

private final class MCPListener: @unchecked Sendable {
    let descriptor: Int32
    let lockDescriptor: Int32
    let path: String
    let socketIdentity: stat
    let backend: FrameThrowerMCPBackend
    let budget = MCPWorkBudget()
    private let lock = NSLock()
    private var stopped = false
    private var channels: [UUID: MCPChannel] = [:]
    init(directory: URL, backend: FrameThrowerMCPBackend) throws {
        let directory = directory.path
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw FrameThrowerMCPError(code: -32603, message: "Cannot create private control directory.") }
        guard let dir = mcpStat(directory), (dir.st_mode & S_IFMT) == S_IFDIR, dir.st_uid == getuid(), dir.st_mode & 0o777 == 0o700 else {
            throw FrameThrowerMCPError(code: -32603, message: "Control directory must be owned by this user, mode 0700, and not a symlink.")
        }
        let lockFD = open(directory + "/server.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw FrameThrowerMCPError(code: -32603, message: "Cannot open control lock safely.") }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_mode & 0o777 == 0o600, lockInfo.st_nlink == 1, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD); throw FrameThrowerMCPError(code: -32603, message: "Another FrameThrower control server is running, or its lock is unsafe.")
        }
        let path = directory + "/control.sock"
        var ownedSocket: stat?
        var socketFD: Int32 = -1
        do {
            if let existing = mcpStat(path) {
                guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK, existing.st_mode & 0o777 == 0o600 else {
                    throw FrameThrowerMCPError(code: -32603, message: "Refusing unsafe existing control socket.")
                }
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { throw FrameThrowerMCPError(code: -32603, message: "Cannot check stale control socket.") }
                var address = try mcpAddress(path)
                _ = fcntl(probe, F_SETFL, O_NONBLOCK)
                let connected = mcpWithAddress(&address) { Darwin.connect(probe, $0, $1) }
                let failure = errno; Darwin.close(probe)
                guard connected < 0, failure == ECONNREFUSED,
                      mcpSame(existing, mcpStat(path)), unlink(path) == 0 else {
                    throw FrameThrowerMCPError(code: -32603, message: "An active or unverified control socket already exists.")
                }
            }
            socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else { throw FrameThrowerMCPError(code: -32603, message: "Cannot create control socket.") }
            _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
            var address = try mcpAddress(path)
            guard mcpWithAddress(&address, { Darwin.bind(socketFD, $0, $1) }) == 0 else { throw FrameThrowerMCPError(code: -32603, message: "Cannot bind control socket.") }
            ownedSocket = mcpStat(path)
            guard chmod(path, 0o600) == 0, listen(socketFD, 8) == 0, let identity = mcpStat(path) else { throw FrameThrowerMCPError(code: -32603, message: "Cannot secure or listen on control socket.") }
            self.descriptor = socketFD; self.lockDescriptor = lockFD; self.path = path
            self.socketIdentity = identity; self.backend = backend
        } catch {
            if socketFD >= 0 { Darwin.close(socketFD) }
            if let ownedSocket, mcpSame(ownedSocket, mcpStat(path)) { _ = unlink(path) }
            Darwin.close(lockFD); throw error
        }
    }
    func stop() {
        let current = lock.withLock { () -> [MCPChannel] in
            guard !stopped else { return [] }
            stopped = true; _ = shutdown(descriptor, SHUT_RDWR); return Array(channels.values)
        }
        current.forEach { $0.close() }
    }
    func run() {
        defer {
            Darwin.close(descriptor)
            if mcpSame(socketIdentity, mcpStat(path)) { _ = unlink(path) }
            Darwin.close(lockDescriptor)
        }
        while !lock.withLock({ stopped }) {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 250) < 0 { if errno == EINTR { continue }; break }
            if event.revents & Int16(POLLERR | POLLNVAL) != 0 { break }
            guard event.revents & Int16(POLLIN) != 0 else { continue }
            let child = accept(descriptor, nil, nil)
            if child < 0 { continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(child, &uid, &gid) == 0, uid == getuid() else { Darwin.close(child); continue }
            _ = fcntl(child, F_SETFL, O_NONBLOCK)
            let channel = MCPChannel(child), id = UUID()
            let accepted = lock.withLock { () -> Bool in guard !stopped, channels.count < 4 else { return false }; channels[id] = channel; return true }
            guard accepted else { channel.close(); continue }
            let session = FrameThrowerMCPProtocol(backend: backend, budget: budget, reply: { channel.enqueue($0) })
            DispatchQueue.global(qos: .utility).async {
                self.read(channel, session: session)
                channel.close(); Task { await session.close() }
                self.lock.withLock { _ = self.channels.removeValue(forKey: id) }
            }
        }
        stop()
    }
    private func read(_ channel: MCPChannel, session: FrameThrowerMCPProtocol) {
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 16_384)
        var lastActivity = ProcessInfo.processInfo.systemUptime, partialSince: TimeInterval?
        while !channel.isClosed {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastActivity > 600 || partialSince.map({ now - $0 > 5 }) == true { return }
            var event = pollfd(fd: channel.descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 250) < 0 { if errno == EINTR { continue }; return }
            if event.revents & Int16(POLLERR | POLLNVAL) != 0 { return }
            if event.revents & Int16(POLLIN | POLLHUP) == 0 { continue }
            let count = Darwin.recv(channel.descriptor, &chunk, chunk.count, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return }
            lastActivity = ProcessInfo.processInfo.systemUptime; buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline); partialSince = nil
                guard line.count <= MCPJSON.maximumBytes else { return }
                // Preserve arrival order (including initialize/initialized and
                // cancellation) without waiting for backend work to complete.
                let delivered = DispatchSemaphore(value: 0)
                Task { await session.receive(line); delivered.signal() }
                guard delivered.wait(timeout: .now() + 5) == .success else { return }
            }
            guard buffer.count <= MCPJSON.maximumBytes else { return }
            partialSince = buffer.isEmpty ? nil : (partialSince ?? ProcessInfo.processInfo.systemUptime)
        }
    }
}

final class FrameThrowerMCPServer: @unchecked Sendable {
    static let shared = FrameThrowerMCPServer()
    static var defaultDirectory: URL { URL(fileURLWithPath: "/tmp/framethrower-\(getuid())", isDirectory: true) }
    private let directory: URL
    private let lock = NSLock()
    private var listener: MCPListener?
    private var starting: UUID?
    init(directory: URL = FrameThrowerMCPServer.defaultDirectory) { self.directory = directory }
    var socketPath: String { directory.appendingPathComponent("control.sock").path }
    func start(backend: FrameThrowerMCPBackend) async throws {
        let ticket = UUID()
        let proceed = try lock.withLock { () throws -> Bool in
            if listener != nil { return false }
            guard starting == nil else { throw FrameThrowerMCPError(code: -32603, message: "Control server is already starting.") }
            starting = ticket; return true
        }
        guard proceed else { return }
        do {
            let directory = self.directory
            let next = try await Task.detached(priority: .utility) { try MCPListener(directory: directory, backend: backend) }.value
            let canceled = Task.isCancelled
            let accepted = lock.withLock { () -> Bool in guard starting == ticket, !canceled else { return false }; listener = next; starting = nil; return true }
            DispatchQueue.global(qos: .utility).async { next.run() }
            if !accepted { next.stop(); throw CancellationError() }
        } catch {
            lock.withLock { if starting == ticket { starting = nil } }
            throw error
        }
    }
    func stop() {
        let previous = lock.withLock { () -> MCPListener? in starting = nil; let previous = listener; listener = nil; return previous }
        if let previous { DispatchQueue.global(qos: .utility).async { previous.stop() } }
    }
}
