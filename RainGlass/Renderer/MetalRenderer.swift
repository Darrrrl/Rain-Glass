import Foundation
import MetalKit
import MetalPerformanceShaders

private struct WallpaperUniforms {
    var viewportSize: SIMD2<Float>
    var imageSize: SIMD2<Float>
    var scaleMode: UInt32
}

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let wallpaperPipeline: MTLRenderPipelineState?
    private let displayPipeline: MTLRenderPipelineState?
    private let dropletPipeline: MTLRenderPipelineState?
    private let trailPipeline: MTLRenderPipelineState?
    private let waterDropletPipeline: MTLRenderPipelineState?
    private let waterTrailPipeline: MTLRenderPipelineState?
    private let wetGlassPipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?
    private let diagnostics: RenderDiagnostics
    private let simulation = RainSimulation(seed: UInt64.random(in: UInt64.min...UInt64.max))
    private var rainSeed = ""
    private var lastFrameTime: CFAbsoluteTime = 0
    private var simulationAccumulator: Float = 0
    private var renderInstances: [DropletRenderInstance] = []
    private var trailInstances: [TrailRenderInstance] = []
    private var instanceBuffers: [MTLBuffer] = []
    private var trailBuffers: [MTLBuffer] = []
    private var nextInstanceBuffer = 0
    private let framesInFlight = DispatchSemaphore(value: 3)
    private weak var observedWindow: NSWindow?
    private weak var observedView: RainMetalView?

    private var wallpaperTexture: MTLTexture?
    private var wallpaperRevision = -1
    private var scaleMode: WallpaperScaleMode = .fill
    private var blurRadius = 2.0
    private var targetBlurRadius = 2.0
    private var backgroundDirty = true
    private var sharpBackground: MTLTexture?
    private var blurredBackground: MTLTexture?
    private var waterHeight: MTLTexture?
    private var refractionStrength: Float = 0.65

    private var diagnosticsEnabled = false
    private var sampleStart: CFAbsoluteTime = 0
    private var sampleFrames = 0
    private var sampleCPUSeconds = 0.0

    init(device: MTLDevice, diagnostics: RenderDiagnostics) {
        self.device = device
        commandQueue = device.makeCommandQueue()
        self.diagnostics = diagnostics

        let library = device.makeDefaultLibrary()
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

        let wetGlassDescriptor = MTLRenderPipelineDescriptor()
        wetGlassDescriptor.vertexFunction = library?.makeFunction(name: "fullscreenVertex")
        wetGlassDescriptor.fragmentFunction = library?.makeFunction(name: "wetGlassFragment")
        wetGlassDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        wetGlassPipeline = try? device.makeRenderPipelineState(descriptor: wetGlassDescriptor)
        let bufferLength = 6_000 * MemoryLayout<DropletRenderInstance>.stride
        instanceBuffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: bufferLength, options: .storageModeShared)
        }
        let trailLength = RainSimulation.maximumTrails * MemoryLayout<TrailRenderInstance>.stride
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
        assert(waterDropletPipeline != nil && waterTrailPipeline != nil && wetGlassPipeline != nil,
               "RainGlass could not create the water refraction pipelines")
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
        simulation.reset(seed: UInt64(raw) ?? UInt64.random(in: UInt64.min...UInt64.max))
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
        let visible = view.window?.occlusionState.contains(.visible) == true
        view.isPaused = !visible
        if visible {
            lastFrameTime = 0
            view.needsDisplay = true
        }
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        guard diagnosticsEnabled != enabled else { return }
        diagnosticsEnabled = enabled
        sampleStart = 0
        sampleFrames = 0
        sampleCPUSeconds = 0
    }

    @MainActor
    func setSceneParameters(_ parameters: RainParameters, in view: MTKView) {
        simulation.setParameters(parameters)
        targetBlurRadius = parameters.blur
        view.needsDisplay = true
    }

    @MainActor
    func setWallpaper(texture: MTLTexture?, revision: Int, scaleMode: WallpaperScaleMode, in view: MTKView) {
        guard wallpaperRevision != revision || self.scaleMode != scaleMode else { return }
        wallpaperTexture = texture
        wallpaperRevision = revision
        self.scaleMode = scaleMode
        backgroundDirty = true
        view.needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        diagnostics.updateSize(width: Int(size.width), height: Int(size.height))
        backgroundDirty = true
        simulation.resize(to: view.bounds.size)
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        let start = CFAbsoluteTimeGetCurrent()
        let frameElapsed = lastFrameTime == 0 ? 0 : min(0.1, start - lastFrameTime)
        lastFrameTime = start
        simulation.resize(to: view.bounds.size)
        simulationAccumulator += Float(frameElapsed)
        let fixedStep: Float = 1.0 / 120.0
        var steps = 0
        while simulationAccumulator >= fixedStep && steps < 4 {
            simulation.step(dt: fixedStep)
            simulationAccumulator -= fixedStep
            steps += 1
        }
        if steps == 4 { simulationAccumulator = 0 }
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

        let waterWidth = max(1, (width + 1) / 2)
        let waterHeightPixels = max(1, (height + 1) / 2)
        if waterHeight?.width != waterWidth || waterHeight?.height != waterHeightPixels {
            let waterDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float, width: waterWidth, height: waterHeightPixels, mipmapped: false
            )
            waterDescriptor.usage = [.renderTarget, .shaderRead]
            waterDescriptor.storageMode = .private
            waterHeight = device.makeTexture(descriptor: waterDescriptor)
        }

        simulation.renderInstances(into: &renderInstances)
        simulation.trailInstances(into: &trailInstances)
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

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            if dropBuffer != nil { framesInFlight.signal() }
            return
        }
        if waterEncoded, let sharp = sharpBackground, let soft = blurredBackground ?? sharpBackground,
           let waterHeight, let wetGlassPipeline, let sampler {
            encoder.setRenderPipelineState(wetGlassPipeline)
            encoder.setFragmentTexture(sharp, index: 0)
            encoder.setFragmentTexture(soft, index: 1)
            encoder.setFragmentTexture(waterHeight, index: 2)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var settings = SIMD4<Float>(Float(width), Float(height), refractionStrength, blurRadius > 0 ? 1 : 0)
            encoder.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else if let background = blurRadius > 0 ? blurredBackground : sharpBackground,
                  let displayPipeline, let sampler {
            encoder.setRenderPipelineState(displayPipeline)
            encoder.setFragmentTexture(background, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var viewport = SIMD2<Float>(Float(width), Float(height))
            encoder.setFragmentBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
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
            scaleMode: scaleMode.shaderValue
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        var blurred: MTLTexture?
        if blurRadius > 0, let output = device.makeTexture(descriptor: textureDescriptor) {
            let blur = MPSImageGaussianBlur(device: device, sigma: Float(blurRadius))
            blur.edgeMode = .clamp
            blur.encode(commandBuffer: commandBuffer, sourceTexture: sharp, destinationTexture: output)
            blurred = output
        }
        sharpBackground = sharp
        blurredBackground = blurred
        backgroundDirty = false
    }
}
