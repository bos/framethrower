import AppKit
import SwiftUI

/// The real command groups in a Window scene, without document placeholders.
/// Only this fixture's offscreen window/menu exists; no project or media opens.
@main
struct EditorFileMenuChecks: App {
    @NSApplicationDelegateAdaptor(FileMenuProbe.self) private var probe

    var body: some Scene {
        Window("File menu fixture", id: "fixture") {
            Color.clear.frame(width: 40, height: 40)
                .task { await probe.check() }
        }
        .commands {
            CommandGroup(after: .newItem) { Button("Open fixture") {} }
            EditorFileCommands()
        }
    }
}

@MainActor
final class FileMenuProbe: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func check() async {
        guard MediaProcessing.isSuspended else { fail("Requires suspended media") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            FileHandle.standardError.write(Data("File menu check timed out\n".utf8))
            Darwin.exit(1)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var lastTitles: [String] = []
        while ContinuousClock.now < deadline {
            NSApp.windows.forEach { $0.setFrameOrigin(CGPoint(x: -10000, y: -10000)) }
            if let menu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu {
                menu.update()
                lastTitles = menu.items.map(\.title)
                let expected = ["Save Recording", "Duplicate Recording", "Save Video…", "Share Video…", "Rename Recording…"]
                if expected.allSatisfy(lastTitles.contains), let duplicate = menu.items.first(where: { $0.title == "Duplicate Recording" }) {
                    guard duplicate.keyEquivalent == "s",
                          duplicate.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == [.command, .shift] else {
                        fail("Duplicate Recording must use Shift-Command-S")
                    }
                    let positions = expected.compactMap { lastTitles.firstIndex(of: $0) }
                    guard positions == positions.sorted() else { fail("File commands are out of order: \(lastTitles)") }
                    FileHandle.standardOutput.write(Data("Editor File menu checks passed (actual Window-scene NSMenu, Save/Duplicate/export/rename presence and order, standard Duplicate shortcut; no project, media or user-app interaction).\n".utf8))
                    NSApp.terminate(nil)
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        fail("File commands missing from Window scene: \(lastTitles)")
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Darwin.exit(1)
    }
}
