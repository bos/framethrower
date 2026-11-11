import AppKit
@preconcurrency import ApplicationServices
import Combine
import Foundation
import SwiftUI

/// Permission today and evidence captured earlier are independent. In particular,
/// granting Accessibility cannot reconstruct menus or controls in an old movie.
enum RecordingMetadataArchive: Equatable, Sendable {
    case none
    case loading
    case unavailable
    case loaded(RecordedScene)

    enum Kind: Equatable, Sendable { case none, loading, unavailable, noObservation, windows, controls, windowsAndControls, empty }
    struct Evidence: Equatable, Sendable {
        var kind: Kind
        var trustedWhenRecorded: Bool? = nil
        var label: String {
            switch kind {
            case .none: "No recorded context"
            case .loading: "Checking recorded context…"
            case .unavailable: "Recorded context unavailable"
            case .noObservation: "No context at playhead"
            case .windows: "Recorded context: Windows only"
            case .controls: "Recorded context: Controls"
            case .windowsAndControls: "Recorded context: Windows & controls"
            case .empty: "Recorded context: No observations"
            }
        }
        var explanation: String {
            switch kind {
            case .none: "This video has no saved window or control data. Granting access now will not add information about its past contents."
            case .loading: "Reading the recording’s saved context."
            case .unavailable: "The recorded context file is missing or unreadable. Changing Accessibility access cannot restore that file."
            case .noObservation: "No window or control observation was saved at this playhead position."
            case .windows:
                if trustedWhenRecorded == false {
                    "Window information was recorded without Accessibility access. Menus, controls and tabs were not available to record."
                } else if trustedWhenRecorded == true {
                    "Window information was recorded, but no menus, controls or tabs were saved even though Accessibility access was allowed."
                } else {
                    "Window information was recorded, but no menus, controls or tabs were saved. Accessibility access varied during this recording."
                }
            case .controls: "Control information was recorded. Window information is unavailable in this observation."
            case .windowsAndControls: "Saved window and control information is available to Director."
            case .empty:
                trustedWhenRecorded == false
                    ? "This observation contains no windows or controls. Accessibility access was off when it was recorded."
                    : "This observation contains no windows or controls. Accessibility access alone does not guarantee that another app exposes them."
            }
        }
    }

    func evidence(at time: Double? = nil) -> Evidence {
        switch self {
        case .none: return Evidence(kind: .none)
        case .loading: return Evidence(kind: .loading)
        case .unavailable: return Evidence(kind: .unavailable)
        case .loaded(let scene):
            let observations: [RecordedSceneSnapshot]
            if let time {
                guard let snapshot = scene.snapshot(at: time) else { return Evidence(kind: .noObservation) }
                observations = [snapshot]
            } else { observations = scene.snapshots }
            let windows = observations.contains { $0.availability.windows && !$0.windows.isEmpty }
            let controls = observations.contains { $0.availability.accessibilityCollected && !$0.elements.isEmpty }
            let trustValues = Set(observations.map { $0.availability.accessibilityTrusted })
            let trusted = trustValues.count == 1 ? trustValues.first : nil
            let kind: Kind = windows ? (controls ? .windowsAndControls : .windows) : (controls ? .controls : .empty)
            return Evidence(kind: kind, trustedWhenRecorded: trusted)
        }
    }
}

/// Native effects are injected so tests can verify opt-in behavior without
/// touching TCC, opening System Settings, or observing the live desktop.
@MainActor
final class RecordingAccessibilityAccess: ObservableObject {
    @Published private(set) var isTrusted: Bool
    private let check: @MainActor () -> Bool
    private let request: @MainActor () -> Void
    private let openSettings: @MainActor () -> Bool
    @Published private(set) var settingsError: String?
    @Published private(set) var hasRequestedAccess = false
    var settingsButtonTitle: String { isTrusted || hasRequestedAccess ? "Open Accessibility Settings…" : "Allow Accessibility…" }

    init(check: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
         request: @escaping @MainActor () -> Void = {
             let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
             _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
         },
         openSettings: @escaping @MainActor () -> Bool = {
             guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return false }
             return NSWorkspace.shared.open(url)
         }) {
        self.check = check; self.request = request; self.openSettings = openSettings
        isTrusted = check()
    }

    func refresh() { isTrusted = check() }

    /// Called only by the explicit permission button, never by appear/refresh.
    func showSettings() {
        refresh()
        if !isTrusted && !hasRequestedAccess {
            // The native prompt already offers its own Settings action. Do not
            // open a second surface or interpret its asynchronous result as a
            // failed grant. A later explicit click can open the pane directly.
            hasRequestedAccess = true
            settingsError = nil
            request()
            refresh()
            return
        }
        settingsError = openSettings() ? nil : "Open System Settings → Privacy & Security → Accessibility, then enable FrameThrower."
        refresh()
    }
}

struct RecordingMetadataAccessView: View {
    enum Mode: Equatable {
        case capture
        case recording(sceneURL: URL?, time: Double?)
        var sceneURL: URL? { if case .recording(let url, _) = self { url } else { nil } }
        var time: Double? { if case .recording(_, let time) = self { time } else { nil } }
        var isRecording: Bool { if case .recording = self { true } else { false } }
    }
    let mode: Mode
    @StateObject private var access = RecordingAccessibilityAccess()
    @State private var archive = RecordingMetadataArchive.none
    @State private var showingDetails = false

    private var evidence: RecordingMetadataArchive.Evidence { archive.evidence(at: mode.time) }
    private var label: String { mode.isRecording ? evidence.label : "Accessibility: " + (access.isTrusted ? "Allowed" : "Off") }

    var body: some View {
        Button { access.refresh(); showingDetails.toggle() } label: {
            Label(label, systemImage: "info.circle")
        }
        .buttonStyle(.borderless).controlSize(.small)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("recording-metadata-access")
        .help(mode.isRecording ? "Review this recording’s saved window/control data and Accessibility access for future recordings." : "Accessibility access lets future recordings save menus, controls and tabs for Director.")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                if mode.isRecording {
                    Text(evidence.label).font(.headline)
                    Text(evidence.explanation).fixedSize(horizontal: false, vertical: true)
                    Text(mode.time != nil ? "At the current playhead." : "Across this recording.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                }
                HStack {
                    Text("Accessibility access").font(.headline)
                    Spacer()
                    Text(access.isTrusted ? "Allowed" : "Off").foregroundStyle(.secondary)
                }
                Text("Window information can be recorded without this access. Accessibility adds menus, controls and tabs when other apps expose them.")
                    .fixedSize(horizontal: false, vertical: true)
                if mode.isRecording {
                    Text("Changes apply to future recordings; saved metadata is unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(access.settingsButtonTitle) { access.showSettings() }
                    .help(access.hasRequestedAccess || access.isTrusted
                        ? "Open System Settings → Privacy & Security → Accessibility. Enable FrameThrower there."
                        : "Ask macOS for Accessibility access. Its dialog lets you open System Settings to enable FrameThrower.")
                if let error = access.settingsError { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            .font(.callout).padding(16).frame(width: 330)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in access.refresh() }
        .task(id: mode.sceneURL) {
            guard let url = mode.sceneURL else { archive = .none; return }
            archive = .loading
            do {
                let scene = try await Task.detached(priority: .utility) { try RecordedScene.load(from: url) }.value
                guard !Task.isCancelled else { return }
                archive = .loaded(scene)
            } catch {
                guard !Task.isCancelled else { return }
                archive = .unavailable
            }
        }
    }
}
