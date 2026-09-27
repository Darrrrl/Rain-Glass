import Foundation
import CoreGraphics

struct Droplet {
    var position: SIMD2<Float>
    var radius: Float
    var velocity: SIMD2<Float>
    var mass: Float
    var age: Float
    var lifetime: Float
    var friction: Float
    var pinned: Bool
    var phase: Float
    var opacity: Float
}

struct DropletRenderInstance {
    var geometry: SIMD4<Float>
    var appearance: SIMD4<Float>
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func range(_ low: Float, _ high: Float) -> Float {
        low + (high - low) * unit()
    }
}

final class RainSimulation {
    private(set) var droplets: [Droplet] = []
    private(set) var viewport = CGSize.zero
    private var random: SplitMix64

    init(seed: UInt64) {
        random = SplitMix64(seed: seed)
    }

    func reset(seed: UInt64) {
        random = SplitMix64(seed: seed)
        droplets.removeAll(keepingCapacity: true)
        populate()
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard size != viewport else { return }
        if viewport.width > 0, viewport.height > 0 {
            let scale = SIMD2<Float>(Float(size.width / viewport.width), Float(size.height / viewport.height))
            for index in droplets.indices {
                droplets[index].position *= scale
            }
        }
        viewport = size
        populate()
    }

    func step(dt: Float) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        for index in droplets.indices {
            droplets[index].age += dt
            if !droplets[index].pinned {
                let radius = droplets[index].radius
                let acceleration = max(0, 112 - droplets[index].friction * 5 / radius)
                droplets[index].velocity.y = min(160, droplets[index].velocity.y + acceleration * dt)
                droplets[index].velocity.x = sin(droplets[index].age * 1.7 + droplets[index].phase) * min(2.5, radius * 0.18)
                droplets[index].position += droplets[index].velocity * dt
            }
            if droplets[index].age >= droplets[index].lifetime ||
                droplets[index].position.y - droplets[index].radius > Float(viewport.height) + 16 {
                droplets[index] = makeDroplet()
            }
        }
    }

    func renderInstances(into output: inout [DropletRenderInstance]) {
        output.removeAll(keepingCapacity: true)
        output.reserveCapacity(droplets.count)
        for droplet in droplets {
            let stretch = droplet.pinned ? 1 : min(1.65, 1 + droplet.velocity.y / 240)
            output.append(DropletRenderInstance(
                geometry: SIMD4(droplet.position.x, droplet.position.y, droplet.radius, stretch),
                appearance: SIMD4(droplet.opacity, droplet.phase, droplet.pinned ? 1 : 0, 0)
            ))
        }
    }

    private func populate() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let target = min(6_000, max(800, Int(viewport.width * viewport.height / 200)))
        if droplets.count > target {
            droplets.removeLast(droplets.count - target)
        }
        droplets.reserveCapacity(target)
        while droplets.count < target {
            droplets.append(makeDroplet())
        }
    }

    private func makeDroplet() -> Droplet {
        let classRoll = random.unit()
        let radius: Float
        if classRoll < 0.83 {
            radius = random.range(0.8, 2.8)
        } else if classRoll < 0.96 {
            radius = random.range(2.8, 5.2)
        } else {
            radius = random.range(6, 15)
        }
        let pinned = radius < 4.8
        let lifetime = pinned ? random.range(45, 125) : random.range(14, 40)
        return Droplet(
            position: SIMD2(random.range(0, Float(viewport.width)), random.range(0, Float(viewport.height))),
            radius: radius,
            velocity: .zero,
            mass: radius * radius * radius,
            age: random.range(0, lifetime * 0.7),
            lifetime: lifetime,
            friction: random.range(28, 85),
            pinned: pinned,
            phase: random.range(0, Float.pi * 2),
            opacity: pinned ? random.range(0.28, 0.55) : random.range(0.5, 0.78)
        )
    }
}
