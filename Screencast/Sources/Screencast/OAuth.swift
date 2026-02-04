import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

struct OAuthTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }
}

struct OAuthConfig: Codable, Hashable {
    var clientID: String
    var redirectURI: String
    var scopes: [String]

    var callbackScheme: String? {
        URL(string: redirectURI)?.scheme
    }
}

final class OAuthClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let config: OAuthConfig
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private var currentSession: ASWebAuthenticationSession?

    init(config: OAuthConfig) {
        self.config = config
        super.init()
    }

    func authorize() async throws -> OAuthTokens {
        let verifier = Self.generateCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let authURL = try authorizationURL(challenge: challenge)

        guard let callbackScheme = config.callbackScheme else {
            throw URLError(.badURL)
        }

        let callbackURL = try await withCheckedThrowingContinuation {(
            continuation: CheckedContinuation<URL, any Error>
        ) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            currentSession = session

            if !session.start() {
                continuation.resume(throwing: URLError(.cannotLoadFromNetwork))
            }
        }

        currentSession = nil

        let code = try Self.extractCode(from: callbackURL)
        return try await exchangeCode(code, verifier: verifier)
    }

    func refresh(tokens: OAuthTokens) async throws -> OAuthTokens {
        let body = [
            "client_id": config.clientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token"
        ]

        let response: TokenResponse = try await postForm(body)
        let expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))
        return OAuthTokens(
            accessToken: response.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: expiresAt
        )
    }

    private func authorizationURL(challenge: String) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
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

    private func exchangeCode(_ code: String, verifier: String) async throws -> OAuthTokens {
        let body = [
            "client_id": config.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": config.redirectURI,
            "grant_type": "authorization_code"
        ]

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
        request.httpBody = body
            .map { item in
                let value = item.value.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ) ?? ""
                return "\(item.key)=\(value)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
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
