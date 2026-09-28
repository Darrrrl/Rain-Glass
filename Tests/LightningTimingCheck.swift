import Foundation

@main
struct LightningTimingCheck {
    static func main() {
        let near = LightningEvent(startedAt: 100, distanceMeters: 343, pan: -0.25)
        let far = LightningEvent(startedAt: 100, distanceMeters: 3_430, pan: 0.25)
        assert(abs(near.thunderAt - 101) < 0.0001)
        assert(abs(far.thunderAt - 110) < 0.0001)
        assert(near.exposure(at: 100) > 0)
        assert(near.exposure(at: 100.05) > far.exposure(at: 100.05))
        assert(near.exposure(at: 99.9) == 0)
        assert(near.exposure(at: 101) == 0)
        let state = LightningFlashState()
        state.emit(near)
        assert(state.exposure(at: 100.05) == near.exposure(at: 100.05))
        print("Lightning flash and thunder timing valid")
    }
}
