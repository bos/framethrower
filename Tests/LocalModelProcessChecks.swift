import Darwin
import Foundation

@main
struct LocalModelProcessChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--model"), CommandLine.arguments.indices.contains(index + 1) {
            try child(mode: URL(fileURLWithPath: CommandLine.arguments[index + 1]).lastPathComponent)
            return
        }
        // A hung cleanup must fail independently of Swift's cooperative pool.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("Local process cleanup exceeded 20 seconds\n".utf8))
            Darwin.exit(1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        for mode in ["natural-exit", "graceful", "ignore-term", "cancelled-close"] {
            let run = directory.appendingPathComponent(mode)
            let server = try LocalModelProcess(serverURL: executable, modelURL: directory.appendingPathComponent(mode), runDirectory: run)
            let pid = try await ready(in: run)
            defer { if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) } }
            if mode == "natural-exit" { try await waitForDisappearance(pid) }
            let key = run.appendingPathComponent("server.key")
            guard FileManager.default.fileExists(atPath: key.path) else { throw Failure.failed("Missing private key before shutdown") }
            let started = ContinuousClock.now
            let cleanup = Task { await server.close() }
            if mode == "cancelled-close" { cleanup.cancel() }
            await cleanup.value
            let elapsed = ContinuousClock.now - started
            guard elapsed < .seconds(4) else { throw Failure.failed("\(mode) cleanup was not bounded") }
            try await waitForDisappearance(pid)
            guard !FileManager.default.fileExists(atPath: key.path) else { throw Failure.failed("\(mode) leaked an authentication key") }
            await server.close()
            print("Local process cleanup: \(mode) passed in \(elapsed)")
        }
        // The synchronous app-termination bridge must still kill its owned
        // child and erase the key; a later close also remains safe.
        let run = directory.appendingPathComponent("app-termination")
        let server = try LocalModelProcess(serverURL: executable, modelURL: directory.appendingPathComponent("ignore-term"), runDirectory: run)
        let pid = try await ready(in: run)
        defer { if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) } }
        LocalModelRuntime.terminateOwnedProcess()
        await server.close()
        try await waitForDisappearance(pid)
        guard !FileManager.default.fileExists(atPath: run.appendingPathComponent("server.key").path) else {
            throw Failure.failed("App termination leaked its key")
        }
        print("Local model process checks passed (already-exited, graceful, forced and cancelled shutdown, repeated close, app termination, actual child removal and private-key cleanup; no inference or media).")
    }

    private static func child(mode: String) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--api-key-file"), CommandLine.arguments.indices.contains(index + 1) else {
            throw Failure.failed("Missing fixture key path")
        }
        if mode == "ignore-term" || mode == "cancelled-close" { _ = Darwin.signal(SIGTERM, SIG_IGN) }
        else { _ = Darwin.signal(SIGTERM, { _ in Darwin._exit(0) }) }
        let run = URL(fileURLWithPath: CommandLine.arguments[index + 1]).deletingLastPathComponent()
        try Data(String(Darwin.getpid()).utf8).write(to: run.appendingPathComponent("ready"), options: .atomic)
        if mode == "natural-exit" { Darwin._exit(0) }
        while true { _ = Darwin.pause() }
    }

    private static func ready(in directory: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        let url = directory.appendingPathComponent("ready")
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text), pid > 0 { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.failed("Tiny child never became ready")
    }

    private static func waitForDisappearance(_ pid: pid_t) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.failed("Child \(pid) survived cleanup")
    }
}
