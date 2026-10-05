import Foundation
import Metal

@main
struct TrailJunctionCheck {
    struct TrailInstance {
        var geometry: SIMD4<Float>
        var appearance: SIMD4<Float>
        var style: SIMD4<Float>
        var dropMask: SIMD4<Float>
    }
    struct DropInstance {
        var geometry: SIMD4<Float>
        var appearance: SIMD4<Float>
    }

    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "TrailJunctionCheck", code: 1)
        }
        let libraryURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let library = try libraryURL.pathExtension == "metal"
            ? device.makeLibrary(source: String(contentsOf: libraryURL, encoding: .utf8), options: nil)
            : device.makeLibrary(URL: libraryURL)
        func pipeline(vertex: String, fragment: String, format: MTLPixelFormat,
                      maxBlend: Bool = false) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            if maxBlend {
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .max
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        func texture(_ format: MTLPixelFormat) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: 64, height: 64, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor)!
        }
        var trail = TrailInstance(geometry: SIMD4(32, 10, 32, 40),
                                  appearance: SIMD4(6, 6, 1, 1), style: .zero,
                                  dropMask: SIMD4(32, 40, 10, 10))
        var drop = DropInstance(geometry: SIMD4(32, 40, 10, 1),
                                appearance: SIMD4(1, 1, 0, 0))
        var viewport = SIMD2<Float>(64, 64)
        func render(_ target: MTLTexture, trailPipeline: MTLRenderPipelineState?,
                    dropPipeline: MTLRenderPipelineState?) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            if let trailPipeline {
                encoder.setRenderPipelineState(trailPipeline)
                encoder.setVertexBytes(&trail, length: MemoryLayout<TrailInstance>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            if let dropPipeline {
                encoder.setRenderPipelineState(dropPipeline)
                encoder.setVertexBytes(&drop, length: MemoryLayout<DropInstance>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            assert(command.status == .completed)
        }
        let visual = texture(.bgra8Unorm_srgb)
        render(visual, trailPipeline: try pipeline(vertex: "trailVertex", fragment: "trailFragment",
                                                   format: .bgra8Unorm_srgb), dropPipeline: nil)
        func alpha(_ y: Int) -> UInt8 {
            var pixel = [UInt8](repeating: 0, count: 4)
            visual.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(32, y, 1, 1), mipmapLevel: 0)
            return pixel[3]
        }
        assert(alpha(26) > 0, "The trail must remain visible behind the drop")
        assert(alpha(38) == 0, "The trail must vanish inside the drop")

        let waterTrail = try pipeline(vertex: "trailVertex", fragment: "waterTrailFragment", format: .r16Float)
        let waterDrop = try pipeline(vertex: "dropletVertex", fragment: "waterDropletFragment",
                                     format: .r16Float, maxBlend: true)
        let joined = texture(.r16Float)
        let dropOnly = texture(.r16Float)
        render(joined, trailPipeline: waterTrail, dropPipeline: waterDrop)
        render(dropOnly, trailPipeline: nil, dropPipeline: waterDrop)
        func height(_ texture: MTLTexture) -> UInt16 {
            var value: UInt16 = 0
            texture.getBytes(&value, bytesPerRow: 2, from: MTLRegionMake2D(32, 38, 1, 1), mipmapLevel: 0)
            return value
        }
        assert(height(joined) == height(dropOnly), "The trail must not raise the drop's lens surface")
        print("Trail junction hides the line and water ridge inside its parent drop")
    }
}
