import Foundation
@preconcurrency import AVFoundation
import Speech
import OSLog

@MainActor
protocol LocalSpeechBackendIdentifying {
    var recognizerIdentifier: String { get }
}

/// Optional additive readiness reporting. Returning from start alone does not
/// establish that the microphone has delivered any owned audio.
@MainActor
protocol LocalSpeechCaptureReadinessReporting: AnyObject {
    var onCaptureReady: (@MainActor () -> Void)? { get set }
}

@MainActor
protocol BufferedSpeechRecognizer: AnyObject {
    var recognizerIdentifier: String { get }
    func prepare() async throws
    func transcribe(_ samples: [Float]) async throws -> String
    func cancel() async
}

@MainActor
protocol LocalSpeechPCMSource: AnyObject {
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws
    func stop()
}

@MainActor
enum LocalSpeechBackendFactory {
    static func make(contextualStrings: [String] = []) throws -> any LocalSpeechSession {
        let apple: @MainActor () throws -> any BufferedSpeechRecognizer = {
            if #available(macOS 26, *) { return AppleBufferedSpeechRecognizer(contextualStrings: contextualStrings) }
            throw LocalSpeechError.unavailable
        }
        if Locale.current.language.languageCode?.identifier == "en",
           let executable = WhisperSpeechWorker.bundledExecutable, LocalSpeechModelStore.hasLocalCandidate {
            let decoder = FallbackBufferedSpeechRecognizer(preferred: WhisperBufferedSpeechRecognizer(executable: executable), fallback: apple)
            return BufferedLocalSpeechSession(recognizer: decoder)
        }
        return BufferedLocalSpeechSession(recognizer: try apple())
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

/// Capture starts independently of decoder preparation. The same bounded PCM
/// is retained if Whisper preparation or inference needs Apple's local fallback.
@MainActor
final class BufferedLocalSpeechSession: LocalSpeechSession, LocalSpeechBackendIdentifying, LocalSpeechCaptureReadinessReporting {
    var recognizerIdentifier: String { recognizer.recognizerIdentifier }
    var onCaptureReady: (@MainActor () -> Void)?
    private enum State { case idle, capturing, finishing, finished, cancelled }
    private var state = State.idle
    private let recognizer: any BufferedSpeechRecognizer
    private let source: any LocalSpeechPCMSource
    private var collector: PendingSpeechPCM?
    private var preparation: Task<Void, any Error>?
    private var preparationWatch: Task<Void, Never>?
    private var captureStart: Task<Void, any Error>?
    private var onResult: (@MainActor (SpeechTranscript.Segment) -> Void)?
    private var onFailure: (@MainActor (String) -> Void)?
    private var reportedReady = false

    init(recognizer: any BufferedSpeechRecognizer, source: (any LocalSpeechPCMSource)? = nil) {
        self.recognizer = recognizer; self.source = source ?? MicrophoneSpeechPCMSource()
    }
    convenience init(executable: URL, modelStore: LocalSpeechModelStore = .shared, syntheticBuffers: [AVAudioPCMBuffer]? = nil) {
        self.init(recognizer: WhisperBufferedSpeechRecognizer(executable: executable, modelStore: modelStore),
                  source: syntheticBuffers.map { SyntheticSpeechPCMSource(buffers: $0) })
    }
    func start(onResult: @escaping @MainActor (SpeechTranscript.Segment) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws {
        guard state == .idle else { throw WhisperSpeechError.busy }
        state = .capturing; self.onResult = onResult; self.onFailure = onFailure
        let collector = PendingSpeechPCM { [weak self] message in
            Task { @MainActor in await self?.failed(message) }
        }
        self.collector = collector
        let recognizer = self.recognizer
        let preparation = Task { try await recognizer.prepare() }
        self.preparation = preparation
        preparationWatch = Task { [weak self] in
            do { try await preparation.value }
            catch {
                guard !Task.isCancelled else { return }
                await self?.failed(error.localizedDescription)
            }
        }
        let source = self.source
        let captureStart = Task { [weak self] in
            try await source.start(onBuffer: { [weak self] buffer in
                if collector.receive(buffer) {
                    Task { @MainActor in self?.capturedFirstBuffer() }
                }
            }, onFailure: { [weak self] message in
                Task { @MainActor in await self?.failed(message) }
            })
        }
        self.captureStart = captureStart
        do {
            try await captureStart.value
            // Synthetic/replayed input may already be owned before its queued
            // readiness callback runs; report that state deterministically.
            if collector.hasOwnedSamples { capturedFirstBuffer() }
        } catch {
            // Stop may freeze a zero/short utterance while permission/source
            // setup is still pending. That setup must not cancel finalization.
            guard state == .capturing else { return }
            await cancel(); throw error
        }
    }
    func finish() async throws {
        guard state == .capturing, let collector, let preparation else { throw CancellationError() }
        state = .finishing
        source.stop(); captureStart?.cancel(); captureStart = nil
        let samples = try collector.finish(); self.collector = nil
        guard samples.count >= 160, samples.contains(where: { abs($0) > 0.00001 }) else { await cancel(); return }
        try await preparation.value
        guard state == .finishing else { throw CancellationError() }
        let text = try await recognizer.transcribe(samples)
        guard state == .finishing else { throw CancellationError() }
        onResult?(.init(start: 0, duration: Double(samples.count) / 16000, text: text, isFinal: true))
        state = .finished; onResult = nil; onFailure = nil; onCaptureReady = nil
        preparationWatch?.cancel(); preparationWatch = nil; self.preparation = nil
        await recognizer.cancel()
    }
    func cancel() async {
        state = .cancelled; source.stop(); captureStart?.cancel(); captureStart = nil
        collector?.cancel(); collector = nil
        preparationWatch?.cancel(); preparationWatch = nil; preparation?.cancel(); preparation = nil
        onResult = nil; onFailure = nil; onCaptureReady = nil
        await recognizer.cancel()
    }
    private func capturedFirstBuffer() {
        guard state == .capturing, !reportedReady else { return }
        reportedReady = true; onCaptureReady?()
    }
    private func failed(_ message: String) async {
        guard state == .capturing else { return }
        let callback = onFailure; await cancel(); callback?(message)
    }
}

// Preserve the explicit native-test initializer and its existing call sites.
typealias WhisperLocalSpeechSession = BufferedLocalSpeechSession

@MainActor
final class WhisperBufferedSpeechRecognizer: BufferedSpeechRecognizer {
    let recognizerIdentifier = "whisper.cpp large-v3-turbo Q5_0 (Metal)"
    private let worker: WhisperSpeechWorker
    private let modelStore: LocalSpeechModelStore
    private var stopped = false
    init(executable: URL, modelStore: LocalSpeechModelStore = .shared) {
        worker = WhisperSpeechWorker(executable: executable); self.modelStore = modelStore
    }
    func prepare() async throws {
        let model: URL
        do { model = try await modelStore.prepare() }
        catch is CancellationError { throw CancellationError() }
        catch let error as WhisperSpeechError { throw error }
        catch { throw WhisperSpeechError.runtimeFailed("The local speech model could not be prepared: " + error.localizedDescription) }
        try Task.checkCancellation(); guard !stopped else { throw CancellationError() }
        try await worker.prepare(model: model)
        try Task.checkCancellation(); guard !stopped else { worker.cancel(); throw CancellationError() }
    }
    func transcribe(_ samples: [Float]) async throws -> String { try await worker.transcribe(samples) }
    func cancel() async { stopped = true; worker.cancel() }
}

@MainActor
final class FallbackBufferedSpeechRecognizer: BufferedSpeechRecognizer {
    var recognizerIdentifier: String { (active ?? preferred).recognizerIdentifier }
    private let preferred: any BufferedSpeechRecognizer
    private let fallback: @MainActor () throws -> any BufferedSpeechRecognizer
    private var active: (any BufferedSpeechRecognizer)?
    private var stopped = false
    init(preferred: any BufferedSpeechRecognizer, fallback: @escaping @MainActor () throws -> any BufferedSpeechRecognizer) {
        self.preferred = preferred; self.fallback = fallback
    }
    func prepare() async throws {
        active = preferred
        do { try await preferred.prepare() }
        catch let error as WhisperSpeechError { try await activateFallback(error) }
        try Task.checkCancellation(); guard !stopped else { throw CancellationError() }
    }
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let active, !stopped else { throw CancellationError() }
        do { return try await active.transcribe(samples) }
        catch let error as WhisperSpeechError {
            guard active === preferred else { throw error }
            try await activateFallback(error)
            guard let next = self.active, !stopped else { throw CancellationError() }
            return try await next.transcribe(samples)
        }
    }
    private func activateFallback(_ error: WhisperSpeechError) async throws {
        try Task.checkCancellation(); await preferred.cancel()
        guard !stopped else { throw CancellationError() }
        Logger(subsystem: "com.example.screencast", category: "speech-setup")
            .error("Whisper unavailable; recognizing the retained PCM with Apple dictation: \(error.localizedDescription, privacy: .public)")
        let next = try fallback(); active = next
        try await next.prepare()
    }
    func cancel() async {
        stopped = true; let current = active
        await preferred.cancel()
        if let current, current !== preferred { await current.cancel() }
    }
}

@MainActor
private final class MicrophoneSpeechPCMSource: LocalSpeechPCMSource {
    private var engine: AVAudioEngine?
    private var stopped = false
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        try Task.checkCancellation(); guard !stopped else { throw CancellationError() }
        guard allowed else { throw LocalSpeechError.microphoneDenied }
        let engine = AVAudioEngine(); let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw LocalSpeechError.noMicrophone }
        self.engine = engine
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in onBuffer(buffer) }
        engine.prepare(); try engine.start()
    }
    func stop() {
        stopped = true
        guard let engine else { return }
        engine.stop(); engine.inputNode.removeTap(onBus: 0); self.engine = nil
    }
}

