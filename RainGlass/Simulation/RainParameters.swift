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
    var lightningEnabled: Bool = false
    var stormFrequency: Double = 0
    var splatsEnabled: Bool = false

    static let rain = RainParameters(
        intensity: 0.72, dropletSize: 1, dropCount: 4_800, gravity: 1,
        wind: 0, blur: 2, refraction: 0.65, trailPersistence: 4.5
    )

    func clamped() -> RainParameters {
        var result = RainParameters(
            intensity: intensity.clamped(to: 0...1),
            dropletSize: dropletSize.clamped(to: 0.5...2),
            dropCount: dropCount.clamped(to: 0...6_000),
            gravity: gravity.clamped(to: 0...2),
            wind: wind.clamped(to: -1...1),
            blur: blur.clamped(to: 0...64),
            refraction: refraction.clamped(to: 0...1),
            trailPersistence: trailPersistence.clamped(to: 0.5...15)
        )
        result.lightningEnabled = lightningEnabled
        result.stormFrequency = stormFrequency.clamped(to: 0...30)
        result.splatsEnabled = splatsEnabled
        return result
    }

    func approaching(_ target: RainParameters, fraction: Double) -> RainParameters {
        func blend(_ from: Double, _ to: Double) -> Double { from + (to - from) * fraction }
        var result = RainParameters(
            intensity: blend(intensity, target.intensity),
            dropletSize: blend(dropletSize, target.dropletSize),
            dropCount: blend(dropCount, target.dropCount),
            gravity: blend(gravity, target.gravity),
            wind: blend(wind, target.wind),
            blur: blend(blur, target.blur),
            refraction: blend(refraction, target.refraction),
            trailPersistence: blend(trailPersistence, target.trailPersistence)
        )
        result.lightningEnabled = target.lightningEnabled
        result.stormFrequency = blend(stormFrequency, target.stormFrequency)
        result.splatsEnabled = target.splatsEnabled
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case intensity, dropletSize, dropCount, gravity, wind, blur, refraction, trailPersistence
        case lightningEnabled, stormFrequency, splatsEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        intensity = try values.decode(Double.self, forKey: .intensity)
        dropletSize = try values.decode(Double.self, forKey: .dropletSize)
        dropCount = try values.decode(Double.self, forKey: .dropCount)
        gravity = try values.decode(Double.self, forKey: .gravity)
        wind = try values.decode(Double.self, forKey: .wind)
        blur = try values.decode(Double.self, forKey: .blur)
        refraction = try values.decode(Double.self, forKey: .refraction)
        trailPersistence = try values.decode(Double.self, forKey: .trailPersistence)
        lightningEnabled = try values.decodeIfPresent(Bool.self, forKey: .lightningEnabled) ?? false
        stormFrequency = try values.decodeIfPresent(Double.self, forKey: .stormFrequency) ?? 0
        splatsEnabled = try values.decodeIfPresent(Bool.self, forKey: .splatsEnabled) ?? false
    }

    init(intensity: Double, dropletSize: Double, dropCount: Double, gravity: Double,
         wind: Double, blur: Double, refraction: Double, trailPersistence: Double,
         lightningEnabled: Bool = false, stormFrequency: Double = 0, splatsEnabled: Bool = false) {
        self.intensity = intensity
        self.dropletSize = dropletSize
        self.dropCount = dropCount
        self.gravity = gravity
        self.wind = wind
        self.blur = blur
        self.refraction = refraction
        self.trailPersistence = trailPersistence
        self.lightningEnabled = lightningEnabled
        self.stormFrequency = stormFrequency
        self.splatsEnabled = splatsEnabled
    }
}

private extension Double {
    func clamped(to limits: ClosedRange<Double>) -> Double { min(max(self, limits.lowerBound), limits.upperBound) }
}
