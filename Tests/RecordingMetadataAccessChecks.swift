import Foundation

@main
@MainActor
struct RecordingMetadataAccessChecks {
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }

    static func main() throws {
        let source = RecordedSceneSource(kind: .display, displayID: 1,
            globalBounds: CGRect(x: 0, y: 0, width: 1000, height: 600), pixelWidth: 1000, pixelHeight: 600)
        let window = RecordedSceneWindow(id: 4, processID: 40, application: "Example", title: "Document",
            frame: CGRect(x: 10, y: 20, width: 800, height: 500), zOrder: 0, isFocused: nil,
            isRecorderApplication: false, occlusionEstimate: nil)
        let menu = RecordedSceneElement(id: "file-menu", parentID: nil, processID: 40, windowID: nil,
            role: "AXMenuBarItem", subrole: nil, label: "File", frame: CGRect(x: 0, y: 0, width: 50, height: 20),
            isEnabled: true, isFocused: nil, isSelected: nil, isExpanded: false, isMenu: true, textRedacted: false)
        let windowsOnly = RecordedSceneSnapshot(time: 0, sourceBounds: source.globalBounds,
            availability: .init(windows: true, accessibilityTrusted: false, accessibilityCollected: false),
            focusedProcessID: 40, focusedWindowID: 4, windows: [window], elements: [])
        let controls = RecordedSceneSnapshot(time: 5, sourceBounds: source.globalBounds,
            availability: .init(windows: true, accessibilityTrusted: true, accessibilityCollected: true),
            focusedProcessID: 40, focusedWindowID: 4, windows: [window], elements: [menu])
        let empty = RecordedSceneSnapshot(time: 8, sourceBounds: source.globalBounds,
            availability: .init(windows: true, accessibilityTrusted: true, accessibilityCollected: true),
            focusedProcessID: nil, focusedWindowID: nil, windows: [], elements: [])
        let scene = RecordedScene(duration: 10, source: source, snapshots: [windowsOnly, controls, empty])
        try scene.validate()
        let archive = RecordingMetadataArchive.loaded(scene)
        require(archive.evidence(at: 2).kind == .windows && archive.evidence(at: 2).trustedWhenRecorded == false,
                "Windows survive missing Accessibility permission")
        require(archive.evidence(at: 6).kind == .windowsAndControls, "Recorded controls become available at their own capture time")
        require(archive.evidence(at: 9).kind == .empty, "An allowed permission must not invent observed controls")
        require(archive.evidence(at: -1).kind == .noObservation && archive.evidence(at: 11).kind == .noObservation,
                "Out-of-range playhead must not advertise data from another time")
        require(archive.evidence().kind == .windowsAndControls && archive.evidence().trustedWhenRecorded == nil, "Whole-recording summary includes observations and preserves mixed historical trust")
        require(RecordingMetadataArchive.none.evidence().kind == .none, "Imported and old recordings can have no sidecar")
        require(RecordingMetadataArchive.unavailable.evidence().kind == .unavailable, "Unreadable sidecar differs from untrusted permission")
        require(RecordingMetadataArchive.loading.evidence().kind == .loading, "Loading is not missing data")
        require(RecordingMetadataArchive.none.evidence().explanation.contains("will not add"), "No retroactive collection promise")

        var trustedNow = false, requests = 0, settingsOpens = 0, checks = 0
        let access = RecordingAccessibilityAccess(check: { checks += 1; return trustedNow },
            request: { requests += 1 }, openSettings: { settingsOpens += 1; return true })
        require(!access.isTrusted && checks == 1 && requests == 0 && settingsOpens == 0,
                "Reading permission status cannot prompt or launch settings")
        access.refresh()
        require(checks == 2 && requests == 0 && settingsOpens == 0, "App activation refresh is nonprompting")
        require(access.settingsButtonTitle == "Allow Accessibility…" && !access.hasRequestedAccess,
                "Unrequested access offers the native permission action")
        access.showSettings()
        require(requests == 1 && settingsOpens == 0 && !access.isTrusted && access.settingsError == nil,
                "First explicit request shows only the native prompt; asynchronous request is neither a grant nor a failure")
        require(access.hasRequestedAccess && access.settingsButtonTitle == "Open Accessibility Settings…",
                "After requesting, the next action offers the settings pane")
        access.showSettings()
        require(requests == 1 && settingsOpens == 1 && !access.isTrusted,
                "A repeated explicit click opens only Settings without issuing another native prompt")
        trustedNow = true
        access.refresh()
        require(access.isTrusted, "Returning from System Settings refreshes current permission")
        require(archive.evidence(at: 2).kind == .windows && archive.evidence(at: 2).trustedWhenRecorded == false,
                "Granting permission now cannot rewrite recorded evidence")
        require(RecordingMetadataArchive.none.evidence().kind == .none, "Granting permission cannot manufacture imported-video metadata")
        access.showSettings()
        require(requests == 1 && settingsOpens == 2, "Already granted permission opens settings without another TCC prompt")
        let failedOpen = RecordingAccessibilityAccess(check: { true }, request: { preconditionFailure("Trusted access must not prompt") }, openSettings: { false })
        failedOpen.showSettings()
        require(failedOpen.settingsError != nil, "Failed settings launch gives an actionable manual path")
        print("Recording metadata access checks passed: historical evidence, window-only observations, explicit opt-in, permission refresh, and no retroactive metadata; no TCC prompts or live capture.")
    }
}
