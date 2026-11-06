import Foundation

private enum AudioCheckError: Error { case failed(String) }

@main
struct CaptureAudioSettingsChecks {
    static func main() throws {
        let suite = "FrameThrower.CaptureAudioSettingsChecks.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw AudioCheckError.failed("isolated preferences unavailable")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        try require(CaptureAudioSettings(defaults: defaults) == CaptureAudioSettings(),
                    "fresh screen-only capture should retain its existing audio defaults")

        // Existing installations use these same keys. Take the full snapshot
        // before property observers can write partially restored settings back.
        defaults.set(true, forKey: "audio.recordSystem")
        defaults.set(false, forKey: "audio.recordMicrophone")
        defaults.set("remembered-microphone", forKey: "audio.selectedMicrophoneID")
        var settings = CaptureAudioSettings(defaults: defaults)
        CaptureAudioSettings().store(in: defaults)
        try require(settings.recordSystemAudio && settings.microphoneID == "remembered-microphone",
                    "restoration must keep the full saved snapshot through intermediate persistence")
        settings.cameraSelectionChanged(from: nil, to: "camera-a")
        settings.store(in: defaults)
        try require(CaptureAudioSettings(defaults: defaults) == settings && settings.recordMicrophoneAudio,
                    "camera activation must enable and persist microphone recording")
        try require(settings.recordSystemAudio && settings.microphoneID == "remembered-microphone",
                    "camera activation must preserve system audio and the selected microphone")

        settings.recordMicrophoneAudio = false
        settings.cameraSelectionChanged(from: "camera-a", to: "camera-b")
        settings.cameraSelectionChanged(from: "camera-b", to: "camera-b")
        settings.reconcileMicrophone(availableIDs: ["other", "remembered-microphone"])
        settings.store(in: defaults)
        let reopened = CaptureAudioSettings(defaults: defaults)
        try require(reopened == settings && !reopened.recordMicrophoneAudio,
                    "an explicit microphone Off must survive camera changes and reopening")
        try require(reopened.microphoneID == "remembered-microphone",
                    "device enumeration order must not replace an available remembered microphone")
        settings.cameraSelectionChanged(from: "camera-b", to: nil)
        settings.cameraSelectionChanged(from: nil, to: nil)
        try require(!settings.recordMicrophoneAudio, "turning a camera off must not enable the microphone")
        settings.cameraSelectionChanged(from: nil, to: "camera-a")
        try require(settings.recordMicrophoneAudio, "a new camera session should default microphone recording On again")

        settings.reconcileMicrophone(availableIDs: ["alphabetically-first", "system-default"])
        try require(settings.microphoneID == nil && settings.recordMicrophoneAudio,
                    "an unavailable microphone must fall back to the Mac default, without disabling recording")
        settings.store(in: defaults)
        settings = CaptureAudioSettings(defaults: defaults)
        settings.reconcileMicrophone(availableIDs: ["alphabetically-first", "system-default"])
        try require(settings.microphoneID == nil,
                    "Default must follow the Mac's selection rather than the first enumerated device")
        settings.recordMicrophoneAudio = false
        settings.reconcileMicrophone(availableIDs: [])
        try require(!settings.recordMicrophoneAudio && settings.microphoneID == nil,
                    "missing devices must not override an explicit microphone Off")
        print("Capture audio settings checks passed (camera session defaults, explicit Off, legacy persistence, remembered device restoration, and system-default fallback).")
    }

    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw AudioCheckError.failed(message) }
    }
}
