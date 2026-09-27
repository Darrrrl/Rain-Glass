import SwiftUI

struct SettingsView: View {
    @ObservedObject var wallpaper: WallpaperController
    @ObservedObject var rainSettings: RainSettingsStore
    @AppStorage(AppSettings.developerOverlayKey) private var developerOverlayEnabled = false
    @AppStorage(AppSettings.rainSeedKey) private var rainSeed = ""
    @State private var presetName = ""
    @State private var confirmDeletion = false

    private var selectedSavedPreset: NamedRainPreset? {
        rainSettings.presets.first { $0.selectionID == rainSettings.selectionID }
    }

    var body: some View {
        Form {
            Section("Scene") {
                Picker("Rain mode", selection: Binding(
                    get: { rainSettings.selectionID },
                    set: { rainSettings.select($0) }
                )) {
                    ForEach(BuiltInRainPreset.allCases) { preset in
                        Text(preset.title).tag(preset.id)
                    }
                    Text("Custom").tag("custom")
                    ForEach(rainSettings.presets) { preset in
                        Text(preset.name).tag(preset.selectionID)
                    }
                }
                .onChange(of: rainSettings.selectionID) { _, id in
                    presetName = rainSettings.presets.first { $0.selectionID == id }?.name ?? ""
                }
                control("Intensity", \.intensity, in: 0...1, format: "%.2f")
                control("Droplet size", \.dropletSize, in: 0.5...2, format: "%.2f×")
                control("Drop count", \.dropCount, in: 0...6_000, format: "%.0f")
                control("Gravity", \.gravity, in: 0...2, format: "%.2f×")
                control("Wind", \.wind, in: -1...1, format: "%.2f")
                control("Blur", \.blur, in: 0...8, format: "%.1f px")
                control("Refraction", \.refraction, in: 0...1, format: "%.2f")
                control("Trail persistence", \.trailPersistence, in: 0.5...15, format: "%.1f s")
            }

            Section("Saved Presets") {
                HStack {
                    TextField("Preset name", text: $presetName)
                    Button("Save As") { rainSettings.save(named: presetName) }
                    if let selectedSavedPreset {
                        Button("Rename") { rainSettings.rename(id: selectedSavedPreset.id, to: presetName) }
                        Button("Delete", role: .destructive) { confirmDeletion = true }
                    }
                }
                if let error = rainSettings.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }

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
                if wallpaper.isLoading { ProgressView("Loading image…") }
                if let error = wallpaper.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section("Developer") {
                Toggle("Show developer overlay", isOn: $developerOverlayEnabled)
                TextField("Rain seed", text: $rainSeed)
                    .help("Optional unsigned integer for repeatable rain. Leave empty for a random seed each launch.")
                if !rainSeed.isEmpty && UInt64(rainSeed) == nil {
                    Text("Enter an unsigned integer seed.").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
        .onAppear {
            presetName = selectedSavedPreset?.name ?? ""
        }
        .confirmationDialog("Delete saved preset?", isPresented: $confirmDeletion) {
            if let selectedSavedPreset {
                Button("Delete \(selectedSavedPreset.name)", role: .destructive) {
                    rainSettings.delete(id: selectedSavedPreset.id)
                    presetName = ""
                }
            }
        }
    }

    private func control(
        _ title: String,
        _ path: WritableKeyPath<RainParameters, Double>,
        in range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack {
            Text(title).frame(width: 125, alignment: .leading)
            Slider(value: Binding(
                get: { rainSettings.parameters[keyPath: path] },
                set: { rainSettings.edit(path, value: $0) }
            ), in: range)
            Text(String(format: format, rainSettings.parameters[keyPath: path]))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
    }
}
