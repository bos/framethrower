import AppKit
import Darwin
import SwiftUI
#if LAYER_APP_MODULE
@testable import FrameThrower
#endif

private enum LayerInterfaceError: Error { case failed(String) }

/// An offscreen vector/text fixture only. Never launches or focuses the user
/// app, opens footage, loads image pixels, or runs the video compositor.
@main @MainActor
struct ContentLayerInterfaceChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw LayerInterfaceError.failed(message) }
    }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Content layer interface check failed: \(error)\n".utf8)); exit(1) }
    }
    private static func run() async throws {
        try require(MediaProcessing.isSuspended, "Suspended vector UI only")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framethrower-layer-interface-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await checkAutomation(in: directory)
        var text = ContentLayer(kind: .text, start: 0, end: 5)
        text.text = "Save your changes"; text.rect = .init(x: 0.1, y: 0.1, width: 0.5, height: 0.2)
        var shape = ContentLayer(kind: .rectangle, start: 0, end: 5)
        shape.rect = text.rect; shape.color = .init(red: 1, green: 0.3, blue: 0.2)
        var project = RecordingProject(screenFilename: "absent.mov", duration: 10)
        project.state.contentLayers = [shape, text]
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("fixture.framethrower"))
        try require(editor.save(), "Save metadata fixture")
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 800, height: 450),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        defer { window.close() }
        let background = LayerVectorBackground(frame: CGRect(x: 0, y: 0, width: 800, height: 450))
        let view = ContentLayersOverlayView(frame: background.bounds)
        background.addSubview(view); window.contentView = background
        window.orderBack(nil)
        view.layers = project.state.contentLayers; view.time = 1; view.isEditing = true
        view.select = { [weak view] in view?.selection = $0 }
        view.begin = { editor.finishDraft() }
        view.preview = { [weak view] layer in
            var next = editor.editingState
            if let index = next.contentLayers.firstIndex(where: { $0.id == layer.id }) { next.contentLayers[index] = layer }
            _ = editor.updateDraft(next, at: 1); view?.layers = editor.editingState.contentLayers
        }
        view.commit = { [weak view] name in _ = editor.finishDraft(name: name); view?.layers = editor.editingState.contentLayers }
        view.cancel = { [weak view] in _ = editor.cancelDraft(); view?.layers = editor.editingState.contentLayers }
        func event(_ type: NSEvent.EventType, point: CGPoint) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw LayerInterfaceError.failed("Create native mouse event")
            }
            return event
        }
        let frame = view.frame(for: text, at: 1), center = CGPoint(x: frame.midX, y: frame.midY)
        view.mouseDown(with: try event(.leftMouseDown, point: center))
        try require(view.selection == text.id && editor.historyState.undo.isEmpty, "Topmost selection is not a saved edit")
        view.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: center.x + 40, y: center.y + 18)))
        try require(editor.draftState != nil, "Canvas movement previews one draft")
        view.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: center.x + 40, y: center.y + 18)))
        try require(editor.historyState.undo == ["Move layer"] && editor.project.state.contentLayers[0] == shape,
                    "One movement commits once and leaves other layers unchanged")
        try require(editor.undo() && editor.project.state == project.state, "Movement undo")
        view.layers = editor.project.state.contentLayers
        let corner = CGPoint(x: frame.maxX, y: frame.maxY)
        view.mouseDown(with: try event(.leftMouseDown, point: corner))
        view.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: corner.x + 30, y: corner.y + 20)))
        view.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: corner.x + 30, y: corner.y + 20)))
        try require(editor.historyState.undo == ["Resize layer"] && editor.project.state.contentLayers[1].rect.width > text.rect.width,
                    "Native corner handle resizes with one Undo step")
        let beforeCancel = editor.project.state
        let resizedFrame = view.frame(for: editor.project.state.contentLayers[1], at: 1)
        let start = CGPoint(x: resizedFrame.midX, y: resizedFrame.midY)
        view.mouseDown(with: try event(.leftMouseDown, point: start))
        view.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: start.x + 20, y: start.y + 10)))
        view.cancelOperation(nil)
        try require(editor.draftState == nil && editor.project.state == beforeCancel && editor.historyState.undo.count == 1,
                    "Escape discards the entire layer gesture")
        view.isEditing = false
        try require(view.hitTest(center) == nil, "Other inspectors retain their canvas interactions")
        view.presentation.aspect = .portrait
        try require(abs(view.canvas.width / view.canvas.height - 9.0 / 16) < 1e-10,
                    "Layer coordinates follow the final presentation canvas")
        view.presentation = CanvasPresentation(); view.isEditing = true
        var arrow = ContentLayer(kind: .arrow, start: 0, end: 5)
        arrow.rect = .init(x: 0.22, y: 0.4, width: 0.35, height: 0.16); arrow.rotation = -25
        arrow.color = .init(red: 0.2, green: 0.7, blue: 1)
        var circle = ContentLayer(kind: .circle, start: 0, end: 5)
        circle.rect = .init(x: 0.62, y: 0.42, width: 0.23, height: 0.36)
        circle.color = .init(red: 1, green: 0.85, blue: 0.2)
        var image = ContentLayer(kind: .image, start: 0, end: 5)
        image.rect = .init(x: 0.1, y: 0.7, width: 0.25, height: 0.2)
        view.layers += [arrow, circle, image]; view.selection = arrow.id
        try await snapshot(background, name: "canvas", window: window)

        text.endRect = .init(x: 0.3, y: 0.5, width: 0.6, height: 0.25)
        let form = NSHostingView(rootView: ContentLayerForm(layer: text, duration: 10, apply: { _ in nil }, cancel: {})
            .background(Color(nsColor: .windowBackgroundColor)))
        form.frame = CGRect(x: 0, y: 0, width: 440, height: 580)
        window.setContentSize(form.frame.size); window.contentView = form
        try await snapshot(form, name: "form", window: window)
        let inspector = NSHostingView(rootView: ContentLayersInspector(editor: editor, sourceTime: 1,
            selection: .constant(text.id), prepare: {}, seek: { _ in }).padding(12).background(Color(nsColor: .windowBackgroundColor)))
        inspector.frame = CGRect(x: 0, y: 0, width: 800, height: 100)
        window.setContentSize(inspector.frame.size); window.contentView = inspector
        try await snapshot(inspector, name: "inspector", window: window)
        try require(MediaProcessing.isSuspended && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("absent.mov").path),
                    "No source or media fixture is created")
        print("Content layer interface checks passed (MCP mutations, asset inspection, dual crossfade samples, Undo/Redo; offscreen selection, move/resize, Escape, letterboxing, inspector/form layout and vector/image placeholders; no app focus or video).")
    }
    private static func snapshot(_ view: NSView, name: String, window: NSWindow) async throws {
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(30)); view.layoutSubtreeIfNeeded() }
        window.displayIfNeeded()
        guard let path = ProcessInfo.processInfo.environment["FRAMETHROWER_LAYER_PREVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LayerInterfaceError.failed("Vector UI snapshot") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw LayerInterfaceError.failed("Save UI snapshot") }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private static func checkAutomation(in directory: URL) async throws {
        var project = RecordingProject(screenFilename: "unopened-tool-source.mov", duration: 10)
        project.state.cuts = [RecordingCut(start: 3, end: 7, crossfade: 1)]
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("tools.framethrower"))
        try require(editor.save(), "Save tool fixture")
        let asset = ContentImageAsset(name: "Logo", data: Data("private-opaque-asset-bytes".utf8), pixelWidth: 10, pixelHeight: 10)
        var image = ContentLayer(kind: .image, start: 0, end: 10); image.assetID = asset.id
        try require(editor.addContentLayer(image, image: asset), "Register image for tool reuse")
        let playback = EditorPlayback()
        let host = EditorAutomationHost(editor: editor, playback: playback)
        await host.rebuildPreview()
        defer { playback.close() }
        func call(_ tool: String, _ fields: [String: Any]) async throws -> [String: Any] {
            var args = fields; args["document_id"] = host.documentID
            let data = try await host.performAutomation(tool, arguments: JSONSerialization.data(withJSONObject: args))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["ok"] as? Bool == true, let result = object["result"] as? [String: Any] else {
                throw LayerInterfaceError.failed("Tool result")
            }
            return result
        }
        func mutate(_ mutation: [String: Any]) async throws {
            _ = try await call("apply_edits", ["expected_revision": EditorCommandDispatcher.revision(for: editor.project),
                "commands": [["action": "mutate", "mutation": mutation]], "name": "Content tool edit"])
        }
        try await mutate(["operation": "addContentLayer", "layer": ["kind": "text", "text": "Save your changes", "start": 1, "end": 3,
            "rect": ["x": 0.2, "y": 0.1, "width": 0.5, "height": 0.2]]])
        try require(editor.project.state.contentLayers.count == 2 && editor.project.state.regions.isEmpty, "MCP edits create visible content without reference boxes")
        let added = editor.project.state.contentLayers[1]
        let inspected = try await call("inspect_editor", ["section": "layers"])
        let bytes = try JSONSerialization.data(withJSONObject: inspected)
        try require(!(String(data: bytes, encoding: .utf8) ?? "").contains(asset.data.base64EncodedString()), "MCP never exposes image bytes")
        let assetPage = inspected["assets"] as? [String: Any], assetRows = assetPage?["items"] as? [[String: Any]]
        try require(assetRows?.first?["id"] as? String == asset.id.uuidString && assetRows?.first?["name"] as? String == "Logo", "Registered image metadata is discoverable")
        let blended = try await call("inspect_editor", ["section": "state", "component": "layers", "time_base": "output", "time": 2.5])
        let samples = blended["samples"] as? [[String: Any]]
        try require(samples?.count == 2 && (samples?[0]["value"] as? [Any])?.count == 2 && (samples?[1]["value"] as? [Any])?.count == 1,
                    "MCP evaluates both source branches during a crossfade")
        var revised = added; revised.text = "Saved"; revised.fadeOut = 1
        try await mutate(["operation": "updateContentLayer", "layer": EditorAutomationAPI.object(revised)])
        try require(editor.project.state.contentLayers[1] == revised, "MCP replaces the specified layer")
        try await mutate(["operation": "reorderContentLayer", "layerID": added.id.uuidString, "index": 0])
        try require(editor.project.state.contentLayers.first?.id == added.id, "MCP changes stack order")
        try await mutate(["operation": "removeContentLayer", "layerID": added.id.uuidString])
        try require(editor.project.state.contentLayers == [image], "MCP removes only requested content")
        _ = try await call("control_document", ["operation": "undo", "count": 1, "expected_revision": EditorCommandDispatcher.revision(for: editor.project)])
        try require(editor.project.state.contentLayers.first == revised, "MCP layer edits use ordinary document Undo")
        _ = try await call("control_document", ["operation": "redo", "count": 1, "expected_revision": EditorCommandDispatcher.revision(for: editor.project)])
        try require(editor.project.state.contentLayers == [image], "MCP layer edits use ordinary document Redo")
    }
}

@MainActor
private final class LayerVectorBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor); context.setLineWidth(1)
        for x in stride(from: 0.0, through: bounds.width, by: 40) {
            context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        for y in stride(from: 0.0, through: bounds.height, by: 40) {
            context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        context.strokePath()
    }
}
