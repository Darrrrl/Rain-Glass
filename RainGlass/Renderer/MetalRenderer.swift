import Foundation
import MetalKit

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue?
    private let diagnostics: RenderDiagnostics
    private var diagnosticsEnabled = false
    private var sampleStart: CFAbsoluteTime = 0
    private var sampleFrames = 0
    private var sampleCPUSeconds = 0.0

    init(device: MTLDevice, diagnostics: RenderDiagnostics) {
        commandQueue = device.makeCommandQueue()
        self.diagnostics = diagnostics
        super.init()
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        guard diagnosticsEnabled != enabled else { return }
        diagnosticsEnabled = enabled
        sampleStart = 0
        sampleFrames = 0
        sampleCPUSeconds = 0
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        diagnostics.updateSize(width: Int(size.width), height: Int(size.height))
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        let start = CFAbsoluteTimeGetCurrent()
        guard let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        guard diagnosticsEnabled else { return }
        sampleFrames += 1
        sampleCPUSeconds += CFAbsoluteTimeGetCurrent() - start
        if sampleStart == 0 { sampleStart = start }
        let elapsed = start - sampleStart
        guard elapsed >= 1 else { return }

        diagnostics.update(
            framesPerSecond: Double(sampleFrames) / elapsed,
            cpuFrameMilliseconds: sampleCPUSeconds * 1_000 / Double(sampleFrames),
            drawableWidth: Int(view.drawableSize.width),
            drawableHeight: Int(view.drawableSize.height)
        )
        sampleStart = start
        sampleFrames = 0
        sampleCPUSeconds = 0
    }
}
