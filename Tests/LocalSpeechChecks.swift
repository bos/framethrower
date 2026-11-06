import Foundation

@MainActor
private final class MockSpeechSession: LocalSpeechSession {
    var onResult: (@MainActor (SpeechTranscript.Segment) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?
    var finishAction: (@MainActor () async throws -> Void)?
    var startAction: (@MainActor () async throws -> Void)?
    var cancellations = 0

    func start(onResult: @escaping @MainActor (SpeechTranscript.Segment) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws {
        self.onResult = onResult
        self.onFailure = onFailure
        try await startAction?()
    }
    func finish() async throws { try await finishAction?() }
    func cancel() async { cancellations += 1 }
    func emit(_ text: String, at time: Double = 0, duration: Double = 1, final: Bool) {
        onResult?(.init(start: time, duration: duration, text: text, isFinal: final))
    }
}

@main
struct LocalSpeechChecks {
    @MainActor
    static func main() async {
        var transcript = SpeechTranscript()
        transcript.receive(.init(start: 0, duration: 1, text: "zoom it", isFinal: false))
        transcript.receive(.init(start: 0, duration: 1.2, text: "zoom into this box", isFinal: false))
        expect(transcript.text == "zoom into this box", "volatile text replaces the previous hypothesis")
        expect(transcript.finalText.isEmpty, "volatile results cannot become commands")
        transcript.receive(.init(start: 0, duration: 1.2, text: "Zoom into this box.", isFinal: true))
        transcript.receive(.init(start: 0, duration: 1, text: "stale hypothesis", isFinal: false))
        transcript.receive(.init(start: 1.2, duration: 1, text: "Then zoom out.", isFinal: true))
        transcript.receive(.init(start: 1.2, duration: 1, text: "Then zoom out.", isFinal: true))
        expect(transcript.finalText == "Zoom into this box. Then zoom out.", "final segments survive stale hypotheses without duplication")
        let valid = transcript
        transcript.receive(.init(start: .nan, duration: 1, text: "bad", isFinal: true))
        transcript.receive(.init(start: 1, duration: -1, text: "bad", isFinal: true))
        expect(transcript == valid, "invalid audio ranges are ignored")

        let mock = MockSpeechSession()
        let speech = LocalSpeechInput(makeSession: { mock })
        expect(speech.phase == .idle, "constructing the controller starts no recognition")
        await speech.start()
        expect(speech.phase == .listening && speech.isActive, "recognition enters listening only after preparation")
        mock.emit("Zoom in", final: false)
        expect(speech.transcript == "Zoom in", "partial text is available for display")
        mock.finishAction = { mock.emit("Zoom into this area.", final: true) }
        let finished = await speech.finish()
        expect(finished == "Zoom into this area.", "finish returns the finalized utterance")
        expect(speech.phase == .idle && !speech.isActive, "finishing releases the active session")
        let repeated = await speech.finish()
        expect(repeated == nil, "one utterance cannot be submitted twice")

        await speech.start()
        mock.emit("discard this", final: false)
        await speech.cancel()
        mock.emit("late final after cancel", final: true)
        expect(speech.phase == .idle && speech.transcript.isEmpty, "cancel clears speech and rejects late results")
        expect(mock.cancellations > 0, "cancel propagates to the recognition engine")

        mock.finishAction = nil
        await speech.start()
        let empty = await speech.finish()
        expect(empty == nil && speech.errorMessage != nil, "empty recognition reports a useful state without an edit")
        speech.dismissError()
        expect(speech.errorMessage == nil, "recognition errors can be dismissed")
        mock.finishAction = nil
        await speech.start()
        mock.emit("unfinished", final: false)
        let partialOnly = await speech.finish()
        expect(partialOnly == nil, "unfinished hypotheses are never returned as final instructions")

        await speech.start()
        mock.onFailure?("The microphone was disconnected.")
        mock.emit("late failure result", final: true)
        expect(speech.phase == .idle && speech.errorMessage == "The microphone was disconnected.", "engine failures reset UI state")

        let unavailable = LocalSpeechInput(makeSession: { throw LocalSpeechError.unavailable })
        await unavailable.start()
        expect(unavailable.phase == .idle && unavailable.errorMessage != nil, "unsupported devices remain usable without a cloud fallback")

        let preparingMock = MockSpeechSession()
        var resumeStart: CheckedContinuation<Void, Never>?
        preparingMock.startAction = { await withCheckedContinuation { resumeStart = $0 } }
        let preparing = LocalSpeechInput(makeSession: { preparingMock })
        let startTask = Task { await preparing.start() }
        while resumeStart == nil { await Task.yield() }
        expect(preparing.phase == .preparing, "preparation is represented explicitly")
        await preparing.cancel()
        resumeStart?.resume()
        await startTask.value
        expect(preparing.phase == .idle && preparingMock.cancellations >= 2,
               "cancel during async preparation cannot reactivate the microphone session")

        print("PASS: local speech transcript replacement, final-only delivery, cancellation, errors, availability (mock audio; no microphone opened)")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else { fatalError("FAIL: \(description)") }
    }
}
