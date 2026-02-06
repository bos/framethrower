#!/usr/bin/env swift
import Foundation

struct SlackTokens: Decodable {
    let accessToken: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "accessToken"
    }
}

struct SlackBaseResponse: Decodable {
    let ok: Bool
    let error: String?
}

struct SlackUsersResponse: Decodable {
    let ok: Bool
    let error: String?
    let members: [SlackUser]
    let responseMetadata: SlackResponseMetadata?

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
        case members
        case responseMetadata = "response_metadata"
    }
}

struct SlackUser: Decodable {
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
}

struct SlackUserProfile: Decodable {
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

struct SlackResponseMetadata: Decodable {
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case nextCursor = "next_cursor"
    }
}

struct SlackOpenConversationResponse: Decodable {
    let ok: Bool
    let error: String?
    let channel: SlackOpenChannel?
}

struct SlackOpenChannel: Decodable {
    let id: String
}

struct SlackUploadURLResponse: Decodable {
    let ok: Bool
    let error: String?
    let uploadURL: URL
    let fileID: String

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
        case uploadURL = "upload_url"
        case fileID = "file_id"
    }
}

struct SlackCompleteUploadResponse: Decodable {
    let ok: Bool
    let error: String?
}

struct SlackAuthTestResponse: Decodable {
    let ok: Bool
    let error: String?
    let userID: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case error
        case userID = "user_id"
    }
}

func run() async {
    do {
        let token = try loadToken()
        let fileURL = try resolveFileURL()
        let fileSize = try fileByteCount(fileURL)
        print("Using file: \(fileURL.path) (\(fileSize) bytes)")

        let userID = try await findUserID(token: token, handle: "bos")
        print("Matched Slack user id: \(userID)")
        let channelID = try await openDM(token: token, userID: userID)
        print("DM channel id: \(channelID)")

        let uploadInfo = try await requestUploadURL(
            token: token,
            filename: fileURL.lastPathComponent,
            length: fileSize
        )
        print("Upload URL received. File id: \(uploadInfo.fileID)")

        try await uploadFileBytes(fileURL: fileURL, uploadURL: uploadInfo.uploadURL)
        print("Upload bytes finished.")

        try await completeUpload(
            token: token,
            fileID: uploadInfo.fileID,
            channelID: channelID
        )
        print("Slack upload complete.")
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}

Task {
    await run()
    exit(0)
}

dispatchMain()

private func loadToken() throws -> String {
    if let env = ProcessInfo.processInfo.environment["SLACK_USER_TOKEN"], !env.isEmpty {
        return env
    }

    let prefsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/com.example.screencast.plist")
    let data = try Data(contentsOf: prefsURL)
    let plist = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
    )
    guard let dict = plist as? [String: Any] else {
        throw NSError(domain: "SlackUploadCLI", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Unexpected plist format."
        ])
    }
    guard let tokenData = dict["slack.tokens"] as? Data else {
        throw NSError(domain: "SlackUploadCLI", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Missing slack.tokens in preferences."
        ])
    }
    let tokens = try JSONDecoder().decode(SlackTokens.self, from: tokenData)
    guard !tokens.accessToken.isEmpty else {
        throw NSError(domain: "SlackUploadCLI", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Slack access token was empty."
        ])
    }
    return tokens.accessToken
}

private func resolveFileURL() throws -> URL {
    let args = CommandLine.arguments.dropFirst()
    if let raw = args.first, !raw.isEmpty {
        return URL(fileURLWithPath: raw).standardizedFileURL
    }

    let moviesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies")
    let contents = try FileManager.default.contentsOfDirectory(
        at: moviesURL,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    )
    let candidates = contents.filter { url in
        url.lastPathComponent.hasPrefix("Screencast-") && url.pathExtension == "mp4"
    }
    guard let latest = candidates.max(by: { lhs, rhs in
        let lhsValues = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
        let rhsValues = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
        let lhsDate = lhsValues?.contentModificationDate ?? .distantPast
        let rhsDate = rhsValues?.contentModificationDate ?? .distantPast
        return lhsDate < rhsDate
    }) else {
        throw NSError(domain: "SlackUploadCLI", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "No Screencast-*.mp4 files found in ~/Movies."
        ])
    }
    return latest
}

private func fileByteCount(_ fileURL: URL) throws -> Int {
    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
    let size = values.fileSize ?? 0
    if size <= 0 {
        throw NSError(domain: "SlackUploadCLI", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "File size was zero."
        ])
    }
    return size
}

