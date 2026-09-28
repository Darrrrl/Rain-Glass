import Foundation

struct LightningEvent: Equatable {
    let startedAt: TimeInterval
    let distanceMeters: Double
    let pan: Float

    var thunderAt: TimeInterval { startedAt + distanceMeters / 343 }

    func exposure(at time: TimeInterval) -> Float {
        let elapsed = time - startedAt
        guard elapsed >= 0, elapsed < 0.65 else { return 0 }
        func pulse(_ center: Double, _ width: Double, _ strength: Double) -> Double {
            max(0, 1 - abs(elapsed - center) / width) * strength
        }
        let distanceFactor = max(0.25, min(1, 1_200 / distanceMeters))
        return Float((pulse(0.05, 0.055, 1.5) +
                      pulse(0.17, 0.045, 0.55) +
                      pulse(0.28, 0.10, 0.3)) * distanceFactor)
    }
}

final class LightningFlashState: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: LightningEvent?

    func emit(_ event: LightningEvent) {
        lock.lock()
        latest = event
        lock.unlock()
    }

    func exposure(at time: TimeInterval) -> Float {
        lock.lock()
        let event = latest
        lock.unlock()
        return event?.exposure(at: time) ?? 0
    }
}
