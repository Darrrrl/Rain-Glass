# RainGlass

RainGlass is a native macOS app built with SwiftUI and MetalKit. M0 presents a resizable Metal view that clears to a dark color. Rain and wallpaper rendering arrive in later milestones.

## Run

Open `RainGlass.xcodeproj` in Xcode 27 and run the shared **RainGlass** scheme on macOS 15 or newer. The project uses `dev.rainglass.app` as its development bundle identifier and does not require a signing team for local builds.

The standard **RainGlass > Settings** menu contains the developer overlay toggle. The overlay shows FPS, CPU time spent encoding and submitting each frame, and drawable pixel dimensions. It enables continuous rendering at a 60 FPS target; with the overlay off, Metal draws only when the view needs an update.

## Boundaries

- **App** owns the SwiftUI lifecycle and persisted app settings.
- **Renderer** owns Metal resources, drawable presentation, and render diagnostics. UI does not encode Metal commands.
- **UI** owns the window content, settings controls, and diagnostic overlay.
- Future **Simulation**, **Audio**, and **Weather** areas will own their respective state and services. They will feed the renderer through explicit data rather than reaching into its Metal internals.

No rain simulation, audio engine, or weather integration is part of M0.