@MainActor
private final class SyntheticSpeechPCMSource: LocalSpeechPCMSource {
    let buffers: [AVAudioPCMBuffer]
    private var stopped = false
    init(buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws {
        guard !buffers.isEmpty else { throw LocalSpeechError.invalidAudio }
        for buffer in buffers { try Task.checkCancellation(); guard !stopped else { throw CancellationError() }; onBuffer(buffer) }
    }
    func stop() { stopped = true }
}

/// Lazily fixes the first input format and owns converted samples immediately.
/// No borrowed AVAudioEngine buffers survive their callback.
private final class PendingSpeechPCM: @unchecked Sendable {
    private let lock = NSLock()
    private let onFailure: @Sendable (String) -> Void
    private var accumulator: WhisperPCMAccumulator?
    private var format: AVAudioFormat?
    private var ended = false
    private var failure: (any Error)?
    private var reportedReady = false
    init(onFailure: @escaping @Sendable (String) -> Void) { self.onFailure = onFailure }
    var hasOwnedSamples: Bool { lock.lock(); defer { lock.unlock() }; return !ended && failure == nil && (accumulator?.sampleCount ?? 0) > 0 }
    func receive(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended, failure == nil else { return false }
        do {
            if accumulator == nil {
                accumulator = try WhisperPCMAccumulator(format: buffer.format, onFailure: onFailure); format = buffer.format
            }
            guard buffer.format == format else { throw LocalSpeechError.invalidAudio }
            accumulator?.receive(buffer)
            if !reportedReady, (accumulator?.sampleCount ?? 0) > 0 { reportedReady = true; return true }
        } catch { failure = error; onFailure(error.localizedDescription) }
        return false
    }
    func finish() throws -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { throw CancellationError() }; ended = true
        if let failure { throw failure }
        return try accumulator?.finish() ?? []
    }
    func cancel() { lock.lock(); ended = true; accumulator?.cancel(); accumulator = nil; lock.unlock() }
}

