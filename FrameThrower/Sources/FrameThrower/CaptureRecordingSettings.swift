import Foundation

/// A name belongs to the next capture, not the last project opened in the editor.
/// Keeping the snapshot separate also preserves the name when a capture fails.
struct PendingRecordingName: Equatable {
    private(set) var title: String?
    var displayName: String { title ?? "New Recording" }

    mutating func rename(to proposedName: String) throws {
        let normalized = proposedName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Clearing a pending title restores automatic date-based naming.
        guard !normalized.isEmpty else { title = nil; return }
        guard normalized.count <= 256,
              !normalized.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw NameError.invalid
        }
        title = normalized
    }

    mutating func didSave(capturedTitle: String?) {
        // A future title entered while a capture completes must not be lost.
        if title == capturedTitle { title = nil }
    }

    enum NameError: LocalizedError {
        case invalid
        var errorDescription: String? { "Use a recording name of up to 256 characters without control characters." }
    }
}

/// These strings describe future captures and use only source geometry, never
/// decoding, screenshotting, or constructing a video encoder for an estimate.
struct CaptureRecordingDetails: Equatable {
    let video: String
    let storage: String

    init(quality: RecordingQuality, width: Int? = nil, height: Int? = nil) {
        let format = quality == .highQuality ? "ProRes LT" : "H.264"
        if let width, let height, width >= 2, height >= 2 {
            video = "\(width) × \(height) · 60 fps · \(format)"
            if quality == .highQuality {
                // ProRes LT's typical 1080p rate is 1.64 bits/pixel/frame.
                let bytes = Double(width) * Double(height) * 60 * 1.64 / 8 * 60
                if bytes.isFinite, bytes > 0, bytes < Double(Int64.max) {
                    let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                    storage = "About \(size)/min for screen video"
                } else {
                    storage = "Storage depends on the recording size"
                }
            } else {
                storage = "File size varies with screen activity"
            }
        } else {
            video = "60 fps · \(format)"
            storage = "Choose a source to see its recording size"
        }
    }

    static func pixelDimension(points: Double, scale: Double) -> Int? {
        let scaled = points * scale
        guard scaled.isFinite, scaled >= 2, scaled < Double(Int.max) else { return nil }
        let raw = Int(scaled.rounded())
        return raw % 2 == 0 ? raw : raw - 1
    }
}
