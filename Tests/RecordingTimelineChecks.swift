import AppKit

// Run with Tests/check-recording-timeline.sh. Exercises native mouse/keyboard
// handling offscreen, including the overlapping trim and playhead controls.
@main
struct RecordingTimelineChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let timeline = RecordingTimelineView(frame: CGRect(x: 20, y: 20, width: 624, height: 48))
        window.contentView!.addSubview(timeline)

        var seeks: [Double] = []
        var trims: [(Double, Double)] = []
        var interactions = 0
        var scrubPhases: [String] = []
        timeline.onSeek = { time in
            precondition(scrubPhases.last == "begin", "Every seek must occur inside an active scrub")
            seeks.append(time); timeline.playhead = time
        }
        timeline.onScrubBegan = { scrubPhases.append("begin") }
        timeline.onScrubEnded = { scrubPhases.append("end") }
        timeline.onTrim = { start, end in
            trims.append((start, end))
            timeline.trimStart = start
            timeline.trimEnd = end
        }
        timeline.onInteractionBegan = { interactions += 1 }

        func reset(duration: Double = 10, start: Double = 2, end: Double = 8, playhead: Double = 4) {
            timeline.duration = duration
            timeline.trimStart = start
            timeline.trimEnd = end
            timeline.playhead = playhead
            seeks = []
            trims = []
            interactions = 0
            scrubPhases = []
        }
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: timeline.convert(point, to: nil), modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func down(_ point: CGPoint) { timeline.mouseDown(with: mouse(.leftMouseDown, at: point)) }
        func drag(_ point: CGPoint) { timeline.mouseDragged(with: mouse(.leftMouseDragged, at: point)) }
        func up(_ point: CGPoint) { timeline.mouseUp(with: mouse(.leftMouseUp, at: point)) }
        func gesture(from: CGPoint, to: CGPoint) { down(from); drag(to); up(to) }
        func key(_ code: UInt16, shift: Bool = false) {
            timeline.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                keyCode: code)!)
        }

        reset()
        precondition(timeline.isFlipped, "Timeline gestures use top-left coordinates")
        near(timeline.x(for: 0), 12, "Source start inset")
        near(timeline.x(for: 10), 612, "Source end inset")
        near(timeline.x(for: 5), 312, "Common source-time geometry")
        down(CGPoint(x: timeline.x(for: 5), y: 24))
        near(seeks.last, 5, "Clicking the track seeks immediately")
        drag(CGPoint(x: timeline.x(for: 6), y: 24))
        near(seeks.last, 6, "Dragging the track seeks before mouse-up")
        up(CGPoint(x: timeline.x(for: 6), y: 24))
        precondition(trims.isEmpty && interactions == 1, "Scrubbing never creates trim edits")
        precondition(scrubPhases == ["begin", "end"], "A mouse scrub has one begin and one end")

        reset()
        gesture(from: CGPoint(x: timeline.x(for: 5), y: 24), to: CGPoint(x: -100, y: 24))
        near(seeks.last, 2, "Scrubbing clamps to the retained start")
        reset()
        gesture(from: CGPoint(x: timeline.x(for: 5), y: 24), to: CGPoint(x: 900, y: 24))
        near(seeks.last, 8, "Scrubbing clamps to the retained end")

        reset()
        let offCenterStart = CGPoint(x: timeline.x(for: 2) + 6, y: 24)
        down(offCenterStart)
        precondition(seeks.isEmpty && trims.isEmpty, "Grabbing a trim handle does not seek or commit")
        drag(CGPoint(x: offCenterStart.x + 60, y: 24))
        drag(CGPoint(x: offCenterStart.x + 120, y: 24))
        precondition(trims.isEmpty, "Trim drag creates no intermediate undo entries")
        up(CGPoint(x: offCenterStart.x + 120, y: 24))
        precondition(trims.count == 1 && interactions == 1, "A trim drag commits once")
        precondition(scrubPhases.isEmpty, "Trimming must not start a video scrub")
        near(trims.last?.0, 4, "Off-center grab uses translation without jumping")
        near(trims.last?.1, 8, "Trimming the start preserves the end")

        reset()
        let offCenterEnd = CGPoint(x: timeline.x(for: 8) - 6, y: 24)
        gesture(from: offCenterEnd, to: CGPoint(x: offCenterEnd.x - 60, y: 24))
        precondition(trims.count == 1)
        near(trims.last?.0, 2, "Trimming the end preserves the start")
        near(trims.last?.1, 7, "End handle uses the same source-time scale")

        reset()
        let stationaryHandle = CGPoint(x: timeline.x(for: 2) + 6, y: 24)
        down(stationaryHandle)
        up(stationaryHandle)
        precondition(trims.isEmpty && seeks.isEmpty, "A stationary handle click creates no undo entry")

        reset(start: 0, end: 10, playhead: 0)
        let topThumb = CGPoint(x: timeline.x(for: 0) + 5, y: 6)
        down(topThumb)
        near(timeline.playhead, 0, "Off-center playhead grab does not jump")
        drag(CGPoint(x: topThumb.x + 60, y: 6))
        near(seeks.last, 1, "Top playhead remains draggable when it overlaps trim start")
        up(CGPoint(x: topThumb.x + 60, y: 6))
        precondition(trims.isEmpty)
        reset(start: 0, end: 10, playhead: 0)
        let lowerTrim = CGPoint(x: timeline.x(for: 0) + 5, y: 24)
        gesture(from: lowerTrim, to: CGPoint(x: lowerTrim.x + 60, y: 24))
        near(trims.last?.0, 1, "Lower trim handle remains independently draggable at overlap")
        precondition(seeks.isEmpty)

        reset()
        gesture(from: CGPoint(x: timeline.x(for: 2), y: 24), to: CGPoint(x: 900, y: 24))
        near(trims.last?.0, 7.9, "Start cannot cross end or discard the minimum retained duration")
        reset()
        gesture(from: CGPoint(x: timeline.x(for: 8), y: 24), to: CGPoint(x: -100, y: 24))
        near(trims.last?.1, 2.1, "End cannot cross start")
        reset()
        gesture(from: CGPoint(x: timeline.x(for: 2), y: 24), to: CGPoint(x: -100, y: 24))
        near(trims.last?.0, 0, "Trim start clamps to original source start")
        reset()
        gesture(from: CGPoint(x: timeline.x(for: 8), y: 24), to: CGPoint(x: 900, y: 24))
        near(trims.last?.1, 10, "Trim end clamps to original source end")

        reset(duration: 0.05, start: 0, end: 0.05, playhead: 0)
        gesture(from: CGPoint(x: timeline.x(for: 0), y: 24), to: CGPoint(x: 900, y: 24))
        near(timeline.trimStart, 0, "Very short recording remains nonempty")
        near(timeline.trimEnd, 0.05, "Very short recording keeps its valid source range")

        reset()
        key(124)
        near(seeks.last, 4.1, "Right arrow steps by 0.1 second")
        key(124, shift: true)
        near(seeks.last, 5.1, "Shift-right steps by one second")
        key(123)
        near(seeks.last, 5, "Left arrow steps backward")
        key(123, shift: true)
        near(seeks.last, 4, "Shift-left steps backward by one second")
        timeline.playhead = 7.9
        key(124, shift: true)
        near(seeks.last, 8, "Keyboard scrub clamps to retained end")
        timeline.playhead = 2.1
        key(123, shift: true)
        near(seeks.last, 2, "Keyboard scrub clamps to retained start")
        precondition(trims.isEmpty, "Keyboard scrubbing does not create edits")

        precondition(scrubPhases == Array(repeating: ["begin", "end"], count: 6).flatMap { $0 },
                     "Each keyboard seek must finish its scrub")
        _ = timeline.accessibilityPerformIncrement()
        precondition(scrubPhases.suffix(2) == ["begin", "end"], "Accessible seek finishes its scrub")

        let zoomChange = RecordingTimelineMarker(id: UUID(), time: 5,
            help: "Zoom change at 5 seconds: 2×. Click to visit and edit this view.")
        var selectedChanges: [UUID] = []
        timeline.onSelectZoomChange = { selectedChanges.append($0) }
        reset(start: 0, end: 10, playhead: 4)
        let height = timeline.intrinsicContentSize.height
        timeline.zoomChanges = [zoomChange]
        let markerPoint = CGPoint(x: timeline.x(for: 5), y: 6)
        down(markerPoint)
        up(markerPoint)
        precondition(selectedChanges == [zoomChange.id] && seeks.isEmpty && trims.isEmpty,
                     "Clicking a zoom diamond selects that change without scrubbing or trimming")
        precondition(timeline.intrinsicContentSize.height == height && height == 36,
                     "Zoom changes must not grow or rearrange the timeline")
        func purpleMarkerPixels() -> Int {
            guard let bitmap = timeline.bitmapImageRepForCachingDisplay(in: timeline.bounds) else {
                fatalError("Could not render timeline marker")
            }
            timeline.cacheDisplay(in: timeline.bounds, to: bitmap)
            let scaleX = Double(bitmap.pixelsWide) / timeline.bounds.width
            var purplePixels = 0
            for x in Int((markerPoint.x - 6) * scaleX)...Int((markerPoint.x + 6) * scaleX) {
                for y in 0..<bitmap.pixelsHigh {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > color.greenComponent + 0.1,
                       color.blueComponent > color.greenComponent + 0.2 { purplePixels += 1 }
                }
            }
            return purplePixels
        }
        precondition(purpleMarkerPixels() >= 12,
                     "Zoom changes must have a visible purple diamond matching the inspector legend")

        reset(start: 0, end: 10, playhead: 5)
        timeline.selectedZoomChangeID = zoomChange.id
        precondition(purpleMarkerPixels() >= 12,
                     "A selected zoom diamond must remain visibly purple when the playhead is at the same time")
        selectedChanges = []
        gesture(from: markerPoint, to: CGPoint(x: timeline.x(for: 6), y: 6))
        near(seeks.last, 6, "The playhead remains draggable over a zoom diamond")
        precondition(selectedChanges.isEmpty && trims.isEmpty, "A zoom marker cannot steal the playhead hit target")
        reset(start: 5, end: 10, playhead: 7)
        gesture(from: CGPoint(x: timeline.x(for: 5), y: 24), to: CGPoint(x: timeline.x(for: 6), y: 24))
        near(trims.last?.0, 6, "The lower trim handle remains draggable beneath a zoom diamond")
        precondition(selectedChanges.isEmpty && seeks.isEmpty, "Zoom markers cannot steal trim handle hits")

        window.close()
        print("Recording timeline checks passed: shared geometry, continuous scrub, trim grouping, keyboard seek, visible zoom diamonds/selection, and playhead/trim hit priority.")
    }

    static func near(_ actual: Double?, _ expected: Double, _ message: String) {
        guard let actual, abs(actual - expected) < 0.000_001 else {
            fatalError("\(message): expected \(expected), got \(String(describing: actual))")
        }
    }
}
