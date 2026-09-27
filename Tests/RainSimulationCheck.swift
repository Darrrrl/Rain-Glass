import Foundation

@main
struct RainSimulationCheck {
    static func main() {
        let size = CGSize(width: 1440, height: 900)
        let first = RainSimulation(seed: 42)
        let second = RainSimulation(seed: 42)
        first.reset(seed: 42)
        second.reset(seed: 42)
        assert(first.droplets.isEmpty)
        first.resize(to: size)
        second.resize(to: size)

        assert(first.droplets.count == second.droplets.count)
        assert(first.droplets.contains(where: { $0.pinned }))
        assert(first.droplets.contains(where: { !$0.pinned }))
        assert(first.droplets.allSatisfy { $0.mass > 0 && $0.lifetime > 0 })

        let initialMass = first.droplets.reduce(Float.zero) { $0 + $1.mass }
        for _ in 0..<4 { first.step(dt: 1.0 / 120.0) }
        let mergedMass = first.droplets.reduce(Float.zero) { $0 + $1.mass }
        assert(mergedMass >= initialMass * 0.9999)
        assert(first.droplets.allSatisfy { abs($0.mass - $0.radius * $0.radius * $0.radius) < max(0.01, $0.mass * 0.0001) })
        first.reset(seed: 42)

        for _ in 0..<600 {
            first.step(dt: 1.0 / 120.0)
            second.step(dt: 1.0 / 120.0)
        }
        for (left, right) in zip(first.droplets, second.droplets) {
            assert(left.position == right.position)
            assert(left.velocity == right.velocity)
            assert(left.radius == right.radius)
            assert(left.mass == right.mass)
            assert(left.age == right.age)
        }
        assert(first.trails.count <= RainSimulation.maximumTrails)
        assert(first.trails.count == second.trails.count)

        let countBeforeTransition = first.droplets.count
        first.setParameters(BuiltInRainPreset.storm.parameters)
        assert(first.droplets.count == countBeforeTransition)
        first.step(dt: 1.0 / 120.0)
        assert(first.currentParameters.intensity > RainParameters.rain.intensity)
        assert(first.currentParameters.intensity < BuiltInRainPreset.storm.parameters.intensity)
        for _ in 0..<240 { first.step(dt: 1.0 / 120.0) }
        assert(first.droplets.count <= RainSimulation.maximumDroplets)
        assert(first.trails.count <= RainSimulation.maximumTrails)

        let third = RainSimulation(seed: 43)
        third.resize(to: size)
        assert(first.droplets[0].position != third.droplets[0].position)

        let originalPosition = first.droplets[0].position
        first.resize(to: CGSize(width: 2880, height: 1800))
        assert(first.droplets[0].position == originalPosition * 2)

        var dry = BuiltInRainPreset.drizzle.parameters
        dry.intensity = 0
        first.setParameters(dry)
        for _ in 0..<720 { first.step(dt: 1.0 / 120.0) }
        assert(first.droplets.isEmpty)
        print("RainSimulation deterministic, bounded, transition-safe, and resize-safe")
    }
}
