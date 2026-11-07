import Foundation

enum EditorConflictSide: String, Equatable, Sendable {
    case existing, proposed
}

/// Source-time comparison geometry, independent of the editor/model pipeline.
struct EditorConflictSpan: Identifiable, Equatable, Sendable {
    let id: String
    let side: EditorConflictSide
    let start: Double
    let end: Double
    let label: String
    let help: String

    var isInstant: Bool { start == end }
    var range: ClosedRange<Double> { start...end }
}

/// Rectangles use the original screen's normalized top-left coordinate space.
struct EditorConflictOutlines: Equatable, Sendable {
    let time: Double
    let existing: CGRect
    let proposed: CGRect
}
