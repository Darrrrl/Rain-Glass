import Foundation

struct RainParameters: Codable, Equatable {
    var intensity: Double
    var dropletSize: Double
    var dropCount: Double
    var gravity: Double
    var wind: Double
    var blur: Double
    var refraction: Double
    var trailPersistence: Double

    static let rain = RainParameters(
        intensity: 0.72, dropletSize: 1, dropCount: 4_800, gravity: 1,
        wind: 0, blur: 2, refraction: 0.65, trailPersistence: 4.5
    )

    func clamped() -> RainParameters {
        RainParameters(
            intensity: intensity.clamped(to: 0...1),
            dropletSize: dropletSize.clamped(to: 0.5...2),
            dropCount: dropCount.clamped(to: 0...6_000),
            gravity: gravity.clamped(to: 0...2),
            wind: wind.clamped(to: -1...1),
            blur: blur.clamped(to: 0...8),
            refraction: refraction.clamped(to: 0...1),
            trailPersistence: trailPersistence.clamped(to: 0.5...15)
        )
    }

    func approaching(_ target: RainParameters, fraction: Double) -> RainParameters {
        func blend(_ from: Double, _ to: Double) -> Double { from + (to - from) * fraction }
        return RainParameters(
            intensity: blend(intensity, target.intensity),
            dropletSize: blend(dropletSize, target.dropletSize),
            dropCount: blend(dropCount, target.dropCount),
            gravity: blend(gravity, target.gravity),
            wind: blend(wind, target.wind),
            blur: blend(blur, target.blur),
            refraction: blend(refraction, target.refraction),
            trailPersistence: blend(trailPersistence, target.trailPersistence)
        )
    }
}

private extension Double {
    func clamped(to limits: ClosedRange<Double>) -> Double { min(max(self, limits.lowerBound), limits.upperBound) }
}
