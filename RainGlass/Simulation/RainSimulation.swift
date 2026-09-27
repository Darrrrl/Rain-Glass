import Foundation
import CoreGraphics
import simd

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

struct TrailSegment {
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var radius: Float
    var age: Float
    var lifetime: Float
}

struct TrailRenderInstance {
    var startEnd: SIMD4<Float>
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
    static let maximumDroplets = 6_000
    static let maximumTrails = 16_000
    private(set) var droplets: [Droplet] = []
    private(set) var trails: [TrailSegment] = []
    private(set) var viewport = CGSize.zero
    private var random: SplitMix64
    private var spawnCredit: Float = 0
    private var collisionCredit: Float = 0

    init(seed: UInt64) {
        random = SplitMix64(seed: seed)
    }

    func reset(seed: UInt64) {
        random = SplitMix64(seed: seed)
        droplets.removeAll(keepingCapacity: true)
        trails.removeAll(keepingCapacity: true)
        spawnCredit = 0
        collisionCredit = 0
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
            for index in trails.indices {
                trails[index].start *= scale
                trails[index].end *= scale
            }
        }
        viewport = size
        if droplets.isEmpty { populate() }
    }

    func step(dt: Float) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        for index in droplets.indices {
            droplets[index].age += dt
            if !droplets[index].pinned {
                let radius = droplets[index].radius
                let acceleration = max(0, 120 - droplets[index].friction * 5 / radius)
                droplets[index].velocity.y = min(180, droplets[index].velocity.y + acceleration * dt)
                droplets[index].velocity.x = sin(droplets[index].age * 1.7 + droplets[index].phase) * min(4, radius * 0.2)
                let previous = droplets[index].position
                droplets[index].position += droplets[index].velocity * dt
                if simd_distance(previous, droplets[index].position) >= 0.9 {
                    trails.append(TrailSegment(
                        start: previous, end: droplets[index].position,
                        radius: max(0.8, radius * 0.42), age: 0, lifetime: 4.5
                    ))
                }
            }
            if droplets[index].age >= droplets[index].lifetime ||
                droplets[index].position.y - droplets[index].radius > Float(viewport.height) + 16 {
                droplets[index] = makeDroplet()
            }
        }
        collisionCredit += dt
        if collisionCredit >= 1.0 / 30.0 {
            mergeCollisions()
            collisionCredit = 0
        }
        for index in trails.indices { trails[index].age += dt }
        trails.removeAll { $0.age >= $0.lifetime }
        if trails.count > Self.maximumTrails {
            trails.removeFirst(trails.count - Self.maximumTrails)
        }
        replenish(dt: dt)
    }

    func trailInstances(into output: inout [TrailRenderInstance]) {
        output.removeAll(keepingCapacity: true)
        output.reserveCapacity(trails.count)
        for trail in trails {
            output.append(TrailRenderInstance(
                startEnd: SIMD4(trail.start.x, trail.start.y, trail.end.x, trail.end.y),
                appearance: SIMD4(trail.radius, max(0, 1 - trail.age / trail.lifetime), 0, 0)
            ))
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
        let target = min(Self.maximumDroplets, max(800, Int(viewport.width * viewport.height / 200)))
        if droplets.count > target {
            droplets.removeLast(droplets.count - target)
        }
        droplets.reserveCapacity(target)
        while droplets.count < target {
            droplets.append(makeDroplet())
        }
    }

    private func replenish(dt: Float) {
        let target = min(Self.maximumDroplets, max(800, Int(viewport.width * viewport.height / 200)))
        spawnCredit += dt * Float(max(40, target / 8))
        let allowance = min(Int(spawnCredit), 12)
        spawnCredit -= Float(allowance)
        for _ in 0..<min(allowance, max(0, target - droplets.count)) {
            droplets.append(makeDroplet())
        }
    }

    private func mergeCollisions() {
        let cellSize: Float = 32
        func cell(_ point: SIMD2<Float>) -> SIMD2<Int> {
            SIMD2(Int(floor(point.x / cellSize)), Int(floor(point.y / cellSize)))
        }
        func key(_ x: Int, _ y: Int) -> Int64 {
            (Int64(x) << 32) ^ Int64(UInt32(truncatingIfNeeded: y))
        }
        var grid: [Int64: [Int]] = [:]
        grid.reserveCapacity(droplets.count)
        let maximumRadius = droplets.reduce(Float.zero) { max($0, $1.radius) }
        for index in droplets.indices {
            let coordinate = cell(droplets[index].position)
            grid[key(coordinate.x, coordinate.y), default: []].append(index)
        }
        var consumed = [Bool](repeating: false, count: droplets.count)
        for index in droplets.indices where !consumed[index] {
            let coordinate = cell(droplets[index].position)
            let reach = Int(ceil((droplets[index].radius + maximumRadius) / cellSize))
            for y in (coordinate.y - reach)...(coordinate.y + reach) {
                for x in (coordinate.x - reach)...(coordinate.x + reach) {
                    guard let candidates = grid[key(x, y)] else { continue }
                    for other in candidates where other > index && !consumed[other] {
                        let first = droplets[index]
                        let second = droplets[other]
                        guard simd_distance(first.position, second.position) <
                                (first.radius + second.radius) * 0.82 else { continue }
                        let mass = first.mass + second.mass
                        droplets[index].position = (first.position * first.mass + second.position * second.mass) / mass
                        droplets[index].velocity = (first.velocity * first.mass + second.velocity * second.mass) / mass
                        droplets[index].mass = mass
                        droplets[index].radius = pow(mass, 1.0 / 3.0)
                        droplets[index].friction = (first.friction * first.mass + second.friction * second.mass) / mass
                        droplets[index].pinned = first.pinned && second.pinned && droplets[index].radius < 4.8
                        droplets[index].age = min(first.age, second.age)
                        droplets[index].lifetime = max(first.lifetime, second.lifetime)
                        droplets[index].opacity = max(first.opacity, second.opacity)
                        consumed[other] = true
                    }
                }
            }
        }
        if consumed.contains(true) {
            var index = 0
            droplets.removeAll { _ in
                defer { index += 1 }
                return consumed[index]
            }
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
