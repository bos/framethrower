import Foundation

@main
struct EditorActionDescriptionChecks {
    enum Failure: Error { case failed(String) }
    static func main() throws {
        var state = EditState(trimStart: 0, trimEnd: 12, pipKeyframes: [PIPKeyframe(time: 0, placement: PIPPlacement())])
        state.zoomKeyframes = [ZoomKeyframe(time: 0), ZoomKeyframe(time: 1, scale: 2),
            ZoomKeyframe(time: 2, scale: 2, x: 0.7), ZoomKeyframe(time: 3), ZoomKeyframe(time: 6),
            ZoomKeyframe(time: 10, scale: 2, transition: .smooth, duration: 4)]
        state.pipKeyframes.append(PIPKeyframe(time: 7, placement: PIPPlacement(x: 0.3)))
        state.editAnchors = [EditAnchor(time: 8)]
        var references = EditorReferences()
        references.register(state: state)
        let edits = state.timedEdits(includeCamera: true)
        let descriptions = edits.map { EditorActionDescription.describe($0, in: state, references: references) }
        try require(descriptions.map(\.shortLabel) == ["Full frame A", "Zoom B", "Pan C", "Full frame D", "Hold E", "Camera F", "Ref G", "Zoom H"],
                    "descriptions must reflect actual screen/camera deltas, holds and reference-only anchors")
        try require(!descriptions[0].isMovement && descriptions[1].isMovement && descriptions[2].isMovement &&
                    !descriptions[4].isMovement && !descriptions[6].isMovement, "holds, initial view and references are not movements")
        try require(descriptions[4].tooltip.contains("3.00") && descriptions[4].tooltip.contains("6.00") &&
                    descriptions[7].tooltip.contains("6.00") && descriptions[7].tooltip.contains("10.00"), "tooltips disclose actual hold and smooth intervals")
        try require(state.zoom(at: 8).scale > 1 && descriptions[6].kind == .reference,
                    "a reference drawn inside ongoing movement must not be described as a hold")
        for alias in ["Zoom B", "Edit B", "B", "b", "Pan B", "Full-frame B", "Ref B"] {
            try require(EditorActionDescription.resolve(alias, in: state, references: references)?.id == edits[1].id,
                        "descriptive/legacy/bare/stale-action aliases must preserve letter B: \(alias)")
        }
        try require(EditorActionDescription.resolve("Zoom Z", in: state, references: references) == nil &&
                    EditorActionDescription.resolve("Box B", in: state, references: references) == nil, "unknown/box labels must not identify an edit")
        try require(EditorActionDescription.mentions(edits[1], in: "At Zoom B, frame Box 1.", state: state, references: references) &&
                    EditorActionDescription.mentions(edits[1], in: "between B and C", state: state, references: references) &&
                    !EditorActionDescription.mentions(edits[0], in: "move to a box", state: state, references: references),
                    "spoken aliases must work without treating the article a as a reference")
        var moved = state
        moved.move(edits[1], to: 11)
        let movedB = moved.timedEdits(includeCamera: true).first { $0.id == edits[1].id }!
        try require(EditorActionDescription.describe(movedB, in: moved, references: references).shortLabel.hasSuffix(" B") &&
                    references.editLabel(for: movedB.id) == "Edit B", "retiming must preserve identity without renumbering")
        var ambiguous = references
        ambiguous.edits[edits[2].id.uuidString] = ambiguous.edits[edits[1].id.uuidString]
        try require(EditorActionDescription.resolve("Zoom B", in: state, references: ambiguous) == nil,
                    "ambiguous legacy identity must not choose an arbitrary active edit")
        var combined = state
        combined.pipKeyframes.append(PIPKeyframe(time: 6, placement: PIPPlacement(visible: false)))
        combined.pipKeyframes.sort { $0.time < $1.time }
        let combinedEdit = combined.timedEdits(includeCamera: true).first { $0.time == 6 }!
        let combinedDescription = EditorActionDescription.describe(combinedEdit, in: combined, references: references)
        try require(combinedDescription.shortLabel == "Camera E" && combinedDescription.detail.contains("Hide"),
                    "a stationary screen plus a real camera change must describe the camera action")
        try require(descriptions[1].aliases.contains("Edit B") && descriptions[1].aliases.contains("B"), "context exposes identity aliases separately")
        var grouped = state
        grouped.editAnchors += [EditAnchor(time: 1.0000005), EditAnchor(time: 7.0000005)]
        grouped.editAnchors.sort { $0.time < $1.time }
        var groupedReferences = references
        groupedReferences.register(state: grouped)
        try RecordingProject(screenFilename: "missing.mov", duration: 12, state: grouped, references: groupedReferences).validate()
        let groupedEdits = grouped.timedEdits(includeCamera: true)
        let groupedZoom = groupedEdits.first { $0.zoomID == state.zoomKeyframes[1].id }!
        let groupedCamera = groupedEdits.first { $0.cameraID == state.pipKeyframes[1].id }!
        try require(EditorActionDescription.describe(groupedZoom, in: grouped, references: groupedReferences).shortLabel == "Zoom B" &&
                    EditorActionDescription.describe(groupedCamera, in: grouped, references: groupedReferences).shortLabel == "Camera F",
                    "a valid grouped anchor a fraction later than its own component must not treat that component as its predecessor")
        print("Editor action description checks passed (Zoom/Pan/Full frame/Hold/Ref/Camera, initial view, actual intervals, combined changes, retimed identity, aliases and ambiguity; no media).")
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.failed(message) }
    }
}
