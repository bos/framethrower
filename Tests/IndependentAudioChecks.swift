import Foundation

private struct AudioFailure: Error { var message: String }
@main @MainActor
struct IndependentAudioChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AudioFailure(message: message) }
    }
    static func near(_ a: Double, _ b: Double, _ message: String) throws { try require(abs(a - b) < 0.000001, message) }
    static func project() -> RecordingProject {
        RecordingProject(screenFilename: "unopened.data", duration: 20,
            audioSources: [.init(role: .microphone), .init(role: .systemAudio)])
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "Media remains suspended")
        try mutationAndIsolation(); try curvesAndCutClocks(); try sampledRampsAndJumps(); try timelineEditing(); try persistenceAndMigration()
        print("Independent audio checks passed: explicit role bindings, independent mute/level/envelopes, shared curves/source-output clocks, exact jumps, bounded ramp projection, shared timeline timing, legacy migration and durable atomic Undo/Redo. No media objects or source audio.")
    }
    static func mutationAndIsolation() throws {
        let project = project(); var state = project.state
        let bindings = project.audioSources
        for ordered in [bindings, Array(bindings.reversed())] {
            for role in RecordingAudioRole.allCases {
                try require(RecordingAudioSource.resolve(identifier: role.metadataIdentifier, value: role.rawValue, bindings: ordered) == role,
                    "Renderer resolver uses marker key AND value, independent of binding/track order")
            }
        }
        try require(RecordingAudioSource.resolve(identifier: "unknown", value: "microphone", bindings: bindings) == nil &&
            RecordingAudioSource.resolve(identifier: RecordingAudioRole.microphone.metadataIdentifier, value: "mixed", bindings: bindings) == nil &&
            RecordingAudioSource.resolve(identifier: RecordingAudioRole.microphone.metadataIdentifier, value: "microphone", bindings: [bindings[0], bindings[0]]) == nil,
            "Unknown/mixed/ambiguous source metadata never guesses roles")
        try EditorMutation.audioTrack(role: .microphone, patch: .init(volume: 0.4)).apply(to: &state, project: project)
        try require(state.audio.channel(.systemAudio) == project.state.audio.channel(.systemAudio) && state.audio.volume == 1, "Role patch preserves other role/master")
        let ramp = EditorMutation.audioGain(role: .microphone, gain: 0.2, timing: .init(start: 2, end: 5, easeIn: 0.7, easeOut: 1))
        try ramp.apply(to: &state, project: project)
        try EditorMutation.audioGain(role: .systemAudio, gain: 0, timing: .init(start: 2, end: 5)).apply(to: &state, project: project)
        let before = state
        do { try EditorMutation.audioGain(role: .microphone, gain: 0.6, timing: .init(start: 3, end: 6)).apply(to: &state, project: project); throw AudioFailure(message: "Same-role overlap accepted") }
        catch is EditorMutationError {}
        try require(state == before, "Rejected overlap is atomic")
        let id = state.audio.channel(.microphone).points[0].id
        try EditorMutation.audioGain(role: .microphone, gain: 0.3, timing: .init(start: 2, end: 5), id: id).apply(to: &state, project: project)
        try require(state.audio.channel(.microphone).points.count == 1 && state.audio.channel(.microphone).points[0].id == id, "Update retains source identity")
        try EditorMutation.audioTrack(role: .microphone, patch: .init(isMuted: true)).apply(to: &state, project: project)
        try near(state.audio.channel(.microphone).gain(at: 4), 0, "Role mute")
        try EditorMutation.audioTrack(role: .microphone, patch: .init(isMuted: false)).apply(to: &state, project: project)
        try require(state.audio.channel(.microphone).points[0].gain == 0.3, "Unmute retains envelope")
        let legacy = RecordingProject(screenFilename: "unopened.data", duration: 20)
        var untouched = legacy.state
        do { try EditorMutation.audioTrack(role: .microphone, patch: .init(volume: 0.2)).apply(to: &untouched, project: legacy); throw AudioFailure(message: "Inferred legacy role") }
        catch is EditorMutationError {}
        try require(untouched == legacy.state, "Unknown legacy source never bound by guessed track index")
        let encoded = try JSONEncoder().encode(ramp)
        try require(try JSONDecoder().decode(EditorMutation.self, from: encoded) == ramp, "Strict typed mutation roundtrip")
        let bad = Data("{\"operation\":\"audioTrack\",\"role\":\"microphone\",\"patch\":{\"volume\":0.5,\"fadeOut\":2}}".utf8)
        do { _ = try JSONDecoder().decode(EditorMutation.self, from: bad); throw AudioFailure(message: "Unexpected role fields accepted") } catch is EditorMutationError {}
    }
    static func curvesAndCutClocks() throws {
        var p = project(), state = p.state
        try EditorMutation.audioGain(role: .microphone, gain: 0.2, timing: .init(start: 2, end: 8, easeIn: 1, easeOut: 2)).apply(to: &state, project: p)
        state.audio.volume = 0.8; state.audio.updateChannel(.microphone) { $0.volume = 0.5 }
        for tick in 0...100 {
            let time = Double(tick) / 5
            let progress = MotionInterpolation.progress(at: time, from: 0, to: 8, duration: 6, transition: .smooth, easeIn: 1, easeOut: 2)
            let expected = time >= 8 ? 0.2 : 1 - 0.8 * progress
            try near(state.audio.channel(.microphone).envelopeGain(at: time), expected, "Actual shared motion curve")
        }
        state.cuts = [.init(start: 4, end: 6, crossfade: 1)]
        let map = try RecordingTimeMap(duration: p.duration, trimStart: 0, trimEnd: 20, cuts: state.cuts)
        let samples = map.samples(at: 3.5)
        try require(samples.count == 2 && samples[0].sourceTime == 3.5 && samples[1].sourceTime == 6.5, "Distinct original-source clocks during overlap")
        let gains = samples.map { sample in state.audio.gain(role: .microphone, sourceTime: sample.sourceTime, outputTime: 3.5, outputDuration: map.outputDuration) * sample.weight }
        try require(gains[0] > gains[1], "Role envelope evaluated separately on outgoing/incoming source")
        try near(state.audio.gain(role: .systemAudio, sourceTime: 7, outputTime: 3.5, outputDuration: map.outputDuration), 0.8, "Other role unaffected by microphone envelope")
        state.audio.fadeIn = 4
        try near(state.audio.gain(role: nil, sourceTime: 8, outputTime: 2, outputDuration: map.outputDuration), 0.4, "Master fades follow output clock, not skipped source time")
        p.state = state; try p.validate()
    }
    static func sampledRampsAndJumps() throws {
        let point = RecordingAudioGainPoint(time: 8, gain: 0.1, duration: 6, easeIn: 0.7, easeOut: 2)
        var audio = RecordingAudio(channels: [.init(role: .microphone, points: [point])])
        let gain: (Double) -> Double = { audio.gain(role: .microphone, sourceTime: $0, outputTime: $0, outputDuration: 20) }
        let points = RecordingAudio.sampledEnvelope(knots: [0, 20] + audio.sourceKnots(role: .microphone), gain: gain)
        for tick in 0...2000 {
            let time = Double(tick) / 100
            let pair = zip(points, points.dropFirst()).first { $0.time <= time && $1.time >= time && $1.time > $0.time }
            guard let (a, b) = pair else { continue }
            let projected = a.volume + (b.volume - a.volume) * (time - a.time) / (b.time - a.time)
            try require(abs(projected - gain(time)) < 0.00012, "Projected audio ramps follow full nonlinear curve")
        }
        audio.channels[0].points = [.init(time: 5, gain: 0.2, transition: .jump)]
        let steps = RecordingAudio.sampledEnvelope(knots: [0, 5, 10]) { audio.channel(.microphone).gain(at: $0) }
        try require(steps.contains(.init(time: 5, volume: 1)) && steps.contains(.init(time: 5, volume: 0.2)), "No anticipatory fade before instantaneous gain jump")
    }
    static func timelineEditing() throws {
        let p = project(); var state = p.state
        try EditorMutation.audioGain(role: .microphone, gain: 0.2, timing: .init(start: 2, end: 5)).apply(to: &state, project: p)
        try EditorMutation.audioGain(role: .systemAudio, gain: 0.8, timing: .init(start: 2, end: 5)).apply(to: &state, project: p)
        let spans = EditorAnimationEditing.animations(in: state, references: p.references, duration: 20)
        let span = spans.first { $0.lane == .audioMicrophone }!
        let drag = AnimationDrag(id: span.id, handle: .move, deltaSeconds: 3)
        let changes = TimelineAnimationSolver.solve(drag, animations: spans, duration: 20)!
        let edited = EditorAnimationEditing.applying(changes, to: state, duration: 20)!.state
        try require(edited.audio.channel(.microphone).points[0].time == 8 && edited.audio.channel(.microphone).points[0].duration == 3, "Shared timeline body drag preserves duration and stable point ID")
        try require(edited.audio.channel(.systemAudio) == state.audio.channel(.systemAudio) && edited.zoomKeyframes == state.zoomKeyframes, "Independent lanes and screen preserved")
    }
    static func persistenceAndMigration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("independent-audio-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("unopened.data"), bytes = Data("Original metadata sentinel".utf8)
        try bytes.write(to: source)
        let editor = ProjectEditor(project: project(), url: folder.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "Save role bindings")
        let original = editor.project
        var next = original.state
        try EditorMutation.audioGain(role: .microphone, gain: 0, timing: .init(start: 1, end: 3)).apply(to: &next, project: original)
        try require(editor.updateDraft(next, at: 3) && editor.finishDraft(name: "Fade microphone"), "One draft gesture commit")
        let changed = editor.project
        try require(changed.undoHistory.count == 1 && editor.undo() && editor.project.state == original.state, "One Undo")
        try require(editor.redo() && editor.project.state == changed.state, "One Redo")
        try require(try ProjectEditor.open(url: editor.url).project == editor.project && Data(contentsOf: source) == bytes, "Durable roles/envelope/history with immutable original")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RecordingAudio())) as! [String: Any]
        json.removeValue(forKey: "channels")
        let legacy = try JSONDecoder().decode(RecordingAudio.self, from: JSONSerialization.data(withJSONObject: json))
        try require(legacy == RecordingAudio(), "Legacy master audio decoding unchanged")
        var invalid = changed; invalid.audioSources = []
        do { try invalid.validate(); throw AudioFailure(message: "Dangling role binding accepted") } catch is ProjectError {}
    }
}
