import Foundation

private enum SimulationClockFailure: Error { case failed(String) }

/// The actual simulation transport clock with deterministic monotonic input.
/// No AppKit, AVFoundation, video fixture, decoder, image, or timer is needed.
@main
struct EditorSimulationClockChecks {
    static func main() throws {
        var clock = EditorSimulationClock(bounds: 2...8, time: 4)
        try near(clock.time, 4, "The paused source playhead starts at the requested time")
        clock.advance(to: 100)
        try near(clock.time, 4, "A paused clock ignores elapsed wall time")
        clock.play(at: 100)
        clock.advance(to: 101)
        try near(clock.time, 5, "Playback advances on the original source-time axis")
        clock.play(at: 101)
        clock.pause(at: 102)
        try near(clock.time, 6, "Pause samples the exact elapsed time without a repeated Play resetting the anchor")
        try require(!clock.isPlaying, "Pause stops the transport")
        clock.advance(to: 300)
        try near(clock.time, 6, "Late timer delivery after Pause cannot move the playhead")
        clock.play(at: 300)
        clock.advance(to: 301)
        try near(clock.time, 7, "Resume continues from the paused frame without counting the paused interval")
        clock.advance(to: 301)
        try near(clock.time, 7, "Repeated delivery of the same monotonic time cannot double-count elapsed time")
        clock.seek(3)
        try require(!clock.isPlaying, "Seeking stops playback so a stale timer cannot overwrite the user's chosen frame")
        clock.advance(to: 500)
        try near(clock.time, 3, "A paused seek remains authoritative over a later timer callback")
        clock.play(at: 500)
        clock.advance(to: 600)
        try near(clock.time, 8, "A delayed tick stops exactly at the kept end instead of overshooting")
        try require(!clock.isPlaying, "Playback stops automatically at the kept end")
        clock.advance(to: 700)
        try near(clock.time, 8, "The ended clock remains stopped")
        clock.play(at: 700)
        try near(clock.time, 2, "Playing from the kept end restarts at the kept beginning")
        clock.advance(to: 701)
        try near(clock.time, 3, "A replay uses a new monotonic anchor")

        clock.seek(0)
        try near(clock.time, 0, "Source inspection may seek before the trimmed range")
        clock.play(at: 800)
        try near(clock.time, 2, "Playing from before the kept range restarts at the kept beginning")
        clock.seek(10)
        try near(clock.time, 10, "Source inspection may seek after the trimmed range")
        clock.play(at: 900)
        try near(clock.time, 2, "Playing from after the kept range restarts without changing the trim")

        var short = EditorSimulationClock(bounds: 4...4.05, time: 4)
        short.play(at: 1_000)
        short.advance(to: 1_000.02)
        try near(short.time, 4.02, "A short retained interval still advances smoothly")
        short.advance(to: 1_000.1)
        try near(short.time, 4.05, "Subframe intervals still honor their exact kept end")
        try require(!short.isPlaying, "Short playback ends normally")
        print("Simulation clock checks passed (source-time playback, pause/resume, ordered callbacks, authoritative seeks, trim/end/restart and short ranges; Foundation only, no media).")
    }

    static func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try require(abs(actual - expected) < 0.000001, "\(message): expected \(expected), got \(actual)")
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SimulationClockFailure.failed(message) }
    }
}
