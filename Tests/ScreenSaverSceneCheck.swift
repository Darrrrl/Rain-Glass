import Foundation

@main
struct ScreenSaverSceneCheck {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RainGlassSaverCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("wallpaper.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: image)
        let scene = ScreenSaverScene(version: 1, wallpaperFileName: image.lastPathComponent,
                                     scaleMode: "fill", zoom: 1.5, rain: .rain,
                                     atmosphere: .init(), frame: .init(), quality: "balanced", seed: "42")
        try ScreenSaverSceneStore.write(scene, in: directory)
        let restored = try ScreenSaverSceneStore.read(in: directory)
        assert(restored.scene == scene)
        assert(restored.imageURL == image)

        let winter = ScreenSaverScene(version: 2, wallpaperFileName: image.lastPathComponent,
            scaleMode: "fill", zoom: 1, rain: .rain, atmosphere: .init(), frame: .init(),
            quality: "eco", seed: "42", snow: SnowSettings(amount: 0.4), frost: FrostSettings(coverage: 0.5))
        try ScreenSaverSceneStore.write(winter, in: directory)
        let winterRestored = try ScreenSaverSceneStore.read(in: directory)
        assert(winterRestored.scene == winter && winterRestored.scene.isSupported)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene)) as! [String: Any]
        old.removeValue(forKey: "snow"); old.removeValue(forKey: "frost")
        let legacy = try JSONDecoder().decode(ScreenSaverScene.self, from: JSONSerialization.data(withJSONObject: old))
        assert(legacy.snow == SnowSettings() && legacy.frost == FrostSettings())
        old["version"] = 3
        let future = try JSONDecoder().decode(ScreenSaverScene.self, from: JSONSerialization.data(withJSONObject: old))
        assert(!future.isSupported)
        try ScreenSaverSceneStore.write(future, in: directory)
        assert((try? ScreenSaverSceneStore.read(in: directory)) == nil)

        let invalid = ScreenSaverScene(version: 1, wallpaperFileName: "../outside.jpg",
                                      scaleMode: "fill", zoom: 1, rain: .rain,
                                      atmosphere: .init(), frame: .init(), quality: "balanced", seed: "")
        try ScreenSaverSceneStore.write(invalid, in: directory)
        assert((try? ScreenSaverSceneStore.read(in: directory)) == nil)
        print("Screen saver scene sharing, decoding, and image path validation checked")
    }
}
