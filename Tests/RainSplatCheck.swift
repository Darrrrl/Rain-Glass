import Foundation

@main
struct RainSplatCheck {
    static func main() {
        let viewport = CGSize(width: 1200, height: 800)
        let simulation = RainSimulation(seed: 98)
        let matching = RainSimulation(seed: 98)
        simulation.resize(to: viewport)
        matching.resize(to: viewport)
        assert(!simulation.currentParameters.splatsEnabled)
        var parameters = RainParameters.rain
        parameters.splatsEnabled = true
        simulation.setParameters(parameters)
        matching.setParameters(parameters)
        var impacts = ImpactSplats()
        var mirror = ImpactSplats()
        var firstArrival: DropArrivalEvent?
        for _ in 0..<840 {
            simulation.step(dt: 1 / 120)
            matching.step(dt: 1 / 120)
            let arrivals = simulation.drainArrivalEvents()
            let other = matching.drainArrivalEvents()
            assert(arrivals.map(\.id) == other.map(\.id))
            impacts.step(dt: 1 / 120)
            mirror.step(dt: 1 / 120)
            if simulation.currentParameters.splatsEnabled {
                impacts.append(arrivals)
                mirror.append(other)
            }
            if firstArrival == nil { firstArrival = arrivals.first }
            assert(impacts.active == mirror.active)
            assert(impacts.active.count <= ImpactSplats.maximumCount)
        }
        assert(firstArrival != nil)
        var instances: [SplatRenderInstance] = []
        impacts.renderInstances(into: &instances)
        assert(instances.count == impacts.active.count)
        impacts.clear()
        impacts.append([firstArrival!])
        impacts.renderInstances(into: &instances)
        assert(instances.count == 1)
        assert(instances[0].geometry.x == firstArrival!.position.x)
        assert(instances[0].geometry.y == firstArrival!.position.y)
        assert(instances[0].appearance.x == 1)
        impacts.step(dt: 0) // Pause preserves animation age.
        assert(impacts.active[0].age == 0)
        impacts.step(dt: ImpactSplats.duration + 0.001)
        assert(impacts.active.isEmpty)
        impacts.append(Array(repeating: firstArrival!, count: 100))
        assert(impacts.active.count == 64)
        impacts.clear() // Disabling, reseeding, and resizing discard old impacts.
        assert(impacts.active.isEmpty)
        print("Seeded impact splats, position, pause, lifetime, and count checked")
    }
}
