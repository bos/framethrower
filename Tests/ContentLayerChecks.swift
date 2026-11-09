import Foundation

private enum LayerCheckError: Error { case failed(String) }

/// Models, project JSON, immutable byte storage, and typed commands only. No
/// image decoder, video, media fixtures, compositor, or capture device is used.
@main @MainActor
struct ContentLayerChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw LayerCheckError.failed(message) }
    }
    static func reject(_ action: () throws -> Void, _ message: String) throws {
        do { try action() }
        catch is ProjectError { return }
        catch is EditorMutationError { return }
        catch is DecodingError { return }
        throw LayerCheckError.failed(message)
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "Media interlock")
        try checkTimingAndGeometry()
        try checkCommandsAndValidation()
        try checkPersistenceAndAssets()
        print("Content layer checks passed (source timing/cuts, fades, motion, bounds, strict commands, atomic validation, JSON migration, image identity/storage, history, recovery, and duplication; no media access).")
    }
    private static func checkTimingAndGeometry() throws {
        var layer = ContentLayer(kind: .text, start: 2, end: 6)
        layer.opacity = 0.8; layer.fadeIn = 5; layer.fadeOut = 5
        try require(!layer.isActive(at: 1.9) && layer.isActive(at: 2) && !layer.isActive(at: 6), "Half-open source interval")
        try require(layer.alpha(at: 2) == 0 && layer.alpha(at: 4) == 0.8 && layer.alpha(at: 6) == 0,
                    "Overlong fades shrink proportionally and reach full layer opacity")
        layer.rect = .init(x: 0.1, y: 0.2, width: 0.2, height: 0.2)
        layer.endRect = .init(x: 0.7, y: 0.6, width: 0.3, height: 0.3)
        try require(layer.frame(at: 2) == layer.rect && layer.frame(at: 6) == layer.endRect, "Motion endpoints")
        var priorX = layer.rect.x
        for step in 0...100 {
            let rect = layer.frame(at: 2 + Double(step) * 0.04)
            try require(rect.isValid && rect.x >= priorX - 1e-12, "Continuous bounded motion")
            priorX = rect.x
        }
        for x in [-10.0, -0.7, 0, 0.2, 10] {
            for y in [-10.0, 0, 10] {
                try layer.translated(x: x, y: y).validate(duration: 10, assets: [])
                try layer.resized(width: x, height: y).validate(duration: 10, assets: [])
            }
        }
        let map = try RecordingTimeMap(duration: 10, trimStart: 0, trimEnd: 10,
            cuts: [RecordingCut(start: 3, end: 7, crossfade: 1)])
        let samples = map.samples(at: 2.5)
        try require(samples.count == 2 && samples[0].sourceTime == 2.5 && samples[1].sourceTime == 7.5,
                    "Crossfades evaluate two independent source moments")
        try require(layer.isActive(at: samples[0].sourceTime) && !layer.isActive(at: samples[1].sourceTime),
                    "Content stays attached to its original footage through cuts")
    }
    private static func checkCommandsAndValidation() throws {
        let base = RecordingProject(screenFilename: "unopened.mov", duration: 10)
        var state = base.state
        let first = ContentLayer(kind: .text, start: 1, end: 4)
        let second = ContentLayer(kind: .arrow, start: 2, end: 6)
        try EditorMutation.addContentLayer(first).apply(to: &state, project: base)
        try EditorMutation.addContentLayer(second).apply(to: &state, project: base)
        try EditorMutation.reorderContentLayer(layerID: first.id, index: 1).apply(to: &state, project: base)
        try require(state.contentLayers.map(\.id) == [second.id, first.id], "Explicit back-to-front order")
        var revised = first; revised.text = "Save your changes"; revised.rotation = 30
        try EditorMutation.updateContentLayer(revised).apply(to: &state, project: base)
        try require(state.contentLayers.last == revised && state.regions.isEmpty, "Content changes preserve reference boxes and stack position")
        let beforeInvalid = state
        var invalid = revised; invalid.end = 11
        try reject({ try EditorMutation.updateContentLayer(invalid).apply(to: &state, project: base) }, "Invalid replacement rejected")
        try reject({ try EditorMutation.addContentLayer(revised).apply(to: &state, project: base) }, "Duplicate identity rejected")
        try reject({ try EditorMutation.reorderContentLayer(layerID: first.id, index: 99).apply(to: &state, project: base) }, "Invalid order rejected")
        try require(state == beforeInvalid, "Failed commands leave state unchanged")
        try EditorMutation.removeContentLayer(layerID: first.id).apply(to: &state, project: base)
        try require(state.contentLayers == [second], "Only the requested content is removed")

        let minimal = Data(#"{"operation":"addContentLayer","layer":{"kind":"text","start":1,"end":3,"rect":{"x":0.1,"y":0.2,"width":0.5,"height":0.2},"text":"Hello"}}"#.utf8)
        let mutation = try JSONDecoder().decode(EditorMutation.self, from: minimal)
        try mutation.apply(to: &state, project: base)
        try require(state.contentLayers.last?.text == "Hello" && state.contentLayers.last?.fontSize == 0.045, "Sparse commands use documented defaults and host identity")
        let encoded = try JSONEncoder().encode(mutation)
        try require(try JSONDecoder().decode(EditorMutation.self, from: encoded) == mutation, "Command roundtrip")
        let malicious = Data(#"{"operation":"addContentLayer","layer":{"kind":"image","start":1,"end":3,"url":"https://example.com/image.png"}}"#.utf8)
        try reject({ _ = try JSONDecoder().decode(EditorMutation.self, from: malicious) }, "Commands cannot load arbitrary images or paths")
        var image = ContentLayer(kind: .image, start: 0, end: 3); image.assetID = UUID()
        try reject({ try EditorMutation.addContentLayer(image).apply(to: &state, project: base) }, "Unregistered image identity rejected")
        for invalid in [-1.0, .nan, .infinity, 181] {
            var layer = first; layer.rotation = invalid == -1 ? -181 : invalid
            try reject({ try layer.validate(duration: 10, assets: []) }, "Invalid finite style rejected")
        }
    }
    private static func checkPersistenceAndAssets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-layers-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("layers.framethrower")
        let original = RecordingProject(screenFilename: "absent-source.mov", duration: 10)
        let editor = ProjectEditor(project: original, url: url)
        try require(editor.save(), "Initial project save")
        // Opaque bytes deliberately are not a real image: metadata persistence
        // must never instantiate an image source or decoder.
        let asset = ContentImageAsset(name: "Image asset", data: Data("opaque immutable test bytes".utf8), pixelWidth: 100, pixelHeight: 50)
        var layer = ContentLayer(kind: .image, start: 1, end: 4); layer.assetID = asset.id
        try require(editor.addContentLayer(layer, image: asset), "Image and layer are one transaction")
        try require(editor.historyState.undo.first == "Add image", "One image import history step")
        try require(editor.undo() && editor.project.state.contentLayers.isEmpty && editor.project.contentAssets == [asset],
                    "Undo retains asset for Redo")
        try require(editor.redo() && editor.project.state.contentLayers == [layer], "Redo restores image identity")
        let reopened = try ProjectEditor.open(url: url)
        try require(reopened.project.contentAssets == [asset] && reopened.project.state.contentLayers == [layer], "Self-contained project roundtrip")
        var copy = layer; copy.id = UUID(); copy.start = 4; copy.end = 7
        try require(reopened.addContentLayer(copy) && reopened.project.contentAssets.count == 1, "Repeated layers share immutable image bytes")
        var draft = reopened.project.state; draft.contentLayers[0].rotation = 20
        try require(reopened.updateDraft(draft, at: 2) && reopened.flushRecovery(), "Layer gesture has ordinary recovery")
        try require(reopened.cancelDraft(), "Cancel restores saved layer")
        let duplicate = reopened.duplicate()
        try require(duplicate?.project.state == reopened.project.state && duplicate?.project.contentAssets == [asset], "Duplicate preserves self-contained images")
        var removed = reopened.project.state; removed.contentLayers = []
        try require(reopened.commit(removed, name: "Remove content"), "Remove layers")
        try require(reopened.project.contentAssets == [asset], "History keeps removed images reachable")
        let emptyCopy = reopened.duplicate()
        try require(emptyCopy?.project.contentAssets.isEmpty == true, "Fresh history prunes unreachable image bytes")

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "contentAssets")
        var legacyState = legacy["state"] as! [String: Any]; legacyState.removeValue(forKey: "contentLayers"); legacy["state"] = legacyState
        let migrated = try JSONDecoder().decode(RecordingProject.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(migrated.state.contentLayers.isEmpty && migrated.contentAssets.isEmpty && migrated.state == original.state, "Legacy projects keep their edits")
        try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { $0.hasSuffix(".framethrower") },
                    "No source/image files, external asset links, or temporary files are created")
    }
}
