import Foundation

@main
struct CursorZoomSuggestionChecks {
    enum Failure: Error { case failed(String) }
    static func main() throws {
        func click(_ time: Double, _ x: Double = 0.5, _ y: Double = 0.5) -> CursorClick {
            CursorClick(time: time, x: x, y: y, button: 0)
        }
        func recording(_ clicks: [CursorClick], duration: Double = 20) -> CursorRecording {
            CursorRecording(duration: duration, logicalWidth: 1600, logicalHeight: 900,
                samples: [CursorSample(time: 0, x: 0.5, y: 0.5), CursorSample(time: duration, x: 0.5, y: 0.5)], clicks: clicks)
        }
        func points(_ source: CursorRecording, range: ClosedRange<Double> = 0...20,
                    preset: CursorZoomSuggestions.Preset = .subtle) -> [ZoomKeyframe] {
            CursorZoomSuggestions.points(in: source, range: range, preset: preset, frameDuration: 1.0 / 30)
        }
        let nearbyClicks = recording([click(2, 0.5, 0.5), click(2.3, 0.51, 0.52), click(2.7, 0.52, 0.5)])
        let grouped = points(nearbyClicks)
        try require(grouped.count == 4, "a click burst produces one arrival, hold, and wide return")
        try near(grouped[1].time, 2, "zoom arrives on the first click")
        try near(grouped[1].x, 0.51, "one stable focus covers nearby clicks")
        try near(grouped[2].time, 3.5, "zoom holds after last click")
        try near(grouped[3].time, 3.9, "zoom returns smoothly to context")
        var state = EditState(trimStart: 0, trimEnd: 20, pipKeyframes: [], zoomKeyframes: grouped)
        try near(state.zoom(at: 1.6).scale, 1, "zoom stays wide before arrival transition")
        try near(state.zoom(at: 1.8).scale, 1.25, "arrival uses smooth interpolation")
        try near(state.zoom(at: 3.5).scale, 1.5, "hold preserves focus scale")
        try near(state.zoom(at: 3.7).scale, 1.25, "return uses smooth interpolation")
        try near(state.zoom(at: 4).scale, 1, "long idle intervals remain wide")
        try require(grouped == points(nearbyClicks), "identities and geometry are deterministic")
        try require(points(nearbyClicks, preset: .focused).contains { $0.scale == 2 }, "focused preset offers stronger zoom")

        let nearbyBursts = points(recording([click(2, 0.4, 0.4), click(3.5, 0.55, 0.45)]))
        try require(!nearbyBursts.contains { $0.time > 2 && $0.time < 3.5 && $0.scale == 1 },
                    "nearby short-gap bursts pan without zooming out and back in")
        state.zoomKeyframes = nearbyBursts
        try near(state.zoom(at: 3.3).scale, 1.5, "pan keeps a steady zoom level")
        try require(state.zoom(at: 3.3).x > 0.4 && state.zoom(at: 3.3).x < 0.55, "pan moves between burst foci")
        let distant = points(recording([click(2, 0.1, 0.1), click(7, 0.9, 0.9)]))
        try require(distant.contains { $0.time > 2 && $0.time < 7 && $0.scale == 1 },
                    "distant late work returns to context")
        state.zoomKeyframes = distant
        try near(state.zoom(at: 5).scale, 1, "long gap does not stay zoomed")
        let rapidFar = points(recording([click(2, 0.1, 0.1), click(2.3, 0.9, 0.9)]))
        try require(!rapidFar.contains { $0.time > 2 && $0.time < 2.3 && $0.scale == 1 },
                    "rapid distant actions do not cause a zoom bounce")

        let trim = 2.1...5.05
        let trimmed = points(recording([click(1), click(2.15), click(5.04), click(6)]), range: trim)
        try require(!trimmed.isEmpty && trimmed.allSatisfy { $0.time >= trim.lowerBound - 1e-9 && $0.time < trim.upperBound },
                    "suggestions stay inside retained trim and exclusive end")
        try require(zip(trimmed, trimmed.dropFirst()).allSatisfy { $0.time < $1.time }, "point times are ordered and unique")
        try require(trimmed.allSatisfy { abs($0.time * 30 - ($0.time * 30).rounded()) < 0.000001 },
                    "every generated point belongs to a source frame")
        let lastClick = points(recording([click(3.999)]), range: 0...4)
        try near(lastClick.last!.time, 119.0 / 30, "exclusive final source frame is retained")
        try require(lastClick.last!.scale > 1, "a final click is not overwritten by an impossible wide return")
        try require(points(recording([])).isEmpty, "no events require no suggested edits")
        try require(points(recording([click(2)]), range: 0...1).isEmpty, "events outside trim are ignored")
        try require(points(recording([click(2)]), range: 2.001...2.01).isEmpty, "subframe range without a source frame is safe")

        let flood = recording((0..<600).map { click(2 + Double($0) * 0.02, 0.5 + Double($0 % 3) * 0.01, 0.5) })
        try require(points(flood).count <= 4, "hundreds of nearby clicks do not flood the timeline")
        let long = recording((0..<200).map { click(2 + Double($0) * 4, $0 % 2 == 0 ? 0.2 : 0.8, 0.5) }, duration: 1000)
        let bounded = points(long, range: 0...1000)
        try require(bounded.count <= 181, "long recordings have a bounded editable point count")
        try require(bounded.contains { $0.scale > 1 && abs($0.time - 2) < 1e-6 } &&
                    bounded.contains { $0.scale > 1 && abs($0.time - 798) < 1e-6 },
                    "bounded suggestions retain both ends of a long recording")
        let tiny = recording([click(0)], duration: 1e-302)
        let tinyPoints = CursorZoomSuggestions.points(in: tiny, range: 0...1e-302, preset: .subtle, frameDuration: 1e-300)
        try require(tinyPoints.count <= 1, "extreme valid subframe durations cannot overflow frame arithmetic")
        print("Cursor auto-zoom suggestion checks passed (burst grouping, stable holds, smooth pan, wide returns, trim/frame bounds, deterministic identities, and bounded point counts).")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
    }
    private static func near(_ value: Double, _ expected: Double, _ message: String) throws {
        try require(abs(value - expected) < 0.000001, "\(message): \(value) != \(expected)")
    }
}
