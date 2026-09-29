import Foundation
import CoreGraphics
import simd

struct Droplet {
    var id: UInt64
    var position: SIMD2<Float>
    var trailAnchor: SIMD2<Float>
    var radius: Float
    var velocity: SIMD2<Float>
    var mass: Float
    var age: Float
    var lifetime: Float
    var friction: Float
    var pinned: Bool
    var opacity: Float
    var birthFade: Float
    var birthDelay: Float
    var birthDuration: Float
    var arrivalPending: Bool
    var resistance: Float
    var targetResistance: Float
    var drift: Float
    var targetDrift: Float
    var surfaceSampleCountdown: Float
    var trailWidthAtAnchor: Float
    var trailBias: Float
    var shapeAspect: Float
    var shapeAsymmetry: Float
    var shapePhase: Float
}

struct DropArrivalEvent: Sendable {
    let id: UInt64
    let radius: Float
    let horizontalPosition: Float
}

struct DropletRenderInstance {
    var geometry: SIMD4<Float>
    var appearance: SIMD4<Float>
}

struct TrailSegment {
    var parentID: UInt64
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var startWidth: Float
    var endWidth: Float
    var strength: Float
    var age: Float
    var lifetime: Float
}

struct WaterBridge {
    var firstID: UInt64
    var secondID: UInt64
    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var width: Float
}

struct TrailRenderInstance {
    var startEnd: SIMD4<Float>
    var appearance: SIMD4<Float>
    var style: SIMD4<Float>
    // Parent drop's center and ellipse radii. Zero radii leave old trails untouched.
    var dropMask: SIMD4<Float> = .zero
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
    static let maximumTrails = 36_000
    static let maximumBridges = 280
    private(set) var droplets: [Droplet] = []
    private(set) var trails: [TrailSegment] = []
    private(set) var bridges: [WaterBridge] = []
    private(set) var viewport = CGSize.zero
    private var random: SplitMix64
    private var spawnCredit: Float = 0
    private var collisionCredit: Float = 0
    private var nextDropletID: UInt64 = 0
    private var startupRemaining: Float = 2
    private var resizeSoundSuppression: Float = 0
    private var arrivalEvents: [DropArrivalEvent] = []
    private var spawnGrid: [Int64: [Int]] = [:]
    private var seed: UInt64
    private(set) var currentParameters = RainParameters.rain
    private var targetParameters = RainParameters.rain

    init(seed: UInt64) {
        self.seed = seed
        random = SplitMix64(seed: seed)
    }

    func setParameters(_ parameters: RainParameters) {
        targetParameters = parameters.clamped()
    }

