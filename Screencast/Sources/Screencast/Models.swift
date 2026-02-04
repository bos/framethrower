import ScreenCaptureKit
import SwiftUI

struct ShareableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let title: String
    let owningApplication: String
    let window: SCWindow

    init(window: SCWindow) {
        id = window.windowID
        title = window.title ?? "Untitled"
        owningApplication = window.owningApplication?.applicationName ?? "Unknown App"
        self.window = window
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

struct CaptureArea: Hashable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 1280
    var height: Double = 720

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
