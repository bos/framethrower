import Foundation
@testable import FrameThrower

/// Actual metadata commands and animation projection; no media or devices.
@main @MainActor
struct ReferenceAnchorChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure.failed(message) }
    }
    static func spans(_ state: EditState) -> [TimelineAnimation] {
        EditorAnimationEditing.animations(in: state, references: EditorReferences(), duration: 12)
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended && MediaProcessing.isCaptureSuspended, "Metadata/vector checks only")
        try boxesAndExplicitReferences()
        try legacyProjectionAndDeletion()
        try commandsAndHistory()
        try routeDeletion()
        print("Reference anchor checks passed: implicit box/generated identities hidden, deliberate references visible, safe legacy inference, explicit promotion with stable IDs and one Undo/Redo, generated command provenance and route deletion preserved; no media.")
    }
    static func boxesAndExplicitReferences() throws {
        var project = RecordingProject(screenFilename: "absent.mov", cameraFilename: "absent-camera.mov", duration: 12)
        let rect = EditorRegionRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3)
        let beforeBoxes = project.state
        let first = project.state.addRegion(rect: rect, at: 2.25)
        let second = project.state.addRegion(rect: rect, at: 2.25)
        project.ensureReferences()
        let beforeCamera = project.state
        try require(DirectorTranscriptStep.changes(from: beforeBoxes, to: beforeCamera, references: project.references).isEmpty,
                    "Drawing a box does not produce an unrequested Reference transcript step")
        project.state.pipKeyframes += [.init(time: 2, placement: .init(), transition: .jump),
            .init(time: 5, placement: .init(x: 0, y: 0, scale: 0.5), transition: .smooth, duration: 3)]
        project.ensureReferences()
        try project.validate()
        try require(first.editID == second.editID && project.state.editAnchors.count == 1 &&
                    project.state.editAnchors[0].origin == .box, "Drawing boxes shares a typed naming identity")
        try require(!spans(project.state).contains(where: \.isReference), "Drawing a box does not add a Reference animation among camera edits")
        let cameraSpans = EditorAnimationEditing.animations(in: project.state, references: project.references, duration: 12).filter { $0.lane == .camera }
        try require(cameraSpans.contains { $0.end == 2 && $0.label == "Hold B" } &&
                    cameraSpans.contains { $0.end == 5 && $0.label == "Camera C" },
                    "Camera baseline and actual movement have truthful Hold/Camera labels with durable letters")
        let cameraSteps = DirectorTranscriptStep.changes(from: beforeCamera, to: project.state, references: project.references)
        try require(cameraSteps.map(\.label) == ["Hold B", "Camera C"] &&
                    !project.state.timedEdits(includeCamera: true).filter({ project.state.showsTimedEdit($0) }).contains { $0.id == first.editID },
                    "User-facing edit navigation/cards omit box-only identity while keeping camera changes")
        try require(project.references.edit(in: project.state, id: first.editID!)?.anchorID == first.editID &&
                    project.references.editLabel(for: first.editID!) != nil, "Director can still name the stable box reference")
        let explicit = EditAnchor(time: 8)
        project.state.editAnchors.append(explicit)
        _ = project.state.addRegion(rect: rect, at: 8)
        try require(spans(project.state).contains { $0.componentID == explicit.id && $0.isReference },
                    "A deliberately created bookmark remains visible when a box is later attached")
    }
    static func legacyProjectionAndDeletion() throws {
        var project = RecordingProject(screenFilename: "absent.mov", duration: 12)
        let boxAnchor = EditAnchor(time: 2.25, origin: nil), oldBookmark = EditAnchor(time: 8, origin: nil)
        project.state.editAnchors = [boxAnchor, oldBookmark]
        let box = EditorRegion(time: 2.25, rect: .init(x: 0, y: 0, width: 0.5, height: 0.5), editID: boxAnchor.id)
        project.state.regions = [box]
        let encoded = try JSONEncoder().encode(project.state)
        let decoded = try JSONDecoder().decode(EditState.self, from: encoded)
        try require(decoded == project.state && decoded.editAnchors.allSatisfy { $0.origin == nil },
                    "Missing provenance decodes compatibly without changing legacy metadata")
        let before = decoded
        let references = spans(decoded).filter(\.isReference)
        try require(references.count == 1 && references[0].componentID == oldBookmark.id && decoded == before,
                    "Legacy box-only mark is hidden by projection; unrelated bookmark and state remain intact")
        let removed = EditorBoxConnections.removing(regionID: box.id, from: decoded)
        try require(removed.editAnchors.first?.id == boxAnchor.id && removed.editAnchors.first?.origin == .box &&
                    !spans(removed).contains { $0.componentID == boxAnchor.id },
                    "Deleting the last legacy box does not reveal an orphan Reference or discard its identity")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ft-legacy-anchor-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        project.state = decoded
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("legacy.framethrower"))
        try require(editor.save(), "Save legacy fixture")
        let bytes = try Data(contentsOf: editor.url)
        let opened = try ProjectEditor.open(url: editor.url)
        _ = spans(opened.project.state)
        try require(opened.project.state == decoded && (try Data(contentsOf: editor.url)) == bytes,
                    "Opening and projecting an old project never migrates or writes anchor provenance")
        try require(editor.commit(removed, name: "Delete box") && editor.project.undoHistory.count == 1 &&
                    editor.undo() && editor.project.state == decoded && editor.redo() && editor.project.state == removed,
                    "Legacy inference on explicit deletion belongs to that one reversible transaction")
    }
    static func commandsAndHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ft-reference-anchor-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var project = RecordingProject(screenFilename: "absent.mov", duration: 12)
        let a = project.state.addRegion(rect: .init(x: 0, y: 0, width: 0.4, height: 0.4), at: 2.25)
        let b = project.state.addRegion(rect: .init(x: 0.6, y: 0.5, width: 0.3, height: 0.3), at: 7)
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("recording.framethrower"))
        try require(editor.save(), "Save metadata")
        let id = UUID(), original = editor.project
        func batch(_ commands: [EditorCommand]) throws -> EditorCommandBatch {
            .init(projectID: id, revision: try EditorCommandDispatcher.revision(for: editor.project), commands: commands)
        }
        try EditorCommandDispatcher.apply(batch([.createEdit(time: 2.25)]), to: editor, projectID: id, name: "Add reference")
        try require(editor.project.state.editAnchors[0].id == a.editID && editor.project.state.editAnchors[0].origin == .reference &&
                    editor.project.state.regions == original.state.regions && editor.project.references == original.references,
                    "Explicit request promotes an implicit mark in place without renaming boxes or Director references")
        let promotion = DirectorTranscriptStep.changes(from: original.state, to: editor.project.state, references: editor.project.references)
        try require(promotion.count == 1 && promotion[0].label == "Reference A",
                    "Explicit promotion appears as a deliberate bookmark transcript step")
        try require(spans(editor.project.state).contains { $0.componentID == a.editID && $0.isReference } &&
                    editor.project.undoHistory.count == 1 && editor.undo() && editor.project.state == original.state,
                    "Promotion is one ordinary Undo restoring the hidden implicit origin")
        try require(editor.redo(), "Redo explicit reference")
        let reopened = try ProjectEditor.open(url: editor.url)
        try require(reopened.project.state == editor.project.state, "Explicit provenance survives Redo and reopening")
        let movement = try EditorCommandDispatcher.prepare(batch([.moveForDuration(startEditID: a.editID!,
            fromRegionID: a.id, toRegionID: b.id, duration: 2)]), for: editor.project, projectID: id)
        try require(movement.editAnchors.first { abs($0.time - 4.25) < 0.000001 }?.origin == .generated,
                    "Movement continuity anchors are generated, never unrequested bookmarks")
        var visual = original
        visual.state.zoomKeyframes = [.init(time: 4, scale: 2)]
        visual.ensureReferences()
        let removal = EditorCommandBatch(projectID: id, revision: try EditorCommandDispatcher.revision(for: visual),
            commands: [.removeScreenFraming(editID: visual.state.zoomKeyframes[0].id)])
        let retained = try EditorCommandDispatcher.prepare(removal, for: visual, projectID: id)
        let generated = retained.editAnchors.first { $0.id == visual.state.zoomKeyframes[0].id }!
        try require(generated.origin == .generated && !spans(retained).contains { $0.componentID == generated.id },
                    "Retaining an edit identity after framing removal does not expose a Reference animation")
        try require(DirectorTranscriptStep.changes(from: visual.state, to: retained, references: visual.references)
            .allSatisfy { !$0.label.contains("Reference") }, "Framing removal never reports a generated identity as a new Reference step")
    }
    static func routeDeletion() throws {
        var project = RecordingProject(screenFilename: "absent.mov", duration: 12)
        let a = project.state.addRegion(rect: .init(x: 0, y: 0, width: 0.4, height: 0.4), at: 1)
        let b = project.state.addRegion(rect: .init(x: 0.3, y: 0.2, width: 0.4, height: 0.4), at: 3)
        let c = project.state.addRegion(rect: .init(x: 0.6, y: 0.5, width: 0.3, height: 0.3), at: 6)
        project.state.zoomKeyframes = [.init(time: 1, scale: 2, transition: .jump, sourceRegionID: a.id),
            .init(time: 3, scale: 2.5, transition: .smooth, duration: 2, sourceRegionID: b.id),
            .init(time: 6, scale: 3, transition: .smooth, duration: 3, sourceRegionID: c.id)]
        let removed = EditorBoxConnections.removing(regionID: b.id, from: project.state)
        try require(removed.zoomKeyframes.map(\.sourceRegionID) == [a.id, c.id] && removed.zoomKeyframes.last?.duration == 5 &&
                    removed.editAnchors == project.state.editAnchors && !spans(removed).contains(where: \.isReference),
                    "Deleting midpoint box still bridges A to C without revealing internal naming marks")
    }
}
