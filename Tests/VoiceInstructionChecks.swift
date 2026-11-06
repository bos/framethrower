import Darwin
import Foundation

private enum VoiceCheckFailure: Error { case failed(String) }
private enum VoiceFixtureError: LocalizedError {
    case disconnected
    var errorDescription: String? { "The fixture microphone was disconnected." }
}

@MainActor
private final class FixtureSpeechSession: LocalSpeechSession {
    var result: (@MainActor (SpeechTranscript.Segment) -> Void)?
    var startAction: (@MainActor () async -> Void)?
    var finishAction: (@MainActor () async throws -> Void)?
    var starts = 0
    var finishes = 0
    var cancellations = 0

    func start(onResult: @escaping @MainActor (SpeechTranscript.Segment) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) async throws {
        starts += 1
        result = onResult
        await startAction?()
    }
    func finish() async throws { finishes += 1; try await finishAction?() }
    func cancel() async { cancellations += 1 }
    func emit(_ text: String, final: Bool) {
        result?(.init(start: 0, duration: 1, text: text, isFinal: final))
    }
}

private actor FixtureTransport {
    private(set) var payloads: [Data] = []
    func send(_ payload: Data) throws -> Data {
        payloads.append(payload)
        let arguments = try JSONSerialization.data(withJSONObject: ["question": "Which edit should change?"])
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["tool_calls": [[
            "type": "function", "function": ["name": "ask_clarification", "arguments": String(decoding: arguments, as: UTF8.self)]
        ]]]]]])
    }
}

@MainActor
private final class InteractionState {
    var deliveries = 0
    var delivered: [String] = []
}

/// Exercises finalized speech → instruction draft → assistant → transport.
/// Speech and model transports are fake; native UI button activation is outside
/// this check. No microphone, speaker, speech model, language model, or video is used.
@main @MainActor
struct VoiceInstructionChecks {
    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            FileHandle.standardError.write(Data("Voice instruction check exceeded 15 seconds.\n".utf8))
            Darwin.exit(1)
        }
        do {
            guard MediaProcessing.isSuspended else { throw VoiceCheckFailure.failed("Requires media interlock") }
            try await checkFinalInstruction()
            try await checkPartialOnly()
            try await checkFailure()
            try await checkCancellation()
            print("Voice instruction checks passed (controller → finalized transcript → draft → assistant → transport; one submission, typed-draft preservation, partial/error/cancel suppression; UI button activation unverified, no microphone/model/media).")
        } catch {
            FileHandle.standardError.write(Data("Voice instruction check failed: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func checkFinalInstruction() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.session.instruction = "At Edit A,"
        await fixture.speech.start()
        try require(fixture.speech.phase == .listening, "Fake speech starts without a microphone")
        fixture.mock.emit("zoom into", final: false)
        try require(fixture.state.deliveries == 0 && fixture.session.instruction == "At Edit A,",
                    "Partial words must not replace or submit the typed draft")
        fixture.session.instruction += " please"
        fixture.mock.finishAction = { [mock = fixture.mock] in
            mock.emit("zoom into Box 1.", final: true)
            mock.emit("zoom into Box 1.", final: true)
        }
        await fixture.finishAndApply()
        try await wait { fixture.state.deliveries == 1 && !fixture.session.isBusy }
        let payloads = await fixture.transport.payloads
        try require(fixture.mock.finishes == 1 && fixture.state.delivered == ["zoom into Box 1."] && payloads.count == 1,
                    "Stop must deliver the final transcript and submit exactly once")
        let object = try JSONSerialization.jsonObject(with: payloads[0]) as! [String: Any]
        let messages = object["messages"] as! [[String: String]]
        try require(messages.last?["content"]?.contains("At Edit A, please zoom into Box 1.") == true,
                    "Automatic submission must preserve text typed before and during dictation")
        let repeated = await fixture.speech.finish()
        try require(repeated == nil && fixture.state.deliveries == 1 && !fixture.editor.canUndo,
                    "An utterance cannot be delivered twice, and fixture clarification cannot edit the recording")
    }

    private static func checkPartialOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.session.instruction = "Typed instruction."
        await fixture.speech.start()
        fixture.mock.emit("unconfirmed words", final: false)
        await fixture.finishAndApply()
        try await wait { fixture.speech.phase == .idle }
        let calls = await fixture.transport.payloads.count
        try require(calls == 0 && fixture.state.deliveries == 0 && fixture.session.instruction == "Typed instruction." && fixture.speech.errorMessage != nil,
                    "Stopping with only a partial result must preserve the draft and submit nothing")
    }

    private static func checkFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.session.instruction = "Typed instruction."
        await fixture.speech.start()
        fixture.mock.finishAction = { throw VoiceFixtureError.disconnected }
        await fixture.finishAndApply()
        try await wait { fixture.speech.phase == .idle }
        let calls = await fixture.transport.payloads.count
        try require(calls == 0 && fixture.state.deliveries == 0 && fixture.session.instruction == "Typed instruction." && fixture.speech.errorMessage == VoiceFixtureError.disconnected.localizedDescription,
                    "Recognition failure must not auto-submit or clear the typed draft")
    }

    private static func checkCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var resume: CheckedContinuation<Void, Never>?
        fixture.mock.startAction = { await withCheckedContinuation { resume = $0 } }
        let start = Task { await fixture.speech.start() }
        try await wait { fixture.speech.phase == .preparing && resume != nil }
        await fixture.speech.cancel()
        resume?.resume()
        await start.value
        fixture.mock.emit("late final after cancellation", final: true)
        try await Task.sleep(for: .milliseconds(30))
        let calls = await fixture.transport.payloads.count
        try require(calls == 0 && fixture.state.deliveries == 0 && fixture.mock.cancellations > 0 && fixture.speech.transcript.isEmpty,
                    "Cancelling preparation must reject late speech results and submit nothing")
    }

    private static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw VoiceCheckFailure.failed("Timed out waiting for voice interaction")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VoiceCheckFailure.failed(message) }
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let editor: ProjectEditor
        let mock = FixtureSpeechSession()
        let speech: LocalSpeechInput
        let session: EditorAssistantSession
        let transport = FixtureTransport()
        let state = InteractionState()

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var project = RecordingProject(screenFilename: "missing.mov", duration: 12)
            let editID = UUID()
            let region = EditorRegion(time: 1, rect: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.2), editID: editID)
            project.state.editAnchors = [EditAnchor(id: editID, time: 1)]
            project.state.regions = [region]
            let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("recording.framethrower"))
            self.editor = editor
            let transport = self.transport
            let session = EditorAssistantSession(transport: { try await transport.send($0) })
            self.session = session
            let mock = self.mock
            speech = LocalSpeechInput(makeSession: { mock })
        }

        func finishAndApply() async {
            guard let text = await speech.finish() else { return }
            state.deliveries += 1
            state.delivered.append(text)
            if session.appendDictation(text) {
                let region = editor.project.state.regions[0]
                session.submit(editor: editor, playhead: 1, regionID: region.id, editID: region.editID)
            }
        }

        func close() {
            session.cancel()
            try? FileManager.default.removeItem(at: directory)
        }

    }
}
