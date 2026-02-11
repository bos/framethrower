import AppKit
import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import SwiftUI

@MainActor
final class CaptureViewModel: ObservableObject {
    enum LogLevel {
        case info
        case error
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
        let level: LogLevel
    }

    @Published var captureKind: CaptureSourceKind = .window {
        didSet { handleCaptureKindChanged() }
    }
    @Published var windows: [ShareableWindow] = []
    @Published var displays: [ShareableDisplay] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var area = CaptureArea()

    @Published var isRecording = false {
        didSet { updateSourceRefreshScheduling() }
    }
    @Published var isUploading = false
    @Published var statusMessage = ""
    @Published var logs: [LogEntry] = []
    @Published var lastRecordingURL: URL? {
        didSet { updateRecordingAvailability() }
    }
    @Published private(set) var hasRecordingToUpload = false
    @Published var lastDriveFileURL: URL?
    @Published var lastSlackFileURL: URL?

    @Published var slackTargetKind: SlackTargetKind = .person {
        didSet { persistSlackSelection() }
    }
    @Published var slackChannels: [SlackChannel] = []
    @Published var slackUsers: [SlackUser] = []
    @Published var selectedSlackChannelID: String? {
        didSet { persistSlackSelection() }
    }
    @Published var selectedSlackUserID: String? {
        didSet { persistSlackSelection() }
    }
    @Published var isSlackUploading = false
    @Published var isSlackRefreshing = false
    @Published var hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    @Published var microphones: [MicrophoneDevice] = []
    @Published var selectedMicrophoneID: String? {
        didSet { persistAudioSettings() }
    }
    @Published var recordSystemAudio = false {
        didSet { persistAudioSettings() }
    }
    @Published var recordMicrophoneAudio = false {
        didSet { persistAudioSettings() }
    }
    @Published var hasMicrophonePermission = (
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    )

