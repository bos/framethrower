import AppKit
import Combine
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

    private struct WindowServerAttributes {
        let layer: Int
        let alpha: Double
        let sharingState: Int?
    }

    @Published var captureKind: CaptureSourceKind = .display {
        didSet {
            capturePreferences.remember(kind: captureKind)
            handleCaptureKindChanged()
        }
    }
    @Published var windows: [ShareableWindow] = []
    @Published var displays: [ShareableDisplay] = []
    @Published var selectedWindowID: CGWindowID? {
        didSet {
            guard !isReconcilingCaptureSelection else { return }
            explicitlySelectedWindowID = selectedWindowID
            capturePreferences.remember(windowID: selectedWindowID,
                identity: selectedWindow.map(captureWindowIdentity))
        }
    }
    @Published var selectedDisplayID: CGDirectDisplayID? {
        didSet {
            if !isReconcilingCaptureSelection { capturePreferences.remember(displayID: selectedDisplayID) }
        }
    }
    @Published var area = CaptureArea() {
        didSet { persistAreaSettings() }
    }

    @Published var isRecording = false {
        didSet { updateSourceRefreshScheduling() }
    }
    @Published var isUploading = false
    @Published private(set) var uploadProgressFraction = 0.0
    @Published private(set) var isUploadProgressVisible = false
    @Published var statusMessage = ""
    @Published var logs: [LogEntry] = []
    @Published var isLogExpanded = false
    @Published var countdownRemainingSeconds: Int?
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

    let camera = CameraRecorder()
    private var cameraChanges: AnyCancellable?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let preferences = CaptureSelectionPreferences(defaults: userDefaults)
        capturePreferences = preferences
        captureKind = preferences.kind
        selectedWindowID = preferences.windowID
        selectedDisplayID = preferences.displayID
        cameraChanges = camera.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isCameraReadyForCapture: Bool {
        !camera.isPreparing && (camera.selectedDeviceID == nil || camera.isReady)
    }
    @Published var initialCameraPlacement = PIPPlacement()
    @Published var projectEditor: ProjectEditor?
    @Published var isProjectEditorPresented = false
    @Published private(set) var isCaptureBusy = false
    @Published private(set) var isExporting = false
    private var activeCameraURL: URL?
    private var activeCameraOffset = 0.0
    private var didRestoreProject = false
    private var exportedState: EditState?
    private var exportedProjectURL: URL?
    private var exportedURL: URL?

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
    private let areaXKey = "capture.area.x"
    private let areaYKey = "capture.area.y"
    private let areaWidthKey = "capture.area.width"
    private let areaHeightKey = "capture.area.height"
    private let userDefaults: UserDefaults
    private let capturePreferences: CaptureSelectionPreferences
    private var isReconcilingCaptureSelection = false
    private var explicitlySelectedWindowID: CGWindowID?
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
    private var didAttemptScreenPermissionRequest = false
    private var uploadProgressRevealTask: Task<Void, Never>?

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

    var isAnyUploadActive: Bool {
        isUploading || isSlackUploading || isExporting
    }

    var latestLogEntry: LogEntry? {
        logs.last
    }

    var latestStatusLine: String {
        if let latestLogEntry {
            return latestLogEntry.message
        }
        return "Ready."
    }

    var driveAccountStatusText: String {
        isAuthorized ? "Signed in" : "Needs setup"
    }

    var slackAccountStatusText: String {
        isSlackAuthorized ? "Connected" : "Needs setup"
    }

    var slackAccountDetailText: String {
        guard let tokens = slackTokens else {
            return "No Slack workspace connected."
        }
        let teamText = tokens.teamID.isEmpty ? "Unknown team" : "Team ID: \(tokens.teamID)"
        let userText = tokens.userID.isEmpty ? "Unknown user" : "User ID: \(tokens.userID)"
        return "\(teamText), \(userText)"
    }

    var selectedWindow: ShareableWindow? {
        guard let id = selectedWindowID else { return nil }
        return windows.first(where: { $0.id == id })
    }

    var isCountdownActive: Bool {
        countdownRemainingSeconds != nil
    }

    func refreshScreenRecordingPermissionState() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool {
        refreshScreenRecordingPermissionState()
        if hasScreenRecordingPermission {
            return true
        }
        guard !didAttemptScreenPermissionRequest else {
            return false
        }
        didAttemptScreenPermissionRequest = true
        let granted = CGRequestScreenCaptureAccess()
        hasScreenRecordingPermission = granted
        if granted {
            log("Screen recording permission granted. Restart the app if needed.")
        } else {
            log("Screen recording permission denied.", level: .error)
        }
        return granted
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

        refreshScreenRecordingPermissionState()
        guard hasScreenRecordingPermission else {
            windows = []
            displays = []
            // Permission loss is not a new source choice. Keep the remembered
            // preference so granting access later restores the user's selection.
            isReconcilingCaptureSelection = true
            selectedWindowID = nil
            selectedDisplayID = nil
            isReconcilingCaptureSelection = false
            if logErrors {
                log("Screen recording permission is required.", level: .error)
            }
            return
        }

        do {
            let content = try await shareableContent()
            let allWindows = content.windows.map(ShareableWindow.init)
            let windowServerAttributes = windowServerAttributesByID()
            let appBundleID = Bundle.main.bundleIdentifier
            windows = allWindows
                .filter { $0.isSelectable }
                .filter { window in
                    isHumanVisibleCandidate(
                        window,
                        attributes: windowServerAttributes[window.id]
                    )
                }
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
            displays = content.displays.enumerated().map { offset, display in
                ShareableDisplay(display: display, index: offset + 1)
            }
            // Read preferences after discovery completes: a user may choose
            // another source while shareableContent() is suspended.
            let choice = capturePreferences.reconciled(
                windows: windows.map(captureWindowIdentity), displays: displays.map(\.id),
                currentDisplayID: selectedDisplayID, explicitlySelectedWindowID: explicitlySelectedWindowID
            )
            isReconcilingCaptureSelection = true
            selectedWindowID = choice.window?.id
            selectedDisplayID = choice.displayID
            isReconcilingCaptureSelection = false
            explicitlySelectedWindowID = nil
            if let window = choice.window {
                capturePreferences.remember(windowID: window.id, identity: window)
            }
            if capturePreferences.displayID == nil {
                capturePreferences.remember(displayID: choice.displayID)
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

    private func windowServerAttributesByID() -> [CGWindowID: WindowServerAttributes] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            return [:]
        }

        var attributesByID: [CGWindowID: WindowServerAttributes] = [:]
        for windowInfo in info {
            guard let windowNumber = windowInfo[kCGWindowNumber as String] as? NSNumber else {
                continue
            }
            let windowID = CGWindowID(windowNumber.uint32Value)
            let layer = (windowInfo[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (windowInfo[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let sharingState = (
                windowInfo[kCGWindowSharingState as String] as? NSNumber
            )?.intValue
            attributesByID[windowID] = WindowServerAttributes(
                layer: layer,
                alpha: alpha,
                sharingState: sharingState
            )
        }
        return attributesByID
    }

    private func isHumanVisibleCandidate(
        _ window: ShareableWindow,
        attributes: WindowServerAttributes?
    ) -> Bool {
        if let attributes {
            if attributes.layer != 0 {
                return false
            }
            if attributes.alpha <= 0.03 {
                return false
            }
            if attributes.sharingState == 0 {
                return false
            }
        } else if window.windowLayer != 0 {
            return false
        }

        if window.bundleIdentifier == "com.apple.dock" {
            return false
        }

        let rawTitle = window.normalizedRawTitle
        let title = window.title.lowercased()
        let ownerName = window.owningApplication.lowercased()
        let bundleID = window.bundleIdentifier?.lowercased() ?? ""
        let searchableTitle = "\(rawTitle) \(title)"
        let isBetterDisplayRelated =
            ownerName.contains("betterdisplay") ||
            bundleID.contains("betterdisplay") ||
            searchableTitle.contains("betterdisplay")

        if rawTitle == "tracking" || rawTitle.hasPrefix("- tracking") {
            return false
        }
        if searchableTitle.contains("tracking") && isBetterDisplayRelated {
            return false
        }
        if searchableTitle.contains("betterdisplay overlay") {
            return false
        }
        if searchableTitle.contains("overlay for display") && isBetterDisplayRelated {
            return false
        }
        if searchableTitle.contains("overlay") && isBetterDisplayRelated {
            return false
        }
        return true
    }

    private func handleCaptureKindChanged() {
        updateSourceRefreshScheduling()
        // Initialization/preferences changes do not initiate capture discovery.
        // ContentView starts refresh explicitly when it becomes visible.
        if isSourceRefreshConfigured { sourceRefreshTriggered(force: true) }
    }

    private func captureWindowIdentity(_ window: ShareableWindow) -> CaptureSelectionPreferences.WindowIdentity {
        let processID = window.window.owningApplication?.processID ?? 0
        return CaptureSelectionPreferences.WindowIdentity(
            id: window.id, processID: processID, bundleIdentifier: window.bundleIdentifier,
            launchDate: NSRunningApplication(processIdentifier: processID)?.launchDate
        )
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
        guard ensureScreenRecordingPermissionForCaptureAction() else { return }
        let frame = selectableScreensUnionFrame() ?? NSScreen.main?.frame ?? .zero
        guard frame.width >= 2, frame.height >= 2 else {
            log("No display available for area selection.", level: .error)
            return
        }
        let hiddenWindows = hideMainWindowsForSelection()
        defer { restoreMainWindowsAfterSelection(hiddenWindows) }
        do {
            let initialSelection: CGRect? = {
                let rect = area.rect
                guard rect.width >= 2, rect.height >= 2 else { return nil }
                return rect
            }()
            let selected = try await AreaSelectionCoordinator.selectArea(
                in: frame,
                initialSelection: initialSelection
            )
            area = CaptureArea(
                x: selected.origin.x,
                y: selected.origin.y,
                width: selected.width,
                height: selected.height
            )
            if let displayID = displayIDContainingLargestIntersection(with: selected) {
                selectedDisplayID = displayID
            }
            log("Area selected.")
        } catch AreaSelectionError.cancelled {
            log("Area selection cancelled.")
        } catch {
            log("Area selection failed: \(error.localizedDescription)", level: .error)
        }
    }

    func selectWindow() async {
        guard captureKind == .window else { return }
        guard ensureScreenRecordingPermissionForCaptureAction() else { return }
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

    func loadAreaSettings() {
        guard userDefaults.object(forKey: areaWidthKey) != nil,
              userDefaults.object(forKey: areaHeightKey) != nil else {
            return
        }
        let saved = CaptureArea(
            x: userDefaults.double(forKey: areaXKey),
            y: userDefaults.double(forKey: areaYKey),
            width: userDefaults.double(forKey: areaWidthKey),
            height: userDefaults.double(forKey: areaHeightKey)
        )
        guard saved.width >= 2, saved.height >= 2 else {
            return
        }
        area = saved
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
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) ==
                    .orderedAscending
            }
            slackChannels = channelList

            let currentUserID = slackTokens?.userID
            if let currentUserID,
               let index = userList.firstIndex(where: { $0.id == currentUserID }) {
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
        guard !isAnyUploadActive, !isRecording, !isCaptureBusy else { return }
        guard let token = slackTokens?.accessToken else {
            log("Connect Slack first.", level: .error)
            return
        }
        isSlackUploading = true
        beginUploadProgress()
        defer {
            isSlackUploading = false
            endUploadProgress()
        }

        do {
            let fileURL = try await recordingForSharing()
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
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateUploadProgress(progress)
                }
            }
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
        guard !isRecording, !isCaptureBusy, !isAnyUploadActive, isCameraReadyForCapture else { return }
        guard countdownRemainingSeconds == nil else { return }
        guard ensureScreenRecordingPermissionForCaptureAction() else { return }
        isCaptureBusy = true
        defer { isCaptureBusy = false }
        refreshMicrophones()
        if recordMicrophoneAudio {
            guard await ensureMicrophonePermission() else { return }
        }

        do {
            let filter = try await selectedFilter()
            let configuration = try makeConfiguration(filter: filter)
            let outputURL = try makeOutputURL()
            activeRecordingURL = outputURL
            activeCameraURL = nil
            activeCameraOffset = 0
            var cameraStart: Double?
            if camera.selectedDeviceID != nil {
                let url = outputURL.deletingPathExtension().appendingPathExtension("camera.mov")
                activeCameraURL = url
                cameraStart = try await camera.startRecording(to: url)
            }
            let screenStart = try await recorder.start(filter: filter, configuration: configuration, outputURL: outputURL)
            if let cameraStart { activeCameraOffset = cameraStart - screenStart }
            lastDriveFileURL = nil
            lastSlackFileURL = nil
            projectEditor = nil
            exportedState = nil
            exportedURL = nil
            isRecording = true
            lastRecordingURL = outputURL
            log(cameraStart == nil ? "Recording started." : "Recording screen and camera independently.")
        } catch {
            try? await camera.stopRecording()
            if let activeRecordingURL { log("Captured sources kept beside \(activeRecordingURL.path)") }
            activeRecordingURL = nil
            activeCameraURL = nil
            log("Recording failed: \(error.localizedDescription)", level: .error)
        }
    }

    func stopRecording() async {
        guard isRecording, !isCaptureBusy else { return }
        isCaptureBusy = true
        defer { isCaptureBusy = false }
        var failures: [String] = []
        do { try await recorder.stop() } catch { failures.append(error.localizedDescription) }
        do { try await camera.stopRecording() } catch { failures.append(error.localizedDescription) }
        isRecording = false
        let outputURL = activeRecordingURL
        activeRecordingURL = nil
        defer { activeCameraURL = nil }
        guard let outputURL, FileManager.default.fileExists(atPath: outputURL.path) else {
            log("No screen file was found. " + failures.joined(separator: " "), level: .error)
            updateRecordingAvailability()
            return
        }
        lastRecordingURL = outputURL
        do {
            let duration = try await AVURLAsset(url: outputURL).load(.duration).seconds
            var cameraFilename: String?
            if let cameraURL = activeCameraURL {
                do {
                    let asset = AVURLAsset(url: cameraURL)
                    guard try await !asset.loadTracks(withMediaType: .video).isEmpty,
                          try await asset.load(.duration).seconds > 0 else {
                        throw CameraRecordingError.noFrames
                    }
                    cameraFilename = cameraURL.lastPathComponent
                } catch {
                    failures.append("Camera video was unavailable; the screen recording and any camera file were kept. " + error.localizedDescription)
                }
            }
            var project = RecordingProject(screenFilename: outputURL.lastPathComponent,
                cameraFilename: cameraFilename,
                cameraOffset: activeCameraOffset, duration: duration)
            project.state.pipKeyframes[0].placement = initialCameraPlacement
            let url = outputURL.deletingPathExtension().appendingPathExtension("framethrower")
            let editor = ProjectEditor(project: project, url: url)
            guard editor.save() else { throw ProjectError.invalid(editor.errorMessage ?? "Could not save the project.") }
            projectEditor = editor
            userDefaults.set(url.path, forKey: "editor.lastProject")
            isProjectEditorPresented = true
            log("Recording saved. Review, trim, and arrange your camera before sharing.")
        } catch {
            log("Sources are safe at \(outputURL.path), but project creation failed: \(error.localizedDescription)", level: .error)
        }
        if !failures.isEmpty { log("Capture reported: " + failures.joined(separator: " "), level: .error) }
    }

    func restoreLastProject() {
        guard !didRestoreProject else { return }
        didRestoreProject = true
        guard let path = userDefaults.string(forKey: "editor.lastProject"),
              FileManager.default.fileExists(atPath: path) else { return }
        openProject(at: URL(fileURLWithPath: path), present: false)
    }

    func chooseProject() {
        guard !isRecording, !isCaptureBusy, !isAnyUploadActive else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a FrameThrower project (.framethrower) to continue editing."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url, present: true)
    }

    private func openProject(at url: URL, present: Bool) {
        do {
            let editor = try ProjectEditor.open(url: url)
            let screenURL = editor.mediaURL(for: editor.project.screenFilename)
            guard FileManager.default.fileExists(atPath: screenURL.path) else {
                throw ProjectError.invalid("Keep the project and its original media files together.")
            }
            projectEditor = editor
            lastRecordingURL = screenURL
            lastDriveFileURL = nil
            lastSlackFileURL = nil
            userDefaults.set(url.path, forKey: "editor.lastProject")
            isProjectEditorPresented = present
        } catch { log("Could not open project: \(error.localizedDescription)", level: .error) }
    }

    /// Both destinations use this exact snapshot, never the unedited screen file.
    private func recordingForSharing() async throws -> URL {
        guard let editor = projectEditor else {
            guard let source = resolveRecordingURL() else { throw ProjectError.invalid("Record something first.") }
            return source
        }
        guard editor.save() else { throw ProjectError.invalid(editor.errorMessage ?? "Could not save the edit.") }
        let snapshot = editor.project
        if exportedState == snapshot.state, exportedProjectURL == editor.url,
           let exportedURL, FileManager.default.fileExists(atPath: exportedURL.path) { return exportedURL }
        isExporting = true
        defer { isExporting = false }
        let url = editor.mediaURL(for: snapshot.screenFilename).deletingPathExtension()
            .appendingPathExtension("edited-" + UUID().uuidString + ".mp4")
        try await ProjectRenderer.export(project: snapshot, directory: editor.url.deletingLastPathComponent(), to: url)
        exportedState = snapshot.state
        exportedProjectURL = editor.url
        exportedURL = url
        return url
    }

    func startRecordingAfterDelay(seconds: Int) async {
        guard !isRecording, !isCaptureBusy, !isAnyUploadActive else { return }
        guard countdownRemainingSeconds == nil else { return }
        guard ensureScreenRecordingPermissionForCaptureAction() else { return }
        let countdownSeconds = max(1, seconds)
        countdownRemainingSeconds = countdownSeconds
        log("Countdown started: \(countdownSeconds)s.")
        do {
            try await RecordingCountdownCoordinator.run(seconds: countdownSeconds) { [weak self]
                remaining in
                self?.countdownRemainingSeconds = remaining
            }
            countdownRemainingSeconds = nil
            log("Countdown finished. Recording started.")
            await startRecordingAfterCountdownHandoff()
        } catch RecordingCountdownError.cancelled {
            countdownRemainingSeconds = nil
            log("Countdown cancelled.")
        } catch {
            countdownRemainingSeconds = nil
            log("Countdown failed: \(error.localizedDescription)", level: .error)
        }
    }

    func cancelRecordingCountdown() {
        guard countdownRemainingSeconds != nil else { return }
        RecordingCountdownCoordinator.cancelCurrent()
    }

    private func startRecordingAfterCountdownHandoff() async {
        // Start from a fresh main-queue turn after overlay teardown to avoid lifetime issues.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    await self.startRecording()
                    continuation.resume()
                }
            }
        }
    }

    private func ensureScreenRecordingPermissionForCaptureAction() -> Bool {
        refreshScreenRecordingPermissionState()
        if hasScreenRecordingPermission {
            return true
        }
        let granted = requestScreenRecordingPermission()
        guard granted else {
            log("Enable Screen Recording permission in System Settings, then restart the app.",
                level: .error)
            return false
        }
        return true
    }

    func uploadLastRecording() async {
        guard !isAnyUploadActive, !isRecording, !isCaptureBusy else { return }
        isUploading = true
        beginUploadProgress()
        defer {
            isUploading = false
            endUploadProgress()
        }

        do {
            let fileURL = try await recordingForSharing()
            let accessToken = try await validAccessToken()
            let result = try await uploader.upload(
                fileURL: fileURL,
                accessToken: accessToken
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateUploadProgress(progress)
                }
            }
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

    private func beginUploadProgress() {
        uploadProgressFraction = 0
        isUploadProgressVisible = false
        uploadProgressRevealTask?.cancel()
        uploadProgressRevealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled, self.isAnyUploadActive else { return }
            self.isUploadProgressVisible = true
        }
    }

    private func updateUploadProgress(_ progress: Double) {
        uploadProgressFraction = min(max(progress, 0), 1)
    }

    private func endUploadProgress() {
        uploadProgressRevealTask?.cancel()
        uploadProgressRevealTask = nil
        isUploadProgressVisible = false
        uploadProgressFraction = 0
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

    private func selectedFilter() async throws -> SCContentFilter {
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
            let content = try await shareableContent()
            let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            return SCContentFilter(display: selected.display, excludingApplications: ownApplications, exceptingWindows: [])
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
        let filename = "Screencast-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).mp4"

        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    private func persistAreaSettings() {
        userDefaults.set(area.x, forKey: areaXKey)
        userDefaults.set(area.y, forKey: areaYKey)
        userDefaults.set(area.width, forKey: areaWidthKey)
        userDefaults.set(area.height, forKey: areaHeightKey)
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

    private func selectableScreensUnionFrame() -> CGRect? {
        var union: CGRect?
        for screen in NSScreen.screens {
            if let existing = union {
                union = existing.union(screen.frame)
            } else {
                union = screen.frame
            }
        }
        return union
    }

    private func displayIDContainingLargestIntersection(with rect: CGRect) -> CGDirectDisplayID? {
        let validArea = rect.standardized
        guard validArea.width > 0, validArea.height > 0 else { return nil }

        var bestDisplay: CGDirectDisplayID?
        var bestIntersectionArea = CGFloat(0)
        for display in displays {
            let intersection = display.display.frame.intersection(validArea)
            let area = intersection.width * intersection.height
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestDisplay = display.id
            }
        }
        return bestDisplay
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


/// The remembered explicit choice is separate from temporary discovery fallback.
/// This value-only reconciliation is also testable without screen access.
@MainActor
struct CaptureSelectionPreferences {
    struct WindowIdentity: Codable, Equatable {
        var id: CGWindowID
        var processID: pid_t
        var bundleIdentifier: String?
        var launchDate: Date?

        func matches(_ candidate: WindowIdentity) -> Bool {
            guard id == candidate.id, processID == candidate.processID,
                  bundleIdentifier == candidate.bundleIdentifier else { return false }
            if let launchDate {
                guard let candidateLaunchDate = candidate.launchDate,
                      abs(launchDate.timeIntervalSince(candidateLaunchDate)) < 0.001 else { return false }
            }
            return true
        }
    }

    private let defaults: UserDefaults
    private static let kindKey = "capture.kind"
    private static let windowKey = "capture.window.id"
    private static let windowIdentityKey = "capture.window.identity"
    private static let displayKey = "capture.display.id"

    init(defaults: UserDefaults) { self.defaults = defaults }

    var kind: CaptureSourceKind {
        defaults.string(forKey: Self.kindKey).flatMap(CaptureSourceKind.init(rawValue:)) ?? .display
    }
    var windowID: CGWindowID? { identifier(forKey: Self.windowKey) }
    var displayID: CGDirectDisplayID? { identifier(forKey: Self.displayKey) }
    private var windowIdentity: WindowIdentity? {
        defaults.data(forKey: Self.windowIdentityKey).flatMap { try? JSONDecoder().decode(WindowIdentity.self, from: $0) }
    }

    func remember(kind: CaptureSourceKind) { defaults.set(kind.rawValue, forKey: Self.kindKey) }

    func remember(windowID: CGWindowID?, identity: WindowIdentity?) {
        let previousID = self.windowID
        defaults.set(windowID.map { NSNumber(value: $0) }, forKey: Self.windowKey)
        if let identity, identity.id == windowID, let data = try? JSONEncoder().encode(identity) {
            defaults.set(data, forKey: Self.windowIdentityKey)
        } else if windowID == nil || windowID != previousID {
            defaults.removeObject(forKey: Self.windowIdentityKey)
        }
    }

    func remember(displayID: CGDirectDisplayID?) {
        defaults.set(displayID.map { NSNumber(value: $0) }, forKey: Self.displayKey)
    }

    func reconciled(windows: [WindowIdentity], displays: [CGDirectDisplayID],
                    currentDisplayID: CGDirectDisplayID?, explicitlySelectedWindowID: CGWindowID?)
        -> (window: WindowIdentity?, displayID: CGDirectDisplayID?) {
        let window = windows.first { candidate in
            guard candidate.id == windowID else { return false }
            return explicitlySelectedWindowID == candidate.id
                || (candidate.processID > 0 && windowIdentity?.matches(candidate) == true)
        }
        let display: CGDirectDisplayID?
        if let displayID, displays.contains(displayID) { display = displayID }
        else if let currentDisplayID, displays.contains(currentDisplayID) { display = currentDisplayID }
        else { display = displays.first }
        return (window, display)
    }

    private func identifier(forKey key: String) -> UInt32? {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= Double(UInt32.max), value.rounded() == value else { return nil }
        return UInt32(value)
    }
}
