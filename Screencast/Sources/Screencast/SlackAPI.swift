import AppKit
import Foundation

struct SlackTokens: Codable {
    let accessToken: String
    let scope: String
    let teamID: String
    let userID: String
}

enum SlackClientError: LocalizedError {
    case serverError(message: String)
    case badResponse(statusCode: Int)
    case missingUserToken
    case uploadFailed(message: String)

    var errorDescription: String? {
        switch self {
        case let .serverError(message):
            return message
        case let .badResponse(statusCode):
            return "Server responded with status \(statusCode)."
        case .missingUserToken:
            return "Slack did not return a user access token."
        case let .uploadFailed(message):
            return message
        }
    }
}

struct SlackOAuthConfig: Codable, Hashable {
    let clientID: String
    let clientSecret: String
    let redirectURI: String
    let userScopes: [String]
}

final class SlackOAuthClient {
    private let config: SlackOAuthConfig
    private let tokenURL = URL(string: "https://slack.com/api/oauth.v2.access")!

    init(config: SlackOAuthConfig) {
        self.config = config
    }

    func authorize() async throws -> SlackTokens {
        let state = UUID().uuidString
        let authURL = try authorizationURL(state: state)
        NSWorkspace.shared.open(authURL)

        let callbackURL = try await SlackCallbackRouter.shared.waitForCallback(
            expectedState: state
        )
        let code = try Self.extractCode(from: callbackURL, expectedState: state)
        return try await exchangeCode(code)
    }

