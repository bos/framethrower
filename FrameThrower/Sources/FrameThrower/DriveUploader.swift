import Foundation
import UniformTypeIdentifiers

final class UploadProgressSession {
    typealias ProgressHandler = @Sendable (_ bytesSent: Int64, _ bytesExpected: Int64) -> Void

    private let delegate: UploadProgressDelegate
    private let session: URLSession

    init(progressHandler: ProgressHandler?) {
        self.delegate = UploadProgressDelegate(progressHandler: progressHandler)
        self.session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func upload(
        request: URLRequest,
        from body: Data
    ) async throws -> (Data, URLResponse) {
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, from: body)
    }

    func upload(
        request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, fromFile: fileURL)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let progressHandler: UploadProgressSession.ProgressHandler?

    init(progressHandler: UploadProgressSession.ProgressHandler?) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progressHandler?(totalBytesSent, totalBytesExpectedToSend)
    }
}

struct DriveUploadResult: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let webViewLink: URL?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mimeType
        case webViewLink
    }
}

final class DriveUploader: @unchecked Sendable {
    private let uploadURL = URL(
        string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart" +
        "&fields=id,name,mimeType,webViewLink"
    )!

    func upload(
        fileURL: URL,
        accessToken: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DriveUploadResult {
        let filename = fileURL.lastPathComponent
        let mimeType = Self.mimeType(for: fileURL)
        let metadata = ["name": filename]

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        let metadataPart = try JSONSerialization.data(withJSONObject: metadata, options: [])
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataPart)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        let progressSession = UploadProgressSession { sent, expected in
            let fraction = min(max(Double(sent) / Double(expected), 0), 1)
            onProgress?(fraction)
        }
        let (data, response) = try await progressSession.upload(request: request, from: body)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DriveUploadResult.self, from: data)
    }

    private static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
