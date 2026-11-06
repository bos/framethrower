import Darwin
import Foundation
@preconcurrency import AVFoundation
import Speech

private enum VoiceIntegrationFailure: Error { case failed(String) }

private actor NativeDirectorTransport {
    private(set) var payloads: [Data] = []
    func send(_ payload: Data) async throws -> Data {
        payloads.append(payload)
        return try await LocalModelRuntime.shared.chat(payload: payload)
    }
}

/// Actual local synthesis → production PCM conversion and dictation → Director
/// session → native model → project metadata. No microphone, speaker, audio file,
/// video source, capture, decoder, encoder, or app UI is used.
@main @MainActor
struct DirectorVoiceIntegrationChecks {
    static let panInstruction = "Pan box one to box three over the next three seconds."
    static let replacementAnswer = "Let's have the new movement replace it."
    static var whisperHelper: URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--whisper-helper"),
              index + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }

    static func main() async {
        defer { LocalModelRuntime.terminateOwnedProcess() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-director-voice-" + UUID().uuidString)
        do {
            guard MediaProcessing.isSuspended else { throw VoiceIntegrationFailure.failed("Requires suspended video") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            output("Voice integration artifacts: " + directory.path)
            DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
                FileHandle.standardError.write(Data("Voice integration exceeded 240 seconds. Artifacts: \(directory.path)\n".utf8))
                LocalModelRuntime.terminateOwnedProcess()
                Darwin.exit(1)
            }
            guard #available(macOS 26, *),
                  let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")),
                  await DictationTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }),
                  let voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha") else {
                throw VoiceIntegrationFailure.failed("Requires existing on-device English dictation assets and local Samantha voice; no download started")
            }
            let panPCM = try await synthesize(panInstruction, voice: voice)
            let answerPCM = try await synthesize(replacementAnswer, voice: voice)
            try await checkDirectMovement(panPCM, locale: locale, directory: directory.appendingPathComponent("direct"))
            try await checkConflictReplacement(panPCM, answerPCM: answerPCM, locale: locale,
                directory: directory.appendingPathComponent("conflict"))
            output("Director voice integration passed (native PCM/ASR/model, unmodified recognition including mistakes, exact movement, manual history context, conflict answer, frozen timing and durable Undo/Redo; no microphone/playback/audio files/video).")
        } catch {
            FileHandle.standardError.write(Data("Director voice integration failed: \(error). Artifacts retained: \(directory.path)\n".utf8))
            LocalModelRuntime.terminateOwnedProcess()
            Darwin.exit(1)
        }
    }

    static func output(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw VoiceIntegrationFailure.failed(message) }
    }
    static func settle(_ session: EditorAssistantSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(100))
        while session.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try require(!session.isBusy, "Native Director request timed out")
        try require(session.errorMessage == nil, "Director rejected the request: " + (session.errorMessage ?? ""))
    }

    @MainActor private final class Fixture {
        let editor: ProjectEditor
        let session: EditorAssistantSession
        let diagnostics: DirectorDiagnostics
        let transport = NativeDirectorTransport()
        let box1: EditorRegion
        let box3: EditorRegion

        init(directory: URL, withConflict: Bool) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "missing-original.mov", cameraFilename: "missing-camera.mov", duration: 14.37)
            project.title = withConflict ? "Voice conflict fixture" : "Voice movement fixture"
            let existingID = UUID()
            if withConflict {
                project.state.zoomKeyframes = [ZoomKeyframe(id: existingID, time: 1, scale: 2,
                    transition: .smooth, duration: 1)]
                project.state.pipKeyframes.append(PIPKeyframe(time: 1,
                    placement: PIPPlacement(x: 0.1, y: 0.2, scale: 0.2), transition: .smooth, duration: 1))
                project.state.cursorStyle.size = 2.5
            }
            box1 = EditorRegion(time: withConflict ? 1 : 0,
                rect: .init(x: 0.1, y: 0.15, width: 0.25, height: 0.3), editID: withConflict ? existingID : nil)
            let box2 = EditorRegion(time: 0, rect: .init(x: 0.4, y: 0.1, width: 0.15, height: 0.2))
            box3 = EditorRegion(time: 0, rect: .init(x: 0.65, y: 0.5, width: 0.25, height: 0.3))
            project.state.regions = [box1, box2, box3]
            project.ensureReferences()
            editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
            guard editor.save() else { throw VoiceIntegrationFailure.failed("Cannot save metadata fixture") }
            diagnostics = DirectorDiagnostics(directory: directory.appendingPathComponent("trace"), byteLimit: 2_000_000)
            let transport = self.transport
            session = EditorAssistantSession(transport: { try await transport.send($0) }, diagnostics: diagnostics,
                persistsConversation: true, conversationStorageURL: directory.appendingPathComponent("conversation.json"))
            session.attach(to: editor)
        }

        var vocabulary: [String] {
            editor.editingState.regions.compactMap { editor.references.boxLabel(for: $0.id) } +
                editor.editingState.timedEdits(includeCamera: true).compactMap { editor.references.editLabel(for: $0.id) }
        }

        func submitRecognized(_ text: String, playhead: Double) async throws {
            try require(session.appendDictation(text), "ASR produced no finished instruction")
            session.submit(editor: editor, playhead: playhead, regionID: nil, editID: nil)
            try await settle(session)
        }

        func checkMotion() throws {
            let points = editor.project.state.zoomKeyframes
            try require(points.count == 2 && abs(points[0].time) < 0.000001 && abs(points[1].time - 3) < 0.000001 &&
                        points[1].transition == .smooth && abs(points[1].duration - 3) < 0.000001,
                        "Model must create one direct movement from the playhead through exactly three seconds")
            try require(editor.project.state.zoom(at: 0) == box1.rect.framing() &&
                        editor.project.state.zoom(at: 3) == box3.rect.framing(), "Spoken Box 1 and Box 3 must be the actual endpoints")
            try require(try ProjectEditor.open(url: editor.url).project.state == editor.project.state,
                        "Native voice change must persist as ordinary project metadata")
        }
    }

    @available(macOS 26, *)
    static func checkDirectMovement(_ buffers: [AVAudioPCMBuffer], locale: Locale, directory: URL) async throws {
        let fixture = try Fixture(directory: directory, withConflict: false)
        let original = fixture.editor.project.state
        fixture.session.beginVoiceInstruction()
        let text = try await recognize(buffers, locale: locale, fixture: fixture)
        output("Direct ASR, unmodified: " + text)
        try await fixture.submitRecognized(text, playhead: 0)
        try require(!fixture.session.awaitsClarification, "Complete named-box request must not ask a redundant question: " + (fixture.session.notice ?? ""))
        try fixture.checkMotion()
        let applied = fixture.editor.project.state
        try require(fixture.editor.project.undoHistory.count == 1 && fixture.editor.undo() && fixture.editor.project.state == original &&
                    fixture.editor.redo() && fixture.editor.project.state == applied, "One Undo/Redo must cover the complete voice movement")

        var resized = fixture.editor.project.state
        resized.cursorStyle.size = 2.75
        try require(fixture.editor.commit(resized, name: "Resize pointer") && fixture.editor.undo() && fixture.editor.redo(),
                    "Manual pointer resize and native undo/redo must be recorded")
        fixture.session.instruction = "Undo the pointer resize."
        fixture.session.submit(editor: fixture.editor, playhead: 9.6, regionID: nil, editID: nil)
        try await settle(fixture.session)
        try require(!fixture.session.awaitsClarification && fixture.editor.project.state.cursorStyle == applied.cursorStyle &&
                    fixture.editor.project.state.zoomKeyframes == applied.zoomKeyframes,
                    "The native model must understand the manual pointer operation without undoing the voice pan")
        let payloads = await fixture.transport.payloads
        try require(payloads.count >= 2, "Pointer undo followup must reach the native model")
        let payload = try JSONSerialization.jsonObject(with: payloads.last!) as! [String: Any]
        let contents = (payload["messages"] as! [[String: Any]]).compactMap { $0["content"] as? String }.joined(separator: "\n")
        try require(contents.contains("Resize pointer") && contents.contains("\"app_event\"") &&
                    contents.contains("\"kind\":\"undo\"") && contents.contains("\"kind\":\"redo\""),
                    "Native followup payload must contain actual manual edits, undo and redo events")
        fixture.session.instruction = "Redo"
        fixture.session.submit(editor: fixture.editor, playhead: 9.6, regionID: nil, editID: nil)
        try await settle(fixture.session)
        try require(fixture.editor.project.state.cursorStyle.size == 2.75, "Ordinary Redo must restore the manual pointer resize")
        output("Direct voice movement and manual-history followup passed.")
    }

    @available(macOS 26, *)
    static func checkConflictReplacement(_ buffers: [AVAudioPCMBuffer], answerPCM: [AVAudioPCMBuffer],
                                         locale: Locale, directory: URL) async throws {
        let fixture = try Fixture(directory: directory, withConflict: true)
        let original = fixture.editor.project
        fixture.session.beginVoiceInstruction()
        let text = try await recognize(buffers, locale: locale, fixture: fixture)
        output("Conflict ASR, unmodified: " + text)
        try await fixture.submitRecognized(text, playhead: 0)
        try require(fixture.session.awaitsClarification && fixture.editor.project == original && !fixture.editor.canUndo,
                    "Existing framing must produce a real pending conflict without changing the recording")
        fixture.session.beginVoiceInstruction()
        let answer = try await recognize(answerPCM, locale: locale, fixture: fixture)
        output("Replacement ASR, unmodified: " + answer)
        try await fixture.submitRecognized(answer, playhead: 9.6)
        try require(!fixture.session.awaitsClarification, "Replacement answer must complete instead of repeating the question: " + (fixture.session.notice ?? ""))
        try fixture.checkMotion()
        let replaced = fixture.editor.project.state
        try require(replaced.pipKeyframes == original.state.pipKeyframes && replaced.cursorStyle == original.state.cursorStyle &&
                    replaced.regions == original.state.regions && fixture.editor.project.title == original.title,
                    "Replacing screen motion must preserve camera, pointer, reference boxes and title")
        try require(fixture.editor.project.undoHistory.count == 1 && fixture.editor.undo() && fixture.editor.project.state == original.state &&
                    fixture.editor.redo() && fixture.editor.project.state == replaced,
                    "Conflict replacement must be one durable Undo/Redo operation at the original zero-to-three-second timing")
        output("Actual spoken conflict question and replacement answer passed.")
    }

    @available(macOS 26, *)
    static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice) async throws -> [AVAudioPCMBuffer] {
        let synthesizer = AVSpeechSynthesizer()
        defer { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let collection = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IntegrationPCM, any Error>) in
            let collector = IntegrationPCM(continuation: continuation)
            synthesizer.write(utterance) { collector.receive($0) }
        }
        return collection.buffers
    }

    @available(macOS 26, *)
    private static func recognize(_ buffers: [AVAudioPCMBuffer], locale: Locale, fixture: Fixture) async throws -> String {
        if let whisperHelper {
            let speech = LocalSpeechInput(makeSession: {
                WhisperLocalSpeechSession(executable: whisperHelper, syntheticBuffers: buffers)
            })
            await speech.start()
            fixture.session.recordSpeechState(phase: String(describing: speech.phase),
                recognizer: speech.recognizerIdentifier, status: speech.statusMessage, error: speech.errorMessage)
            try require(speech.phase == .listening && speech.errorMessage == nil,
                        "Whisper must prepare through the production controller: " + (speech.errorMessage ?? ""))
            let text = await speech.finish()
            fixture.session.recordSpeechState(phase: String(describing: speech.phase),
                recognizer: speech.recognizerIdentifier, status: speech.statusMessage, error: speech.errorMessage)
            try require(speech.recognizerIdentifier == "whisper.cpp large-v3-turbo Q5_0 (Metal)" &&
                        speech.errorMessage == nil && text?.isEmpty == false,
                        "Verified Metal recognition must finish without fallback or word substitutions: " + (speech.errorMessage ?? ""))
            fixture.session.recordSpeechHypothesis(text!, phase: "final")
            return text!
        }
        let transcriber = AppleSpeechConfiguration.transcriber(locale: locale)
        try await AppleSpeechAssetPreparation.prepare(transcriber, locale: locale)
        guard let first = buffers.first,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: first.format),
              let converter = AVAudioConverter(from: first.format, to: format) else { throw VoiceIntegrationFailure.failed("Cannot configure native speech PCM conversion") }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await AppleSpeechConfiguration.configure(analyzer, contextualStrings: fixture.vocabulary)
        try await analyzer.prepareToAnalyze(in: format)
        let results = Task { @MainActor in
            var transcript = SpeechTranscript()
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                fixture.session.recordSpeechHypothesis(text, phase: result.isFinal ? "final" : "partial")
                transcript.receive(.init(start: result.range.start.seconds, duration: result.range.duration.seconds, text: text, isFinal: result.isFinal))
            }
            return transcript.finalText
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let failures = IntegrationFeedFailures()
        let feed = SpeechAudioFeed(converter: converter, outputFormat: format, continuation: continuation, onFailure: { failures.record($0) })
        for buffer in buffers { feed.receive(buffer) }
        feed.finish()
        do {
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let text = try await results.value
            try require(failures.isEmpty && !text.isEmpty, "Native speech must finish with usable final words and no PCM errors")
            return text
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

private final class IntegrationPCM: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<IntegrationPCM, any Error>?
    private var values: [AVAudioPCMBuffer] = []
    var buffers: [AVAudioPCMBuffer] { lock.lock(); defer { lock.unlock() }; return values }
    init(continuation: CheckedContinuation<IntegrationPCM, any Error>) { self.continuation = continuation }
    func receive(_ buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            self.continuation = nil
            continuation.resume(throwing: VoiceIntegrationFailure.failed("Synthesis did not return PCM")); return
        }
        if pcm.frameLength == 0 { self.continuation = nil; continuation.resume(returning: self); return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength) else {
            self.continuation = nil
            continuation.resume(throwing: VoiceIntegrationFailure.failed("Cannot retain synthetic PCM")); return
        }
        copy.frameLength = pcm.frameLength
        for (destination, source) in zip(UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList), UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)) {
            if let to = destination.mData, let from = source.mData { to.copyMemory(from: from, byteCount: Int(min(destination.mDataByteSize, source.mDataByteSize))) }
        }
        values.append(copy)
    }
}

private final class IntegrationFeedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return values.isEmpty }
}
