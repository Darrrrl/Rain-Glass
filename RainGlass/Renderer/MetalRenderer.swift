import Foundation
import MetalKit
import MetalPerformanceShaders
import OSLog

private struct WallpaperUniforms {
    var viewportSize: SIMD2<Float>
    var imageSize: SIMD2<Float>
    var scaleMode: UInt32
    var zoom: Float
}

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let log = Logger(subsystem: "dev.rainglass.app", category: "renderer")
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let wallpaperPipeline: MTLRenderPipelineState?
    private let displayPipeline: MTLRenderPipelineState?
    private let dropletPipeline: MTLRenderPipelineState?
    private let trailPipeline: MTLRenderPipelineState?
    private let waterDropletPipeline: MTLRenderPipelineState?
    private let waterTrailPipeline: MTLRenderPipelineState?
    private let fogWipeDropletPipeline: MTLRenderPipelineState?
    private let fogWipeTrailPipeline: MTLRenderPipelineState?
    private let wetGlassPipeline: MTLRenderPipelineState?
    private let fogPipeline: MTLComputePipelineState?
    private let winter: WinterRenderer
    private let sampler: MTLSamplerState?
    private let diagnostics: RenderDiagnostics
    private var flashState: LightningFlashState?
    private let simulation = RainSimulation(seed: UInt64.random(in: UInt64.min...UInt64.max))
    private var rainSeed = ""
    private let audioSourceID = UUID()
    private var onArrivals: (@MainActor @Sendable ([(id: UInt64, radius: Float, x: Float)], UUID) -> Void)?
    private var lastFrameTime: CFAbsoluteTime = 0
    private var simulationAccumulator: Float = 0
    private var renderInstances: [DropletRenderInstance] = []
    private var trailInstances: [TrailRenderInstance] = []
    private var wipeInstances: [TrailRenderInstance] = []
    private var previousDropPositions: [UInt64: SIMD2<Float>] = [:]
    private var instanceBuffers: [MTLBuffer] = []
    private var trailBuffers: [MTLBuffer] = []
    private var nextInstanceBuffer = 0
    private let framesInFlight = DispatchSemaphore(value: 3)
    private weak var observedWindow: NSWindow?
    private weak var observedView: RainMetalView?
    private let respectsWindowOcclusion: Bool

    private var wallpaperTexture: MTLTexture?
    private var wallpaperRevision = -1
    private var scaleMode: WallpaperScaleMode = .fill
    private var wallpaperZoom: Float = 1
    private var blurRadius = 2.0
    private var targetBlurRadius = 2.0
    private var backgroundDirty = true
    private var sharpBackground: MTLTexture?
    private var blurredBackground: MTLTexture?
    private var foggedBackground: MTLTexture?
    private var waterHeight: MTLTexture?
    private var fogDensity: MTLTexture?
    private var fogNext: MTLTexture?
    private var fogWipe: MTLTexture?
    private var quality: RenderQuality = .balanced
    private var atmosphere = AtmosphereSettings()
    private var targetAtmosphere = AtmosphereSettings()
    private var refractionStrength: Float = 0.65

    private var diagnosticsEnabled = false
    private var sampleStart: CFAbsoluteTime = 0
    private var sampleFrames = 0
    private var sampleCPUSeconds = 0.0

    init(device: MTLDevice, diagnostics: RenderDiagnostics, flashState: LightningFlashState?,
         respectsWindowOcclusion: Bool = true, libraryBundle: Bundle = .main) {
        self.device = device
        self.flashState = flashState
        self.respectsWindowOcclusion = respectsWindowOcclusion
        commandQueue = device.makeCommandQueue()
        self.diagnostics = diagnostics

        let library = try? device.makeDefaultLibrary(bundle: libraryBundle)
        winter = WinterRenderer(device: device, library: library, seed: UInt64.random(in: 0...UInt64.max))
        let wallpaperDescriptor = MTLRenderPipelineDescriptor()
        wallpaperDescriptor.vertexFunction = library?.makeFunction(name: "fullscreenVertex")
        wallpaperDescriptor.fragmentFunction = library?.makeFunction(name: "wallpaperFragment")
        wallpaperDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        wallpaperPipeline = try? device.makeRenderPipelineState(descriptor: wallpaperDescriptor)

        let displayDescriptor = MTLRenderPipelineDescriptor()
        displayDescriptor.vertexFunction = library?.makeFunction(name: "fullscreenVertex")
        displayDescriptor.fragmentFunction = library?.makeFunction(name: "displayBackgroundFragment")
        displayDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        displayPipeline = try? device.makeRenderPipelineState(descriptor: displayDescriptor)

        let dropletDescriptor = MTLRenderPipelineDescriptor()
        dropletDescriptor.vertexFunction = library?.makeFunction(name: "dropletVertex")
        dropletDescriptor.fragmentFunction = library?.makeFunction(name: "dropletFragment")
        dropletDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        dropletDescriptor.colorAttachments[0].isBlendingEnabled = true
        dropletDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        dropletDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        dropletDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        dropletDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        dropletPipeline = try? device.makeRenderPipelineState(descriptor: dropletDescriptor)
        let trailDescriptor = MTLRenderPipelineDescriptor()
        trailDescriptor.vertexFunction = library?.makeFunction(name: "trailVertex")
        trailDescriptor.fragmentFunction = library?.makeFunction(name: "trailFragment")
        trailDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        trailDescriptor.colorAttachments[0].isBlendingEnabled = true
        trailDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        trailDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        trailPipeline = try? device.makeRenderPipelineState(descriptor: trailDescriptor)

        let waterDropletDescriptor = MTLRenderPipelineDescriptor()
        waterDropletDescriptor.vertexFunction = library?.makeFunction(name: "dropletVertex")
        waterDropletDescriptor.fragmentFunction = library?.makeFunction(name: "waterDropletFragment")
        waterDropletDescriptor.colorAttachments[0].pixelFormat = .r16Float
        waterDropletDescriptor.colorAttachments[0].isBlendingEnabled = true
        waterDropletDescriptor.colorAttachments[0].rgbBlendOperation = .max
        waterDropletDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        waterDropletDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        waterDropletPipeline = try? device.makeRenderPipelineState(descriptor: waterDropletDescriptor)

        let waterTrailDescriptor = MTLRenderPipelineDescriptor()
        waterTrailDescriptor.vertexFunction = library?.makeFunction(name: "trailVertex")
        waterTrailDescriptor.fragmentFunction = library?.makeFunction(name: "waterTrailFragment")
        waterTrailDescriptor.colorAttachments[0].pixelFormat = .r16Float
        waterTrailDescriptor.colorAttachments[0].isBlendingEnabled = true
        waterTrailDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        waterTrailDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        waterTrailPipeline = try? device.makeRenderPipelineState(descriptor: waterTrailDescriptor)

        let wipeDropDescriptor = MTLRenderPipelineDescriptor()
        wipeDropDescriptor.vertexFunction = library?.makeFunction(name: "dropletVertex")
        wipeDropDescriptor.fragmentFunction = library?.makeFunction(name: "fogWipeDropletFragment")
        wipeDropDescriptor.colorAttachments[0].pixelFormat = .r8Unorm
        wipeDropDescriptor.colorAttachments[0].isBlendingEnabled = true
        wipeDropDescriptor.colorAttachments[0].rgbBlendOperation = .max
        wipeDropDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        wipeDropDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        fogWipeDropletPipeline = try? device.makeRenderPipelineState(descriptor: wipeDropDescriptor)

        let wipeTrailDescriptor = MTLRenderPipelineDescriptor()
        wipeTrailDescriptor.vertexFunction = library?.makeFunction(name: "trailVertex")
        wipeTrailDescriptor.fragmentFunction = library?.makeFunction(name: "fogWipeTrailFragment")
        wipeTrailDescriptor.colorAttachments[0].pixelFormat = .r8Unorm
        wipeTrailDescriptor.colorAttachments[0].isBlendingEnabled = true
        wipeTrailDescriptor.colorAttachments[0].rgbBlendOperation = .max
        wipeTrailDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        wipeTrailDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        fogWipeTrailPipeline = try? device.makeRenderPipelineState(descriptor: wipeTrailDescriptor)

        let wetGlassDescriptor = MTLRenderPipelineDescriptor()
        wetGlassDescriptor.vertexFunction = library?.makeFunction(name: "fullscreenVertex")
        wetGlassDescriptor.fragmentFunction = library?.makeFunction(name: "wetGlassFragment")
        wetGlassDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        wetGlassPipeline = try? device.makeRenderPipelineState(descriptor: wetGlassDescriptor)
        fogPipeline = library?.makeFunction(name: "fogEvolutionKernel").flatMap { try? device.makeComputePipelineState(function: $0) }
        let bufferLength = 6_000 * MemoryLayout<DropletRenderInstance>.stride
        instanceBuffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: bufferLength, options: .storageModeShared)
        }
        let trailLength = (RainSimulation.maximumTrails + RainSimulation.maximumBridges +
                           RainSimulation.maximumDroplets * 2) *
            MemoryLayout<TrailRenderInstance>.stride
        trailBuffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: trailLength, options: .storageModeShared)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        super.init()
        if commandQueue == nil || wallpaperPipeline == nil || displayPipeline == nil ||
            waterDropletPipeline == nil || waterTrailPipeline == nil || fogWipeDropletPipeline == nil ||
            fogWipeTrailPipeline == nil || wetGlassPipeline == nil || fogPipeline == nil ||
            sampler == nil || !winter.available {
            log.error("Metal pipeline or command queue creation failed")
            Task { @MainActor in diagnostics.reportError("The renderer could not start. Try restarting RainGlass.") }
        }
    }

    deinit {
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow)
        }
    }

    @MainActor
    func setRainSeed(_ raw: String, in view: MTKView) {
        guard raw.isEmpty || UInt64(raw) != nil else { return }
        guard rainSeed != raw else { return }
        rainSeed = raw
        let seed = UInt64(raw) ?? UInt64.random(in: UInt64.min...UInt64.max)
        simulation.reset(seed: seed)
        winter.reset(seed: seed)
        previousDropPositions.removeAll(keepingCapacity: true)
        fogDensity = nil
        fogNext = nil
        simulationAccumulator = 0
        lastFrameTime = 0
        view.needsDisplay = true
    }

    @MainActor
    func observeWindow(of view: RainMetalView) {
        guard observedWindow !== view.window || observedView !== view else { return }
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow)
        }
        observedWindow = view.window
        observedView = view
        if let window = view.window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionChanged(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updatePauseState()
    }

    @MainActor
    @objc private func windowOcclusionChanged(_ notification: Notification) {
        updatePauseState()
    }

    @MainActor
    private func updatePauseState() {
        guard let view = observedView else { return }
        let visible = !respectsWindowOcclusion || view.window?.occlusionState.contains(.visible) == true
        view.isPaused = !visible || manuallyPaused
        if visible {
            lastFrameTime = 0
            view.needsDisplay = true
        }
    }

    private var manuallyPaused = false

    @MainActor
    func setManuallyPaused(_ value: Bool) {
        guard manuallyPaused != value else { return }
        manuallyPaused = value
        updatePauseState()
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        guard diagnosticsEnabled != enabled else { return }
        diagnosticsEnabled = enabled
        sampleStart = 0
        sampleFrames = 0
        sampleCPUSeconds = 0
    }

    @MainActor
    func setFlashState(_ state: LightningFlashState?) {
        flashState = state
    }

    @MainActor
    func setArrivalHandler(
        handler: (@MainActor @Sendable ([(id: UInt64, radius: Float, x: Float)], UUID) -> Void)?) {
        onArrivals = handler
    }

    @MainActor
    func setSceneParameters(_ parameters: RainParameters, in view: MTKView) {
        simulation.setParameters(parameters)
        targetBlurRadius = parameters.blur
        view.needsDisplay = true
    }

    @MainActor
    func setQuality(_ value: RenderQuality, in view: MTKView) {
        guard quality != value else { return }
        quality = value
        view.preferredFramesPerSecond = min(value.targetFPS, view.window?.screen?.maximumFramesPerSecond ?? value.targetFPS)
        waterHeight = nil
        fogNext = nil
        fogWipe = nil
        backgroundDirty = true
        view.needsDisplay = true
    }

    @MainActor
    func setAtmosphere(_ value: AtmosphereSettings, in view: MTKView) {
        guard targetAtmosphere != value else { return }
        targetAtmosphere = value
        view.needsDisplay = true
    }

    @MainActor
    func setWinter(snow: SnowSettings, frost: FrostSettings, frame: WindowFrameSettings, in view: MTKView) {
        winter.configure(snow: snow, frost: frost, frame: frame)
        view.needsDisplay = true
    }

    @MainActor
    func setWallpaper(texture: MTLTexture?, revision: Int, scaleMode: WallpaperScaleMode,
                      zoom: Double, in view: MTKView) {
        let newZoom = Float(min(3, max(1, zoom)))
        guard wallpaperRevision != revision || self.scaleMode != scaleMode || wallpaperZoom != newZoom else { return }
        wallpaperTexture = texture
        wallpaperRevision = revision
        self.scaleMode = scaleMode
        wallpaperZoom = newZoom
        backgroundDirty = true
        view.needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        diagnostics.updateSize(width: Int(size.width), height: Int(size.height))
        backgroundDirty = true
        previousDropPositions.removeAll(keepingCapacity: true)
        simulation.resize(to: view.bounds.size)
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        let start = CFAbsoluteTimeGetCurrent()
        let frameElapsed = manuallyPaused || lastFrameTime == 0 ? 0 : min(0.1, start - lastFrameTime)
        lastFrameTime = start
        let atmosphereFraction = min(1, frameElapsed / 0.6)
        func approach(_ current: Double, _ target: Double) -> Double {
            abs(current - target) < 0.002 ? target : current + (target - current) * atmosphereFraction
        }
        atmosphere.condensation = approach(atmosphere.condensation, targetAtmosphere.condensation)
        atmosphere.haze = approach(atmosphere.haze, targetAtmosphere.haze)
        atmosphere.imperfections = approach(atmosphere.imperfections, targetAtmosphere.imperfections)
        atmosphere.fogSoftness = approach(atmosphere.fogSoftness, targetAtmosphere.fogSoftness)
        atmosphere.fogReturnTime = approach(atmosphere.fogReturnTime, targetAtmosphere.fogReturnTime)
        simulation.resize(to: view.bounds.size)
        winter.prepare(quality: quality, size: view.bounds.size)
        simulationAccumulator += Float(frameElapsed)
        let fixedStep: Float = quality == .eco ? 1.0 / 60.0 : 1.0 / 120.0
        var steps = 0
        while simulationAccumulator >= fixedStep && steps < 4 {
            simulation.step(dt: fixedStep)
            winter.step(dt: fixedStep)
            simulationAccumulator -= fixedStep
            steps += 1
        }
        if steps == 4 { simulationAccumulator = 0 }
        let arrivals = simulation.drainArrivalEvents()
        if !arrivals.isEmpty, view.window?.occlusionState.contains(.visible) == true,
           !manuallyPaused, let onArrivals {
            let cues = arrivals.map { (id: $0.id, radius: $0.radius, x: $0.horizontalPosition) }
            let sourceID = audioSourceID
            Task { @MainActor in onArrivals(cues, sourceID) }
        }
        let desiredBlur = simulation.currentParameters.blur
        if abs(desiredBlur - blurRadius) >= 0.4 ||
            (abs(desiredBlur - blurRadius) > 0.02 && abs(desiredBlur - targetBlurRadius) < 0.03) {
            blurRadius = desiredBlur
            backgroundDirty = true
        }
        refractionStrength = Float(simulation.currentParameters.refraction)
        guard let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        if width > 0, height > 0, let wallpaperTexture {
            updateBackgroundIfNeeded(texture: wallpaperTexture, width: width, height: height, commandBuffer: commandBuffer)
        }

        winter.encode(commandBuffer: commandBuffer, width: width, height: height, points: view.bounds.size)

        let waterWidth = max(1, (width + quality.waterScale - 1) / quality.waterScale)
        let waterHeightPixels = max(1, (height + quality.waterScale - 1) / quality.waterScale)
        if waterHeight?.width != waterWidth || waterHeight?.height != waterHeightPixels {
            let waterDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float, width: waterWidth, height: waterHeightPixels, mipmapped: false
            )
            waterDescriptor.usage = [.renderTarget, .shaderRead]
            waterDescriptor.storageMode = .private
            waterHeight = device.makeTexture(descriptor: waterDescriptor)
        }

        let useFog = atmosphere.condensation > 0.001 || atmosphere.haze > 0.001 ||
            atmosphere.imperfections > 0.001
        if useFog {
            let fogWidth = max(1, (width + quality.atmosphereScale - 1) / quality.atmosphereScale)
            let fogHeight = max(1, (height + quality.atmosphereScale - 1) / quality.atmosphereScale)
            if fogWipe?.width != fogWidth || fogWipe?.height != fogHeight {
                let fogDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r8Unorm, width: fogWidth, height: fogHeight, mipmapped: false)
                fogDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
                fogDescriptor.storageMode = .private
                fogWipe = device.makeTexture(descriptor: fogDescriptor)
                fogNext = device.makeTexture(descriptor: fogDescriptor)
            } else if fogNext?.width != fogWidth || fogNext?.height != fogHeight {
                let fogDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r8Unorm, width: fogWidth, height: fogHeight, mipmapped: false)
                fogDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
                fogDescriptor.storageMode = .private
                fogNext = device.makeTexture(descriptor: fogDescriptor)
            }
        } else {
            fogDensity = nil
            fogNext = nil
            fogWipe = nil
        }

        simulation.renderInstances(into: &renderInstances)
        simulation.trailInstances(into: &trailInstances)
        wipeInstances.removeAll(keepingCapacity: true)
        if useFog {
            for drop in simulation.droplets where !drop.pinned {
                guard let previous = previousDropPositions[drop.id],
                      simd_distance_squared(previous, drop.position) > 0.01 else { continue }
                let width = simulation.trailWidth(for: drop) * 1.55
                wipeInstances.append(TrailRenderInstance(
                    startEnd: SIMD4(previous.x, previous.y, drop.position.x, drop.position.y),
                    appearance: SIMD4(width, width, drop.birthFade, 1),
                    style: .zero
                ))
            }
        }
        previousDropPositions = Dictionary(uniqueKeysWithValues: simulation.droplets.map { ($0.id, $0.position) })
        var dropBuffer: MTLBuffer?
        var trailBuffer: MTLBuffer?
        if (!renderInstances.isEmpty || !trailInstances.isEmpty), instanceBuffers.count == 3, trailBuffers.count == 3 {
            framesInFlight.wait()
            dropBuffer = instanceBuffers[nextInstanceBuffer]
            trailBuffer = trailBuffers[nextInstanceBuffer]
            nextInstanceBuffer = (nextInstanceBuffer + 1) % 3
            if !renderInstances.isEmpty {
                renderInstances.withUnsafeBytes { source in
                    dropBuffer!.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
            if !trailInstances.isEmpty {
                trailInstances.withUnsafeBytes { source in
                    trailBuffer!.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
            if !wipeInstances.isEmpty {
                wipeInstances.withUnsafeBytes { source in
                    trailBuffer!.contents().advanced(by: trailInstances.count * MemoryLayout<TrailRenderInstance>.stride)
                        .copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
        }
        var viewportPoints = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))

        var waterEncoded = false
        if let waterHeight {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = waterHeight
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let waterEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                if let dropBuffer, let trailBuffer, let waterDropletPipeline, let waterTrailPipeline {
                    waterEncoder.setVertexBytes(&viewportPoints, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                    if !trailInstances.isEmpty {
                        waterEncoder.setRenderPipelineState(waterTrailPipeline)
                        waterEncoder.setVertexBuffer(trailBuffer, offset: 0, index: 0)
                        waterEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: trailInstances.count)
                    }
                    if !renderInstances.isEmpty {
                        waterEncoder.setRenderPipelineState(waterDropletPipeline)
                        waterEncoder.setVertexBuffer(dropBuffer, offset: 0, index: 0)
                        waterEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: renderInstances.count)
                    }
                }
                waterEncoder.endEncoding()
                waterEncoded = true
            }
        }

        if useFog, let wipe = fogWipe, let next = fogNext, let fogPipeline {
            let wipePass = MTLRenderPassDescriptor()
            wipePass.colorAttachments[0].texture = wipe
            wipePass.colorAttachments[0].loadAction = .clear
            wipePass.colorAttachments[0].storeAction = .store
            wipePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let wipeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: wipePass) {
                wipeEncoder.setVertexBytes(&viewportPoints, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                let liveStart = simulation.trails.count + simulation.bridges.count
                let liveCount = trailInstances.count - liveStart
                if let trailBuffer, let fogWipeTrailPipeline, liveCount > 0 {
                    wipeEncoder.setRenderPipelineState(fogWipeTrailPipeline)
                    wipeEncoder.setVertexBuffer(trailBuffer,
                        offset: liveStart * MemoryLayout<TrailRenderInstance>.stride, index: 0)
                    wipeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                               instanceCount: liveCount)
                }
                if let trailBuffer, let fogWipeTrailPipeline, !wipeInstances.isEmpty {
                    wipeEncoder.setRenderPipelineState(fogWipeTrailPipeline)
                    wipeEncoder.setVertexBuffer(trailBuffer,
                        offset: trailInstances.count * MemoryLayout<TrailRenderInstance>.stride, index: 0)
                    wipeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                               instanceCount: wipeInstances.count)
                }
                if let dropBuffer, let fogWipeDropletPipeline, !renderInstances.isEmpty {
                    wipeEncoder.setRenderPipelineState(fogWipeDropletPipeline)
                    wipeEncoder.setVertexBuffer(dropBuffer, offset: 0, index: 0)
                    wipeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                               instanceCount: renderInstances.count)
                }
                wipeEncoder.endEncoding()
            }
            if let compute = commandBuffer.makeComputeCommandEncoder() {
                let old = fogDensity
                compute.setComputePipelineState(fogPipeline)
                compute.setTexture(old ?? wipe, index: 0)
                compute.setTexture(wipe, index: 1)
                compute.setTexture(next, index: 2)
                var fogSettings = SIMD4<Float>(Float(frameElapsed), Float(atmosphere.fogReturnTime),
                                               old == nil ? 0 : 1, 0)
                compute.setBytes(&fogSettings, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                let threads = MTLSize(width: 8, height: 8, depth: 1)
                compute.dispatchThreads(MTLSize(width: next.width, height: next.height, depth: 1),
                                        threadsPerThreadgroup: threads)
                compute.endEncoding()
                fogDensity = next
                fogNext = old
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            if dropBuffer != nil { framesInFlight.signal() }
            return
        }
        if waterEncoded, let sharp = sharpBackground, let soft = blurredBackground ?? sharpBackground,
           let waterHeight, let wetGlassPipeline, let sampler {
            let useWinter = winter.snowTexture != nil || winter.frostTexture != nil || winter.contactTexture != nil
            encoder.setRenderPipelineState(useWinter ? (winter.glassPipeline ?? wetGlassPipeline) : wetGlassPipeline)
            if useWinter {
                encoder.setFragmentTexture(winter.snowTexture ?? waterHeight, index: 5)
                encoder.setFragmentTexture(winter.frostTexture ?? waterHeight, index: 6)
                encoder.setFragmentTexture(winter.contactTexture ?? waterHeight, index: 7)
                var winterSettings = SIMD4<Float>(winter.snowTexture == nil ? 0 : 1,
                    winter.frostTexture == nil ? 0 : winter.coverage,
                    winter.contactTexture == nil ? 0 : 1, 0)
                encoder.setFragmentBytes(&winterSettings, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
            }
            encoder.setFragmentTexture(sharp, index: 0)
            encoder.setFragmentTexture(soft, index: 1)
            encoder.setFragmentTexture(waterHeight, index: 2)
            encoder.setFragmentTexture(fogDensity ?? waterHeight, index: 3)
            encoder.setFragmentTexture(foggedBackground ?? soft, index: 4)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var settings = SIMD4<Float>(Float(width), Float(height), refractionStrength, blurRadius > 0 ? 1 : 0)
            encoder.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            var exposure = flashState?.exposure(at: ProcessInfo.processInfo.systemUptime) ?? 0
            encoder.setFragmentBytes(&exposure, length: MemoryLayout<Float>.stride, index: 1)
            var glass = SIMD4<Float>(Float(atmosphere.condensation), Float(atmosphere.haze),
                                     Float(atmosphere.imperfections), Float(atmosphere.fogSoftness))
            encoder.setFragmentBytes(&glass, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else if let background = blurRadius > 0 ? blurredBackground : sharpBackground,
                  let displayPipeline, let sampler {
            encoder.setRenderPipelineState(displayPipeline)
            encoder.setFragmentTexture(background, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var viewport = SIMD2<Float>(Float(width), Float(height))
            encoder.setFragmentBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            var exposure = flashState?.exposure(at: ProcessInfo.processInfo.systemUptime) ?? 0
            encoder.setFragmentBytes(&exposure, length: MemoryLayout<Float>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if let dropBuffer, let trailBuffer, let dropletPipeline, let trailPipeline {
            encoder.setVertexBytes(&viewportPoints, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            if !trailInstances.isEmpty {
                encoder.setRenderPipelineState(trailPipeline)
                encoder.setVertexBuffer(trailBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: trailInstances.count)
            }
            if !renderInstances.isEmpty {
                encoder.setRenderPipelineState(dropletPipeline)
                encoder.setVertexBuffer(dropBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: renderInstances.count)
            }
        }
        encoder.endEncoding()
        if dropBuffer != nil {
            commandBuffer.addCompletedHandler { [framesInFlight] _ in framesInFlight.signal() }
        }
        commandBuffer.present(drawable)
        if diagnosticsEnabled {
            commandBuffer.addCompletedHandler { [diagnostics] completed in
                let milliseconds = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1_000
                Task { @MainActor in diagnostics.updateGPU(milliseconds) }
            }
        }
        commandBuffer.commit()

        guard diagnosticsEnabled else { return }
        sampleFrames += 1
        sampleCPUSeconds += CFAbsoluteTimeGetCurrent() - start
        if sampleStart == 0 { sampleStart = start }
        let elapsed = start - sampleStart
        guard elapsed >= 1 else { return }
        let sharpBytes = (sharpBackground?.width ?? 0) * (sharpBackground?.height ?? 0) * 8
        let blurBytes = (blurredBackground?.width ?? 0) * (blurredBackground?.height ?? 0) * 8
        let waterBytes = (waterHeight?.width ?? 0) * (waterHeight?.height ?? 0) * 2
        let fogBytes = (fogDensity?.width ?? 0) * (fogDensity?.height ?? 0) * 3
        let fogBlurBytes = (foggedBackground?.width ?? 0) * (foggedBackground?.height ?? 0) * 8
        let textureMegabytes = Double(sharpBytes + blurBytes + waterBytes + fogBytes + fogBlurBytes + winter.textureBytes) / 1_048_576
        diagnostics.update(
            framesPerSecond: Double(sampleFrames) / elapsed,
            cpuFrameMilliseconds: sampleCPUSeconds * 1_000 / Double(sampleFrames),
            renderTextureMegabytes: textureMegabytes,
            drawableWidth: width,
            drawableHeight: height
        )
        sampleStart = start
        sampleFrames = 0
        sampleCPUSeconds = 0
    }

    private func updateBackgroundIfNeeded(texture: MTLTexture, width: Int, height: Int, commandBuffer: MTLCommandBuffer) {
        if sharpBackground?.width != width || sharpBackground?.height != height { backgroundDirty = true }
        guard backgroundDirty, let wallpaperPipeline, let sampler else { return }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        textureDescriptor.storageMode = .private
        guard let sharp = device.makeTexture(descriptor: textureDescriptor) else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sharp
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.045, green: 0.055, blue: 0.075, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(wallpaperPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var uniforms = WallpaperUniforms(
            viewportSize: SIMD2(Float(width), Float(height)),
            imageSize: SIMD2(Float(texture.width), Float(texture.height)),
            scaleMode: scaleMode.shaderValue,
            zoom: wallpaperZoom
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        var blurred: MTLTexture?
        if blurRadius > 0 {
            let scale = blurRadius >= 2.5 ? quality.blurScale : 1
            let softWidth = max(1, (width + scale - 1) / scale)
            let softHeight = max(1, (height + scale - 1) / scale)
            let softDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: softWidth, height: softHeight, mipmapped: false)
            softDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            softDescriptor.storageMode = .private
            if let softSource = device.makeTexture(descriptor: softDescriptor),
               let output = device.makeTexture(descriptor: softDescriptor) {
                let softPass = MTLRenderPassDescriptor()
                softPass.colorAttachments[0].texture = softSource
                softPass.colorAttachments[0].loadAction = .clear
                softPass.colorAttachments[0].storeAction = .store
                if let softEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: softPass) {
                    softEncoder.setRenderPipelineState(wallpaperPipeline)
                    softEncoder.setFragmentTexture(texture, index: 0)
                    softEncoder.setFragmentSamplerState(sampler, index: 0)
                    var softUniforms = WallpaperUniforms(
                        viewportSize: SIMD2(Float(softWidth), Float(softHeight)),
                        imageSize: SIMD2(Float(texture.width), Float(texture.height)),
                        scaleMode: scaleMode.shaderValue, zoom: wallpaperZoom)
                    softEncoder.setFragmentBytes(&softUniforms, length: MemoryLayout<WallpaperUniforms>.stride, index: 0)
                    softEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    softEncoder.endEncoding()
                    let blur = MPSImageGaussianBlur(device: device, sigma: Float(blurRadius) / Float(scale))
                    blur.edgeMode = .clamp
                    blur.encode(commandBuffer: commandBuffer, sourceTexture: softSource, destinationTexture: output)
                    blurred = output
                }
            }
        }
        var fogged: MTLTexture?
        let fogScale = 2
        let fogWidth = max(1, (width + fogScale - 1) / fogScale)
        let fogHeight = max(1, (height + fogScale - 1) / fogScale)
        let fogDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: fogWidth, height: fogHeight, mipmapped: false)
        fogDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        fogDescriptor.storageMode = .private
        if let fogSource = device.makeTexture(descriptor: fogDescriptor),
           let output = device.makeTexture(descriptor: fogDescriptor) {
            let fogPass = MTLRenderPassDescriptor()
            fogPass.colorAttachments[0].texture = fogSource
            fogPass.colorAttachments[0].loadAction = .clear
            fogPass.colorAttachments[0].storeAction = .store
            if let fogEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: fogPass) {
                fogEncoder.setRenderPipelineState(wallpaperPipeline)
                fogEncoder.setFragmentTexture(texture, index: 0)
                fogEncoder.setFragmentSamplerState(sampler, index: 0)
                var fogUniforms = WallpaperUniforms(
                    viewportSize: SIMD2(Float(fogWidth), Float(fogHeight)),
                    imageSize: SIMD2(Float(texture.width), Float(texture.height)),
                    scaleMode: scaleMode.shaderValue, zoom: wallpaperZoom)
                fogEncoder.setFragmentBytes(&fogUniforms, length: MemoryLayout<WallpaperUniforms>.stride, index: 0)
                fogEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                fogEncoder.endEncoding()
                let fogBlur = MPSImageGaussianBlur(device: device,
                    sigma: Float(max(10, blurRadius + 8)) / Float(fogScale))
                fogBlur.edgeMode = .clamp
                fogBlur.encode(commandBuffer: commandBuffer, sourceTexture: fogSource, destinationTexture: output)
                fogged = output
            }
        }
        sharpBackground = sharp
        blurredBackground = blurred
        foggedBackground = fogged
        backgroundDirty = false
    }
}
