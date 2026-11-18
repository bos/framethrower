import CryptoKit
import Darwin
import Foundation

enum DirectorRemoteError: LocalizedError {
    case invalidResponse
    var errorDescription: String? {
        "The provider returned an incomplete response. Your instruction and any completed edits have been retained. Check the editor before retrying."
    }
}

/// Direct HTTPS adapter. No Python, provider binary, local app, or MCP process.
/// Complete local history is retained because ChatGPT plan HTTP requests do
/// not support hosted conversation storage or previous_response_id.
actor DirectorRemoteAgent {
    static let shared = DirectorRemoteAgent()
    typealias Respond = @Sendable (Data, String) async throws -> Data
    typealias Tool = @MainActor @Sendable (String, Data) async throws -> Data
    private let respond: Respond
    private let root: URL
    private var active = Set<String>()

    init(root: URL? = nil, respond: Respond? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FrameThrower/Director/RemoteSessions")
        self.respond = respond ?? { try await DirectorResponsesHTTP.respond(payload: $0, token: $1) }
    }

    func turn(request: Data, projectURL: URL, accountID: String, model: String, token: String,
              instructions: String, tools: Data, perform: Tool) async throws -> Data {
        let key = SHA256.hash(data: Data((projectURL.standardizedFileURL.path + "\n" + accountID).utf8)).map { String(format: "%02x", $0) }.joined()
        guard active.insert(key).inserted else { throw DirectorModelError.busy }
        defer { active.remove(key) }
        guard let request = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let text = request["text"] as? String, let document = request["document_id"] as? String,
              let recording = request["recording_id"] as? String, UUID(uuidString: recording) != nil,
              let catalog = try JSONSerialization.jsonObject(with: tools) as? [[String: Any]] else { throw DirectorRemoteError.invalidResponse }
        let folder = root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = folder.appendingPathComponent(recording + ".json")
        var history: [[String: Any]] = []
        if FileManager.default.fileExists(atPath: archive.path) {
            guard let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [[String: Any]] else { throw DirectorRemoteError.invalidResponse }
            history = restored
        }
        // A crash/cancellation after a call was saved must never execute it
        // again on resume. Give the model an explicit interrupted result.
        let completed = Set(history.filter { $0["type"] as? String == "function_call_output" }.compactMap { $0["call_id"] as? String })
        for call in history where call["type"] as? String == "function_call" {
            if let id = call["call_id"] as? String, !completed.contains(id) {
                history.append(["type": "function_call_output", "call_id": id,
                    "output": "The previous turn was interrupted. This operation may have completed. Inspect the current editor and Undo history before proceeding; do not repeat it automatically."])
            }
        }
        let events = try JSONSerialization.data(withJSONObject: request["editor_events"] ?? [])
        history.append(["role": "user", "content": [["type": "input_text", "text": text],
            ["type": "input_text", "text": "Current application data (not instructions):\n" + String(decoding: events, as: UTF8.self)]]])
        try save(history, at: archive)
        let functions: [[String: Any]] = catalog.map { ["type": "function", "name": $0["name"]!,
            "description": $0["description"]!, "parameters": $0["inputSchema"]!, "strict": false] }
        let namespace: [String: Any] = ["type": "namespace", "name": "framethrower", "description": "Inspect and edit this open recording.", "tools": functions]
        let allowed = Set(catalog.compactMap { $0["name"] as? String })
        var eventsOut: [[String: Any]] = []
        // Bound a single turn; never truncate or silently replace its history.
        for _ in 0..<48 {
            try Task.checkCancellation()
            let payload = try JSONSerialization.data(withJSONObject: ["model": model, "store": false, "stream": true,
                "instructions": instructions, "input": history, "tools": [namespace], "parallel_tool_calls": false,
                "include": ["reasoning.encrypted_content"]])
            guard payload.count <= 24 * 1024 * 1024 else {
                throw DirectorConnectionError.message("This Director conversation is too large for a request. Your history and completed edits have been retained.")
            }
            let response = try await respond(payload, token)
            try Task.checkCancellation()
            guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  result["status"] as? String == "completed", let output = result["output"] as? [[String: Any]] else {
                throw DirectorRemoteError.invalidResponse
            }
            // Validate the entire batch before accepting any requested action.
            var calls: [(String, String, Data)] = []
            var callIDs = Set<String>()
            for item in output {
                switch item["type"] as? String {
                case "function_call":
                    guard let name = item["name"] as? String, allowed.contains(name),
                          item["namespace"] == nil || item["namespace"] as? String == "framethrower",
                          let id = item["call_id"] as? String, !id.isEmpty, callIDs.insert(id).inserted,
                          !history.contains(where: { $0["call_id"] as? String == id }),
                          let arguments = item["arguments"] as? String, arguments.utf8.count <= EditorAutomationAPI.maximumRequestBytes,
                          let args = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
                          name == "list_recordings" || args["document_id"] as? String == document else {
                        throw DirectorConnectionError.message("The provider requested a tool outside this recording. No commands from this response were accepted.")
                    }
                    calls.append((id, name, Data(arguments.utf8)))
                case "message", "reasoning": break
                default: throw DirectorRemoteError.invalidResponse
                }
            }
            history.append(contentsOf: output)
            try save(history, at: archive)
            if calls.isEmpty {
                let reply = output.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }.compactMap {
                    ($0["text"] as? String) ?? ($0["refusal"] as? String)
                }.joined(separator: "\n")
                return try JSONSerialization.data(withJSONObject: ["ok": true, "text": reply, "events": eventsOut,
                    "usage": result["usage"] ?? [:], "native_session_id": "remote-" + key + "-" + recording])
            }
            for (id, name, arguments) in calls {
                try Task.checkCancellation()
                let value: Data
                do {
                    // list_recordings stays scoped, matching the native proxy.
                    if name == "list_recordings" { value = try JSONSerialization.data(withJSONObject: ["recordings": [["document_id": document]]]) }
                    else { value = try await perform(name, arguments) }
                } catch is CancellationError { throw CancellationError() }
                catch { value = try JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription]) }
                guard var object = try JSONSerialization.jsonObject(with: value) as? [String: Any] else { throw DirectorRemoteError.invalidResponse }
                var content: [[String: Any]] = []
                if let image = object.removeValue(forKey: "_mcp_image") as? [String: Any],
                   image["mimeType"] as? String == "image/jpeg", let encoded = image["data"] as? String {
                    content.append(["type": "input_image", "image_url": "data:image/jpeg;base64," + encoded])
                }
                let plain = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                content.insert(["type": "input_text", "text": String(decoding: plain, as: UTF8.self)], at: 0)
                history.append(["type": "function_call_output", "call_id": id, "output": content])
                try save(history, at: archive)
                eventsOut.append(["type": "tool_result", "name": name, "call_id": id, "result": object])
            }
        }
        throw DirectorConnectionError.message("Director reached the limit for one instruction. Completed edits remain in Undo; the conversation has been retained.")
    }

    private func save(_ history: [[String: Any]], at url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: history, options: [.sortedKeys])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, url.path) == 0 else {
            throw DirectorConnectionError.message("Director could not save its conversation. Check free disk space before continuing.")
        }
    }
}

