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

    @AppStorage("drive.clientID") var clientID: String = ""
    @AppStorage("drive.redirectURI") var redirectURI: String = ""

    private let recorder = ScreenRecorder()
    private let uploader = DriveUploader()
    private let keychain = KeychainStore(service: "Screencast.Drive")

    private var tokens: OAuthTokens? {
        didSet { persistTokens() }
    }

    var isAuthorized: Bool {
        tokens != nil
    }

    func refreshSources() async {
        do {
            let content = try await SCShareableContent.current
            windows = content.windows.map(ShareableWindow.init)
            displays = content.displays.map(ShareableDisplay.init)
            selectedWindowID = windows.first?.id
            selectedDisplayID = displays.first?.id
            statusMessage = "Sources refreshed."
        } catch {
            statusMessage = "Failed to load sources: \(error.localizedDescription)"
        }
    }

    func loadTokens() {
        do {
            let data = try keychain.read(account: "tokens")
            tokens = try JSONDecoder().decode(OAuthTokens.self, from: data)
        } catch {
            tokens = nil
        }
    }

    func authorize() async {
        guard !clientID.isEmpty else {
            statusMessage = "Enter a Google OAuth client ID."
            return
        }

        let redirect = redirectURI.isEmpty ? "com.example.screencast:/oauth" : redirectURI
        let config = OAuthConfig(
            clientID: clientID,
            redirectURI: redirect,
            scopes: ["https://www.googleapis.com/auth/drive.file"]
        )

        do {
            let client = OAuthClient(config: config)
            tokens = try await client.authorize()
            statusMessage = "Signed in to Google Drive."
        } catch {
            statusMessage = "Auth failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        do {
            try keychain.delete(account: "tokens")
        } catch {
            statusMessage = "Failed to remove token: \(error.localizedDescription)"
        }
        tokens = nil
    }

    func startRecording() async {
        guard !isRecording else { return }

        do {
            let filter = try selectedFilter()
            let configuration = try makeConfiguration()
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

    private func makeConfiguration() throws -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        switch captureKind {
        case .window:
            guard let id = selectedWindowID,
                  let selected = windows.first(where: { $0.id == id }) else {
                throw URLError(.badURL)
            }
            configuration.width = Int(selected.window.frame.width)
            configuration.height = Int(selected.window.frame.height)
        case .display:
            guard let id = selectedDisplayID,
                  let selected = displays.first(where: { $0.id == id }) else {
                throw URLError(.badURL)
            }
            configuration.width = Int(selected.display.frame.width)
            configuration.height = Int(selected.display.frame.height)
        case .area:
            guard let id = selectedDisplayID,
                  let selected = displays.first(where: { $0.id == id }) else {
                throw URLError(.badURL)
            }
            configuration.width = Int(area.width)
            configuration.height = Int(area.height)
            if #available(macOS 14.0, *) {
                configuration.sourceRect = area.rect
            } else {
                configuration.width = Int(selected.display.frame.width)
                configuration.height = Int(selected.display.frame.height)
            }
        }

        return configuration
    }

    private func makeOutputURL() throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
        let filename = "Screencast-\(formatter.string(from: Date())).mp4"

        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent(filename)
    }

    private func validAccessToken() async throws -> String {
        guard let current = tokens else {
            throw URLError(.userAuthenticationRequired)
        }

        if !current.isExpired {
            return current.accessToken
        }

        let redirect = redirectURI.isEmpty ? "com.example.screencast:/oauth" : redirectURI
        let config = OAuthConfig(
            clientID: clientID,
            redirectURI: redirect,
            scopes: ["https://www.googleapis.com/auth/drive.file"]
        )

        let client = OAuthClient(config: config)
        let refreshed = try await client.refresh(tokens: current)
        tokens = refreshed
        return refreshed.accessToken
    }

    private func persistTokens() {
        guard let tokens else { return }
        do {
            let data = try JSONEncoder().encode(tokens)
            try keychain.write(account: "tokens", data: data)
        } catch {
            statusMessage = "Token save failed: \(error.localizedDescription)"
        }
    }
}
