import Combine
import Darwin
import Foundation

/// A usable transport, not merely an installed application's name. Nothing in
/// this file probes the machine until DirectorConnections.open() is called.
struct DirectorConnection: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case localModel, claude, codex, chatGPT }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    var executable: String? = nil
    var accountID: String? = nil

    var providers: [DirectorProvider] {
        switch kind {
        case .localModel: [.localQwen]
        case .claude: [.claudeHaiku, .claudeSonnet]
        case .codex, .chatGPT: [.openAIFast, .openAIBalanced]
        }
    }
    var defaultProvider: DirectorProvider {
        switch kind {
        case .localModel: .localQwen
        case .claude: .claudeSonnet
        case .codex, .chatGPT: .openAIBalanced
        }
    }
}

struct DirectorRemoteModel: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

@MainActor
final class DirectorConnections: ObservableObject {
    static let preferenceKey = "director.connection"
    @Published private(set) var available: [DirectorConnection] = []
    @Published private(set) var selected: DirectorConnection?
    @Published private(set) var models: [DirectorRemoteModel] = []
    @Published var modelID = ""
    @Published private(set) var isChecking = false
    @Published private(set) var isConnecting = false
    @Published private(set) var error: String?
    @Published var showsChooser = true
    private let discover: @Sendable () async throws -> [DirectorConnection]
    private let fetchModels: @Sendable (String) async throws -> [DirectorRemoteModel]
    private let accounts: DirectorChatGPTAccounts
    private let preferences: UserDefaults
    private var work: Task<Void, Never>?
    private var workID = UUID()
    private var opening: Task<Void, Never>?
    private var openingID = UUID()
    private var generation = UUID()
    private(set) var isOpen = false

    init(preferences: UserDefaults = .standard, accounts: DirectorChatGPTAccounts = .shared,
         discover: (@Sendable () async throws -> [DirectorConnection])? = nil,
         fetchModels: (@Sendable (String) async throws -> [DirectorRemoteModel])? = nil) {
        self.preferences = preferences
        self.accounts = accounts
        self.discover = discover ?? { try await DirectorConnectionDiscovery.discover() }
        self.fetchModels = fetchModels ?? { try await accounts.models(accountID: $0) }
    }
    deinit { work?.cancel(); opening?.cancel() }

    func open() async {
        guard !isOpen, !Task.isCancelled else { return }
        isOpen = true
        let id = UUID(); openingID = id
        let discovery = Task<Void, Never> { [weak self] in await self?.refresh() }
        opening = discovery
        await withTaskCancellationHandler { await discovery.value } onCancel: { discovery.cancel() }
        if openingID == id { opening = nil }
    }

    func refresh() async {
        guard isOpen, !isConnecting else { return }
        let token = UUID(); generation = token
        isChecking = true; error = nil
        defer { if generation == token { isChecking = false } }
        do {
            var found = try await discover()
            try Task.checkCancellation()
            do { found += try await accounts.connections() }
            catch { self.error = error.localizedDescription }
            guard isOpen, generation == token else { return }
            available = found
            let previous = selected?.id ?? preferences.string(forKey: Self.preferenceKey)
            if let previous, let connection = found.first(where: { $0.id == previous }) {
                // A remembered choice is restored only after opening Director.
                await choose(connection)
            } else {
                selected = nil; models = []; modelID = ""; showsChooser = true
            }
        } catch is CancellationError { }
        catch {
            guard isOpen, generation == token else { return }
            self.error = "Could not check Director connections. Try again or connect ChatGPT."
        }
    }

    func choose(_ connection: DirectorConnection) async {
        guard isOpen, !Task.isCancelled else { return }
        let operation = generation
        error = nil
        if connection.kind == .chatGPT {
            isConnecting = true
            defer { if generation == operation { isConnecting = false } }
            do {
                guard let accountID = connection.accountID else {
                    throw DirectorConnectionError.message("This ChatGPT connection is incomplete. Sign in again.")
                }
                let catalog = try await fetchModels(accountID)
                try Task.checkCancellation()
                guard isOpen, generation == operation else { return }
                guard !catalog.isEmpty else { throw DirectorConnectionError.message("This account has no available Director models. Choose another account or provider.") }
                models = catalog
                let saved = preferences.string(forKey: "director.remoteModel." + connection.id)
                modelID = catalog.first(where: { $0.id == saved })?.id
                    ?? catalog.first(where: { $0.id == DirectorProvider.openAIBalanced.modelID })?.id ?? catalog[0].id
            } catch is CancellationError { return }
            catch {
                if isOpen, generation == operation { self.error = error.localizedDescription; showsChooser = true }
                return
            }
        } else { models = []; modelID = "" }
        selected = connection; showsChooser = false
        preferences.set(connection.id, forKey: Self.preferenceKey)
    }

    func select(_ connection: DirectorConnection) {
        guard isOpen, !isChecking, !isConnecting else { return }
        startWork { await $0.choose(connection) }
    }

    func checkAgain() {
        guard !isChecking, !isConnecting else { return }
        startWork { await $0.refresh() }
    }

    func connectChatGPT(accountID: String? = nil) {
        guard isOpen, !isChecking, !isConnecting else { return }
        error = nil; isConnecting = true
        startWork { connectionState in
            do {
                let connection = try await connectionState.accounts.signIn(accountID: accountID)
                try Task.checkCancellation()
                guard connectionState.isOpen else { return }
                connectionState.available.removeAll { $0.id == connection.id }; connectionState.available.append(connection)
                await connectionState.choose(connection)
            } catch is CancellationError { }
            catch { if connectionState.isOpen { connectionState.error = error.localizedDescription } }
        }
    }

