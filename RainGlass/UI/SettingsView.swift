import SwiftUI

struct SettingsView: View {
    @ObservedObject var wallpaper: WallpaperController
    @AppStorage(AppSettings.developerOverlayKey) private var developerOverlayEnabled = false
    @AppStorage(AppSettings.rainSeedKey) private var rainSeed = ""

    var body: some View {
        Form {
            Section("Wallpaper") {
                HStack {
                    Text(wallpaper.displayName ?? "No image selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose Image…") { wallpaper.chooseImage() }
                }
                Picker("Scale", selection: $wallpaper.scaleMode) {
                    ForEach(WallpaperScaleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                HStack {
                    Text("Background blur")
                    Slider(value: $wallpaper.blurRadius, in: 0...8)
                    Text("\(wallpaper.blurRadius, specifier: "%.1f") px")
                }
                if wallpaper.isLoading { ProgressView("Loading image…") }
                if let error = wallpaper.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            Section("Developer") {
                Toggle("Show developer overlay", isOn: $developerOverlayEnabled)
                    .help("Shows render rate, CPU frame time, and drawable size.")
                TextField("Rain seed", text: $rainSeed)
                    .help("Optional unsigned integer for repeatable rain. Leave empty for a random seed each launch.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 370)
    }
}
