import AppKit
import SwiftUI

private struct WorkspaceProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Exercises the production two-column layout without constructing a capture
/// model, discovering devices, requesting permissions, or capturing any pixels.
@main
@MainActor
struct RecorderWorkspaceChecks {
    enum Failure: Error { case failed(String) }

    static func main() async throws {
        _ = NSApplication.shared
        for size in [CGSize(width: 1000, height: 780), CGSize(width: 1100, height: 820)] {
            var baseline: [String: CGRect]?
            for count in [0, 1, 40] {
                let host = NSHostingView(rootView: content(count: count).frame(width: size.width, height: size.height))
                let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
                var frames: [String: CGRect] = [:]
                for name in ["capture", "preview", "record", "history"] {
                    guard let view = find(name, in: host) else { throw Failure.failed("Missing \(name) probe") }
                    frames[name] = host.convert(view.bounds, from: view)
                }
                let capture = frames["capture"]!, preview = frames["preview"]!
                let record = frames["record"]!, history = frames["history"]!
                try require(capture.width >= 640 && preview.height >= 300,
                            "Saved recordings squeezed the capture preview at \(size), count=\(count): \(frames)")
                try require(record.maxX <= host.bounds.maxX && capture.maxX < record.minX,
                            "Recording action must stay in its sidebar without overflowing")
                let recordAboveHistory = host.isFlipped
                    ? record.maxY + 15 <= history.minY : record.minY >= history.maxY + 15
                try require(recordAboveHistory,
                            "Record must remain above the recordings list")
                if let baseline {
                    for name in ["capture", "preview", "record", "history"] {
                        try same(frames[name]!, baseline[name]!, "History count changed \(name) geometry at \(size)")
                    }
                } else { baseline = frames }
                window.close()
            }
        }
        print("Recorder workspace checks passed (minimum/default sizes, 0/1/40 recordings, stable preview >=300pt, Record above history, and no capture/device activity).")
    }

    private static func content(count: Int) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 62)
            RecorderWorkspace {
                VStack(spacing: 12) {
                    Color.clear.frame(height: 44)
                    WorkspaceProbe(name: "preview").frame(minHeight: 300, maxHeight: .infinity)
                    Color.clear.frame(height: 100)
                }
                .padding(18)
                .background(WorkspaceProbe(name: "capture"))
            } recordingControls: {
                WorkspaceProbe(name: "record").frame(height: 52)
            } recordings: {
                ScrollView {
                    LazyVStack {
                        ForEach(0..<count, id: \.self) { _ in Color.clear.frame(height: 72) }
                    }
                }
                .background(WorkspaceProbe(name: "history"))
            }
            .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 16)
            Color.clear.frame(height: 40)
        }
    }

    private static func find(_ name: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == name { return view }
        for child in view.subviews {
            if let match = find(name, in: child) { return match }
        }
        return nil
    }

    private static func same(_ value: CGRect, _ expected: CGRect, _ message: String) throws {
        try require(abs(value.minX - expected.minX) < 0.5 && abs(value.minY - expected.minY) < 0.5
                    && abs(value.width - expected.width) < 0.5 && abs(value.height - expected.height) < 0.5, message)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.failed(message) }
    }
}
