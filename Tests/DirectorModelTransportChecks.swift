import Darwin
import Foundation

@main struct DirectorModelTransportChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure.failed(message) }
    }
    static func main() async throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("framethrower-transport-check-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake.py")
        try #"""
import json,os,sys,time,pathlib
p=json.load(sys.stdin)
mode=p.get('mode','echo')
if mode=='sleep':
 pathlib.Path(__file__).with_suffix('.pid').write_text(str(os.getpid()))
 time.sleep(30)
if mode=='auth':
 print(json.dumps({'error':{'code':'authentication','message':'Sign in using the installed provider CLI.'}}),file=sys.stderr)
 sys.exit(1)
if mode=='invalid':
 print('this is not a model response')
 sys.exit(0)
print(json.dumps({'choices':[{'message':{'role':'assistant','tool_calls':[{'id':'call-check','type':'function','function':{'name':'ask_clarification','arguments':'{"question":"Which box?"}'}}]}}],'echo':p,'argv':sys.argv[1:]}))
"""#.write(to: helper, atomically: true, encoding: .utf8)
        let payload = try JSONSerialization.data(withJSONObject: ["messages": [["role": "user", "content": String(repeating: "A", count: 200_000)]]])
        let response = try await DirectorModelTransport.chat(payload: payload, provider: .claudeSonnet, helperURL: helper)
        let decoded = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        let echo = decoded["echo"] as! [String: Any]
        let argv = decoded["argv"] as! [String]
        try require((echo["messages"] as? [[String: String]])?.first?["content"]?.count == 200_000 &&
                    argv.contains("claude-sonnet-5-5") && argv.contains("claude") && argv.contains("medium"),
                    "Large stdin and exact model/effort survive without a shell or blocking pipe")
        do {
            _ = try await DirectorModelTransport.chat(payload: Data(#"{"mode":"auth"}"#.utf8), provider: .openAIBalanced, helperURL: helper)
            throw Failure.failed("Authentication failure was accepted")
        } catch DirectorModelError.rejected(let message) {
            try require(message == "Sign in using the installed provider CLI.", "Only the bounded structured error reaches the UI")
        }
        do {
            _ = try await DirectorModelTransport.chat(payload: Data(#"{"mode":"invalid"}"#.utf8), provider: .claudeHaiku, helperURL: helper)
            throw Failure.failed("Malformed response was accepted")
        } catch DirectorModelError.invalidResponse {}
        let pending = Task {
            try await DirectorModelTransport.chat(payload: Data(#"{"mode":"sleep"}"#.utf8), provider: .openAIFast, helperURL: helper)
        }
        let pidURL = helper.deletingPathExtension().appendingPathExtension("pid")
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !files.fileExists(atPath: pidURL.path) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let pidText = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(pidText) else {
            pending.cancel(); throw Failure.failed("Cancellation fixture never started")
        }
        do {
            _ = try await DirectorModelTransport.chat(payload: Data("{}".utf8), provider: .claudeHaiku, helperURL: helper)
            pending.cancel(); throw Failure.failed("Parallel CLI request bypassed ownership guard")
        } catch DirectorModelError.busy {}
        let cancelledAt = ContinuousClock.now
        pending.cancel()
        do { _ = try await pending.value; throw Failure.failed("Canceled request succeeded") }
        catch is CancellationError {}
        try require(cancelledAt.duration(to: .now) < .seconds(4) && kill(pid, 0) != 0 && errno == ESRCH,
                    "Cancellation reaps the exact helper and returns promptly")
        let later = try await DirectorModelTransport.chat(payload: Data("{}".utf8), provider: .openAIBalanced, helperURL: helper)
        try require(!later.isEmpty, "Canceled ownership is released for the next request")
        print("Director transport checks passed (large input, pinned model/effort, safe errors, malformed response, ownership, cancellation and recovery; fake helper only).")
    }
}
