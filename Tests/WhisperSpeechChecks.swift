import CryptoKit
import Darwin
import Foundation
@preconcurrency import AVFoundation

private enum CheckFailure: Error { case failed(String) }
private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try value() == false { throw CheckFailure.failed(message) }
}

@main @MainActor
struct WhisperSpeechChecks {
    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { Darwin.exit(2) }
        do {
            try await integrityChecks()
            try await workerChecks()
            try await fallbackChecks()
            try await generationChecks()
            if let executable = CommandLine.arguments.dropFirst().first { try await nativeChecks(URL(fileURLWithPath: executable)) }
            print("PASS: verified atomic model import, partial cleanup, cancellation, helper errors/timeouts; synthetic RAM only, no microphone/playback/audio file/video")
        } catch { print("FAIL: \(error)"); Darwin.exit(1) }
    }
    static func integrityChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-speech-assets-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 73, count: 2 * 1024 * 1024)
        let model = LocalSpeechModel(filename: "test-model.bin", bytes: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let source = root.appendingPathComponent("source-weights.bin"); try bytes.write(to: source)
        let directory = root.appendingPathComponent("models")
        let store = LocalSpeechModelStore(directory: directory, importURL: source, model: model)
        let installed = try await store.prepare(); try await store.verify(installed)
        try require(try Data(contentsOf: installed) == bytes, "verified installation changed weights")
        let invalid = root.appendingPathComponent("invalid.bin"); try Data(repeating: 17, count: bytes.count).write(to: invalid)
        do { _ = try await store.install(from: invalid); throw CheckFailure.failed("bad hash accepted") }
        catch WhisperSpeechError.invalidModel {}
        try require(try Data(contentsOf: installed) == bytes, "failed install replaced the valid model")
        try Data(repeating: 0, count: bytes.count).write(to: installed)
        do { try await store.verify(installed); throw CheckFailure.failed("corrupt installed model accepted") }
        catch WhisperSpeechError.invalidModel {}
        _ = try await store.prepare(); try await store.verify(installed)
        let cancelled = Task { try await store.install(from: source) }; cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure.failed("cancelled install succeeded") }
        catch is CancellationError {}
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try require(!names.contains(where: { $0.hasSuffix(".partial") }), "failed/cancelled install left partial weights")
        print("PASS: model checksum, failed replacement preservation, corrupt-cache recovery, cancellation and partial cleanup")
    }
    static func helper(_ script: String, root: URL, name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + script).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    static func workerChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-speech-workers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = try helper("printf 'not json\\n'\n", root: root, name: "bad")
        do { try await WhisperSpeechWorker(executable: bad).prepare(model: root); throw CheckFailure.failed("invalid helper response accepted") }
        catch WhisperSpeechError.invalidResponse {}
        let noMetal = try helper("printf '{\"ready\":true,\"protocol\":1,\"backend\":\"cpu\"}\\n'\n", root: root, name: "cpu")
        do { try await WhisperSpeechWorker(executable: noMetal).prepare(model: root); throw CheckFailure.failed("CPU fallback accepted") }
        catch WhisperSpeechError.invalidResponse {}
        let hanging = try helper("exec /bin/sleep 20\n", root: root, name: "hanging")
        let timed = WhisperSpeechWorker(executable: hanging, startupTimeout: 0.1)
        do { try await timed.prepare(model: root); throw CheckFailure.failed("startup timeout ignored") }
        catch WhisperSpeechError.runtimeFailed(let message) { try require(message.contains("too long"), "timeout not explained") }
        let cancelled = WhisperSpeechWorker(executable: hanging)
        let preparation = Task { try await cancelled.prepare(model: root) }
        try await Task.sleep(for: .milliseconds(50)); preparation.cancel()
        do { try await preparation.value; throw CheckFailure.failed("startup cancellation ignored") } catch is CancellationError {}
        let exited = try helper("printf '{\"ready\":true,\"protocol\":1,\"backend\":\"metal\"}\\n'\n", root: root, name: "exited")
        let worker = WhisperSpeechWorker(executable: exited)
        try await worker.prepare(model: root); try await Task.sleep(for: .milliseconds(50))
        do { _ = try await worker.transcribe([Float](repeating: 0, count: 16000)); throw CheckFailure.failed("exited helper accepted PCM") }
        catch is CheckFailure { throw CheckFailure.failed("exited helper accepted PCM") }
        catch {}
        let nonReader = try helper("printf '{\"ready\":true,\"protocol\":1,\"backend\":\"metal\"}\\n'\nexec /bin/sleep 20\n", root: root, name: "non-reader")
        let blocked = WhisperSpeechWorker(executable: nonReader, inferenceTimeout: 0.1)
        try await blocked.prepare(model: root)
        let began = ContinuousClock.now
        do { _ = try await blocked.transcribe([Float](repeating: 0.1, count: 1_000_000)); throw CheckFailure.failed("blocked-write timeout ignored") }
        catch WhisperSpeechError.runtimeFailed(let message) { try require(message.contains("too long"), "inference timeout not explained") }
        try require(began.duration(to: .now) < .seconds(2), "timeout stalled while closing a blocked PCM writer")
        print("PASS: bounded protocol, Metal requirement, timeouts, task cancellation, broken-pipe and blocked-write isolation")
    }
    static func fallbackChecks() async throws {
        let preferred = FixtureSpeechSession(identifier: "whisper", error: WhisperSpeechError.runtimeUnavailable)
        let fallback = FixtureSpeechSession(identifier: "Apple DictationTranscriber")
        let speech = LocalSpeechInput(makeSession: {
            PreferredLocalSpeechSession(preferred: preferred, fallback: { fallback })
        })
        await speech.start()
        try require(speech.phase == .listening && speech.recognizerIdentifier == "Apple DictationTranscriber", "fallback did not report its actual recognizer")
        fallback.onResult?(.init(start: 0, duration: 1, text: "replace it", isFinal: true))
        let final = await speech.finish()
        try require(final == "replace it" && preferred.cancelled, "fallback failed final delivery or preferred cleanup")
        let denied = FixtureSpeechSession(identifier: "whisper", error: LocalSpeechError.microphoneDenied)
        let unused = FixtureSpeechSession(identifier: "Apple DictationTranscriber")
        let permission = LocalSpeechInput(makeSession: { PreferredLocalSpeechSession(preferred: denied, fallback: { unused }) })
        await permission.start()
        try require(permission.phase == .idle && !unused.started && permission.errorMessage == LocalSpeechError.microphoneDenied.localizedDescription, "microphone denial incorrectly triggered another recording backend")
        print("PASS: preparation fallback, actual recognizer identity, final delivery, and permission-error preservation")
    }
    static func generationChecks() async throws {
        for failureInStart in [false, true] {
            let previous = FixtureSpeechSession(identifier: "old", error: failureInStart ? CheckFailure.failed("old start") : nil)
            if !failureInStart { previous.finishError = CheckFailure.failed("old finish") }
            let next = FixtureSpeechSession(identifier: "new")
            var gate: CheckedContinuation<Void, Never>?
            previous.cancelAction = { count in
                if count == (failureInStart ? 2 : 1) {
                    await withCheckedContinuation { gate = $0 }
                }
            }
            var starts = 0
            let speech = LocalSpeechInput(makeSession: { starts += 1; return starts == 1 ? previous : next })
            let oldOperation: Task<Void, Never>
            if failureInStart { oldOperation = Task { await speech.start() } }
            else { await speech.start(); oldOperation = Task { _ = await speech.finish() } }
            while gate == nil { await Task.yield() }
            await speech.cancel(); await speech.start()
            try require(speech.phase == .listening && speech.recognizerIdentifier == "new", "new utterance could not start during old cleanup")
            gate?.resume(); await oldOperation.value
            try require(speech.phase == .listening && speech.errorMessage == nil && speech.recognizerIdentifier == "new", "old suspended cleanup cleared the new utterance")
            next.onResult?(.init(start: 0, duration: 1, text: "new result", isFinal: true))
            let final = await speech.finish(); try require(final == "new result", "old failure erased the new final transcript")
        }
        print("PASS: suspended start/finish error cleanup cannot clear or report errors into a newer utterance")
    }
    static func nativeChecks(_ executable: URL) async throws {
        let voiceIDs = ["com.apple.voice.compact.en-US.Samantha", "com.apple.voice.compact.en-GB.Daniel", "com.apple.voice.compact.en-IE.Moira"]
        let cases = [
            ("Pan box one to box three over the next three seconds.", #"(?is)\bpan\W+box\W+(?:one|1)\W+to\W+box\W+(?:three|3)\b.*\bnext\W+(?:three|3)\W+seconds\b"#),
            ("One second from now, I want you to pan from box one, zoom out, and into box two after three seconds.", #"(?is)\b(?:one|1)\W+second\W+from\W+now\b.*\bpan\W+from\W+box\W+(?:one|1)\b.*\bzoom\W+out\b.*\binto\W+(?:a\W+)?box\W+(?:two|2)\b.*\bafter\W+(?:three|3)\W+seconds\b"#),
            ("Pan from box one to box two over three seconds.", #"(?is)\bpan\W+from\W+box\W+(?:one|1)\W+to\W+box\W+(?:two|2)\b.*\bover\W+(?:three|3)\W+seconds\b"#),
            ("Pan from box one to box two over twelve seconds.", #"(?is)\bpan\W+from\W+box\W+(?:one|1)\W+to\W+box\W+(?:two|2)\b.*\bover\W+(?:twelve|12)\W+seconds\b"#),
            ("Let's have the new movement replace it.", #"(?is)\blet.?s\W+have\W+(?:the|a)\W+new\W+movement\W+replace\W+it\b"#)
        ]
        var count = 0
        for identifier in voiceIDs {
            guard let voice = AVSpeechSynthesisVoice(identifier: identifier) else { throw CheckFailure.failed("missing installed synthetic voice") }
            for (index, item) in cases.enumerated() {
                for rate: Float in index == 0 ? [0.5, 0.575] : [0.5] {
                    let buffers = try await synthesize(item.0, voice: voice, rate: rate)
                    let speech = LocalSpeechInput(makeSession: { WhisperLocalSpeechSession(executable: executable, syntheticBuffers: buffers) })
                    await speech.start()
                    try require(speech.phase == .listening && speech.errorMessage == nil, "native start failed: \(speech.errorMessage ?? "")")
                    try require(speech.transcript.isEmpty, "a synthetic hypothesis leaked before final recognition")
                    let final = await speech.finish()
                    print("NATIVE [\(voice.name), \(rate)] raw=\(final ?? "<nil>")")
                    try require(final?.range(of: item.1, options: .regularExpression) != nil, "native final lost action, targets, timing, or replacement")
                    try require(speech.recognizerIdentifier == "whisper.cpp large-v3-turbo Q5_0 (Metal)", "actual backend identifier missing")
                    count += 1
                }
            }
        }
        let voice = AVSpeechSynthesisVoice(identifier: voiceIDs[0])!
        let buffers = try await synthesize(cases[0].0, voice: voice, rate: 0.5)
        let speech = LocalSpeechInput(makeSession: { WhisperLocalSpeechSession(executable: executable, syntheticBuffers: buffers) })
        await speech.start()
        let finishing = Task { await speech.finish() }
        try await Task.sleep(for: .milliseconds(20)); await speech.cancel()
        let result = await finishing.value
        try require(result == nil && speech.phase == .idle && speech.transcript.isEmpty, "cancelled inference returned a stale utterance")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!; silence.frameLength = 16000
        silence.floatChannelData![0].initialize(repeating: 0, count: 16000)
        let muted = LocalSpeechInput(makeSession: { WhisperLocalSpeechSession(executable: executable, syntheticBuffers: [silence]) })
        await muted.start(); let mutedText = await muted.finish()
        try require(mutedText == nil && muted.transcript.isEmpty && muted.errorMessage == "No speech was recognized.", "digital silence invented a command")
        print("PASS: \(count) synthetic utterances → packaged Metal helper → LocalSpeechInput.finish; actual native inference cancellation")
    }
    static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice, rate: Float) async throws -> [AVAudioPCMBuffer] {
        let synth = AVSpeechSynthesizer(); let utterance = AVSpeechUtterance(string: text); utterance.voice = voice; utterance.rate = rate
        return try await withCheckedThrowingContinuation { continuation in
            let collector = SyntheticPCM(continuation)
            synth.write(utterance) { collector.receive($0) }
        }
    }
}

private final class SyntheticPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], any Error>?
    private var buffers = [AVAudioPCMBuffer]()
    init(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], any Error>) { self.continuation = continuation }
    func receive(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else { self.continuation = nil; continuation.resume(throwing: CheckFailure.failed("non-PCM synthesis")); return }
        if pcm.frameLength == 0 { self.continuation = nil; continuation.resume(returning: buffers); return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else { return }
        copy.frameLength = pcm.frameLength
        for (to, from) in zip(UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList), UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)) {
            if let destination = to.mData, let source = from.mData { destination.copyMemory(from: source, byteCount: Int(min(to.mDataByteSize, from.mDataByteSize))) }
        }
        buffers.append(copy)
    }
}

@MainActor
private final class FixtureSpeechSession: LocalSpeechSession, LocalSpeechBackendIdentifying {
    let recognizerIdentifier: String
    let error: (any Error)?
    var started = false
    var cancelled = false
    var finishError: (any Error)?
    var cancelAction: (@MainActor (Int) async -> Void)?
    var cancellationCount = 0
    var onResult: (@MainActor (SpeechTranscript.Segment) -> Void)?
    init(identifier: String, error: (any Error)? = nil) { recognizerIdentifier = identifier; self.error = error }
    func start(onResult: @escaping @MainActor (SpeechTranscript.Segment) -> Void, onFailure: @escaping @MainActor (String) -> Void) async throws {
        started = true
        if let error { throw error }
        self.onResult = onResult
    }
    func finish() async throws { if let finishError { throw finishError }; onResult = nil }
    func cancel() async { cancelled = true; onResult = nil; cancellationCount += 1; await cancelAction?(cancellationCount) }
}
