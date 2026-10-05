import Foundation

@main
struct SnowSimulationCheck {
    static func main() {
        let a = SnowSimulation(seed: 42)
        let b = SnowSimulation(seed: 42)
        let settings = SnowSettings(amount: 0.6, flakeSize: 1.2, speed: 0.8, wind: -0.4)
        for sim in [a, b] {
            sim.configure(settings, limit: 900, size: CGSize(width: 1440, height: 900))
            for _ in 0..<600 { sim.step(dt: 1 / 120) }
        }
        assert(a.particles == b.particles)
        assert(a.contacts == b.contacts)
        assert(a.particles.count == 540)
        assert(Set(a.particles.map(\.layer)) == Set([0, 1, 2]))
        let before = a.particles
        a.step(dt: 0)
        assert(a.particles == before, "A paused clock must preserve the scene")
        let pausedContacts = a.contacts
        a.step(dt: 0)
        assert(a.contacts == pausedContacts)
        a.configure(settings, limit: 900, size: CGSize(width: 900, height: 1440))
        assert(a.particles == before, "Resize must preserve normalized positions")
        a.step(dt: 1 / 120)
        assert(a.particles != before)
        assert(a.particles.allSatisfy { (-0.02...1.02).contains($0.position.x) && (-0.02...1.02).contains($0.position.y) })
        assert(a.contacts.count <= SnowSimulation.maximumContacts)
        assert(a.contacts.allSatisfy { (0...1).contains($0.position.x) && (0...1).contains($0.position.y) && $0.duration <= 1 })
        let rate = SnowSimulation(seed: 42)
        rate.configure(SnowSettings(amount: 0.35), limit: 900, size: CGSize(width: 1440, height: 900))
        var events = 0
        for _ in 0..<(120 * 120) {
            rate.step(dt: 1 / 120)
            events += rate.contacts.filter { $0.age == 0 }.count
            assert(rate.contacts.count <= SnowSimulation.maximumContacts)
        }
        assert((1.0...3.0).contains(Double(events) / 120), "Moderate snow should make sparse contacts")
        a.configure(SnowSettings(amount: 1), limit: Int.max, size: CGSize(width: 0, height: 0))
        for _ in 0..<240 { a.step(dt: 1 / 120) }
        assert(a.particles.count == SnowSimulation.maximumParticles)
        a.configure(.init(), limit: 450, size: CGSize(width: 1920, height: 1080))
        a.step(dt: 1 / 120)
        assert(!a.particles.isEmpty, "Turning snow off must fade rather than pop")
        for _ in 0..<240 { a.step(dt: 1 / 120) }
        assert(a.particles.isEmpty)
        assert(a.contacts.isEmpty)
        a.reset(seed: 42)
        a.configure(settings, limit: 900, size: CGSize(width: 1440, height: 900))
        for _ in 0..<600 { a.step(dt: 1 / 120) }
        assert(a.particles == b.particles)
        assert(!SnowSettings(amount: .nan).isValid)
        assert(!FrostSettings(coverage: .infinity).isValid)
        print("Snow determinism, contacts (\(events) in 120 s), bounds, pause, resize, fade-out and seed reset checked")
    }
}
