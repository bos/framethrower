import Foundation
import UniformTypeIdentifiers

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

    func upload(fileURL: URL, accessToken: String) async throws -> DriveUploadResult {
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
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
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