    func reset(seed: UInt64) {
        self.seed = seed
        random = SplitMix64(seed: seed)
        droplets.removeAll(keepingCapacity: true)
        trails.removeAll(keepingCapacity: true)
        bridges.removeAll(keepingCapacity: true)
        spawnCredit = 0
        collisionCredit = 0
        nextDropletID = 0
        startupRemaining = 2
        resizeSoundSuppression = 0
        arrivalEvents.removeAll(keepingCapacity: true)
        populate()
    }

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard size != viewport else { return }
        if viewport.width > 0, viewport.height > 0 {
            resizeSoundSuppression = 0.5
            arrivalEvents.removeAll(keepingCapacity: true)
            let scale = SIMD2<Float>(Float(size.width / viewport.width), Float(size.height / viewport.height))
            for index in droplets.indices {
                droplets[index].position *= scale
                droplets[index].trailAnchor *= scale
            }
            for index in trails.indices {
                trails[index].start *= scale
                trails[index].end *= scale
            }
            for index in bridges.indices {
                bridges[index].start *= scale
                bridges[index].end *= scale
            }
        }
        viewport = size
        if droplets.isEmpty { populate() }
    }

    func step(dt: Float) {
        guard viewport.width > 0, viewport.height > 0 else { return }
        resizeSoundSuppression = max(0, resizeSoundSuppression - dt)
        let previousSize = currentParameters.dropletSize
        let previousPersistence = currentParameters.trailPersistence
        currentParameters = currentParameters.approaching(targetParameters, fraction: 1 - exp(-Double(dt) * 2.2))
        let sizeRatio = Float(currentParameters.dropletSize / max(previousSize, 0.01))
        if abs(sizeRatio - 1) > 0.00001 {
            for index in droplets.indices {
                droplets[index].radius *= sizeRatio
                droplets[index].mass *= sizeRatio * sizeRatio * sizeRatio
            }
        }
        let persistenceRatio = Float(currentParameters.trailPersistence / max(previousPersistence, 0.01))
        if abs(persistenceRatio - 1) > 0.00001 {
            for index in trails.indices { trails[index].lifetime *= persistenceRatio }
        }
        rebuildSpawnGrid()
        for index in droplets.indices {
            if droplets[index].birthDelay > 0 {
                droplets[index].birthDelay = max(0, droplets[index].birthDelay - dt)
                continue
            }
            droplets[index].age += dt
            let progress = min(1, droplets[index].birthFade + dt / droplets[index].birthDuration)
            droplets[index].birthFade = progress
            if droplets[index].arrivalPending && progress >= 0.5 {
                droplets[index].arrivalPending = false
                if resizeSoundSuppression <= 0 {
                    arrivalEvents.append(DropArrivalEvent(
                        id: droplets[index].id, radius: droplets[index].radius,
                        horizontalPosition: droplets[index].position.x / Float(viewport.width)))
                }
            }
            if !droplets[index].pinned && progress >= 1 {
                let radius = droplets[index].radius
                let gravity = Float(currentParameters.gravity * (0.75 + currentParameters.intensity * 0.5))
                droplets[index].surfaceSampleCountdown -= dt
                if droplets[index].surfaceSampleCountdown <= 0 {
                    let position = droplets[index].position
                    let surfaceGrip = surfaceNoise(at: position / 56, salt: 0xA0761D6478BD642F)
                    let surfaceFlow = surfaceNoise(at: position / 105, salt: 0xE7037ED1A0B428DB)
                    droplets[index].targetResistance = 0.55 + surfaceGrip * 1.9
                    droplets[index].targetDrift = surfaceFlow * 2 - 1
                    droplets[index].surfaceSampleCountdown += 0.1
                }
                let ease = 1 - exp(-dt * 2.2)
                droplets[index].resistance += (droplets[index].targetResistance - droplets[index].resistance) * ease
                droplets[index].drift += (droplets[index].targetDrift - droplets[index].drift) * ease
                // Local adhesion is fixed to the glass; a drop changes pace as it crosses it.
                let sizeSpeed = pow(max(0.3, radius / 4), 1.3)
                let adhesion = droplets[index].friction / 55 * droplets[index].resistance
                let targetSpeed = gravity > 0 ? min(95, max(0, 26 * gravity * sizeSpeed / max(0.3, adhesion) - 3)) : 0
                let speedEase = 1 - exp(-dt * (1.8 + min(radius, 12) * 0.12))
                droplets[index].velocity.y += (targetSpeed - droplets[index].velocity.y) * speedEase
                if targetSpeed < 0.8 && droplets[index].velocity.y < 0.5 && radius < 2.6 {
                    droplets[index].pinned = true
                    droplets[index].velocity = .zero
                }
                let slope = max(-0.25, min(0.25,
                    Float(currentParameters.wind) * 0.16 + droplets[index].drift * 0.11))
                let lateralTarget = droplets[index].velocity.y * slope
                droplets[index].velocity.x += (lateralTarget - droplets[index].velocity.x) *
                    (1 - exp(-dt * 2.5))
                droplets[index].velocity.x = max(-droplets[index].velocity.y * 0.25,
                                                 min(droplets[index].velocity.y * 0.25, droplets[index].velocity.x))
                droplets[index].position += droplets[index].velocity * dt
                let segmentLength = max(9, min(20, radius * 2.5))
                let uncommittedDistance = simd_distance(droplets[index].trailAnchor, droplets[index].position)
                if uncommittedDistance >= segmentLength ||
                    (droplets[index].pinned && uncommittedDistance >= 0.1) {
                    let endWidth = trailWidth(for: droplets[index])
                    trails.append(TrailSegment(
                        parentID: droplets[index].id,
                        start: droplets[index].trailAnchor, end: droplets[index].position,
                        startWidth: droplets[index].trailWidthAtAnchor, endWidth: endWidth,
                        strength: max(0.4, min(1, radius / 3)) * droplets[index].birthFade, age: 0,
                        lifetime: Float(currentParameters.trailPersistence)
                    ))
                    droplets[index].trailAnchor = droplets[index].position
                    droplets[index].trailWidthAtAnchor = endWidth
                }
            }
            if droplets[index].age >= droplets[index].lifetime ||
                droplets[index].position.y - droplets[index].radius > Float(viewport.height) + 16 {
                invalidateBridges(for: droplets[index].id)
                droplets[index] = makeDroplet(fadeIn: true, soundEligible: startupRemaining <= 0)
                addToSpawnGrid(index)
            }
        }
        collisionCredit += dt
        if collisionCredit >= 1.0 / 30.0 {
            mergeCollisions()
            rebuildSpawnGrid()
            collisionCredit = 0
        }
        for index in trails.indices { trails[index].age += dt }
        trails.removeAll { $0.age >= $0.lifetime }
        if trails.count > Self.maximumTrails {
            trails.removeFirst(trails.count - Self.maximumTrails)
        }
        replenish(dt: dt)
    }

    func drainArrivalEvents() -> [DropArrivalEvent] {
        defer { arrivalEvents.removeAll(keepingCapacity: true) }
        return arrivalEvents
    }

    func trailInstances(into output: inout [TrailRenderInstance]) {
        output.removeAll(keepingCapacity: true)
        output.reserveCapacity(trails.count + bridges.count + droplets.count)
        let activeDrops = Dictionary(uniqueKeysWithValues: droplets.map { ($0.id, $0) })
        func mask(for drop: Droplet?) -> SIMD4<Float> {
            guard let drop, drop.birthDelay <= 0 else { return .zero }
            let stretch = drop.pinned ? 1 : min(1.32, 1 + max(0, drop.velocity.y) / 270)
            let radius = drop.radius * (0.9 + 0.1 * drop.birthFade)
            return SIMD4(drop.position.x, drop.position.y, radius, radius * drop.shapeAspect * stretch)
        }
        for trail in trails {
            let remaining = max(0, 1 - trail.age / trail.lifetime)
            output.append(TrailRenderInstance(
                startEnd: SIMD4(trail.start.x, trail.start.y, trail.end.x, trail.end.y),
                appearance: SIMD4(trail.startWidth, trail.endWidth,
                                  remaining * trail.strength, remaining),
                style: SIMD4(0, 0, 0, 0),
                dropMask: mask(for: activeDrops[trail.parentID])
            ))
        }
        for bridge in bridges {
            output.append(TrailRenderInstance(
                startEnd: SIMD4(bridge.start.x, bridge.start.y, bridge.end.x, bridge.end.y),
                appearance: SIMD4(bridge.width, bridge.width, 0.55, 1),
                style: SIMD4(1, 0, 0, 0)
            ))
        }
        // The newest part of each path remains joined to its moving drop between samples.
        for drop in droplets where !drop.pinned {
            guard simd_distance_squared(drop.trailAnchor, drop.position) > 0.01 else { continue }
            output.append(TrailRenderInstance(
                startEnd: SIMD4(drop.trailAnchor.x, drop.trailAnchor.y, drop.position.x, drop.position.y),
                appearance: SIMD4(drop.trailWidthAtAnchor, trailWidth(for: drop),
                                  max(0.4, min(1, drop.radius / 3)) * drop.birthFade, 1),
                style: SIMD4(0, 0, 0, 0),
                dropMask: mask(for: drop)
            ))
        }
    }

    func renderInstances(into output: inout [DropletRenderInstance]) {
        output.removeAll(keepingCapacity: true)
        output.reserveCapacity(droplets.count)
        for droplet in droplets {
            let stretch = droplet.pinned ? 1 : min(1.32, 1 + max(0, droplet.velocity.y) / 270)
            let visible = droplet.birthFade * droplet.birthFade * (3 - 2 * droplet.birthFade)
            output.append(DropletRenderInstance(
                geometry: SIMD4(droplet.position.x, droplet.position.y, droplet.radius * (0.9 + 0.1 * visible), stretch),
                appearance: SIMD4(droplet.opacity * visible, droplet.shapeAspect,
                                  droplet.shapeAsymmetry, droplet.shapePhase)
            ))
        }
    }

    private func populate() {
        guard viewport.width > 0, viewport.height > 0 else { return }
        let target = targetCount
        if droplets.count > target {
            for droplet in droplets[target...] { invalidateBridges(for: droplet.id) }
            droplets.removeLast(droplets.count - target)
        }
        droplets.reserveCapacity(target)
        rebuildSpawnGrid()
        let initial = min(target, max(1, Int(Float(target) * 0.25)))
        while droplets.count < initial {
            droplets.append(makeDroplet(fadeIn: false, smallBead: true))
            addToSpawnGrid(droplets.count - 1)
        }
    }

    private func replenish(dt: Float) {
        let target = targetCount
        let inStartup = startupRemaining > 0
        startupRemaining = max(0, startupRemaining - dt)
        spawnCredit += dt * (inStartup ? Float(target) * 0.375 : Float(max(60, max(target, droplets.count))))
        let allowance = min(Int(spawnCredit), 36)
        spawnCredit -= Float(allowance)
        if droplets.count < target {
            for _ in 0..<min(allowance, target - droplets.count) {
                droplets.append(makeDroplet(fadeIn: true, soundEligible: !inStartup))
                addToSpawnGrid(droplets.count - 1)
            }
        } else if droplets.count > target {
            let removed = min(allowance, droplets.count - target)
            for droplet in droplets.suffix(removed) { invalidateBridges(for: droplet.id) }
            droplets.removeLast(removed)
        }
    }

    private var targetCount: Int {
        min(Self.maximumDroplets, max(0, Int(currentParameters.dropCount * currentParameters.intensity)))
    }

    private func spawnKey(_ point: SIMD2<Float>) -> Int64 {
        let x = Int(floor(point.x / 64))
        let y = Int(floor(point.y / 64))
        return (Int64(x) << 32) ^ Int64(UInt32(truncatingIfNeeded: y))
    }

    private func rebuildSpawnGrid() {
        spawnGrid.removeAll(keepingCapacity: true)
        for index in droplets.indices { addToSpawnGrid(index) }
    }

    private func addToSpawnGrid(_ index: Int) {
        spawnGrid[spawnKey(droplets[index].position), default: []].append(index)
    }

    private func openPosition(radius: Float) -> SIMD2<Float> {
        var best = SIMD2<Float>.zero
        var bestClearance: Float = -.infinity
        for _ in 0..<6 {
            let point = SIMD2(random.range(0, Float(viewport.width)), random.range(0, Float(viewport.height)))
            let cellX = Int(floor(point.x / 64))
            let cellY = Int(floor(point.y / 64))
            var clearance: Float = 64
            for y in (cellY - 1)...(cellY + 1) {
                for x in (cellX - 1)...(cellX + 1) {
                    let key = (Int64(x) << 32) ^ Int64(UInt32(truncatingIfNeeded: y))
                    for index in spawnGrid[key] ?? [] where index < droplets.count {
                        let other = droplets[index]
                        clearance = min(clearance, simd_distance(point, other.position) -
                                        (radius + other.radius) * 1.25)
                    }
                }
            }
            if clearance > bestClearance { best = point; bestClearance = clearance }
            if clearance >= radius * 2 { break }
        }
        return best
    }

    private func invalidateBridges(for id: UInt64) {
        bridges.removeAll { $0.firstID == id || $0.secondID == id }
    }

    private static func pairHash(_ first: UInt64, _ second: UInt64) -> UInt64 {
        var value = min(first, second) &* 0x9E3779B97F4A7C15 ^
            max(first, second) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    private func surfaceNoise(at point: SIMD2<Float>, salt: UInt64) -> Float {
        let x = Int(floor(point.x))
        let y = Int(floor(point.y))
        let fractional = point - SIMD2(Float(x), Float(y))
        let smooth = fractional * fractional * (SIMD2<Float>(repeating: 3) - fractional * 2)
        func sample(_ x: Int, _ y: Int) -> Float {
            var value = seed ^ salt ^ UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15 ^
                UInt64(bitPattern: Int64(y)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return Float((value ^ (value >> 31)) >> 40) / Float(1 << 24)
        }
        let top = sample(x, y) + (sample(x + 1, y) - sample(x, y)) * smooth.x
        let bottom = sample(x, y + 1) + (sample(x + 1, y + 1) - sample(x, y + 1)) * smooth.x
        return top + (bottom - top) * smooth.y
    }

    func trailWidth(for drop: Droplet) -> Float {
        let speedFactor = 1.25 - min(1, drop.velocity.y / 95) * 0.4
        return max(2.2, min(9, drop.radius * 0.65 * drop.trailBias * speedFactor))
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
        for index in droplets.indices where droplets[index].birthDelay <= 0 && droplets[index].birthFade >= 0.5 {
            let coordinate = cell(droplets[index].position)
            grid[key(coordinate.x, coordinate.y), default: []].append(index)
        }
        var consumed = [Bool](repeating: false, count: droplets.count)
        var modified = [Bool](repeating: false, count: droplets.count)
        var bridgeDegree = [UInt8](repeating: 0, count: droplets.count)
        var bridgePairs: [(Int, Int)] = []
        bridgePairs.reserveCapacity(Self.maximumBridges)
        func contactRadius(_ drop: Droplet, toward direction: SIMD2<Float>) -> Float {
            let stretch = drop.pinned ? 1 : min(1.32, 1 + max(0, drop.velocity.y) / 270)
            let verticalScale = max(0.85, drop.shapeAspect * stretch)
            return drop.radius / sqrt(direction.x * direction.x +
                                      direction.y * direction.y / (verticalScale * verticalScale))
        }
        for index in droplets.indices where !consumed[index] &&
            droplets[index].birthDelay <= 0 && droplets[index].birthFade >= 0.5 {
            let coordinate = cell(droplets[index].position)
            let reach = Int(ceil(1.6 * (droplets[index].radius + maximumRadius) / cellSize))
            search: for y in (coordinate.y - reach)...(coordinate.y + reach) {
                for x in (coordinate.x - reach)...(coordinate.x + reach) {
                    guard let candidates = grid[key(x, y)] else { continue }
                    for other in candidates where other > index && !consumed[other] &&
                        droplets[other].birthDelay <= 0 && droplets[other].birthFade >= 0.5 {
                        let first = droplets[index]
                        let second = droplets[other]
                        let separation = simd_distance(first.position, second.position)
                        let direction = separation > 0.0001 ?
                            (second.position - first.position) / separation : SIMD2<Float>(0, 1)
                        let combinedRadius = contactRadius(first, toward: direction) +
                            contactRadius(second, toward: direction)
                        guard separation < combinedRadius * 1.2 else { continue }
                        let canBridge = first.pinned && second.pinned &&
                            !modified[index] && !modified[other] &&
                            min(first.radius, second.radius) / max(first.radius, second.radius) >= 0.62 &&
                            separation >= combinedRadius * 0.68 &&
                            Self.pairHash(first.id, second.id) % 2 == 0 &&
                            bridgePairs.count < Self.maximumBridges &&
                            bridgeDegree[index] < 2 && bridgeDegree[other] < 2
                        if canBridge {
                            bridgePairs.append((index, other))
                            bridgeDegree[index] += 1
                            bridgeDegree[other] += 1
                            continue
                        }
                        guard separation < combinedRadius * 0.82 else { continue }
                        let survivorIndex: Int
                        if first.pinned != second.pinned {
                            survivorIndex = first.pinned ? other : index
                        } else if first.pinned {
                            survivorIndex = first.radius > second.radius ||
                                (first.radius == second.radius && first.id < second.id) ? index : other
                        } else {
                            survivorIndex = first.position.y > second.position.y ||
                                (first.position.y == second.position.y &&
                                 (first.mass > second.mass || (first.mass == second.mass && first.id < second.id)))
                                ? index : other
                        }
                        let loserIndex = survivorIndex == index ? other : index
                        let survivor = droplets[survivorIndex]
                        let mass = first.mass + second.mass
                        var blendedVelocity = (first.velocity * first.mass + second.velocity * second.mass) / mass
                        blendedVelocity.y = max(0, blendedVelocity.y)
                        droplets[survivorIndex].velocity = blendedVelocity
                        droplets[survivorIndex].mass = mass
                        droplets[survivorIndex].radius = pow(mass, 1.0 / 3.0)
                        droplets[survivorIndex].friction = (first.friction * first.mass + second.friction * second.mass) / mass
                        droplets[survivorIndex].pinned = first.pinned && second.pinned && droplets[survivorIndex].radius < 4.8
                        droplets[survivorIndex].age = min(first.age, second.age)
                        droplets[survivorIndex].lifetime = max(first.lifetime, second.lifetime)
                        droplets[survivorIndex].opacity = max(first.opacity, second.opacity)
                        if survivor.pinned && !droplets[survivorIndex].pinned {
                            droplets[survivorIndex].trailWidthAtAnchor = trailWidth(for: droplets[survivorIndex])
                        }
                        modified[survivorIndex] = true
                        consumed[loserIndex] = true
                        if consumed[index] { break }
                    }
                    if consumed[index] { break search }
                }
            }
        }
        bridges = bridgePairs.compactMap { firstIndex, secondIndex in
            guard !consumed[firstIndex], !consumed[secondIndex],
                  !modified[firstIndex], !modified[secondIndex],
                  droplets[firstIndex].pinned, droplets[secondIndex].pinned else { return nil }
            let first = droplets[firstIndex]
            let second = droplets[secondIndex]
            return WaterBridge(firstID: first.id, secondID: second.id,
                               start: first.position, end: second.position,
                               width: max(1.0, min(2.0, min(first.radius, second.radius) * 0.18)))
        }
        if consumed.contains(true) {
            var index = 0
            droplets.removeAll { _ in
                defer { index += 1 }
                return consumed[index]
            }
        }
    }

    private func makeDroplet(fadeIn: Bool, smallBead: Bool = false, soundEligible: Bool = true) -> Droplet {
        let classRoll = random.unit()
        let radius: Float
        let size = Float(currentParameters.dropletSize)
        if smallBead {
            radius = random.range(0.8, 2.5) * size
        } else if classRoll < 0.83 {
            radius = random.range(0.8, 2.8) * size
        } else if classRoll < 0.96 {
            radius = random.range(2.8, 5.2) * size
        } else {
            radius = random.range(6, 15) * size
        }
        let id = nextDropletID
        nextDropletID &+= 1
        let pinned = Self.pairHash(seed, id) % 10 < 3
        let lifetime = pinned ? random.range(45, 125) : random.range(14, 40)
        var position = openPosition(radius: radius)
        if pinned && Self.pairHash(seed ^ 0xE7037ED1A0B428DB, id) % 10 == 0 {
            for _ in 0..<8 {
                guard !droplets.isEmpty else { break }
                let neighbor = droplets[min(droplets.count - 1, Int(random.unit() * Float(droplets.count)))]
                guard neighbor.pinned,
                      min(radius, neighbor.radius) / max(radius, neighbor.radius) >= 0.62 else { continue }
                let angle = random.range(0, Float.pi * 2)
                let separation = (radius + neighbor.radius) * random.range(0.9, 1.08)
                let candidate = neighbor.position + SIMD2(cos(angle), sin(angle)) * separation
                guard candidate.x >= 0, candidate.x <= Float(viewport.width),
                      candidate.y >= 0, candidate.y <= Float(viewport.height) else { continue }
                position = candidate
                break
            }
        }
        let age = fadeIn ? 0 : random.range(0, lifetime * 0.7)
        let friction = random.range(28, 85)
        let phase = random.range(0, Float.pi * 2)
        let opacity = pinned ? random.range(0.28, 0.55) : random.range(0.5, 0.78)
        let shapeStrength = max(0, min(1, (radius - 2) / 6))
        let shapeAspect = 1 + random.range(-0.015, 0.015) + random.range(-0.03, 0.14) * shapeStrength
        let shapeAsymmetry = random.range(-0.1, 0.1) * shapeStrength
        let shapePhase = random.range(-1, 1)
        let resistance = 0.55 + surfaceNoise(at: position / 56, salt: 0xA0761D6478BD642F) * 1.9
        let drift = surfaceNoise(at: position / 105, salt: 0xE7037ED1A0B428DB) * 2 - 1
        let trailBias = 0.94 + phase / (Float.pi * 2) * 0.12
        let initialWidth = max(2.2, min(9, radius * 0.65 * trailBias * 1.25))
        return Droplet(
            id: id,
            position: position,
            trailAnchor: position,
            radius: radius,
            velocity: .zero,
            mass: radius * radius * radius,
            age: age,
            lifetime: lifetime,
            friction: friction,
            pinned: pinned,
            opacity: opacity,
            birthFade: fadeIn ? 0 : 1,
            birthDelay: fadeIn ? random.range(0, 0.35) : 0,
            birthDuration: fadeIn ? random.range(0.25, 0.45) : 0.3,
            arrivalPending: fadeIn && soundEligible && radius >= 3.5 &&
                Self.pairHash(seed ^ 0xC6BC279692B5CC83, id) % 4 == 0,
            resistance: resistance,
            targetResistance: resistance,
            drift: drift,
            targetDrift: drift,
            surfaceSampleCountdown: random.range(0, 0.1),
            trailWidthAtAnchor: initialWidth,
            trailBias: trailBias,
            shapeAspect: shapeAspect,
            shapeAsymmetry: shapeAsymmetry,
            shapePhase: shapePhase
        )
    }
}
