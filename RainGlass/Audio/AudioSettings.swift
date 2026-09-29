import Combine
import Foundation
import OSLog

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
    var glassTaps: Double = 0.2

    private enum CodingKeys: String, CodingKey {
        case master, muted, window, distant, wind, room, thunder, glassTaps
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        master = try values.decode(Double.self, forKey: .master)
        muted = try values.decode(Bool.self, forKey: .muted)
        window = try values.decode(Double.self, forKey: .window)
        distant = try values.decode(Double.self, forKey: .distant)
        wind = try values.decode(Double.self, forKey: .wind)
        room = try values.decode(Double.self, forKey: .room)
        thunder = try values.decode(Double.self, forKey: .thunder)
        glassTaps = try values.decodeIfPresent(Double.self, forKey: .glassTaps) ?? 0.2
    }

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
        copy.glassTaps = min(max(glassTaps, 0), 1)
        return copy
    }
}

@MainActor
final class AudioController: ObservableObject {
    private let log = Logger(subsystem: "dev.rainglass.app", category: "audio")
    @Published private(set) var settings: AudioSettings
    @Published private(set) var errorMessage: String?
    private let defaults: UserDefaults
    private let engine = AmbientAudioEngine()
    private var started = false
    private var temporarilySilent = false
    private var lastTapTime = -Double.infinity
    private var recentTapTimes: [Double] = []
    private var desktopSource: UUID?
    private var desktopSourceTime = 0.0

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
        engine.errorHandler = { [weak self] message in
            if let message { self?.log.error("Audio engine error: \(message, privacy: .public)") }
            self?.errorMessage = message
        }
        do {
            try engine.start(settings: effectiveSettings)
            started = true
            errorMessage = nil
        } catch {
            log.error("Audio start failed: \(error.localizedDescription, privacy: .public)")
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
    func setGlassTaps(_ value: Double) { update { $0.glassTaps = value } }

    private var effectiveSettings: AudioSettings {
        var value = settings
        if temporarilySilent { value.muted = true }
        return value
    }

    func setTemporarilySilent(_ value: Bool) {
        guard temporarilySilent != value else { return }
        temporarilySilent = value
        engine.apply(effectiveSettings)
    }

    func playArrivals(_ arrivals: [(id: UInt64, radius: Float, x: Float)], sourceID: UUID) {
        guard !temporarilySilent, !settings.muted, settings.glassTaps > 0, started else { return }
        let sourceTime = ProcessInfo.processInfo.systemUptime
        if let desktopSource, desktopSource != sourceID, sourceTime - desktopSourceTime < 1 { return }
        desktopSource = sourceID
        desktopSourceTime = sourceTime
        for arrival in arrivals {
            let now = ProcessInfo.processInfo.systemUptime
            recentTapTimes.removeAll { now - $0 >= 1 }
            guard now - lastTapTime >= 0.18, recentTapTimes.count < 3 else { continue }
            lastTapTime = now
            recentTapTimes.append(now)
            engine.playGlassTap(id: arrival.id, radius: arrival.radius, x: arrival.x)
        }
    }

    func applyPreset(_ preset: AudioSettings) {
        // Preserve the user's mute choice while the engine ramps to the new levels.
        update { current in
            let muted = current.muted
            current = preset
            current.muted = muted
        }
    }

    func playThunder(distance: Double, pan: Float) {
        guard !temporarilySilent else { return }
        engine.playThunder(distance: distance, pan: pan)
    }

    private func update(_ change: (inout AudioSettings) -> Void) {
        change(&settings)
        settings = settings.clamped()
        engine.apply(effectiveSettings)
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: AppSettings.audioSettingsKey)
        }
    }
}
