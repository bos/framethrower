import ScreenCaptureKit
import SwiftUI

struct ShareableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let owningApplication: String
    let bundleIdentifier: String?
    let windowLayer: Int
    let onScreen: Bool
    let frame: CGRect
    let window: SCWindow

    init(window: SCWindow) {
        id = window.windowID
        let rawTitle = window.title?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = rawTitle.isEmpty ? "Untitled" : rawTitle
        owningApplication = window.owningApplication?.applicationName ?? "Unknown App"
        bundleIdentifier = window.owningApplication?.bundleIdentifier
        windowLayer = window.windowLayer
        onScreen = window.isOnScreen
        frame = window.frame
        self.window = window
    }

    var displayName: String {
        let sizeText = "\(Int(frame.width))x\(Int(frame.height))"
        var details = ["id \(id)", sizeText]
        if !onScreen {
            details.append("off-screen")
        }
        if windowLayer != 0 {
            details.append("layer \(windowLayer)")
        }
        let suffix = details.joined(separator: ", ")
        return "\(owningApplication) - \(title) (\(suffix))"
    }

    var isSelectable: Bool {
        onScreen && frame.width >= 64 && frame.height >= 64
    }
}

struct ShareableDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let display: SCDisplay

    init(display: SCDisplay) {
        id = display.displayID
        name = "Display \(display.displayID)"
        self.display = display
    }
}

enum CaptureSourceKind: String, CaseIterable, Identifiable {
    case window = "Window"
    case display = "Display"
    case area = "Area"

    var id: String { rawValue }
}

enum SlackTargetKind: String, CaseIterable, Identifiable {
    case channel = "Channel"
    case person = "Person"

    var id: String { rawValue }
}

struct MicrophoneDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct CaptureArea: Hashable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1280
    var height: Double = 720

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
