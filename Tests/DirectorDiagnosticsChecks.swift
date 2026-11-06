import Foundation

private enum DiagnosticsCheckFailure: Error { case failed(String) }

@main @MainActor
struct DirectorDiagnosticsChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-diagnostics-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try checkRecords(directory.appendingPathComponent("records"))
        try checkRotation(directory.appendingPathComponent("rotation"))
        try checkOversized(directory.appendingPathComponent("oversized"))
        try checkFailures(directory.appendingPathComponent("failures"))
        print("Director diagnostic checks passed (JSONL chronology/correlation, bounded rotation and truncation, private permissions, and nonfatal failures; no app, audio, video, or network).")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw DiagnosticsCheckFailure.failed(message) }
    }

    static func rows(_ url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        try require(data.last == 0x0A, "Every record must end with a newline")
        return try data.split(separator: 0x0A).map {
            guard let row = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else {
                throw DiagnosticsCheckFailure.failed("Record is not a JSON object")
            }
            return row
        }
    }

    static func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    static func checkRecords(_ directory: URL) throws {
        let logger = DirectorDiagnostics(directory: directory)
        let session = UUID(), request = UUID()
        let text = "Pan box one to box three.\nDon't change the camera."
        try require(logger.record("recognized_text", sessionID: session, requestID: request,
                                  details: ["text": text, "playhead": 1.5, "selected_box": NSNull()]), "Record transcript")
        try require(logger.record("tool_result", sessionID: session, requestID: request,
                                  details: ["applied": true, "changes": [["type": "zoom", "time": 4.5]]]), "Record structured result")
        try require(logger.record("manual_undo", sessionID: session, details: ["count": 1]), "Record manual event without request")
        let values = try rows(logger.logURL)
        try require(values.count == 3 && values.compactMap { ($0["sequence"] as? NSNumber)?.intValue } == [1, 2, 3], "Records keep call order")
        try require(values[0]["session_id"] as? String == session.uuidString && values[0]["request_id"] as? String == request.uuidString &&
                    values[1]["request_id"] as? String == request.uuidString && values[2]["request_id"] == nil,
                    "Session and optional request IDs correlate events")
        try require((values[0]["details"] as? [String: Any])?["text"] as? String == text &&
                    values[1]["event"] as? String == "tool_result" && values[2]["event"] as? String == "manual_undo",
                    "Text including newlines and structured action results round-trip")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try require(values.allSatisfy { ($0["timestamp"] as? String).flatMap { formatter.date(from: $0) } != nil }, "UTC timestamps are parseable")
        try require(permissions(directory) == 0o700 && permissions(logger.logURL) == 0o600, "Diagnostic directory and file are private")
    }

    static func checkRotation(_ directory: URL) throws {
        let limit = 1024
        let logger = DirectorDiagnostics(directory: directory, byteLimit: limit)
        let session = UUID()
        for index in 0..<40 {
            try require(logger.record("manual_edit", sessionID: session,
                                      details: ["index": index, "summary": String(repeating: "x", count: 250)]), "Write rotating event")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try require(files.count == 4 && files.contains(where: { $0.lastPathComponent == "interactions.jsonl" }),
                    "Rotation keeps current and at most three archives: \(files.map(\.lastPathComponent))")
        var sequences: [Int] = []
        for name in ["interactions.3.jsonl", "interactions.2.jsonl", "interactions.1.jsonl", "interactions.jsonl"] {
            let file = directory.appendingPathComponent(name)
            try require(Data(contentsOf: file).count <= limit && permissions(file) == 0o600, "Every archive respects size and permissions")
            sequences += try rows(file).map { ($0["sequence"] as! NSNumber).intValue }
        }
        try require(sequences == sequences.sorted() && sequences.last == 40 && sequences.first! > 1,
                    "Rotation retains newest events in chronological order")
        let reopened = DirectorDiagnostics(directory: directory, byteLimit: limit)
        try require(reopened.record("reopened", sessionID: UUID(), details: ["message": "next session"]), "Existing logs remain appendable")
        try require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 4,
                    "Reopening cannot increase retained file count")
        try Data(repeating: 0x78, count: limit * 3).write(to: logger.logURL)
        try require(reopened.record("after_oversized_file", sessionID: session, details: [:]),
                    "A pre-existing oversized diagnostic file cannot block new records")
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try require(Data(contentsOf: file).count <= limit && permissions(file) == 0o600,
                        "Retained files stay bounded and private after an oversized predecessor")
            _ = try rows(file)
        }
    }

    static func checkOversized(_ directory: URL) throws {
        let logger = DirectorDiagnostics(directory: directory, byteLimit: 1024)
        let session = UUID(), request = UUID()
        try require(logger.record("model_response", sessionID: session, requestID: request,
            details: ["nested": ["response": String(repeating: "🍎\"\n", count: 30_000)],
                      "actions": Array(repeating: ["summary": String(repeating: "long", count: 500)], count: 100)]), "Oversized event remains loggable")
        let data = try Data(contentsOf: logger.logURL)
        let row = try rows(logger.logURL)[0]
        try require(data.count <= 1024 && row["details_truncated"] as? Bool == true &&
                    (row["original_record_bytes"] as? NSNumber)?.intValue ?? 0 > 1024,
                    "Oversized details are explicitly marked and bounded valid JSON")
        try require(row["event"] as? String == "model_response" && row["session_id"] as? String == session.uuidString &&
                    row["request_id"] as? String == request.uuidString, "Truncation retains correlation and event identity")
        let tiny = DirectorDiagnostics(directory: directory.appendingPathComponent("tiny"), byteLimit: 512)
        try require(tiny.record(String(repeating: "🍎", count: 1000), sessionID: session, requestID: request,
                               details: ["text": String(repeating: "large", count: 100_000)]), "Oversized event names cannot overflow tiny logs")
        try require(try Data(contentsOf: tiny.logURL).count <= 512 && rows(tiny.logURL).count == 1, "Fallback envelope stays valid and bounded")
    }

    static func checkFailures(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("preserve".utf8).write(to: blocked)
        let failed = DirectorDiagnostics(directory: blocked)
        try require(!failed.record("event", sessionID: UUID(), details: [:]) && Data(contentsOf: blocked) == Data("preserve".utf8),
                    "An unwritable destination fails without touching unrelated data")
        let invalid = DirectorDiagnostics(directory: directory.appendingPathComponent("invalid"))
        try require(!invalid.record("event", sessionID: UUID(), details: ["bad": Double.nan]) && !manager.fileExists(atPath: invalid.logURL.path),
                    "Invalid JSON fails without creating a partial log")
        let symlinked = DirectorDiagnostics(directory: directory.appendingPathComponent("symlink"))
        try manager.createDirectory(at: symlinked.directory, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: symlinked.logURL, withDestinationURL: blocked)
        try require(!symlinked.record("event", sessionID: UUID(), details: [:]) && Data(contentsOf: blocked) == Data("preserve".utf8),
                    "Logger refuses a symlink instead of appending to another file")
    }
}
