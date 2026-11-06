import Foundation

private enum CaptureCheckError: Error, Equatable { case timeout, operation, failed(String) }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CaptureCheckError.failed(message) }
}

@main
struct CaptureLifecycleChecks {
    static func main() async throws {
        try require(ScreenRecordingState.acceptsFirstFrame(status: .started), "initial screen frame was skipped")
        try require(ScreenRecordingState.acceptsFirstFrame(status: .complete), "complete screen frame was skipped")
        try require(!ScreenRecordingState.acceptsFirstFrame(status: .idle)
                    && !ScreenRecordingState.acceptsFirstFrame(status: .blank)
                    && !ScreenRecordingState.acceptsFirstFrame(status: nil), "non-frame event was used for synchronization")
        var state = ScreenRecordingState()
        try require(state.startResult == nil && state.finishResult == nil, "new capture was already resolved")
        state.firstFrameTime = 1234.5
        try require(state.startResult == nil, "sample output alone started capture before encoder readiness")
        state.didStartRecording = true
        let hostTime = try state.startResult?.get()
        try require(hostTime == 1234.5, "first frame host timestamp changed")
        state.finish(error: nil)
        try state.finishResult?.get()
        do {
            _ = try state.startResult?.get()
            throw CaptureCheckError.failed("already-finished capture reported successful start")
        } catch ScreenRecorder.RecorderError.noFramesCaptured {}

        var interrupted = ScreenRecordingState()
        interrupted.recordStreamFailure(CaptureCheckError.operation)
        try require(interrupted.finishResult == nil, "stream error completed file before encoder flushed")
        do {
            _ = try interrupted.startResult?.get()
            throw CaptureCheckError.failed("stream failure did not abort startup")
        } catch CaptureCheckError.operation {}
        interrupted.finish(error: nil)
        interrupted.finish(error: CaptureCheckError.timeout)
        do {
            try interrupted.finishResult?.get()
            throw CaptureCheckError.failed("successful file flush swallowed original stream error")
        } catch CaptureCheckError.operation {}

        var encoderFirst = ScreenRecordingState()
        encoderFirst.didStartRecording = true
        try require(encoderFirst.startResult == nil, "encoder callback alone bypassed first screen frame")
        encoderFirst.firstFrameTime = .nan
        try require(encoderFirst.startResult == nil, "invalid timestamp was accepted for synchronization")
        encoderFirst.firstFrameTime = 42
        let encoderFirstTime = try encoderFirst.startResult?.get()
        try require(encoderFirstTime == 42, "callback ordering changed source alignment")

        // A framework that never invokes completion must not strand capture UI.
        let started = ContinuousClock.now
        do {
            try await CaptureOperationDeadline.run(seconds: 0.025, timeoutError: CaptureCheckError.timeout) { _ in }
            throw CaptureCheckError.failed("missing callback did not time out")
        } catch CaptureCheckError.timeout {}
        try require(started.duration(to: .now) < .seconds(1), "timeout did not bound framework wait")

        do {
            try await CaptureOperationDeadline.run(seconds: 1, timeoutError: CaptureCheckError.timeout) { completion in
                completion(CaptureCheckError.operation)
            }
            throw CaptureCheckError.failed("framework failure was swallowed")
        } catch CaptureCheckError.operation {}

        // A duplicate framework callback must never resume a continuation twice.
        try await CaptureOperationDeadline.run(seconds: 1, timeoutError: CaptureCheckError.timeout) { completion in
            completion(nil)
            completion(CaptureCheckError.operation)
            completion(nil)
        }

        do {
            try await CaptureOperationDeadline.run(seconds: 0.01, timeoutError: CaptureCheckError.timeout) { completion in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.04) {
                    completion(nil)
                    completion(CaptureCheckError.operation)
                }
            }
            throw CaptureCheckError.failed("late callback beat deadline")
        } catch CaptureCheckError.timeout {}
        // A subsequent recording has an independent gate; the old callback must
        // not complete it, fail it, or crash from double continuation resumption.
        try await CaptureOperationDeadline.run(seconds: 1, timeoutError: CaptureCheckError.timeout) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { completion(nil) }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    try await CaptureOperationDeadline.run(seconds: 1, timeoutError: CaptureCheckError.timeout) { completion in
                        DispatchQueue.global().asyncAfter(deadline: .now() + Double(index % 5) / 1000) {
                            completion(nil)
                            completion(CaptureCheckError.operation)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        print("Capture lifecycle checks passed (event ordering, file finalization, missing/late/duplicate callbacks, and retries).")
    }
}
