import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

@main
struct RainSplatRenderCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle(path: CommandLine.arguments[1])!),
              let vertex = library.makeFunction(name: "splatVertex"),
              let fragment = library.makeFunction(name: "splatFragment"),
              let queue = device.makeCommandQueue() else { fatalError("Metal splat shader unavailable") }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        for size in [128, 512] {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: size, height: size, mipmapped: false)
            textureDescriptor.storageMode = .shared
            textureDescriptor.usage = [.renderTarget, .shaderRead]
            let target = device.makeTexture(descriptor: textureDescriptor)!
            var splats = ImpactSplats()
            splats.append([DropArrivalEvent(id: 42, radius: 11,
                                            horizontalPosition: 0.5,
                                            position: SIMD2(Float(size) / 2, Float(size) / 2))])
            splats.step(dt: 0.07)
            var instances: [SplatRenderInstance] = []
            splats.renderInstances(into: &instances)
            let buffer = device.makeBuffer(bytes: instances,
                                           length: instances.count * MemoryLayout<SplatRenderInstance>.stride)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1)
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            var viewport = SIMD2<Float>(Float(size), Float(size))
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            assert(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            target.getBytes(&pixels, bytesPerRow: size * 4,
                            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            let background = Array(pixels[0..<3])
            let affected = stride(from: 0, to: pixels.count, by: 4).filter {
                Array(pixels[$0..<$0+3]) != background
            }.count
            assert(affected > 100 && affected < size * size / 3)
            assert(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: size, height: size, bitsPerComponent: 8,
                                bitsPerPixel: 32, bytesPerRow: size * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                    .union(.byteOrder32Little), provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let url = URL(fileURLWithPath: "/tmp/RainSplatPreview-\(size).png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            assert(CGImageDestinationFinalize(destination))
            print("Rendered \(size) px impact: \(affected) affected pixels")
        }
    }
}
