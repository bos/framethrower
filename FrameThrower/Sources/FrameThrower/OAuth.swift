import AppKit
import CryptoKit
import Foundation
import Network

struct OAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }
}

struct OAuthServerError: Decodable, Error {
    let error: String
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

enum OAuthClientError: LocalizedError {
    case serverError(message: String)
    case badResponse(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case let .serverError(message):
            return message
        case let .badResponse(statusCode):
            return "Server responded with status \(statusCode)."
        }
    }
}

struct OAuthConfig: Codable, Hashable {
    var clientID: String
    var redirectURI: String
    var scopes: [String]
    var clientSecret: String?

    var callbackScheme: String? {
        URL(string: redirectURI)?.scheme
    }
}

final class OAuthClient {
    private let config: OAuthConfig
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private lazy var userAgent: String = {
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "FrameThrower"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(name)/\(version) (\(build))"
    }()

    init(config: OAuthConfig) {
        self.config = config
    }

    func authorize() async throws -> (OAuthTokens, String) {
        let loopback = try LoopbackCodeReceiver()
        let redirectURI = loopback.redirectURI.absoluteString

        let verifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let authURL = try authorizationURL(challenge: challenge, redirectURI: redirectURI)

        NSWorkspace.shared.open(authURL)

        let callbackURL = try await loopback.waitForCallback()
        let code = try Self.extractCode(from: callbackURL)
        let tokens = try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI)
        return (tokens, redirectURI)
    }

    func refresh(tokens: OAuthTokens) async throws -> OAuthTokens {
        var body = [
            "client_id": config.clientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token"
        ]
        if let secret = config.clientSecret, !secret.isEmpty {
            body["client_secret"] = secret
        }

        let response: TokenResponse = try await postForm(body)
        let expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: expiresAt
        )
    }

    private func authorizationURL(challenge: String, redirectURI: String) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func exchangeCode(
        _ code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> OAuthTokens {
        var body = [
            "client_id": config.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        if let secret = config.clientSecret, !secret.isEmpty {
            body["client_secret"] = secret
        }

        let response: TokenResponse = try await postForm(body)
        let expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        guard let refresh = response.refreshToken else {
            throw URLError(.userAuthenticationRequired)
        }

        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: refresh,
            expiresAt: expiresAt
        )
    }

    private func postForm<T: Decodable>(_ body: [String: String]) async throws -> T {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded(body)

        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode < 300 else {
            if let serverError = try? JSONDecoder().decode(OAuthServerError.self, from: data) {
                let detail = serverError.errorDescription ?? serverError.error
                throw OAuthClientError.serverError(message: detail)
            }
            throw OAuthClientError.badResponse(statusCode: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func formURLEncoded(_ body: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }


    private static func extractCode(from url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        guard let code else {
            throw URLError(.userAuthenticationRequired)
        }
        return code
    }

    private static func generateCodeVerifier() -> String {
        let data = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return data.base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64URLEncodedString()
    }
}

private final class LoopbackCodeReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "screencast.loopback")
    private var continuation: CheckedContinuation<URL, any Error>?

    private(set) var redirectURI: URL

    init() throws {
        var created: NWListener?
        var chosenPort: NWEndpoint.Port?

        for _ in 0..<5 {
            let portValue = UInt16.random(in: 49152...65535)
            guard let port = NWEndpoint.Port(rawValue: portValue) else { continue }
            do {
                created = try NWListener(using: .tcp, on: port)
                chosenPort = port
                break
            } catch {
                continue
            }
        }

        guard let listener = created, let chosenPort else {
            throw URLError(.cannotCreateFile)
        }

        self.listener = listener
        redirectURI = URL(string: "http://127.0.0.1:\(chosenPort)/oauth")!

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.handle(connection)
        }

        listener.start(queue: .global())
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let lines = request.split(separator: "\r\n")
            guard let first = lines.first else {
                connection.cancel()
                return
            }

            let parts = first.split(separator: " ")
            guard parts.count >= 2, let url = URL(string: "http://localhost\(parts[1])") else {
                connection.cancel()
                return
            }

            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Connection: close\r
            \r
            <html><body>You can close this window.</body></html>
            """
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            self.finish(url: url)
        }
    }

    private func finish(url: URL) {
        queue.async {
            self.listener.cancel()
            self.continuation?.resume(returning: url)
            self.continuation = nil
        }
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        let base64 = self.base64EncodedString()
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
