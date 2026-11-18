import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI

private actor ConnectionCheckRecorder {
    var probes = 0
    var requests: [Data] = []
    var calls = 0
    func discover() -> [DirectorConnection] {
        probes += 1
        return [.init(id: "native-claude", kind: .claude, title: "Claude", detail: "Connected on this Mac", executable: "/fake/claude")]
    }
    func probeCount() -> Int { probes }
    func tool() { calls += 1 }
    func callCount() -> Int { calls }
    func response(_ payload: Data, failAfterTool: Bool = false, invalidAfterTool: Bool = false) throws -> Data {
        requests.append(payload)
        if failAfterTool && requests.count == 2 { throw URLError(.networkConnectionLost) }
        if invalidAfterTool && requests.count == 2 { return Data("{}".utf8) }
        let output: [[String: Any]] = requests.count == 1
            ? [["type": "function_call", "call_id": "call-1", "namespace": "framethrower", "name": "control_document", "arguments": "{\"document_id\":\"document\",\"operation\":\"rename\",\"name\":\"Updated\"}"]]
            : [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Done."]]]]
        return try JSONSerialization.data(withJSONObject: ["status": "completed", "output": output])
    }
    func payloads() -> [Data] { requests }
}

private actor ConnectionCatalogGate {
    private var pending: [String: CheckedContinuation<[DirectorRemoteModel], Never>] = [:]
    func models(_ id: String) async -> [DirectorRemoteModel] {
        await withCheckedContinuation { pending[id] = $0 }
    }
    func isWaiting(_ id: String) -> Bool { pending[id] != nil }
    func complete(_ id: String) { pending.removeValue(forKey: id)?.resume(returning: [.init(id: "model", title: "Model")]) }
}

@main @MainActor
struct DirectorConnectionChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure.failed(message) }
    }
    static func main() async throws {
        try await lazyConnections()
        try await closeReopenRace()
        try callbackAndPKCE()
        try await callbackLifecycle()
        try identityVerification()
        try responseEvents()
        try await remoteToolsAndResume()
        try await remoteToolsAndResume(malformed: true)
        try await scopeRejection()
        try await probeProcesses()
        try await setupPaneLayout()
        print("Director connection checks passed: cold/lazy discovery, explicit selection, remembered connection, draft retention, callback/PKCE/JWT validation, terminal SSE failures, scoped tools, durable resume after partial failure, bounded process probes; no browser, provider, model, keychain, or capture activity.")
    }

    static func lazyConnections() async throws {
        let preferences = UserDefaults(suiteName: "director-check-" + UUID().uuidString)!
        let recorder = ConnectionCheckRecorder()
        let accounts = DirectorChatGPTAccounts(load: { [] }, save: { _ in })
        let connections = DirectorConnections(preferences: preferences, accounts: accounts, discover: { await recorder.discover() })
        let session = EditorAssistantSession(transport: { _ in throw Failure.failed("Setup must not submit an instruction") }, connections: connections)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = ProjectEditor(project: .init(screenFilename: "missing.mov", duration: 5), url: root.appendingPathComponent("test.framethrower"))
        session.attach(to: editor)
        session.instruction = "Zoom into this area."
        try await Task.sleep(for: .milliseconds(20))
        let cold = await recorder.probeCount()
        try require(cold == 0 && !connections.isChecking && !connections.isOpen, "Creating/opening an ordinary editor must not discover or authenticate an LLM")
        session.submit(editor: editor, playhead: 0, regionID: nil, editID: nil)
        try require(session.instruction == "Zoom into this area." && !session.isBusy, "Unconnected send preserves the pending instruction")
        await session.openDirector()
        let opened = await recorder.probeCount()
        try require(opened == 1 && connections.available.count == 1 && connections.selected == nil,
            "Opening Director discovers once without choosing or using a provider")
        await session.openDirector()
        let repeated = await recorder.probeCount()
        try require(repeated == 1, "Redrawing an open pane must not repeat discovery")
        await connections.choose(connections.available[0])
        session.synchronizeConnectionProvider()
        try require(connections.selected?.id == "native-claude" && !connections.showsChooser && session.modelProvider == .claudeSonnet,
            "Choosing a ready connection exposes its supported models")
        try require(session.instruction == "Zoom into this area." && !session.isBusy, "Connecting must never submit or erase a draft")
        session.suspend()
        let returning = DirectorConnections(preferences: preferences, accounts: accounts, discover: { await recorder.discover() })
        try require(returning.selected == nil && !returning.isOpen, "Remembering a provider must not cause eager restoration")
        await returning.open()
        try require(returning.selected?.id == "native-claude" && !returning.showsChooser, "Reopening Director restores a verified saved choice")
        returning.close()
        let noConnections = DirectorConnections(preferences: preferences, accounts: accounts, discover: { [] })
        await noConnections.open()
        try require(noConnections.selected == nil && noConnections.available.isEmpty && noConnections.showsChooser,
            "A missing remembered installation opens connection setup without falling back to another provider")
        noConnections.close()
    }

    static func callbackAndPKCE() throws {
        let url = DirectorChatGPTAccounts.authorizationURL(redirect: URL(string: "http://127.0.0.1:45678/auth/callback")!,
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "state", nonce: "nonce", host: "urn:uuid:test")
        let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        try require(fields["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "OAuth must implement the RFC PKCE S256 vector")
        try require(fields["client_id"] == "dynamic_agent_client" && fields["scope"]!.contains("chatgpt.tokens.use.direct") && fields["nonce"] == "nonce",
            "Browser login must request inference permission, bind identity, and register Framethrower independently")
        let good = "GET /auth/callback?state=state&code=code&client_id=issued HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        try require(DirectorOAuthCallback.parse(good, state: "state")?["client_id"] == "issued", "Valid callback carries the issued client ID")
        for request in [good.replacingOccurrences(of: "state=state", with: "state=wrong"), good.replacingOccurrences(of: "/auth/callback", with: "/other"),
            good.replacingOccurrences(of: "code=code", with: "state=state&code=code"), good.replacingOccurrences(of: "GET", with: "POST")] {
            try require(DirectorOAuthCallback.parse(request, state: "state") == nil, "Reject wrong state/path, duplicate parameters, and non-GET callbacks")
        }
        let models = try DirectorChatGPTAccounts.decodeModels(Data("{\"models\":[{\"visibility\":\"list\",\"slug\":\"account-model\",\"display_name\":\"Available model\"},{\"visibility\":\"hidden\",\"slug\":\"hidden\",\"display_name\":\"Hidden\"}]}".utf8))
        try require(models == [.init(id: "account-model", title: "Available model")], "Remote models must come from the selected account's catalog")
    }

    static func closeReopenRace() async throws {
        let preferences = UserDefaults(suiteName: "director-cancel-" + UUID().uuidString)!
        let accounts = DirectorChatGPTAccounts(load: { [] }, save: { _ in })
        let gate = ConnectionCatalogGate()
        let first = DirectorConnection(id: "first", kind: .chatGPT, title: "ChatGPT", detail: "First account", accountID: "first")
        let second = DirectorConnection(id: "second", kind: .chatGPT, title: "ChatGPT", detail: "Second account", accountID: "second")
        let connections = DirectorConnections(preferences: preferences, accounts: accounts, discover: { [first, second] }, fetchModels: { await gate.models($0) })
        await connections.open()
        connections.select(first)
        while !(await gate.isWaiting("first")) { await Task.yield() }
        connections.close()
        await connections.open()
        connections.select(second)
        while !(await gate.isWaiting("second")) { await Task.yield() }
        await gate.complete("first")
        for _ in 0..<5 { await Task.yield() }
        try require(connections.isConnecting && connections.selected == nil, "A cancelled connection must not reset the newer connection's busy state or select its old account")
        await gate.complete("second")
        for _ in 0..<50 where connections.isConnecting { try await Task.sleep(for: .milliseconds(5)) }
        try require(connections.selected?.id == "second" && !connections.isConnecting, "The new account wins after close/reopen and late completion of a cancelled request")
        connections.close()
    }

    static func identityVerification() throws {
        let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(key)!
        let der = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        var offset = 0
        func field() -> Data {
            offset += 1
            let first = Int(der[offset]); offset += 1
            var length = first
            if first >= 128 {
                length = 0
                for _ in 0..<(first & 127) { length = length * 256 + Int(der[offset]); offset += 1 }
            }
            let value = der.subdata(in: offset..<(offset + length)); offset += length
            return value
        }
        _ = field(); offset = der.count > 256 ? 4 : 3
        var modulus = field(); if modulus.first == 0 { modulus.removeFirst() }
        let exponent = field()
        let keys = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "test", "kty": "RSA", "n": modulus.directorBase64URL, "e": exponent.directorBase64URL]]])
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test"]).directorBase64URL
        let now = Date()
        func token(_ overrides: [String: Any] = [:]) throws -> String {
            var claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "issued", "sub": "user", "email": "test@example.invalid", "nonce": "nonce", "exp": now.timeIntervalSince1970 + 300]
            claims.merge(overrides) { _, next in next }
            let body = header + "." + (try JSONSerialization.data(withJSONObject: claims)).directorBase64URL
            let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(body.utf8) as CFData, nil)! as Data
            return body + "." + signature.directorBase64URL
        }
        let identity = try DirectorOpenAIIdentity.verify(token(), keys: keys, clientID: "issued", nonce: "nonce", now: now)
        try require(identity.subject == "user", "Verify actual RSA signatures and identity claims")
        for claims: [String: Any] in [["iss": "https://other.invalid"], ["aud": "other-client"], ["azp": "other-client"], ["nonce": "other"], ["exp": now.timeIntervalSince1970 - 1], ["nbf": now.timeIntervalSince1970 + 500]] {
            do { _ = try DirectorOpenAIIdentity.verify(token(claims), keys: keys, clientID: "issued", nonce: "nonce", now: now); throw Failure.failed("Invalid identity accepted") }
            catch is DirectorConnectionError { }
        }
        var forged = try token().split(separator: ".").map(String.init)
        forged[1] = Data("{\"sub\":\"attacker\"}".utf8).directorBase64URL
        do { _ = try DirectorOpenAIIdentity.verify(forged.joined(separator: "."), keys: keys, clientID: "issued", nonce: "nonce", now: now); throw Failure.failed("Unsigned identity accepted") }
        catch is DirectorConnectionError { }
    }

    static func callbackLifecycle() async throws {
        let callback = try DirectorOAuthCallback()
        let url = try await callback.start()
        try require(url.host == "127.0.0.1" && url.path == "/auth/callback", "Sign-in callback binds only IPv4 loopback")
        let waiting = Task { try await callback.receive(state: "fixture-state") { true } }
        try await Task.sleep(for: .milliseconds(20))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel(); callback.cancel() }
        let (_, rejected) = try await session.data(from: URL(string: url.absoluteString + "?state=wrong&code=code&client_id=issued")!)
        try require((rejected as? HTTPURLResponse)?.statusCode == 400, "Wrong-state traffic must not complete or consume sign-in")
        let (_, accepted) = try await session.data(from: URL(string: url.absoluteString + "?state=fixture-state&code=code&client_id=issued")!)
        let fields = try await waiting.value
        try require((accepted as? HTTPURLResponse)?.statusCode == 200 && fields["client_id"] == "issued", "Fragment-safe loopback listener completes only the bound transaction")
        let cancelled = try DirectorOAuthCallback()
        _ = try await cancelled.start()
        let pending = Task { try await cancelled.receive(state: "cancel") { true } }
        pending.cancel()
        do { _ = try await pending.value; throw Failure.failed("Cancelled sign-in did not stop its listener") }
        catch is CancellationError { }
    }

    static func responseEvents() throws {
        var parser = DirectorResponseEvents()
        let prefix = ": heartbeat\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"unfinished\"}\r\n\r\n"
        for byte in prefix.utf8 { try require(try parser.append(byte) == nil, "Partial output cannot authorize tools or success") }
        let completed = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n"
        var result: Data?
        for byte in completed.utf8 { if let data = try parser.append(byte) { result = data } }
        try require(result != nil, "Accept a complete terminal response")
        var failed = DirectorResponseEvents()
        do {
            for byte in (prefix + "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n\n").utf8 { _ = try failed.append(byte) }
            throw Failure.failed("Stream failure was accepted")
        } catch let error as DirectorConnectionError {
            try require(error.localizedDescription.contains("limit"), "Terminal usage failures must produce an actionable error")
        }
    }

    static func remoteToolsAndResume(malformed: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConnectionCheckRecorder()
        let runtime = DirectorRemoteAgent(root: root, respond: { payload, _ in try await recorder.response(payload, failAfterTool: !malformed, invalidAfterTool: malformed) })
        let request = try JSONSerialization.data(withJSONObject: ["text": "Rename it.", "document_id": "document", "recording_id": UUID().uuidString, "editor_events": []])
        let tools = try JSONSerialization.data(withJSONObject: EditorAutomationAPI.tools)
        func turn() async throws -> Data {
            try await runtime.turn(request: request, projectURL: root.appendingPathComponent("project"), accountID: "account", model: "model", token: "PRIVATE_TOKEN",
                instructions: "Use the editor.", tools: tools) { _, _ in
                    await recorder.tool()
                    return Data("{\"ok\":true}".utf8)
                }
        }
        do { _ = try await turn(); throw Failure.failed("Expected network failure after real tool completion") }
        catch is URLError { try require(!malformed, "Expected the malformed-response recovery path") }
        catch let failure as DirectorRemoteError {
            try require(malformed && failure.localizedDescription.contains("completed edits"), "Incomplete responses must report that earlier edits may have completed")
        }
        let before = await recorder.callCount()
        try require(before == 1, "Execute the original tool once")
        _ = try await turn()
        let after = await recorder.callCount()
        try require(after == 1, "Resuming after a failed response must not replay a completed edit")
        let payloads = await recorder.payloads()
        let resumed = try JSONSerialization.jsonObject(with: payloads.last!) as! [String: Any]
        let history = resumed["input"] as! [[String: Any]]
        try require(history.filter { $0["type"] as? String == "function_call_output" }.count == 1, "Resume retains actual paired tool results")
        try require(resumed["store"] as? Bool == false && resumed["stream"] as? Bool == true && resumed["previous_response_id"] == nil,
            "Follow ChatGPT plan transport requirements")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        for file in files where file.pathExtension == "json" {
            let bytes = try Data(contentsOf: file)
            try require(!String(decoding: bytes, as: UTF8.self).contains("PRIVATE_TOKEN"), "Never persist provider credentials in a conversation")
            try require((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600, "Remote conversation files are owner-only")
        }
    }

    static func scopeRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ConnectionCheckRecorder()
        let runtime = DirectorRemoteAgent(root: root, respond: { _, _ in
            try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [
                ["type": "function_call", "call_id": "allowed", "name": "control_document", "arguments": "{\"document_id\":\"document\",\"operation\":\"save\"}"],
                ["type": "function_call", "call_id": "forbidden", "name": "control_document", "arguments": "{\"document_id\":\"other-recording\",\"operation\":\"rename\"}"]]])
        })
        let request = try JSONSerialization.data(withJSONObject: ["text": "Save.", "document_id": "document", "recording_id": UUID().uuidString])
        do {
            _ = try await runtime.turn(request: request, projectURL: root, accountID: "account", model: "model", token: "token", instructions: "tools",
                tools: JSONSerialization.data(withJSONObject: EditorAutomationAPI.tools)) { _, _ in await recorder.tool(); return Data("{}".utf8) }
            throw Failure.failed("Out-of-scope tool accepted")
        } catch is DirectorConnectionError { }
        let count = await recorder.callCount()
        try require(count == 0, "Validate all calls before executing any action from a response containing a scope violation")
    }

    static func probeProcesses() async throws {
        try require(DirectorConnectionDiscovery.pythonPath(isExecutable: { $0 == "/usr/bin/python3" }, hasDeveloperTools: false) == nil,
            "A fresh Mac's executable Python shim must never trigger an Xcode tools installation")
        try require(DirectorConnectionDiscovery.pythonPath(isExecutable: { $0 == "/usr/bin/python3" }, hasDeveloperTools: true) == "/usr/bin/python3",
            "Existing developer-provided Python remains usable")
        try require(DirectorConnectionDiscovery.pythonPath(isExecutable: { $0 == "/opt/homebrew/bin/python3" }, hasDeveloperTools: false) == "/opt/homebrew/bin/python3",
            "Existing standalone Python does not need Xcode")
        let result = try await DirectorProbe.run("/bin/echo", arguments: ["ready"])
        try require(result.status == 0 && result.text.contains("ready"), "Probe captures output without a shell")
        do { _ = try await DirectorProbe.run("/bin/sleep", arguments: ["4"], timeout: 0.05); throw Failure.failed("Probe timeout did not fire") }
        catch is DirectorConnectionError { }
    }

    static func setupPaneLayout() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        let preferences = UserDefaults(suiteName: "director-layout-" + UUID().uuidString)!
        let accounts = DirectorChatGPTAccounts(load: { [] }, save: { _ in })
        let connections = DirectorConnections(preferences: preferences, accounts: accounts, discover: {
            [.init(id: "claude", kind: .claude, title: "Claude", detail: "Connected on this Mac"),
             .init(id: "chatgpt", kind: .codex, title: "ChatGPT", detail: "Connected through ChatGPT on this Mac"),
             .init(id: "local", kind: .localModel, title: "Qwen", detail: "Runs on this Mac")]
        })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); connections.close() }
        let editor = ProjectEditor(project: .init(screenFilename: "missing.mov", duration: 5), url: root.appendingPathComponent("project.framethrower"))
        let session = EditorAssistantSession(transport: { _ in throw Failure.failed("Layout cannot invoke a model") }, connections: connections)
        session.attach(to: editor)
        session.instruction = "Make this movement smoother."
        let host = NSHostingView(rootView: EditorAssistantPanel(editor: editor, session: session, selectedRegionID: nil,
            onSelectRegion: { _ in }, onRemoveRegion: { _ in }, onSubmit: {}))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 280, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        let composer = fields(host).first { $0.placeholderString == "What would you like to change?" }
        try require(composer != nil && host.bounds.contains(composer!.convert(composer!.bounds, to: host)),
            "A minimum-width setup pane keeps its editable instruction composer visible")
        try require(connections.available.count == 3 && connections.selected == nil && !session.isBusy,
            "Rendering Director triggers discovery without choosing a provider or submitting the draft")
        func snapshot(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["DIRECTOR_CONNECTION_SNAPSHOTS"] else { return }
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
            }
            let renderer = ImageRenderer(content: DirectorConnectionView(connections: connections, isBusy: false)
                .frame(width: 248).padding(16).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            renderer.scale = 2
            if let image = renderer.cgImage {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + "-connections.png"))
            }
        }
        try snapshot("setup")
        await connections.choose(connections.available[0])
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        try require(session.instruction == "Make this movement smoother." && !session.isBusy,
            "Choosing an existing connection keeps the instruction and never sends it")
        try snapshot("connected")
    }
}
