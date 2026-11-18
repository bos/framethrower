import Foundation

private actor Calls {
    var metadata = 0
    var files = 0
    func sentMetadata() { metadata += 1 }
    func sentFile() { files += 1 }
    func verify(metadata expectedMetadata: Int, files expectedFiles: Int) {
        precondition(metadata == expectedMetadata && files == expectedFiles)
    }
}

private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ value: Double) { lock.withLock { values.append(value) } }
    func verify() { lock.withLock { precondition(values == [0.5, 1]) } }
}

@main
struct YouTubeUploadChecks {
    static func response(_ request: URLRequest, status: Int = 200,
                         headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    static func expectError(_ text: String, _ operation: @Sendable () async throws -> Void) async {
        do {
            try await operation()
            preconditionFailure("Expected error: \(text)")
        } catch {
            precondition(error.localizedDescription.contains(text), error.localizedDescription)
        }
    }

    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Plain bytes only: no video fixtures, media frameworks, or network requests.
        let file = folder.appendingPathComponent("upload.bin")
        try Data("test payload".utf8).write(to: file)
        let emptyFile = folder.appendingPathComponent("empty.bin")
        try Data().write(to: emptyFile)

        var metadata = YouTubeUploadMetadata(title: " My demo ")
        precondition(metadata.visibility == .private && metadata.madeForKids == nil)
        precondition(metadata.validationMessage?.contains("made for kids") == true)
        metadata.madeForKids = false
        precondition(metadata.validationMessage == nil)
        let valid = metadata
        for title in ["", "  \n", String(repeating: "x", count: 101), "<demo>"] {
            metadata.title = title
            precondition(metadata.validationMessage != nil)
        }
        metadata = valid
        metadata.description = String(repeating: "é", count: 2501)
        precondition(metadata.validationMessage != nil)
        metadata.description = "<invalid>"
        precondition(metadata.validationMessage != nil)
        metadata.description = String(repeating: "é", count: 2500)
        precondition(metadata.validationMessage == nil)
        for visibility in YouTubeUploadMetadata.Visibility.allCases {
            metadata.visibility = visibility
            let object = try JSONSerialization.jsonObject(with: metadata.encoded()) as! [String: Any]
            let status = object["status"] as! [String: Any]
            precondition(status["privacyStatus"] as? String == visibility.rawValue)
        }

        let calls = Calls()
        let uploader = YouTubeUploader(sendMetadata: { request in
            await calls.sentMetadata()
            precondition(request.httpMethod == "POST")
            precondition(request.url?.host == "www.googleapis.com")
            precondition(request.url?.query?.contains("uploadType=resumable") == true)
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
            precondition(request.value(forHTTPHeaderField: "X-Upload-Content-Length") == "12")
            precondition(request.value(forHTTPHeaderField: "X-Upload-Content-Type") == "video/mp4")
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let snippet = object["snippet"] as! [String: Any]
            let status = object["status"] as! [String: Any]
            precondition(snippet["title"] as? String == "My demo")
            precondition(snippet["categoryId"] as? String == "22")
            precondition(status["privacyStatus"] as? String == "private")
            precondition(status["selfDeclaredMadeForKids"] as? Bool == false)
            return (Data(), response(request, headers: ["Location": "https://www.googleapis.com/upload/session"]))
        }, sendFile: { request, url, progress in
            await calls.sentFile()
            precondition(url == file && request.httpBody == nil)
            precondition(request.httpMethod == "PUT")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
            precondition(request.value(forHTTPHeaderField: "Content-Length") == "12")
            progress?(0.5)
            return (Data(#"{"id":"abc_DE-123"}"#.utf8), response(request, status: 201))
        })
        let progress = ProgressValues()
        let result = try await uploader.upload(fileURL: file, metadata: valid, accessToken: "fake-token",
            onProgress: { progress.record($0) })
        progress.verify()
        precondition(result.url.absoluteString == "https://www.youtube.com/watch?v=abc_DE-123")
        await calls.verify(metadata: 1, files: 1)
        await expectError("empty") {
            _ = try await uploader.upload(fileURL: emptyFile, metadata: valid, accessToken: "fake-token")
        }
        await expectError("made for kids") {
            _ = try await uploader.upload(fileURL: file, metadata: YouTubeUploadMetadata(title: "Demo"), accessToken: "fake-token")
        }
        await calls.verify(metadata: 1, files: 1)

        for location in [nil, "http://www.googleapis.com/upload", "https://attacker.invalid/upload", "https://googleapis.com.attacker.invalid/upload"] as [String?] {
            let badLocation = YouTubeUploader(sendMetadata: { request in
                (Data(), response(request, headers: location.map { ["Location": $0] } ?? [:]))
            }, sendFile: { _, _, _ in preconditionFailure("Untrusted upload address") })
            await expectError("valid upload address") {
                _ = try await badLocation.upload(fileURL: file, metadata: valid, accessToken: "fake-token")
            }
        }
        for status in [401, 403, 429, 500] {
            let failing = YouTubeUploader(sendMetadata: { request in
                (Data(#"{"error":{"message":"API denied this upload"}}"#.utf8), response(request, status: status))
            }, sendFile: { _, _, _ in preconditionFailure("Must stop after API error") })
            await expectError("API denied") {
                _ = try await failing.upload(fileURL: file, metadata: valid, accessToken: "fake-token")
            }
        }
        let transferFailure = YouTubeUploader(sendMetadata: { request in
            (Data(), response(request, headers: ["Location": "https://www.googleapis.com/upload/session"]))
        }, sendFile: { request, _, _ in
            (Data(), response(request, status: 503))
        })
        await expectError("503") {
            _ = try await transferFailure.upload(fileURL: file, metadata: valid, accessToken: "fake-token")
        }
        let invalidResult = YouTubeUploader(sendMetadata: { request in
            (Data(), response(request, headers: ["Location": "https://www.googleapis.com/upload/session"]))
        }, sendFile: { request, _, _ in
            (Data(#"{"id":"bad&id=oops"}"#.utf8), response(request, status: 201))
        })
        await expectError("video link") {
            _ = try await invalidResult.upload(fileURL: file, metadata: valid, accessToken: "fake-token")
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await uploader.upload(fileURL: file, metadata: valid, accessToken: "fake-token")
                preconditionFailure("Cancelled upload started")
            } catch is CancellationError { }
        }
        try await cancelled.value
        await calls.verify(metadata: 1, files: 1)
        print("YouTube metadata, streamed upload requests, API errors, and cancellation checks passed")
    }
}
