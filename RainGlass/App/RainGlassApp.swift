import SwiftUI

@main
struct RainGlassApp: App {
    @StateObject private var wallpaper = WallpaperController()
    @StateObject private var rainSettings = RainSettingsStore()

    var body: some Scene {
        Window("RainGlass", id: "main") {
            ContentView(wallpaper: wallpaper, rainSettings: rainSettings)
                .frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView(wallpaper: wallpaper, rainSettings: rainSettings)
        }
    }
}
