import AppKit
import Combine
import CoreGraphics
import SwiftUI
import OSLog
import Metal

@MainActor
final class DesktopWindowManager: ObservableObject {
    private let log = Logger(subsystem: "dev.rainglass.app", category: "desktop")
    @Published var paused: Bool {
        didSet { defaults.set(paused, forKey: AppSettings.pausedKey) }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var systemSleeping = false
    @Published var screenSaverActive = false

    private let defaults: UserDefaults
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    private var scene: (() -> AnyView)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        paused = defaults.bool(forKey: AppSettings.pausedKey)
        // A previous release could save window mode. RainGlass now always presents on the desktop.
        defaults.set("desktop", forKey: AppSettings.presentationModeKey)
    }

    func start(scene: @escaping () -> AnyView) {
        guard self.scene == nil else { return }
        self.scene = scene
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke),
                                                           name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping),
                                                           name: NSWorkspace.willSleepNotification, object: nil)
        reconcile()
    }

    @objc private func woke(_ notification: Notification) { systemSleeping = false; reconcile() }
    @objc private func sleeping(_ notification: Notification) { systemSleeping = true }
    @objc private func screenChanged(_ notification: Notification) { reconcile() }

    func presentationFailed(_ message: String) { fail(message) }

    func retry() {
        for window in windows.values {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows.removeAll()
        reconcile()
    }

    func reconcile() {
        guard let scene else { return }
        guard MTLCreateSystemDefaultDevice() != nil else {
            fail("Desktop mode needs a Mac with Metal support.")
            return
        }
        if systemSleeping { return }
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        guard desktopLevel + 1 < iconLevel else {
            fail("This macOS version does not provide a desktop layer below icons.")
            return
        }
        let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen)
        }
        guard !screens.isEmpty else {
            fail("No display is available for Desktop mode.")
            return
        }
        let connected = Set(screens.map(\.0))
        for id in windows.keys.filter({ !connected.contains($0) }) {
            if let window = windows.removeValue(forKey: id) {
                window.orderOut(nil)
                window.contentView = nil // releases the display's renderer and textures
                window.close()
            }
        }
        for (id, screen) in screens {
            if let window = windows[id] {
                window.setFrame(screen.frame, display: true)
            } else {
                let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false, screen: screen)
                window.level = NSWindow.Level(rawValue: desktopLevel + 1)
                window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                window.ignoresMouseEvents = true
                window.isOpaque = true
                window.backgroundColor = .black
                window.hasShadow = false
                window.contentView = NSHostingView(rootView: scene())
                window.setFrame(screen.frame, display: true)
                window.orderFrontRegardless()
                windows[id] = window
            }
        }
        errorMessage = nil
    }

    private func fail(_ message: String) {
        log.error("Desktop presentation failed: \(message, privacy: .public)")
        errorMessage = message
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
