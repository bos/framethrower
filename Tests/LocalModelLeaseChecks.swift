import Darwin
import Foundation

private actor Factory {
    var calls = 0
    let executable: URL
    let directory: URL
    var servers: [LocalModelProcess] = []
    init(executable: URL, directory: URL) { self.executable = executable; self.directory = directory }
    func make() async throws -> LocalModelProcess {
        calls += 1
        try await Task.sleep(for: .milliseconds(80))
        let run = directory.appendingPathComponent("run-\(calls)")
        let server = try LocalModelProcess(serverURL: executable, modelURL: directory.appendingPathComponent("mock"), runDirectory: run)
        servers.append(server)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: run.appendingPathComponent("ready").path) {
            guard ContinuousClock.now < deadline else { throw CheckFailure.failed("mock child readiness timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        return server
    }
    func closeAll() async { for server in servers { await server.close() } }
}
private enum CheckFailure: Error { case failed(String) }

@main
struct LocalModelLeaseChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
    static func main() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--api-key-file") {
            let run = URL(fileURLWithPath: CommandLine.arguments[index + 1]).deletingLastPathComponent()
            _ = Darwin.signal(SIGTERM, { _ in Darwin._exit(0) })
            try Data("ready".utf8).write(to: run.appendingPathComponent("ready"))
            while true { _ = Darwin.pause() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { Darwin._exit(2) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = Factory(executable: URL(fileURLWithPath: CommandLine.arguments[0]), directory: directory)
        let runtime = LocalModelRuntime(serverFactory: { try await factory.make() })
        async let first = runtime.acquireEndpoint()
        async let second = runtime.acquireEndpoint()
        let (one, two) = try await (first, second)
        try require(await factory.calls == 1, "simultaneous leases started duplicate servers")
        try require(one.id != two.id && one.token == two.token && one.baseURL == two.baseURL, "leases did not share the authenticated server")
        try require(one.baseURL.path == "/v1" && one.model == "framethrower-local" && one.contextWindowSize == LocalModelRuntime.contextWindowSize, "incorrect endpoint or actual capacity")
        await runtime.releaseEndpoint(one); await runtime.releaseEndpoint(two)
        let third = try await runtime.acquireEndpoint()
        try require(await factory.calls == 1 && third.token == one.token, "release killed warm weights/cache")
        await runtime.releaseEndpoint(third)
        let canceled = Task { try await runtime.acquireEndpoint() }
        canceled.cancel()
        do { _ = try await canceled.value; throw CheckFailure.failed("canceled turn obtained a lease") }
        catch is CancellationError {}
        await factory.closeAll()
        do { _ = try await runtime.acquireEndpoint(); throw CheckFailure.failed("dead server silently substituted during a turn") }
        catch LocalModelError.startupFailed {}
        let recovered = try await runtime.acquireEndpoint()
        try require(await factory.calls == 2 && recovered.token != one.token, "explicit later acquire could not recover dead process")
        await runtime.releaseEndpoint(recovered)
        await factory.closeAll()
        print("Local model lease checks passed: concurrent preparation, authenticated shared endpoint, actual capacity, warm release, cancellation, dead-process failure and explicit recovery; no inference/media.")
    }
}
