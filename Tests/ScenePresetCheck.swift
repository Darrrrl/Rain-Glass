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
        wrong["version"] = 2
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
        print("Scene presets round trip and invalid imports checked")
    }
}
