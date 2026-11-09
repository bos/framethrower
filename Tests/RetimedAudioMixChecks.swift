@preconcurrency import AVFoundation
import Foundation

/// Actual framework gain parameters, never assets, samples, playback or codecs.
@main @MainActor
struct RetimedAudioMixChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.failed(message) }
    }
    static func gain(_ parameter: AVAudioMixInputParameters, at seconds: Double, equals expected: Double) throws {
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.invalid
        let queried = parameter.getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 60_000),
            startVolume: &start, endVolume: &end, timeRange: &range)
        try require(queried, "Missing gain for track \(parameter.trackID)")
        let fraction = range.duration.seconds.isFinite && range.duration.seconds > 0 ? (seconds - range.start.seconds) / range.duration.seconds : 0
        let actual = Double(start) + Double(end - start) * fraction
        try require(abs(actual - expected) < 0.001, "Track \(parameter.trackID) at \(seconds): gain\(actual), expected\(expected)")
    }
    static func main() throws {
        try require(MediaProcessing.isSuspended, "Requires the media interlock")
        var state = RecordingProject(screenFilename: "never-open.mov", duration: 10).state
        state.speedKeyframes = [.init(time: 0, rate: 2, transition: .jump)]
        state.audio.volume = 0.8
        state.audio.updateChannel(.microphone) { $0.points = [.init(time: 4, gain: 0.2, transition: .jump)] }
        state.audio.updateChannel(.systemAudio) { $0.volume = 0.5 }
        let map = try RecordingTimeMap(duration: 10, trimStart: 0, trimEnd: 10, cuts: [], speedKeyframes: state.speedKeyframes)
        let segments: [RenderedProject.CutAudioSegment] = [
            .init(trackID: 11, clipIndex: 0, outputStart: 0, outputEnd: 5, role: .microphone),
            .init(trackID: 21, clipIndex: 0, outputStart: 0, outputEnd: 5, role: .systemAudio)]
        guard let mix = ProjectRenderer.cutAudioMix(for: state, timingMap: map, segments: segments) else { throw Failure.failed("Missing retimed audio mix") }
        let parameters = Dictionary(uniqueKeysWithValues: mix.inputParameters.map { ($0.trackID, $0) })
        try gain(parameters[11]!, at: 1, equals: 0.8)
        try gain(parameters[11]!, at: 2.5, equals: 0.16)
        try gain(parameters[21]!, at: 2.5, equals: 0.4)
        try require(mix.inputParameters.allSatisfy { $0.audioTimePitchAlgorithm == .spectral }, "Speed changes must preserve voices by default")
        state.preservesAudioPitch = false
        let shifted = ProjectRenderer.cutAudioMix(for: state, timingMap: map, segments: segments)!
        try require(shifted.inputParameters.allSatisfy { $0.audioTimePitchAlgorithm == .varispeed }, "Explicit pitch-following option was ignored")
        state.audio.updateChannel(.microphone) { $0.points = [.init(time: 6.5, gain: 0.2, transition: .jump)] }
        let cutMap = try RecordingTimeMap(duration: 10, trimStart: 0, trimEnd: 10,
            cuts: [.init(start: 4, end: 6, crossfade: 1)], speedKeyframes: state.speedKeyframes)
        let cutSegments: [RenderedProject.CutAudioSegment] = cutMap.clips.enumerated().flatMap { index, clip in
            [RenderedProject.CutAudioSegment(trackID: index == 0 ? 11 : 12, clipIndex: index,
                outputStart: clip.outputStart, outputEnd: clip.outputEnd, role: .microphone),
             RenderedProject.CutAudioSegment(trackID: index == 0 ? 21 : 22, clipIndex: index,
                outputStart: clip.outputStart, outputEnd: clip.outputEnd, role: .systemAudio)]
        }
        let cutMix = ProjectRenderer.cutAudioMix(for: state, timingMap: cutMap, segments: cutSegments)!
        let branches = Dictionary(uniqueKeysWithValues: cutMix.inputParameters.map { ($0.trackID, $0) })
        try gain(branches[11]!, at: 1.5, equals: 0.4)
        try gain(branches[12]!, at: 1.5, equals: 0.08)
        try gain(branches[21]!, at: 1.5, equals: 0.2)
        try gain(branches[22]!, at: 1.5, equals: 0.2)
        print("Retimed audio mix checks passed: actual per-role gain parameters, source-to-output automation, independent crossfade branches, preserved/following pitch; no media execution.")
    }
}