private func findUserID(token: String, handle: String) async throws -> String {
    let normalizedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    var cursor: String? = nil
    repeat {
        var components = URLComponents(string: "https://slack.com/api/users.list")
        var items = [URLQueryItem(name: "limit", value: "200")]
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let response: SlackUsersResponse = try await slackGET(url: url, token: token)
        if let user = response.members.first(where: { user in
            if user.deleted || user.isBot {
                return false
            }
            let candidates = [
                user.name,
                user.displayName,
                user.realName ?? ""
            ]
            return candidates.contains(where: { $0.lowercased() == normalizedHandle })
        }) {
            return user.id
        }
        cursor = response.responseMetadata?.nextCursor
    } while cursor != nil && cursor != ""

    return try await authTestUserID(token: token)
}

private func authTestUserID(token: String) async throws -> String {
    let url = URL(string: "https://slack.com/api/auth.test")!
    let response: SlackAuthTestResponse = try await slackPOST(
        url: url,
        token: token,
        body: [:]
    )
    guard let userID = response.userID, !userID.isEmpty else {
        throw NSError(domain: "SlackUploadCLI", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "No Slack user found with handle bos."
        ])
    }
    return userID
}

private func openDM(token: String, userID: String) async throws -> String {
    let url = URL(string: "https://slack.com/api/conversations.open")!
    let response: SlackOpenConversationResponse = try await slackPOST(
        url: url,
        token: token,
        body: ["users": userID]
    )
    guard response.ok else {
        throw NSError(domain: "SlackUploadCLI", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "Slack error: \(response.error ?? "")"
        ])
    }
    guard let channel = response.channel else {
        throw NSError(domain: "SlackUploadCLI", code: 12, userInfo: [
            NSLocalizedDescriptionKey: "Slack did not return a channel."
        ])
    }
    return channel.id
}

private func requestUploadURL(
    token: String,
    filename: String,
    length: Int
) async throws -> SlackUploadURLResponse {
    let url = URL(string: "https://slack.com/api/files.getUploadURLExternal")!
    return try await slackPOST(
        url: url,
        token: token,
        body: [
            "filename": filename,
            "length": "\(length)"
        ]
    )
}

private func uploadFileBytes(fileURL: URL, uploadURL: URL) async throws {
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
    guard let http = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
    }
    guard http.statusCode < 300 else {
        throw NSError(domain: "SlackUploadCLI", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Upload bytes failed with status \(http.statusCode)."
        ])
    }
    if !data.isEmpty {
        let snippet = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        print("Upload response: \(snippet)")
    }
}

private func completeUpload(token: String, fileID: String, channelID: String) async throws {
    let url = URL(string: "https://slack.com/api/files.completeUploadExternal")!
    let filePayload = "[{\"id\":\"\(fileID)\"}]"
    let response: SlackCompleteUploadResponse = try await slackPOST(
        url: url,
        token: token,
        body: [
            "files": filePayload,
            "channel_id": channelID
        ]
    )
    guard response.ok else {
        throw NSError(domain: "SlackUploadCLI", code: 8, userInfo: [
            NSLocalizedDescriptionKey: "Slack completeUpload failed: \(response.error ?? "")"
        ])
    }
}

private func slackGET<T: Decodable>(url: URL, token: String) async throws -> T {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
        throw URLError(.badServerResponse)
    }
    let decoded = try JSONDecoder().decode(T.self, from: data)
    if let base = decoded as? SlackBaseResponse, base.ok == false {
        throw NSError(domain: "SlackUploadCLI", code: 9, userInfo: [
            NSLocalizedDescriptionKey: "Slack error: \(base.error ?? "")"
        ])
    }
    return decoded
}

private func slackPOST<T: Decodable>(
    url: URL,
    token: String,
    body: [String: String]
) async throws -> T {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formURLEncoded(body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
        throw URLError(.badServerResponse)
    }
    let decoded = try JSONDecoder().decode(T.self, from: data)
    if let base = decoded as? SlackBaseResponse, base.ok == false {
        throw NSError(domain: "SlackUploadCLI", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "Slack error: \(base.error ?? "")"
        ])
    }
    return decoded
}

private func formURLEncoded(_ body: [String: String]) -> Data? {
    var components = URLComponents()
    components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
    return components.percentEncodedQuery?.data(using: .utf8)
}
