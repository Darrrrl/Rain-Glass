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
    private var nextSnapshot = RenderSnapshot()
    private var publishScheduled = false

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            self.snapshot = self.nextSnapshot
        }
    }

    func reportError(_ message: String) { errorMessage = message }
    func clearError() { errorMessage = nil }

    func updateGPU(_ milliseconds: Double) {
        nextSnapshot.gpuFrameMilliseconds = milliseconds
        schedulePublish()
    }

    func update(framesPerSecond: Double, cpuFrameMilliseconds: Double,
                renderTextureMegabytes: Double, drawableWidth: Int, drawableHeight: Int) {
        nextSnapshot = RenderSnapshot(
            framesPerSecond: framesPerSecond,
            cpuFrameMilliseconds: cpuFrameMilliseconds,
            gpuFrameMilliseconds: nextSnapshot.gpuFrameMilliseconds,
            renderTextureMegabytes: renderTextureMegabytes,
            drawableWidth: drawableWidth,
            drawableHeight: drawableHeight
        )
        schedulePublish()
    }

    func updateSize(width: Int, height: Int) {
        nextSnapshot.drawableWidth = width
        nextSnapshot.drawableHeight = height
        schedulePublish()
    }
}
