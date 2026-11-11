import AppKit
import SwiftUI
@testable import FrameThrower

@main @MainActor
struct DebugLiveCaptureToggleChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }
    static func all<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, $0) }
    }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Debug capture control failed: \(error)\n".utf8)); Darwin.exit(1) }
    }
    static func run() async throws {
        try require(MediaProcessing.isCaptureSuspended, "App/test process must start with live capture off")
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        var requests: [Bool] = []
        let host = NSHostingView(rootView: DebugLiveCaptureToggle(isOn: false, isEnabled: true) { requests.append($0) })
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 240, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(50)); host.layoutSubtreeIfNeeded()
        let button = all(NSButton.self, host).first { $0.identifier?.rawValue == "debug-live-capture" || $0.title == "Debug: Live capture" }!
        try require(button.state == .off && button.isEnabled && button.toolTip?.contains("next launch") == true, "Default, availability or session explanation missing")
        button.performClick(nil)
        try require(requests == [true], "Native checkbox did not request normal capture")
        // A fake callback tests the actual native control without enabling policy
        // or constructing camera/screen capture components.
        try require(MediaProcessing.isCaptureSuspended, "UI fixture enabled actual capture")
        host.rootView = DebugLiveCaptureToggle(isOn: true, isEnabled: true) { requests.append($0) }
        try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
        button.performClick(nil)
        try require(requests == [true, false], "Native checkbox did not request revocation")
        host.rootView = DebugLiveCaptureToggle(isOn: true, isEnabled: false) { requests.append($0) }
        try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
        try require(!button.isEnabled && button.state == .on, "Recording/transition lock did not preserve state")
        button.performClick(nil)
        try require(requests == [true, false], "Disabled control accepted a change")
        let defaults = UserDefaults(suiteName: "DebugCaptureControls-\(UUID())")!
        let model = CaptureViewModel(userDefaults: defaults, recordingDirectories: [])
        try require(!model.debugLiveCaptureEnabled && model.canChangeDebugLiveCapture && model.camera.session == nil, "Default model opened a camera or enabled capture")
        await model.setDebugLiveCaptureEnabled(false)
        try require(MediaProcessing.isCaptureSuspended && model.camera.session == nil && !model.isChangingDebugCapture, "No-op Off opened devices or stuck in transition")
        await model.camera.suspendCapture()
        try require(model.camera.session == nil, "Off lifecycle constructed a session")
        print("Debug capture UI checks passed: native checkbox, per-run Off default, on/off callbacks, busy lock, no camera/session/device/stream")
    }
}
