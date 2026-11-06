import CoreGraphics
import Foundation

/// A guide in the original screen frame's top-left coordinate system. Guides
/// remain editing metadata; they are never visible export overlays implicitly.
struct EditorRegionRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 &&
            width > 0 && height > 0 && x + width <= 1 && y + height <= 1
    }

    /// Fits the entire guide with breathing room. The same bounded viewport
    /// math used by direct manipulation keeps the view inside the source.
    func framing(padding: Double = 0.1) -> ZoomPlacement {
        guard isValid, padding.isFinite, (0...1).contains(padding) else { return ZoomPlacement() }
        let scale = min(3, max(1, min(1 / (width * (1 + 2 * padding)),
                                      1 / (height * (1 + 2 * padding)))))
        return ZoomPlacement(scale: scale, x: x + width / 2, y: y + height / 2).clamped
    }
}

struct EditorRegion: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var time: Double
    var rect: EditorRegionRect
    var note: String = ""
    /// Association identifies the edit selected when this frame was marked.
    /// The source timestamp stays fixed if that edit is moved or removed.
    var editID: UUID? = nil

    func validate(duration: Double) throws {
        guard time.isFinite, (0...duration).contains(time), rect.isValid else {
            throw ProjectError.invalid("A box must be inside the recording and the original screen frame.")
        }
        guard note.count <= 4_096,
              !note.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
              }) else {
            throw ProjectError.invalid("Use a box name of at most 4,096 characters without control characters.")
        }
    }
}

/// Human references are allocation records, outside undoable state. Removing,
/// retiming, or undoing an edit must never give its name to a different edit.
struct EditorReferences: Codable, Equatable, Sendable {
    var edits: [String: Int] = [:]
    var boxes: [String: Int] = [:]

    func editLabel(for id: UUID) -> String? {
        guard let number = edits[id.uuidString], number > 0 else { return nil }
        var remaining = number
        var letters = ""
        while remaining > 0 {
            remaining -= 1
            letters = String(UnicodeScalar(65 + remaining % 26)!) + letters
            remaining /= 26
        }
        return "Edit " + letters
    }

    func boxLabel(for id: UUID) -> String? {
        boxes[id.uuidString].map { "Box \($0)" }
    }

    /// A combined edit can retain its camera component after its zoom is
    /// removed. Its component aliases still identify the same visible edit.
    func edit(in state: EditState, id: UUID, includeCamera: Bool = true) -> TimedEdit? {
        let active = state.timedEdits(includeCamera: includeCamera)
        if let direct = active.first(where: { $0.id == id }) { return direct }
        guard let number = edits[id.uuidString] else { return nil }
        let matches = active.filter { edits[$0.id.uuidString] == number }
        return matches.count == 1 ? matches[0] : nil
    }

    mutating func register(state: EditState, includeCamera: Bool = true) {
        var nextEditNumber = max(0, min(1_000_000, edits.values.max() ?? 0)) + 1
        for edit in state.timedEdits(includeCamera: includeCamera) {
            let ids = [edit.id, edit.zoomID, edit.cameraID].compactMap { $0 }
            let existing = ids.compactMap { edits[$0.uuidString] }.first
            let number = existing ?? nextEditNumber
            if existing == nil { nextEditNumber = min(1_000_001, nextEditNumber + 1) }
            for id in ids where edits[id.uuidString] == nil { edits[id.uuidString] = number }
        }
        var nextBoxNumber = max(0, min(1_000_000, boxes.values.max() ?? 0)) + 1
        for region in state.regions where boxes[region.id.uuidString] == nil {
            boxes[region.id.uuidString] = nextBoxNumber
            nextBoxNumber = min(1_000_001, nextBoxNumber + 1)
        }
    }

    mutating func merge(_ other: EditorReferences) throws {
        try other.validate()
        var combined = self
        for (key, number) in other.edits {
            guard combined.edits[key] == nil || combined.edits[key] == number else {
                throw ProjectError.invalid("An edit reference conflicts with the saved recording.")
            }
            combined.edits[key] = number
        }
        for (key, number) in other.boxes {
            guard combined.boxes[key] == nil || combined.boxes[key] == number else {
                throw ProjectError.invalid("A box reference conflicts with the saved recording.")
            }
            combined.boxes[key] = number
        }
        try combined.validate()
        self = combined
    }

    func validate() throws {
        for catalog in [edits, boxes] {
            guard catalog.count <= 100_000,
                  catalog.allSatisfy({ key, value in
                      UUID(uuidString: key)?.uuidString == key && (1...1_000_000).contains(value)
                  }) else {
                throw ProjectError.invalid("Edit and box references must have valid identities and positive reference numbers.")
            }
        }
        guard Set(boxes.values).count == boxes.count else {
            throw ProjectError.invalid("Each box must have its own reference number.")
        }
    }
}
