import AppKit

@MainActor
final class ScreenSaverAudioBridge: NSObject {
    private let audio: AudioController
    private let desktop: DesktopWindowManager
    private var activeTokens: [String: Date] = [:]
    private var expiryTimer: Timer?

    init(audio: AudioController, desktop: DesktopWindowManager) {
        self.audio = audio
        self.desktop = desktop
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(active(_:)), name: ScreenSaverLifecycle.active, object: nil)
        center.addObserver(self, selector: #selector(stopped(_:)), name: ScreenSaverLifecycle.stopped, object: nil)
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireStaleTokens() }
        }
    }

    @objc private func active(_ notification: Notification) {
        guard let token = notification.object as? String else { return }
        activeTokens[token] = Date()
        updateOutput()
    }

    @objc private func stopped(_ notification: Notification) {
        guard let token = notification.object as? String else { return }
        activeTokens.removeValue(forKey: token)
        updateOutput()
    }

    private func expireStaleTokens() {
        activeTokens = activeTokens.filter { Date().timeIntervalSince($0.value) < 8 }
        updateOutput()
    }

    private func updateOutput() {
        let active = !activeTokens.isEmpty
        audio.setTemporarilySilent(active)
        desktop.screenSaverActive = active
    }

}
