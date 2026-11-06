import Foundation
import SwiftUI
@preconcurrency import AVFoundation
import Speech
import OSLog

/// Recognition results replace earlier hypotheses for the same audio range.
/// Consumers only receive the finished transcript, never individual hypotheses.
struct SpeechTranscript: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        var start: Double
        var duration: Double
        var text: String
        var isFinal: Bool
        var end: Double { start + duration }
    }

    private(set) var segments: [Segment] = []
    var text: String { joined(segments) }
    var finalText: String { joined(segments.filter(\.isFinal)) }

    mutating func receive(_ segment: Segment) {
        guard segment.start.isFinite, segment.duration.isFinite,
              segment.start >= 0, segment.duration > 0 else { return }
        func overlaps(_ other: Segment) -> Bool {
            segment.start < other.end - 0.000_001 && other.start < segment.end - 0.000_001
        }
        // A late volatile result must not roll back finalized words.
        if !segment.isFinal && segments.contains(where: { $0.isFinal && overlaps($0) }) { return }
        segments.removeAll { overlaps($0) }
        segments.append(segment)
        segments.sort { $0.start < $1.start }
    }

    private func joined(_ segments: [Segment]) -> String {
        segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

@MainActor
protocol LocalSpeechSession: AnyObject, Sendable {
    func start(onResult: @escaping @MainActor (SpeechTranscript.Segment) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws
    func finish() async throws
    func cancel() async
}

enum LocalSpeechError: LocalizedError {
    case unavailable, unsupportedLocale, microphoneDenied, noMicrophone, assetsPreparing, unsupportedConfiguration, invalidAudio

    var errorDescription: String? {
        switch self {
        case .unavailable: "On-device dictation requires macOS 26 and a supported Mac."
        case .unsupportedLocale: "On-device dictation is unavailable for your current language."
        case .microphoneDenied: "Allow microphone access for FrameThrower in System Settings to dictate edits."
        case .noMicrophone: "No microphone is available."
        case .assetsPreparing: "Apple is still preparing on-device dictation for your language. Try again shortly."
        case .unsupportedConfiguration: "Apple's on-device dictation is unavailable for this language on this Mac."
        case .invalidAudio: "The microphone's audio format is not supported."
        }
    }
}

/// Installation requests are optional because existing system assets may only
/// need to be reserved for this app. In that case requesting installation can
/// return nil while changing readiness from supported to installed.
enum SpeechAssetReadiness: String, Sendable {
    case installed, supported, downloading, unsupported

    @MainActor
    static func prepare(status: () async -> SpeechAssetReadiness,
                        installation: () async throws -> (@MainActor () async throws -> Void)?) async throws {
        try Task.checkCancellation()
        let initial = await status()
        if initial == .installed { return }
        if initial == .unsupported { throw LocalSpeechError.unsupportedConfiguration }
        if let install = try await installation() {
            try Task.checkCancellation()
            try await install()
        }
        try Task.checkCancellation()
        switch await status() {
        case .installed: return
        case .downloading: throw LocalSpeechError.assetsPreparing
        case .unsupported: throw LocalSpeechError.unsupportedConfiguration
        case .supported:
            // A nil request is not a connectivity error. Readiness metadata
            // may lag; SpeechAnalyzer.prepareToAnalyze is the final authority
            // and will report its real system error if assets cannot be used.
            return
        }
    }
}

@available(macOS 26, *)
enum AppleSpeechConfiguration {
    // Dictation preserves spoken timing in native command tests. Avoid the
    // shortForm hint: on this OS it can leave short utterances volatile even
    // after finalization. Long dictation still ends when the user presses Stop.
    // Tentative words are displayed, while only true final results are returned.
    static var preset: DictationTranscriber.Preset {
        var preset = DictationTranscriber.Preset.longDictation
        preset.reportingOptions.insert(.volatileResults)
        return preset
    }

    static func transcriber(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, preset: preset)
    }
}

@available(macOS 26, *)
@MainActor
enum AppleSpeechAssetPreparation {
    private static let logger = Logger(subsystem: "com.example.screencast", category: "speech-setup")

    static func prepare(_ transcriber: any SpeechModule, locale: Locale) async throws {
        try await SpeechAssetReadiness.prepare(status: {
            let state = await AssetInventory.status(forModules: [transcriber])
            let mapped: SpeechAssetReadiness
            switch state {
            case .installed: mapped = .installed
            case .supported: mapped = .supported
            case .downloading: mapped = .downloading
            case .unsupported: mapped = .unsupported
            @unknown default: mapped = .unsupported
            }
            logger.info("On-device dictation locale=\(locale.identifier, privacy: .public), asset status=\(mapped.rawValue, privacy: .public)")
            return mapped
        }, installation: {
            let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            logger.info("On-device dictation installation request available=\(request != nil, privacy: .public)")
            guard let request else { return nil }
            return { try await request.downloadAndInstall() }
        })
    }
}

/// No recording starts until the user presses the microphone control.
/// SpeechAnalyzer runs on device. Asset installation may download the speech model;
/// microphone audio and recognized words are never sent to a recognition service.
@MainActor
final class LocalSpeechInput: ObservableObject {
    enum Phase: Equatable { case idle, preparing, listening, finishing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    private var hypothesis = SpeechTranscript()
    private var session: (any LocalSpeechSession)?
    private var generation = UUID()
    private let makeSession: @MainActor () throws -> any LocalSpeechSession

    init(makeSession: (@MainActor () throws -> any LocalSpeechSession)? = nil) {
        self.makeSession = makeSession ?? {
            if #available(macOS 26, *) { return AppleLocalSpeechSession() }
            throw LocalSpeechError.unavailable
        }
    }

    deinit {
        let previous = session
        Task { @MainActor in await previous?.cancel() }
    }

    var isActive: Bool { phase != .idle }

    func start() async {
        guard phase == .idle else { return }
        generation = UUID()
        let current = generation
        hypothesis = SpeechTranscript()
        transcript = ""
        errorMessage = nil
        statusMessage = "Preparing on-device dictation…"
        phase = .preparing
        do {
            let next = try makeSession()
            session = next
            do {
                try await next.start(onResult: { [weak self] result in
                    guard let self, self.generation == current, self.phase != .idle else { return }
                    self.hypothesis.receive(result)
                    self.transcript = self.hypothesis.text
                }, onFailure: { [weak self] message in
                    guard let self, self.generation == current else { return }
                    self.generation = UUID()
                    self.errorMessage = message
                    self.statusMessage = nil
                    self.phase = .idle
                    self.session = nil
                })
            } catch {
                await next.cancel()
                throw error
            }
            guard generation == current else { await next.cancel(); return }
            statusMessage = nil
            phase = .listening
        } catch {
            guard generation == current else { return }
            await session?.cancel()
            session = nil
            phase = .idle
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Stop listening and return the single finalized utterance. The caller can
    /// put it in an editable command field; it does not apply an editor change.
    func finish() async -> String? {
        guard phase == .listening, let session else { return nil }
        let current = generation
        phase = .finishing
        statusMessage = "Finishing dictation…"
        do {
            try await session.finish()
            guard generation == current else { return nil }
            let result = hypothesis.finalText
            transcript = result
            self.session = nil
            phase = .idle
            statusMessage = nil
            if result.isEmpty { errorMessage = "No speech was recognized."; return nil }
            return result
        } catch {
            guard generation == current else { return nil }
            await session.cancel()
            self.session = nil
            phase = .idle
            statusMessage = nil
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func cancel() async {
        generation = UUID()
        let previous = session
        session = nil
        phase = .idle
        transcript = ""
        hypothesis = SpeechTranscript()
        statusMessage = nil
        await previous?.cancel()
    }

    func dismissError() { errorMessage = nil }
}

/// A microphone toggles dictation. Escape is supplied by the containing panel,
/// which should call cancel() when dismissing it.
struct LocalVoiceButton: View {
    @ObservedObject var speech: LocalSpeechInput
    var purpose = "Dictate an edit"
    let onTranscript: (String) -> Void

    var body: some View {
        Button {
            Task { @MainActor in
                if speech.phase == .listening {
                    if let text = await speech.finish() { onTranscript(text) }
                } else if speech.phase == .idle {
                    await speech.start()
                } else {
                    await speech.cancel()
                }
            }
        } label: {
            Image(systemName: speech.phase == .listening ? "stop.fill" : speech.phase == .idle ? "mic" : "xmark")
                .frame(width: 18, height: 18)
                .foregroundStyle(speech.phase == .listening ? Color.red : Color.primary)
        }
        .help(speech.phase == .listening ? "Finish dictation" : speech.phase == .idle ? purpose + " using on-device speech recognition" : "Cancel dictation")
        .accessibilityLabel(speech.phase == .listening ? "Finish dictation" : speech.phase == .idle ? purpose : "Cancel dictation")
    }
}

@available(macOS 26, *)
@MainActor
private final class AppleLocalSpeechSession: LocalSpeechSession {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var audioFeed: SpeechAudioFeed?
    private var resultsTask: Task<Void, any Error>?
    private var analysisTask: Task<Void, any Error>?
    private var onFailure: (@MainActor (String) -> Void)?
    private var stopped = false

    func start(onResult: @escaping @MainActor (SpeechTranscript.Segment) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else {
            throw LocalSpeechError.unsupportedLocale
        }
        try Task.checkCancellation()
        let transcriber = AppleSpeechConfiguration.transcriber(locale: locale)
        try await AppleSpeechAssetPreparation.prepare(transcriber, locale: locale)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed else { throw LocalSpeechError.microphoneDenied }
        try Task.checkCancellation()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let naturalFormat = input.outputFormat(forBus: 0)
        guard naturalFormat.channelCount > 0, naturalFormat.sampleRate > 0 else { throw LocalSpeechError.noMicrophone }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: naturalFormat),
              let converter = AVAudioConverter(from: naturalFormat, to: format) else { throw LocalSpeechError.invalidAudio }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.engine = engine
        self.onFailure = onFailure
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        self.continuation = continuation
        let feed = SpeechAudioFeed(converter: converter, outputFormat: format, continuation: continuation) { [weak self] message in
            Task { @MainActor in await self?.failedMessage(message) }
        }
        audioFeed = feed
        input.installTap(onBus: 0, bufferSize: 2048, format: naturalFormat) { buffer, _ in
            feed.receive(buffer)
        }
        try await analyzer.prepareToAnalyze(in: format)
        guard !stopped else { throw CancellationError() }
        resultsTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    onResult(SpeechTranscript.Segment(start: result.range.start.seconds,
                        duration: result.range.duration.seconds,
                        text: String(result.text.characters), isFinal: result.isFinal))
                }
            } catch {
                if !Task.isCancelled { await self.failed(error) }
                throw error
            }
        }
        analysisTask = Task { @MainActor in
            do { try await analyzer.start(inputSequence: stream) }
            catch {
                if !Task.isCancelled { await self.failed(error) }
                throw error
            }
        }
        engine.prepare()
        try engine.start()
    }

    func finish() async throws {
        stopMicrophone()
        audioFeed?.finish()
        audioFeed = nil
        continuation?.finish()
        continuation = nil
        try await analysisTask?.value
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        stopped = true
        analyzer = nil
        analysisTask = nil
        resultsTask = nil
        onFailure = nil
    }

    func cancel() async {
        stopped = true
        stopMicrophone()
        audioFeed?.cancel()
        audioFeed = nil
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        analysisTask?.cancel()
        let previous = analyzer
        analyzer = nil
        await previous?.cancelAndFinishNow()
        resultsTask = nil
        analysisTask = nil
        onFailure = nil
    }

    private func stopMicrophone() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    private func failed(_ error: any Error) async { await failedMessage(error.localizedDescription) }

    private func failedMessage(_ message: String) async {
        guard !stopped else { return }
        let callback = onFailure
        await cancel()
        callback?(message)
    }
}

/// AVAudioEngine serializes callbacks for this tap. The converter and its input
/// cursor are protected while the owning session flushes or cancels the feed.
/// AsyncStream's continuation carries owned converted buffers to the analyzer.
@available(macOS 26, *)
final class SpeechAudioFeed: @unchecked Sendable {
    let converter: AVAudioConverter
    let outputFormat: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var isFinished = false

    init(converter: AVAudioConverter, outputFormat: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.onFailure = onFailure
        self.converter = converter
        self.outputFormat = outputFormat
        self.continuation = continuation
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            onFailure("Could not allocate a microphone audio buffer.")
            return
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else {
            onFailure(conversionError?.localizedDescription ?? "Could not convert microphone audio for dictation.")
            return
        }
        guard output.frameLength > 0 else { return }
        yield(output)
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        // Drain the sample-rate converter so the final consonant isn't lost
        // when the microphone stops between hardware buffers.
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if status == .error || error != nil {
                onFailure(error?.localizedDescription ?? "Could not finish converting microphone audio.")
                break
            }
            if output.frameLength > 0 { yield(output) }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        continuation.finish()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isFinished = true
        continuation.finish()
    }

    private func yield(_ output: AVAudioPCMBuffer) {
        if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
            onFailure("Dictation could not keep up with the microphone. Please try a shorter instruction.")
        }
    }
}
