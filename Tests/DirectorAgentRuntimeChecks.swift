import Foundation

private enum NativeRuntimeFailure: Error { case failed(String) }
@main
struct DirectorAgentRuntimeChecks {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NativeRuntimeFailure.failed(message) }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("fake-native-helper.py")
        try Data("""
        import json,sys
        value=json.load(sys.stdin)
        json.dump({'ok':True,'captured':value},sys.stdout)
        """.utf8).write(to: helper)
        let runtime = DirectorAgentRuntime()
        let project = root.appendingPathComponent("same-path.framethrower")
        let recording = UUID().uuidString, otherRecording = UUID().uuidString
        func turn(_ id: String, provider: DirectorProvider) async throws -> [String: Any] {
            let input = try JSONSerialization.data(withJSONObject: ["text": "Inspect only.",
                "document_id": "open-document", "recording_id": id, "editor_events": []])
            let output = try await runtime.turn(request: input, projectURL: project, provider: provider,
                helperURL: helper, proxyURL: helper, sessionRoot: root.appendingPathComponent("sessions"))
            return (try JSONSerialization.jsonObject(with: output) as! [String: Any])["captured"] as! [String: Any]
        }
        let first = try await turn(recording, provider: .claudeSonnet)
        let changedModel = try await turn(recording, provider: .claudeHaiku)
        let replaced = try await turn(otherRecording, provider: .claudeSonnet)
        let otherProvider = try await turn(recording, provider: .openAIBalanced)
        let a = first["configuration"] as! [String: Any], b = changedModel["configuration"] as! [String: Any]
        let c = replaced["configuration"] as! [String: Any], d = otherProvider["configuration"] as! [String: Any]
        try require(a["cwd"] as? String == b["cwd"] as? String, "Model changes within a provider must retain native conversation scope")
        try require(a["cwd"] as? String != c["cwd"] as? String, "A replaced recording at the same path must not inherit the previous conversation")
        try require(a["cwd"] as? String != d["cwd"] as? String, "Different native providers must not share their transcript bindings")
        try require(a["recording_id"] as? String == recording && a["document_id"] as? String == "open-document", "Persistent identity and current open scope must both reach broker")
        try require((first["request"] as? [String: Any])?["text"] as? String == "Inspect only.", "The bridge preserves the literal new turn")
        print("Native agent runtime checks passed: real helper process, same-family model resume scope, replaced-recording separation and independent provider bindings; no CLI/model/media/GUI.")
    }
}
