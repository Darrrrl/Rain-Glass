import AppKit
import MetalKit

@main
struct WinterRenderCheck {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "WinterRenderCheck: Metal unavailable", code: 1)
        }
        let libraryURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let library = try libraryURL.pathExtension == "metal"
            ? device.makeLibrary(source: String(contentsOf: libraryURL, encoding: .utf8), options: nil)
            : device.makeLibrary(URL: libraryURL)
        let winter = WinterRenderer(device: device, library: library, seed: 42)
        assert(winter.available)
        let size = CGSize(width: 640, height: 400)
        func encode() {
            let command = queue.makeCommandBuffer()!
            winter.encode(commandBuffer: command, width: 640, height: 400, points: size)
            command.commit(); command.waitUntilCompleted()
            assert(command.status == .completed, "Winter passes must execute successfully")
        }
        winter.prepare(quality: .balanced, size: size)
        encode()
        assert(winter.textureBytes == 0 && winter.snowTexture == nil && winter.contactTexture == nil && winter.frostTexture == nil)
        winter.configure(snow: SnowSettings(amount: 0.5), frost: FrostSettings(coverage: 0.5), frame: .init())
        winter.prepare(quality: .balanced, size: size)
        for _ in 0..<600 { winter.step(dt: 1 / 120) }
        encode()
        assert(winter.textureBytes > 0 && winter.snowTexture != nil && winter.frostTexture != nil)
        var sawContact = winter.contactTexture != nil
        for _ in 0..<1200 where !sawContact {
            winter.step(dt: 1 / 120)
            encode()
            sawContact = winter.contactTexture != nil
        }
        assert(sawContact, "Seeded near flakes should briefly touch the glass")
        let cached = winter.frostTexture!
        encode()
        assert(winter.frostTexture === cached, "Stable frames must reuse the frost cache")

        func texture(_ format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: descriptor)!
        }
        let background = texture(.rgba8Unorm, width: 1, height: 1)
        let empty = texture(.r16Float, width: 1, height: 1)
        var zero: UInt16 = 0
        empty.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 2)
        let water = texture(.r16Float, width: 64, height: 64)
        var waterData = (0..<4096).map { index -> Float16 in
            let x = Float(index % 64 - 32) / 10
            let y = Float(index / 64 - 32) / 14
            return Float16(max(0, 1 - x*x - y*y).squareRoot())
        }
        water.replace(region: MTLRegionMake2D(0,0,64,64), mipmapLevel: 0, withBytes: &waterData, bytesPerRow: 128)
        let fog = texture(.r16Float, width: 1, height: 1)
        var density = Float16(0.8)
        fog.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &density, bytesPerRow: 2)
        func render(_ name: String, snow: Bool, frost: Bool, bright: Bool = false, rain: Bool = false) throws -> [UInt8] {
            var color: [UInt8] = bright ? [180, 190, 205, 255] : [8, 17, 30, 255]
            background.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &color, bytesPerRow: 4)
            let output = texture(.bgra8Unorm_srgb, width: 640, height: 400)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(winter.glassPipeline!)
            encoder.setFragmentTexture(background, index: 0)
            encoder.setFragmentTexture(background, index: 1)
            encoder.setFragmentTexture(rain ? water : empty, index: 2)
            encoder.setFragmentTexture(rain ? fog : empty, index: 3)
            encoder.setFragmentTexture(background, index: 4)
            encoder.setFragmentTexture(winter.snowTexture ?? empty, index: 5)
            encoder.setFragmentTexture(winter.frostTexture ?? empty, index: 6)
            encoder.setFragmentTexture(winter.contactTexture ?? empty, index: 7)
            let sampler = MTLSamplerDescriptor()
            sampler.minFilter = .linear; sampler.magFilter = .linear
            sampler.sAddressMode = .clampToEdge; sampler.tAddressMode = .clampToEdge
            encoder.setFragmentSamplerState(device.makeSamplerState(descriptor: sampler), index: 0)
            var settings = SIMD4<Float>(640, 400, rain ? 0.65 : 0, rain ? 1 : 0)
            var exposure: Float = 0
            var glass = rain ? SIMD4<Float>(0.45, 0, 0, 0.65) : .zero
            var effects = SIMD4<Float>(snow ? 1 : 0, frost ? winter.coverage : 0,
                                       snow && winter.contactTexture != nil ? 1 : 0, 0)
            encoder.setFragmentBytes(&settings, length: 16, index: 0)
            encoder.setFragmentBytes(&exposure, length: 4, index: 1)
            encoder.setFragmentBytes(&glass, length: 16, index: 2)
            encoder.setFragmentBytes(&effects, length: 16, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            assert(command.status == .completed)
            var bytes = [UInt8](repeating: 0, count: 640 * 400 * 4)
            output.getBytes(&bytes, bytesPerRow: 640 * 4, from: MTLRegionMake2D(0,0,640,400), mipmapLevel: 0)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 640 * 4, bitsPerPixel: 32)!
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bitmap.bitmapData![i] = bytes[i+2]; bitmap.bitmapData![i+1] = bytes[i+1]
                bitmap.bitmapData![i+2] = bytes[i]; bitmap.bitmapData![i+3] = 255
            }
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/RainGlassWinter-\(name).png"))
            return bytes
        }
        let baseline = try render("off", snow: false, frost: false)
        let snow = try render("snow", snow: true, frost: false)
        let frost = try render("frost", snow: false, frost: true)
        assert(snow != baseline && frost != baseline)
        let center = (200 * 640 + 320) * 4
        assert(abs(Int(frost[center]) - Int(baseline[center])) <= 1, "Moderate frost must leave the center readable")
        assert(frost[4 * (20 * 640 + 5)] > baseline[4 * (20 * 640 + 5)])
        let both = try render("both", snow: true, frost: true)
        let wetWinter = try render("rain-winter", snow: true, frost: true, rain: true)
        assert(wetWinter != both)
        _ = try render("bright", snow: true, frost: true, bright: true)
        winter.reset(seed: 99)
        encode()
        let reseeded = try render("reseeded", snow: false, frost: true)
        assert(reseeded != frost, "Changing seed must change the frost pattern")
        winter.reset(seed: 42)
        for _ in 0..<600 { winter.step(dt: 1 / 120) }
        encode()
        let repeatFrost = try render("repeat", snow: false, frost: true)
        assert(repeatFrost == frost, "Frost generation must be deterministic")
        for layout in WindowPaneLayout.allCases {
            winter.configure(snow: SnowSettings(amount: 0.5), frost: FrostSettings(coverage: 0.5),
                             frame: WindowFrameSettings(layout: layout))
            encode()
            _ = try render(layout.rawValue, snow: true, frost: true)
        }
        for quality in RenderQuality.allCases {
            winter.prepare(quality: quality, size: size)
            winter.step(dt: 1 / 120)
            encode()
            assert(winter.snowTexture!.width == (640 + quality.winterScale - 1) / quality.winterScale)
        }
        winter.configure(snow: .init(), frost: .init(), frame: .init())
        winter.prepare(quality: .balanced, size: size)
        for _ in 0..<600 { winter.step(dt: 1 / 120) }
        encode()
        assert(winter.textureBytes == 0 && winter.snowTexture == nil && winter.contactTexture == nil && winter.frostTexture == nil)
        // Measure only optional winter passes at a 4K drawable, excluding first-use cache generation.
        for enabled in [false, true] {
            winter.configure(snow: SnowSettings(amount: enabled ? 0.5 : 0),
                             frost: FrostSettings(coverage: enabled ? 0.5 : 0), frame: .init())
            winter.prepare(quality: .balanced, size: CGSize(width: 1920, height: 1080))
            for _ in 0..<600 { winter.step(dt: 1 / 120) }
            var gpu = 0.0
            for index in 0..<31 {
                let command = queue.makeCommandBuffer()!
                winter.step(dt: 1 / 60)
                winter.encode(commandBuffer: command, width: 3840, height: 2160, points: CGSize(width: 1920, height: 1080))
                command.commit(); command.waitUntilCompleted()
                assert(command.status == .completed)
                if index > 0 { gpu += max(0, command.gpuEndTime - command.gpuStartTime) * 1000 }
            }
            print("4K Balanced optional winter passes \(enabled ? "on" : "off"): \(gpu / 30) ms GPU, \(winter.textureBytes) texture bytes (excludes final glass composite)")
        }
        print("Runtime Metal compilation, winter pipelines, compositing, frost center, pane layouts, cache reuse, quality and release checked")
    }
}
