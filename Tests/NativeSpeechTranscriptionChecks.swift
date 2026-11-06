import Darwin
import Foundation
@preconcurrency import AVFoundation
import Speech

private enum NativeSpeechFailure: Error { case failed(String) }

/// Only synthesized PCM is supplied. This never opens a microphone, plays
/// audio, writes an audio file, or constructs a media decoder/encoder.
@main @MainActor
struct NativeSpeechTranscriptionChecks {
    static func main() async {
        do { try await check() }
        catch {
            FileHandle.standardError.write(Data("Native speech check failed: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func check() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            FileHandle.standardError.write(Data("Native speech check exceeded 45 seconds; no microphone was opened.\n".utf8))
            Darwin.exit(1)
        }
        guard #available(macOS 26, *),
              let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw NativeSpeechFailure.failed("Native on-device English recognition is unavailable")
        }
        guard await DictationTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) else {
            throw NativeSpeechFailure.failed("This check requires existing local speech assets; no download was started")
        }
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language == "en-US" && $0.quality == .default }) else {
            throw NativeSpeechFailure.failed("No installed local English voice is available for synthetic test input")
        }
        FileHandle.standardOutput.write(Data("Synthetic voice: \(voice.name) (\(voice.identifier)); production short-command dictation.\n".utf8))
        let commands = [
            ("Zoom into box one.", #"(?is)\bzoom\W+into\W+box\W+(?:one|1)\b"#),
            ("One second from now, I want you to pan from box one, zoom out, and into box two after three seconds.",
             #"(?is)\b(?:one|1)\W+second\W+from\W+now\b.*\bpan\W+from\W+box\W+(?:one|1)\b.*\bzoom\W+out\b.*\binto\W+box\W+(?:two|2)\b.*\bafter\W+(?:three|3)\W+seconds\b"#),
            ("Twelve seconds from now, pan from box two to box one over two seconds.",
             #"(?is)\b(?:twelve|12)\W+seconds\W+from\W+now\b.*\bpan\W+from\W+box\W+(?:two|2)\W+to\W+box\W+(?:one|1)\b.*\bover\W+(?:two|2)\W+seconds\b"#),
            ("Two seconds from now, pan from box one to box two over twelve seconds.",
             #"(?is)\b(?:two|2)\W+seconds\W+from\W+now\b.*\bpan\W+from\W+box\W+(?:one|1)\W+to\W+box\W+(?:two|2)\b.*\bover(?:\W+(?:twelve|12)|12)\W+seconds\b"#)
        ]
        for (source, requiredMeaning) in commands {
            let final = try await transcribe(source, locale: locale, voice: voice)
            FileHandle.standardOutput.write(Data("Synthetic command transcript: \(final)\n".utf8))
            guard final.range(of: requiredMeaning, options: .regularExpression) != nil else {
                throw NativeSpeechFailure.failed("Native final transcription lost command targets, action order, or relative timing. Input: \(source); actual: \(final)")
            }
        }
        print("Native speech transcription passed (four commands preserving targets, action order, and one/two/three/twelve-second timing; existing local TTS → production PCM converter → production on-device DictationTranscriber; no microphone, playback, audio file, or video).")
    }

    @available(macOS 26, *)
    private static func transcribe(_ source: String, locale: Locale, voice: AVSpeechSynthesisVoice) async throws -> String {
        let transcriber = AppleSpeechConfiguration.transcriber(locale: locale)
        try await AppleSpeechAssetPreparation.prepare(transcriber, locale: locale)
        let synthesizer = AVSpeechSynthesizer()
        defer { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: source)
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
            guard failures.messages.isEmpty else { throw NativeSpeechFailure.failed("Production PCM converter reported a failure") }
            return final
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
