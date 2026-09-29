import Foundation
import Metal

private struct WallpaperUniforms {
    var viewportSize: SIMD2<Float>
    var imageSize: SIMD2<Float>
    var scaleMode: UInt32
    var zoom: Float
}

@main
struct WallpaperZoomCheck {
    static func main() throws {
        let device = MTLCreateSystemDefaultDevice()!
        let queue = device.makeCommandQueue()!
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "wallpaperFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        let sampler = device.makeSamplerState(descriptor: samplerDescriptor)!

        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        sourceDescriptor.usage = [.shaderRead]
        sourceDescriptor.storageMode = .shared
        let source = device.makeTexture(descriptor: sourceDescriptor)!
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for y in 0..<8 {
            for x in 0..<8 {
                let blue = (2..<6).contains(x) && (2..<6).contains(y)
                let offset = (y * 8 + x) * 4
                pixels[offset] = blue ? 0 : 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = blue ? 255 : 0
                pixels[offset + 3] = 255
            }
        }
        source.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0,
                       withBytes: pixels, bytesPerRow: 32)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        outputDescriptor.usage = [.renderTarget]
        outputDescriptor.storageMode = .shared
        let output = device.makeTexture(descriptor: outputDescriptor)!

        for mode in [UInt32(0), 1, 2] {
            for zoom in [Float(1), 2] {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = output
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let command = queue.makeCommandBuffer()!
                let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(source, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                var uniforms = WallpaperUniforms(viewportSize: SIMD2(8, 8), imageSize: SIMD2(8, 8),
                                                 scaleMode: mode, zoom: zoom)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                assert(command.status == .completed)
                var corner = [UInt8](repeating: 0, count: 4)
                output.getBytes(&corner, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
                assert((corner[0] > 200) == (zoom == 2))
                assert((corner[2] > 200) == (zoom == 1))
            }
        }
        print("Wallpaper zoom changes framing in fill, fit, and stretch modes")
    }
}
