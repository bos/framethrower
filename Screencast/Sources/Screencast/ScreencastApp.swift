import SwiftUI

@main
struct ScreencastApp: App {
    @StateObject private var model = CaptureViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }

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
