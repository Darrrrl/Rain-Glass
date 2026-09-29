import Foundation
import Metal

@main
struct FogHistoryCheck {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "FogHistoryCheck", code: 1)
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let evolution = try device.makeComputePipelineState(function: library.makeFunction(name: "fogEvolutionKernel")!)
        var wipePipelines: [String: MTLRenderPipelineState] = [:]
        for fragment in ["fogWipeDropletFragment", "fogWipeTrailFragment"] {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: fragment == "fogWipeDropletFragment" ?
                                                              "dropletVertex" : "trailVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .r8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .max
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            wipePipelines[fragment] = try device.makeRenderPipelineState(descriptor: descriptor)
        }

        func texture(_ size: Int, value: UInt8) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .shared
            let result = device.makeTexture(descriptor: descriptor)!
            let bytes = [UInt8](repeating: value, count: size * size)
            result.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                           withBytes: bytes, bytesPerRow: size)
            return result
        }
        func value(_ texture: MTLTexture) -> UInt8 {
            var byte: UInt8 = 0
            texture.getBytes(&byte, bytesPerRow: 1, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            return byte
        }
        func evolve(_ previous: MTLTexture?, wipe: MTLTexture, dt: Float, size: Int) -> MTLTexture {
            let output = texture(size, value: 0)
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(evolution)
            encoder.setTexture(previous ?? wipe, index: 0)
            encoder.setTexture(wipe, index: 1)
            encoder.setTexture(output, index: 2)
            var settings = SIMD4<Float>(dt, 18, previous == nil ? 0 : 1, 0)
            encoder.setBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            assert(command.status == .completed)
            return output
        }

        let dry = texture(1, value: 0)
        let wet = texture(1, value: 255)
        let base = evolve(nil, wipe: dry, dt: 0, size: 1)
        let wiped = evolve(base, wipe: wet, dt: 1.0 / 60, size: 1)
        assert(value(base) > 150 && value(wiped) < 4)
        let afterOneSecond = evolve(wiped, wipe: dry, dt: 1, size: 1)
        assert(value(afterOneSecond) > 0 && value(afterOneSecond) < value(base) / 3)
        var recovered = afterOneSecond
        for _ in 0..<17 { recovered = evolve(recovered, wipe: dry, dt: 1, size: 1) }
        assert(Int(value(recovered)) >= Int(value(base)) * 9 / 10)
        let resized = evolve(recovered, wipe: texture(2, value: 0), dt: 0, size: 2)
        assert(abs(Int(value(resized)) - Int(value(recovered))) <= 1)

        struct DropInstance { var geometry: SIMD4<Float>; var appearance: SIMD4<Float> }
        struct TrailInstance { var geometry: SIMD4<Float>; var appearance: SIMD4<Float>; var style: SIMD4<Float>; var dropMask: SIMD4<Float> }
        let mask = texture(32, value: 0)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = mask
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
        var viewport = SIMD2<Float>(32, 32)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        var drop = DropInstance(geometry: SIMD4(16, 13, 5, 1), appearance: SIMD4(0.8, 1, 0, 0))
        encoder.setRenderPipelineState(wipePipelines["fogWipeDropletFragment"]!)
        encoder.setVertexBytes(&drop, length: MemoryLayout<DropInstance>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        var trail = TrailInstance(geometry: SIMD4(16, 16, 16, 28),
                                  appearance: SIMD4(4, 4, 1, 1), style: .zero, dropMask: .zero)
        encoder.setRenderPipelineState(wipePipelines["fogWipeTrailFragment"]!)
        encoder.setVertexBytes(&trail, length: MemoryLayout<TrailInstance>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        assert(command.status == .completed)
        func maskValue(_ x: Int, _ y: Int) -> UInt8 {
            var byte: UInt8 = 0
            mask.getBytes(&byte, bytesPerRow: 1, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return byte
        }
        assert(maskValue(16, 13) > 100)
        assert(maskValue(16, 24) > 100)
        assert(maskValue(0, 0) == 0)
        print("Fog wipe, gradual return, resize sampling, and Metal wipe pipelines checked")
    }
}
