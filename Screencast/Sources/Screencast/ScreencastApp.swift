import SwiftUI

@main
struct ScreencastApp: App {
    @StateObject private var model = CaptureViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .defaultSize(width: 980, height: 380)

        Settings {
            TabView {
                AccountsSettingsView(model: model)
                    .tabItem {
                        Label("Accounts", systemImage: "person.crop.circle")
                    }
            }
        }
    }
}
