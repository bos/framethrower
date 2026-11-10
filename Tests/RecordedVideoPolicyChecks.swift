import Foundation

@main
struct RecordedVideoPolicyChecks {
    static func main() {
        guard MediaProcessing.isCaptureSuspended else { fatalError("Live capture must remain off") }
        do { try MediaProcessing.requireCaptureEnabled(); fatalError("Capture guard unexpectedly opened") }
        catch is MediaProcessing.CaptureSuspended { }
        catch { fatalError("Wrong live-capture failure: \(error)") }
        if CommandLine.arguments.contains("--vector") {
            guard MediaProcessing.isSuspended else { fatalError("Vector mode should block recorded processing") }
            do { try MediaProcessing.requireEnabled(); fatalError("Recorded guard unexpectedly opened in vector mode") }
            catch is MediaProcessing.Suspended { }
            catch { fatalError("Wrong recorded-processing failure") }
        } else {
            guard !MediaProcessing.isSuspended else { fatalError("Recorded files must be enabled by default") }
            do { try MediaProcessing.requireEnabled() } catch { fatalError("Recorded processing blocked: \(error)") }
        }
        print("Recorded/live policy checks passed: recorded files permitted, capture fixed off; no devices or media opened")
    }
}