@available(macOS 26, *)
@MainActor
final class AppleBufferedSpeechRecognizer: BufferedSpeechRecognizer {
    let recognizerIdentifier = "Apple DictationTranscriber"
    private let contextualStrings: [String]
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var inputFormat: AVAudioFormat?
    private var results: Task<String, any Error>?
    private var stopped = false
    init(contextualStrings: [String]) { self.contextualStrings = contextualStrings }
    func prepare() async throws {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else { throw LocalSpeechError.unsupportedLocale }
        let transcriber = AppleSpeechConfiguration.transcriber(locale: locale)
        try await AppleSpeechAssetPreparation.prepare(transcriber, locale: locale)
        try Task.checkCancellation(); guard !stopped else { throw CancellationError() }
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: pcm) else { throw LocalSpeechError.invalidAudio }
        let analyzer = SpeechAnalyzer(modules: [transcriber]); self.analyzer = analyzer
        try await AppleSpeechConfiguration.configure(analyzer, contextualStrings: contextualStrings)
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation(); guard !stopped else { await analyzer.cancelAndFinishNow(); throw CancellationError() }
        self.transcriber = transcriber; inputFormat = format
    }
    func transcribe(_ samples: [Float]) async throws -> String {
        guard !stopped, let analyzer, let transcriber, let inputFormat,
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(samples.count)),
              let converter = AVAudioConverter(from: pcm, to: inputFormat) else { throw LocalSpeechError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let task = Task { @MainActor in
            var transcript = SpeechTranscript()
            for try await result in transcriber.results {
                try Task.checkCancellation()
                transcript.receive(.init(start: result.range.start.seconds, duration: result.range.duration.seconds,
                                         text: String(result.text.characters), isFinal: result.isFinal))
            }
            return transcript.finalText
        }
        results = task
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let failure = BufferedAppleFeedFailure()
        let feed = SpeechAudioFeed(converter: converter, outputFormat: inputFormat, continuation: continuation, onFailure: { failure.record($0) })
        feed.receive(buffer); feed.finish()
        do {
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = try await task.value
            try Task.checkCancellation(); guard !stopped else { throw CancellationError() }
            if let message = failure.message { throw WhisperSpeechError.runtimeFailed(message) }
            self.analyzer = nil; self.transcriber = nil; results = nil
            return text
        } catch { await cancel(); throw error }
    }
    func cancel() async {
        stopped = true; results?.cancel(); results = nil
        let previous = analyzer; analyzer = nil; transcriber = nil
        await previous?.cancelAndFinishNow()
    }
}

private final class BufferedAppleFeedFailure: @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    var message: String? { lock.lock(); defer { lock.unlock() }; return value }
    func record(_ message: String) { lock.lock(); value = message; lock.unlock() }
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
    var sampleCount: Int { lock.lock(); defer { lock.unlock() }; return values.count }
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
