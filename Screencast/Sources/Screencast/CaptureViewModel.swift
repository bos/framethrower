import Foundation
@preconcurrency import ScreenCaptureKit
import SwiftUI

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var captureKind: CaptureSourceKind = .window
    @Published var windows: [ShareableWindow] = []
    @Published var displays: [ShareableDisplay] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var area = CaptureArea()

    @Published var isRecording = false
    @Published var isUploading = false
    @Published var statusMessage = ""
    @Published var lastRecordingURL: URL?

    private var clientID: String {
        Bundle.main.object(forInfoDictionaryKey: "GDriveClientID") as? String ?? ""
    }

    private var clientSecret: String {
        Bundle.main.object(forInfoDictionaryKey: "GDriveClientSecret") as? String ?? ""
    }

    private let recorder = ScreenRecorder()
    private let uploader = DriveUploader()
    private let tokenStorageKey = "drive.tokens"
    private let userDefaults = UserDefaults.standard

    private var tokens: OAuthTokens? {
        didSet { persistTokens() }
    }

    var isAuthorized: Bool {
        tokens != nil
    }

    func refreshSources() async {
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
            selectedWindowID = windows.first?.id
            selectedDisplayID = displays.first?.id
            statusMessage = "Sources refreshed. Showing \(windows.count) windows."
        } catch {
            statusMessage = "Failed to load sources: \(error.localizedDescription)"
        }
    }

    func loadTokens() {
        guard let data = userDefaults.data(forKey: tokenStorageKey) else {
            tokens = nil
            return
        }
        tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    func authorize() async {
        guard !clientID.isEmpty else {
            statusMessage = "Missing Google OAuth client ID in Info.plist."
            return
        }
        guard !clientSecret.isEmpty else {
            statusMessage = "Missing Google OAuth client secret in Info.plist."
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
            statusMessage = "Signed in to Google Drive."
        } catch {
            statusMessage = "Auth failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        userDefaults.removeObject(forKey: tokenStorageKey)
        tokens = nil
    }

    func startRecording() async {
        guard !isRecording else { return }

        do {
            let filter = try selectedFilter()
            let configuration = try makeConfiguration(filter: filter)
            let outputURL = try makeOutputURL()

            try await recorder.start(
                filter: filter,
                configuration: configuration,
                outputURL: outputURL
            )
            isRecording = true
            lastRecordingURL = outputURL
            statusMessage = "Recording started."
        } catch {
            statusMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        do {
            try await recorder.stop()
            isRecording = false
            statusMessage = "Recording stopped."
        } catch {
            statusMessage = "Stop failed: \(error.localizedDescription)"
        }
    }

    func uploadLastRecording() async {
        guard let fileURL = lastRecordingURL else {
            statusMessage = "Record something first."
            return
        }

        isUploading = true
        defer { isUploading = false }

        do {
            let accessToken = try await validAccessToken()
            let result = try await uploader.upload(fileURL: fileURL, accessToken: accessToken)
            statusMessage = "Uploaded to Drive: \(result.name)"
        } catch {
            statusMessage = "Upload failed: \(error.localizedDescription)"
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
        configuration.capturesAudio = false
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
                configuration.sourceRect = clamped
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
}
