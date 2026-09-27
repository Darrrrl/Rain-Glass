import Metal
import SwiftUI

struct ContentView: View {
    @ObservedObject var wallpaper: WallpaperController
    @ObservedObject var rainSettings: RainSettingsStore
    @AppStorage(AppSettings.developerOverlayKey) private var developerOverlayEnabled = false
    @AppStorage(AppSettings.rainSeedKey) private var rainSeed = ""
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
                        parameters: rainSettings.parameters,
                        rainSeed: rainSeed
                    )
                        .ignoresSafeArea()

                    if wallpaper.texture == nil {
                        VStack {
                            Spacer()
                            VStack(spacing: 12) {
                                Text("Choose a wallpaper")
                                    .font(.title2.weight(.semibold))
                                Text("RainGlass will use your image as the scene behind the glass.")
                                    .foregroundStyle(.secondary)
                                Button("Choose Image…") { wallpaper.chooseImage() }
                                    .buttonStyle(.borderedProminent)
                                if wallpaper.isLoading { ProgressView() }
                                if let error = wallpaper.errorMessage {
                                    Text(error)
                                        .foregroundStyle(.red)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }

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
    }
}
