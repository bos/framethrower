import Foundation

@main
struct CaptureRecordingSettingsChecks {
    enum Failure: Error { case failed(String) }

    static func main() throws {
        var name = PendingRecordingName()
        try require(name.title == nil && name.displayName == "New Recording", "Untouched title must retain automatic naming")
        try name.rename(to: "  Installation\n walkthrough  ")
        try require(name.title == "Installation walkthrough", "Normalize whitespace like saved recording names")
        let captured = name.title
        try name.rename(to: "Next take")
        name.didSave(capturedTitle: captured)
        try require(name.title == "Next take", "Saving an earlier snapshot must preserve a newer name")
        name.didSave(capturedTitle: name.title)
        try require(name.title == nil, "A successfully saved capture consumes its custom title")
        try name.rename(to: "Retain after failure")
        let snapshot = name
        // A failed start/save never calls didSave: title remains retryable.
        try require(name == snapshot, "A capture failure must preserve its pending name")
        do {
            try name.rename(to: String(repeating: "a", count: 257))
            throw Failure.failed("Overlong name accepted")
        } catch is PendingRecordingName.NameError {}
        try require(name == snapshot, "Invalid rename must not alter the chosen name")
        do {
            try name.rename(to: "bad\u{0000}name")
            throw Failure.failed("Control character accepted")
        } catch is PendingRecordingName.NameError {}
        try name.rename(to: " \n ")
        try require(name.title == nil, "Clearing the name restores automatic naming")

        for quality in RecordingQuality.allCases {
            let known = CaptureRecordingDetails(quality: quality, width: 1900, height: 1736)
            let unknown = CaptureRecordingDetails(quality: quality)
            try require(known.video.contains("1900 × 1736") && known.video.contains("60 fps"), "Both formats retain resolution and cadence")
            try require(!known.storage.isEmpty && !unknown.storage.isEmpty, "Both formats retain decision information")
            try require(unknown.video.contains("60 fps"), "Unknown source still shows capture cadence")
            if quality == .highQuality {
                try require(known.video.contains("ProRes LT") && known.storage.contains("/min"), "High quality identifies codec and estimated storage")
            } else {
                try require(known.video.contains("H.264") && known.storage.contains("screen activity"), "Compact identifies codec without promising an unconfigured bitrate")
            }
        }
        try require(CaptureRecordingDetails.pixelDimension(points: 950.2, scale: 2) == 1900, "Estimate matches even capture dimensions")
        try require(CaptureRecordingDetails.pixelDimension(points: 951.5, scale: 1) == 952, "Capture dimensions round before even alignment")
        try require(CaptureRecordingDetails.pixelDimension(points: .infinity, scale: 2) == nil, "Reject invalid geometry")
        try require(CaptureRecordingDetails.pixelDimension(points: 900, scale: .nan) == nil, "Reject invalid scale")
        print("Capture recording settings checks passed (pending name snapshots/reset/failure policy, both quality detail rows, and source-only geometry estimates).")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }
}
