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

        let invalid = ScreenSaverScene(version: 1, wallpaperFileName: "../outside.jpg",
                                      scaleMode: "fill", zoom: 1, rain: .rain,
                                      atmosphere: .init(), frame: .init(), quality: "balanced", seed: "")
        try ScreenSaverSceneStore.write(invalid, in: directory)
        assert((try? ScreenSaverSceneStore.read(in: directory)) == nil)
        print("Screen saver scene sharing, decoding, and image path validation checked")
    }
}
