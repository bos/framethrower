import Foundation

@main
@MainActor
struct RecordingAudioChecks {
    enum Failure: Error { case failed(String) }

    static func main() throws {
        try curves()
        try migration()
        try editing()
        print("Recording audio checks passed (source-time gain curves, trim clamping, legacy history migration, validation, atomic persistence, single-step Undo/Redo, cancellation, original bytes preserved).")
    }

    private static func curves() throws {
        let defaults = RecordingAudio()
        try require(defaults.envelope(trimStart: 2, trimEnd: 10) == [.init(time: 2, volume: 1), .init(time: 10, volume: 1)],
                    "defaults retain full level without fades")
        var audio = RecordingAudio(volume: 0.8, fadeIn: 1.5, fadeOut: 2.5)
        let points = audio.envelope(trimStart: 2, trimEnd: 10)
        try require(points == [.init(time: 2, volume: 0), .init(time: 3.5, volume: 0.8),
                               .init(time: 7.5, volume: 0.8), .init(time: 10, volume: 0)],
                    "gain points follow source trim boundaries")
        try near(gain(points, at: 2.75), 0.4, "linear fade in")
        try near(gain(points, at: 5), 0.8, "constant middle")
        try near(gain(points, at: 8.75), 0.4, "linear fade out")
        audio.fadeIn = 1; audio.fadeOut = 3
        let short = audio.effectiveFades(duration: 0.5)
        try near(short.fadeIn, 0.125, "shortened incoming fade")
        try near(short.fadeOut, 0.375, "shortened outgoing fade")
        let shortened = audio.envelope(trimStart: 5, trimEnd: 5.5)
        try require(shortened == [.init(time: 5, volume: 0), .init(time: 5.125, volume: 0.8), .init(time: 5.5, volume: 0)],
                    "overlapping fades meet at full gain without a discontinuity")
        try near(gain(shortened, at: 5.0625), 0.4, "short incoming curve")
        try near(gain(shortened, at: 5.3125), 0.4, "short outgoing curve")
        try require(audio.fadeIn == 1 && audio.fadeOut == 3, "effective clamp preserves requested settings")
        audio.isMuted = true
        try require(audio.envelope(trimStart: 0, trimEnd: 8).allSatisfy { $0.volume == 0 }, "mute covers every envelope point")
        audio.isMuted = false; audio.volume = 0
        try require(audio.envelope(trimStart: 0, trimEnd: 8).allSatisfy { $0.volume == 0 }, "zero volume is silence")
        for range in [(Double.nan, 4.0), (0.0, Double.infinity), (2.0, 1.0), (-1.0, 5.0)] {
            try require(audio.envelope(trimStart: range.0, trimEnd: range.1).isEmpty, "invalid trim produces no ramps")
        }
        for duration in [0.00001, 0.125, 1, 4, 12] {
            for incoming in [0.0, 0.3, 5] {
                for outgoing in [0.0, 0.7, 5] {
                    let audio = RecordingAudio(volume: 0.7, fadeIn: incoming, fadeOut: outgoing)
                    let points = audio.envelope(trimStart: 2, trimEnd: 2 + duration)
                    try require(points.count >= 2 && points.first?.time == 2 && points.last?.time == 2 + duration,
                                "all curves span the kept trim")
                    try require(zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time }, "ramp times strictly increase")
                    try require(points.allSatisfy { $0.volume.isFinite && (0...0.7).contains($0.volume) }, "gain stays bounded")
                }
            }
        }
    }

    private static func migration() throws {
        var project = RecordingProject(screenFilename: "untouched.txt", duration: 12)
        project.undoHistory = [NamedEditSnapshot(name: "Earlier", state: project.state)]
        project.redoHistory = [NamedEditSnapshot(name: "Later", state: project.state)]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        var state = object["state"] as! [String: Any]
        state.removeValue(forKey: "audio")
        object["state"] = state
        for key in ["undoHistory", "redoHistory"] {
            var history = object[key] as! [[String: Any]]
            for index in history.indices { history[index]["state"] = state }
            object[key] = history
        }
        let legacy = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: object))
        try legacy.validate()
        try require(legacy == project, "old current, Undo and Redo states migrate to identity audio")
        for bad in [RecordingAudio(volume: -0.1), RecordingAudio(volume: 1.01), RecordingAudio(volume: .nan),
                    RecordingAudio(fadeIn: -1), RecordingAudio(fadeIn: 5.01), RecordingAudio(fadeOut: .infinity)] {
            var invalid = project
            invalid.state.audio = bad
            try rejects(invalid, "invalid audio state")
            invalid = project
            invalid.undoHistory[0].state.audio = bad
            try rejects(invalid, "invalid audio in Undo")
            invalid = project
            invalid.redoHistory[0].state.audio = bad
            try rejects(invalid, "invalid audio in Redo")
        }
    }

    private static func editing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("untouched.txt")
        let originalBytes = Data("Original sentinel text; no audio or video media is opened.".utf8)
        try originalBytes.write(to: original)
        let url = directory.appendingPathComponent("recording.framethrower")
        let editor = ProjectEditor(project: RecordingProject(screenFilename: original.lastPathComponent, duration: 12), url: url)
        try require(editor.save(), "save initial metadata")
        let initial = editor.project
        let initialBytes = try Data(contentsOf: url)
        var next = initial.state
        for step in 0...200 {
            next.audio.volume = Double(step) / 250
            next.audio.fadeIn = 1
            next.audio.fadeOut = 3
            try require(editor.updateDraft(next, at: 2), "preview master audio gesture")
        }
        try require(editor.project == initial && (try Data(contentsOf: url)) == initialBytes,
                    "drag samples leave saved metadata and history unchanged")
        try require(editor.finishDraft(name: "Change recording volume"), "commit gesture")
        let edited = editor.project
        try require(edited.undoHistory.count == 1 && edited.state == next, "one gesture creates one Undo entry")
        try require(editor.undo() && editor.project.state == initial.state, "single Undo restores all audio controls")
        try require(editor.redo() && editor.project.state == next, "single Redo restores all audio controls")
        let reopened = try ProjectEditor.open(url: url)
        try require(reopened.project == editor.project, "audio and its history persist exactly")

        var trimmed = next
        trimmed.trimStart = 5; trimmed.trimEnd = 5.5
        try require(editor.commit(trimmed, name: "Trim"), "shorten kept trim")
        try near(editor.project.state.audio.effectiveFades(duration: 0.5).fadeOut, 0.375, "short trim uses clamped fades")
        try require(editor.project.state.audio == next.audio, "trim does not rewrite audio settings")
        try require(editor.undo() && editor.project.state == next, "Undo trim restores requested fade room")
        try near(editor.project.state.audio.effectiveFades(duration: 12).fadeOut, 3, "restored trim restores full fade")
        var muted = editor.project.state
        muted.audio.isMuted = true
        try require(editor.commit(muted, name: "Mute recording"), "mute recording")
        try require(!editor.canRedo && editor.project.state.audio.volume == 0.8, "mute preserves volume and replaces Redo branch")
        try require(editor.undo() && editor.project.state.audio == next.audio, "Undo mute preserves all other settings")
        var cancelled = editor.project.state
        cancelled.audio.fadeIn = 4
        let beforeCancel = editor.project
        try require(editor.updateDraft(cancelled, at: 2) && editor.cancelDraft() && editor.project == beforeCancel,
                    "Escape discards audio gesture without replacing history")
        var invalid = editor.project.state
        invalid.audio.volume = 2
        try require(!editor.commit(invalid, name: "Invalid audio") && editor.project == beforeCancel,
                    "invalid audio never reaches disk or history")
        try require(try Data(contentsOf: original) == originalBytes, "all audio edits leave source bytes intact")

        let blockedURL = directory.appendingPathComponent("blocked.framethrower")
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: false)
        let blocked = ProjectEditor(project: initial, url: blockedURL)
        try require(blocked.updateDraft(next, at: 2) && !blocked.finishDraft(name: "Change recording volume"), "failed write is reported")
        try require(blocked.project == initial && blocked.draftState == next && blocked.project.undoHistory.isEmpty,
                    "failed write retains unsaved gesture and original history")
    }

    private static func gain(_ points: [RecordingAudio.Point], at time: Double) -> Double {
        for (start, end) in zip(points, points.dropFirst()) where time >= start.time && time <= end.time {
            return start.volume + (end.volume - start.volume) * (time - start.time) / (end.time - start.time)
        }
        return 0
    }

    private static func rejects(_ project: RecordingProject, _ message: String) throws {
        do { try project.validate() }
        catch { return }
        throw Failure.failed(message)
    }

    private static func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try require(abs(actual - expected) < 0.000001, "\(message): \(actual) != \(expected)")
    }

    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.failed(message) }
    }
}
