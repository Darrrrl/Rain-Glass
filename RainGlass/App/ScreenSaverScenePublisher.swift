import AppKit
import Combine

@MainActor
final class ScreenSaverScenePublisher: ObservableObject {
    private weak var model: RainGlassModel?
    private var timer: Timer?
    private var copiedURL: URL?
    private var copiedRevision = -1
    private var copiedName: String?
    private var copyingRevision = -1
    private var copyingName: String?
    private var lastScene: ScreenSaverScene?
    private var retryAfter = Date.distantPast
    @Published private(set) var errorMessage: String?

    func start(model: RainGlassModel) {
        guard timer == nil else { return }
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishIfNeeded() }
        }
        publishIfNeeded()
    }

    func publishIfNeeded() {
        guard let model, let source = model.wallpaper.currentURL,
              model.wallpaper.texture != nil else { return }
        let revision = model.wallpaper.revision
        if copiedURL != source || copiedRevision != revision {
            guard Date() >= retryAfter else { return }
            guard copyingRevision != revision else { return }
            copyingRevision = revision
            let name = "wallpaper-\(UUID().uuidString).\(source.pathExtension.isEmpty ? "image" : source.pathExtension)"
            copyingName = name
            Task.detached(priority: .utility) { [weak self] in
                let result = Result { try ScreenSaverSceneStore.copyWallpaper(source, name: name) }
                await MainActor.run {
                    guard let self else { return }
                    if self.copyingRevision == revision { self.copyingRevision = -1 }
                    if self.copyingName == name { self.copyingName = nil }
                    guard self.model?.wallpaper.revision == revision else {
                        if case .success = result, let directory = try? ScreenSaverSceneStore.directory() {
                            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                        }
                        return
                    }
                    switch result {
                    case .success:
                        self.copiedURL = source
                        self.copiedRevision = revision
                        self.copiedName = name
                        self.errorMessage = nil
                        self.publishIfNeeded()
                    case .failure(let error):
                        self.errorMessage = "Could not share the wallpaper with the screen saver: \(error.localizedDescription)"
                        self.retryAfter = Date().addingTimeInterval(15)
                    }
                }
            }
            return
        }
        guard let copiedName else { return }
        guard let scene = makeScene(wallpaperFileName: copiedName) else { return }
        guard scene != lastScene else { return }
        do {
            let previousImage = lastScene?.wallpaperFileName
            try ScreenSaverSceneStore.write(scene)
            lastScene = scene
            errorMessage = nil
            try? ScreenSaverSceneStore.pruneWallpapers(
                keeping: Set([scene.wallpaperFileName, previousImage, copyingName].compactMap { $0 }))
        } catch {
            errorMessage = "Could not update the screen saver scene: \(error.localizedDescription)"
        }
    }

    func makeScene(wallpaperFileName: String) -> ScreenSaverScene? {
        guard let model, model.wallpaper.texture != nil else { return nil }
        let defaults = UserDefaults.standard
        func number(_ key: String, fallback: Double) -> Double {
            (defaults.object(forKey: key) as? Double) ?? fallback
        }
        let scene = ScreenSaverScene(
            version: 1, wallpaperFileName: wallpaperFileName,
            scaleMode: model.wallpaper.scaleMode.rawValue, zoom: model.wallpaper.zoom,
            rain: model.weather.effectiveParameters(base: model.rainSettings.parameters),
            atmosphere: AtmosphereSettings(
                condensation: number(AppSettings.condensationKey, fallback: 0.45),
                haze: number(AppSettings.hazeKey, fallback: 0),
                imperfections: number(AppSettings.imperfectionsKey, fallback: 0),
                fogSoftness: number(AppSettings.fogSoftnessKey, fallback: 0.65),
                fogReturnTime: number(AppSettings.fogReturnTimeKey, fallback: 18)),
            frame: WindowFrameSettings(
                layout: WindowPaneLayout(rawValue: defaults.string(forKey: AppSettings.windowPaneLayoutKey) ?? "") ?? .off,
                thickness: number(AppSettings.windowFrameThicknessKey, fallback: 12)),
            quality: defaults.string(forKey: AppSettings.renderQualityKey) ?? RenderQuality.balanced.rawValue,
            seed: defaults.string(forKey: AppSettings.rainSeedKey) ?? "")
        return scene
    }
}