    private var clientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GDriveClientID") as? String ?? ""
    }

    private var clientSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "GDriveClientSecret") as? String ?? ""
    }

    private var slackClientID: String {
        Bundle.main.object(forInfoDictionaryKey: "SlackClientID") as? String ?? ""
    }

    private var slackClientSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "SlackClientSecret") as? String ?? ""
    }

    private let recorder = ScreenRecorder()
    private let uploader = DriveUploader()
    private let tokenStorageKey = "drive.tokens"
    private let slackTokenStorageKey = "slack.tokens"
    private let slackTargetKindKey = "slack.targetKind"
    private let slackSelectedUserKey = "slack.selectedUserID"
    private let slackSelectedChannelKey = "slack.selectedChannelID"
    private let slackCachedUsersKey = "slack.cachedUsers"
    private let slackCachedChannelsKey = "slack.cachedChannels"
    private let recordSystemAudioKey = "audio.recordSystem"
    private let recordMicrophoneAudioKey = "audio.recordMicrophone"
    private let selectedMicrophoneIDKey = "audio.selectedMicrophoneID"
    private let userDefaults = UserDefaults.standard
    private let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Screencast.log")
    private let clipboardTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
    private var activeRecordingURL: URL?
    private var sourceRefreshObservers: [any NSObjectProtocol] = []
    private var sourceRefreshTimer: Timer?
    private var isSourceRefreshConfigured = false
    private var isSourceRefreshing = false
    private var isAppActive = false

    private var tokens: OAuthTokens? {
        didSet { persistTokens() }
    }

    private var slackTokens: SlackTokens? {
        didSet { persistSlackTokens() }
    }

    var isAuthorized: Bool {
        tokens != nil
    }

    var isSlackAuthorized: Bool {
        slackTokens != nil
    }

    var selectedWindow: ShareableWindow? {
        guard let id = selectedWindowID else { return nil }
        return windows.first(where: { $0.id == id })
    }

    func requestScreenRecordingPermission() {
        let preflight = CGPreflightScreenCaptureAccess()
        if preflight {
            hasScreenRecordingPermission = true
            return
        }
        let granted = CGRequestScreenCaptureAccess()
        hasScreenRecordingPermission = granted
        if granted {
            log("Screen recording permission granted. Restart the app if needed.")
        } else {
            log("Screen recording permission denied.", level: .error)
        }
    }

    func startSourceAutoRefresh() {
        guard !isSourceRefreshConfigured else { return }
        isSourceRefreshConfigured = true
        isAppActive = NSApp.isActive
        registerSourceRefreshObservers()
        updateSourceRefreshScheduling()
    }

    func stopSourceAutoRefresh() {
        guard isSourceRefreshConfigured else { return }
        isSourceRefreshConfigured = false
        sourceRefreshTimer?.invalidate()
        sourceRefreshTimer = nil
        for observer in sourceRefreshObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sourceRefreshObservers.removeAll()
    }

    func refreshSources(logSuccess: Bool = true, logErrors: Bool = true) async {
        guard !isSourceRefreshing else { return }
        isSourceRefreshing = true
        defer { isSourceRefreshing = false }

        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        guard hasScreenRecordingPermission else {
            windows = []
            displays = []
            selectedWindowID = nil
            selectedDisplayID = nil
            if logErrors {
                log("Screen recording permission is required.", level: .error)
            }
            return
        }

        let previousWindowID = selectedWindowID
        let previousDisplayID = selectedDisplayID
        do {
            let content = try await shareableContent()
            let allWindows = content.windows.map(ShareableWindow.init)
            let appBundleID = Bundle.main.bundleIdentifier
            windows = allWindows
                .filter { $0.isSelectable }
                .filter { window in
                    guard let appBundleID else { return true }
                    return window.bundleIdentifier != appBundleID
                }
                .sorted { lhs, rhs in
                    if lhs.owningApplication != rhs.owningApplication {
                        return lhs.owningApplication < rhs.owningApplication
                    }
                    if lhs.title != rhs.title {
                        return lhs.title < rhs.title
                    }
                    return lhs.id < rhs.id
                }
            displays = content.displays.map(ShareableDisplay.init)
            if let previousWindowID,
               windows.contains(where: { $0.id == previousWindowID }) {
                selectedWindowID = previousWindowID
            } else {
                selectedWindowID = windows.first?.id
            }
            if let previousDisplayID,
               displays.contains(where: { $0.id == previousDisplayID }) {
                selectedDisplayID = previousDisplayID
            } else {
                selectedDisplayID = displays.first?.id
            }
            if logSuccess {
                log("Sources refreshed. Showing \(windows.count) windows.")
            }
        } catch {
            if logErrors {
                log("Failed to load sources: \(error.localizedDescription)", level: .error)
            }
        }
    }

    private func handleCaptureKindChanged() {
        updateSourceRefreshScheduling()
        sourceRefreshTriggered(force: true)
    }

    private func registerSourceRefreshObservers() {
        let center = NotificationCenter.default
        sourceRefreshObservers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAppActive = true
                    self.updateSourceRefreshScheduling()
                    self.sourceRefreshTriggered(force: true)
                }
            }
        )
        sourceRefreshObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isAppActive = false
                    self.updateSourceRefreshScheduling()
                }
            }
        )
        sourceRefreshObservers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sourceRefreshTriggered(force: true)
                }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        sourceRefreshObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sourceRefreshTriggered(force: true)
                }
            }
        )
        sourceRefreshObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sourceRefreshTriggered(force: true)
                }
            }
        )
        sourceRefreshObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sourceRefreshTriggered(force: true)
                }
            }
        )
    }

    private func updateSourceRefreshScheduling() {
        let shouldRunTimer = isSourceRefreshConfigured &&
            isAppActive &&
            !isRecording &&
            captureKind == .window

        if !shouldRunTimer {
            sourceRefreshTimer?.invalidate()
            sourceRefreshTimer = nil
            return
        }
        if sourceRefreshTimer != nil {
            return
        }
        let timer = Timer(
            timeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sourceRefreshTriggered(force: false)
            }
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        sourceRefreshTimer = timer
    }

    private func sourceRefreshTriggered(force: Bool) {
        if !force {
            guard isSourceRefreshConfigured,
                  isAppActive,
                  !isRecording,
                  captureKind == .window else {
                return
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshSources(logSuccess: false, logErrors: false)
        }
    }

    func selectArea() async {
        guard captureKind == .area else { return }
        let frame = selectedDisplayFrame() ?? NSScreen.main?.frame ?? .zero
        guard frame.width >= 2, frame.height >= 2 else {
            log("No display available for area selection.", level: .error)
            return
        }
        let hiddenWindows = hideMainWindowsForSelection()
        defer { restoreMainWindowsAfterSelection(hiddenWindows) }
        do {
            let selected = try await AreaSelectionCoordinator.selectArea(in: frame)
            area = CaptureArea(
                x: selected.origin.x,
                y: selected.origin.y,
                width: selected.width,
                height: selected.height
            )
            log("Area selected.")
        } catch AreaSelectionError.cancelled {
            log("Area selection cancelled.")
        } catch {
            log("Area selection failed: \(error.localizedDescription)", level: .error)
        }
    }

    func selectWindow() async {
        guard captureKind == .window else { return }
        guard hasScreenRecordingPermission else {
            log("Enable Screen Recording permission and restart the app.", level: .error)
            return
        }
        await refreshSources(logSuccess: false, logErrors: false)
        let hiddenWindows = hideMainWindowsForSelection()
        defer { restoreMainWindowsAfterSelection(hiddenWindows) }

        do {
            let bundleID = Bundle.main.bundleIdentifier
            let selectedID = try await WindowSelectionCoordinator.selectWindow(
                excludingBundleID: bundleID
            ) { [weak self] message in
                self?.log(message)
            }
            if windows.isEmpty {
                await refreshSources()
            }
            if windows.contains(where: { $0.id == selectedID }) {
                selectedWindowID = selectedID
                log("Window selected.")
            } else {
                selectedWindowID = selectedID
                log("Window selected. If it is missing from the list, refresh sources.")
            }
        } catch WindowSelectionError.cancelled {
            log("Window selection cancelled.")
        } catch {
            log("Window selection failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func hideMainWindowsForSelection() -> [NSWindow] {
        let windowsToHide = NSApp.windows.filter { window in
            guard window.isVisible else { return false }
            guard window.level == .normal else { return false }
            return window.styleMask.contains(.titled)
        }
        for window in windowsToHide {
            window.orderOut(nil)
        }
        return windowsToHide
    }

    private func restoreMainWindowsAfterSelection(_ windows: [NSWindow]) {
        guard !windows.isEmpty else { return }
        for window in windows {
            window.orderFront(nil)
        }
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func loadTokens() {
        guard let data = userDefaults.data(forKey: tokenStorageKey) else {
            tokens = nil
            return
        }
        tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    func loadAudioSettings() {
        recordSystemAudio = userDefaults.bool(forKey: recordSystemAudioKey)
        recordMicrophoneAudio = userDefaults.bool(forKey: recordMicrophoneAudioKey)
        selectedMicrophoneID = userDefaults.string(forKey: selectedMicrophoneIDKey)
        refreshMicrophonePermissionState()
        refreshMicrophones()
    }

    func loadSlackTokens() {
        loadSlackCachedTargets()
        guard let data = userDefaults.data(forKey: slackTokenStorageKey) else {
            slackTokens = nil
            return
        }
        slackTokens = try? JSONDecoder().decode(SlackTokens.self, from: data)
        loadSlackSelection()
        if slackTokens != nil {
            Task { await refreshSlackTargets() }
        }
    }

    func loadSlackSelection() {
        if let raw = userDefaults.string(forKey: slackTargetKindKey),
           let kind = SlackTargetKind(rawValue: raw) {
            slackTargetKind = kind
        }
        if let savedUserID = userDefaults.string(forKey: slackSelectedUserKey) {
            selectedSlackUserID = savedUserID
        }
        if let savedChannelID = userDefaults.string(forKey: slackSelectedChannelKey) {
            selectedSlackChannelID = savedChannelID
        }
    }

    private func persistSlackSelection() {
        userDefaults.set(slackTargetKind.rawValue, forKey: slackTargetKindKey)
        userDefaults.set(selectedSlackUserID, forKey: slackSelectedUserKey)
        userDefaults.set(selectedSlackChannelID, forKey: slackSelectedChannelKey)
    }

    private func loadSlackCachedTargets() {
        if let data = userDefaults.data(forKey: slackCachedChannelsKey),
           let cached = try? JSONDecoder().decode([SlackChannel].self, from: data) {
            slackChannels = cached
            if selectedSlackChannelID == nil {
                selectedSlackChannelID = slackChannels.first?.id
            }
        }
        if let data = userDefaults.data(forKey: slackCachedUsersKey),
           let cached = try? JSONDecoder().decode([SlackUser].self, from: data) {
            slackUsers = cached
            if selectedSlackUserID == nil {
                selectedSlackUserID = slackUsers.first?.id
            }
        }
    }

    private func persistSlackCachedTargets() {
        if let data = try? JSONEncoder().encode(slackChannels) {
            userDefaults.set(data, forKey: slackCachedChannelsKey)
        }
        if let data = try? JSONEncoder().encode(slackUsers) {
            userDefaults.set(data, forKey: slackCachedUsersKey)
        }
    }

    func authorize() async {
        guard !clientID.isEmpty else {
            log("Missing Google OAuth client ID in Info.plist.", level: .error)
            return
        }
        guard !clientSecret.isEmpty else {
            log("Missing Google OAuth client secret in Info.plist.", level: .error)
            return
        }

        let redirect = "http://127.0.0.1:0/oauth"
        let config = OAuthConfig(
            clientID: clientID,
            redirectURI: redirect,
            scopes: ["https://www.googleapis.com/auth/drive"],
            clientSecret: clientSecret
        )

        do {
            let client = OAuthClient(config: config)
            let (newTokens, _) = try await client.authorize()
            tokens = newTokens
            log("Signed in to Google Drive.")
        } catch {
            log("Auth failed: \(error.localizedDescription)", level: .error)
        }
    }

    func connectSlack() async {
        guard !slackClientID.isEmpty else {
            log("Missing Slack client ID in Info.plist.", level: .error)
            return
        }
        guard !slackClientSecret.isEmpty else {
            log("Missing Slack client secret in Info.plist.", level: .error)
            return
        }

        let config = SlackOAuthConfig(
            clientID: slackClientID,
            clientSecret: slackClientSecret,
            redirectURI: slackRedirectURI,
            userScopes: slackScopes
        )

        do {
            let client = SlackOAuthClient(config: config)
            let tokens = try await client.authorize()
            slackTokens = tokens
            log("Connected to Slack.")
            await refreshSlackTargets()
        } catch {
            log("Slack auth failed: \(error.localizedDescription)", level: .error)
        }
    }

    func signOutSlack() {
        userDefaults.removeObject(forKey: slackTokenStorageKey)
        userDefaults.removeObject(forKey: slackTargetKindKey)
        userDefaults.removeObject(forKey: slackSelectedUserKey)
        userDefaults.removeObject(forKey: slackSelectedChannelKey)
        slackTokens = nil
        slackChannels = []
        slackUsers = []
        selectedSlackChannelID = nil
        selectedSlackUserID = nil
        lastSlackFileURL = nil
    }

    func refreshSlackTargets() async {
        guard let token = slackTokens?.accessToken else {
            log("Connect Slack first.", level: .error)
            return
        }
        isSlackRefreshing = true
        defer { isSlackRefreshing = false }
        do {
            let api = SlackAPI(token: token)
            let channels = try await api.listChannels()
            let users = try await api.listUsers()
            let channelList = channels.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            let userList = users.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            slackChannels = channelList

            let currentUserID = slackTokens?.userID
            if let currentUserID, let index = userList.firstIndex(where: { $0.id == currentUserID }) {
                var reordered = userList
                let currentUser = reordered.remove(at: index)
                slackUsers = [currentUser] + reordered
            } else {
                slackUsers = userList
            }
            if let savedUserID = selectedSlackUserID,
               slackUsers.contains(where: { $0.id == savedUserID }) {
                selectedSlackUserID = savedUserID
            } else if let currentUserID, slackUsers.contains(where: { $0.id == currentUserID }) {
                selectedSlackUserID = currentUserID
            } else {
                selectedSlackUserID = slackUsers.first?.id
            }

            if let savedChannelID = selectedSlackChannelID,
               channelList.contains(where: { $0.id == savedChannelID }) {
                selectedSlackChannelID = savedChannelID
            } else {
                selectedSlackChannelID = channelList.first?.id
            }
            persistSlackCachedTargets()
            log("Slack targets refreshed.")
        } catch {
            log("Slack refresh failed: \(error.localizedDescription)", level: .error)
        }
    }

    func uploadLastRecordingToSlack() async {
        guard let fileURL = resolveRecordingURL() else {
            log("Record something first.", level: .error)
            return
        }
        guard let token = slackTokens?.accessToken else {
            log("Connect Slack first.", level: .error)
            return
        }
        isSlackUploading = true
        defer { isSlackUploading = false }

        do {
            let size = try fileSize(for: fileURL)
            log("Slack upload starting: \(fileURL.path) (\(size) bytes)")
            if size == 0 {
                throw URLError(.zeroByteResource)
            }
            let api = SlackAPI(token: token)
            let channelID: String
            switch slackTargetKind {
            case .channel:
                guard let selected = selectedSlackChannelID else {
                    throw URLError(.badURL)
                }
                channelID = selected
            case .person:
                guard let selected = selectedSlackUserID else {
                    throw URLError(.badURL)
                }
                channelID = try await api.openDM(userID: selected)
            }

            let filename = fileURL.lastPathComponent
            let result = try await api.uploadFile(
                fileURL: fileURL,
                filename: filename,
                channelID: channelID
            )
            lastSlackFileURL = result.permalink
            if let url = result.permalink {
                copyTextToPasteboard(url.absoluteString)
                log("Uploaded to Slack: \(filename). Slack URL copied to clipboard.")
                log("Slack URL: \(url.absoluteString)")
            } else {
                log("Uploaded to Slack. No permalink returned by Slack.")
            }
        } catch {
            log("Slack upload failed: \(error.localizedDescription)", level: .error)
        }
    }

    func copyLastSlackURLToPasteboard() {
        guard let lastSlackFileURL else {
            log("No Slack URL available yet.", level: .error)
            return
        }
        copyTextToPasteboard(lastSlackFileURL.absoluteString)
        log("Copied Slack URL to clipboard.")
    }

    func signOut() {
        userDefaults.removeObject(forKey: tokenStorageKey)
        tokens = nil
    }

    func startRecording() async {
        guard !isRecording else { return }
        guard hasScreenRecordingPermission else {
            log("Enable Screen Recording permission and restart the app.", level: .error)
            return
        }
        refreshMicrophones()
        if recordMicrophoneAudio {
            let granted = await ensureMicrophonePermission()
            guard granted else { return }
        }

        do {
            let filter = try selectedFilter()
            let configuration = try makeConfiguration(filter: filter)
            let outputURL = try makeOutputURL()
            activeRecordingURL = outputURL

            try await recorder.start(
                filter: filter,
                configuration: configuration,
                outputURL: outputURL
            )
            isRecording = true
            lastRecordingURL = outputURL
            let systemAudioEnabled = recordSystemAudio
            let microphoneEnabled = recordMicrophoneAudio
            if !systemAudioEnabled && !microphoneEnabled {
                log("Recording started.")
                return
            }
            var inputs: [String] = []
            if systemAudioEnabled {
                inputs.append("system audio")
            }
            if microphoneEnabled {
                let microphoneName = microphones
                    .first(where: { $0.id == selectedMicrophoneID })?.name
                    ?? "System Default Microphone"
                inputs.append("voiceover: \(microphoneName)")
            }
            log("Recording started with \(inputs.joined(separator: " + ")).")
        } catch {
            activeRecordingURL = nil
            log("Recording failed: \(error.localizedDescription)", level: .error)
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        do {
            try await recorder.stop()
            isRecording = false
            let outputURL = activeRecordingURL ?? lastRecordingURL
            activeRecordingURL = nil
            if let outputURL,
               FileManager.default.fileExists(atPath: outputURL.path) {
                lastRecordingURL = outputURL
                let size = (try? fileSize(for: outputURL)) ?? 0
                log(
                    "Recording stopped. Saved \(outputURL.lastPathComponent) " +
                    "(\(size) bytes)."
                )
                log("Local file URL: \(outputURL.absoluteString)")
            } else {
                updateRecordingAvailability()
                log("Recording stopped, but no output file was found.", level: .error)
            }
        } catch {
            log("Stop failed: \(error.localizedDescription)", level: .error)
        }
    }

    func uploadLastRecording() async {
        guard let fileURL = resolveRecordingURL() else {
            log("Record something first.", level: .error)
            return
        }

        isUploading = true
        defer { isUploading = false }

        do {
            let accessToken = try await validAccessToken()
            let result = try await uploader.upload(fileURL: fileURL, accessToken: accessToken)
            let driveURL = result.webViewLink ?? URL(
                string: "https://drive.google.com/file/d/\(result.id)/view"
            )
            lastDriveFileURL = driveURL
            if let driveURL {
                copyTextToPasteboard(driveURL.absoluteString)
                log("Uploaded to Drive: \(result.name). Drive URL copied to clipboard.")
                log("Drive URL: \(driveURL.absoluteString)")
            } else {
                log("Uploaded to Drive: \(result.name)")
            }
        } catch {
            log("Upload failed: \(error.localizedDescription)", level: .error)
        }
    }

    func copyLastDriveURLToPasteboard() {
        guard let lastDriveFileURL else {
            log("No Google Drive URL available yet.", level: .error)
            return
        }
        copyTextToPasteboard(lastDriveFileURL.absoluteString)
        log("Copied Google Drive URL to clipboard.")
    }

    private func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(date: Date(), message: message, level: level)
        statusMessage = message
        logs.append(entry)
        appendLogToFile(entry)
    }

    func copyLogsToPasteboard() {
        let lines = logs.map { entry in
            let level = entry.level == .error ? "ERROR" : "INFO"
            let timestamp = clipboardTimestampFormatter.string(from: entry.date)
            return "\(timestamp)  [\(level)]  \(entry.message)"
        }
        let text = lines.joined(separator: "\n")
        copyTextToPasteboard(text)
        log("Copied \(logs.count) log entries to clipboard.")
    }

    private func copyTextToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func appendLogToFile(_ entry: LogEntry) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: entry.date)
        let levelLabel = entry.level == .error ? "ERROR" : "INFO"
        let line = "[\(timestamp)] [\(levelLabel)] \(entry.message)\n"
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                try handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } else {
                try line.write(to: logFileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            // Avoid recursive logging loops.
        }
    }

    private func selectedFilter() throws -> SCContentFilter {
        switch captureKind {
        case .window:
            guard let id = selectedWindowID,
                  let selected = windows.first(where: { $0.id == id }) else {
                throw URLError(.badURL)
            }
            return SCContentFilter(desktopIndependentWindow: selected.window)
        case .display, .area:
            guard let id = selectedDisplayID,
                  let selected = displays.first(where: { $0.id == id }) else {
                throw URLError(.badURL)
            }
            return SCContentFilter(display: selected.display, excludingWindows: [])
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let content else {
                    continuation.resume(throwing: URLError(.unknown))
                    return
                }
                continuation.resume(returning: content)
            }
        }
    }

    private func makeConfiguration(filter: SCContentFilter) throws -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        configuration.capturesAudio = recordSystemAudio
        configuration.captureMicrophone = recordMicrophoneAudio
        configuration.microphoneCaptureDeviceID = recordMicrophoneAudio
            ? selectedMicrophoneID
            : nil
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        let scale = Double(filter.pointPixelScale)
        let pixelSize: (Double) -> Int = { points in
            let raw = max(2, Int((points * scale).rounded()))
            return raw % 2 == 0 ? raw : raw - 1
        }

        switch captureKind {
        case .window:
            guard let id = selectedWindowID,
                  windows.contains(where: { $0.id == id }) else {
                throw URLError(.badURL)
            }
            configuration.width = pixelSize(filter.contentRect.width)
            configuration.height = pixelSize(filter.contentRect.height)
        case .display:
            guard let id = selectedDisplayID,
                  displays.contains(where: { $0.id == id }) else {
                throw URLError(.badURL)
            }
            configuration.width = pixelSize(filter.contentRect.width)
            configuration.height = pixelSize(filter.contentRect.height)
        case .area:
            guard let id = selectedDisplayID,
                  let selected = displays.first(where: { $0.id == id }) else {
                throw URLError(.badURL)
            }
            let displayFrame = selected.display.frame
            let requested = CGRect(x: area.x, y: area.y, width: area.width, height: area.height)
            let clamped = requested.intersection(displayFrame)
            guard clamped.width >= 2, clamped.height >= 2 else {
                throw URLError(.dataNotAllowed)
            }
            configuration.width = pixelSize(clamped.width)
            configuration.height = pixelSize(clamped.height)
            if #available(macOS 14.0, *) {
                let localX = clamped.minX - displayFrame.minX
                let localY = displayFrame.maxY - clamped.maxY
                configuration.sourceRect = CGRect(
                    x: localX,
                    y: localY,
                    width: clamped.width,
                    height: clamped.height
                )
            } else {
                configuration.width = pixelSize(filter.contentRect.width)
                configuration.height = pixelSize(filter.contentRect.height)
            }
        }

        return configuration
    }

    private func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "Screencast-\(formatter.string(from: Date())).mp4"

        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent(filename)
    }

    private func validAccessToken() async throws -> String {
        guard let current = tokens else {
            throw URLError(.userAuthenticationRequired)
        }
        guard !clientID.isEmpty else {
            throw OAuthClientError.serverError(
                message: "Missing Google OAuth client ID in Info.plist."
            )
        }
        if clientSecret.isEmpty {
            throw OAuthClientError.serverError(
                message: "Missing Google OAuth client secret in Info.plist."
            )
        }

        if !current.isExpired {
            return current.accessToken
        }

        let redirect = "http://127.0.0.1:0/oauth"
        let config = OAuthConfig(
            clientID: clientID,
            redirectURI: redirect,
            scopes: ["https://www.googleapis.com/auth/drive"],
            clientSecret: clientSecret
        )

        let client = OAuthClient(config: config)
        let refreshed = try await client.refresh(tokens: current)
        tokens = refreshed
        return refreshed.accessToken
    }

    private func persistTokens() {
        guard let tokens else { return }
        let data = try? JSONEncoder().encode(tokens)
        userDefaults.set(data, forKey: tokenStorageKey)
    }

    private func refreshMicrophonePermissionState() {
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophonePermission = true
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            hasMicrophonePermission = granted
            if granted {
                log("Microphone permission granted.")
            } else {
                log("Microphone permission denied.", level: .error)
            }
            return granted
        case .denied, .restricted:
            hasMicrophonePermission = false
            log(
                "Microphone permission is required for voiceover. " +
                "Enable it in System Settings > Privacy & Security > Microphone.",
                level: .error
            )
            return false
        @unknown default:
            hasMicrophonePermission = false
            return false
        }
    }

    private func refreshMicrophones() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discovery.devices
        var seen = Set<String>()
        var list: [MicrophoneDevice] = []
        for device in devices {
            guard seen.insert(device.uniqueID).inserted else { continue }
            list.append(MicrophoneDevice(id: device.uniqueID, name: device.localizedName))
        }
        list.sort { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        microphones = list
        if let selectedMicrophoneID,
           list.contains(where: { $0.id == selectedMicrophoneID }) {
            return
        }
        selectedMicrophoneID = list.first?.id
    }

    private func persistAudioSettings() {
        userDefaults.set(recordSystemAudio, forKey: recordSystemAudioKey)
        userDefaults.set(recordMicrophoneAudio, forKey: recordMicrophoneAudioKey)
        userDefaults.set(selectedMicrophoneID, forKey: selectedMicrophoneIDKey)
    }

    private func resolveRecordingURL() -> URL? {
        if let fileURL = lastRecordingURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            hasRecordingToUpload = true
            return fileURL
        }
        hasRecordingToUpload = false
        return nil
    }

    private func updateRecordingAvailability() {
        guard let fileURL = lastRecordingURL else {
            hasRecordingToUpload = false
            return
        }
        hasRecordingToUpload = FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func fileSize(for url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func selectedDisplayFrame() -> CGRect? {
        guard let id = selectedDisplayID,
              let display = displays.first(where: { $0.id == id }) else {
            return nil
        }
        return display.display.frame
    }

    private func persistSlackTokens() {
        guard let slackTokens else { return }
        let data = try? JSONEncoder().encode(slackTokens)
        userDefaults.set(data, forKey: slackTokenStorageKey)
    }

    private var slackRedirectURI: String {
        "https://screencast-auth.bosullivan.workers.dev/slack/oauth"
    }

    private var slackScopes: [String] {
        [
            "files:write",
            "chat:write",
            "channels:read",
            "groups:read",
            "im:read",
            "im:write",
            "mpim:read",
            "mpim:write",
            "users:read"
        ]
    }
}
