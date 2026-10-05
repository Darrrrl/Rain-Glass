import Foundation

// The screen saver runs in a different process. Keep its input independent of app defaults.
struct ScreenSaverScene: Codable, Equatable {
    let version: Int
    let wallpaperFileName: String
    let scaleMode: String
    let zoom: Double
    let rain: RainParameters
    let atmosphere: AtmosphereSettings
    let frame: WindowFrameSettings
    let quality: String
    let seed: String
    var snow: SnowSettings = .init()
    var frost: FrostSettings = .init()

    var isSupported: Bool { (1...2).contains(version) && snow.isValid && frost.isValid }

    private enum CodingKeys: String, CodingKey {
        case version, wallpaperFileName, scaleMode, zoom, rain, atmosphere, frame, quality, seed, snow, frost
    }

    init(version: Int, wallpaperFileName: String, scaleMode: String, zoom: Double,
         rain: RainParameters, atmosphere: AtmosphereSettings, frame: WindowFrameSettings,
         quality: String, seed: String, snow: SnowSettings = .init(), frost: FrostSettings = .init()) {
        self.version = version; self.wallpaperFileName = wallpaperFileName
        self.scaleMode = scaleMode; self.zoom = zoom; self.rain = rain; self.atmosphere = atmosphere
        self.frame = frame; self.quality = quality; self.seed = seed; self.snow = snow; self.frost = frost
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        wallpaperFileName = try values.decode(String.self, forKey: .wallpaperFileName)
        scaleMode = try values.decode(String.self, forKey: .scaleMode)
        zoom = try values.decode(Double.self, forKey: .zoom)
        rain = try values.decode(RainParameters.self, forKey: .rain)
        atmosphere = try values.decode(AtmosphereSettings.self, forKey: .atmosphere)
        frame = try values.decode(WindowFrameSettings.self, forKey: .frame)
        quality = try values.decode(String.self, forKey: .quality)
        seed = try values.decode(String.self, forKey: .seed)
        snow = try values.decodeIfPresent(SnowSettings.self, forKey: .snow) ?? .init()
        frost = try values.decodeIfPresent(FrostSettings.self, forKey: .frost) ?? .init()
    }
}

enum ScreenSaverSceneStore {
    static let groupID = "group.dev.rainglass.app"
    static let snapshotName = "scene.json"

    static func directory() throws -> URL {
        if ProcessInfo.processInfo.processName == "ScreenSaverTransferCheck",
           let testPath = ProcessInfo.processInfo.environment["RAINGLASS_SAVER_TEST_DIRECTORY"] {
            return URL(fileURLWithPath: testPath, isDirectory: true)
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RainGlass/ScreenSaver", isDirectory: true)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            let directory = group.appendingPathComponent("ScreenSaver", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
               FileManager.default.isWritableFile(atPath: directory.path) {
                return directory
            }
        }
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func read() throws -> (scene: ScreenSaverScene, imageURL: URL) {
        try read(in: directory())
    }

    static func read(in directory: URL) throws -> (scene: ScreenSaverScene, imageURL: URL) {
        let data = try Data(contentsOf: directory.appendingPathComponent(snapshotName))
        let scene = try JSONDecoder().decode(ScreenSaverScene.self, from: data)
        guard scene.isSupported,
              (scene.wallpaperFileName as NSString).lastPathComponent == scene.wallpaperFileName else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let imageURL = directory.appendingPathComponent(scene.wallpaperFileName)
        guard FileManager.default.isReadableFile(atPath: imageURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return (scene, imageURL)
    }

    static func write(_ scene: ScreenSaverScene) throws {
        try write(scene, in: directory())
    }

    static func write(_ scene: ScreenSaverScene, in directory: URL) throws {
        let data = try JSONEncoder().encode(scene)
        try data.write(to: directory.appendingPathComponent(snapshotName), options: .atomic)
    }

    static func copyWallpaper(_ source: URL, name: String) throws {
        try copyWallpaper(source, name: name, into: directory())
    }

    static func copyWallpaper(_ source: URL, name: String, into directory: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let destination = directory.appendingPathComponent(name)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func pruneWallpapers(keeping names: Set<String>) throws {
        let directory = try directory()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix("wallpaper-") && !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

enum ScreenSaverLifecycle {
    static let active = Notification.Name("dev.rainglass.screensaver.active")
    static let stopped = Notification.Name("dev.rainglass.screensaver.stopped")
    static let sceneRequest = Notification.Name("dev.rainglass.screensaver.scene-request")
    static let sceneResponse = Notification.Name("dev.rainglass.screensaver.scene-response")
    static let chunkRequest = Notification.Name("dev.rainglass.screensaver.chunk-request")
    static let chunkResponse = Notification.Name("dev.rainglass.screensaver.chunk-response")
}
