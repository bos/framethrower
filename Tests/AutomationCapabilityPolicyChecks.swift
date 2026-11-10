import Foundation

private enum CapabilityPolicyFailure: Error { case failed(String) }

/// Reads capability facts and JSON only. Deliberately never rebuilds playback,
/// creates a fixture movie, decodes footage, or invokes any capture subsystem.
@main @MainActor
struct AutomationCapabilityPolicyChecks {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw CapabilityPolicyFailure.failed(message) }
    }
    static func main() async throws {
        try require(MediaProcessing.isCaptureSuspended, "Live capture must remain suspended independently of recorded-media policy")
        let project = RecordingProject(screenFilename: "unopened.mov", duration: 12)
        let editor = ProjectEditor(project: project, url: FileManager.default.temporaryDirectory.appendingPathComponent("unwritten-policy-\(UUID()).framethrower"))
        let playback = EditorPlayback(), host = EditorAutomationHost(editor: editor, playback: playback)
        defer { playback.close() }
        let original = editor.project
        let initialPlayer = playback.canvasPlayer
        let initiallyHasPlayer = playback.hasMediaPlayer
        let context = try host.automationContext
        try require(context.liveCaptureSuspended == true && context.mediaProcessingSuspended == MediaProcessing.isSuspended,
            "Native automation context distinguishes live capture from recorded processing")
        let encoded = try JSONEncoder().encode(context)
        let encodedObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        try require(encodedObject["live_capture_suspended"] as? Bool == true && encodedObject["media_processing_suspended"] as? Bool == MediaProcessing.isSuspended,
            "Native wire capability names match editor summary facts")
        try require(try JSONDecoder().decode(EditorAutomationContext.self, from: encoded) == context, "Capability facts round-trip through native JSON")
        var oldContext = encodedObject
        oldContext.removeValue(forKey: "live_capture_suspended"); oldContext.removeValue(forKey: "media_processing_suspended")
        let migrated = try JSONDecoder().decode(EditorAutomationContext.self, from: JSONSerialization.data(withJSONObject: oldContext))
        try require(migrated.liveCaptureSuspended == nil && migrated.mediaProcessingSuspended == nil,
            "Older context records do not invent capability facts")
        for section in ["summary", "view"] {
            let data = try await host.performAutomation("inspect_editor", arguments: JSONSerialization.data(withJSONObject: ["document_id": host.documentID, "section": section]))
            let reply = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let value = reply["result"] as! [String: Any]
            let nested = value["context"] as! [String: Any]
            try require(value["live_capture_suspended"] as? Bool == true && value["media_processing_suspended"] as? Bool == MediaProcessing.isSuspended,
                "Summary preserves recorded policy while reporting capture policy separately")
            try require(nested["live_capture_suspended"] as? Bool == true && nested["media_processing_suspended"] as? Bool == MediaProcessing.isSuspended,
                "Native view carries the same separate policy facts")
        }
        if CommandLine.arguments.contains("--expect-recorded-enabled") { try require(!MediaProcessing.isSuspended, "Normal policy enables recorded video independently") }
        if CommandLine.arguments.contains("--expect-vector-preview") { try require(MediaProcessing.isSuspended, "Explicit vector fixture mode suspends recorded video") }
        try require(editor.project == original && playback.hasMediaPlayer == initiallyHasPlayer && playback.canvasPlayer === initialPlayer,
            "Capability inspection changes neither document/history nor the initial empty-player allocation")
        print("Automation capability policy checks passed (separate live/recorded facts, native JSON compatibility, metadata-only summary/view; no capture/media).")
    }
}
