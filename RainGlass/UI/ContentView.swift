import Metal
import SwiftUI

struct ContentView: View {
    @ObservedObject var wallpaper: WallpaperController
    @ObservedObject var rainSettings: RainSettingsStore
    @ObservedObject var audio: AudioController
    @ObservedObject var weather: WeatherController
    let flashState: LightningFlashState?
    let paused: Bool
    let onRendererError: (String) -> Void
    @AppStorage(AppSettings.developerOverlayKey) private var developerOverlayEnabled = false
    @AppStorage(AppSettings.rainSeedKey) private var rainSeed = ""
    @AppStorage(AppSettings.renderQualityKey) private var qualityRaw = RenderQuality.balanced.rawValue
    @AppStorage(AppSettings.condensationKey) private var condensation = 0.45
    @AppStorage(AppSettings.hazeKey) private var haze = 0.0
    @AppStorage(AppSettings.imperfectionsKey) private var imperfections = 0.0
    @AppStorage(AppSettings.fogSoftnessKey) private var fogSoftness = 0.65
    @AppStorage(AppSettings.fogReturnTimeKey) private var fogReturnTime = 18.0
    @AppStorage(AppSettings.windowPaneLayoutKey) private var frameLayoutRaw = WindowPaneLayout.off.rawValue
    @AppStorage(AppSettings.windowFrameThicknessKey) private var frameThickness = 12.0
    @StateObject private var diagnostics = RenderDiagnostics()

    var body: some View {
        Group {
            if let device = wallpaper.device {
                ZStack(alignment: .topLeading) {
                    MetalView(
                        device: device,
                        diagnostics: diagnostics,
                        diagnosticsEnabled: developerOverlayEnabled,
                        wallpaperTexture: wallpaper.texture,
                        wallpaperRevision: wallpaper.revision,
                        scaleMode: wallpaper.scaleMode,
                        zoom: wallpaper.zoom,
                        parameters: weather.effectiveParameters(base: rainSettings.parameters),
                        flashState: flashState,
                        rainSeed: rainSeed,
                        quality: RenderQuality(rawValue: qualityRaw) ?? .balanced,
                        atmosphere: AtmosphereSettings(condensation: condensation, haze: haze,
                                                       imperfections: imperfections, fogSoftness: fogSoftness,
                                                       fogReturnTime: fogReturnTime),
                        manuallyPaused: paused,
                        onArrivals: { arrivals, sourceID in
                            audio.playArrivals(arrivals, sourceID: sourceID)
                        }
                    )
                        .ignoresSafeArea()

                    WindowFrameView(layout: WindowPaneLayout(rawValue: frameLayoutRaw) ?? .off,
                                    thickness: frameThickness)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()

                    if developerOverlayEnabled {
                        DeveloperOverlay(snapshot: diagnostics.snapshot)
                            .padding(16)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Metal is unavailable",
                    systemImage: "display.trianglebadge.exclamationmark",
                    description: Text("RainGlass needs a Mac with Metal support.")
                )
            }
        }
        .onChange(of: diagnostics.errorMessage) { _, message in
            if let message { onRendererError(message) }
        }
    }
}
