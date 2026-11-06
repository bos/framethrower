import Darwin
import Foundation
@preconcurrency import AVFoundation
import Speech

private enum NativeSpeechFailure: Error { case failed(String) }

/// Only synthesized PCM is supplied. This never opens a microphone, plays
/// audio, writes an audio file, or constructs a media decoder/encoder.
@main @MainActor
struct NativeSpeechTranscriptionChecks {
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("Native speech check exceeded 45 seconds; no microphone was opened.\n".utf8))
            Darwin.exit(1)
        }
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw NativeSpeechFailure.failed("Native on-device English recognition is unavailable")
        }
        guard await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) else {
            throw NativeSpeechFailure.failed("This check requires existing local speech assets; no download was started")
        }
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .default }) else {
            throw NativeSpeechFailure.failed("No installed local English voice is available for synthetic test input")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await AppleSpeechAssetPreparation.prepare(transcriber, locale: locale)
        let synthesizer = AVSpeechSynthesizer()
        defer { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: "Zoom into box one.")
        utterance.voice = voice
        let synthesized = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SynthesizedPCM, any Error>) in
            let collection = SynthesizedPCM(continuation: continuation)
            synthesizer.write(utterance) { buffer in collection.receive(buffer) }
        }
        let buffers = synthesized.buffers
        guard let first = buffers.first, !buffers.isEmpty,
              buffers.allSatisfy({ $0.format == first.format }) else {
            throw NativeSpeechFailure.failed("Apple synthesis returned no usable consistent PCM")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: first.format),
              let converter = AVAudioConverter(from: first.format, to: format) else {
            throw NativeSpeechFailure.failed("Cannot convert synthetic PCM to the recognizer's native audio format")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let resultTask = Task { @MainActor in
            var transcript = SpeechTranscript()
            for try await result in transcriber.results {
                transcript.receive(.init(start: result.range.start.seconds, duration: result.range.duration.seconds,
                    text: String(result.text.characters), isFinal: result.isFinal))
            }
            return transcript.finalText
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let failures = FeedFailures()
        let feed = SpeechAudioFeed(converter: converter, outputFormat: format, continuation: continuation,
                                   onFailure: { failures.record($0) })
        for buffer in buffers { feed.receive(buffer) }
        feed.finish()
        do {
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let final = try await resultTask.value
            let words = Set(final.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            guard failures.messages.isEmpty else { throw NativeSpeechFailure.failed("Production PCM converter reported a failure") }
            guard words.contains("zoom"), words.contains("box"), words.contains("one") || words.contains("1") else {
                throw NativeSpeechFailure.failed("Native final transcription did not recognize the distinct synthetic command words")
            }
            print("Native speech transcription passed (existing local TTS → production PCM converter → on-device SpeechAnalyzer → finalized command words; no microphone, playback, audio file, or video).")
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

private final class SynthesizedPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SynthesizedPCM, any Error>?
    private var values: [AVAudioPCMBuffer] = []
    var buffers: [AVAudioPCMBuffer] { lock.lock(); defer { lock.unlock() }; return values }
    init(continuation: CheckedContinuation<SynthesizedPCM, any Error>) { self.continuation = continuation }
    func receive(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            self.continuation = nil
            continuation.resume(throwing: NativeSpeechFailure.failed("Apple synthesis did not return PCM"))
            return
        }
        if pcm.frameLength == 0 {
            self.continuation = nil
            continuation.resume(returning: self)
            return
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else {
            self.continuation = nil
            continuation.resume(throwing: NativeSpeechFailure.failed("Cannot retain synthetic PCM"))
            return
        }
        copy.frameLength = pcm.frameLength
        for (destination, source) in zip(UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList), UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)) {
            guard let to = destination.mData, let from = source.mData else { continue }
            to.copyMemory(from: from, byteCount: Int(min(destination.mDataByteSize, source.mDataByteSize)))
        }
        values.append(copy)
    }
}

private final class FeedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ message: String) { lock.lock(); defer { lock.unlock() }; values.append(message) }
}
