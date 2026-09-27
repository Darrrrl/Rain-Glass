import Combine
import Foundation

struct RenderSnapshot {
    var framesPerSecond: Double = 0
    var cpuFrameMilliseconds: Double = 0
    var drawableWidth: Int = 0
    var drawableHeight: Int = 0
}

@MainActor
final class RenderDiagnostics: ObservableObject {
    @Published private(set) var snapshot = RenderSnapshot()

    func update(framesPerSecond: Double, cpuFrameMilliseconds: Double, drawableWidth: Int, drawableHeight: Int) {
        snapshot = RenderSnapshot(
            framesPerSecond: framesPerSecond,
            cpuFrameMilliseconds: cpuFrameMilliseconds,
            drawableWidth: drawableWidth,
            drawableHeight: drawableHeight
        )
    }

    func updateSize(width: Int, height: Int) {
        snapshot.drawableWidth = width
        snapshot.drawableHeight = height
    }
}
