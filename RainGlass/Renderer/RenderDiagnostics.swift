import Combine
import Foundation

struct RenderSnapshot {
    var framesPerSecond: Double = 0
    var cpuFrameMilliseconds: Double = 0
    var gpuFrameMilliseconds: Double = 0
    var renderTextureMegabytes: Double = 0
    var drawableWidth: Int = 0
    var drawableHeight: Int = 0
}

@MainActor
final class RenderDiagnostics: ObservableObject {
    @Published private(set) var snapshot = RenderSnapshot()
    @Published private(set) var errorMessage: String?

    func reportError(_ message: String) { errorMessage = message }
    func clearError() { errorMessage = nil }

    func updateGPU(_ milliseconds: Double) {
        snapshot.gpuFrameMilliseconds = milliseconds
    }

    func update(framesPerSecond: Double, cpuFrameMilliseconds: Double, gpuFrameMilliseconds: Double,
                renderTextureMegabytes: Double, drawableWidth: Int, drawableHeight: Int) {
        snapshot = RenderSnapshot(
            framesPerSecond: framesPerSecond,
            cpuFrameMilliseconds: cpuFrameMilliseconds,
            gpuFrameMilliseconds: gpuFrameMilliseconds,
            renderTextureMegabytes: renderTextureMegabytes,
            drawableWidth: drawableWidth,
            drawableHeight: drawableHeight
        )
    }

    func updateSize(width: Int, height: Int) {
        snapshot.drawableWidth = width
        snapshot.drawableHeight = height
    }
}
