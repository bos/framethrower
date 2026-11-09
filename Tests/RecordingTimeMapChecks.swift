import Foundation

private struct TimeMapFailure: Error { let message: String }
@main @MainActor
struct RecordingTimeMapChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TimeMapFailure(message: message) }
    }
    static func close(_ a: Double, _ b: Double, _ message: String) throws {
        try require(abs(a - b) <= 1e-10 * max(1, abs(a), abs(b)), message)
    }
    static func reject(_ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw TimeMapFailure(message: "Invalid map accepted")
    }
    static func map(_ cuts: [RecordingCut], start: Double = 0, end: Double = 10) throws -> RecordingTimeMap {
        try RecordingTimeMap(duration: 10, trimStart: start, trimEnd: end, cuts: cuts)
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "No source media may be processed")
        try basicMapping(); try fadeMapping(); try allocationAndTrim(); try invalidMetadata(); try persistence(); try allocationPropertiesAndStress()
        print("Recording time map checks passed: half-open hard cuts, two-source alpha joins, deterministic proportional clamps, tiny sections, trim restoration, validation/migration, durable Undo/Redo and immutable originals; no media.")
    }
    static func basicMapping() throws {
        let plain = try map([], start: 2, end: 9)
        try close(plain.outputDuration, 7, "Trim duration")
        try require(plain.clips.count == 1 && plain.joins.isEmpty && plain.samples(at: 0).first?.sourceTime == 2, "Trim source origin")
        try require(plain.samples(at: 7).first?.sourceTime == 9 && plain.outputTime(for: 9) == 7, "Explicit final endpoint")
        for time in [-1.0, 7.1, .infinity, .nan] { try require(plain.samples(at: time).isEmpty, "Invalid output has no samples") }
        let cut = RecordingCut(start: 4, end: 6)
        let hard = try map([cut], start: 2)
        try close(hard.outputDuration, 6, "Hard cut output duration")
        try require(hard.samples(at: 2) == [.init(clipIndex: 1, sourceTime: 6, weight: 1)], "Hard cut chooses incoming at exact join")
        try require(hard.outputTime(for: 4) == nil && hard.outputTime(for: 5) == nil && hard.outputTime(for: 6) == 2, "Excluded interval half open")
        try require(hard.joins.first?.id == cut.id && hard.joins.first?.duration == 0, "Stable hard join identity")
        try require(hard.outputTime(for: 1) == nil && hard.outputTime(for: 11) == nil, "Source outside trim unmapped")
    }
    static func fadeMapping() throws {
        let cut = RecordingCut(start: 4, end: 6, crossfade: 1)
        let fade = try map([cut], start: 2)
        try close(fade.outputDuration, 5, "Fade consumes retained handles")
        let join = fade.joins[0]
        try require(join.outputStart == 1 && join.outputEnd == 2 && join.outgoingClipIndex == 0 && join.incomingClipIndex == 1, "Join output interval")
        try require(fade.samples(at: 1) == [.init(clipIndex: 0, sourceTime: 3, weight: 1)], "Zero-alpha incoming omitted")
        try require(fade.samples(at: 1.5) == [.init(clipIndex: 0, sourceTime: 3.5, weight: 0.5), .init(clipIndex: 1, sourceTime: 6.5, weight: 0.5)], "Independent branch clocks and normalized linear alpha")
        try require(fade.samples(at: 2) == [.init(clipIndex: 1, sourceTime: 7, weight: 1)], "Outgoing excluded at join end")
        try require(fade.outputTime(for: 3.5) == 1.5 && fade.outputTime(for: 6.5) == 1.5, "Both retained instants map into overlap")
        for tick in 0...500 {
            let samples = fade.samples(at: Double(tick) / 100)
            try require(!samples.isEmpty && samples.count <= 2, "No output gap or triple sample")
            try close(samples.reduce(0) { $0 + $1.weight }, 1, "Alpha normalized")
            for sample in samples {
                let clip = fade.clips[sample.clipIndex]
                try require(sample.sourceTime >= clip.sourceStart && sample.sourceTime <= clip.sourceEnd && sample.weight > 0, "Samples stay in retained clips")
            }
        }
    }
    static func allocationAndTrim() throws {
        let first = RecordingCut(start: 2, end: 3, crossfade: 1)
        let second = RecordingCut(start: 4, end: 5, crossfade: 3)
        let forward = try map([first, second], end: 9), reversed = try map([second, first], end: 9)
        try require(forward == reversed, "Input ordering never changes allocation")
        try close(forward.joins[0].duration, 0.25, "Shared handle proportional first fade")
        try close(forward.joins[1].duration, 0.75, "Shared handle proportional second fade")
        try close(forward.outputDuration, 6, "Both fades consume one shared second")
        let trimmed = try map([first, second], start: 3.75, end: 6)
        try require(trimmed.joins.count == 1 && trimmed.joins[0].requestedDuration == 3, "Invisible join removed but request retained")
        try close(trimmed.joins[0].duration, 0.25, "Trim clamps visible handles only")
        try require(first.crossfade == 1 && second.crossfade == 3 && (try map([first, second], end: 9)) == forward, "Restoring trim restores effective fades without changing requests")
        let tiny = try map([.init(start: 1e-6, end: 2e-6, crossfade: 2), .init(start: 3e-6, end: 4e-6, crossfade: 4)], end: 5e-6)
        for clip in tiny.clips.indices {
            let incoming = clip > 0 ? tiny.joins[clip - 1].duration : 0
            let outgoing = clip < tiny.joins.count ? tiny.joins[clip].duration : 0
            try require(incoming + outgoing <= tiny.clips[clip].sourceEnd - tiny.clips[clip].sourceStart, "Tiny clips cannot triple overlap")
        }
        for tick in 0...1000 {
            let samples = tiny.samples(at: tiny.outputDuration * Double(tick) / 1000)
            try require(!samples.isEmpty && samples.count <= 2, "Tiny output has no holes/triples")
        }
        let frozenNeighbor = try map([.init(start: 0.1, end: 0.2, crossfade: 1), .init(start: 1.2, end: 2, crossfade: 1)])
        try close(frozenNeighbor.joins[0].duration, 0.1, "First clip exhausts handle")
        try close(frozenNeighbor.joins[1].duration, 0.9, "Other fade continues filling after neighbor freezes")
    }
    /// Independent slow water-filling oracle for short randomized clip chains.
    /// Production uses heap events; this directly advances every active edge.
    static func referenceFades(_ requests: [Double], lengths: [Double]) -> [Double] {
        var values = requests.map { _ in 0.0 }
        var active = Set(requests.indices.filter { requests[$0] > 0 })
        while !active.isEmpty {
            var steps: [(Double, [Int])] = active.map { ((requests[$0] - values[$0]) / requests[$0], [$0]) }
            for clip in lengths.indices {
                let edges = [clip - 1, clip].filter { requests.indices.contains($0) }
                let moving = edges.filter { active.contains($0) }
                let slope = moving.reduce(0.0) { $0 + requests[$1] }
                if slope > 0 {
                    let remaining = max(0, lengths[clip] - edges.reduce(0.0) { $0 + values[$1] })
                    steps.append((remaining / slope, moving))
                }
            }
            let step = steps.map { $0.0 }.min()!
            for edge in active { values[edge] = min(requests[edge], values[edge] + requests[edge] * step) }
            active.subtract(steps.filter { $0.0 == step }.flatMap { $0.1 })
        }
        return values
    }
    static func allocationPropertiesAndStress() throws {
        var seed: UInt64 = 81723
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 32) / Double(UInt32.max)
        }
        for count in 1...40 {
            let lengths = (0...count).map { _ in 0.001 + random() * 4 }
            let requests = (0..<count).map { _ in random() * 6 }
            var position = 0.0, cuts: [RecordingCut] = []
            for index in 0..<count {
                position += lengths[index]
                cuts.append(.init(start: position, end: position + 0.01, crossfade: requests[index]))
                position += 0.01
            }
            let duration = position + lengths.last!
            let projected = try RecordingTimeMap(duration: duration, trimStart: 0, trimEnd: duration, cuts: cuts)
            let actualLengths = projected.clips.map { $0.sourceEnd - $0.sourceStart }
            let expected = referenceFades(requests, lengths: actualLengths)
            for index in requests.indices { try close(projected.joins[index].duration, expected[index], "Heap matches direct proportional water filling") }
        }
        let cuts: [RecordingCut] = (0..<1000).map { (index: Int) -> RecordingCut in
            let start = Double(index * 2 + 1)
            let end = start + 1.0
            let crossfade = Double(index % 7 + 1) / 3.0
            return RecordingCut(start: start, end: end, crossfade: crossfade)
        }
        let large = try RecordingTimeMap(duration: 2001, trimStart: 0, trimEnd: 2001, cuts: cuts)
        try require(large.clips.count == 1001 && large.joins.count == 1000, "Thousand-cut metadata plan")
        let reordered = try RecordingTimeMap(duration: 2001, trimStart: 0, trimEnd: 2001, cuts: Array(cuts.reversed()))
        try require(large == reordered, "Large plan deterministic")
        for index in large.clips.indices {
            let incoming = index > 0 ? large.joins[index - 1].duration : 0
            let outgoing = index < large.joins.count ? large.joins[index].duration : 0
            try require(incoming + outgoing <= 1, "Large clip budgets cannot triple overlap")
        }
        for tick in 0...1000 {
            let samples = large.samples(at: large.outputDuration * Double(tick) / 1000)
            try require(samples.count >= 1 && samples.count <= 2, "Large map remains covered without triple overlaps")
            try close(samples.reduce(0) { $0 + $1.weight }, 1, "Large alpha normalization")
        }
    }
    static func invalidMetadata() throws {
        let duplicate = UUID()
        let invalid: [[RecordingCut]] = [
            [.init(start: -1, end: 2)], [.init(start: 1, end: 11)], [.init(start: 2, end: 2)],
            [.init(start: .nan, end: 3)], [.init(start: 2, end: .infinity)], [.init(start: 2, end: 3, crossfade: -1)],
            [.init(start: 2, end: 3, crossfade: .infinity)], [.init(start: 0, end: 10)],
            [.init(start: 2, end: 5), .init(start: 4, end: 6)], [.init(start: 2, end: 4), .init(start: 4, end: 6)],
            [.init(id: duplicate, start: 1, end: 2), .init(id: duplicate, start: 4, end: 6)]]
        for cuts in invalid { try reject { _ = try map(cuts) } }
        try reject { _ = try map([.init(start: 1, end: 2, crossfade: .nan)], start: 5) }
        try reject { _ = try map([.init(start: 2, end: 8)], start: 3, end: 7) }
        for bounds in [(Double.nan, 10.0), (-1.0, 9.0), (0.0, 11.0), (3.0, 3.0)] {
            try reject { _ = try map([], start: bounds.0, end: bounds.1) }
        }
        try reject { _ = try RecordingTimeMap(duration: .infinity, trimStart: 0, trimEnd: 1, cuts: []) }
    }
    static func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-time-map-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original.data"), sourceBytes = Data("Immutable original sentinel".utf8)
        try sourceBytes.write(to: source)
        let project = RecordingProject(screenFilename: source.lastPathComponent, duration: 10)
        let url = directory.appendingPathComponent("test.framethrower")
        let editor = ProjectEditor(project: project, url: url)
        try require(editor.save(), "Save original metadata")
        var state = editor.project.state
        state.cuts = [.init(start: 2, end: 4, crossfade: 10)]
        try require(editor.commit(state, name: "Cut section"), "Single saved cut transaction")
        let cutState = editor.project.state
        try require(editor.project.undoHistory.count == 1 && editor.undo() && editor.project.state.cuts.isEmpty, "One Undo restores excluded footage")
        try require(editor.redo() && editor.project.state == cutState, "Redo restores same cut IDs and requested fade")
        let reopened = try ProjectEditor.open(url: url)
        try require(reopened.project == editor.project, "Reopen preserves cuts and complete history")
        try require(try Data(contentsOf: source) == sourceBytes, "No source bytes rewritten")
        var invalid = editor.project
        invalid.undoHistory[0].state.cuts = [.init(start: 1, end: 20)]
        try reject { try invalid.validate() }
        invalid = editor.project
        invalid.redoHistory = [.init(name: "Invalid history", state: invalid.undoHistory[0].state)]
        invalid.redoHistory[0].state.cuts = [.init(start: 1, end: 20)]
        try reject { try invalid.validate() }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(editor.project)) as! [String: Any]
        var legacyState = json["state"] as! [String: Any]; legacyState.removeValue(forKey: "cuts"); json["state"] = legacyState
        for key in ["undoHistory", "redoHistory"] {
            var entries = json[key] as! [[String: Any]]
            for index in entries.indices { var old = entries[index]["state"] as! [String: Any]; old.removeValue(forKey: "cuts"); entries[index]["state"] = old }
            json[key] = entries
        }
        let legacy = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: json))
        try require(legacy.state.cuts.isEmpty && legacy.undoHistory.allSatisfy { $0.state.cuts.isEmpty }, "Each legacy state/history decodes cuts as empty")
        let cutJSON: [String: Any] = ["id": UUID().uuidString, "start": 1, "end": 2]
        let hard = try JSONDecoder().decode(RecordingCut.self, from: JSONSerialization.data(withJSONObject: cutJSON))
        try require(hard.crossfade == 0, "Missing requested fade defaults to hard cut")
    }
}
