import Foundation
@preconcurrency import AVFoundation
import OSLog

@MainActor
protocol LocalSpeechBackendIdentifying {
    var recognizerIdentifier: String { get }
}

@MainActor
enum LocalSpeechBackendFactory {
    static func make(apple: @escaping @MainActor () throws -> any LocalSpeechSession) throws -> any LocalSpeechSession {
        if Locale.current.language.languageCode?.identifier == "en",
           let executable = WhisperSpeechWorker.bundledExecutable, LocalSpeechModelStore.hasLocalCandidate {
            return PreferredLocalSpeechSession(preferred: WhisperLocalSpeechSession(executable: executable), fallback: apple)
        }
        return try apple()
    }
}

/// A failed model/runtime preparation may fall back before any microphone opens.
/// Microphone permissions and recording errors are never mistaken for model errors.
@MainActor
final class PreferredLocalSpeechSession: LocalSpeechSession, LocalSpeechBackendIdentifying {
    var recognizerIdentifier: String {
        ((active ?? preferred) as? any LocalSpeechBackendIdentifying)?.recognizerIdentifier ?? "custom"
    }
    private let preferred: any LocalSpeechSession
    private let fallback: @MainActor () throws -> any LocalSpeechSession
    private var active: (any LocalSpeechSession)?
    private var cancelled = false
    init(preferred: any LocalSpeechSession, fallback: @escaping @MainActor () throws -> any LocalSpeechSession) {
        self.preferred = preferred; self.fallback = fallback
    }
    func start(onResult: @escaping @MainActor (SpeechTranscript.Segment) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws {
        active = preferred
        do { try await preferred.start(onResult: onResult, onFailure: onFailure) }
        catch let error as WhisperSpeechError {
            await preferred.cancel()
            guard !cancelled else { throw CancellationError() }
            Logger(subsystem: "com.example.screencast", category: "speech-setup")
                .error("Local speech preparation failed; using Apple dictation: \(error.localizedDescription, privacy: .public)")
            let next = try fallback(); active = next
            try await next.start(onResult: onResult, onFailure: onFailure)
        }
        guard !cancelled else { await active?.cancel(); throw CancellationError() }
    }
    func finish() async throws { try await active?.finish() }
    func cancel() async { cancelled = true; let previous = active; active = nil; await previous?.cancel() }
}

/// English command recognition using the verified large-v3-turbo model. The
/// helper receives one in-memory utterance when Stop is pressed. It produces
/// only the actual finalized words; no grammar, prompt, or word substitutions.
@MainActor
final class WhisperLocalSpeechSession: LocalSpeechSession, LocalSpeechBackendIdentifying {
    let recognizerIdentifier = "whisper.cpp large-v3-turbo Q5_0 (Metal)"
    private let worker: WhisperSpeechWorker
    private let modelStore: LocalSpeechModelStore
    private let syntheticBuffers: [AVAudioPCMBuffer]?
    private var engine: AVAudioEngine?
    private var accumulator: WhisperPCMAccumulator?
    private var onResult: (@MainActor (SpeechTranscript.Segment) -> Void)?
    private var onFailure: (@MainActor (String) -> Void)?
    private var stopped = false
    private var started = false

    init(executable: URL, modelStore: LocalSpeechModelStore = .shared, syntheticBuffers: [AVAudioPCMBuffer]? = nil) {
        worker = WhisperSpeechWorker(executable: executable); self.modelStore = modelStore
        self.syntheticBuffers = syntheticBuffers
    }
    func start(onResult: @escaping @MainActor (SpeechTranscript.Segment) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws {
        guard !started, !stopped else { throw WhisperSpeechError.busy }
        started = true
        let model: URL
        do { model = try await modelStore.prepare() }
        catch is CancellationError { throw CancellationError() }
        catch let error as WhisperSpeechError { throw error }
        catch { throw WhisperSpeechError.runtimeFailed("The local speech model could not be prepared: " + error.localizedDescription) }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        try await worker.prepare(model: model); try Task.checkCancellation()
        guard !stopped else { worker.cancel(); throw CancellationError() }
        self.onResult = onResult; self.onFailure = onFailure
        if let syntheticBuffers {
            guard let first = syntheticBuffers.first else { throw LocalSpeechError.invalidAudio }
            let feed = try WhisperPCMAccumulator(format: first.format) { [weak self] message in
                Task { @MainActor in await self?.failed(message) }
            }
            accumulator = feed
            for buffer in syntheticBuffers { feed.receive(buffer) }
            return
        }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard !stopped else { throw CancellationError() }
        guard allowed else { throw LocalSpeechError.microphoneDenied }
        let engine = AVAudioEngine(); let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw LocalSpeechError.noMicrophone }
        let feed = try WhisperPCMAccumulator(format: format) { [weak self] message in
            Task { @MainActor in await self?.failed(message) }
        }
        self.engine = engine; accumulator = feed
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in feed.receive(buffer) }
        engine.prepare(); try engine.start()
    }
    func finish() async throws {
        guard started, !stopped, let accumulator else { throw CancellationError() }
        stopMicrophone()
        let samples = try accumulator.finish(); self.accumulator = nil
        // Digital silence and sub-0.01-second input contain no usable speech.
        // Do not let a generative recognizer invent text for a muted input.
        guard samples.count >= 160, samples.contains(where: { abs($0) > 0.00001 }) else { await cancel(); return }
        let text = try await worker.transcribe(samples)
        guard !stopped else { throw CancellationError() }
        onResult?(.init(start: 0, duration: Double(samples.count) / 16000, text: text, isFinal: true))
        stopped = true; onResult = nil; onFailure = nil
    }
    func cancel() async {
        stopped = true; worker.cancel(); stopMicrophone()
        accumulator?.cancel(); accumulator = nil; onResult = nil; onFailure = nil
    }
    private func stopMicrophone() {
        guard let engine else { return }
        engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil
    }
    private func failed(_ message: String) async {
        guard !stopped else { return }
        let callback = onFailure; await cancel(); callback?(message)
    }
}

/// Owns converted samples, never retains a microphone tap's borrowed buffer.
/// The lock serializes the tap, final converter drain, and cancellation.
final class WhisperPCMAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let onFailure: @Sendable (String) -> Void
    private var values = [Float]()
    private var ended = false
    private var failure: (any Error)?
    init(format: AVAudioFormat, onFailure: @escaping @Sendable (String) -> Void) throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else { throw LocalSpeechError.invalidAudio }
        self.converter = converter; outputFormat = output; self.onFailure = onFailure
    }
    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !ended, failure == nil else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { fail(LocalSpeechError.invalidAudio); return }
        var consumed = false; var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .noDataNow; return nil }
            consumed = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil else { fail(LocalSpeechError.invalidAudio); return }
        append(output)
    }
    func finish() throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { throw CancellationError() }; ended = true
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { throw LocalSpeechError.invalidAudio }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            guard status != .error, error == nil else { throw LocalSpeechError.invalidAudio }
            append(output)
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        if let failure { throw failure }
        let result = values; values = []; return result
    }
    func cancel() { lock.lock(); ended = true; values = []; lock.unlock() }
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard values.count + Int(buffer.frameLength) <= 120 * 16000 else { fail(WhisperSpeechError.tooLong); return }
        if buffer.frameLength > 0, let channels = buffer.floatChannelData {
            let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
            guard samples.allSatisfy(\.isFinite) else { fail(LocalSpeechError.invalidAudio); return }
            values.append(contentsOf: samples)
        }
    }
    private func fail(_ error: any Error) { if failure == nil { failure = error; onFailure(error.localizedDescription) } }
}
