import AppKit
import Combine
import Foundation
import OSLog
import UniformTypeIdentifiers

struct ScenePreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var rain: RainParameters
    var atmosphere: AtmosphereSettings
    var audio: AudioSettings
    var frame: WindowFrameSettings = .init()

    private enum CodingKeys: String, CodingKey { case id, name, rain, atmosphere, audio, frame }
    init(id: UUID, name: String, rain: RainParameters, atmosphere: AtmosphereSettings,
         audio: AudioSettings, frame: WindowFrameSettings = .init()) {
        self.id = id; self.name = name; self.rain = rain; self.atmosphere = atmosphere
        self.audio = audio; self.frame = frame
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        rain = try values.decode(RainParameters.self, forKey: .rain)
        atmosphere = try values.decode(AtmosphereSettings.self, forKey: .atmosphere)
        audio = try values.decode(AudioSettings.self, forKey: .audio)
        frame = try values.decodeIfPresent(WindowFrameSettings.self, forKey: .frame) ?? .init()
    }
}

struct PresetFile: Codable {
    var version: Int
    var preset: ScenePreset
}

private enum PresetError: LocalizedError {
    case unsupportedVersion
    case invalidValues
    case duplicateName
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This preset uses an unsupported file version."
        case .invalidValues: "The preset contains missing or invalid scene or audio values."
        case .duplicateName: "A preset with this name already exists."
        }
    }
}

enum BuiltInScene: String, CaseIterable, Identifiable {
    case cozyWindow, lightDrizzle, autumnStorm, nightRain, sleep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cozyWindow: "Cozy Window"
        case .lightDrizzle: "Light Drizzle"
        case .autumnStorm: "Autumn Storm"
        case .nightRain: "Night Rain"
        case .sleep: "Sleep"
        }
    }
    var preset: ScenePreset {
        var rain = RainParameters.rain
        var audio = AudioSettings()
        var atmosphere = AtmosphereSettings()
        switch self {
        case .cozyWindow:
            rain.intensity = 0.58
            rain.dropCount = 3_200
            rain.dropletSize = 1.1
            rain.gravity = 0.85
            atmosphere.condensation = 0.58
            atmosphere.haze = 0.12
            atmosphere.fogReturnTime = 22
        case .lightDrizzle:
            rain = BuiltInRainPreset.drizzle.parameters
            atmosphere.condensation = 0.3
            audio.master = 0.25
            audio.wind = 0.05
        case .autumnStorm:
            rain = BuiltInRainPreset.storm.parameters
            rain.wind = 0.6
            atmosphere.condensation = 0.64
            atmosphere.haze = 0.25
            atmosphere.fogReturnTime = 12
            audio.master = 0.5
            audio.wind = 0.4
        case .nightRain:
            rain.intensity = 0.55
            rain.dropCount = 3_600
            atmosphere.haze = 0.35
            atmosphere.condensation = 0.48
            audio.master = 0.28
            audio.room = 0.22
        case .sleep:
            rain.intensity = 0.28
            rain.dropCount = 2_000
            rain.lightningEnabled = false
            atmosphere.haze = 0.16
            atmosphere.condensation = 0.38
            atmosphere.fogReturnTime = 24
            audio.master = 0.18
            audio.wind = 0.03
            audio.thunder = 0
        }
        return ScenePreset(id: UUID(), name: title, rain: rain, atmosphere: atmosphere, audio: audio)
    }
}

