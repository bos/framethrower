@preconcurrency import AVFoundation
import Foundation

/// Inspect actual AVAudioMix parameters without opening an asset, player,
/// device, codec, compositor, sample buffer, or media file.
@main @MainActor
struct RecordingAudioMixChecks {
    enum Failure: Error { case failed(String) }

    static func main() throws {
        guard MediaProcessing.isSuspended else { throw Failure.failed("Requires the video interlock") }
        var state = RecordingProject(screenFilename: "never-open.mov", duration: 12).state
        state.trimStart = 2; state.trimEnd = 10
        try require(ProjectRenderer.audioMix(for: state, trackIDs: [11, 29], duration: 12) == nil,
                    "Unchanged settings leave the source audio pipeline alone")
        state.audio = RecordingAudio(volume: 0.8, fadeIn: 2, fadeOut: 3)
        try require(ProjectRenderer.audioMix(for: state, trackIDs: [], duration: 12) == nil,
                    "No original tracks cannot create an invented audio track")
        let mix = try parameters(state, duration: 12)
        for parameter in mix {
            try gain(parameter, at: 3, equals: 0.4)
            try gain(parameter, at: 5, equals: 0.8)
            try gain(parameter, at: 8.5, equals: 0.4)
        }
        state.audio.isMuted = true
        for parameter in try parameters(state, duration: 12) {
            for time in [2.5, 5, 9.5] { try gain(parameter, at: time, equals: 0) }
        }
        // The requested fades meet inside a short trim, in source time.
        state.trimStart = 5; state.trimEnd = 6
        state.audio = RecordingAudio(volume: 1, fadeIn: 4, fadeOut: 1)
        for parameter in try parameters(state, duration: 12) {
            try gain(parameter, at: 5.4, equals: 0.5)
            try gain(parameter, at: 5.9, equals: 0.5)
        }
        // Effective end follows the actual original duration as export does.
        state.trimStart = 2; state.trimEnd = 10
        state.audio = RecordingAudio(volume: 0.6, fadeOut: 2)
        for parameter in try parameters(state, duration: 8) {
            try gain(parameter, at: 5, equals: 0.6)
            try gain(parameter, at: 7, equals: 0.3)
        }
        print("Recording audio mix checks passed (actual AVAudioMix gain ramps, source-time trim boundaries, shortened fades, mute, independent track mapping, identity/no-track bypass; no assets, devices, codecs, playback or video).")
    }

    static func parameters(_ state: EditState, duration: Double) throws -> [AVAudioMixInputParameters] {
        guard let mix = ProjectRenderer.audioMix(for: state, trackIDs: [11, 29], duration: duration) else {
            throw Failure.failed("Expected an audio mix for edited settings")
        }
        try require(mix.inputParameters.map(\.trackID) == [11, 29],
                    "Every original track keeps its own input mapping")
        return mix.inputParameters
    }

    static func gain(_ parameter: AVAudioMixInputParameters, at seconds: Double, equals expected: Double) throws {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.invalid
        try require(parameter.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range),
                    "No framework gain ramp at source time \(seconds)")
        let duration = range.duration.seconds
        let fraction = duration.isFinite && duration > 0 ? (seconds - range.start.seconds) / duration : 0
        let actual = Double(start) + (Double(end) - Double(start)) * fraction
        try require(abs(actual - expected) < 0.001,
                    "Track \(parameter.trackID) at \(seconds): expected \(expected), got \(actual)")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
    }
}
