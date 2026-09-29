import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import MetalPerformanceShaders
import UniformTypeIdentifiers

private struct WallpaperUniforms {
    var viewportSize: SIMD2<Float>
    var imageSize: SIMD2<Float>
    var scaleMode: UInt32
    var zoom: Float
}

@main
struct WallpaperColorCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Pass the built app's default.metallib path on a Metal-capable Mac")
        }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let wallpaper = try pipeline(device, library, "wallpaperFragment", .rgba16Float)
        let composite = try pipeline(device, library, "wetGlassFragment", .bgra8Unorm_srgb)
        let sampler = device.makeSamplerState(descriptor: MTLSamplerDescriptor())!
        let colors: [(String, [UInt8])] = [
            ("blue", [0, 0, 255]), ("red", [255, 0, 0]), ("gray", [128, 128, 128])
        ]
        for (name, rgb) in colors {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("rainglass-color-\(name).jpg")
            try writeJPEG(rgb, to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let source = try WallpaperDecoder.makeTexture(url: url, device: device)
            assert(source.pixelFormat == .rgba8Unorm_srgb)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 32, height: 32, mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            let sharp = device.makeTexture(descriptor: descriptor)!
            let blurred = device.makeTexture(descriptor: descriptor)!
            let waterDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float, width: 16, height: 16, mipmapped: false
            )
            waterDescriptor.usage = [.renderTarget, .shaderRead]
            let water = device.makeTexture(descriptor: waterDescriptor)!
            let finalDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: 32, height: 32, mipmapped: false
            )
            finalDescriptor.usage = [.renderTarget, .shaderRead]
            let output = device.makeTexture(descriptor: finalDescriptor)!
            let command = queue.makeCommandBuffer()!

            let first = MTLRenderPassDescriptor()
            first.colorAttachments[0].texture = sharp
            first.colorAttachments[0].loadAction = .clear
            first.colorAttachments[0].storeAction = .store
            let encoder = command.makeRenderCommandEncoder(descriptor: first)!
            encoder.setRenderPipelineState(wallpaper)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            var uniforms = WallpaperUniforms(
                viewportSize: SIMD2(32, 32), imageSize: SIMD2(32, 32), scaleMode: 2, zoom: 1
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            let blur = MPSImageGaussianBlur(device: device, sigma: 2)
            blur.edgeMode = .clamp
            blur.encode(commandBuffer: command, sourceTexture: sharp, destinationTexture: blurred)

            let clear = MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture = water
            clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].storeAction = .store
            command.makeRenderCommandEncoder(descriptor: clear)!.endEncoding()
            let sourceBytes = readPixel(source, command, device)
            let sharpBytes = readPixel(sharp, command, device)
            let blurBytes = readPixel(blurred, command, device)
            for enabled in [false, true] {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = output
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let final = command.makeRenderCommandEncoder(descriptor: pass)!
                final.setRenderPipelineState(composite)
                final.setFragmentTexture(sharp, index: 0)
                final.setFragmentTexture(enabled ? blurred : sharp, index: 1)
                final.setFragmentTexture(water, index: 2)
                final.setFragmentTexture(water, index: 3)
                final.setFragmentTexture(blurred, index: 4)
                final.setFragmentSamplerState(sampler, index: 0)
                var settings = SIMD4<Float>(32, 32, 0.65, enabled ? 1 : 0)
                var exposure: Float = 0
                var glass = SIMD4<Float>(repeating: 0)
                final.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                final.setFragmentBytes(&exposure, length: MemoryLayout<Float>.stride, index: 1)
                final.setFragmentBytes(&glass, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                final.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                final.endEncoding()
                let finalBytes = readPixel(output, command, device)
                command.addCompletedHandler { _ in
                    let actual = [byte(finalBytes, 2), byte(finalBytes, 1), byte(finalBytes, 0)]
                    for channel in 0..<3 {
                        assert(abs(Int(actual[channel]) - Int(rgb[channel])) <= 3,
                               "\(name) changed color with blur \(enabled): \(actual)")
                    }
                }
            }
            command.commit()
            command.waitUntilCompleted()
            assert(command.status == .completed, "\(String(describing: command.error))")
            for channel in 0..<3 {
                assert(abs(Int(byte(sourceBytes, channel)) - Int(rgb[channel])) <= 3)
                let expected = srgbToLinear(Double(rgb[channel]) / 255)
                assert(abs(Double(half(sharpBytes, channel)) - expected) < 0.015)
                assert(abs(Double(half(blurBytes, channel)) - expected) < 0.02)
            }
            assert(byte(sourceBytes, 3) == 255)
            assert(abs(half(sharpBytes, 3) - 1) < 0.002)
            assert(abs(half(blurBytes, 3) - 1) < 0.002)
        }
        print("Wallpaper RGB preserved through upload, linear blur, and blur on/off display")
    }

    private static func pipeline(
        _ device: MTLDevice, _ library: MTLLibrary, _ fragment: String, _ format: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func writeJPEG(_ rgb: [UInt8], to url: URL) throws {
        let pixels = Data(Array(repeating: rgb + [255], count: 37 * 29).flatMap { $0 })
        let image = CGImage(
            width: 37, height: 29, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 148, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: pixels as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        assert(CGImageDestinationFinalize(destination))
    }

    private static func readPixel(_ texture: MTLTexture, _ command: MTLCommandBuffer, _ device: MTLDevice) -> MTLBuffer {
        let buffer = device.makeBuffer(length: 256, options: .storageModeShared)!
        let blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 16, y: 16, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: 256,
                  destinationBytesPerImage: 256)
        blit.endEncoding()
        return buffer
    }

    private static func byte(_ buffer: MTLBuffer, _ index: Int) -> UInt8 {
        buffer.contents().load(fromByteOffset: index, as: UInt8.self)
    }

    private static func half(_ buffer: MTLBuffer, _ index: Int) -> Float {
        Float(Float16(bitPattern: buffer.contents().load(fromByteOffset: index * 2, as: UInt16.self)))
    }

    private static func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
