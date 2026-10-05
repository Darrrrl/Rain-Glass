import MetalKit
import SwiftUI

struct MetalView: NSViewRepresentable {
    let device: MTLDevice
    let diagnostics: RenderDiagnostics
    let diagnosticsEnabled: Bool
    let wallpaperTexture: MTLTexture?
    let wallpaperRevision: Int
    let scaleMode: WallpaperScaleMode
    let zoom: Double
    let parameters: RainParameters
    let flashState: LightningFlashState?
    let rainSeed: String
    let quality: RenderQuality
    let atmosphere: AtmosphereSettings
    let manuallyPaused: Bool
    var snow: SnowSettings = .init()
    var frost: FrostSettings = .init()
    var frame: WindowFrameSettings = .init()
    var onArrivals: (@MainActor @Sendable ([(id: UInt64, radius: Float, x: Float)], UUID) -> Void)? = nil

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
        // A paused desktop still needs one drawable for its wallpaper and later scene edits.
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = quality.targetFPS
        view.isPaused = true
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ view: RainMetalView, context: Context) {
        context.coordinator.setFlashState(flashState)
        context.coordinator.setArrivalHandler(handler: onArrivals)
        context.coordinator.setDiagnosticsEnabled(diagnosticsEnabled)
        context.coordinator.setRainSeed(rainSeed, in: view)
        context.coordinator.setSceneParameters(parameters, in: view)
        context.coordinator.setQuality(quality, in: view)
        context.coordinator.setAtmosphere(atmosphere, in: view)
        context.coordinator.setWinter(snow: snow, frost: frost, frame: frame, in: view)
        context.coordinator.setWallpaper(
            texture: wallpaperTexture,
            revision: wallpaperRevision,
            scaleMode: scaleMode,
            zoom: zoom,
            in: view
        )
        context.coordinator.observeWindow(of: view)
        context.coordinator.setManuallyPaused(manuallyPaused)
    }
}

final class RainMetalView: MTKView {
    var windowChanged: ((RainMetalView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(self)
    }
}
