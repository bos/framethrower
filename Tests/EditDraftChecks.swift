import Foundation

private enum DraftCheckError: Error { case failed(String) }

@main
@MainActor
struct EditDraftChecks {
    static func main() throws {
        try withEditor { editor, source in
            let baseline = editor.project
            let savedBytes = try Data(contentsOf: editor.url)
            let zoomID = UUID()
            let cameraID = UUID()
            var next = editor.editingState
            next.zoomKeyframes = [ZoomKeyframe(id: zoomID, time: 2, scale: 2)]
            next.pipKeyframes.append(PIPKeyframe(id: cameraID, time: 2,
                                               placement: PIPPlacement(x: 0.3, y: 0.4)))
            for step in 0...200 {
                next.zoomKeyframes[0].scale = 1.5 + Double(step) / 400
                next.pipKeyframes[1].placement.x = 0.2 + Double(step) / 1000
                try require(editor.updateDraft(next, at: 2), "refine a combined zoom/camera edit")
            }
            try require(editor.project == baseline && editor.editingState == next,
                        "many finger samples update only the shared draft")
            try require(try Data(contentsOf: editor.url) == savedBytes,
                        "no intermediate sample rewrites the project")
            try require(editor.canUndo && editor.undoName == "Edit" && !editor.canRedo,
                        "pending combined edit can be undone")
            try require(editor.finishDraft() && editor.draftState == nil && editor.draftTime == nil,
                        "leaving the edit finalizes it")
            try require(editor.project.undoHistory.count == 1 && editor.project.state == next,
                        "all refinements become one history snapshot")
            try require(try ProjectEditor.open(url: editor.url).project == editor.project,
                        "the combined edit survives reopening")

            let beforeRevision = editor.project
            next.zoomKeyframes[0].scale = 2.8
            next.pipKeyframes[1].placement.scale = 0.4
            try require(editor.updateDraft(next, at: 2) && editor.finishDraft(), "revise an existing edit")
            try require(editor.project.state.zoomKeyframes.map(\.id) == [zoomID] &&
                        editor.project.state.pipKeyframes.last?.id == cameraID,
                        "revisions preserve existing edit identities")
            try require(editor.undo() && editor.project.state == beforeRevision.state,
                        "one undo restores all properties of the revised edit")
            try require(editor.redo() && editor.project.state == next, "redo restores the combined revision")
            let beforeDraftUndo = editor.project
            next.zoomKeyframes[0].scale = 2.9
            next.pipKeyframes[1].placement.sourceZoom = 2
            try require(editor.updateDraft(next, at: 2) && editor.undo(), "Undo a combined pending revision")
            try require(editor.project.state == beforeDraftUndo.state &&
                        editor.project.undoHistory == beforeDraftUndo.undoHistory && editor.canRedo,
                        "pending Undo adds no intermediate undo snapshot")
            try require(editor.redo() && editor.project.state == next &&
                        editor.project.undoHistory.count == beforeDraftUndo.undoHistory.count + 1,
                        "Redo restores every screen and camera property from the combined pending revision")
            try require(try Data(contentsOf: source) == Data("immutable source".utf8),
                        "drafting and undo never alter original media")
        }

        try withEditor { editor, _ in
            let original = editor.project.state
            var first = original
            first.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2)]
            try require(editor.updateDraft(first, at: 2), "begin first draft")
            var second = first
            second.zoomKeyframes.append(ZoomKeyframe(time: 3, scale: 2.5))
            try require(editor.updateDraft(second, at: 3), "moving to a new time finalizes the previous edit")
            try require(editor.project.state == first && editor.project.undoHistory.count == 1 &&
                        editor.draftState == second && editor.draftTime == 3,
                        "new instant has an independent draft after the first is saved")
            try require(editor.finishDraft() && editor.project.undoHistory.count == 2, "second instant is one more edit")
            try require(editor.undo() && editor.project.state == first, "undo second instant")
            try require(editor.undo() && editor.project.state == original, "undo first instant")
            let redoHistory = editor.project.redoHistory
            try require(editor.canRedo && editor.updateDraft(first, at: 2) && !editor.canRedo && !editor.redo(),
                        "a draft disables redo without destroying its saved branch")
            try require(editor.updateDraft(original, at: 2) && editor.draftState == nil && editor.canRedo &&
                        editor.project.redoHistory == redoHistory && editor.project.undoHistory.isEmpty,
                        "returning exactly to baseline is no edit and preserves redo")
            try require(editor.updateDraft(first, at: 2) && editor.undo(), "Undo restores the baseline of an unfinished edit")
            try require(editor.draftState == nil && editor.project.state == original &&
                        editor.project.undoHistory.isEmpty && editor.project.redoHistory.count == 1 &&
                        editor.project.redoHistory[0].state == first && editor.canRedo,
                        "Undo preserves the pending edit in redo without a spurious undo entry")
            let reopened = try ProjectEditor.open(url: editor.url)
            try require(reopened.canRedo && reopened.redo() && reopened.project.state == first &&
                        reopened.project.undoHistory.count == 1,
                        "the undone draft survives reopening and redo restores it as one edit")
            try require(!editor.cancelDraft(), "cancel without a draft is a no-op")
            let redoBeforeEscape = editor.project.redoHistory
            try require(editor.updateDraft(first, at: 2) && editor.cancelDraft() && editor.project.state == original,
                        "Escape-style cancellation restores the committed state")
            try require(editor.project.redoHistory == redoBeforeEscape,
                        "Escape discards the draft without replacing the existing redo branch")
            try require(!editor.updateDraft(first, at: .nan) && editor.draftState == nil,
                        "invalid time never creates a pending edit")
        }

        try withEditor { editor, _ in
            let before = editor.project
            var next = before.state
            next.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2)]
            try require(editor.updateDraft(next, at: 2), "begin a draft before disk failure")
            let directory = editor.url.deletingLastPathComponent()
            let displaced = directory.appendingPathExtension("displaced")
            try FileManager.default.moveItem(at: directory, to: displaced)
            defer { try? FileManager.default.moveItem(at: displaced, to: directory) }
            try require(!editor.finishDraft() && editor.project == before && editor.draftState == next &&
                        editor.draftTime == 2 && editor.errorMessage != nil,
                        "failed atomic persistence preserves draft, baseline, and history")
            try require(!editor.undo() && editor.project == before && editor.draftState == next && editor.draftTime == 2,
                        "a failed atomic Undo retains the draft and both history branches")
            var later = next
            later.zoomKeyframes.append(ZoomKeyframe(time: 3, scale: 1.5))
            try require(!editor.updateDraft(later, at: 3) && editor.draftState == next && editor.draftTime == 2,
                        "a failed finalization prevents losing the old draft on navigation")
            try require(!editor.rename(to: "Cannot save yet") && editor.project == before,
                        "rename cannot run past a failed draft save")
            try FileManager.default.moveItem(at: displaced, to: directory)
            try require(editor.finishDraft() && editor.project.undoHistory.count == 1 && editor.draftState == nil,
                        "retry saves exactly one edit")
        }

        try withEditor { editor, _ in
            let original = editor.project.state
            var next = original
            next.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2)]
            try require(editor.updateDraft(next, at: 2) && editor.save(), "save finalizes pending framing")
            try require(editor.project.undoHistory.count == 1 && editor.save() && editor.project.undoHistory.count == 1,
                        "saving twice never duplicates a draft snapshot")
            try require(editor.undo() && editor.project.state == original, "undo saved draft")
            try require(editor.updateDraft(next, at: 2) && editor.commit(next, name: "Already drafted"),
                        "commit accepts a state that already includes the pending draft")
            try require(editor.project.undoHistory.count == 1, "commit does not double-record the same state")
            try require(editor.undo(), "return to baseline for rename ordering")
            let oldName = editor.displayName
            try require(editor.updateDraft(next, at: 2) && editor.rename(to: "A renamed recording"),
                        "rename first finalizes framing")
            try require(editor.project.undoHistory.map(\.name) == ["Edit", "Rename recording"],
                        "framing and rename remain in chronological order")
            try require(editor.undo() && editor.displayName == oldName && editor.project.state == next,
                        "undo rename keeps the earlier framing edit")
            try require(editor.undo() && editor.project.state == original, "next undo restores framing baseline")
            var trimmed = original
            trimmed.trimEnd = 8
            try require(editor.commit(trimmed, name: "Trim") && editor.undoName == "Trim" &&
                        editor.project.undoHistory.count == 1,
                        "legacy direct commit behavior stays unchanged when no draft exists")
        }
        try checkUnifiedEdits()
        try checkRampHistoryAndMigration()
        print("Edit draft checks passed (combined refinements, unified edit grouping/move/removal, ramp persistence/migration/validation, timing boundaries, no-op/redo preservation, failed writes/retry, and immutable originals).")
    }

    private static func checkUnifiedEdits() throws {
        let initial = PIPKeyframe(time: 0, placement: PIPPlacement())
        let zoom = ZoomKeyframe(time: 2, scale: 2.3, x: 0.6, y: 0.4,
                                transition: .smooth, duration: 1.2, easeIn: 0.2, easeOut: 0.4)
        let camera = PIPKeyframe(time: 2,
                                placement: PIPPlacement(x: 0.3, y: 0.6, scale: 0.3, shape: .square,
                                                        crop: PIPCrop(x: 0.2, y: 0.8), sourceZoom: 1.5),
                                transition: .smooth, duration: 0.8, easeIn: 0.1, easeOut: 0.3)
        let cameraOnly = PIPKeyframe(time: 4, placement: PIPPlacement(x: 0.7, y: 0.2))
        let state = EditState(trimStart: 0, trimEnd: 10, pipKeyframes: [initial, camera, cameraOnly],
                              zoomKeyframes: [zoom])
        let edits = state.timedEdits(includeCamera: true)
        try require(edits.count == 2 && edits.map(\.time) == [2, 4],
                    "screen and camera changes at the same timestamp share one diamond")
        try require(edits[0].id == zoom.id && edits[0].zoomID == zoom.id && edits[0].cameraID == camera.id,
                    "a grouped edit retains both underlying identities")
        try require(edits[1].id == cameraOnly.id && edits[1].zoomID == nil && edits[1].cameraID == cameraOnly.id,
                    "camera-only edits appear without a zoom change")
        let screenOnly = state.timedEdits(includeCamera: false)
        try require(screenOnly.count == 1 && screenOnly[0].zoomID == zoom.id && screenOnly[0].cameraID == nil,
                    "projects without camera media ignore dormant camera track changes")

        var moved = state
        moved.move(edits[0], to: 3)
        var movedZoom = zoom
        movedZoom.time = 3
        var movedCamera = camera
        movedCamera.time = 3
        try require(moved.zoomKeyframes == [movedZoom] && moved.pipKeyframes == [initial, movedCamera, cameraOnly],
                    "moving a diamond moves both tracks while preserving geometry, duration, ramps, and IDs")
        try require(moved.timedEdits(includeCamera: true).map(\.time) == [3, 4],
                    "a grouped move remains one selectable edit")
        var removed = state
        removed.remove(edits[0])
        try require(removed.zoomKeyframes.isEmpty && removed.pipKeyframes == [initial, cameraOnly],
                    "a grouped X removes both screen and camera changes and retains the initial camera")
        removed.remove(edits[1])
        try require(removed.pipKeyframes == [initial] && removed.timedEdits(includeCamera: true).isEmpty,
                    "removing the camera-only edit restores the initial placement track")

        var atZero = state
        let zeroZoom = ZoomKeyframe(time: 0, scale: 1.5)
        atZero.zoomKeyframes.insert(zeroZoom, at: 0)
        guard let zeroEdit = atZero.timedEdits(includeCamera: true).first else {
            throw DraftCheckError.failed("missing time-zero edit")
        }
        atZero.remove(zeroEdit)
        try require(atZero.pipKeyframes.first == initial && !atZero.zoomKeyframes.contains { $0.id == zeroZoom.id },
                    "removing a time-zero screen edit cannot delete the initial camera source placement")
    }

    private static func checkRampHistoryAndMigration() throws {
        try withEditor { editor, source in
            var custom = editor.project.state
            custom.zoomKeyframes = [ZoomKeyframe(time: 2, scale: 2, transition: .smooth, duration: 1,
                                                 easeIn: 0.1, easeOut: 0.4)]
            custom.pipKeyframes.append(PIPKeyframe(time: 2, placement: PIPPlacement(scale: 0.3),
                                                 transition: .smooth, duration: 0.8,
                                                 easeIn: 0.2, easeOut: 0.3))
            try require(editor.updateDraft(custom, at: 2) && editor.finishDraft(), "save custom movement ramps")
            var revised = custom
            revised.zoomKeyframes[0].easeIn = 0.3
            revised.pipKeyframes[1].easeOut = 0.1
            try require(editor.updateDraft(revised, at: 2) && editor.finishDraft(), "revise custom ramps")
            let reopened = try ProjectEditor.open(url: editor.url)
            try require(reopened.project.state == revised && reopened.undo() && reopened.project.state == custom,
                        "custom screen and camera ramps roundtrip through saved history")
            try require(reopened.redo() && reopened.project.state == revised, "redo restores revised ramp values")

            var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reopened.project)) as! [String: Any]
            func stripRamps(_ value: Any) -> [String: Any] {
                var state = value as! [String: Any]
                for track in ["zoomKeyframes", "pipKeyframes"] {
                    state[track] = (state[track] as! [[String: Any]]).map { value in
                        var point = value
                        point.removeValue(forKey: "easeIn")
                        point.removeValue(forKey: "easeOut")
                        return point
                    }
                }
                return state
            }
            legacyJSON["state"] = stripRamps(legacyJSON["state"]!)
            for branch in ["undoHistory", "redoHistory"] {
                legacyJSON[branch] = (legacyJSON[branch] as! [[String: Any]]).map { value in
                    var snapshot = value
                    snapshot["state"] = stripRamps(value["state"]!)
                    return snapshot
                }
            }
            let migrated = try JSONDecoder().decode(RecordingProject.self,
                from: JSONSerialization.data(withJSONObject: legacyJSON))
            try migrated.validate()
            for state in [migrated.state] + (migrated.undoHistory + migrated.redoHistory).map(\.state) {
                try require(state.zoomKeyframes.allSatisfy { $0.easeIn == nil && $0.easeOut == nil } &&
                            state.pipKeyframes.allSatisfy { $0.easeIn == nil && $0.easeOut == nil },
                            "legacy current and history keyframes decode missing ramp fields with defaults")
            }

            for bad in [-0.1, Double.nan, Double.infinity] {
                for camera in [false, true] {
                    for incoming in [false, true] {
                        var invalid = reopened.project
                        if camera {
                            if incoming { invalid.state.pipKeyframes[1].easeIn = bad }
                            else { invalid.state.pipKeyframes[1].easeOut = bad }
                        } else {
                            if incoming { invalid.state.zoomKeyframes[0].easeIn = bad }
                            else { invalid.state.zoomKeyframes[0].easeOut = bad }
                        }
                        do {
                            try invalid.validate()
                            throw DraftCheckError.failed("negative/nonfinite movement ramps must be rejected")
                        } catch is ProjectError { }
                        invalid.undoHistory = [NamedEditSnapshot(name: "Invalid historical ramp", state: invalid.state)]
                        invalid.state = custom
                        do {
                            try invalid.validate()
                            throw DraftCheckError.failed("invalid historical ramps must be rejected")
                        } catch is ProjectError { }
                    }
                }
            }
            try require(try Data(contentsOf: source) == Data("immutable source".utf8),
                        "ramp changes preserve source bytes")
        }
    }

    private static func withEditor(_ check: (ProjectEditor, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("screen.mp4")
        try Data("immutable source".utf8).write(to: source)
        let editor = ProjectEditor(project: RecordingProject(screenFilename: "screen.mp4", duration: 10),
                                   url: directory.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "save fixture")
        try check(editor, source)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw DraftCheckError.failed(message) }
    }
}
