# RainGlass

Windows 11 and GNOME Wayland port work lives in [ports/README.md](ports/README.md).

RainGlass is a native macOS app built with SwiftUI and MetalKit. It renders a chosen image behind a procedural rain scene.

## Run

Open `RainGlass.xcodeproj` in Xcode 27 and run the shared **RainGlass** scheme on macOS 15 or newer. The project uses `dev.rainglass.app` as its development bundle identifier. Debug builds receive a local ad hoc signature after compilation. For distribution, sign the app and screen saver with your developer identity and the configured entitlements.

On first launch, choose a wallpaper in the small setup window. RainGlass then runs behind desktop icons on each display, without a normal app window or Dock icon. Click its menu bar icon for a compact controls panel with preset, pause, mute, volume, focus, wallpaper, and the Scene, Image, Sound, and App sections. Focus on drops softens the wallpaper while the drops continue to sample the sharp image. Closing the panel keeps the desktop rain and audio running. If the saved image becomes unavailable, the setup window helps choose another one. Start at Login uses the installed app's system registration and displays its actual status.

Scene presets include Cozy Window, Light Drizzle, Autumn Storm, Night Rain, Sleep, Quiet Snow, and Frosted Window. They change rain, lightning, atmosphere, and audio levels while preserving the wallpaper and quality mode. Save a custom scene and import or export it as versioned JSON. Existing saved rain-only presets remain available under Legacy rain preset in Scene settings.

The developer overlay shows FPS, CPU and GPU frame times, estimated render texture memory, and drawable pixel dimensions on the desktop. Eco targets 30 FPS, Balanced 60 FPS, and Ultra up to 120 FPS when the display supports it. Developer controls are collapsed under Diagnostics in App settings.

Drizzle, Rain, Heavy Rain, and Storm are built-in starting points. Moving any slider switches to Custom without resetting existing drops. Save a named preset in Scene controls; select one to export or delete it. Scene settings and saved presets stay on this Mac.

The app starts a quiet four-layer ambient mix on launch. Occasional larger drop arrivals can make softly synthesized glass taps; their separate volume defaults to 20%. Audio continues when the window is hidden; use the master mute or individual volume sliders in Settings. Storm enables lightning by default, with a frequency control in Custom. Each strike changes scene exposure and plays near or distant thunder after a distance-based delay. Bundled recording sources and licenses are listed in [Audio/SOURCES.md](RainGlass/Resources/Audio/SOURCES.md).

