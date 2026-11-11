import Foundation

private enum CameraLifecycleFailure: Error { case failed(String) }

/// Simulates permissions/request revocation through a pure gate. The real
/// Debug capture override remains Off; no discovery/session/device is created.
@main @MainActor
struct CameraCaptureLifecycleChecks {
    private final class SimulatedPolicy: @unchecked Sendable {
        let lock = NSLock()
        private var suspended = false
        private var generation: UInt64 = 10
        var snapshot: (suspended: Bool, generation: UInt64) {
            lock.lock(); defer { lock.unlock() }; return (suspended, generation)
        }
        func change(suspended next: Bool) {
            lock.lock(); defer { lock.unlock() }
            if next != suspended { suspended = next; generation &+= 1 }
        }
    }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw CameraLifecycleFailure.failed(message) }
    }
    static func main() async throws {
        try require(MediaProcessing.isCaptureSuspended, "Actual live capture must stay Off throughout these checks")
        let policy = SimulatedPolicy()
        let gate = CameraCaptureRequestGate(captureGeneration: 10, policy: { policy.snapshot })
        let first = gate.nextRequest()
        try require(gate.allows(first), "Current simulated selection may configure")
        let second = gate.nextRequest()
        try require(!gate.allows(first) && gate.allows(second), "New selection supersedes a queued old configuration")
        policy.change(suspended: true)
        try require(!gate.allows(second), "Off revokes already accepted queued work")
        policy.change(suspended: false)
        try require(!gate.allows(second), "Off then On cannot revive a request from the previous capture generation")
        let fresh = CameraCaptureRequestGate(captureGeneration: policy.snapshot.generation, policy: { policy.snapshot })
        let accepted = fresh.nextRequest()
        try require(fresh.allows(accepted), "A deliberately fresh activation has its own generation")
        fresh.invalidate()
        try require(!fresh.allows(accepted) && !fresh.allows(fresh.nextRequest()), "Shutdown permanently invalidates an old engine regardless of global policy")
        do { try fresh.requireAllowed(); throw CameraLifecycleFailure.failed("Revoked engine accepted work") }
        catch is MediaProcessing.CaptureSuspended {}

        let recorder = CameraRecorder()
        try require(recorder.session == nil && recorder.devices.isEmpty && !recorder.isPreparing && !recorder.isReady,
            "Startup creates neither native camera session nor discovery")
        await recorder.resumeCaptureDiscovery()
        try require(recorder.session == nil && recorder.devices.isEmpty, "Off resume cannot discover cameras or create a session")
        await recorder.selectDevice("remembered-camera")
        try require(recorder.selectedDeviceID == "remembered-camera" && recorder.session == nil && !recorder.isReady,
            "Off selection retains the restore choice without asking permission or constructing a session")
        await recorder.suspendCapture()
        await recorder.suspendCapture()
        try require(recorder.selectedDeviceID == "remembered-camera" && recorder.session == nil && !recorder.isPreparing && !recorder.isRecording,
            "Repeated shutdown remains valid after Off and preserves the selected camera")
        await recorder.selectDevice(nil)
        try require(recorder.selectedDeviceID == nil && recorder.session == nil && recorder.errorMessage == nil,
            "An explicit Camera Off selection clears the preference without creating native objects")
        try require(MediaProcessing.isCaptureSuspended, "Tests never enable the real Debug capture override")
        print("Camera capture lifecycle checks passed (lazy startup, retained selection, disabled resume/selection/shutdown, queued request ordering and Off/On ABA rejection; no hardware or media).")
    }
}
