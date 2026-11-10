import Foundation

/// Recorded files are enabled. Live screen/camera capture remains source-fixed
/// off; neither a preference nor a test environment can enable capture.
enum MediaProcessing {
    static let isCaptureSuspended = true
    static let captureStatusMessage = "Live video capture is temporarily disabled."

    /// A disabling-only switch for metadata/vector fixtures. The default app
    /// can import, decode, composite, play and export existing video files.
    static let isSuspended = ProcessInfo.processInfo.environment["FRAMETHROWER_VECTOR_PREVIEW"] == "1"
    static let statusMessage = "Recorded video processing is disabled in vector-preview mode."

    struct Suspended: LocalizedError {
        var errorDescription: String? { MediaProcessing.statusMessage }
    }
    struct CaptureSuspended: LocalizedError {
        var errorDescription: String? { MediaProcessing.captureStatusMessage }
    }
    static func requireEnabled() throws {
        if isSuspended { throw Suspended() }
    }
    static func requireCaptureEnabled() throws {
        if isCaptureSuspended { throw CaptureSuspended() }
    }
}
