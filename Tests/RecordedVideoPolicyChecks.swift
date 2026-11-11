import Foundation

@main
struct RecordedVideoPolicyChecks {
    static func main() {
        guard MediaProcessing.isCaptureSuspended else { fatalError("Live capture must remain off") }
        do { try MediaProcessing.requireCaptureEnabled(); fatalError("Capture guard unexpectedly opened") }
        catch is MediaProcessing.CaptureSuspended { }
        catch { fatalError("Wrong live-capture failure: \(error)") }
        #if DEBUG
        let beforeGeneration = MediaProcessing.captureGeneration
        MediaProcessing.setDebugLiveCaptureEnabled(true)
        guard !MediaProcessing.isCaptureSuspended, MediaProcessing.captureGeneration == beforeGeneration + 1 else { fatalError("Debug opt-in failed") }
        do { try MediaProcessing.requireCaptureEnabled() } catch { fatalError("Explicit debug opt-in blocked") }
        let enabledGeneration = MediaProcessing.captureGeneration
        MediaProcessing.setDebugLiveCaptureEnabled(true)
        guard MediaProcessing.captureGeneration == enabledGeneration else { fatalError("No-op enable invalidates work") }
        MediaProcessing.setDebugLiveCaptureEnabled(false)
        guard MediaProcessing.isCaptureSuspended, MediaProcessing.captureGeneration == enabledGeneration + 1 else { fatalError("Debug disable failed") }
        do { try MediaProcessing.requireCaptureEnabled(); fatalError("Revocation failed") }
        catch is MediaProcessing.CaptureSuspended { }
        catch { fatalError("Wrong revoked-policy failure") }
        // This executable links Foundation and policy only. It has no recorder,
        // camera, screenshot, or device code to execute while the flag is on.
        #endif
        if CommandLine.arguments.contains("--vector") {
            guard MediaProcessing.isSuspended else { fatalError("Vector mode should block recorded processing") }
            do { try MediaProcessing.requireEnabled(); fatalError("Recorded guard unexpectedly opened in vector mode") }
            catch is MediaProcessing.Suspended { }
            catch { fatalError("Wrong recorded-processing failure") }
        } else {
            guard !MediaProcessing.isSuspended else { fatalError("Recorded files must be enabled by default") }
            do { try MediaProcessing.requireEnabled() } catch { fatalError("Recorded processing blocked: \(error)") }
        }
        print("Recorded/live policy checks passed: recorded files permitted, capture defaults off with explicit Debug opt-in; no devices or media opened")
    }
}
