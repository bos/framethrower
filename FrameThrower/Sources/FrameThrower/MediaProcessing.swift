import Foundation

/// Temporary development interlock while this Mac's video-scaling driver is
/// unstable. Keep this fixed in source: preferences, launch arguments, and test
/// runners must not accidentally enable media work on the user's machine.
enum MediaProcessing {
    static let isSuspended = true
    static let statusMessage = "Video processing is temporarily disabled."

    struct Suspended: LocalizedError {
        var errorDescription: String? { MediaProcessing.statusMessage }
    }

    static func requireEnabled() throws {
        if isSuspended { throw Suspended() }
    }
}
