import AppKit
import SwiftUI
@testable import FrameThrower

@main @MainActor
struct EditorWorkspaceInteractionChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.failed(message) }
    }
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }
    static func region(in host: NSView) throws -> NSView {
        guard let value = all(EditorPreviewRegionMarker.MarkerView.self, in: host).first else {
            throw Failure.failed("Allocated preview-region marker missing")
        }
        return value
    }
    static func settle(_ host: NSView) async throws {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
    }
    static func event(_ type: NSEvent.EventType, point: CGPoint, window: NSWindow) throws -> NSEvent {
        guard let value = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { throw Failure.failed("Local divider event") }
        return value
    }
    static func snapshot(_ host: NSView, name: String) throws {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.failed("Vector snapshot") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: "/tmp/framethrower-\(name).png"))
        }
    }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Workspace interaction checks failed: \(error)\n".utf8)); Darwin.exit(1) }
    }
    static func run() async throws {
        try require(MediaProcessing.isSuspended && MediaProcessing.isCaptureSuspended, "Vector-only mode with live capture Off is mandatory")
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await SuspendingClock().sleep(for: .seconds(90)) } catch { return }
            FileHandle.standardError.write(Data("Workspace interaction checks exceeded 90 awake seconds\n".utf8)); Darwin.exit(1)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-interactions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for director in [false, true] { try await checkDivider(directory: directory, director: director) }
        try checkCanvasGeometry()
        print("Workspace interaction checks passed: stable native divider sampling/cancellation/bounds, growing timeline allocation, preserved project/playhead, aspect-correct canvas and visible border in light/dark; own invisible vector windows only.")
    }
    static func checkDivider(directory: URL, director: Bool) async throws {
        var project = RecordingProject(screenFilename: "unopened.mov", cameraFilename: "unopened-camera.mov", duration: 12,
            audioSources: [.init(role: .microphone), .init(role: .systemAudio)])
        project.state.zoomKeyframes = [.init(time: 4, scale: 2, transition: .smooth, duration: 1)]
        project.state.pipKeyframes.append(.init(time: 5, placement: .init(x: 0.2, y: 0.3, scale: 0.3), transition: .smooth, duration: 1))
        project.state.cameraOpacityKeyframes = [.init(time: 7, opacity: 0.4, transition: .smooth, duration: 1)]
        project.state.speedKeyframes = [.init(time: 8, rate: 2)]
        project.state.audio.channels = [.init(role: .microphone, points: [.init(time: 3, gain: 0.6)]),
            .init(role: .systemAudio, points: [.init(time: 6, gain: 0.4)])]
        project.state.cuts = [.init(start: 9, end: 10)]
        let editor = ProjectEditor(project: project, url: directory.appendingPathComponent("\(director).framethrower"))
        try require(editor.save(), "Save vector fixture")
        let playback = EditorPlayback()
        let host = NSHostingView(rootView: ProjectEditorView(editor: editor, directorModeInitiallyEnabled: director,
            playback: playback, assistant: EditorAssistantSession(transport: { _ in throw CancellationError() }, persistsConversation: false)))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 1100, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host; window.orderBack(nil)
        defer { playback.close(); window.close() }
        let deadline = SuspendingClock.now.advanced(by: .seconds(15))
        while !playback.canPlay || all(RecordingTimelineView.self, in: host).isEmpty {
            try require(SuspendingClock.now < deadline, "Vector editor did not become ready")
            try await settle(host)
        }
        let previewRegion = try region(in: host)
        guard let canvas = all(EditorCanvasView.self, in: host).first,
              let timeline = all(RecordingTimelineView.self, in: host).first,
              let divider = all(EditorTimelineDivider.DividerView.self, in: host).first else { throw Failure.failed("Production workspace views missing") }
        try await settle(host)
        try require(timeline.enclosingScrollView!.contentView.bounds.height >= timeline.bounds.height - 2,
            "Opening an already-roomy window still clips tracks")
        try require(timeline.showsTrimHandles && timeline.sourceTrimDuration == project.duration,
            "Output timeline must expose full-source trim handles")
        try require(timeline.enclosingScrollView!.contentView.bounds.minY <= 1,
            "Installing the ruler scrolled the playhead and trim handles out of view")
        window.setContentSize(CGSize(width: 1100, height: 540)); try await settle(host)
        guard let ruler = timeline.pinnedTimeRuler, let trackScroll = timeline.enclosingScrollView else {
            throw Failure.failed("Numeric timeline ruler missing")
        }
        try require(trackScroll.hasHorizontalRuler && trackScroll.rulersVisible && !ruler.isHiddenOrHasHiddenAncestor,
            "Numeric ruler is not visible in a compact populated timeline")
        let rulerFrame = ruler.convert(ruler.bounds, to: host)
        let trimHandle = timeline.convert(CGRect(x: timeline.trimX(for: project.state.trimStart) - 5,
            y: 14, width: 10, height: 20), to: host)
        try require(!rulerFrame.intersects(trimHandle), "Pinned ruler covers part of a trim handle: \(rulerFrame), \(trimHandle)")
        try require(host.bounds.insetBy(dx: -1, dy: -1).contains(rulerFrame) && rulerFrame.height >= 18,
            "Pinned time ruler is clipped")
        let visibleTicks = timeline.timeRulerTicks().filter { tick in
            let x = ruler.convert(CGPoint(x: timeline.x(for: tick.time), y: 0), from: timeline).x
            return !tick.label.isEmpty && x >= ruler.bounds.minX && x <= ruler.bounds.maxX
        }
        try require(visibleTicks.count >= 2, "Compact timeline has no discoverable numeric timescale")
        let original = editor.project
        try snapshot(host, name: "rich-timeline-compact-\(director ? "director" : "properties")")
        let trackClip = trackScroll.contentView, originalScroll = trackScroll.contentView.bounds.origin
        trackClip.scroll(to: CGPoint(x: originalScroll.x, y: max(0, timeline.bounds.height - trackClip.bounds.height)))
        trackScroll.reflectScrolledClipView(trackClip); try await settle(host)
        try require(ruler.convert(ruler.bounds, to: host) == rulerFrame,
            "Scrolling tracks moved their numeric ruler")
        try snapshot(host, name: "rich-timeline-scrolled-\(director ? "director" : "properties")")
        trackClip.scroll(to: originalScroll); trackScroll.reflectScrolledClipView(trackClip); try await settle(host)
        let compactPreview = previewRegion.bounds.height
        let compactDivider = divider.convert(divider.bounds, to: host)
        window.setContentSize(CGSize(width: 1100, height: 900)); try await settle(host)
        let roomyDivider = divider.convert(divider.bounds, to: host)
        try snapshot(host, name: "rich-timeline-roomy-\(director ? "director" : "properties")")
        // The richer timeline may consume some of the added height until its
        // actual rows fit. Afterwards, further height belongs to the preview.
        try require(roomyDivider.maxY > compactDivider.maxY || previewRegion.bounds.height > compactPreview,
            "Enlarging the window did not expand either useful workspace area")
        guard let clip = timeline.enclosingScrollView?.contentView else { throw Failure.failed("Timeline scroll viewport missing") }
        try require(clip.bounds.height >= timeline.bounds.height - 2, "A roomy window still clips populated timeline rows: viewport \(clip.bounds), document \(timeline.bounds)")
        let fittedPreview = previewRegion.bounds.height
        window.setContentSize(CGSize(width: 1100, height: 1100)); try await settle(host)
        try require(abs(previewRegion.bounds.height - fittedPreview - 200) <= 2,
            "Height after timeline fit was not allocated to preview: \(previewRegion.bounds.height - fittedPreview)")
        window.setContentSize(CGSize(width: 1100, height: 900)); try await settle(host)
        let baseline = previewRegion.bounds.height
        let playhead = playback.outputTime
        let origin = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        try require(divider.hitTest(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY)) != nil,
            "Native divider cannot receive a drag")
        divider.mouseDown(with: try event(.leftMouseDown, point: origin, window: window))
        var previousSample: (delta: Double, height: CGFloat)?
        for delta in [8.0, 16, 24, 40, 56, 80, 80, 80, 64, 40, 16, 0, -8, -24, -40, -40, 0] {
            // Deliberately preserve the initial WINDOW point. The divider moves
            // during layout, so recomputing local points would hide feedback.
            let point = CGPoint(x: origin.x, y: origin.y + delta)
            divider.mouseDragged(with: try event(.leftMouseDragged, point: point, window: window))
            try await settle(host)
            try require(abs(previewRegion.bounds.height - (baseline - delta)) <= 2,
                "Divider feedback/jitter at delta \(delta): preview \(previewRegion.bounds.height), expected \(baseline - delta), Director \(director)")
            if let previousSample, previousSample.delta == delta {
                try require(abs(previewRegion.bounds.height - previousSample.height) < 0.1,
                    "Holding a stationary divider pointer oscillated its allocation")
            }
            previousSample = (delta, previewRegion.bounds.height)
        }
        divider.mouseUp(with: try event(.leftMouseUp, point: origin, window: window)); try await settle(host)
        divider.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: origin.x, y: origin.y + 40), window: window))
        try await settle(host)
        try require(abs(previewRegion.bounds.height - baseline) <= 2, "A drag continued after mouse-up")
        divider.mouseDown(with: try event(.leftMouseDown, point: origin, window: window))
        divider.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: origin.x, y: origin.y + 40), window: window))
        try await settle(host); divider.cancelOperation(nil); try await settle(host)
        divider.mouseUp(with: try event(.leftMouseUp, point: CGPoint(x: origin.x, y: origin.y + 80), window: window)); try await settle(host)
        try require(abs(previewRegion.bounds.height - baseline) <= 2, "Cancel then late mouse-up did not restore divider allocation")
        divider.mouseDown(with: try event(.leftMouseDown, point: origin, window: window))
        for delta in [5000.0, 5000, -5000, -5000, 0] {
            divider.mouseDragged(with: try event(.leftMouseDragged, point: CGPoint(x: origin.x, y: origin.y + delta), window: window))
            try await settle(host)
            try require(previewRegion.bounds.height >= 158 && previewRegion.bounds.height < host.bounds.height,
                "Divider crossed preview bounds at \(delta): \(previewRegion.bounds)")
        }
        divider.mouseUp(with: try event(.leftMouseUp, point: origin, window: window)); try await settle(host)
        guard let microphone = timeline.animationGeometry().first(where: { $0.animation.lane == .audioMicrophone }) else {
            throw Failure.failed("Recorded microphone lane has no selectable span")
        }
        let microphonePoint = timeline.convert(CGPoint(x: microphone.body.midX, y: microphone.body.midY), to: nil)
        timeline.mouseDown(with: try event(.leftMouseDown, point: microphonePoint, window: window))
        timeline.mouseUp(with: try event(.leftMouseUp, point: microphonePoint, window: window))
        try await settle(host)
        let context = try await EditorUIProbe.context(editor: editor)
        try require(context["inspector"] as? String == "Camera" && timeline.selectedAnimationID?.lane == .audioMicrophone,
            "Selecting the recorded microphone did not reveal its related PIP properties")
        guard let duration = all(MotionDurationTextField.self, in: host).first else {
            throw Failure.failed("Selected microphone fade duration missing")
        }
        let durationFrame = duration.convert(duration.bounds, to: host)
        var ancestor = duration.superview
        while let view = ancestor {
            if let propertyClip = view as? NSClipView {
                try require(propertyClip.convert(propertyClip.bounds, to: host).insetBy(dx: -1, dy: -1).contains(durationFrame),
                    "Selecting microphone left its timed controls below the property fold")
            }
            ancestor = view.superview
        }
        try snapshot(host, name: "pip-microphone-\(director ? "director" : "properties")")
        // Explicit selection reveals its controls, but live previews must not
        // scroll the active controls away as they create/select a new point.
        if director {
            // Keep the base camera panel scrollable even when onBegin removes
            // the Mic envelope. Otherwise AppKit must legally clamp to zero.
            window.setContentSize(CGSize(width: 1100, height: 540)); try await settle(host)
        }
        var propertyAncestor = duration.superview
        var propertyClip: NSClipView?
        while let view = propertyAncestor {
            if let clip = view as? NSClipView { propertyClip = clip; break }
            propertyAncestor = view.superview
        }
        guard let propertyClip, let propertyDocument = propertyClip.documentView else {
            throw Failure.failed("Property viewport missing")
        }
        let maximumScroll = max(0, propertyDocument.bounds.height - propertyClip.bounds.height)
        if director { try require(maximumScroll >= 8, "Director fixture does not exercise a scrollable property panel") }
        propertyClip.scroll(to: CGPoint(x: propertyClip.bounds.minX, y: min(8, maximumScroll)))
        propertyClip.enclosingScrollView?.reflectScrolledClipView(propertyClip); try await settle(host)
        let liveScroll = propertyClip.bounds.origin
        let liveViewport = propertyClip.bounds
        let liveDocument = propertyDocument.bounds
        try require(!editor.editingState.pipKeyframes.contains(where: { abs($0.time - 3) < 0.000001 }),
            "Live-preview fixture already has the target camera point")
        canvas.onBegin?(); try await settle(host)
        if director {
            try require(propertyDocument.bounds.height - propertyClip.bounds.height >= 8,
                "Camera regression fixture ceased to be scrollable after gesture began")
        }
        try require(abs(propertyClip.bounds.minY - liveScroll.y) < 0.5,
            "Beginning camera gesture scrolled controls: Director=\(director), before viewport=\(liveViewport) document=\(liveDocument), after viewport=\(propertyClip.bounds) document=\(propertyDocument.bounds)")
        for x in [0.2, 0.25, 0.3] {
            var placement = editor.editingState.placement(at: 3); placement.x = x
            canvas.onPreview?(placement); try await settle(host)
            try require(editor.draftState?.pipKeyframes.contains(where: { abs($0.time - 3) < 0.000001 }) == true
                && timeline.selectedAnimationID?.lane == .camera,
                "Camera preview did not create/select its new camera point")
            try require(abs(propertyClip.bounds.minY - liveScroll.y) < 0.5,
                "A new camera-point selection scrolled its live controls away")
        }
        canvas.onCancel?(); try await settle(host)
        try require(editor.draftState == nil && editor.project == original,
            "Cancelling property-scroll regression gesture did not restore the project")
        guard let microphoneAgain = timeline.animationGeometry().first(where: { $0.animation.lane == .audioMicrophone }) else {
            throw Failure.failed("Microphone span disappeared after cancelled camera preview")
        }
        timeline.scrollToVisible(microphoneAgain.body); try await settle(host)
        let pointAgain = timeline.convert(CGPoint(x: microphoneAgain.body.midX, y: microphoneAgain.body.midY), to: nil)
        timeline.mouseDown(with: try event(.leftMouseDown, point: pointAgain, window: window))
        timeline.mouseUp(with: try event(.leftMouseUp, point: pointAgain, window: window)); try await settle(host)
        guard let revealedDuration = all(MotionDurationTextField.self, in: host).first else {
            throw Failure.failed("Explicit microphone re-selection did not restore its timed controls")
        }
        try require(propertyClip.convert(propertyClip.bounds, to: host).insetBy(dx: -1, dy: -1)
            .contains(revealedDuration.convert(revealedDuration.bounds, to: host)),
            "Explicit microphone re-selection no longer reveals its timed controls")
        try require(editor.project == original && playback.outputTime == playhead && !playback.isInspectingSource,
            "Workspace resizing changed edits, history or the project playhead")
        for (edge, from, to) in [("start", 0.0, 1.0), ("end", 12.0, 11.0)] {
            let beforeTrim = editor.project
            let start = timeline.convert(CGPoint(x: timeline.trimX(for: from), y: 24), to: nil)
            let end = timeline.convert(CGPoint(x: timeline.trimX(for: to), y: 24), to: nil)
            timeline.mouseDown(with: try event(.leftMouseDown, point: start, window: window))
            timeline.mouseDragged(with: try event(.leftMouseDragged, point: end, window: window)); try await settle(host)
            try require(editor.project == beforeTrim, "Source trim saved before release")
            timeline.mouseUp(with: try event(.leftMouseUp, point: end, window: window)); try await settle(host)
            try require(abs((edge == "start" ? editor.project.state.trimStart : editor.project.state.trimEnd) - to) < 0.000001
                && editor.project.undoHistory.count == original.undoHistory.count + 1 && !playback.isInspectingSource,
                "Output timeline \(edge) trim did not save one source-timed operation")
            try require(editor.undo(), "Undo source trim"); try await settle(host)
            try require(editor.project.state == original.state && timeline.sourceTrimDuration == project.duration,
                "Undo did not recover the source trim and its full range")
        }
        try require(!playback.hasMediaPlayer && !canvas.hasMediaPlayerLayer, "Vector resize opened media")
    }
    static func checkCanvasGeometry() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: name) else { throw Failure.failed("Appearance missing") }
            for source in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920), CGSize(width: 3840, height: 960)] {
                for aspect in [CanvasAspect.source, .square, .portrait, .wide] {
                  for white in [false, true] {
                    let canvas = EditorCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 520))
                    canvas.appearance = appearance
                    let presentation = CanvasPresentation(aspect: aspect, padding: 0.15,
                        background: white ? CanvasColor(red: 1, green: 1, blue: 1) : .black)
                    appearance.performAsCurrentDrawingAppearance {
                        canvas.configure(player: nil, image: nil, sourceSize: source, cameraAspect: 16.0 / 9,
                            placement: .init(), cameraEnabled: false, presentation: presentation, nativeSourceSize: source)
                        canvas.layoutSubtreeIfNeeded()
                    }
                    let expectedAspect: CGFloat = switch aspect {
                    case .source: source.width / source.height
                    case .square: 1
                    case .portrait: 9.0 / 16
                    case .wide: 16.0 / 9
                    }
                    try require(abs(canvas.canvasRect.width / canvas.canvasRect.height - expectedAspect) < 0.000001,
                        "Preview stretched \(source), \(aspect)")
                    try require(abs(canvas.contentRect.width / canvas.contentRect.height - source.width / source.height) < 0.000001,
                        "Screen content was stretched while fitting the output canvas")
                    try require(canvas.bounds.insetBy(dx: -1, dy: -1).contains(canvas.canvasRect), "Output canvas escapes viewer")
                    try require(!canvas.hasMediaPlayerLayer, "Canvas geometry allocated video")
                    try checkBorder(canvas, appearance: appearance, white: white,
                        label: "\(name.rawValue)-\(Int(source.width))-\(aspect.rawValue)-\(white ? "white" : "black")")
                  }
                }
            }
        }
    }
    static func checkBorder(_ canvas: EditorCanvasView, appearance: NSAppearance, white: Bool, label: String) throws {
        guard let borderLayer = canvas.layer?.sublayers?.first(where: { $0.name == "output-canvas-border" }) else {
            throw Failure.failed("Output canvas border layer missing")
        }
        let border = borderLayer.frame
        try require(abs(border.minX - canvas.canvasRect.minX) <= 1 && abs(border.minY - canvas.canvasRect.minY) <= 1
            && abs(border.width - canvas.canvasRect.width) <= 2 && abs(border.height - canvas.canvasRect.height) <= 2,
            "Border outlines the viewer instead of the actual output canvas: \(border), \(canvas.canvasRect)")
        try require((0.5...1.5).contains(borderLayer.borderWidth) && !borderLayer.isHidden,
            "Output border is missing or excessively thick")
        let width = Int(canvas.bounds.width), height = Int(canvas.bounds.height)
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        defer { bytes.deallocate() }
        guard let context = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let layer = canvas.layer else { throw Failure.failed("Border raster context") }
        context.setFillColor((white ? NSColor.white : NSColor.black).cgColor); context.fill(canvas.bounds)
        appearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
        func brightness(_ x: CGFloat, _ y: CGFloat) -> Double {
            let a = min(width - 1, max(0, Int(x))), b = min(height - 1, max(0, Int(y)))
            let i = (b * width + a) * 4
            return (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
        }
        let vertical = canvas.canvasRect.minX > 4
        let x = vertical ? canvas.canvasRect.minX : canvas.canvasRect.midX
        let y = vertical ? canvas.canvasRect.midY : canvas.canvasRect.minY
        let edgeSamples = (-2...2).map { offset in brightness(x + (vertical ? CGFloat(offset) : 0), y + (vertical ? 0 : CGFloat(offset))) }
        let edge = white ? edgeSamples.min()! : edgeSamples.max()!
        let outside = brightness(x - (vertical ? 4 : 0), y - (vertical ? 0 : 4))
        let inside = brightness(x + (vertical ? 4 : 0), y + (vertical ? 0 : 4))
        try require(white ? edge < min(outside, inside) - 8 : edge > max(outside, inside) + 8,
            "Output boundary is not visibly distinguished in \(label): edge \(edge), surrounding \(outside)/\(inside)")
        if label.contains("1080-source"), let image = context.makeImage() {
            let rep = NSBitmapImageRep(cgImage: image)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "/tmp/framethrower-output-border-\(appearance.name.rawValue)-\(white ? "white" : "black").png"))
            }
        }
    }
}
