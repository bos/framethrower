import Foundation

private enum PreferenceCheckError: Error { case failed(String) }

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PreferenceCheckError.failed(message) }
}

@main
struct CapturePreferenceChecks {
    @MainActor
    static func main() async throws {
        let suite = "FrameThrower.CapturePreferenceChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw PreferenceCheckError.failed("isolated preferences unavailable")
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = CaptureViewModel(userDefaults: defaults)
        try require(fresh.captureKind == .display, "first launch must default to Display")
        try require(fresh.selectedWindowID == nil && fresh.selectedDisplayID == nil, "fresh launch invented a source")
        fresh.captureKind = .window
        fresh.selectedWindowID = 31
        fresh.selectedDisplayID = 42
        let reopened = CaptureViewModel(userDefaults: defaults)
        try require(reopened.captureKind == .window, "last capture mode was not restored")
        try require(reopened.selectedWindowID == 31 && reopened.selectedDisplayID == 42,
                    "last source IDs were not restored before discovery")
        reopened.captureKind = .area
        reopened.area = CaptureArea(x: 100, y: 200, width: 640, height: 360)
        let areaReopened = CaptureViewModel(userDefaults: defaults)
        areaReopened.loadAreaSettings()
        try require(areaReopened.captureKind == .area && areaReopened.area == reopened.area,
                    "Area mode or its existing geometry did not round-trip")
        for _ in 0..<5 { await Task.yield() }
        try require(fresh.windows.isEmpty && reopened.windows.isEmpty && areaReopened.windows.isEmpty,
                    "preference initialization/change started source discovery")
        try require(fresh.logs.isEmpty && reopened.logs.isEmpty && areaReopened.logs.isEmpty,
                    "preference changes caused recording or network work")
        try require(fresh.camera.selectedDeviceID == nil && !fresh.camera.isPreparing && !fresh.camera.isRecording,
                    "restoring capture preferences activated the camera")

        let preferences = CaptureSelectionPreferences(defaults: defaults)
        let original = CaptureSelectionPreferences.WindowIdentity(
            id: 31, processID: 700, bundleIdentifier: "com.example.Editor", launchDate: Date(timeIntervalSince1970: 1234)
        )
        preferences.remember(windowID: original.id, identity: original)
        preferences.remember(displayID: 55)
        let valid = preferences.reconciled(windows: [original], displays: [12, 55],
                                          currentDisplayID: 12, explicitlySelectedWindowID: nil)
        try require(valid.window == original && valid.displayID == 55, "available remembered sources were not selected")
        let missing = preferences.reconciled(windows: [], displays: [],
                                            currentDisplayID: nil, explicitlySelectedWindowID: nil)
        try require(missing.window == nil && missing.displayID == nil, "missing sources produced an invalid selection")
        try require(preferences.windowID == 31 && preferences.displayID == 55,
                    "temporary discovery/permission loss erased preferences")
        let fallback = preferences.reconciled(windows: [], displays: [12, 13],
                                             currentDisplayID: 13, explicitlySelectedWindowID: nil)
        try require(fallback.window == nil && fallback.displayID == 13, "unavailable source fallback was not sensible")
        let reconnected = preferences.reconciled(windows: [original], displays: [13, 55],
                                                currentDisplayID: 13, explicitlySelectedWindowID: nil)
        try require(reconnected.displayID == 55, "reconnected preferred display was forgotten")

        var reused = original
        reused.processID = 701
        let wrongOwner = preferences.reconciled(windows: [reused], displays: [55],
                                               currentDisplayID: 55, explicitlySelectedWindowID: nil)
        try require(wrongOwner.window == nil, "a reused window ID silently selected a different app")
        reused = original
        reused.launchDate = Date(timeIntervalSince1970: 9999)
        let restartedOwner = preferences.reconciled(windows: [reused], displays: [55],
                                                   currentDisplayID: 55, explicitlySelectedWindowID: nil)
        try require(restartedOwner.window == nil, "reused process/window IDs survived owner restart validation")

        // Discovery started with an older choice, but the user chose again
        // before it completed. Reconciliation reads the current preference.
        let newer = CaptureSelectionPreferences.WindowIdentity(
            id: 32, processID: 701, bundleIdentifier: "com.example.Other", launchDate: Date(timeIntervalSince1970: 9999)
        )
        preferences.remember(windowID: newer.id, identity: newer)
        preferences.remember(displayID: 99)
        let latest = preferences.reconciled(windows: [original, newer], displays: [55, 99],
                                           currentDisplayID: 55, explicitlySelectedWindowID: nil)
        try require(latest.window == newer && latest.displayID == 99,
                    "discovery restored an old source over a newer user choice")
        preferences.remember(windowID: nil, identity: nil)
        preferences.remember(displayID: nil)
        let cleared = CaptureViewModel(userDefaults: defaults)
        try require(cleared.selectedWindowID == nil && cleared.selectedDisplayID == nil,
                    "explicit source clearing was not persisted")

        defaults.set("Not a capture mode", forKey: "capture.kind")
        defaults.set(-1, forKey: "capture.window.id")
        defaults.set(Double(UInt32.max) + 1, forKey: "capture.display.id")
        let invalid = CaptureViewModel(userDefaults: defaults)
        try require(invalid.captureKind == .display, "invalid saved mode must safely default to Display")
        try require(invalid.selectedWindowID == nil && invalid.selectedDisplayID == nil,
                    "invalid saved identifiers were accepted")
        defaults.set(2.5, forKey: "capture.display.id")
        try require(preferences.displayID == nil, "fractional source identifier was accepted")
        print("Capture preference checks passed (first launch, mode/source round-trip, owner validation, fallback, and discovery races).")
    }
}
