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
    private let sampler: MTLSamplerState?
    private let diagnostics: RenderDiagnostics

    private var wallpaperTexture: MTLTexture?
    private var wallpaperRevision = -1
    private var scaleMode: WallpaperScaleMode = .fill
    private var blurRadius = 2.0
    private var backgroundDirty = true
    private var sharpBackground: MTLTexture?
    private var blurredBackground: MTLTexture?

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

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        super.init()
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        guard diagnosticsEnabled != enabled else { return }
        diagnosticsEnabled = enabled
        sampleStart = 0
        sampleFrames = 0
        sampleCPUSeconds = 0
    }

    @MainActor
    func setWallpaper(texture: MTLTexture?, revision: Int, scaleMode: WallpaperScaleMode, blurRadius: Double, in view: MTKView) {
        guard wallpaperRevision != revision || self.scaleMode != scaleMode || self.blurRadius != blurRadius else { return }
        wallpaperTexture = texture
        wallpaperRevision = revision
        self.scaleMode = scaleMode
        self.blurRadius = blurRadius
        backgroundDirty = true
        view.needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        diagnostics.updateSize(width: Int(size.width), height: Int(size.height))
        backgroundDirty = true
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        let start = CFAbsoluteTimeGetCurrent()
        guard let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        if width > 0, height > 0, let wallpaperTexture {
            updateBackgroundIfNeeded(texture: wallpaperTexture, width: width, height: height, commandBuffer: commandBuffer)
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        if let background = blurRadius > 0 ? blurredBackground : sharpBackground,
           let displayPipeline, let sampler {
            encoder.setRenderPipelineState(displayPipeline)
            encoder.setFragmentTexture(background, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var viewport = SIMD2<Float>(Float(width), Float(height))
            encoder.setFragmentBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
