import SwiftUI

@main
struct FrameThrowerApp: App {
    @StateObject private var model = CaptureViewModel()

    var body: some Scene {
        Window("FrameThrower", id: "recorder") {
            ContentView(model: model)
        }
        .defaultSize(width: 740, height: 740)
        .windowStyle(.hiddenTitleBar)

        Settings {
            AccountsSettingsView(model: model)
        }
    }
}
