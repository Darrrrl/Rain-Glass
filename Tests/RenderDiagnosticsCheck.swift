import Combine
import Foundation

@main
@MainActor
struct RenderDiagnosticsCheck {
    static func main() async {
        let diagnostics = RenderDiagnostics()
        var updatingView = false
        var deliveredDuringUpdate = false
        var updates = 0
        let observation = diagnostics.$snapshot.dropFirst().sink { snapshot in
            deliveredDuringUpdate = deliveredDuringUpdate || updatingView
            updates += 1
        }
        updatingView = true
        diagnostics.updateSize(width: 320, height: 220)
        diagnostics.updateGPU(1.25)
        diagnostics.update(framesPerSecond: 30, cpuFrameMilliseconds: 2,
                           renderTextureMegabytes: 4, drawableWidth: 320, drawableHeight: 220)
        assert(updates == 0, "Diagnostics must not publish inside a view update")
        updatingView = false
        try? await Task.sleep(for: .milliseconds(50))
        assert(!deliveredDuringUpdate && updates == 1)
        assert(diagnostics.snapshot.drawableWidth == 320)
        assert(diagnostics.snapshot.gpuFrameMilliseconds == 1.25)
        assert(diagnostics.snapshot.framesPerSecond == 30)
        observation.cancel()
        print("Render diagnostics defer and coalesce view-update notifications")
    }
}