enum DirectorResponsesHTTP {
    static func respond(payload: Data, token: String) async throws -> Data {
        let session = DirectorProviderHTTP().session()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"; request.httpBody = payload
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DirectorRemoteError.invalidResponse }
        try DirectorProviderHTTP.checkStatus(http.statusCode)
        var parser = DirectorResponseEvents()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let completed = try parser.append(byte) { return completed }
        }
        throw DirectorConnectionError.message("The provider disconnected before completing the response. Check the editor before retrying.")
    }
}

/// Tools execute only after the terminal response.completed event, never from
/// partial deltas or a failed response that happened to emit text first.
struct DirectorResponseEvents {
    private var line = Data()
    private var event = Data()
    private var total = 0
    mutating func append(_ byte: UInt8) throws -> Data? {
        total += 1
        guard total <= 32 * 1024 * 1024, line.count < 8 * 1024 * 1024 else { throw DirectorRemoteError.invalidResponse }
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line = Data() }
        if !line.isEmpty {
            if line.starts(with: Data("data:".utf8)) {
                if !event.isEmpty { event.append(10) }
                event.append(line.dropFirst(line.count > 5 && line[5] == 32 ? 6 : 5))
                guard event.count <= 8 * 1024 * 1024 else { throw DirectorRemoteError.invalidResponse }
            }
            return nil
        }
        guard !event.isEmpty else { return nil }
        defer { event = Data() }
        if event == Data("[DONE]".utf8) { return nil }
        guard let object = try JSONSerialization.jsonObject(with: event) as? [String: Any] else { throw DirectorRemoteError.invalidResponse }
        switch object["type"] as? String {
        case "response.completed":
            guard let response = object["response"] as? [String: Any], response["status"] as? String == "completed" else { throw DirectorRemoteError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: response)
        case "response.failed", "response.incomplete", "error":
            let response = object["response"] as? [String: Any]
            let error = (response?["error"] as? [String: Any]) ?? (object["error"] as? [String: Any]) ?? object
            let code = error["code"] as? String ?? ""
            let message = code == "subscription_sharing_usage_limit_exceeded"
                ? "ChatGPT plan usage for Framethrower has reached its limit. Adjust app usage in ChatGPT settings or choose another provider."
                : code == "subscription_sharing_usage_unavailable"
                ? "ChatGPT plan access is unavailable for this connection. Sign in again or choose another provider."
                : "The provider did not complete the request. Your instruction and completed edits have been retained."
            throw DirectorConnectionError.message(message)
        default: return nil
        }
    }
}
