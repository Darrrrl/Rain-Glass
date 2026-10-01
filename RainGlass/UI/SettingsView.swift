import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case scene, wallpaper, sound, app
    var id: String { rawValue }
}

@MainActor
final class SettingsPresentation: ObservableObject {
    @Published var section: SettingsSection = .scene
}

struct SettingsView: View {
    @ObservedObject var presentation: SettingsPresentation
    @ObservedObject var wallpaper: WallpaperController
    @ObservedObject var rainSettings: RainSettingsStore
    @ObservedObject var scenePresets: ScenePresetStore
    @ObservedObject var audio: AudioController
    @ObservedObject var weather: WeatherController
    @ObservedObject var desktop: DesktopWindowManager
    let triggerLightning: (Double) -> Void
    @StateObject private var login = LoginItemController()
    @AppStorage(AppSettings.renderQualityKey) private var qualityRaw = RenderQuality.balanced.rawValue
    @AppStorage(AppSettings.condensationKey) private var condensation = 0.45
    @AppStorage(AppSettings.hazeKey) private var haze = 0.0
    @AppStorage(AppSettings.imperfectionsKey) private var imperfections = 0.0
    @AppStorage(AppSettings.fogSoftnessKey) private var fogSoftness = 0.65
    @AppStorage(AppSettings.fogReturnTimeKey) private var fogReturnTime = 18.0
    @AppStorage(AppSettings.windowPaneLayoutKey) private var frameLayoutRaw = WindowPaneLayout.off.rawValue
    @AppStorage(AppSettings.windowFrameThicknessKey) private var frameThickness = 12.0
    @AppStorage(AppSettings.developerOverlayKey) private var developerOverlayEnabled = false
    @AppStorage(AppSettings.rainSeedKey) private var rainSeed = ""
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var cityQuery = ""
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Controls").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 18)
            HStack(spacing: 4) {
                sectionButton(.scene, title: "Scene", symbol: "cloud.rain")
                sectionButton(.wallpaper, title: "Image", symbol: "photo")
                sectionButton(.sound, title: "Sound", symbol: "speaker.wave.2")
                sectionButton(.app, title: "App", symbol: "gearshape")
            }
            .padding(4)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 14)
            Group {
                switch presentation.section {
                case .scene: sceneTab
                case .wallpaper: wallpaperTab
                case .sound: audioTab
                case .app: appTab
                }
            }
        }
        .frame(width: 400)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(reduceTransparency ? AnyShapeStyle(Color.black.opacity(0.96)) :
                        AnyShapeStyle(.ultraThinMaterial))
                .overlay { RoundedRectangle(cornerRadius: 20).fill(.black.opacity(reduceTransparency ? 0 : 0.5)) }
        }
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.16)) }
        .shadow(color: .black.opacity(0.35), radius: 24, x: -6, y: 10)
        .preferredColorScheme(.dark)
    }

    private func sectionButton(_ section: SettingsSection, title: String, symbol: String) -> some View {
        Button { presentation.section = section } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(presentation.section == section ? Color.white.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(presentation.section == section ? .isSelected : [])
    }

    private var wallpaperTab: some View {
        Form {
            Section("Image") {
                HStack {
                    Text(wallpaper.displayName ?? "No image selected").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose Image…") { wallpaper.chooseImage() }
                }
                Picker("Scale", selection: $wallpaper.scaleMode) {
                    ForEach(WallpaperScaleMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                HStack {
                    Text("Zoom").frame(width: 125, alignment: .leading)
                    Slider(value: $wallpaper.zoom, in: 1...3)
                    Text(String(format: "%.2f×", wallpaper.zoom))
                        .monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                control("Background blur", \.blur, in: 0...64, format: "%.0f px")
                if wallpaper.isLoading { ProgressView("Loading image…") }
                if let error = wallpaper.errorMessage { Text(error).foregroundStyle(.red) }
            }
        }.formStyle(.grouped)
    }

    private var sceneTab: some View {
        Form {
            Section("Presets") {
                Picker("Scene", selection: Binding(
                    get: { scenePresets.selectionID },
                    set: { scenePresets.select($0, rain: rainSettings, audio: audio) }
                )) {
                    Text("Custom").tag("custom")
                    ForEach(BuiltInScene.allCases) { preset in Text(preset.title).tag(preset.id) }
                    ForEach(scenePresets.presets) { preset in
                        Text(preset.name).tag("scene:\(preset.id.uuidString)")
                    }
                }
                if !rainSettings.presets.isEmpty {
                    Picker("Legacy rain preset", selection: Binding(
                        get: { rainSettings.selectionID },
                        set: { rainSettings.select($0); scenePresets.markCustom() }
                    )) {
                        Text("Custom").tag("custom")
                        ForEach(BuiltInRainPreset.allCases) { preset in Text(preset.title).tag(preset.id) }
                        ForEach(rainSettings.presets) { preset in Text(preset.name).tag(preset.selectionID) }
                    }
                    Text("Legacy presets change rain only.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("New preset name", text: $presetName)
                    Button("Save Current") {
                        scenePresets.save(name: presetName, rain: rainSettings.parameters,
                                          atmosphere: AtmosphereSettings(condensation: condensation, haze: haze,
                                                                         imperfections: imperfections,
                                                                         fogSoftness: fogSoftness,
                                                                         fogReturnTime: fogReturnTime), audio: audio.settings,
                                          frame: WindowFrameSettings(
                                            layout: WindowPaneLayout(rawValue: frameLayoutRaw) ?? .off,
                                            thickness: frameThickness))
                    }
                }
                HStack {
                    Button("Import JSON…") { scenePresets.importFile() }
                    if let selected = scenePresets.presets.first(where: { "scene:\($0.id.uuidString)" == scenePresets.selectionID }) {
                        Button("Export JSON…") { scenePresets.export(selected.id) }
                        Button("Delete Preset", role: .destructive) { scenePresets.delete(selected.id) }
                    }
                }
                if let error = scenePresets.errorMessage { Text(error).foregroundStyle(.red) }
            }
            Section("Rain") {
                control("Intensity", \.intensity, in: 0...1, format: "%.2f")
                control("Droplet size", \.dropletSize, in: 0.5...2, format: "%.2f×")
                DisclosureGroup("Detailed rain controls") {
                    control("Drop count", \.dropCount, in: 0...6_000, format: "%.0f")
                    control("Gravity", \.gravity, in: 0...2, format: "%.2f×")
                    control("Wind", \.wind, in: -1...1, format: "%.2f")
                    control("Refraction", \.refraction, in: 0...1, format: "%.2f")
                    control("Trail persistence", \.trailPersistence, in: 0.5...15, format: "%.1f s")
                }
            }
            Section("Lightning") {
                Toggle("Enable lightning", isOn: Binding(
                    get: { rainSettings.parameters.lightningEnabled },
                    set: { rainSettings.editLightningEnabled($0); scenePresets.markCustom() }
                ))
                control("Storm frequency", \.stormFrequency, in: 0...30, format: "%.0f / hour")
            }
            Section("Glass atmosphere") {
                atmosphereControl("Condensation", value: $condensation)
                atmosphereControl("Fog softness", value: $fogSoftness)
                HStack {
                    Text("Fog return").frame(width: 125, alignment: .leading)
                    Slider(value: Binding(get: { fogReturnTime },
                                          set: { fogReturnTime = $0; scenePresets.markCustom() }), in: 8...35)
                    Text(String(format: "%.0f s", fogReturnTime))
                        .monospacedDigit().frame(width: 70, alignment: .trailing)
                }
                atmosphereControl("Haze", value: $haze)
                atmosphereControl("Imperfections", value: $imperfections)
            }
            Section("Window frame") {
                Picker("Panes", selection: Binding(get: { frameLayoutRaw }, set: {
                    frameLayoutRaw = $0; scenePresets.markCustom()
                })) {
                    ForEach(WindowPaneLayout.allCases) { layout in Text(layout.title).tag(layout.rawValue) }
                }
                HStack {
                    Text("Thickness").frame(width: 125, alignment: .leading)
                    Slider(value: Binding(get: { frameThickness }, set: {
                        frameThickness = $0; scenePresets.markCustom()
                    }), in: 6...24)
                    Text(String(format: "%.0f pt", frameThickness)).frame(width: 70)
                }
            }
            Section("Live weather") {
                DisclosureGroup("Weather options") {
                    Toggle("Use live weather", isOn: Binding(get: { weather.enabled }, set: { weather.setEnabled($0) }))
                    HStack {
                        TextField("City or postal code", text: $cityQuery)
                            .onChange(of: cityQuery) { _, query in
                                if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                                    weather.clearSearch()
                                }
                            }
                        Button("Search") { Task { await weather.search(cityQuery) } }
                    }
                    if weather.isSearching { ProgressView() }
                    ForEach(weather.searchResults) { city in Button(city.title) { weather.select(city) } }
                    if let city = weather.city { Text(city.title) }
                    if let conditions = weather.conditions {
                        Text(String(format: "Rain %.1f mm/h · Wind %.0f km/h · Clouds %.0f%%%@",
                                    conditions.precipitation, conditions.windSpeed, conditions.cloudCover,
                                    weather.isStale ? " · Cached" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = weather.errorMessage { Text(error).foregroundStyle(.red) }
                    Text("Weather data by Open-Meteo").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            Section("Mix") {
                Toggle("Mute", isOn: Binding(get: { audio.settings.muted }, set: { audio.setMuted($0) }))
                audioControl("Master volume", value: audio.settings.master, set: audio.setMaster)
                ForEach(AmbientLayer.allCases) { layer in
                    audioControl(layer.title, value: audio.settings.volume(for: layer)) {
                        audio.setLayer(layer, volume: $0)
                    }
                }
                audioControl("Thunder", value: audio.settings.thunder, set: audio.setThunder)
                audioControl("Glass taps", value: audio.settings.glassTaps, set: audio.setGlassTaps)
                if let error = audio.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Retry Audio") { audio.retry() }
                }
            }
        }.formStyle(.grouped)
    }

    private var appTab: some View {
        Form {
            Section("Desktop") {
                Text("RainGlass runs behind your desktop icons on each display.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = desktop.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Retry Desktop") { desktop.retry() }
                }
            }
            Section("Performance") {
                Picker("Quality", selection: $qualityRaw) {
                    ForEach(RenderQuality.allCases) { quality in Text(quality.title).tag(quality.rawValue) }
                }
                Toggle("Pause visuals", isOn: $desktop.paused)
            }
            Section("Startup") {
                Toggle("Start at Login", isOn: Binding(
                    get: { login.status == .enabled }, set: { login.setEnabled($0) }
                ))
                if login.status == .requiresApproval {
                    Button("Open Login Items Settings") { login.openSystemSettings() }
                }
                if let error = login.errorMessage { Text(error).foregroundStyle(.red) }
            }
            Section("Developer") {
                DisclosureGroup("Diagnostics") {
                    Toggle("Frame timing overlay", isOn: $developerOverlayEnabled)
                    TextField("Rain seed", text: $rainSeed)
                    Button("Test lightning") { triggerLightning(1_000) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
    }

    private func control(_ title: String, _ path: WritableKeyPath<RainParameters, Double>,
                         in range: ClosedRange<Double>, format: String) -> some View {
        HStack {
            Text(title).frame(width: 125, alignment: .leading)
            Slider(value: Binding(get: { rainSettings.parameters[keyPath: path] },
                                  set: { rainSettings.edit(path, value: $0); scenePresets.markCustom() }), in: range)
            Text(String(format: format, rainSettings.parameters[keyPath: path]))
                .monospacedDigit().frame(width: 70, alignment: .trailing)
        }
    }

    private func audioControl(_ title: String, value: Double,
                              set: @escaping @MainActor @Sendable (Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 125, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set($0); scenePresets.markCustom() }), in: 0...1)
            Text(String(format: "%.0f%%", value * 100)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
    }

    private func atmosphereControl(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 125, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = $0; scenePresets.markCustom() }), in: 0...1)
            Text(String(format: "%.0f%%", value.wrappedValue * 100))
                .monospacedDigit().frame(width: 70, alignment: .trailing)
        }
    }
}
