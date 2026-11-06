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

    func validate(duration: Double) throws {
        guard time.isFinite, (0...duration).contains(time), rect.isValid else {
            throw ProjectError.invalid("A scribble must be inside the recording and the original screen frame.")
        }
        guard note.count <= 4_096,
              !note.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
              }) else {
            throw ProjectError.invalid("Use a scribble note of at most 4,096 characters without control characters.")
        }
    }
}
