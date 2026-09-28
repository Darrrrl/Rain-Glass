import AppKit
import Combine
import ImageIO
import MetalKit
import UniformTypeIdentifiers

enum WallpaperScaleMode: String, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var shaderValue: UInt32 {
        switch self {
        case .fill: 0
        case .fit: 1
        case .stretch: 2
        }
    }
}

@MainActor
final class WallpaperController: ObservableObject {
    let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    @Published private(set) var texture: MTLTexture?
    @Published private(set) var displayName: String?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var revision = 0

    @Published var scaleMode: WallpaperScaleMode {
        didSet { UserDefaults.standard.set(scaleMode.rawValue, forKey: AppSettings.wallpaperScaleModeKey) }
    }

    private var loadID = 0

    init() {
        let storedMode = UserDefaults.standard.string(forKey: AppSettings.wallpaperScaleModeKey)
        scaleMode = WallpaperScaleMode(rawValue: storedMode ?? "") ?? .fill
        Task { restoreWallpaper() }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a wallpaper image for RainGlass"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.loadWallpaper(at: url, remember: true)
            }
        }
    }

    private func restoreWallpaper() {
        guard let bookmark = UserDefaults.standard.data(forKey: AppSettings.wallpaperBookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            loadWallpaper(at: url, remember: stale)
        } catch {
            errorMessage = "The saved wallpaper could not be found. Choose it again."
        }
    }

    private func loadWallpaper(at url: URL, remember: Bool) {
        guard let device else {
            errorMessage = "Metal is unavailable on this Mac."
            return
        }
        loadID += 1
        let requestID = loadID
        isLoading = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let newTexture = try WallpaperDecoder.makeTexture(url: url, device: device)
                let bookmark = remember ? try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
                await self?.finishLoad(id: requestID, url: url, texture: newTexture, bookmark: bookmark)
            } catch {
                await self?.failLoad(id: requestID, error: error)
            }
        }
    }

    private func finishLoad(id: Int, url: URL, texture: MTLTexture, bookmark: Data?) {
        guard id == loadID else { return }
        self.texture = texture
        displayName = url.lastPathComponent
        revision += 1
        isLoading = false
        errorMessage = nil
        if let bookmark {
            UserDefaults.standard.set(bookmark, forKey: AppSettings.wallpaperBookmarkKey)
        }
    }

    private func failLoad(id: Int, error: Error) {
        guard id == loadID else { return }
        isLoading = false
        errorMessage = "Could not open the image: \(error.localizedDescription)"
    }
}

enum WallpaperDecoder {
    enum DecodeError: LocalizedError {
        case invalidImage
        case textureCreationFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: "The file is not a supported still image."
            case .textureCreationFailed: "The wallpaper could not be uploaded to Metal."
            }
        }
    }

    static func makeTexture(url: URL, device: MTLDevice) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw DecodeError.invalidImage
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 8192
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 8192
        let longEdge = max(width, height)
        let areaScale = min(1, sqrt(32_000_000 / max(width * height, 1)))
        let maxPixelSize = Int(max(1, min(longEdge * areaScale, 8192)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DecodeError.invalidImage
        }

        let alignment = device.minimumLinearTextureAlignment(for: .rgba8Unorm_srgb)
        let bytesPerRow = ((decoded.width * 4 + alignment - 1) / alignment) * alignment
        let bounds = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: decoded.width, height: decoded.height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ),
              let pixels = context.data else {
            throw DecodeError.invalidImage
        }
        // ImageIO thumbnails may use skip-first ARGB bytes; upload a known sRGB RGBA layout.
        context.setFillColor(CGColor(srgbRed: 0.045, green: 0.055, blue: 0.075, alpha: 1))
        context.fill(bounds)
        context.draw(decoded, in: bounds)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: decoded.width, height: decoded.height, mipmapped: true
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let staging = device.makeBuffer(bytes: pixels, length: bytesPerRow * decoded.height, options: .storageModeShared),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw DecodeError.textureCreationFailed
        }
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerRow * decoded.height,
            sourceSize: MTLSize(width: decoded.width, height: decoded.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw commandBuffer.error ?? DecodeError.textureCreationFailed
        }
        return texture
    }
}
