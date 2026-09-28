import MetalKit
import SwiftUI

struct MetalView: NSViewRepresentable {
    let device: MTLDevice
    let diagnostics: RenderDiagnostics
    let diagnosticsEnabled: Bool
    let wallpaperTexture: MTLTexture?
    let wallpaperRevision: Int
    let scaleMode: WallpaperScaleMode
    let parameters: RainParameters
    let flashState: LightningFlashState?
    let rainSeed: String

    func makeCoordinator() -> MetalRenderer {
        MetalRenderer(device: device, diagnostics: diagnostics, flashState: flashState)
    }

    func makeNSView(context: Context) -> RainMetalView {
        let view = RainMetalView(frame: .zero, device: device)
        view.delegate = context.coordinator
        view.windowChanged = { [weak renderer = context.coordinator] view in
            renderer?.observeWindow(of: view)
        }
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.045, green: 0.055, blue: 0.075, alpha: 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.isPaused = true
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ view: RainMetalView, context: Context) {
        context.coordinator.setFlashState(flashState)
        context.coordinator.setDiagnosticsEnabled(diagnosticsEnabled)
        context.coordinator.setRainSeed(rainSeed, in: view)
        context.coordinator.setSceneParameters(parameters, in: view)
        context.coordinator.setWallpaper(
            texture: wallpaperTexture,
            revision: wallpaperRevision,
            scaleMode: scaleMode,
            in: view
        )
        context.coordinator.observeWindow(of: view)
    }
}

final class RainMetalView: MTKView {
    var windowChanged: ((RainMetalView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(self)
    }
}
