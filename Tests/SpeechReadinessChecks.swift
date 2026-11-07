import Darwin
import Foundation
@preconcurrency import AVFoundation

private enum ReadinessFailure: Error { case failed(String) }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ReadinessFailure.failed(message) }
}

@MainActor
private final class ManualPCMSource: LocalSpeechPCMSource {
    var receive: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var startup: CheckedContinuation<Void, any Error>?
    var delayStartup = false
    var starts = 0
    var startupError: (any Error)?
    var stopped = false
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onFailure: @escaping @Sendable (String) -> Void) async throws {
        starts += 1; receive = onBuffer
        if let startupError { throw startupError }
        if delayStartup { try await withCheckedThrowingContinuation { startup = $0 } }
        guard !stopped else { throw CancellationError() }
    }
    func stop() { stopped = true }
    func finishStartup() { let previous = startup; startup = nil; previous?.resume() }
    func send(_ value: Float, count: Int) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        buffer.floatChannelData![0].initialize(repeating: value, count: count)
        receive?(buffer)
    }
}

@MainActor
private final class DelayedRecognizer: BufferedSpeechRecognizer {
    let recognizerIdentifier: String
    var delayPreparation = true
    var delayTranscription = false
    var ignoresCancellation = false
    var preparationError: (any Error)?
    var transcriptionError: (any Error)?
    var preparationGate: CheckedContinuation<Void, any Error>?
    var transcriptionGate: CheckedContinuation<Void, Never>?
    var preparationBegan = false
    var cancelled = false
    var received = [[Float]]()
    var underlying: (any BufferedSpeechRecognizer)?
    var underlyingPreparationBegan = false
    let text: String
    init(_ name: String = "delayed recognizer", text: String = "Hand box one to box three") { recognizerIdentifier = name; self.text = text }
    func prepare() async throws {
        preparationBegan = true
        if delayPreparation { try await withCheckedThrowingContinuation { preparationGate = $0 } }
        if let preparationError { throw preparationError }
        if cancelled && !ignoresCancellation { throw CancellationError() }
        if let underlying { underlyingPreparationBegan = true; try await underlying.prepare() }
    }
    func transcribe(_ samples: [Float]) async throws -> String {
        received.append(samples)
        if delayTranscription { await withCheckedContinuation { transcriptionGate = $0 } }
        if let transcriptionError { throw transcriptionError }
        if let underlying { return try await underlying.transcribe(samples) }
        return text
    }
    func releasePreparation() { let previous = preparationGate; preparationGate = nil; previous?.resume() }
    func releaseTranscription() { let previous = transcriptionGate; transcriptionGate = nil; previous?.resume() }
    func cancel() async {
        cancelled = true
        if !ignoresCancellation { let previous = preparationGate; preparationGate = nil; previous?.resume(throwing: CancellationError()) }
        await underlying?.cancel()
    }
}

