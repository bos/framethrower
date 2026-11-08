import AppKit
import SwiftUI

@MainActor private final class CadenceWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Reads a supplied conversation once; every write by a real session is routed
/// to a disposable copy. Only suspended clocks and vector previews are used.
@main @MainActor struct PlaybackCadenceDiagnostics {
    enum Failure: Error { case failed(String) }
    struct Sample { var wall: Double; var clock: Double; var scale: Double }
    static func main() async throws {
        guard MediaProcessing.isSuspended, (2...3).contains(CommandLine.arguments.count) else {
            throw Failure.failed("Requires the video interlock and a read-only conversation archive path and optional saved project JSON path")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let original = try Data(contentsOf: source)
        let archive = DirectorConversation(storageURL: source)
        guard let snapshot = archive.lastProject else { throw Failure.failed("Archive has no saved project state") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cadence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var project: RecordingProject
        if CommandLine.arguments.count == 3 {
            project = try JSONDecoder().decode(RecordingProject.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        } else {
            project = RecordingProject(screenFilename: "never-open-screen.mov", cameraFilename: "never-open-camera.mov",
                duration: max(snapshot.state.trimEnd, 1), state: snapshot.state)
            project.ensureReferences()
        }
        var projectionCosts: [Double] = []
        var entries = 0
        for _ in 0..<50 {
            let start = ProcessInfo.processInfo.systemUptime
            entries = DirectorTranscript.entries(in: archive, references: project.references).count
            projectionCosts.append(ProcessInfo.processInfo.systemUptime - start)
        }
        report(String(format: "ARCHIVE bytes=%d exchanges=%d entries=%d boxes=%d projectionMeanMs=%.3f projectionMaxMs=%.3f",
            original.count, archive.exchanges.count, entries, project.state.regions.count,
            projectionCosts.reduce(0,+) / Double(projectionCosts.count) * 1000, (projectionCosts.max() ?? 0) * 1000))
        let points = project.state.zoomKeyframes.filter { $0.transition == .smooth }.suffix(2)
        guard !points.isEmpty else { throw Failure.failed("Saved state has no smooth Screen motion") }
        for director in [false, true] {
            let copy = directory.appendingPathComponent("conversation-\(director).json")
            try original.write(to: copy)
            let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("project-\(director).framethrower"))
            let session = EditorAssistantSession(transport: { _ in throw Failure.failed("No model request is allowed") },
                conversationStorageURL: copy)
            let playback = EditorPlayback()
            let host = NSHostingView(rootView: ProjectEditorView(editor: editor, directorModeInitiallyEnabled: director,
                playback: playback, assistant: session))
            let window = CadenceWindow(contentRect: CGRect(x: -15000, y: -15000, width: 1250, height: 900),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            guard let canvas = views(EditorCanvasView.self, in: host).first,
                  let timeline = views(RecordingTimelineView.self, in: host).first else { throw Failure.failed("Production native preview missing") }
            for point in points {
                playback.pause()
                playback.seek(max(project.state.trimStart, point.time - min(1.2, point.duration) - 0.06))
                try await Task.sleep(for: .milliseconds(80))
                let fixedCanvas = canvas.frame, fixedTimeline = timeline.frame, before = editor.project
                var samples: [Sample] = []
                var previous: ZoomPlacement? = nil
                playback.togglePlayback()
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while playback.isPlaying && playback.time < point.time + 0.06 && ProcessInfo.processInfo.systemUptime < deadline {
                    if canvas.zoom != previous {
                        samples.append(Sample(wall: ProcessInfo.processInfo.systemUptime, clock: playback.time, scale: canvas.zoom.scale))
                        previous = canvas.zoom
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
                playback.pause()
                guard !playback.hasMediaPlayer, !canvas.hasMediaPlayerLayer, canvas.stillLayer.contents == nil,
                      editor.project == before, editor.draftState == nil, canvas.frame == fixedCanvas, timeline.frame == fixedTimeline else {
                    throw Failure.failed("Diagnostic changed history/layout or instantiated media: project=\(editor.project == before), draft=\(editor.draftState != nil), player=\(playback.hasMediaPlayer), videoLayer=\(canvas.hasMediaPlayerLayer), canvas \(fixedCanvas)→\(canvas.frame), timeline \(fixedTimeline)→\(timeline.frame)")
                }
                let active = samples.filter { $0.clock >= point.time - min(1.1, point.duration) && $0.clock <= point.time }
                let tail = active.filter { $0.clock >= point.time - 0.37 }
                func gaps(_ values: [Sample]) -> [Double] {
                    zip(values, values.dropFirst()).map { $1.wall - $0.wall }
                }
                let wholeGaps = gaps(active), tailGaps = gaps(tail)
                let scaleNow = project.state.zoom(at: point.time).scale
                let scaleBefore = project.state.zoom(at: point.time - 0.1).scale
                let screenTravel = canvas.contentRect.width * abs(scaleNow - scaleBefore)
                report(String(format: "CADENCE director=%@ target=%.5f duration=%.5f delivered=%d tailDelivered=%d meanMs=%.3f maxMs=%.3f tailMaxMs=%.3f lastSampleBeforeEndMs=%.3f last100msScaleDelta=%.10f screenWidthScaleTravel=%.6f",
                    director ? "open" : "closed", point.time, point.duration, active.count, tail.count,
                    wholeGaps.isEmpty ? 0 : wholeGaps.reduce(0,+)/Double(wholeGaps.count)*1000,
                    (wholeGaps.max() ?? 0)*1000, (tailGaps.max() ?? 0)*1000,
                    (point.time - (active.last?.clock ?? point.time))*1000, scaleNow-scaleBefore, screenTravel))
                guard active.count >= 3 else { throw Failure.failed("Insufficient delivered native viewport updates") }
            }
            session.suspend(); playback.close(); window.close()
            try await Task.sleep(for: .milliseconds(80))
        }
        report("Playback cadence diagnostic completed (saved dialogue read-only; actual suspended ProjectEditorView/vector updates; no AV objects, model calls or media).")
    }
    static func report(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    static func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }
}
