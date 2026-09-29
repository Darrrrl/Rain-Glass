import Foundation

@main
@MainActor
struct WallpaperSetupCheck {
    static func main() {
        let name = "dev.rainglass.setup-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let newInstall = WallpaperController(defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assert(newInstall.initialRestoreComplete)
        assert(newInstall.texture == nil)

        defaults.set(Data([1, 2, 3]), forKey: AppSettings.wallpaperBookmarkKey)
        let brokenBookmark = WallpaperController(defaults: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assert(brokenBookmark.initialRestoreComplete)
        assert(brokenBookmark.texture == nil)
        assert(brokenBookmark.errorMessage != nil)
        print("Missing and invalid saved wallpaper restoration checked")
    }
}
