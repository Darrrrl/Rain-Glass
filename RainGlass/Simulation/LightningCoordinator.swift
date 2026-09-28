import Foundation

@MainActor
final class LightningCoordinator: NSObject {
    let flashState = LightningFlashState()
    private let rainSettings: RainSettingsStore
    private let audio: AudioController
    private var timer: Timer?
    private var nextStrikeAt = Double.infinity
    private var scheduledFrequency = 0.0
    private var pendingThunder: [LightningEvent] = []

    init(rainSettings: RainSettingsStore, audio: AudioController) {
        self.rainSettings = rainSettings
        self.audio = audio
        super.init()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
    }

    func triggerForDebug(distanceMeters: Double = 1_000) {
        strike(at: ProcessInfo.processInfo.systemUptime, distance: distanceMeters)
    }

    @objc private func tick(_ timer: Timer) {
        let now = ProcessInfo.processInfo.systemUptime
        let parameters = rainSettings.parameters
        let frequency = parameters.lightningEnabled ? parameters.stormFrequency : 0
        if frequency != scheduledFrequency {
            scheduledFrequency = frequency
            nextStrikeAt = frequency > 0 ? nextInterval(from: now, eventsPerHour: frequency) : .infinity
        }
        if now >= nextStrikeAt {
            strike(at: now, distance: Double.random(in: 300...5_000))
            nextStrikeAt = nextInterval(from: now, eventsPerHour: frequency)
        }
        for event in pendingThunder where now >= event.thunderAt && now - event.thunderAt < 2 {
            audio.playThunder(distance: event.distanceMeters, pan: event.pan)
        }
        pendingThunder.removeAll { now >= $0.thunderAt }
    }

    private func nextInterval(from now: Double, eventsPerHour: Double) -> Double {
        let random = Double.random(in: 0.0001...0.9999)
        return now - log(random) * 3_600 / max(eventsPerHour, 0.001)
    }

    private func strike(at now: Double, distance: Double) {
        let event = LightningEvent(
            startedAt: now,
            distanceMeters: max(300, min(distance, 5_000)),
            pan: Float.random(in: -0.65...0.65)
        )
        flashState.emit(event)
        pendingThunder.append(event)
    }
}
