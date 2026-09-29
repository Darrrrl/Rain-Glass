import Foundation

@main
@MainActor
struct DesktopModeCheck {
    static func main() {
        let name = "dev.rainglass.desktop-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("window", forKey: AppSettings.presentationModeKey)
        let manager = DesktopWindowManager(defaults: defaults)
        assert(defaults.string(forKey: AppSettings.presentationModeKey) == "desktop")
        manager.paused = true
        assert(defaults.bool(forKey: AppSettings.pausedKey))
        print("Legacy window mode migrates to desktop; pause persists")
    }
}
