import Foundation

@main
@MainActor
struct RainSettingsCheck {
    static func main() {
        let suite = "dev.rainglass.settings-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3.5, forKey: AppSettings.wallpaperBlurRadiusKey)

        let first = RainSettingsStore(defaults: defaults)
        assert(first.parameters.blur == 3.5)
        first.select(BuiltInRainPreset.drizzle.id)
        assert(first.parameters == BuiltInRainPreset.drizzle.parameters)
        first.edit(\.wind, value: -0.4)
        assert(first.selectionID == "custom")
        first.save(named: "Window Seat")
        assert(first.presets.count == 1)

        let savedID = first.presets[0].id
        let second = RainSettingsStore(defaults: defaults)
        assert(second.selectionID == first.selectionID)
        assert(second.parameters.wind == -0.4)
        second.rename(id: savedID, to: "Evening Window")
        assert(second.presets[0].name == "Evening Window")
        second.delete(id: savedID)
        assert(second.presets.isEmpty)
        assert(second.selectionID == "custom")
        second.edit(\.dropCount, value: 100_000)
        assert(second.parameters.dropCount == 6_000)
        second.select(BuiltInRainPreset.storm.id)
        assert(second.parameters.lightningEnabled)
        assert(second.parameters.stormFrequency == 6)
        second.editLightningEnabled(false)
        assert(second.selectionID == "custom")

        var legacy = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(RainParameters.rain)) as! [String: Any]
        legacy.removeValue(forKey: "lightningEnabled")
        legacy.removeValue(forKey: "stormFrequency")
        let migrated = try! JSONDecoder().decode(RainParameters.self, from: JSONSerialization.data(withJSONObject: legacy))
        assert(!migrated.lightningEnabled && migrated.stormFrequency == 0)
        var legacyStorm = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(BuiltInRainPreset.storm.parameters)) as! [String: Any]
        legacyStorm.removeValue(forKey: "lightningEnabled")
        legacyStorm.removeValue(forKey: "stormFrequency")
        let snapshot: [String: Any] = ["selectionID": "storm", "parameters": legacyStorm, "presets": []]
        defaults.set(try! JSONSerialization.data(withJSONObject: snapshot), forKey: AppSettings.rainSettingsKey)
        let restoredStorm = RainSettingsStore(defaults: defaults)
        assert(restoredStorm.parameters.lightningEnabled && restoredStorm.parameters.stormFrequency == 6)
        print("Rain settings migrated, saved, renamed, and deleted")
    }
}