    private func startWork(_ action: @escaping @MainActor @Sendable (DirectorConnections) async -> Void) {
        work?.cancel()
        let id = UUID(); workID = id
        work = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await action(self)
            if self.workID == id { self.work = nil; self.isConnecting = false }
        }
    }

    func saveModelPreference() {
        if let selected, selected.kind == .chatGPT {
            preferences.set(modelID, forKey: "director.remoteModel." + selected.id)
        }
    }

    func reportFailure(_ message: String) {
        error = message
        showsChooser = true
    }

    func close() {
        isOpen = false; generation = UUID()
        workID = UUID(); openingID = UUID()
        work?.cancel(); work = nil
        opening?.cancel(); opening = nil
        isChecking = false; isConnecting = false
    }

    func cancelConnection() { work?.cancel(); opening?.cancel() }
}

enum DirectorConnectionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}

enum DirectorConnectionDiscovery {
    static var python: String? {
        let developerRoots = ["/Library/Developer/CommandLineTools", "/Applications/Xcode.app/Contents/Developer"]
            + (ProcessInfo.processInfo.environment["DEVELOPER_DIR"].map { [$0] } ?? [])
        return pythonPath(isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            hasDeveloperTools: developerRoots.contains { FileManager.default.isExecutableFile(atPath: $0 + "/usr/bin/python3") })
    }

    static func pythonPath(isExecutable: (String) -> Bool, hasDeveloperTools: Bool) -> String? {
        // On a fresh Mac /usr/bin/python3 is an executable installer shim.
        // Never invoke it to discover whether Python exists: that can open the
        // Xcode tools installer. Such Macs should use direct provider sign-in.
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            + (hasDeveloperTools ? ["/usr/bin/python3"] : [])
        return candidates.first(where: isExecutable)
    }

    static func discover() async throws -> [DirectorConnection] {
        // The existing native bridge needs Python. Remote connections do not.
        guard python != nil else { return [] }
        var found: [DirectorConnection] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let qwen = home.appendingPathComponent("Library/Caches/FrameThrower/DirectorAgents/QwenCode/0.27.0/node_modules/.bin/qwen").path
        if LocalModelRuntime.isInstalled, FileManager.default.isExecutableFile(atPath: qwen),
           (try? LocalModelRuntime.modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) == LocalModelRuntime.modelBytes {
            found.append(.init(id: "local-qwen", kind: .localModel, title: "Qwen", detail: "Runs on this Mac", executable: qwen))
        }
        let bins = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        for family in ["claude", "codex"] {
            var paths = bins.map { $0 + "/" + family }
            if family == "codex" {
                for directory in ["/Applications", home.appendingPathComponent("Applications").path] {
                    paths += [directory + "/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                              directory + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
                }
            }
            var visited = Set<String>()
            for path in paths where FileManager.default.isExecutableFile(atPath: path) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { return found }
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard visited.insert(resolved).inserted else { continue }
                do {
                    let help = try await DirectorProbe.run(path, arguments: ["--help"], timeout: 1.5)
                    let required = family == "claude" ? ["--restricted", "--strict-mcp-config"] : ["--no-daemon"]
                    guard help.status == 0, required.allSatisfy({ help.text.contains($0) }) else { continue }
                    if family == "codex" {
                        let isolated = try await DirectorProbe.run(path, arguments: ["--no-daemon", "--ignore-user-config", "--ignore-rules", "--strict-config", "--help"], timeout: 1.5)
                        guard isolated.status == 0 else { continue }
                    }
                    let status = try await DirectorProbe.run(path, arguments: family == "claude" ? ["auth", "status", "--json"] : ["login", "status"], timeout: 1.5)
                    guard status.status == 0 else { continue }
                    if family == "claude" {
                        guard let value = try? JSONSerialization.jsonObject(with: Data(status.text.utf8)) as? [String: Any],
                              value["loggedIn"] as? Bool == true else { continue }
                    }
                    let app = path.contains(".app/")
                    found.append(.init(id: "native-" + family, kind: family == "claude" ? .claude : .codex,
                        title: family == "claude" ? "Claude" : "ChatGPT",
                        detail: app ? "Connected through ChatGPT on this Mac" : "Connected on this Mac", executable: path))
                    break
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
        }
        return found
    }
}

/// Status/help only: no inference, shell, device, sign-in, or runtime install.
enum DirectorProbe {
    struct Result: Sendable { let status: Int32; let text: String }
    static func run(_ executable: String, arguments: [String], timeout: Double = 4) async throws -> Result {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "OPENAI_API_KEY", "OPENAI_BASE_URL"] { environment.removeValue(forKey: key) }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        let capture = DirectorProbeCapture()
        output.fileHandleForReading.readabilityHandler = { handle in capture.append(handle.availableData) }
        defer { output.fileHandleForReading.readabilityHandler = nil; try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        try process.run()
        // The child owns its copy; closing ours lets EOF confirm that all status
        // output has been captured before inspecting it.
        try output.fileHandleForWriting.close()
        return try await withTaskCancellationHandler {
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            do {
            while process.isRunning || !capture.finished {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else {
                    throw DirectorConnectionError.message("The installed provider did not respond.")
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            return Result(status: process.terminationStatus, text: capture.text)
            } catch {
                if process.isRunning { process.terminate() }
                let grace = ContinuousClock.now.advanced(by: .milliseconds(200))
                while process.isRunning && ContinuousClock.now < grace {
                    await Task.detached { try? await Task.sleep(for: .milliseconds(10)) }.value
                }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                throw error
            }
        } onCancel: { if process.isRunning { process.terminate() } }
    }
}

private final class DirectorProbeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; if bytes.isEmpty { ended = true }; if data.count < 128 * 1024 { data.append(bytes.prefix(128 * 1024 - data.count)) } }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
