import SwiftUI

@main
struct RainGlassApp: App {
    var body: some Scene {
        Window("RainGlass", id: "main") {
            ContentView()
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
        }
    }
}
