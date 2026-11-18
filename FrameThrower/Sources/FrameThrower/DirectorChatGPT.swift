import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Network
import Security

/// These are Framethrower's own OAuth registrations, never credentials copied
/// from ChatGPT, Codex, a browser, or another application's storage.
struct DirectorChatGPTAccount: Codable, Sendable {
    let clientID: String
    let subject: String
    let email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date
    var scopes: [String]
    var connection: DirectorConnection {
        .init(id: "chatgpt-" + clientID, kind: .chatGPT, title: "ChatGPT",
              detail: email + " · " + String(clientID.suffix(6)), accountID: clientID)
    }
}

actor DirectorChatGPTAccounts {
    static let shared = DirectorChatGPTAccounts()
    private let load: @Sendable () throws -> [DirectorChatGPTAccount]
    private let save: @Sendable ([DirectorChatGPTAccount]) throws -> Void
    private var refreshes: [String: Task<DirectorChatGPTAccount, any Error>] = [:]
    private let http: DirectorProviderHTTP

    init(http: DirectorProviderHTTP = .init(),
         load: @escaping @Sendable () throws -> [DirectorChatGPTAccount] = { try DirectorAccountKeychain.read() },
         save: @escaping @Sendable ([DirectorChatGPTAccount]) throws -> Void = { try DirectorAccountKeychain.write($0) }) {
        self.http = http; self.load = load; self.save = save
    }

    func connections() throws -> [DirectorConnection] { try load().map(\.connection) }

    func signIn(accountID: String? = nil) async throws -> DirectorConnection {
        let previous = try accountID.flatMap { id in try load().first { $0.clientID == id } }
        let callback = try DirectorOAuthCallback()
        defer { callback.cancel() }
        let redirect = try await callback.start()
        let verifier = Self.random(), state = Self.random(), nonce = Self.random()
        let host = await MainActor.run {
            if let existing = UserDefaults.standard.string(forKey: "director.chatgpt.host") { return existing }
            let value = "urn:uuid:" + UUID().uuidString.lowercased()
            UserDefaults.standard.set(value, forKey: "director.chatgpt.host"); return value
        }
        let url = Self.authorizationURL(redirect: redirect, verifier: verifier, state: state, nonce: nonce, host: host,
            clientID: previous?.clientID, idTokenHint: previous?.idToken)
        let reply = try await callback.receive(state: state) {
            await MainActor.run { !Task.isCancelled && NSWorkspace.shared.open(url) }
        }
        guard let clientID = reply["client_id"] ?? previous?.clientID, !clientID.isEmpty,
              previous == nil || clientID == previous?.clientID,
              let code = reply["code"], !code.isEmpty else {
            throw DirectorConnectionError.message("ChatGPT did not finish registering this connection. Try signing in again.")
        }
        let data = try await http.form(url: Self.tokenURL, fields: ["client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect.absoluteString, "grant_type": "authorization_code",
            "resource": "https://api.openai.com/v1"])
        let tokens = try JSONDecoder().decode(DirectorOAuthTokens.self, from: data)
        guard let idToken = tokens.id_token, let refresh = tokens.refresh_token,
              let scopes = tokens.scope?.split(separator: " ").map(String.init), scopes.contains("chatgpt.tokens.use.direct") else {
            throw DirectorConnectionError.message("ChatGPT plan access was not enabled. Sign in again and allow Framethrower to use your plan.")
        }
        let keys = try await http.request(url: URL(string: "https://auth.openai.com/.well-known/jwks.json")!)
        let identity = try DirectorOpenAIIdentity.verify(idToken, keys: keys, clientID: clientID, nonce: nonce)
        guard previous == nil || previous?.subject == identity.subject else {
            throw DirectorConnectionError.message("ChatGPT returned a different account. Add it as another connection instead.")
        }
        let account = DirectorChatGPTAccount(clientID: clientID, subject: identity.subject, email: identity.email,
            accessToken: tokens.access_token, refreshToken: refresh, idToken: idToken,
            expiresAt: Date().addingTimeInterval(tokens.expires_in), scopes: scopes)
        try Task.checkCancellation()
        var accounts = try load()
        if let prior = accounts.first(where: { $0.clientID == clientID }), prior.subject != account.subject {
            throw DirectorConnectionError.message("ChatGPT returned a different account for this connection. Choose another account.")
        }
        accounts.removeAll { $0.clientID == clientID }; accounts.append(account)
        try save(accounts)
        await MainActor.run { NSApplication.shared.activate() }
        return account.connection
    }

    func accessToken(accountID: String) async throws -> String {
        guard let account = try load().first(where: { $0.clientID == accountID }),
              account.scopes.contains("chatgpt.tokens.use.direct") else {
            throw DirectorConnectionError.message("Sign in to ChatGPT to reconnect Director.")
        }
        if account.expiresAt > Date().addingTimeInterval(90) { return account.accessToken }
        if let refresh = refreshes[accountID] { return try await refresh.value.accessToken }
        let http = self.http
        let refresh = Task {
            let data = try await http.form(url: Self.tokenURL, fields: ["grant_type": "refresh_token",
                "client_id": account.clientID, "refresh_token": account.refreshToken, "resource": "https://api.openai.com/v1"])
            let tokens = try JSONDecoder().decode(DirectorOAuthTokens.self, from: data)
            var renewed = account
            renewed.accessToken = tokens.access_token
            renewed.refreshToken = tokens.refresh_token ?? account.refreshToken
            renewed.idToken = tokens.id_token ?? account.idToken
            renewed.expiresAt = Date().addingTimeInterval(tokens.expires_in)
            if let scope = tokens.scope { renewed.scopes = scope.split(separator: " ").map(String.init) }
            guard renewed.scopes.contains("chatgpt.tokens.use.direct") else {
                throw DirectorConnectionError.message("ChatGPT plan access has been removed. Connect your account again.")
            }
            try self.persistRenewed(renewed)
            return renewed
        }
        refreshes[accountID] = refresh
        defer { refreshes[accountID] = nil }
        let renewed = try await refresh.value
        return renewed.accessToken
    }

    private func persistRenewed(_ account: DirectorChatGPTAccount) throws {
        var accounts = try load(); accounts.removeAll { $0.clientID == account.clientID }; accounts.append(account)
        try save(accounts)
    }

    func models(accountID: String) async throws -> [DirectorRemoteModel] {
        let token = try await accessToken(accountID: accountID)
        let data = try await http.request(url: URL(string: "https://api.openai.com/v1/models")!, token: token)
        return try Self.decodeModels(data)
    }

    static func decodeModels(_ data: Data) throws -> [DirectorRemoteModel] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = value["models"] as? [[String: Any]] else {
            throw DirectorConnectionError.message("ChatGPT returned an unreadable model list. Try connecting again.")
        }
        return models.compactMap {
            guard $0["visibility"] as? String == "list", let id = $0["slug"] as? String, !id.isEmpty,
                  let title = $0["display_name"] as? String else { return nil }
            return DirectorRemoteModel(id: id, title: title)
        }
    }

    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static func random() -> String { Data((0..<32).map { _ in UInt8.random(in: 0...255) }).directorBase64URL }
    static func authorizationURL(redirect: URL, verifier: String, state: String, nonce: String, host: String,
                                 clientID: String? = nil, idTokenHint: String? = nil) -> URL {
        var parts = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        parts.queryItems = ["client_id": "dynamic_agent_client", "agent_name_hint": "Framethrower",
            "ext_agent_host_id": host, "response_type": "code", "redirect_uri": redirect.absoluteString,
            "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
            "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce,
            "code_challenge_method": "S256", "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).directorBase64URL]
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        if let clientID {
            parts.queryItems?.removeAll { $0.name == "client_id" || $0.name == "agent_name_hint" }
            parts.queryItems?.append(URLQueryItem(name: "client_id", value: clientID))
            if let idTokenHint { parts.queryItems?.append(URLQueryItem(name: "id_token_hint", value: idTokenHint)) }
        }
        return parts.url!
    }
}

