import Foundation

/// Recorded files are enabled. Live capture requires a deliberate Debug UI
/// opt-in for this process; release builds remain blocked. No saved preference
/// or environment variable enables live capture.
enum MediaProcessing {
    #if DEBUG
    private static let captureOverride = DebugCaptureOverride()
    static var isCaptureSuspended: Bool { !captureOverride.snapshot.enabled }
    static var captureGeneration: UInt64 { captureOverride.snapshot.generation }
    static func setDebugLiveCaptureEnabled(_ enabled: Bool) { captureOverride.set(enabled) }
    #else
    static let isCaptureSuspended = true
    static let captureGeneration: UInt64 = 0
    #endif
    static let captureStatusMessage = "Live capture is off."

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

#if DEBUG
/// Capture workers read the policy off the main thread. A generation also
/// rejects work accepted before the user turned capture off and back on.
private final class DebugCaptureOverride: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0
    var snapshot: (enabled: Bool, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (enabled, generation)
    }
    func set(_ next: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard next != enabled else { return }
        enabled = next; generation &+= 1
    }
}
#endif
