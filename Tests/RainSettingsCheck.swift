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
        print("Rain settings migrated, saved, renamed, and deleted")
    }
}
