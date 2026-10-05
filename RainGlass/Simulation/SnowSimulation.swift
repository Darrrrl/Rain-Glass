import Foundation

/// Normalized coordinates keep flakes stable when a display resizes. The caller owns the fixed-step clock.
struct SnowParticle: Equatable {
    var position: SIMD2<Float>
    var phase: Float
    var variation: Float
    var layer: Int
    var opacity: Float = 0
    var contactY: Float = 0
    var contactEligible = false
}

struct SnowRenderInstance {
    var geometry: SIMD4<Float> // normalized center, radius in points, opacity
    var style: SIMD4<Float> = .zero // contact flag, seed, arm count, unused
}

struct SnowContact: Equatable {
    var position: SIMD2<Float>
    var age: Float
    var duration: Float
    var seed: Float
    var arms: Float
}

final class SnowSimulation {
    static let maximumParticles = 1_500
    private(set) var particles: [SnowParticle] = []
    private(set) var contacts: [SnowContact] = []
    static let maximumContacts = 12
    private(set) var settings = SnowSettings()
    private var randomState: UInt64
    private var limit = 900
    private var viewport = SIMD2<Float>(1440, 900)

    init(seed: UInt64) { randomState = seed }

    func reset(seed: UInt64) {
        randomState = seed
        particles.removeAll()
        contacts.removeAll()
    }

    func configure(_ settings: SnowSettings, limit: Int, size: CGSize) {
        self.settings = settings.clamped()
        self.limit = max(0, min(Self.maximumParticles, limit))
        viewport = SIMD2(max(1, Float(size.width)), max(1, Float(size.height)))
    }

    private func random() -> Float {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Float(randomState >> 40) / Float(1 << 24)
    }

    private func contactPoint(for layer: Int) -> (Float, Bool) {
        let y = 0.12 + random() * 0.76
        let eligible = random() < 0.28 && layer == 2
        return (y, eligible)
    }

    func step(dt: Float) {
        guard dt > 0, dt.isFinite else { return }
        let dt = min(dt, 1 / 30)
        let target = Int((settings.amount * Double(limit)).rounded())
        while particles.count < target {
            let index = particles.count
            let position = SIMD2(random(), random())
            let phase = random() * .pi * 2
            let variation = 0.7 + random() * 0.6
            let contact = contactPoint(for: index % 3)
            particles.append(SnowParticle(position: position, phase: phase,
                                          variation: variation, layer: index % 3,
                                          contactY: contact.0, contactEligible: contact.1))
        }
        for index in contacts.indices { contacts[index].age += dt }
        contacts.removeAll { $0.age >= $0.duration }
        for index in particles.indices {
            let desired: Float = index < target ? 1 : 0
            particles[index].opacity += max(-dt * 0.8, min(dt * 0.8, desired - particles[index].opacity))
            let depth = Float(particles[index].layer)
            particles[index].phase += dt * (0.35 + depth * 0.1)
            let velocity = SIMD2<Float>(Float(settings.wind) * (24 + depth * 14) +
                                        sin(particles[index].phase) * (5 + depth * 3),
                                        (16 + depth * 17) * Float(settings.speed) * particles[index].variation)
            let previousY = particles[index].position.y
            particles[index].position += velocity * dt / viewport
            if desired > 0, particles[index].contactEligible,
               previousY < particles[index].contactY,
               particles[index].position.y >= particles[index].contactY,
               contacts.count < Self.maximumContacts {
                contacts.append(SnowContact(position: SIMD2(max(0, min(1, particles[index].position.x)), particles[index].contactY),
                    age: 0, duration: 0.65 + random() * 0.3, seed: random(), arms: Float(3 + Int(random() * 5))))
                particles[index].contactEligible = false
            }
            if particles[index].position.y > 1.02 {
                particles[index].position.y = -0.02
                let contact = contactPoint(for: particles[index].layer)
                particles[index].contactY = contact.0
                particles[index].contactEligible = contact.1
            }
            if particles[index].position.x > 1.02 { particles[index].position.x = -0.02 }
            if particles[index].position.x < -0.02 { particles[index].position.x = 1.02 }
        }
        // Only remove from the tail so density changes preserve identities and layer assignments.
        while particles.count > target, particles.last!.opacity <= 0 { particles.removeLast() }
        if target == 0 && particles.isEmpty { contacts.removeAll() }
    }

    func renderInstances(into result: inout [SnowRenderInstance]) {
        result.removeAll(keepingCapacity: true)
        for particle in particles {
            let depth = Float(particle.layer)
            let radius = (3.6 + depth * 1.6) * Float(settings.flakeSize) * particle.variation
            let opacity = particle.opacity * (0.08 + depth * 0.035)
            result.append(SnowRenderInstance(geometry: SIMD4(particle.position.x, particle.position.y, radius, opacity)))
        }
    }

    func renderContacts(into result: inout [SnowRenderInstance]) {
        result.removeAll(keepingCapacity: true)
        for contact in contacts {
            let life = contact.age / contact.duration
            let opacity = min(1, contact.age / 0.12) * (1 - life) * 0.23
            result.append(SnowRenderInstance(
                geometry: SIMD4(contact.position.x, contact.position.y,
                                (6.0 + contact.seed * 3.0) * Float(settings.flakeSize), opacity),
                style: SIMD4(1, contact.seed, contact.arms, 0)))
        }
    }
}
