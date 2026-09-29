import Foundation
import simd

@main
struct RainWaterPolishCheck {
    static func main() {
        let size = CGSize(width: 1440, height: 900)
        let first = RainSimulation(seed: 42)
        let second = RainSimulation(seed: 42)
        assert(MemoryLayout<TrailRenderInstance>.stride == 64)
        first.resize(to: size)
        second.resize(to: size)
        assert(first.droplets.map(\.id) == second.droplets.map(\.id))
        assert(first.droplets.allSatisfy { $0.trailAnchor == $0.position })
        assert(first.droplets.allSatisfy { $0.birthFade == 1 })
        let stationaryShare = Float(first.droplets.filter(\.pinned).count) / Float(first.droplets.count)
        assert((0.25...0.35).contains(stationaryShare))
        for (a, b) in zip(first.droplets, second.droplets) {
            assert(a.shapeAspect == b.shapeAspect && a.shapeAsymmetry == b.shapeAsymmetry &&
                   a.shapePhase == b.shapePhase)
        }
        let tiny = first.droplets.filter { $0.radius < 2 }
        assert(tiny.allSatisfy { abs($0.shapeAspect - 1) <= 0.016 && abs($0.shapeAsymmetry) < 0.001 })
        assert(first.droplets.contains { abs($0.shapeAspect - 1) > 0.02 })
        assert(first.droplets.contains { !$0.pinned && $0.radius < 2 })
        assert(first.droplets.allSatisfy { $0.radius <= 2.5 })
        assert(first.drainArrivalEvents().isEmpty)

        var sawAccumulatedTrail = false
        var sawBridge = false
        var sawMerge = false
        var sawFade = false
        var sawFullFade = false
        var sawSpeedChange = false
        var sawRetarget = false
        var sawLateralDrift = false
        var priorBridgeIDs = Set<UInt64>()
        var knownIDs = Set(first.droplets.map(\.id))
        var birthSteps: [UInt64: Int] = [:]
        for tick in 0..<240 {
            let anchors = Dictionary(uniqueKeysWithValues: first.droplets.map { ($0.id, $0.trailAnchor) })
            let positions = Dictionary(uniqueKeysWithValues: first.droplets.map { ($0.id, $0.position) })
            let masses = Dictionary(uniqueKeysWithValues: first.droplets.map { ($0.id, $0.mass) })
            let speeds = Dictionary(uniqueKeysWithValues: first.droplets.map { ($0.id, $0.velocity.y) })
            let lateralSpeeds = Dictionary(uniqueKeysWithValues: first.droplets.map { ($0.id, $0.velocity.x) })
            let targets = Dictionary(uniqueKeysWithValues: first.droplets.map {
                ($0.id, SIMD2($0.targetResistance, $0.targetDrift))
            })
            var lastWidths: [UInt64: Float] = [:]
            for trail in first.trails { lastWidths[trail.parentID] = trail.endWidth }
            first.step(dt: 1.0 / 120.0)
            second.step(dt: 1.0 / 120.0)
            for droplet in first.droplets {
                if let priorPosition = positions[droplet.id] {
                    assert(droplet.position.y >= priorPosition.y)
                }
                if let previousMass = masses[droplet.id], droplet.mass > previousMass + 0.001 {
                    assert(droplet.position.y >= positions[droplet.id]!.y)
                    assert(droplet.trailAnchor == anchors[droplet.id] || droplet.trailAnchor == droplet.position)
                    sawMerge = true
                }
                assert(droplet.velocity.y >= 0)
                assert(abs(droplet.velocity.x) <= droplet.velocity.y * 0.25 + 0.0001)
                if !knownIDs.contains(droplet.id) {
                    assert(droplet.birthFade <= 1.0 / 24.0 + 0.0001)
                    birthSteps[droplet.id] = tick
                    sawFade = true
                }
                if let birthStep = birthSteps[droplet.id], tick - birthStep >= 100 {
                    assert(droplet.birthFade == 1)
                    sawFullFade = true
                }
                if let previousSpeed = speeds[droplet.id], !droplet.pinned,
                   droplet.velocity.y < previousSpeed - 0.0001 { sawSpeedChange = true }
                if let previousTarget = targets[droplet.id],
                   previousTarget != SIMD2(droplet.targetResistance, droplet.targetDrift) {
                    sawRetarget = true
                }
                if let previousLateralSpeed = lateralSpeeds[droplet.id], !droplet.pinned,
                   abs(droplet.velocity.x - previousLateralSpeed) > 0.001 { sawLateralDrift = true }
            }
            for trail in first.trails where trail.age <= 1.0 / 120.0 + 0.0001 {
                if let anchor = anchors[trail.parentID] {
                    assert(trail.start == anchor)
                    assert(simd_distance(trail.start, trail.end) >= 9)
                    if let previousWidth = lastWidths[trail.parentID] {
                        assert(abs(trail.startWidth - previousWidth) < 0.0001)
                    }
                    if let previous = positions[trail.parentID],
                       simd_distance(trail.start, trail.end) > simd_distance(previous, trail.end) + 0.5 {
                        sawAccumulatedTrail = true
                    }
                }
                assert((2.2...9).contains(trail.startWidth))
                assert((2.2...9).contains(trail.endWidth))
            }
            assert(first.droplets.map(\.id) == second.droplets.map(\.id))
            for (a, b) in zip(first.droplets, second.droplets) {
                assert(a.position == b.position && a.velocity == b.velocity)
                assert(a.resistance == b.resistance && a.drift == b.drift)
                assert(a.birthFade == b.birthFade && a.trailWidthAtAnchor == b.trailWidthAtAnchor)
            }
            knownIDs = Set(first.droplets.map(\.id))
            let ids = Set(first.droplets.map(\.id))
            assert(ids.count == first.droplets.count)
            let currentBridgeIDs = Set(first.bridges.flatMap { [$0.firstID, $0.secondID] })
            priorBridgeIDs.formUnion(currentBridgeIDs)
            if !first.bridges.isEmpty { sawBridge = true }
            assert(first.bridges.count <= RainSimulation.maximumBridges)
            assert(first.trails.count <= RainSimulation.maximumTrails)
            assert(first.bridges.count == second.bridges.count)
            for (a, b) in zip(first.bridges, second.bridges) {
                assert(a.firstID == b.firstID && a.secondID == b.secondID)
                assert(a.start == b.start && a.end == b.end && a.width == b.width)
                let left = first.droplets.first { $0.id == a.firstID }!
                let right = first.droplets.first { $0.id == a.secondID }!
                assert(left.pinned && right.pinned)
                assert(simd_distance(left.position, right.position) <= 1.2 * (left.radius + right.radius))
            }
            var instances: [TrailRenderInstance] = []
            first.trailInstances(into: &instances)
            let livePaths = first.droplets.filter {
                !$0.pinned && simd_distance_squared($0.trailAnchor, $0.position) > 0.01
            }
            assert(instances.count == first.trails.count + first.bridges.count + livePaths.count)
            assert(instances.count <= RainSimulation.maximumTrails + RainSimulation.maximumBridges +
                   RainSimulation.maximumDroplets)
            if let trail = first.trails.first {
                assert(instances[0].appearance.x == trail.startWidth)
                assert(instances[0].appearance.y == trail.endWidth)
                if let parent = first.droplets.first(where: { $0.id == trail.parentID }) {
                    assert(instances[0].dropMask.x == parent.position.x)
                    assert(instances[0].dropMask.z > 0)
                }
                assert(instances[0].style.x == 0)
            }
            if !first.bridges.isEmpty {
                assert(instances[first.trails.count].style.x == 1)
            }
            for (drop, instance) in zip(livePaths, instances.suffix(livePaths.count)) {
                assert(SIMD2(instance.startEnd.x, instance.startEnd.y) == drop.trailAnchor)
                assert(SIMD2(instance.startEnd.z, instance.startEnd.w) == drop.position)
            }
        }
        assert(sawAccumulatedTrail && sawBridge && sawMerge && sawFade && sawFullFade &&
               sawSpeedChange && sawRetarget && sawLateralDrift)
        let movingSpeeds = first.droplets.filter { !$0.pinned }.map { $0.velocity.y }
        assert(movingSpeeds.max()! > 20 && movingSpeeds.min()! < 5)
        assert(first.trails.contains { $0.age > 1 && $0.age < $0.lifetime })
        assert(!priorBridgeIDs.isEmpty)
        let originalAnchor = first.droplets[0].trailAnchor
        let originalTrail = first.trails[0]
        first.resize(to: CGSize(width: 2880, height: 1800))
        assert(first.droplets[0].trailAnchor == originalAnchor * 2)
        assert(first.trails[0].start == originalTrail.start * 2)
        assert(first.trails[0].end == originalTrail.end * 2)
        let bridgeSimulation = RainSimulation(seed: 42)
        bridgeSimulation.resize(to: size)
        for _ in 0..<240 where bridgeSimulation.bridges.isEmpty {
            bridgeSimulation.step(dt: 1.0 / 120.0)
        }
        let originalBridge = bridgeSimulation.bridges[0]
        bridgeSimulation.resize(to: CGSize(width: 2880, height: 1800))
        assert(bridgeSimulation.bridges[0].start == originalBridge.start * 2)
        assert(bridgeSimulation.bridges[0].end == originalBridge.end * 2)
        var dry = RainParameters.rain
        dry.intensity = 0
        first.setParameters(dry)
        for _ in 0..<720 { first.step(dt: 1.0 / 120.0) }
        assert(first.droplets.isEmpty && first.bridges.isEmpty)
        print("Merge positions, seeded flow, trail widths, fades, bridges, resize, and bounds checked")
    }
}
