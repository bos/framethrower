import Foundation
import CryptoKit

/// Local interaction traces contain text and editing metadata supplied by the
/// caller. They never record audio, video, credentials, or network traffic.
/// A logging failure is deliberately separate from an editor failure.
@MainActor
final class DirectorDiagnostics {
    static let shared = DirectorDiagnostics()

    let directory: URL
    let logURL: URL
    let byteLimit: Int
    private var sequence: UInt64 = 0
    private let files = FileManager.default

    init(directory: URL? = nil, byteLimit: Int = 5 * 1024 * 1024) {
        self.directory = (directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FrameThrower/Director", isDirectory: true)).standardizedFileURL
        logURL = self.directory.appendingPathComponent("interactions.jsonl")
        // Leave room for the event envelope even when a test uses tiny files.
        self.byteLimit = max(512, byteLimit)
    }

    @discardableResult
    func record(_ event: String, sessionID: UUID, requestID: UUID? = nil,
                details: [String: Any]) -> Bool {
        do {
            let next = sequence &+ 1
            let timestamp = ISO8601DateFormatter()
            timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var entry: [String: Any] = [
                "timestamp": timestamp.string(from: Date()),
                "sequence": next,
                "session_id": sessionID.uuidString,
                "event": String(event.prefix(128)),
                "details": Self.withoutImagePixels(details)
            ]
            if event.count > 128 { entry["event_truncated"] = true }
            if let requestID { entry["request_id"] = requestID.uuidString }
            guard JSONSerialization.isValidJSONObject(entry) else { return false }
            let line = try boundedLine(entry)
            try prepareDirectory()
            if try size(of: logURL) > byteLimit - line.count { try rotate() }
            try prepareFile(logURL)
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            let start = try handle.seekToEnd()
            do { try handle.write(contentsOf: line) }
            catch {
                // Keep complete earlier JSONL records if an append fails.
                try? handle.truncate(atOffset: start)
                throw error
            }
            sequence = next
            return true
        } catch { return false }
    }

    /// Keep requests debuggable without copying image pixels into interaction
    /// logs. The corresponding inspection result retains its ID and geometry.
    private static func withoutImagePixels(_ value: Any) -> Any {
        if let values = value as? [Any] { return values.map(withoutImagePixels) }
        guard let dictionary = value as? [String: Any] else { return value }
        if dictionary["type"] as? String == "image_url" {
            let image = dictionary["image_url"] as? [String: Any]
            let url = image?["url"] as? String ?? ""
            let digest = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
            return ["type": "image_attachment", "encoded_bytes": url.utf8.count, "sha256": digest]
        }
        return dictionary.mapValues(withoutImagePixels)
    }

    private func boundedLine(_ original: [String: Any]) throws -> Data {
        func encode(_ entry: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .fragmentsAllowed])
            data.append(0x0A)
            return data
        }
        let full = try encode(original)
        if full.count <= byteLimit { return full }
        var entry = original
        entry["details_truncated"] = true
        entry["original_record_bytes"] = full.count
        // Truncate values structurally, then re-encode. Never cut a JSON line
        // or a UTF-8 sequence on disk. Smaller budgets converge on the envelope.
        var budget = max(16, byteLimit / 4)
        while budget >= 16 {
            entry["details"] = truncated(original["details"] ?? [:], budget: budget, depth: 0)
            let candidate = try encode(entry)
            if candidate.count <= byteLimit { return candidate }
            budget /= 2
        }
        entry["details"] = ["omitted": "Record exceeded the diagnostic size limit."]
        if let event = entry["event"] as? String, event.utf8.count > 32 {
            entry["event"] = String(decoding: event.utf8.prefix(32), as: UTF8.self)
            entry["event_truncated"] = true
        }
        let fallback = try encode(entry)
        guard fallback.count <= byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        return fallback
    }

    private func truncated(_ value: Any, budget: Int, depth: Int) -> Any {
        guard depth < 8 else { return "…" }
        if let text = value as? String {
            guard text.utf8.count > budget else { return text }
            return String(decoding: text.utf8.prefix(max(0, budget - 3)), as: UTF8.self) + "…"
        }
        if let dictionary = value as? [String: Any] {
            let keys = dictionary.keys.sorted().prefix(max(1, min(32, budget / 16)))
            let childBudget = max(8, budget / max(1, keys.count))
            var result: [String: Any] = [:]
            for key in keys {
                result[String(key.prefix(128))] = truncated(dictionary[key]!, budget: childBudget, depth: depth + 1)
            }
            if keys.count < dictionary.count { result["_omitted_keys"] = dictionary.count - keys.count }
            return result
        }
        if let values = value as? [Any] {
            let kept = values.prefix(max(1, min(16, budget / 16)))
            let childBudget = max(8, budget / max(1, kept.count))
            return kept.map { truncated($0, budget: childBudget, depth: depth + 1) }
        }
        return value
    }

    private func prepareDirectory() throws {
        if files.fileExists(atPath: directory.path) {
            guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func prepareFile(_ url: URL) throws {
        if (try? files.attributesOfItem(atPath: url.path)) != nil {
            try requireRegularFile(url)
        } else {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func requireRegularFile(_ url: URL) throws {
        guard try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private func size(of url: URL) throws -> Int {
        guard (try? files.attributesOfItem(atPath: url.path)) != nil else { return 0 }
        try requireRegularFile(url)
        return (try files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private func archive(_ index: Int) -> URL { directory.appendingPathComponent("interactions.\(index).jsonl") }

    private func rotate() throws {
        let oldest = archive(3)
        if files.fileExists(atPath: oldest.path) {
            try requireRegularFile(oldest)
            try files.removeItem(at: oldest)
        }
        for index in stride(from: 2, through: 0, by: -1) {
            let source = index == 0 ? logURL : archive(index)
            guard files.fileExists(atPath: source.path) else { continue }
            try requireRegularFile(source)
            // Existing diagnostic files may predate this instance's settings.
            // Retention still applies if a prior file is already oversized.
            if try size(of: source) > byteLimit {
                try files.removeItem(at: source)
                continue
            }
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            try files.moveItem(at: source, to: archive(index + 1))
        }
    }
}