private struct DirectorOAuthTokens: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let expires_in: Double
    let scope: String?
}

enum DirectorAccountKeychain {
    static let service = "com.framethrower.director.chatgpt"
    static func read() throws -> [DirectorChatGPTAccount] {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: "accounts", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DirectorConnectionError.message("Director could not read its saved ChatGPT connection. Unlock your login keychain and try again.")
        }
        return try JSONDecoder().decode([DirectorChatGPTAccount].self, from: data)
    }
    static func write(_ accounts: [DirectorChatGPTAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "accounts"]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData] = data
            insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DirectorConnectionError.message("Director could not save the ChatGPT connection in your login keychain.") }
    }
}

/// Shared transport deliberately does not follow redirects with credentials.
final class DirectorProviderHTTP: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 240
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func request(url: URL, token: String? = nil, body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        let session = session(); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try Self.checkStatus(response.statusCode)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4 * 1024 * 1024 else { throw DirectorConnectionError.message("The provider returned too much data.") }
            data.append(byte)
        }
        return data
    }
    func form(url: URL, fields: [String: String]) async throws -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        return try await request(url: url, body: Data(body.utf8), contentType: "application/x-www-form-urlencoded")
    }
    static func checkStatus(_ status: Int) throws {
        guard (200...299).contains(status) else {
            let message: String
            switch status {
            case 400, 401: message = "The provider could not authorize this connection. Sign in again."
            case 403: message = "This account does not allow Director access. Check your plan or workspace permissions, or choose another provider."
            case 429: message = "The provider's usage limit was reached. Try later or choose another provider."
            default: message = "The provider is unavailable (HTTP \(status)). Try again later."
            }
            throw DirectorConnectionError.message(message)
        }
    }
}

