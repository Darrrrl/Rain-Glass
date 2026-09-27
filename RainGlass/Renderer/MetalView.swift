import MetalKit
import SwiftUI

struct MetalView: NSViewRepresentable {
    let device: MTLDevice
    let diagnostics: RenderDiagnostics
    let continuousRendering: Bool

    func makeCoordinator() -> MetalRenderer {
        MetalRenderer(device: device, diagnostics: diagnostics)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.045, green: 0.055, blue: 0.075, alpha: 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
        view.isPaused = !continuousRendering
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.setDiagnosticsEnabled(continuousRendering)
        if view.isPaused == continuousRendering {
            view.isPaused = !continuousRendering
            view.needsDisplay = true
        }
    }
}
