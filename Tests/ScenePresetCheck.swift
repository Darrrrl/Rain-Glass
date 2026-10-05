import Foundation

@main
@MainActor
struct ScenePresetCheck {
    static func main() throws {
        let suite = "dev.rainglass.scene-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let rain = RainSettingsStore(defaults: defaults)
        let audio = AudioController(defaults: defaults)
        let store = ScenePresetStore(defaults: defaults)
        defaults.set("ultra", forKey: AppSettings.renderQualityKey)
        defaults.set(Data([1, 2, 3]), forKey: AppSettings.wallpaperBookmarkKey)
        for scene in BuiltInScene.allCases {
            store.select(scene.id, rain: rain, audio: audio)
            assert(rain.parameters == scene.preset.rain)
            assert(audio.settings.master == scene.preset.audio.master)
            assert(defaults.string(forKey: AppSettings.renderQualityKey) == "ultra")
            assert(defaults.data(forKey: AppSettings.wallpaperBookmarkKey) == Data([1, 2, 3]))
        }
        store.save(name: "My Storm", rain: rain.parameters, atmosphere: AtmosphereSettings(),
                   audio: audio.settings, frame: WindowFrameSettings(layout: .six, thickness: 18))
        assert(store.presets.count == 1)
        assert(ScenePresetStore(defaults: defaults).selectionID == store.selectionID)
        let data = try store.exportData(for: store.presets[0])
        let otherDefaults = UserDefaults(suiteName: "\(suite).import")!
        defer { otherDefaults.removePersistentDomain(forName: "\(suite).import") }
        let imported = ScenePresetStore(defaults: otherDefaults)
        try imported.importData(data)
        assert(imported.selectionID == "custom", "Import must not change the active scene")
        assert(imported.presets.count == 1)
        assert(imported.presets[0].rain == store.presets[0].rain)
        assert(imported.presets[0].audio == store.presets[0].audio)
        assert(imported.presets[0].atmosphere == store.presets[0].atmosphere)
        assert(imported.presets[0].frame.layout == .six && imported.presets[0].frame.thickness == 18)
        assert(ScenePresetStore(defaults: otherDefaults).presets.count == 1)
        do {
            try imported.importData(data)
            assertionFailure("Duplicate name accepted")
        } catch { }
        var wrong = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        wrong["version"] = 3
        do {
            try imported.importData(JSONSerialization.data(withJSONObject: wrong))
            assertionFailure("Unsupported version accepted")
        } catch { }
        wrong["version"] = 1
        var preset = wrong["preset"] as! [String: Any]
        var sound = preset["audio"] as! [String: Any]
        sound["master"] = 4
        preset["audio"] = sound
        wrong["preset"] = preset
        do {
            try imported.importData(JSONSerialization.data(withJSONObject: wrong))
            assertionFailure("Invalid volume accepted")
        } catch { }
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var legacyPreset = legacy["preset"] as! [String: Any]
        legacyPreset.removeValue(forKey: "frame")
        var legacyAudio = legacyPreset["audio"] as! [String: Any]
        legacyAudio.removeValue(forKey: "glassTaps")
        legacyPreset["audio"] = legacyAudio
        legacyPreset["name"] = "Old Scene"
        legacy["preset"] = legacyPreset
        try imported.importData(JSONSerialization.data(withJSONObject: legacy))
        let restored = imported.presets.first { $0.name == "Old Scene" }!
        assert(restored.frame.layout == .off && restored.frame.thickness == 12)
        assert(restored.audio.glassTaps == 0.2)
        imported.select("scene:\(restored.id.uuidString)", rain: rain, audio: audio)
        assert(otherDefaults.string(forKey: AppSettings.windowPaneLayoutKey) == "off")
        let winter = BuiltInScene.quietSnow.preset
        let winterData = try store.exportData(for: winter)
        let winterFile = try JSONDecoder().decode(PresetFile.self, from: winterData)
        assert(winterFile.version == 2)
        let rainFile = try JSONDecoder().decode(PresetFile.self, from: data)
        assert(rainFile.version == 1)
        try imported.importData(winterData)
        let selectedBefore = imported.selectionID
        assert(selectedBefore == "scene:\(restored.id.uuidString)")
        let winterID = imported.presets.first { $0.name == "Quiet Snow" }!.id.uuidString
        imported.select("scene:\(winterID)", rain: rain, audio: audio)
        assert(otherDefaults.double(forKey: AppSettings.snowAmountKey) == winter.snow.amount)
        assert(otherDefaults.double(forKey: AppSettings.frostCoverageKey) == winter.frost.coverage)
        assert(rain.parameters.dropCount == 0 && !rain.parameters.lightningEnabled)
        assert(audio.settings.window == 0 && audio.settings.distant == 0)
        imported.select("lightDrizzle", rain: rain, audio: audio)
        assert(otherDefaults.double(forKey: AppSettings.snowAmountKey) == 0)
        assert(otherDefaults.double(forKey: AppSettings.frostCoverageKey) == 0)
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var oldPreset = old["preset"] as! [String: Any]
        oldPreset.removeValue(forKey: "snow"); oldPreset.removeValue(forKey: "frost")
        oldPreset["name"] = "Before Winter"; old["preset"] = oldPreset
        try imported.importData(JSONSerialization.data(withJSONObject: old))
        assert(imported.presets.last!.snow == SnowSettings())
        assert(imported.presets.last!.frost == FrostSettings())
        var badWinter = winter
        badWinter.name = "Invalid winter"
        badWinter.snow.amount = 2
        do {
            try imported.importData(store.exportData(for: badWinter))
            assertionFailure("Invalid snow accepted")
        } catch { }
        print("Scene presets round trip and invalid imports checked")
    }
}
