import Foundation

struct YouTubeUploadMetadata: Sendable {
    enum Visibility: String, CaseIterable, Identifiable, Sendable {
        case `private`, unlisted, `public`
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var title: String
    var description = ""
    var visibility: Visibility = .private
    var madeForKids: Bool? = nil

    var validationMessage: String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.count > 100 || title.contains(where: { "<>".contains($0) }) {
            return "Enter a title of 1–100 characters without < or >."
        }
        if description.utf8.count > 5000 || description.contains(where: { "<>".contains($0) }) {
            return "The description must be at most 5,000 bytes and cannot contain < or >."
        }
        if madeForKids == nil { return "Choose whether this video is made for kids." }
        return nil
    }

    func encoded() throws -> Data {
        if let validationMessage { throw YouTubeUploadError(message: validationMessage) }
        return try JSONSerialization.data(withJSONObject: [
            "snippet": ["title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                        "description": description,
                        "categoryId": "22"], // People & Blogs, the API sample default.
            "status": ["privacyStatus": visibility.rawValue,
                       "selfDeclaredMadeForKids": madeForKids == true]
        ])
    }
}

struct YouTubeUploadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct YouTubeUploadResult: Decodable, Sendable {
    let id: String
    var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
}

/// Initiates Google's resumable protocol, then streams the file from disk.
/// Failed transfers are reported without automatically starting a duplicate upload.
struct YouTubeUploader: Sendable {
    typealias SendMetadata = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias SendFile = @Sendable (URLRequest, URL, (@Sendable (Double) -> Void)?) async throws -> (Data, URLResponse)
    private let sendMetadata: SendMetadata
    private let sendFile: SendFile

    init(sendMetadata: @escaping SendMetadata = { try await URLSession.shared.data(for: $0) },
         sendFile: @escaping SendFile = { request, fileURL, progress in
             try await UploadProgressSession { sent, expected in
                 progress?(min(max(Double(sent) / Double(expected), 0), 1))
             }.upload(request: request, fromFile: fileURL)
         }) {
        self.sendMetadata = sendMetadata
        self.sendFile = sendFile
    }

    func upload(fileURL: URL, metadata: YouTubeUploadMetadata, accessToken: String,
                onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> YouTubeUploadResult {
        let body = try metadata.encoded()
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw YouTubeUploadError(message: "The video file is empty or unavailable.")
        }
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string:
            "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = body
        let (data, response) = try await sendMetadata(request)
        let http = try Self.check(data, response)
        guard let location = http.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location), uploadURL.scheme == "https",
              let host = uploadURL.host,
              host == "googleapis.com" || host.hasSuffix(".googleapis.com") else {
            throw YouTubeUploadError(message: "YouTube did not return a valid upload address.")
        }
        try Task.checkCancellation()
        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "PUT"
        upload.timeoutInterval = 3600
        upload.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        upload.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        upload.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (resultData, resultResponse) = try await sendFile(upload, fileURL, onProgress)
        _ = try Self.check(resultData, resultResponse)
        let result = try JSONDecoder().decode(YouTubeUploadResult.self, from: resultData)
        guard !result.id.isEmpty,
              result.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw YouTubeUploadError(message: "YouTube did not return a video link.")
        }
        onProgress?(1)
        return result
    }

    private static func check(_ data: Data, _ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = body?["error"] as? [String: Any]
            let message = error?["message"] as? String
            throw YouTubeUploadError(message: message ?? "YouTube responded with status \(http.statusCode).")
        }
        return http
    }
}
