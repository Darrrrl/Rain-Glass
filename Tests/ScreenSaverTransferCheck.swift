import AppKit
import MetalKit
import ScreenSaver

private final class SceneResponder: NSObject {
    let image: Data
    let scene: Data
    let chunkSize = 64 * 1024
    var requests = 0

    init(image: Data, scene: Data) {
        self.image = image
        self.scene = scene
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(request(_:)),
                           name: ScreenSaverLifecycle.sceneRequest, object: nil)
        center.addObserver(self, selector: #selector(chunk(_:)),
                           name: ScreenSaverLifecycle.chunkRequest, object: nil)
    }

    @objc private func request(_ notification: Notification) {
        guard let token = notification.object as? String else { return }
        requests += 1
        DistributedNotificationCenter.default().post(
            name: ScreenSaverLifecycle.sceneResponse, object: token,
            userInfo: ["scene": scene, "chunks": (image.count + chunkSize - 1) / chunkSize,
                       "size": image.count])
    }

    @objc private func chunk(_ notification: Notification) {
        guard let request = notification.object as? String,
              let separator = request.lastIndex(of: "|"),
              let index = Int(request[request.index(after: separator)...]) else { return }
        let token = String(request[..<separator])
        let start = index * chunkSize
        guard start < image.count else { return }
        DistributedNotificationCenter.default().post(
            name: ScreenSaverLifecycle.chunkResponse, object: token,
            userInfo: ["index": index, "bytes": image.subdata(in: start..<min(start + chunkSize, image.count))])
    }
}

@main
struct ScreenSaverTransferCheck {
    static func main() throws {
        let saverURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let imageURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let image = try Data(contentsOf: imageURL)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RainGlassSaverTransfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        setenv("RAINGLASS_SAVER_TEST_DIRECTORY", directory.path, 1)
        let scene = ScreenSaverScene(version: 2, wallpaperFileName: "transferred.png",
                                     scaleMode: "fill", zoom: 1, rain: .rain,
                                     atmosphere: .init(), frame: .init(), quality: "eco", seed: "7",
                                     snow: SnowSettings(amount: 0.3), frost: FrostSettings(coverage: 0.4))
        let responder = SceneResponder(image: image, scene: try JSONEncoder().encode(scene))
        if CommandLine.arguments.contains("--stored") {
            try image.write(to: directory.appendingPathComponent(scene.wallpaperFileName))
            try ScreenSaverSceneStore.write(scene, in: directory)
        }
        _ = NSApplication.shared
        guard let bundle = Bundle(url: saverURL), bundle.load(),
              let saverClass = bundle.principalClass as? ScreenSaverView.Type,
              let view = saverClass.init(frame: NSRect(x: 0, y: 0, width: 320, height: 220), isPreview: true) else {
            throw NSError(domain: "ScreenSaverTransferCheck", code: 1)
        }
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = view
        view.startAnimation()
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        if CommandLine.arguments.contains("--stored") {
            assert(responder.requests == 0, "Stored scenes must load without requesting a transfer")
        } else {
            assert(responder.requests > 0, "The saver must request a scene when shared storage is unavailable")
        }
        assert(view.subviews.contains { $0 is MTKView }, "The transferred scene must start the Metal renderer")
        view.stopAnimation()
        print("Screen saver \(CommandLine.arguments.contains("--stored") ? "stored scene" : "scene transfer"), bundle loading, and renderer startup checked")
    }
}
