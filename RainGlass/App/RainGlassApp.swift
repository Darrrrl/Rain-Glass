import AppKit
import Combine
import SwiftUI

@main
struct RainGlassApp: App {
    @NSApplicationDelegateAdaptor(RainGlassAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("RainGlass", systemImage: "cloud.rain") {
            RainGlassMenuPanel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class RainGlassAppDelegate: NSObject, NSApplicationDelegate {
    let model = RainGlassModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }
}

@MainActor
final class RainGlassModel {
    let wallpaper = WallpaperController()
    let rainSettings = RainSettingsStore()
    let scenePresets = ScenePresetStore()
    let audio = AudioController()
    let weather = WeatherController()
    let desktop = DesktopWindowManager()
    let settingsPresentation = SettingsPresentation()
    let screenSaverScene = ScreenSaverScenePublisher()
    private var screenSaverAudioBridge: ScreenSaverAudioBridge?
    private var screenSaverTransferServer: ScreenSaverTransferServer?

    private var lightning: LightningCoordinator?
    private var wallpaperObservation: AnyCancellable?
    private var setupWindow: NSWindow?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        audio.start()
        screenSaverScene.start(model: self)
        screenSaverAudioBridge = ScreenSaverAudioBridge(audio: audio, desktop: desktop)
        screenSaverTransferServer = ScreenSaverTransferServer(model: self)
        weather.start()
        let coordinator = LightningCoordinator(rainSettings: rainSettings, weather: weather, audio: audio)
        coordinator.start()
        lightning = coordinator
        wallpaperObservation = wallpaper.$initialRestoreComplete
            .combineLatest(wallpaper.$texture)
            .sink { [weak self] completed, texture in
                guard let self, completed else { return }
                if texture == nil {
                    self.showSetup()
                } else {
                    self.setupWindow?.close()
                    self.startDesktop()
                }
            }
    }

    func showSetup() {
        if let setupWindow {
            setupWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 230),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Set Up RainGlass"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WallpaperSetupView(wallpaper: wallpaper))
            window.center()
            window.makeKeyAndOrderFront(nil)
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func testLightning() { lightning?.triggerForDebug(distanceMeters: 1_000) }

    func installScreenSaver() -> String {
        guard let saver = Bundle.main.url(forResource: "RainGlass", withExtension: "saver") else {
            return "The screen saver is missing from this build. Build the RainGlass scheme again."
        }
        guard NSWorkspace.shared.open(saver) else {
            return "macOS could not open the screen saver installer. Check the app's signing and try again."
        }
        return "Replacing the installed copy does not select it. In System Settings → Wallpaper → Screen Saver, open Other and choose RainGlass."
    }


    private func startDesktop() {
        desktop.start { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(DesktopContentView(wallpaper: self.wallpaper, rainSettings: self.rainSettings,
                                              audio: self.audio, weather: self.weather, desktop: self.desktop,
                                              flashState: self.lightning?.flashState))
        }
    }
}

private struct DesktopContentView: View {
    @ObservedObject var wallpaper: WallpaperController
    @ObservedObject var rainSettings: RainSettingsStore
    @ObservedObject var audio: AudioController
    @ObservedObject var weather: WeatherController
    @ObservedObject var desktop: DesktopWindowManager
    let flashState: LightningFlashState?

    var body: some View {
        ContentView(wallpaper: wallpaper, rainSettings: rainSettings, audio: audio, weather: weather,
                    flashState: flashState, paused: desktop.paused || desktop.systemSleeping || desktop.screenSaverActive,
                    onRendererError: { desktop.presentationFailed($0) })
    }
}

private struct RainGlassMenuPanel: View {
    let model: RainGlassModel
    @ObservedObject private var wallpaper: WallpaperController
    @ObservedObject private var rainSettings: RainSettingsStore
    @ObservedObject private var scenePresets: ScenePresetStore
    @ObservedObject private var audio: AudioController
    @ObservedObject private var desktop: DesktopWindowManager
    @ObservedObject private var presentation: SettingsPresentation
    @ObservedObject private var screenSaverScene: ScreenSaverScenePublisher
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var screenSaverMessage: String?

    init(model: RainGlassModel) {
        self.model = model
        wallpaper = model.wallpaper
        rainSettings = model.rainSettings
        scenePresets = model.scenePresets
        audio = model.audio
        desktop = model.desktop
        presentation = model.settingsPresentation
        screenSaverScene = model.screenSaverScene
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("RainGlass", systemImage: "cloud.rain")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(desktop.paused ? "Resume" : "Pause", systemImage: desktop.paused ? "play.fill" : "pause.fill") {
                    desktop.paused.toggle()
                }
                .labelStyle(.iconOnly)
                Button(audio.settings.muted ? "Unmute" : "Mute",
                       systemImage: audio.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    audio.setMuted(!audio.settings.muted)
                }
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            HStack {
                Picker("Preset", selection: Binding(get: { scenePresets.selectionID }, set: {
                    scenePresets.select($0, rain: rainSettings, audio: audio)
                })) {
                    Text("Custom").tag("custom")
                    ForEach(BuiltInScene.allCases) { preset in Text(preset.title).tag(preset.id) }
                    ForEach(scenePresets.presets) { preset in
                        Text(preset.name).tag("scene:\(preset.id.uuidString)")
                    }
                }
                Button("Choose Wallpaper…") { wallpaper.chooseImage() }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            HStack {
                Text("Volume").font(.caption)
                Slider(value: Binding(get: { audio.settings.master }, set: { audio.setMaster($0) }), in: 0...1)
                Text(String(format: "%.0f%%", audio.settings.master * 100))
                    .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            HStack {
                Text("Focus on drops").font(.caption)
                Slider(value: Binding(get: { rainSettings.parameters.blur }, set: {
                    rainSettings.edit(\.blur, value: $0)
                    scenePresets.markCustom()
                }), in: 0...64)
                .accessibilityLabel("Focus on drops")
                Text(String(format: "%.0f", rainSettings.parameters.blur))
                    .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            if wallpaper.texture == nil {
                Button("Complete Setup…") { model.showSetup() }
                    .padding(.top, 8)
            }
            if let error = desktop.errorMessage {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { desktop.retry() }
                }
                .font(.caption)
                .padding(.horizontal, 18)
                .padding(.top, 8)
            }
            if let error = audio.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 18).padding(.top, 8)
            }
            if let message = screenSaverMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 18).padding(.top, 8)
            }
            if let error = screenSaverScene.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 18).padding(.top, 8)
            }

            SettingsView(presentation: presentation, wallpaper: wallpaper, rainSettings: rainSettings,
                         scenePresets: scenePresets, audio: audio, weather: model.weather, desktop: desktop,
                         triggerLightning: { _ in model.testLightning() })
                .frame(height: 445)

            HStack {
                Text(wallpaper.displayName ?? "No wallpaper selected")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Install Screen Saver…") { screenSaverMessage = model.installScreenSaver() }
                    .font(.caption)
                Button("Quit RainGlass") { NSApp.terminate(nil) }
                    .font(.caption)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .background(reduceTransparency ? Color.black : Color.black.opacity(0.82))
        .preferredColorScheme(.dark)
    }
}
