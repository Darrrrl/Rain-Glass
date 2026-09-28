import Combine
import Foundation

enum AmbientLayer: String, CaseIterable, Identifiable {
    case window
    case distant
    case wind
    case room

    var id: String { rawValue }
    var title: String {
        switch self {
        case .window: "Window rain"
        case .distant: "Distant rainfall"
        case .wind: "Wind"
        case .room: "Room ambience"
        }
    }
}

struct AudioSettings: Codable, Equatable {
    var master: Double = 0.35
    var muted = false
    var window: Double = 0.65
    var distant: Double = 0.45
    var wind: Double = 0.16
    var room: Double = 0.08
    var thunder: Double = 0.65

    func volume(for layer: AmbientLayer) -> Double {
        switch layer {
        case .window: window
        case .distant: distant
        case .wind: wind
        case .room: room
        }
    }

    mutating func setVolume(_ value: Double, for layer: AmbientLayer) {
        switch layer {
        case .window: window = value
        case .distant: distant = value
        case .wind: wind = value
        case .room: room = value
        }
    }

    func clamped() -> AudioSettings {
        var copy = self
        copy.master = min(max(master, 0), 1)
        copy.window = min(max(window, 0), 1)
        copy.distant = min(max(distant, 0), 1)
        copy.wind = min(max(wind, 0), 1)
        copy.room = min(max(room, 0), 1)
        copy.thunder = min(max(thunder, 0), 1)
        return copy
    }
}

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var settings: AudioSettings
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let engine = AmbientAudioEngine()
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: AppSettings.audioSettingsKey),
           let stored = try? JSONDecoder().decode(AudioSettings.self, from: data) {
            settings = stored.clamped()
        } else {
            settings = AudioSettings()
        }
    }

    func start() {
        guard !started else { return }
        engine.errorHandler = { [weak self] message in self?.errorMessage = message }
        do {
            try engine.start(settings: settings)
            started = true
            errorMessage = nil
        } catch {
            errorMessage = "Audio could not start: \(error.localizedDescription)"
        }
    }

    func retry() {
        if started { engine.retry() }
        else { start() }
    }

    func setMaster(_ value: Double) { update { $0.master = value } }
    func setMuted(_ value: Bool) { update { $0.muted = value } }
    func setLayer(_ layer: AmbientLayer, volume: Double) {
        update { $0.setVolume(volume, for: layer) }
    }
    func setThunder(_ value: Double) { update { $0.thunder = value } }

    func playThunder(distance: Double, pan: Float) {
        engine.playThunder(distance: distance, pan: pan)
    }

    private func update(_ change: (inout AudioSettings) -> Void) {
        change(&settings)
        settings = settings.clamped()
        engine.apply(settings)
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: AppSettings.audioSettingsKey)
        }
    }
}
