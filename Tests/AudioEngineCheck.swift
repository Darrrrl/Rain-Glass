import Foundation

@main
@MainActor
struct AudioEngineCheck {
    static func main() throws {
        let suite = "dev.rainglass.audio-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AudioController(defaults: defaults)
        controller.setMaster(0.42)
        controller.setLayer(.wind, volume: 0.27)
        controller.setGlassTaps(0.2)
        controller.setMuted(true)
        let restored = AudioController(defaults: defaults)
        assert(restored.settings.master == 0.42)
        assert(restored.settings.wind == 0.27)
        assert(restored.settings.muted)
        assert(restored.settings.glassTaps == 0.2)

        guard CommandLine.arguments.count == 2,
              let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Pass the built RainGlass.app path")
        }
        let engine = AmbientAudioEngine(bundle: bundle)
        var failure: String?
        engine.errorHandler = { failure = $0 }
        var settings = AudioSettings()
        settings.muted = true
        try engine.start(settings: settings)
        engine.playGlassTap(id: 1, radius: 6, x: 0.25)
        settings.muted = false
        engine.apply(settings)
        engine.playGlassTap(id: 2, radius: 8, x: 0.75)
        settings.muted = true
        engine.apply(settings)
        RunLoop.main.run(until: Date().addingTimeInterval(23))
        assert(failure == nil, failure ?? "")
        print("Audio settings persisted; graph started and crossed an ambient loop")
    }
}
