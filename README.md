# RainGlass

RainGlass is a native macOS app built with SwiftUI and MetalKit. It renders a chosen image behind a procedural rain scene.

## Run

Open `RainGlass.xcodeproj` in Xcode 27 and run the shared **RainGlass** scheme on macOS 15 or newer. The project uses `dev.rainglass.app` as its development bundle identifier and does not require a signing team for local builds.

Choose an image in the main window or in **RainGlass > Settings**. Settings offers Fill, Fit, and Stretch placement, rain modes, live scene controls, and named custom presets. RainGlass remembers a bookmark to the original image; if the file becomes unavailable, choose it again.

The developer overlay shows FPS, CPU time spent encoding and submitting each frame, and drawable pixel dimensions. The rain scene targets 60 FPS while its window is visible and pauses when the window is hidden. In Developer settings, enter an unsigned integer rain seed to reproduce the same initial droplet layout and motion.

Drizzle, Rain, Heavy Rain, and Storm are built-in starting points. Moving any slider switches to Custom without resetting existing drops. Use Save As to create a named preset; select one to rename or delete it. Scene settings and saved presets stay on this Mac.

## Boundaries

- **App** owns the SwiftUI lifecycle and persisted app settings.
- **Renderer** owns Metal resources, drawable presentation, and render diagnostics. UI does not encode Metal commands.
- **Wallpaper** owns user image selection, bookmarks, decoding, and texture upload.
- **Simulation** owns seeded droplet state and fixed-step movement; the renderer uploads its visual instances in one batched draw.
- **UI** owns the window content, settings controls, and diagnostic overlay.
- Future **Audio** and **Weather** areas will own their respective state and services. They will feed the renderer through explicit data rather than reaching into its Metal internals.

Drops merge when they touch, sliding drops collect smaller ones, and their trails fade. A half resolution water surface bends the cached wallpaper behind drops and trails, with subtle highlights over the lens effect. Audio and weather integration come later.

## Checks

Run the shared Xcode scheme in Debug or Release. From the repository root, run the standalone checks with:

```sh
swiftc RainGlass/Simulation/RainParameters.swift RainGlass/App/AppSettings.swift RainGlass/App/RainSettingsStore.swift RainGlass/Simulation/RainSimulation.swift Tests/RainSimulationCheck.swift -o /tmp/RainSimulationCheck
/tmp/RainSimulationCheck
swiftc RainGlass/Simulation/RainParameters.swift RainGlass/App/AppSettings.swift RainGlass/App/RainSettingsStore.swift Tests/RainSettingsCheck.swift -o /tmp/RainSettingsCheck
/tmp/RainSettingsCheck
```
