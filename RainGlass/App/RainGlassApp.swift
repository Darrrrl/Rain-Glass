import SwiftUI

@main
struct RainGlassApp: App {
    @StateObject private var wallpaper = WallpaperController()
    @StateObject private var rainSettings = RainSettingsStore()
    @StateObject private var audio = AudioController()
    @State private var lightning: LightningCoordinator?

    var body: some Scene {
        Window("RainGlass", id: "main") {
            ContentView(wallpaper: wallpaper, rainSettings: rainSettings, audio: audio,
                        flashState: lightning?.flashState)
                .frame(minWidth: 640, minHeight: 400)
                .task { startServices() }
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView(wallpaper: wallpaper, rainSettings: rainSettings, audio: audio,
                         triggerLightning: { distance in lightning?.triggerForDebug(distanceMeters: distance) })
                .task { startServices() }
        }
    }

    @MainActor
    private func startServices() {
        audio.start()
        if lightning == nil {
            let coordinator = LightningCoordinator(rainSettings: rainSettings, audio: audio)
            coordinator.start()
            lightning = coordinator
        }
    }
}
