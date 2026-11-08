import Foundation

/// Preview navigation is transient. These commands never alter project edits,
/// trim, exported timing, source files, or the ordinary Undo/Redo stack.
enum EditorPreviewCommand: Codable, Equatable, Sendable {
    case play
    case pause
    case seek(Double)
    case setRate(Double)
    case stepFrames(Int)
    case playRange(start: Double, end: Double)
}

struct EditorPreviewRange: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}

struct EditorPreviewSnapshot: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case testPattern, footage }
    var time: Double
    /// Source-frame editing timestamp, using the recording's frame cadence.
    var frameTime: Double
    var isPlaying: Bool
    var rate: Double
    var range: EditorPreviewRange?
    var canPlay: Bool
    var kind: Kind
}

enum EditorPreviewError: LocalizedError {
    case unavailable, invalidTime, invalidRange, unsupportedRate
    var errorDescription: String? {
        switch self {
        case .unavailable: "The recording preview is not ready. No playback action was performed."
        case .invalidTime: "Choose a finite source time inside the recording."
        case .invalidRange: "Choose a nonempty preview range inside the original recording."
        case .unsupportedRate: "Choose an available preview playback speed. Exported timing is unchanged."
        }
    }
}
