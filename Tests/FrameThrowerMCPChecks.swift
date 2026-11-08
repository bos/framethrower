import Darwin
import Foundation

private struct CheckFailure: Error { let message: String }
private actor Replies {
    var values = [Data]()
    func append(_ value: Data) { values.append(value) }
    func count() -> Int { values.count }
    func response(_ id: Int) -> Data? {
        values.first { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["id"] as? Int == id }
    }
}
private actor BackendState {
    var calls = [String]()
    var canceled = 0
    func call(_ name: String, _ arguments: Data) async throws -> Data {
        calls.append(name)
        if name == "wait" {
            do { try await Task.sleep(for: .seconds(5)) }
            catch { canceled += 1; throw error }
        }
        if name == "fail" { throw CheckFailure(message: "Synthetic tool failure") }
        return try JSONSerialization.data(withJSONObject: ["ok": name != "domain_error", "name": name,
            "arguments": JSONSerialization.jsonObject(with: arguments)])
    }
    func count() -> Int { calls.count }
    func cancellationCount() -> Int { canceled }
}

@main
struct FrameThrowerMCPChecks {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw CheckFailure(message: message) }
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func object(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
    static var meta: [String: Any] { ["io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [:], "io.modelcontextprotocol/clientInfo": ["name": "metadata-check", "version": "1"]] }
    static func request(_ id: Int, _ method: String, _ params: [String: Any] = [:], modern: Bool = true) throws -> Data {
        var params = params; if modern { params["_meta"] = meta }
        return try json(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }
    static func wait(_ condition: @Sendable () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < end { if await condition() { return }; try await Task.sleep(for: .milliseconds(3)) }
        throw CheckFailure(message: "Bounded check timed out")
    }
    private static func backend(_ state: BackendState) -> FrameThrowerMCPBackend {
        let tools: [[String: Any]] = (["echo", "wait", "fail", "domain_error"] + (0..<61).map { "tool\($0)" }).map {
            ["name": $0, "description": "Synthetic metadata-only tool", "inputSchema": ["type": "object"]]
        }
        let toolData = try! json(tools), resources = try! json([["name": "state", "uri": "framethrower://state"]])
        return FrameThrowerMCPBackend(listTools: { toolData }, callTool: { try await state.call($0, $1) },
            listResources: { resources }, readResource: { uri in try json(["uri": uri, "value": 7]) })
    }
    private static func response(_ session: FrameThrowerMCPProtocol, _ replies: Replies, id: Int, method: String,
                         params: [String: Any] = [:], modern: Bool = true) async throws -> [String: Any] {
        await session.receive(try request(id, method, params, modern: modern))
        try await wait { await replies.response(id) != nil }
        return try object(await replies.response(id)!)
    }
    static func result(_ value: [String: Any]) throws -> [String: Any] {
        guard let result = value["result"] as? [String: Any] else { throw CheckFailure(message: "Unexpected error: \(value)") }; return result
    }
    static func code(_ value: [String: Any]) -> Int? { (value["error"] as? [String: Any])?["code"] as? Int }
    static func protocolChecks() async throws {
        let state = BackendState(), replies = Replies()
        let session = FrameThrowerMCPProtocol(backend: backend(state), reply: { data in Task { await replies.append(data) } })
        let discovery = try result(await response(session, replies, id: 1, method: "server/discover"))
        try require(discovery["resultType"] as? String == "complete" && discovery["supportedVersions"] as? [String] == ["2026-07-28"], "Modern discovery/version metadata")
        try require(discovery["ttlMs"] as? Int == 0 && discovery["cacheScope"] as? String == "private", "Modern cache fields")
        let page = try result(await response(session, replies, id: 2, method: "tools/list"))
        try require((page["tools"] as? [[String: Any]])?.count == 32, "First catalog page bounded")
        let second = try result(await response(session, replies, id: 3, method: "tools/list", params: ["cursor": page["nextCursor"]!]))
        let third = try result(await response(session, replies, id: 4, method: "tools/list", params: ["cursor": second["nextCursor"]!]))
        try require((third["tools"] as? [[String: Any]])?.count == 1 && third["nextCursor"] == nil, "Pagination discovers every fixed catalog item")
        try require(code(await response(session, replies, id: 5, method: "tools/list", params: ["cursor": "garbage"])) == -32602, "Malformed cursor rejected")
        let call = try result(await response(session, replies, id: 6, method: "tools/call", params: ["name": "echo", "arguments": ["x": 4]]))
        let content = call["content"] as! [[String: Any]], structured = call["structuredContent"] as! [String: Any]
        try require(call["isError"] as? Bool == false && structured["name"] as? String == "echo" && content[0]["type"] as? String == "text", "Tool result text plus structured domain object")
        let domainError = try result(await response(session, replies, id: 7, method: "tools/call", params: ["name": "domain_error"]))
        let thrown = try result(await response(session, replies, id: 8, method: "tools/call", params: ["name": "fail"]))
        try require(domainError["isError"] as? Bool == true && thrown["isError"] as? Bool == true, "Tool-origin errors are MCP tool results")
        try require(code(await response(session, replies, id: 9, method: "tools/call", params: ["name": "not_real"])) == -32602, "Unknown tool is protocol error")
        try require(code(await response(session, replies, id: 10, method: "tools/call", params: ["name": "echo", "arguments": []])) == -32602, "Arguments must be object")
        let resource = try result(await response(session, replies, id: 11, method: "resources/read", params: ["uri": "framethrower://state"]))
        let contents = resource["contents"] as! [[String: Any]]
        try require(contents[0]["uri"] as? String == "framethrower://state" && contents[0]["mimeType"] as? String == "application/json", "Resource wraps domain JSON at declared URI")
        try require(code(await response(session, replies, id: 12, method: "resources/read", params: ["uri": "file:///private/not-a-resource"])) == -32602, "Unknown resources never reach backend")
        var badMeta = meta; badMeta["io.modelcontextprotocol/protocolVersion"] = "1900-01-01"
        await session.receive(try json(["jsonrpc": "2.0", "id": 13, "method": "ping", "params": ["_meta": badMeta]]))
        try await wait { await replies.response(13) != nil }
        try require(code(object(await replies.response(13)!)) == -32022, "Unsupported modern version has standard error")
        try require(code(await response(session, replies, id: 14, method: "unknown")) == -32601, "Unknown method")
        let before = await replies.count()
        await session.receive(try json(["jsonrpc": "2.0", "method": "notifications/unknown"]))
        try await Task.sleep(for: .milliseconds(15))
        try require(await replies.count() == before, "Notifications do not receive responses")
        await session.close()
        // Even a near-limit ID plus a large backend error must produce valid
        // JSON-RPC, never an empty stdout line or an oversized response.
        let boundedReplies = Replies()
        var boundedBackend = backend(state)
        boundedBackend.listTools = { throw FrameThrowerMCPError(code: -32603, message: String(repeating: "x", count: 1000)) }
        let bounded = FrameThrowerMCPProtocol(backend: boundedBackend, reply: { data in Task { await boundedReplies.append(data) } })
        await bounded.receive(try json(["jsonrpc": "2.0", "id": String(repeating: "i", count: 1_048_576 - 600), "method": "tools/list", "params": ["_meta": meta]]))
        try await wait { await boundedReplies.count() == 1 }
        let boundedResponse = await boundedReplies.values[0]
        try require(boundedResponse.count < 1_048_576 && code(object(boundedResponse)) == -32600, "Oversized error envelope remains valid bounded JSON-RPC")
        await bounded.close()
    }
    static func legacyAndCancellation() async throws {
        let state = BackendState(), replies = Replies()
        let session = FrameThrowerMCPProtocol(backend: backend(state), timeout: .milliseconds(100), reply: { data in Task { await replies.append(data) } })
        try require(code(await response(session, replies, id: 20, method: "tools/list", modern: false)) == -32000, "Legacy requires initialization")
        let initialized = try result(await response(session, replies, id: 21, method: "initialize", params: ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]], modern: false))
        try require(initialized["protocolVersion"] as? String == "2025-11-25" && initialized["resultType"] == nil, "Legacy handshake has legacy shape")
        try require(code(await response(session, replies, id: 22, method: "tools/list", modern: false)) == -32000, "Wait for initialized notification")
        await session.receive(try json(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let tools = try result(await response(session, replies, id: 23, method: "tools/list", modern: false))
        try require(tools["resultType"] == nil && tools["ttlMs"] == nil, "Legacy result remains compatible")
        await session.receive(try request(24, "tools/call", ["name": "wait"]))
        try await wait { await state.count() == 1 }
        await session.receive(try json(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 24]]))
        try await wait { await state.cancellationCount() == 1 }
        try await Task.sleep(for: .milliseconds(130))
        try require(await replies.response(24) == nil, "Canceled requests never publish late/error replies")
        let timedOut = try await response(session, replies, id: 25, method: "tools/call", params: ["name": "wait"])
        try require(code(timedOut) == -32000, "Whole backend operation has bounded timeout")
        try await wait { await state.cancellationCount() == 2 }
        try require(await replies.values.filter { (try? object($0)["id"] as? Int) == 25 }.count == 1, "No late result after timeout")
        await session.receive(Data("[1]".utf8))
        await session.receive(Data("broken".utf8))
        try await wait { await replies.count() >= 7 }
        await session.close()
    }
    static func socketRequest(_ path: String, _ message: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw CheckFailure(message: "socket") }; defer { Darwin.close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CheckFailure(message: "test path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw CheckFailure(message: "connect") }
        var line = message; line.append(10)
        let sent = line.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, line.count, 0) }
        guard sent == line.count else { throw CheckFailure(message: "send") }
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 100) <= 0 { continue }
            let count = recv(fd, &chunk, chunk.count, 0); guard count > 0 else { break }
            buffer.append(contentsOf: chunk.prefix(count))
            if let newline = buffer.firstIndex(of: 10) { return Data(buffer[..<newline]) }
        }
        throw CheckFailure(message: "IPC response timed out")
    }
    static func ipc() async throws {
        let root = URL(fileURLWithPath: "/tmp/ft-mcp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private")
        let server = FrameThrowerMCPServer(directory: directory), state = BackendState()
        try await server.start(backend: backend(state))
        defer { server.stop() }
        var info = stat(); try require(lstat(server.socketPath, &info) == 0 && info.st_mode & 0o777 == 0o600, "Socket mode0600")
        try require(lstat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "Directory mode0700")
        let path = server.socketPath, request = try request(40, "tools/call", ["name": "echo", "arguments": ["value": "prefix preserved"]])
        let answer = try await Task.detached(priority: .utility) { try socketRequest(path, request) }.value
        try require((try result(object(answer)))["isError"] as? Bool == false, "Real Unix IPC reaches async backend without app/UI")
        let duplicate = FrameThrowerMCPServer(directory: directory)
        do { try await duplicate.start(backend: backend(state)); throw CheckFailure(message: "Duplicate listener accepted") }
        catch is FrameThrowerMCPError {}
        server.stop()
        try await wait { !FileManager.default.fileExists(atPath: path) }
        // Directory and socket symlinks are rejected without touching targets.
        let target = root.appendingPathComponent("sentinel"); try Data("keep".utf8).write(to: target)
        let symlink = root.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: directory)
        do { try await FrameThrowerMCPServer(directory: symlink).start(backend: backend(state)); throw CheckFailure(message: "Directory symlink accepted") }
        catch is FrameThrowerMCPError {}
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        do { try await server.start(backend: backend(state)); throw CheckFailure(message: "Socket symlink accepted") }
        catch is FrameThrowerMCPError {}
        try require(Data(contentsOf: target) == Data("keep".utf8), "Unsafe socket target untouched")
        try FileManager.default.removeItem(atPath: path)
        // A crashed server leaves an owned socket inode with no listener. Only
        // that positively refused, mode0600 inode may be reclaimed.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try require(bound == 0 && chmod(path, 0o600) == 0, "Create synthetic stale owned socket")
        Darwin.close(stale)
        try await server.start(backend: backend(state))
        let moved = directory.appendingPathComponent("old.sock")
        try FileManager.default.moveItem(atPath: path, toPath: moved.path)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: path))
        server.stop(); try await Task.sleep(for: .milliseconds(350))
        try require(Data(contentsOf: URL(fileURLWithPath: path)) == Data("replacement".utf8), "Stop never unlinks another inode")
    }
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 25) { Darwin.exit(2) }
        try await protocolChecks(); try await legacyAndCancellation(); try await ipc()
        print("MCP protocol/IPC checks passed (dual-era framing, pagination, structured errors/resources, cancellation/timeouts, private socket ownership and replacement safety; synthetic JSON only).")
    }
}
