import Combine
import Foundation

enum BuiltInRainPreset: String, CaseIterable, Identifiable {
    case drizzle
    case rain
    case heavyRain
    case storm

    var id: String { rawValue }
    var title: String {
        switch self {
        case .drizzle: "Drizzle"
        case .rain: "Rain"
        case .heavyRain: "Heavy Rain"
        case .storm: "Storm"
        }
    }
    var parameters: RainParameters {
        switch self {
        case .drizzle:
            RainParameters(intensity: 0.30, dropletSize: 0.75, dropCount: 2_800, gravity: 0.75,
                           wind: 0, blur: 1.2, refraction: 0.42, trailPersistence: 3)
        case .rain: .rain
        case .heavyRain:
            RainParameters(intensity: 0.90, dropletSize: 1.15, dropCount: 5_400, gravity: 1.2,
                           wind: 0.12, blur: 2.8, refraction: 0.78, trailPersistence: 5.5)
        case .storm:
            RainParameters(intensity: 1, dropletSize: 1.35, dropCount: 6_000, gravity: 1.55,
                           wind: 0.45, blur: 3.8, refraction: 0.9, trailPersistence: 7,
                           lightningEnabled: true, stormFrequency: 6)
        }
    }
}

struct NamedRainPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var parameters: RainParameters

    var selectionID: String { "saved:\(id.uuidString)" }
}

private struct StoredRainSettings: Codable {
    var selectionID: String
    var parameters: RainParameters
    var presets: [NamedRainPreset]
}

@MainActor
final class RainSettingsStore: ObservableObject {
    @Published private(set) var parameters: RainParameters
    @Published private(set) var selectionID: String
    @Published private(set) var presets: [NamedRainPreset]
    @Published private(set) var errorMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: AppSettings.rainSettingsKey),
           let stored = try? JSONDecoder().decode(StoredRainSettings.self, from: data) {
            parameters = stored.parameters.clamped()
            selectionID = stored.selectionID
            presets = stored.presets
        } else {
            var initial = RainParameters.rain
            if let oldBlur = defaults.object(forKey: AppSettings.wallpaperBlurRadiusKey) as? Double {
                initial.blur = oldBlur
            }
            parameters = initial.clamped()
            selectionID = initial.blur == RainParameters.rain.blur ? BuiltInRainPreset.rain.rawValue : "custom"
            presets = []
        }
        if selectionID != "custom" && BuiltInRainPreset(rawValue: selectionID) == nil &&
            !presets.contains(where: { $0.selectionID == selectionID }) {
            selectionID = "custom"
        }
        if let builtIn = BuiltInRainPreset(rawValue: selectionID) {
            parameters = builtIn.parameters
        }
    }

    private let defaults: UserDefaults

    func select(_ id: String) {
        if let builtIn = BuiltInRainPreset(rawValue: id) {
            parameters = builtIn.parameters
        } else if let saved = presets.first(where: { $0.selectionID == id }) {
            parameters = saved.parameters
        } else if id != "custom" {
            return
        }
        selectionID = id
        errorMessage = nil
        persist()
    }

    func applyPreset(_ value: RainParameters) {
        parameters = value.clamped()
        selectionID = "custom"
        errorMessage = nil
        persist()
    }

    func edit(_ keyPath: WritableKeyPath<RainParameters, Double>, value: Double) {
        parameters[keyPath: keyPath] = value
        parameters = parameters.clamped()
        selectionID = "custom"
        errorMessage = nil
        persist()
    }

    func editLightningEnabled(_ enabled: Bool) {
        parameters.lightningEnabled = enabled
        selectionID = "custom"
        errorMessage = nil
        persist()
    }

    func editSplatsEnabled(_ enabled: Bool) {
        parameters.splatsEnabled = enabled
        selectionID = "custom"
        errorMessage = nil
        persist()
    }

    func save(named rawName: String) {
        guard let name = validName(rawName) else { return }
        let preset = NamedRainPreset(id: UUID(), name: name, parameters: parameters)
        presets.append(preset)
        selectionID = preset.selectionID
        errorMessage = nil
        persist()
    }

    func rename(id: UUID, to rawName: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              let name = validName(rawName, excluding: id) else { return }
        presets[index].name = name
        errorMessage = nil
        persist()
    }

    func delete(id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = presets[index].selectionID == selectionID
        presets.remove(at: index)
        if wasSelected { selectionID = "custom" }
        errorMessage = nil
        persist()
    }

    private func validName(_ rawName: String, excluding id: UUID? = nil) -> String? {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { errorMessage = "Enter a preset name."; return nil }
        guard !presets.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            errorMessage = "A preset with that name already exists."
            return nil
        }
        return name
    }

    private func persist() {
        let snapshot = StoredRainSettings(selectionID: selectionID, parameters: parameters, presets: presets)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: AppSettings.rainSettingsKey)
    }
}
