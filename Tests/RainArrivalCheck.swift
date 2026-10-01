import Foundation

@main
struct RainArrivalCheck {
    static func main() {
        let size = CGSize(width: 1200, height: 800)
        let first = RainSimulation(seed: 314159)
        let second = RainSimulation(seed: 314159)
        first.resize(to: size)
        second.resize(to: size)
        let initialCount = first.droplets.count
        assert(initialCount > 0 && initialCount < 1_000)
        assert(first.drainArrivalEvents().isEmpty)

        var seenEvents = Set<UInt64>()
        var secondSecond = 0
        var delayedBirths = 0
        var fadingBirths = 0
        for tick in 0..<480 {
            let previous = Dictionary(uniqueKeysWithValues: first.droplets.map { ($0.id, $0.position) })
            first.step(dt: 1.0 / 120.0)
            second.step(dt: 1.0 / 120.0)
            let events = first.drainArrivalEvents()
            let matchingEvents = second.drainArrivalEvents()
            assert(events.map(\.id) == matchingEvents.map(\.id))
            for event in events {
                assert(seenEvents.insert(event.id).inserted)
                assert((0...1).contains(event.horizontalPosition))
                assert(event.position.x / Float(size.width) == event.horizontalPosition)
                assert(event.position == matchingEvents.first(where: { $0.id == event.id })?.position)
            }
            if tick == 120 { secondSecond = first.droplets.count }
            if tick < 240 { assert(events.isEmpty) }
            for drop in first.droplets {
                if drop.birthDelay > 0 { delayedBirths += 1 }
                if drop.birthFade > 0 && drop.birthFade < 1 { fadingBirths += 1 }
                if drop.birthFade < 1, let old = previous[drop.id] {
                    assert(drop.position == old)
                }
            }
            assert(first.droplets.map(\.id) == second.droplets.map(\.id))
        }
        assert(first.droplets.count > initialCount)
        assert(secondSecond > initialCount)
        assert(delayedBirths > 0 && fadingBirths > 0)
        assert(!seenEvents.isEmpty)

        let positionsBeforeResize = first.droplets.map(\.position)
        first.resize(to: CGSize(width: 2400, height: 1600))
        assert(first.droplets.count == positionsBeforeResize.count)
        for (old, drop) in zip(positionsBeforeResize, first.droplets) {
            assert(drop.position == old * 2)
        }
        assert(first.drainArrivalEvents().isEmpty)
        print("Seeded staggered arrivals, event uniqueness, fade stability, and resize checked")
    }
}