Real Weather is optional. Search for a city in Settings, select it, and enable live weather to drive rain, wind, cloud blur, and lightning. Current conditions are refreshed every 15 minutes from [Open-Meteo](https://open-meteo.com/); the last successful reading is cached for outages. Turn Real Weather off to return to the saved manual scene. The free Open-Meteo service is for noncommercial use; commercial distribution requires an appropriate provider plan. The Glass atmosphere section adds optional condensation, haze, and subtle imperfections. Condensation defaults to 45%; haze and imperfections default to off.

## Frost and snow (macOS)

Scene controls include independent Snow amount, flake size, speed, and wind, plus Frost coverage and crystal detail. Set amount or coverage to zero to disable that effect. Soft snow drifts behind the glass in three depth layers; occasional near flakes leave a brief icy contact mark. Thin, branching frost cracks grow inward from window and pane edges. Both can be combined with rain. Moving rain clears condensation but does not wipe frost. Changes preserve the rain settings and mark the scene Custom.

Quiet Snow pairs gentle snowfall with light frost. Frosted Window emphasizes ice without snowfall. Both turn rain and lightning off and use quiet existing wind/room ambience. Manual winter controls stay active with live weather; weather currently drives only rain, wind, clouds, and lightning. It does not fetch snowfall or temperature or change the audio mix.

Winter effects default off for older installations, presets, and screen saver snapshots. Presets with active winter effects export as version 2; other scenes still export as version 1. The macOS app accepts both versions. Windows/GNOME currently reject version 2. Importing adds a preset to the library without changing the active scene; select the imported preset to apply it. An older installed screen saver must be reinstalled to display winter scenes.

## Screen saver

The RainGlass build embeds `RainGlass.saver`. Choose **Install Screen Saver…** in the menu bar panel and accept the macOS installation prompt. Installing or replacing the bundle does not select it: open **System Settings → Wallpaper → Screen Saver → Other** and choose RainGlass. The screen saver mirrors the current wallpaper and visual settings in a fresh simulation. The app stores a copy of the wallpaper and settings in its App Group container when available, otherwise in Application Support, and can also transfer them directly to the separately hosted screen saver. Keep RainGlass running for that direct transfer. The screen saver has no audio engine; while it runs, the menu bar app temporarily silences audio and pauses its desktop renderers without changing saved mute or volume settings. macOS controls when the chosen saver appears on the Lock Screen.

## Boundaries

- **App** owns the SwiftUI lifecycle and persisted app settings.
- **Renderer** owns Metal resources, drawable presentation, and render diagnostics. UI does not encode Metal commands.
- **Wallpaper** owns user image selection, bookmarks, decoding, and texture upload.
- **Simulation** owns seeded droplet state and fixed-step movement; the renderer uploads its visual instances in one batched draw.
- **UI** owns the window content, settings controls, and diagnostic overlay.
- **Audio** owns playback, layer crossfades, and persistent volume settings; **Simulation** coordinates lightning timing.
- **Weather** owns city selection, cached current conditions, and the mapping into effective scene parameters.

Drops merge when they touch, sliding drops collect smaller ones, and their water traces fade. A quality-scaled water surface bends the cached wallpaper behind drops and trails. Condensation persists in a low resolution texture: moving drops wipe clear paths through it, and fog slowly returns. Fog softness and return time have separate controls.
Moving drops respond to a seeded adhesion pattern fixed to the glass, so they creep, pause, or slide at different speeds and curve smoothly with the surface and wind. Merges retain the surviving drop's center. Startup begins with scattered small beads, then fills over two seconds; replacements wait briefly and fade in without moving their centers. Larger drops sag and narrow toward their upper attachment; nearby stationary pairs can share a thin water bridge. Optional two, four, and six pane frames sit in front of the rain without changing the simulation.
The wallpaper can be zoomed from 1× to 3× in fill, fit, or stretch mode. The background blur control reaches 64 px; fog remains softer than the chosen wallpaper blur. Water traces retain their width as they fade, keeping adjoining sections connected.

## Checks

Run the shared Xcode scheme in Debug or Release. From the repository root, run the standalone checks with:

```sh
swiftc RainGlass/Simulation/RainParameters.swift RainGlass/App/AppSettings.swift RainGlass/App/RainSettingsStore.swift RainGlass/Simulation/RainSimulation.swift Tests/RainSimulationCheck.swift -o /tmp/RainSimulationCheck
/tmp/RainSimulationCheck
swiftc -O -assert-config Debug RainGlass/Simulation/RainParameters.swift RainGlass/Simulation/RainSimulation.swift Tests/RainWaterPolishCheck.swift -o /tmp/RainWaterPolishCheck
/tmp/RainWaterPolishCheck
swiftc -parse-as-library Tests/TrailJunctionCheck.swift -o /tmp/TrailJunctionCheck
/tmp/TrailJunctionCheck /tmp/RainGlassDerivedData/Build/Products/Debug/RainGlass.app/Contents/Resources/default.metallib
swiftc RainGlass/Simulation/RainParameters.swift RainGlass/App/VisualSettings.swift RainGlass/App/ScreenSaverScene.swift Tests/ScreenSaverSceneCheck.swift -o /tmp/ScreenSaverSceneCheck
/tmp/ScreenSaverSceneCheck
swiftc RainGlass/Simulation/RainParameters.swift RainGlass/App/VisualSettings.swift RainGlass/App/ScreenSaverScene.swift Tests/ScreenSaverTransferCheck.swift -o /tmp/ScreenSaverTransferCheck
/tmp/ScreenSaverTransferCheck /tmp/RainGlassDerivedData/Build/Products/Debug/RainGlass.app/Contents/Resources/RainGlass.saver RainGlass/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png
swiftc -O -assert-config Debug RainGlass/Simulation/RainParameters.swift RainGlass/Simulation/RainSimulation.swift Tests/RainArrivalCheck.swift -o /tmp/RainArrivalCheck
/tmp/RainArrivalCheck
swiftc -parse-as-library Tests/FogHistoryCheck.swift -o /tmp/FogHistoryCheck
/tmp/FogHistoryCheck /tmp/RainGlassDerivedData/Build/Products/Debug/RainGlass.app/Contents/Resources/default.metallib
swiftc RainGlass/Simulation/RainParameters.swift RainGlass/App/AppSettings.swift RainGlass/App/RainSettingsStore.swift Tests/RainSettingsCheck.swift -o /tmp/RainSettingsCheck
/tmp/RainSettingsCheck
swiftc RainGlass/App/AppSettings.swift RainGlass/App/VisualSettings.swift RainGlass/Simulation/RainParameters.swift RainGlass/App/RainSettingsStore.swift RainGlass/Audio/AudioSettings.swift RainGlass/Audio/AmbientAudioEngine.swift RainGlass/App/ScenePresetStore.swift Tests/ScenePresetCheck.swift -o /tmp/ScenePresetCheck
/tmp/ScenePresetCheck
swiftc RainGlass/App/AppSettings.swift RainGlass/App/DesktopWindowManager.swift Tests/DesktopModeCheck.swift -o /tmp/DesktopModeCheck
/tmp/DesktopModeCheck
swiftc RainGlass/Simulation/LightningTiming.swift Tests/LightningTimingCheck.swift -o /tmp/LightningTimingCheck
/tmp/LightningTimingCheck
swiftc -parse-as-library Tests/AudioAssetsCheck.swift -o /tmp/AudioAssetsCheck
/tmp/AudioAssetsCheck /tmp/RainGlassDerivedData/Build/Products/Debug/RainGlass.app
swiftc -parse-as-library RainGlass/App/AppSettings.swift RainGlass/Audio/AudioSettings.swift RainGlass/Audio/AmbientAudioEngine.swift Tests/AudioEngineCheck.swift -o /tmp/AudioEngineCheck
/tmp/AudioEngineCheck /tmp/RainGlassDerivedData/Build/Products/Debug/RainGlass.app
swiftc RainGlass/App/AppSettings.swift RainGlass/Wallpaper/WallpaperController.swift Tests/WallpaperColorCheck.swift -o /tmp/WallpaperColorCheck
/tmp/WallpaperColorCheck /tmp/RainGlassDerivedData/Build/Products/Debug/RainGlass.app/Contents/Resources/default.metallib
swiftc RainGlass/App/AppSettings.swift RainGlass/Wallpaper/WallpaperController.swift Tests/WallpaperSetupCheck.swift -o /tmp/WallpaperSetupCheck
/tmp/WallpaperSetupCheck
swiftc -parse-as-library Tests/WallpaperZoomCheck.swift -o /tmp/WallpaperZoomCheck
/tmp/WallpaperZoomCheck /tmp/RainGlassDerivedData/Build/Products/Debug/RainGlass.app/Contents/Resources/default.metallib
swiftc RainGlass/App/AppSettings.swift RainGlass/Simulation/RainParameters.swift RainGlass/Weather/WeatherProvider.swift RainGlass/Weather/WeatherController.swift Tests/WeatherCheck.swift -o /tmp/WeatherCheck
/tmp/WeatherCheck
```

### Winter and weather regression checks

```sh
swiftc RainGlass/App/VisualSettings.swift RainGlass/Simulation/SnowSimulation.swift Tests/SnowSimulationCheck.swift -o /tmp/SnowSimulationCheck
/tmp/SnowSimulationCheck
swiftc RainGlass/App/AppSettings.swift RainGlass/Simulation/RainParameters.swift RainGlass/Weather/WeatherProvider.swift RainGlass/Weather/WeatherController.swift Tests/WeatherRaceCheck.swift -o /tmp/WeatherRaceCheck
/tmp/WeatherRaceCheck
swiftc RainGlass/App/VisualSettings.swift RainGlass/Simulation/SnowSimulation.swift RainGlass/Renderer/WinterRenderer.swift Tests/WinterRenderCheck.swift -o /tmp/WinterRenderCheck
/tmp/WinterRenderCheck RainGlass/Renderer/WallpaperShaders.metal
```

The winter GPU check compiles the shader source through the Metal driver, checks compositing and resource release, and writes preview PNGs to `/tmp/RainGlassWinter-*.png`. FogHistoryCheck, TrailJunctionCheck, WallpaperColorCheck, and WallpaperZoomCheck also accept a `.metal` source path instead of a compiled library. This permits focused GPU checks without the offline Metal Toolchain; building the application and embedded saver still requires it.

## Desktop acceptance checks

The desktop level uses public Quartz levels, but its behavior needs verification on each supported macOS release in an installed build. Check that Finder icon clicks work, then switch Spaces, use Mission Control and Stage Manager, open a full-screen app, connect and disconnect displays with mixed scales, and sleep and wake. Confirm that a disconnected display's renderer and textures are released and that the menu bar shows a recoverable error if desktop presentation fails. The 30 minute performance test is intentionally skipped.

A local `swiftc` strict concurrency typecheck and focused scene preset and legacy preset checks can run without the Metal compiler. A complete Xcode build requires Xcode's Metal Toolchain component.

## Prioritized follow-ups

1. Respect Reduce Motion and offer a reduced-flash option.
2. Measure CPU/GPU, thermal and memory baselines; adapt to Low Power Mode and thermal pressure.
3. Extend live weather to snowfall and temperature while preserving manual winter settings.
4. Offer optional weather-linked audio mixing.
5. Bring winter effects to Windows/GNOME and complete native desktop lifecycle checks.

Snow accumulation, interactive frost wiping, and physical freezing/melting remain outside the first winter release.