@MainActor
final class ScenePresetStore: ObservableObject {
    @Published private(set) var presets: [ScenePreset] = []
    @Published private(set) var selectionID = "custom"
    var selectedTitle: String {
        if let builtIn = BuiltInScene(rawValue: selectionID) { return builtIn.title }
        return presets.first(where: { "scene:\($0.id.uuidString)" == selectionID })?.name ?? "Custom"
    }
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "dev.rainglass.app", category: "presets")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: AppSettings.scenePresetsKey),
           let stored = try? JSONDecoder().decode([ScenePreset].self, from: data) {
            presets = stored.filter(Self.valid)
        }
        let savedSelection = defaults.string(forKey: AppSettings.sceneSelectionKey) ?? "custom"
        if BuiltInScene(rawValue: savedSelection) != nil ||
            presets.contains(where: { "scene:\($0.id.uuidString)" == savedSelection }) {
            selectionID = savedSelection
        }
    }

    func select(_ id: String, rain: RainSettingsStore, audio: AudioController) {
        let preset: ScenePreset?
        if let builtIn = BuiltInScene(rawValue: id) { preset = builtIn.preset }
        else { preset = presets.first { "scene:\($0.id.uuidString)" == id } }
        guard let preset else { return }
        rain.applyPreset(preset.rain)
        audio.applyPreset(preset.audio)
        defaults.set(preset.atmosphere.condensation, forKey: AppSettings.condensationKey)
        defaults.set(preset.atmosphere.haze, forKey: AppSettings.hazeKey)
        defaults.set(preset.atmosphere.imperfections, forKey: AppSettings.imperfectionsKey)
        defaults.set(preset.atmosphere.fogSoftness, forKey: AppSettings.fogSoftnessKey)
        defaults.set(preset.atmosphere.fogReturnTime, forKey: AppSettings.fogReturnTimeKey)
        defaults.set(preset.frame.layout.rawValue, forKey: AppSettings.windowPaneLayoutKey)
        defaults.set(preset.frame.thickness, forKey: AppSettings.windowFrameThicknessKey)
        selectionID = id
        defaults.set(id, forKey: AppSettings.sceneSelectionKey)
        errorMessage = nil
    }

    func markCustom() {
        selectionID = "custom"
        defaults.set(selectionID, forKey: AppSettings.sceneSelectionKey)
    }

    func save(name raw: String, rain: RainParameters, atmosphere: AtmosphereSettings,
              audio: AudioSettings, frame: WindowFrameSettings = .init()) {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { errorMessage = "Enter a preset name."; return }
        guard !presets.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = PresetError.duplicateName.localizedDescription; return
        }
        let preset = ScenePreset(id: UUID(), name: name, rain: rain, atmosphere: atmosphere,
                                 audio: audio, frame: frame)
        presets.append(preset)
        selectionID = "scene:\(preset.id.uuidString)"
        defaults.set(selectionID, forKey: AppSettings.sceneSelectionKey)
        persist()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if selectionID == "scene:\(id.uuidString)" { markCustom() }
        persist()
    }

    func export(_ id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportData(for: preset).write(to: url, options: .atomic)
            errorMessage = nil
        } catch {
            log.error("Preset export failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Could not export the preset: \(error.localizedDescription)"
        }
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try importData(data)
        } catch {
            log.error("Preset import failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Could not import preset: \(error.localizedDescription)"
        }
    }

    func exportData(for preset: ScenePreset) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PresetFile(version: 1, preset: preset))
    }

    func importData(_ data: Data) throws {
        let file: PresetFile
        do { file = try JSONDecoder().decode(PresetFile.self, from: data) }
        catch { throw PresetError.invalidValues }
        guard file.version == 1 else { throw PresetError.unsupportedVersion }
        guard Self.valid(file.preset) else { throw PresetError.invalidValues }
        guard !presets.contains(where: { $0.name.localizedCaseInsensitiveCompare(file.preset.name) == .orderedSame }) else {
            throw PresetError.duplicateName
        }
        var preset = file.preset
        preset.id = UUID()
        presets.append(preset)
        selectionID = "scene:\(preset.id.uuidString)"
        defaults.set(selectionID, forKey: AppSettings.sceneSelectionKey)
        persist()
    }

    private static func valid(_ preset: ScenePreset) -> Bool {
        let rain = preset.rain
        let audio = preset.audio
        let atmosphere = preset.atmosphere
        let values = [rain.intensity, rain.dropletSize, rain.dropCount, rain.gravity, rain.wind,
                      rain.blur, rain.refraction, rain.trailPersistence, rain.stormFrequency,
                      audio.master, audio.window, audio.distant, audio.wind, audio.room, audio.thunder,
                      audio.glassTaps,
                      atmosphere.condensation, atmosphere.haze, atmosphere.imperfections,
                      atmosphere.fogSoftness, atmosphere.fogReturnTime, preset.frame.thickness]
        return !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && preset.name.count <= 40 &&
            values.allSatisfy(\.isFinite) && rain == rain.clamped() && audio == audio.clamped() &&
            (0...1).contains(atmosphere.condensation) && (0...1).contains(atmosphere.haze) &&
            (0...1).contains(atmosphere.imperfections) && (0...1).contains(atmosphere.fogSoftness) &&
            (8...35).contains(atmosphere.fogReturnTime) && (6...24).contains(preset.frame.thickness)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: AppSettings.scenePresetsKey) }
        errorMessage = nil
    }
}
