import MetalKit

/// Owns optional winter resources. No winter textures or passes exist while both effects are off.
final class WinterRenderer {
    private let device: MTLDevice
    private let snowPipeline: MTLRenderPipelineState?
    private let frostPipeline: MTLComputePipelineState?
    let glassPipeline: MTLRenderPipelineState?
    private let snowSimulation: SnowSimulation
    private var instances: [SnowRenderInstance] = []
    private var contactInstances: [SnowRenderInstance] = []
    private var snowSettings = SnowSettings()
    private var frostSettings = FrostSettings()
    private var frame = WindowFrameSettings()
    private var quality = RenderQuality.balanced
    private var seed: UInt64
    private var frostKey: FrostKey?
    private(set) var snowTexture: MTLTexture?
    private(set) var contactTexture: MTLTexture?
    private(set) var frostTexture: MTLTexture?
    private(set) var coverage: Float = 0

    private struct FrostKey: Equatable {
        let width: Int
        let height: Int
        let points: CGSize
        let seed: UInt64
        let detail: Double
        let frame: WindowFrameSettings
    }

    var available: Bool { snowPipeline != nil && frostPipeline != nil && glassPipeline != nil }
    var textureBytes: Int {
        (snowTexture.map { $0.width * $0.height * 4 } ?? 0) +
        (contactTexture.map { $0.width * $0.height * 4 } ?? 0) +
        (frostTexture.map { $0.width * $0.height * 4 } ?? 0)
    }

    init(device: MTLDevice, library: MTLLibrary?, seed: UInt64) {
        self.device = device
        self.seed = seed
        snowSimulation = SnowSimulation(seed: seed)
        let snow = MTLRenderPipelineDescriptor()
        snow.vertexFunction = library?.makeFunction(name: "snowVertex")
        snow.fragmentFunction = library?.makeFunction(name: "snowFragment")
        snow.colorAttachments[0].pixelFormat = .rgba8Unorm
        snow.colorAttachments[0].isBlendingEnabled = true
        snow.colorAttachments[0].sourceRGBBlendFactor = .one
        snow.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        snow.colorAttachments[0].sourceAlphaBlendFactor = .one
        snow.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        snowPipeline = try? device.makeRenderPipelineState(descriptor: snow)
        frostPipeline = library?.makeFunction(name: "frostPatternKernel").flatMap {
            try? device.makeComputePipelineState(function: $0)
        }
        let glass = MTLRenderPipelineDescriptor()
        glass.vertexFunction = library?.makeFunction(name: "fullscreenVertex")
        glass.fragmentFunction = library?.makeFunction(name: "winterGlassFragment")
        glass.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        glassPipeline = try? device.makeRenderPipelineState(descriptor: glass)
    }

    func reset(seed: UInt64) {
        self.seed = seed
        snowSimulation.reset(seed: seed)
        frostKey = nil
    }

    func configure(snow: SnowSettings, frost: FrostSettings, frame: WindowFrameSettings) {
        snowSettings = snow.clamped()
        frostSettings = frost.clamped()
        self.frame = frame
    }

    func prepare(quality: RenderQuality, size: CGSize) {
        self.quality = quality
        snowSimulation.configure(snowSettings, limit: quality.snowLimit, size: size)
    }

    func step(dt: Float) {
        snowSimulation.step(dt: dt)
        let target = Float(frostSettings.coverage)
        // Advance the edge slowly enough to read as growing/receding ice.
        coverage += max(-dt * 0.16, min(dt * 0.16, target - coverage))
    }

    private func texture(format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        return device.makeTexture(descriptor: descriptor)
    }

    func encode(commandBuffer: MTLCommandBuffer, width: Int, height: Int, points: CGSize) {
        guard available, width > 0, height > 0 else { return }
        let w = max(1, (width + quality.winterScale - 1) / quality.winterScale)
        let h = max(1, (height + quality.winterScale - 1) / quality.winterScale)
        snowSimulation.renderInstances(into: &instances)
        snowSimulation.renderContacts(into: &contactInstances)
        if instances.isEmpty {
            snowTexture = nil
            contactTexture = nil
        } else if let snowPipeline {
            if snowTexture?.width != w || snowTexture?.height != h {
                snowTexture = texture(format: .rgba8Unorm, width: w, height: h)
            }
            if contactInstances.isEmpty {
                contactTexture = nil
            } else if contactTexture?.width != w || contactTexture?.height != h {
                contactTexture = texture(format: .rgba8Unorm, width: w, height: h)
            }
            func draw(_ entries: [SnowRenderInstance], into target: MTLTexture?) {
                guard let target, !entries.isEmpty else { return }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                // The command buffer retains this immutable upload until the GPU finishes.
                let buffer = entries.withUnsafeBytes { bytes in
                    device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
                }
                if let buffer, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                    encoder.setRenderPipelineState(snowPipeline)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                    var viewport = SIMD2<Float>(max(1, Float(points.width)), max(1, Float(points.height)))
                    encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: entries.count)
                    encoder.endEncoding()
                }
            }
            draw(instances, into: snowTexture)
            draw(contactInstances, into: contactTexture)
        }
        guard coverage > 0 else { frostTexture = nil; frostKey = nil; return }
        let fw = max(1, (width + quality.frostScale - 1) / quality.frostScale)
        let fh = max(1, (height + quality.frostScale - 1) / quality.frostScale)
        let key = FrostKey(width: fw, height: fh, points: points, seed: seed, detail: frostSettings.detail, frame: frame)
        guard key != frostKey, let frostPipeline else { return }
        if frostTexture?.width != fw || frostTexture?.height != fh {
            frostTexture = texture(format: .rg16Float, width: fw, height: fh)
        }
        guard let frostTexture, let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(frostPipeline)
        encoder.setTexture(frostTexture, index: 0)
        var settings = SIMD4<Float>(Float(points.width), Float(points.height), Float(frostSettings.detail), Float(seed % 65_521))
        var panes = SIMD4<Float>(Float(max(1, frame.layout.columns)), Float(max(1, frame.layout.rows)), Float(frame.thickness), 0)
        encoder.setBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setBytes(&panes, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: fw, height: fh, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        frostKey = key
    }
}
