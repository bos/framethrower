@preconcurrency import AVFoundation
import Foundation
import ImageIO

/// Tiny generated prerecorded color video only. No device/capture/window API.
@main @MainActor
struct RecordedFrameInspectionChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { guard try value() else { throw Failure.failed(message) } }
    static func main() async {
        do { try await run() } catch { FileHandle.standardError.write(Data("Recorded frame inspection failed: \(error)\n".utf8)); exit(1) }
    }
    static func greenPixel(_ data: Data) throws -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.failed("Decode generated frame") }
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure.failed("Pixel sampling context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Int(pixel[1]) > Int(pixel[0]) + 40 && Int(pixel[1]) > Int(pixel[2]) + 40
    }
    static func run() async throws {
        try require(!MediaProcessing.isSuspended && MediaProcessing.isCaptureSuspended, "Prerecorded media only; actual live capture stays Off")
        guard CommandLine.arguments.count >= 2 else { throw Failure.failed("Generated fixture directory required") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var project = RecordingProject(screenFilename: "fixture.mov", duration: 3, captureFrameDuration: 0.1)
        project.state.trimStart = 0.5; project.state.trimEnd = 2.5
        var text = ContentLayer(kind: .text, start: 0, end: 3)
        text.rect = .init(x: 0.2, y: 0.33, width: 0.6, height: 0.3)
        text.text = "ORBIT 42"; text.fontSize = 0.16; text.opacity = 1; text.fadeIn = 0; text.fadeOut = 0
        var circle = ContentLayer(kind: .circle, start: 0, end: 3)
        circle.rect = .init(x: 0.04, y: 0.08, width: 0.2, height: 0.3)
        circle.filled = true; circle.color = .init(red: 1, green: 1, blue: 0); circle.fadeIn = 0; circle.fadeOut = 0
        project.state.contentLayers = [circle, text]
        let original = try Data(contentsOf: folder.appendingPathComponent("fixture.mov"))
        let editor = ProjectEditor(project: project, url: folder.appendingPathComponent("fixture.framethrower"))
        try require(editor.save(), "Save generated fixture project")
        let playback = EditorPlayback(), host = EditorAutomationHost(editor: editor, playback: playback)
        defer { playback.close() }
        func frame(_ fields: [String: Any] = [:]) async throws -> [String: Any] {
            var args: [String: Any] = ["document_id": host.documentID, "detail": "frame"]
            fields.forEach { args[$0] = $1 }
            return try JSONSerialization.jsonObject(with: await host.performAutomation("inspect_recording", arguments: JSONSerialization.data(withJSONObject: args))) as! [String: Any]
        }
        let before = editor.project
        let preview = try await frame()
        let metadata = preview["result"] as! [String: Any]
        let image = preview["_mcp_image"] as! [String: Any]
        let jpeg = Data(base64Encoded: image["data"] as! String)!
        try require(metadata["frame_view"] as? String == "preview" && metadata["time_base"] as? String == "output" && metadata["live_desktop"] as? Bool == false,
            "Default image is the current edited recording, not desktop or raw footage")
        try require(metadata["original_pixel_width"] as? Int == 640 && metadata["original_pixel_height"] as? Int == 360,
            "Original composition geometry accompanies bounded encoded dimensions")
        try require(jpeg.count < 550 * 1024 && CGImageSourceCreateWithData(jpeg as CFData, nil) != nil, "Valid bounded native JPEG")
        try jpeg.write(to: folder.appendingPathComponent("edited-preview.jpg"))
        let log = DirectorDiagnostics(directory: folder.appendingPathComponent("logs"))
        let pixels = jpeg.base64EncodedString()
        try require(log.record("native_image", sessionID: UUID(), details: ["content": [
            ["type": "image", "data": pixels, "mimeType": "image/jpeg"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": pixels]],
            ["_mcp_image": ["mimeType": "image/jpeg", "data": pixels]]]]), "Write sanitized native-image diagnostic")
        let logged = try String(contentsOf: log.logURL, encoding: .utf8)
        try require(!logged.contains(pixels) && logged.contains("image_attachment"), "MCP and Anthropic native pixels never enter interaction logs")
        let raw = try await frame(["frame_view": "source", "time": 2.85, "time_base": "source"])
        let rawImage = raw["_mcp_image"] as! [String: Any]
        try require(Data(base64Encoded: rawImage["data"] as! String) != jpeg, "Edited graphics appear only in preview, never baked into original footage")
        try require((raw["result"] as! [String: Any])["coordinates"] as? String == "original_recorded_source", "Raw source geometry is explicit")
        let cache = DirectorInspectionCache(recordedSceneURL: nil, recordedFrameProvider: { project, time in
            try await DirectorRecordedFrameReader.sourceFrame(project: project, directory: folder, at: time)
        })
        let capabilities = cache.capabilities(supportsImages: true)
        try require(capabilities.frame, "Real recorded provider is discoverable independently of AX metadata")
        let action = DirectorInspectionAction.frame(.init(projectID: editor.automationID,
            revision: try EditorCommandDispatcher.revision(for: editor.project), sourceTime: 0.5))
        let observed = try await cache.perform(action, project: editor.project, projectID: editor.automationID, supportsImages: true)
        if case let .observation(value) = observed {
            let facts = try JSONSerialization.jsonObject(with: value.result) as! [String: Any]
            try require(facts["evidence"] as? String == "recorded_source" && value.imagePNG != nil, "Real frames are not mislabeled synthetic")
            let message = value.imageMessage(toolCallID: "actual-frame-call")!
            let imageText = (message["content"] as! [[String: Any]])[0]["text"] as! String
            let imageFacts = try JSONSerialization.jsonObject(with: Data(imageText.utf8)) as! [String: Any]
            try require(imageFacts["evidence"] as? String == "recorded_source", "Legacy native image attachment retains the real source evidence label")
        } else { throw Failure.failed("Recorded source observation missing") }
        // Finished0.8s maps to authoring1.8s after this cut. A timed green
        // overlay is visible only at the latter, so pixel checks catch passing
        // the wrong clock even when both requests happen to report0.8s.
        var timed = editor.editingState
        timed.cuts = [.init(start: 1, end: 1.5)]
        var green = ContentLayer(kind: .rectangle, start: 1.7, end: 2.1)
        green.rect = .init(x: 0, y: 0, width: 1, height: 1); green.filled = true
        green.color = .init(red: 0, green: 1, blue: 0); green.fadeIn = 0; green.fadeOut = 0
        timed.contentLayers.append(green)
        try require(editor.updateDraft(timed, at: 0.8), "Prepare timed edited preview without a saved mutation")
        let finished = try await frame(["time": 0.8, "time_base": "output"])
        let sourceClock = try await frame(["time": 0.8, "time_base": "source"])
        func frameBytes(_ value: [String: Any]) -> Data { Data(base64Encoded: (value["_mcp_image"] as! [String: Any])["data"] as! String)! }
        try require(try greenPixel(frameBytes(finished)) && !greenPixel(frameBytes(sourceClock)),
            "Finished cut clock renders source1.8s while explicit source0.8s shows the earlier scene")
        try require(abs(((finished["result"] as! [String: Any])["actual_time"] as! Double) - 0.8) < 0.11,
            "Finished actual time is reported in the requested output clock")
        try require(editor.cancelDraft(), "Cancel inspection fixture draft")
        try require(editor.project == before && Data(contentsOf: folder.appendingPathComponent("fixture.mov")) == original,
            "Frame requests preserve document/history and original media bytes")
        EditorAutomationRegistry.shared.register(host)
        defer { EditorAutomationRegistry.shared.unregister(host) }
        let backend = FrameThrowerMCPBackend(
            listTools: { try JSONSerialization.data(withJSONObject: EditorAutomationAPI.tools) },
            callTool: { name, arguments in try await EditorAutomationRegistry.shared.call(name, arguments: arguments) },
            listResources: { try await EditorAutomationRegistry.shared.resourceList() },
            readResource: { uri in try await EditorAutomationRegistry.shared.read(uri) })
        let socketDirectory = folder.appendingPathComponent("mcp", isDirectory: true)
        let server = FrameThrowerMCPServer(directory: socketDirectory)
        try await server.start(backend: backend)
        defer { server.stop() }
        let ready: [String: Any] = ["document_id": host.documentID, "recording_id": editor.automationID.uuidString,
            "socket": server.socketPath, "project": editor.url.path]
        try JSONSerialization.data(withJSONObject: ready).write(to: folder.appendingPathComponent("ready.json"))
        print("Recorded frame extraction checks passed; isolated MCP fixture ready.")
        if CommandLine.arguments.contains("--serve") {
            let deadline = ContinuousClock.now.advanced(by: .seconds(180))
            while ContinuousClock.now < deadline && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("stop").path) {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