@main @MainActor
struct SpeechReadinessChecks {
    static func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try require(condition(), "a controlled asynchronous state did not arrive")
    }
    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { Darwin.exit(2) }
        do {
            try await earlyPrefixAndStop()
            try await stopBeforeCapture()
            try await cancelPreparation()
            try await fallbackPreservesPCM(inferenceFailure: false)
            try await fallbackPreservesPCM(inferenceFailure: true)
            try await oldUtteranceCannotReturn()
            try await boundedCapture()
            try await sourceFailureAndFormatChange()
            if let helper = CommandLine.arguments.dropFirst().first { try await nativeOpeningSpeech(URL(fileURLWithPath: helper)) }
            print("PASS: readiness tracks owned PCM; opening audio survives slow preparation, early Stop and Apple fallback; cancellation/generation/cap checks (synthetic RAM only; no microphone/playback/audio file/video)")
        } catch { print("FAIL: \(error)"); Darwin.exit(1) }
    }
    static func earlyPrefixAndStop() async throws {
        let decoder = DelayedRecognizer(); let source = ManualPCMSource()
        let speech = LocalSpeechInput(makeSession: { BufferedLocalSpeechSession(recognizer: decoder, source: source) })
        await speech.start()
        try require(speech.phase == .preparing && source.starts == 1, "returning from source start falsely announced Listening")
        try await until { decoder.preparationGate != nil }
        source.send(0.125, count: 3200)
        try await until { speech.phase == .listening }
        try require(decoder.received.isEmpty && decoder.preparationGate != nil, "capture waited for the decoder before Listening")
        source.send(0.25, count: 1600)
        let finish = Task { await speech.finish() }
        try await until { source.stopped }
        try require(speech.phase == .finishing, "Stop did not freeze immediately while preparation was pending")
        source.send(0.75, count: 1600) // An already queued late tap must be ignored.
        decoder.releasePreparation()
        let final = await finish.value
        try require(final == decoder.text, "recognized words were normalized or lost")
        let expected = [Float](repeating: 0.125, count: 3200) + [Float](repeating: 0.25, count: 1600)
        try require(decoder.received == [expected], "opening PCM prefix was dropped, reordered, or extended after Stop")
    }
    static func stopBeforeCapture() async throws {
        let decoder = DelayedRecognizer(); let source = ManualPCMSource(); source.delayStartup = true
        let speech = LocalSpeechInput(makeSession: { BufferedLocalSpeechSession(recognizer: decoder, source: source) })
        let starting = Task { await speech.start() }
        try await until { source.startup != nil && decoder.preparationGate != nil }
        try require(speech.phase == .preparing, "pending source startup falsely announced Listening")
        let final = await speech.finish()
        try require(final == nil && speech.phase == .idle && source.stopped && decoder.cancelled, "Stop before capture did not cancel pending preparation")
        source.finishStartup(); await starting.value
        source.send(0.5, count: 1600)
        try await Task.sleep(for: .milliseconds(5))
        try require(speech.phase == .idle && decoder.received.isEmpty, "late startup reactivated capture after Stop")
    }
    static func cancelPreparation() async throws {
        let decoder = DelayedRecognizer(); let source = ManualPCMSource()
        let speech = LocalSpeechInput(makeSession: { BufferedLocalSpeechSession(recognizer: decoder, source: source) })
        await speech.start(); try await until { decoder.preparationGate != nil }
        source.send(0.125, count: 1600)
        await speech.cancel() // May precede the queued first-buffer readiness task.
        source.send(0.5, count: 1600)
        try await Task.sleep(for: .milliseconds(5))
        try require(speech.phase == .idle && speech.transcript.isEmpty && decoder.cancelled && decoder.received.isEmpty, "late capture/preparation escaped cancellation")
    }
    static func fallbackPreservesPCM(inferenceFailure: Bool) async throws {
        let preferred = DelayedRecognizer("Whisper")
        if inferenceFailure { preferred.transcriptionError = WhisperSpeechError.runtimeFailed("fixture failure") }
        else { preferred.preparationError = WhisperSpeechError.invalidModel }
        let fallback = DelayedRecognizer("Apple DictationTranscriber", text: "Pond box one to box three")
        fallback.delayPreparation = false
        let decoder = FallbackBufferedSpeechRecognizer(preferred: preferred, fallback: { fallback })
        let source = ManualPCMSource()
        let speech = LocalSpeechInput(makeSession: { BufferedLocalSpeechSession(recognizer: decoder, source: source) })
        await speech.start(); try await until { preferred.preparationGate != nil }
        source.send(0.125, count: 1600); source.send(0.25, count: 800)
        try await until { speech.phase == .listening }
        let finish = Task { await speech.finish() }
        try await until { source.stopped }
        preferred.releasePreparation()
        let final = await finish.value
        let expected = [Float](repeating: 0.125, count: 1600) + [Float](repeating: 0.25, count: 800)
        try require(final == fallback.text && fallback.received == [expected], "fallback lost the opening PCM or rewrote its recognized words")
        try require(source.starts == 1 && speech.recognizerIdentifier == "Apple DictationTranscriber", "fallback restarted capture or hid its actual backend")
        if inferenceFailure { try require(preferred.received == fallback.received, "fallback inference received different audio") }
    }
    static func oldUtteranceCannotReturn() async throws {
        let old = DelayedRecognizer("old", text: "stale result"); old.delayPreparation = false; old.delayTranscription = true; old.ignoresCancellation = true
        let next = DelayedRecognizer("new", text: "new result"); next.delayPreparation = false
        let firstSource = ManualPCMSource(); let nextSource = ManualPCMSource(); var starts = 0
        let speech = LocalSpeechInput(makeSession: {
            starts += 1
            return starts == 1 ? BufferedLocalSpeechSession(recognizer: old, source: firstSource) : BufferedLocalSpeechSession(recognizer: next, source: nextSource)
        })
        await speech.start(); firstSource.send(0.125, count: 1600)
        try await until { speech.phase == .listening }
        let oldFinish = Task { await speech.finish() }
        try await until { old.transcriptionGate != nil }
        await speech.cancel(); await speech.start(); nextSource.send(0.25, count: 800)
        try await until { speech.phase == .listening }
        let final = await speech.finish()
        old.releaseTranscription(); let stale = await oldFinish.value
        try require(final == "new result" && stale == nil && speech.transcript == "new result", "late previous utterance replaced the new transcript")
    }
    static func boundedCapture() async throws {
        let decoder = DelayedRecognizer(); let source = ManualPCMSource()
        let speech = LocalSpeechInput(makeSession: { BufferedLocalSpeechSession(recognizer: decoder, source: source) })
        await speech.start(); try await until { decoder.preparationGate != nil }
        source.send(0.125, count: 120 * 16000)
        source.send(0.25, count: 16)
        try await until { speech.phase == .idle }
        try require(speech.errorMessage == WhisperSpeechError.tooLong.localizedDescription && decoder.received.isEmpty && source.stopped, "bounded capture silently discarded or transcribed a partial utterance")
    }
    static func sourceFailureAndFormatChange() async throws {
        let deniedDecoder = DelayedRecognizer(); let denied = ManualPCMSource(); denied.startupError = LocalSpeechError.microphoneDenied
        let permission = LocalSpeechInput(makeSession: { BufferedLocalSpeechSession(recognizer: deniedDecoder, source: denied) })
        await permission.start()
        try require(permission.phase == .idle && permission.errorMessage == LocalSpeechError.microphoneDenied.localizedDescription && deniedDecoder.cancelled, "capture startup failure became Listening or was hidden by decoder preparation")
        let decoder = DelayedRecognizer(); let source = ManualPCMSource()
        let speech = LocalSpeechInput(makeSession: { BufferedLocalSpeechSession(recognizer: decoder, source: source) })
        await speech.start(); try await until { decoder.preparationGate != nil }
        source.send(0.125, count: 1600)
        let other = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 800)!; buffer.frameLength = 800
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 800)
        source.receive?(buffer)
        let final = await speech.finish() // Race queued onFailure with Stop.
        try require(final == nil && decoder.received.isEmpty && speech.errorMessage == LocalSpeechError.invalidAudio.localizedDescription, "a format change silently transcribed the earlier partial utterance")
    }
    static func nativeOpeningSpeech(_ helper: URL) async throws {
        guard let voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha") else { throw ReadinessFailure.failed("no installed synthetic voice") }
        let cases = [
            ("Pan box one to box three over the next three seconds.", #"(?is)\bpan\W+box\W+(?:one|1)\W+to\W+box\W+(?:three|3)\b.*\bnext\W+(?:three|3)\W+seconds\b"#),
            ("One second from now, I want you to pan from box one, zoom out, and into box two after three seconds.", #"(?is)\b(?:one|1)\W+second\W+from\W+now\b.*\bpan\W+from\W+box\W+(?:one|1)\b.*\bzoom\W+out\b.*\binto\W+(?:a\W+)?box\W+(?:two|2)\b.*\bafter\W+(?:three|3)\W+seconds\b"#)
        ]
        for (text, meaning) in cases {
            let buffers = try await synthesize(text, voice: voice)
            let decoder = DelayedRecognizer("whisper.cpp large-v3-turbo Q5_0 (Metal)")
            decoder.underlying = WhisperBufferedSpeechRecognizer(executable: helper)
            let source = ManualPCMSource()
            let speech = LocalSpeechInput(makeSession: { BufferedLocalSpeechSession(recognizer: decoder, source: source) })
            await speech.start(); try await until { decoder.preparationGate != nil }
            for buffer in buffers { source.receive?(buffer) }
            try await until { speech.phase == .listening }
            let finish = Task { await speech.finish() }
            try await until { source.stopped }
            try require(!decoder.underlyingPreparationBegan, "real model preparation began before the controlled opening-prefix capture")
            decoder.releasePreparation()
            let final = await finish.value
            print("NATIVE delayed-preparation raw=\(final ?? "<nil>")")
            try require(final?.range(of: meaning, options: .regularExpression) != nil, "actual Whisper lost opening words captured before initialization")
        }
        if #available(macOS 26, *) {
            let buffers = try await synthesize(cases[1].0, voice: voice)
            let preferred = DelayedRecognizer("Whisper"); preferred.preparationError = WhisperSpeechError.invalidModel
            let decoder = FallbackBufferedSpeechRecognizer(preferred: preferred, fallback: { AppleBufferedSpeechRecognizer(contextualStrings: ["Box 1", "Box 2", "Box 3"]) })
            let source = ManualPCMSource()
            let speech = LocalSpeechInput(makeSession: { BufferedLocalSpeechSession(recognizer: decoder, source: source) })
            await speech.start(); try await until { preferred.preparationGate != nil }
            for buffer in buffers { source.receive?(buffer) }
            try await until { speech.phase == .listening }
            let finish = Task { await speech.finish() }
            try await until { source.stopped }; preferred.releasePreparation()
            let final = await finish.value
            print("NATIVE buffered-Apple-fallback raw=\(final ?? "<nil>")")
            try require(final?.range(of: cases[1].1, options: .regularExpression) != nil && source.starts == 1 && speech.recognizerIdentifier == "Apple DictationTranscriber", "actual Apple fallback lost opening audio, reopened capture, or hid its identifier")
        }
    }
    static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice) async throws -> [AVAudioPCMBuffer] {
        let synth = AVSpeechSynthesizer(); let utterance = AVSpeechUtterance(string: text); utterance.voice = voice
        return try await withCheckedThrowingContinuation { continuation in
            let collection = ReadinessSyntheticPCM(continuation)
            synth.write(utterance) { collection.receive($0) }
        }
    }

}

private final class ReadinessSyntheticPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], any Error>?
    private var buffers = [AVAudioPCMBuffer]()
    init(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], any Error>) { self.continuation = continuation }
    func receive(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { self.continuation = nil; continuation.resume(throwing: ReadinessFailure.failed("non-PCM synthesis")); return }
        if pcm.frameLength == 0 { self.continuation = nil; continuation.resume(returning: buffers); return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else { return }
        copy.frameLength = pcm.frameLength
        for (to, from) in zip(UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList), UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)) {
            if let destination = to.mData, let source = from.mData { destination.copyMemory(from: source, byteCount: Int(min(to.mDataByteSize, from.mDataByteSize))) }
        }
        buffers.append(copy)
    }
}
