import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ScreenSaverTransferServer: NSObject {
    private static let chunkSize = 64 * 1024
    private weak var model: RainGlassModel?
    private var preparingRevision = -1
    private var cachedRevision = -1
    private var cachedImage: Data?
    private var cachedName = "transferred.jpg"
    private var pendingTokens = Set<String>()
    private var transfers: [String: (scene: Data, image: Data)] = [:]

    init(model: RainGlassModel) {
        self.model = model
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(sceneRequested(_:)),
                           name: ScreenSaverLifecycle.sceneRequest, object: nil)
        center.addObserver(self, selector: #selector(chunkRequested(_:)),
                           name: ScreenSaverLifecycle.chunkRequest, object: nil)
        center.addObserver(self, selector: #selector(stopped(_:)),
                           name: ScreenSaverLifecycle.stopped, object: nil)
    }

    @objc private func sceneRequested(_ notification: Notification) {
        guard let token = notification.object as? String, UUID(uuidString: token) != nil,
              let model, let source = model.wallpaper.currentURL,
              model.wallpaper.texture != nil else { return }
        let revision = model.wallpaper.revision
        pendingTokens.insert(token)
        if cachedRevision == revision, cachedImage != nil {
            answerPending()
            return
        }
        guard preparingRevision != revision else { return }
        preparingRevision = revision
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try Self.prepareImage(from: source) }
            await MainActor.run {
                guard let self else { return }
                if self.preparingRevision == revision { self.preparingRevision = -1 }
                guard self.model?.wallpaper.revision == revision else { return }
                if case .success(let prepared) = result {
                    self.cachedRevision = revision
                    self.cachedImage = prepared.data
                    self.cachedName = prepared.name
                    self.answerPending()
                }
            }
        }
    }

    private func answerPending() {
        guard let model, let image = cachedImage,
              let scene = model.screenSaverScene.makeScene(wallpaperFileName: cachedName),
              let sceneData = try? JSONEncoder().encode(scene) else { return }
        let count = (image.count + Self.chunkSize - 1) / Self.chunkSize
        for token in pendingTokens {
            transfers[token] = (sceneData, image)
            DistributedNotificationCenter.default().post(
                name: ScreenSaverLifecycle.sceneResponse, object: token,
                userInfo: ["scene": sceneData, "chunks": count, "size": image.count])
        }
        pendingTokens.removeAll()
    }

    @objc private func chunkRequested(_ notification: Notification) {
        guard let request = notification.object as? String,
              let separator = request.lastIndex(of: "|"),
              let index = Int(request[request.index(after: separator)...]) else { return }
        let token = String(request[..<separator])
        guard let transfer = transfers[token], index >= 0 else { return }
        let start = index * Self.chunkSize
        guard start < transfer.image.count else { return }
        let end = min(start + Self.chunkSize, transfer.image.count)
        DistributedNotificationCenter.default().post(
            name: ScreenSaverLifecycle.chunkResponse, object: token,
            userInfo: ["index": index, "bytes": transfer.image.subdata(in: start..<end)])
    }

    @objc private func stopped(_ notification: Notification) {
        guard let token = notification.object as? String else { return }
        transfers.removeValue(forKey: token)
        pendingTokens.remove(token)
    }

    nonisolated private static func prepareImage(from source: URL) throws -> (data: Data, name: String) {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        if (attributes[.size] as? NSNumber)?.intValue ?? .max <= 8 * 1024 * 1024 {
            return (try Data(contentsOf: source), "transferred.\(source.pathExtension.isEmpty ? "image" : source.pathExtension)")
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, thumbnail,
                                  [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return (output as Data, "transferred.jpg")
    }
}
