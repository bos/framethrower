import AppKit
import ScreenCaptureKit
import SwiftUI

struct ShareableWindow: Identifiable, Hashable {
    let id: CGWindowID
    let rawTitle: String
    let title: String
    let owningApplication: String
    let bundleIdentifier: String?
    let windowLayer: Int
    let onScreen: Bool
    let frame: CGRect
    let window: SCWindow

    init(window: SCWindow) {
        id = window.windowID
        rawTitle = window.title?
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
        var details = [sizeText]
        if !onScreen {
            details.append("off-screen")
        }
        let suffix = details.joined(separator: ", ")
        return "\(primaryLabel) (\(suffix))"
    }

    var isSelectable: Bool {
        onScreen && frame.width >= 64 && frame.height >= 64
    }

    var normalizedRawTitle: String {
        rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var primaryLabel: String {
        if rawTitle.isEmpty || title.caseInsensitiveCompare(owningApplication) == .orderedSame {
            return owningApplication
        }
        if title.lowercased().hasPrefix(owningApplication.lowercased()) {
            return title
        }
        return "\(owningApplication) - \(title)"
    }
}

struct ShareableDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let index: Int
    let name: String
    let display: SCDisplay

    init(display: SCDisplay, index: Int) {
        id = display.displayID
        self.index = index
        let indexLabel = "Display \(index)"
        if let localized = ShareableDisplay.localizedDisplayName(for: id) {
            name = "\(localized) (\(indexLabel))"
        } else {
            name = indexLabel
        }
        self.display = display
    }

    private static func localizedDisplayName(for id: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            guard let screenID = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
            else {
                continue
            }
            if CGDirectDisplayID(screenID.uint32Value) == id {
                let label = screen.localizedName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if !label.isEmpty {
                    return label
                }
                return nil
            }
        }
        return nil
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

/// A value snapshot avoids one restored property overwriting the remaining
/// saved fields through the view model's persistence observers.
struct CaptureAudioSettings: Equatable {
    var recordSystemAudio = false
    var recordMicrophoneAudio = false
    /// nil lets ScreenCaptureKit follow the Mac's default microphone.
    var microphoneID: String?
}

extension CaptureAudioSettings {
    init(defaults: UserDefaults) {
        recordSystemAudio = defaults.bool(forKey: "audio.recordSystem")
        recordMicrophoneAudio = defaults.bool(forKey: "audio.recordMicrophone")
        microphoneID = defaults.string(forKey: "audio.selectedMicrophoneID")
    }

    func store(in defaults: UserDefaults) {
        defaults.set(recordSystemAudio, forKey: "audio.recordSystem")
        defaults.set(recordMicrophoneAudio, forKey: "audio.recordMicrophone")
        defaults.set(microphoneID, forKey: "audio.selectedMicrophoneID")
    }

    mutating func cameraSelectionChanged(from previous: String?, to next: String?) {
        if previous == nil, next != nil { recordMicrophoneAudio = true }
    }

    mutating func reconcileMicrophone(availableIDs: Set<String>) {
        if let microphoneID, !availableIDs.contains(microphoneID) { self.microphoneID = nil }
    }
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
