import AppKit
import MetalKit
import ScreenSaver
import SwiftUI

@objc(RainGlassSaverView)
final class RainGlassSaverView: ScreenSaverView {
    private let instanceID = UUID().uuidString
    private var metalView: RainMetalView?
    private var renderer: MetalRenderer?
    private var frameView: NSHostingView<WindowFrameView>?
    private var errorLabel: NSTextField?
    private var heartbeat: Timer?
    private var transferTimer: Timer?
    private var transferScene: ScreenSaverScene?
    private var expectedChunks = 0
    private var expectedBytes = 0
    private var receivedChunks: [Data] = []
    private var transferAttempts = 0
    private var active = false

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 60 // MTKView owns the frame clock.
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func startAnimation() {
        super.startAnimation()
        guard !active else { return }
        active = true
        if !isPreview {
            announceActive()
            heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.announceActive() }
            }
        }
        do {
            let (scene, imageURL) = try ScreenSaverSceneStore.read()
            try startScene(scene: scene, imageURL: imageURL)
        } catch {
            requestSceneFromApp()
        }
    }

    override func stopAnimation() {
        active = false
        heartbeat?.invalidate()
        heartbeat = nil
        transferTimer?.invalidate()
        transferTimer = nil
        let center = DistributedNotificationCenter.default()
        center.removeObserver(self, name: ScreenSaverLifecycle.sceneResponse, object: nil)
        center.removeObserver(self, name: ScreenSaverLifecycle.chunkResponse, object: nil)
        transferScene = nil
        receivedChunks.removeAll()
        if !isPreview {
            DistributedNotificationCenter.default().post(name: ScreenSaverLifecycle.stopped,
                                                         object: instanceID)
        }
        renderer?.setManuallyPaused(true)
        metalView?.delegate = nil
        metalView?.removeFromSuperview()
        frameView?.removeFromSuperview()
        errorLabel?.removeFromSuperview()
        metalView = nil
        frameView = nil
        errorLabel = nil
        renderer = nil
        super.stopAnimation()
    }

    private func announceActive() {
        DistributedNotificationCenter.default().post(name: ScreenSaverLifecycle.active,
                                                     object: instanceID)
    }

    private func startScene(scene: ScreenSaverScene, imageURL: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
        let texture = try WallpaperDecoder.makeTexture(url: imageURL, device: device)
        let quality = isPreview ? RenderQuality.eco : (RenderQuality(rawValue: scene.quality) ?? .balanced)
        let view = RainMetalView(frame: bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.045, green: 0.055, blue: 0.075, alpha: 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = quality.targetFPS
        view.isPaused = true
        let renderer = MetalRenderer(device: device, diagnostics: RenderDiagnostics(),
                                     flashState: nil, respectsWindowOcclusion: false,
                                     libraryBundle: Bundle(for: RainGlassSaverView.self))
        view.delegate = renderer
        addSubview(view)
        renderer.setRainSeed(scene.seed.isEmpty ? String(UInt64.random(in: 0...UInt64.max)) : scene.seed, in: view)
        renderer.setSceneParameters(scene.rain, in: view)
        renderer.setQuality(quality, in: view)
        renderer.setAtmosphere(scene.atmosphere, in: view)
        renderer.setWallpaper(texture: texture, revision: 1,
                              scaleMode: WallpaperScaleMode(rawValue: scene.scaleMode) ?? .fill,
                              zoom: scene.zoom, in: view)
        renderer.observeWindow(of: view)
        renderer.setManuallyPaused(false)
        metalView = view
        self.renderer = renderer

        if scene.frame.layout != .off {
            let overlay = NSHostingView(rootView: WindowFrameView(layout: scene.frame.layout,
                                                                   thickness: scene.frame.thickness))
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay)
            frameView = overlay
        }
    }

    private func showError(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.textColor = .white
        label.alignment = .center
        label.frame = bounds.insetBy(dx: 24, dy: 24)
        label.autoresizingMask = [.width, .height]
        addSubview(label)
        errorLabel = label
    }

    private func requestSceneFromApp() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(sceneReceived(_:)),
                           name: ScreenSaverLifecycle.sceneResponse, object: instanceID)
        center.addObserver(self, selector: #selector(chunkReceived(_:)),
                           name: ScreenSaverLifecycle.chunkResponse, object: instanceID)
        sendSceneRequest()
        transferTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryTransfer() }
        }
    }

    private func sendSceneRequest() {
        DistributedNotificationCenter.default().post(name: ScreenSaverLifecycle.sceneRequest,
                                                     object: instanceID)
    }

    private func requestChunk(_ index: Int) {
        DistributedNotificationCenter.default().post(name: ScreenSaverLifecycle.chunkRequest,
                                                     object: "\(instanceID)|\(index)")
    }

    private func retryTransfer() {
        guard active else { return }
        transferAttempts += 1
        if transferAttempts > 8 {
            transferTimer?.invalidate()
            transferTimer = nil
            showError("Open RainGlass, choose a wallpaper, then preview the screen saver again.")
            return
        }
        if transferScene == nil { sendSceneRequest() }
        else { requestChunk(receivedChunks.count) }
    }

    @objc private func sceneReceived(_ notification: Notification) {
        guard active, transferScene == nil, let info = notification.userInfo,
              let data = info["scene"] as? Data,
              let count = info["chunks"] as? Int,
              let size = info["size"] as? Int,
              count > 0, count <= 800, size > 0, size <= 50 * 1024 * 1024,
              let scene = try? JSONDecoder().decode(ScreenSaverScene.self, from: data),
              scene.version == 1 else { return }
        transferScene = scene
        expectedChunks = count
        expectedBytes = size
        receivedChunks.removeAll(keepingCapacity: true)
        transferAttempts = 0
        requestChunk(0)
    }

    @objc private func chunkReceived(_ notification: Notification) {
        guard active, transferScene != nil, let info = notification.userInfo,
              let index = info["index"] as? Int, index == receivedChunks.count,
              let bytes = info["bytes"] as? Data, !bytes.isEmpty, bytes.count <= 64 * 1024 else { return }
        receivedChunks.append(bytes)
        transferAttempts = 0
        if receivedChunks.count < expectedChunks {
            requestChunk(receivedChunks.count)
            return
        }
        guard let scene = transferScene else { return }
        let image = receivedChunks.reduce(into: Data(capacity: expectedBytes)) { $0.append($1) }
        guard image.count == expectedBytes else { return }
        transferTimer?.invalidate()
        transferTimer = nil
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RainGlass-\(instanceID).\((scene.wallpaperFileName as NSString).pathExtension)")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try image.write(to: file, options: .atomic)
            try startScene(scene: scene, imageURL: file)
        } catch {
            showError("RainGlass could not render the chosen wallpaper. Choose another image in the app.")
        }
        transferScene = nil
        receivedChunks.removeAll()
    }
}