enum DirectorOpenAIIdentity {
    struct Identity: Sendable { let subject: String; let email: String }
    static func verify(_ token: String, keys: Data, clientID: String, nonce: String, now: Date = Date()) throws -> Identity {
        let invalid = DirectorConnectionError.message("ChatGPT returned an identity that could not be verified. Try signing in again.")
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, let headerData = Data(directorBase64URL: String(pieces[0])),
              let payloadData = Data(directorBase64URL: String(pieces[1])), let signature = Data(directorBase64URL: String(pieces[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let set = try JSONSerialization.jsonObject(with: keys) as? [String: Any],
              let jwks = set["keys"] as? [[String: Any]], let jwk = jwks.first(where: { $0["kid"] as? String == kid }),
              jwk["kty"] as? String == "RSA", let n = jwk["n"] as? String, let e = jwk["e"] as? String,
              let modulus = Data(directorBase64URL: n), let exponent = Data(directorBase64URL: e) else { throw invalid }
        func der(_ tag: UInt8, _ bytes: Data) -> Data {
            let length: [UInt8] = bytes.count < 128 ? [UInt8(bytes.count)] : bytes.count < 256 ? [0x81, UInt8(bytes.count)] : [0x82, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]
            return Data([tag] + length) + bytes
        }
        func integer(_ bytes: Data) -> Data { der(0x02, bytes.first.map { $0 & 0x80 != 0 } == true ? Data([0]) + bytes : bytes) }
        let keyData = der(0x30, integer(modulus) + integer(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                  Data((pieces[0] + "." + pieces[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              claims["nonce"] as? String == nonce,
              let expiry = claims["exp"] as? Double, expiry > now.timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty else { throw invalid }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID), audiences.count == 1 || claims["azp"] as? String == clientID else { throw invalid }
        if let party = claims["azp"] as? String, party != clientID { throw invalid }
        if let notBefore = claims["nbf"] as? Double, notBefore > now.timeIntervalSince1970 + 30 { throw invalid }
        return Identity(subject: subject, email: claims["email"] as? String ?? "ChatGPT account")
    }
}

/// Loopback only, bounded requests, validated state/path, cancellable and timed.
final class DirectorOAuthCallback: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "framethrower.director.oauth")
    private var ready: CheckedContinuation<URL, any Error>?
    private var reply: CheckedContinuation<[String: String], any Error>?
    private var terminalError: (any Error)?
    private var state = ""
    private var timeout: DispatchWorkItem?
    private var opener: Task<Void, Never>?
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let error = self.terminalError { continuation.resume(throwing: error); return }
                    self.ready = continuation
                    self.listener.stateUpdateHandler = { [weak owner = self] status in
                        guard let self = owner else { return }
                        if case .ready = status, let port = self.listener.port, let pending = self.ready {
                            self.ready = nil
                            pending.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                        } else if case let .failed(error) = status { self.finish(error: error) }
                    }
                    self.listener.newConnectionHandler = { [weak owner = self] connection in owner?.handle(connection) }
                    self.listener.start(queue: self.queue)
                    let timer = DispatchWorkItem { [weak owner = self] in owner?.finish(error: DirectorConnectionError.message("Sign-in timed out. Try again.")) }
                    self.timeout = timer; self.queue.asyncAfter(deadline: .now() + 180, execute: timer)
                }
            }
        } onCancel: { self.cancel() }
    }
    func receive(state: String, open: @escaping @Sendable () async -> Bool) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let error = self.terminalError { continuation.resume(throwing: error); return }
                    self.state = state; self.reply = continuation
                    self.opener = Task {
                        guard !Task.isCancelled else { return }
                        if !(await open()) { self.cancel() }
                    }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { queue.async { self.finish(error: CancellationError()) } }
    private func finish(error: any Error) {
        guard terminalError == nil else { return }
        terminalError = error; timeout?.cancel(); timeout = nil; listener.cancel()
        opener?.cancel(); opener = nil
        ready?.resume(throwing: error); ready = nil; reply?.resume(throwing: error); reply = nil
    }
    static func parse(_ request: String, state: String) -> [String: String]? {
        guard let line = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              let url = URLComponents(string: "http://127.0.0.1" + parts[1]), url.path == "/auth/callback",
              url.fragment == nil else { return nil }
        let items = url.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state, !state.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        let expiry = Task {
            do { try await Task.sleep(for: .seconds(5)); connection.cancel() }
            catch { }
        }
        receive(connection, data: Data(), expiry: expiry)
    }
    private func receive(_ connection: NWConnection, data: Data, expiry: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            let buffer = data + (chunk ?? Data())
            if error == nil, !complete, buffer.count < 8192, !buffer.contains(Data("\r\n\r\n".utf8)) {
                self.receive(connection, data: buffer, expiry: expiry); return
            }
            expiry.cancel()
            let fields = Self.parse(String(decoding: buffer, as: UTF8.self), state: self.state)
            let valid = fields != nil && self.reply != nil
            let body = valid ? "Return to Framethrower to finish connecting." : "Invalid sign-in callback."
            let response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard let fields, let pending = self.reply else { return }
            self.reply = nil; self.timeout?.cancel(); self.timeout = nil; self.listener.cancel()
            self.opener?.cancel(); self.opener = nil
            if fields["error"] != nil { pending.resume(throwing: DirectorConnectionError.message("ChatGPT sign-in was cancelled or access was declined.")) }
            else { pending.resume(returning: fields) }
        }
    }
}

extension Data {
    var directorBase64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(directorBase64URL value: String) {
        var value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