    private func authorizationURL(state: String) throws -> URL {
        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")
        let scopeValue = config.userScopes.joined(separator: ",")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "user_scope", value: scopeValue),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        return url
    }

    private func exchangeCode(_ code: String) async throws -> SlackTokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formURLEncoded([
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "code": code,
            "redirect_uri": config.redirectURI
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode < 300 else {
            throw SlackClientError.badResponse(statusCode: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(SlackOAuthResponse.self, from: data)
        guard decoded.ok else {
            throw SlackClientError.serverError(message: decoded.error ?? "Auth failed.")
        }
        guard let user = decoded.authedUser else {
            throw SlackClientError.missingUserToken
        }

        return SlackTokens(
            accessToken: user.accessToken,
            scope: user.scope ?? "",
            teamID: decoded.team?.id ?? "",
            userID: user.id ?? ""
        )
    }

    private func formURLEncoded(_ body: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func extractCode(from url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard state == expectedState else {
            throw URLError(.userAuthenticationRequired)
        }
        guard let code else {
            throw URLError(.userAuthenticationRequired)
        }
        return code
    }
}

final class SlackAPI {
    private let token: String

    init(token: String) {
        self.token = token
    }

    func listChannels() async throws -> [SlackChannel] {
        var results: [SlackChannel] = []
        var cursor: String? = nil

        repeat {
            var components = URLComponents(string: "https://slack.com/api/conversations.list")
            var queryItems = [
                URLQueryItem(name: "limit", value: "1000"),
                URLQueryItem(name: "exclude_archived", value: "true"),
                URLQueryItem(
                    name: "types",
                    value: "public_channel,private_channel"
                )
            ]
            if let cursor, !cursor.isEmpty {
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { break }

            let response: SlackConversationsResponse = try await get(url)
            results.append(contentsOf: response.channels)
            cursor = response.responseMetadata?.nextCursor
        } while cursor != nil && cursor != ""

        return results
    }

    func listUsers() async throws -> [SlackUser] {
        var results: [SlackUser] = []
        var cursor: String? = nil

        repeat {
            var components = URLComponents(string: "https://slack.com/api/users.list")
            var queryItems = [
                URLQueryItem(name: "limit", value: "200")
            ]
            if let cursor, !cursor.isEmpty {
                queryItems.append(URLQueryItem(name: "cursor", value: cursor))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { break }

            let response: SlackUsersResponse = try await get(url)
            results.append(contentsOf: response.members.filter { !$0.deleted && !$0.isBot })
            cursor = response.responseMetadata?.nextCursor
        } while cursor != nil && cursor != ""

        return results
    }

    func openDM(userID: String) async throws -> String {
        let url = URL(string: "https://slack.com/api/conversations.open")!
        let response: SlackOpenConversationResponse = try await postForm(
            url,
            body: ["users": userID]
        )
        guard response.ok else {
            throw SlackClientError.serverError(message: response.error ?? "Slack error.")
        }
        guard let channel = response.channel else {
            throw SlackClientError.serverError(message: "Slack did not return a channel.")
        }
        return channel.id
    }

    func uploadFile(
        fileURL: URL,
        filename: String,
        channelID: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> SlackUploadResult {
        guard fileURL.isFileURL else {
            throw URLError(.badURL)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            throw URLError(.zeroByteResource)
        }

        let uploadInfo = try await requestUploadURL(filename: filename, length: size)
        try await uploadBytes(fileURL: fileURL, uploadURL: uploadInfo.uploadURL) { progress in
            onProgress?(progress)
        }
        return try await completeUpload(fileID: uploadInfo.fileID, channelID: channelID)
    }

    private func requestUploadURL(
        filename: String,
        length: Int
    ) async throws -> SlackUploadURLResponse {
        let url = URL(string: "https://slack.com/api/files.getUploadURLExternal")!
        return try await postForm(
            url,
            body: [
                "filename": filename,
                "length": "\(length)"
            ]
        )
    }

    private func uploadBytes(
        fileURL: URL,
        uploadURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let progressSession = UploadProgressSession { sent, expected in
            let fraction = min(max(Double(sent) / Double(expected), 0), 1)
            onProgress?(fraction)
        }
        let (data, response) = try await progressSession.upload(
            request: request,
            fromFile: fileURL
        )
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode < 300 else {
            let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
            let message = snippet.isEmpty
                ? "Upload failed with status \(http.statusCode)."
                : "Upload failed with status \(http.statusCode). \(snippet)"
            throw SlackClientError.uploadFailed(message: message)
        }
    }

    private func completeUpload(
        fileID: String,
        channelID: String
    ) async throws -> SlackUploadResult {
        let url = URL(string: "https://slack.com/api/files.completeUploadExternal")!
        let filePayload = "[{\"id\":\"\(fileID)\"}]"
        let response: SlackCompleteUploadResponse = try await postForm(
            url,
            body: [
                "files": filePayload,
                "channel_id": channelID
            ]
        )
        guard response.ok else {
            throw SlackClientError.serverError(message: response.error ?? "Upload failed.")
        }
        let file = response.files?.first
        let linkString = file?.permalinkPublic ?? file?.permalink
        let permalink = linkString.flatMap(URL.init(string:))
        return SlackUploadResult(fileID: file?.id ?? fileID, permalink: permalink)
    }

    private func get<T: Decodable & SlackOkResponse>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode < 300 else {
            throw SlackClientError.badResponse(statusCode: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(T.self, from: data)
        if decoded.ok == false {
            throw SlackClientError.serverError(message: decoded.error ?? "Slack error.")
        }
        return decoded
    }

    private func postForm<T: Decodable & SlackOkResponse>(
        _ url: URL,
        body: [String: String]
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formURLEncoded(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode < 300 else {
            throw SlackClientError.badResponse(statusCode: http.statusCode)
        }
        let decoded = try JSONDecoder().decode(T.self, from: data)
        if decoded.ok == false {
            throw SlackClientError.serverError(message: decoded.error ?? "Slack error.")
        }
        return decoded
    }

    private func formURLEncoded(_ body: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}

@MainActor
final class SlackCallbackRouter {
    static let shared = SlackCallbackRouter()

    private var continuation: CheckedContinuation<URL, any Error>?
    private var expectedState: String?

    func waitForCallback(expectedState: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.expectedState = expectedState
            self.continuation = continuation
        }
    }

    func handle(url: URL) {
        guard url.scheme == "screencast-slack" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return
        }
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        if let expected = expectedState, state != expected {
            return
        }
        expectedState = nil
        continuation?.resume(returning: url)
        continuation = nil
    }
}

struct SlackBaseResponse: Decodable {
    let ok: Bool
    let error: String?
}

protocol SlackOkResponse {
    var ok: Bool { get }
    var error: String? { get }
}

struct SlackOAuthResponse: Decodable {
    let ok: Bool
    let error: String?
    let authedUser: SlackAuthedUser?
    let team: SlackTeam?

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
        case authedUser = "authed_user"
        case team
    }
}

extension SlackOAuthResponse: SlackOkResponse {}

struct SlackAuthedUser: Decodable {
    let id: String?
    let accessToken: String
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case accessToken = "access_token"
        case scope
    }
}

struct SlackTeam: Decodable {
    let id: String?
}

struct SlackChannel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let isPrivate: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case isPrivate = "is_private"
    }
}

struct SlackUser: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let realName: String?
    let deleted: Bool
    let isBot: Bool
    let profile: SlackUserProfile?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case realName = "real_name"
        case deleted
        case isBot = "is_bot"
        case profile
    }

    var displayName: String {
        if let profile, let display = profile.displayName, !display.isEmpty {
            return display
        }
        if let realName, !realName.isEmpty {
            return realName
        }
        return name
    }

    var label: String {
        let base = displayName
        let handle = name
        if base.lowercased() == handle.lowercased() {
            return base
        }
        return "\(base) (@\(handle))"
    }
}

struct SlackUserProfile: Codable, Hashable {
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

struct SlackConversationsResponse: Decodable {
    let ok: Bool
    let channels: [SlackChannel]
    let responseMetadata: SlackResponseMetadata?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case channels
        case error
        case responseMetadata = "response_metadata"
    }
}

extension SlackConversationsResponse: SlackOkResponse {}

struct SlackResponseMetadata: Decodable {
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
    }
}

struct SlackUsersResponse: Decodable {
    let ok: Bool
    let members: [SlackUser]
    let error: String?
    let responseMetadata: SlackResponseMetadata?

    private enum CodingKeys: String, CodingKey {
        case ok
        case members
        case error
        case responseMetadata = "response_metadata"
    }
}

extension SlackUsersResponse: SlackOkResponse {}

struct SlackOpenConversationResponse: Decodable {
    let ok: Bool
    let channel: SlackOpenChannel?
    let error: String?
}

extension SlackOpenConversationResponse: SlackOkResponse {}

struct SlackOpenChannel: Decodable {
    let id: String
}

struct SlackUploadURLResponse: Decodable {
    let ok: Bool
    let uploadURL: URL
    let fileID: String
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case uploadURL = "upload_url"
        case fileID = "file_id"
        case error
    }
}

extension SlackUploadURLResponse: SlackOkResponse {}

struct SlackCompleteUploadResponse: Decodable {
    let ok: Bool
    let files: [SlackUploadedFile]?
    let error: String?
}

extension SlackCompleteUploadResponse: SlackOkResponse {}

struct SlackUploadedFile: Decodable {
    let id: String?
    let permalink: String?
    let permalinkPublic: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case permalink
        case permalinkPublic = "permalink_public"
    }
}

struct SlackUploadResult {
    let fileID: String
    let permalink: URL?
}
