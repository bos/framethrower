import AppKit
import SwiftUI

/// Full production editor, empty playback, and vector guides only. These
/// callbacks drive the same edit selection and canvas actions as the UI.
@main @MainActor
struct DirectorReferenceChecks {
    enum Failure: Error { case failed(String) }

    private final class Pinch: NSEvent {
        var eventPhase: NSEvent.Phase = []
        var amount: CGFloat = 0
        var position = CGPoint.zero
        override var type: NSEvent.EventType { .magnify }
        override var phase: NSEvent.Phase { eventPhase }
        override var magnification: CGFloat { amount }
        override var locationInWindow: NSPoint { position }
    }

    static func main() async throws {
        guard MediaProcessing.isSuspended else { throw Failure.failed("Requires suspended media") }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        DispatchQueue.global().asyncAfter(deadline: .now() + 40) {
            FileHandle.standardError.write(Data("Director reference check exceeded 40 seconds\n".utf8))
            Darwin.exit(1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = ZoomKeyframe(time: 1, scale: 2, x: 0.3, y: 0.3)
        let b = ZoomKeyframe(time: 6, scale: 1)
        let first = EditorRegion(time: 0, rect: EditorRegionRect(x: 0.05, y: 0.05, width: 0.2, height: 0.2))
        let second = EditorRegion(time: 8, rect: EditorRegionRect(x: 0.8, y: 0.8, width: 0.15, height: 0.15))
        var project = RecordingProject(screenFilename: "missing-screen.mov", duration: 12)
        project.state.zoomKeyframes = [a, b]
        project.state.regions = [first, second]
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("reference.framethrower"))
        try require(editor.save(), "Save metadata-only fixture")
        let original = editor.project
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, directorModeInitiallyEnabled: true))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close(); _ = editor.cancelDraft() }
        try await settle(host)
        guard let canvas: EditorCanvasView = find(in: host), let timeline: RecordingTimelineView = find(in: host) else {
            throw Failure.failed("Production native editor controls missing")
        }
        try require(canvas.scribbleMode, "Director mode opens reference guides")
        for _ in 0..<3 {
            for edit in [a, b] {
                timeline.onSelectEdit?(edit.id)
                try await settle(host)
                try require(abs(timeline.playhead - edit.time) < 1e-8, "Selecting an edit still seeks its frame")
                try require(Set(canvas.guideBadges.map(\.regionID)) == [first.id, second.id],
                            "Switching edit marks must not filter reference guides by their drawing timestamps")
                canvas.onSelectRegion?(second.id)
                try await settle(host)
                try require(timeline.selectedEditID == edit.id && abs(timeline.playhead - edit.time) < 1e-8,
                            "Selecting a reference must preserve the edit and source time being directed")
                try require(canvas.guideBadges.first(where: { $0.regionID == second.id })?.selected == true,
                            "Reference selection highlights the matching preview badge")
                try require(canvas.playerLayer.player == nil && canvas.stillLayer.contents == nil,
                            "Reference UI must not access suspended video")
                canvas.onSelectRegion?(second.id)
                try await settle(host)
                try require(canvas.selectedRegionID == nil && canvas.scribbleMode &&
                            timeline.selectedEditID == edit.id && abs(timeline.playhead - edit.time) < 1e-8,
                            "Clicking the selected reference again clears only box selection")
            }
        }
        try require(editor.project == original && editor.draftState == nil, "Navigating references cannot edit the project")
        timeline.onSelectEdit?(a.id)
        try await settle(host)
        try require(canvas.guideBadges.first(where: { $0.regionID == second.id })?.outsideViewport == true,
                    "A box beyond the selected edit's zoom has an edge badge instead of disappearing")
        let pinch = Pinch()
        pinch.position = canvas.convert(CGPoint(x: canvas.contentRect.midX, y: canvas.contentRect.midY), to: nil)
        pinch.eventPhase = .began; pinch.amount = 0.1
        canvas.magnify(with: pinch)
        pinch.eventPhase = .ended; pinch.amount = 0
        canvas.magnify(with: pinch)
        try await settle(host)
        try require(editor.draftState != nil && canvas.scribbleMode, "Pinch can refine the current edit in Director mode")
        canvas.cancelOperation(nil)
        try await settle(host)
        try require(editor.draftState == nil && canvas.scribbleMode, "Escape cancels a framing draft before leaving Director mode")
        timeline.onSelectEdit?(a.id)
        try await settle(host)
        canvas.onSelectRegion?(second.id)
        try await settle(host)
        canvas.cancelOperation(nil)
        try await settle(host)
        try require(canvas.selectedRegionID == nil && canvas.scribbleMode &&
                    timeline.selectedEditID == a.id && abs(timeline.playhead - a.time) < 1e-8 && editor.project == original,
                    "Escape deselects the box without leaving Director, seeking, or changing edits")
        canvas.onSelectRegion?(second.id)
        try await settle(host)
        canvas.onSelectRegion?(nil)
        try await settle(host)
        try require(canvas.selectedRegionID == nil && canvas.scribbleMode && editor.project == original,
                    "An empty preview click clears the reference without changing project history")
        let newRect = EditorRegionRect(x: 0.4, y: 0.2, width: 0.2, height: 0.2)
        canvas.onDrawRegion?(newRect)
        try await settle(host)
        guard let drawn = editor.project.state.regions.last else { throw Failure.failed("New guide missing") }
        try require(drawn.time == a.time && drawn.editID == a.id && drawn.rect == newRect,
                    "A new box belongs to the selected edit, not the selected reference's original frame")
        try require(editor.project.undoHistory.count == 1 && editor.undo() && editor.project.state == original.state,
                    "Drawing after reference selection is one ordinary undoable edit")
        try await settle(host)
        canvas.cancelOperation(nil)
        try await settle(host)
        try require(!canvas.scribbleMode && canvas.guideBadges.isEmpty, "Leaving Director mode hides editing guides")
        print("Director reference checks passed (A/B navigation, persistent cross-frame and offscreen guides, linked selection without seeking, pinch/cancel, correct drawing frame, and Undo; no media).")
    }

    static func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(130))
        host.layoutSubtreeIfNeeded()
    }
    static func find<T: NSView>(in view: NSView) -> T? {
        if let value = view as? T { return value }
        for child in view.subviews { if let value: T = find(in: child) { return value } }
        return nil
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.failed(message) }
    }
}
