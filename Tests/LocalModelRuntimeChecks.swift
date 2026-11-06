import Foundation

private enum LocalRuntimeCheckError: Error { case failed(String) }

@main
struct LocalModelRuntimeChecks {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, let port = Int(arguments[1]) else { throw LocalRuntimeCheckError.failed("fixture port") }
        for address in ["https://127.0.0.1:1234", "http://example.com:1234", "http://localhost:1234",
                        "http://127.0.0.1:1234/path", "http://127.0.0.1:1234?q=1", "http://127.0.0.1:1234#x",
                        "http://user:password@127.0.0.1:1234", "http://127.0.0.1", "http://127.0.0.1:0"] {
            do {
                _ = try LocalModelEndpoint(url: URL(string: address)!, token: "fixture-token")
                throw LocalRuntimeCheckError.failed("reject endpoint " + address)
            } catch is LocalModelError { }
        }
        let endpoint = try LocalModelEndpoint(url: URL(string: "http://127.0.0.1:\(port)")!, token: "fixture-token")
        let client = LocalModelHTTPClient(endpoint: endpoint)
        let health = try await client.request(path: "/health")
        try require((try JSONSerialization.jsonObject(with: health) as? [String: Any])?["status"] as? String == "ok",
                    "loopback connection with proxies disabled")
        let payload = Data("{\"test\":true}".utf8)
        let response = try await client.request(path: "/v1/chat/completions", payload: payload)
        try require((try JSONSerialization.jsonObject(with: response) as? [String: Any])?["accepted"] as? Bool == true,
                    "native client sends authenticated local payload")
        do {
            _ = try await client.request(path: "/v1/chat/completions", payload: Data("{\"redirect\":true}".utf8))
            throw LocalRuntimeCheckError.failed("reject redirect")
        } catch LocalModelError.serverRejected(302) { }
        do {
            _ = try await client.request(path: "/other")
            throw LocalRuntimeCheckError.failed("reject paths")
        } catch LocalModelError.invalidEndpoint { }
        print("Native local-model transport checks passed (numeric loopback, authentication, proxy bypass, redirect rejection, and endpoint allowlist).")

        if arguments.contains("--model") {
            guard LocalModelRuntime.isInstalled else { throw LocalRuntimeCheckError.failed("local model installed") }
            let request = try JSONSerialization.data(withJSONObject: [
                "model": "framethrower-local", "messages": [["role": "user", "content": "Reply with OK."]],
                "max_tokens": 8, "temperature": 0, "chat_template_kwargs": ["enable_thinking": false]
            ])
            let result = try await LocalModelRuntime.shared.chat(payload: request)
            let decoded = try JSONSerialization.jsonObject(with: result) as? [String: Any]
            try require((decoded?["choices"] as? [[String: Any]])?.count == 1, "native model returned one completion")
            let task = Task { try await LocalModelRuntime.shared.chat(payload: request) }
            try await Task.sleep(for: .milliseconds(20))
            do {
                _ = try await LocalModelRuntime.shared.chat(payload: request)
                throw LocalRuntimeCheckError.failed("second model request must be busy")
            } catch LocalModelError.busy { }
            task.cancel()
            do {
                _ = try await task.value
                throw LocalRuntimeCheckError.failed("cancel model request")
            } catch is CancellationError { }
            LocalModelRuntime.terminateOwnedProcess()
            print("Native Metal model checks passed (verified local weights, actual completion, concurrent-window rejection, and cancellation).")
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw LocalRuntimeCheckError.failed(message) }
    }
}
