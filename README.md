# RainGlass

RainGlass is a native macOS app built with SwiftUI and MetalKit. It renders a chosen image behind a glass scene. The first rain simulation is being added in M2.

## Run

Open `RainGlass.xcodeproj` in Xcode 27 and run the shared **RainGlass** scheme on macOS 15 or newer. The project uses `dev.rainglass.app` as its development bundle identifier and does not require a signing team for local builds.

Choose an image in the main window or in **RainGlass > Settings**. Settings also offers Fill, Fit, and Stretch placement and a subtle blur slider. RainGlass remembers a bookmark to the original image; if the file becomes unavailable, choose it again.

The developer overlay shows FPS, CPU time spent encoding and submitting each frame, and drawable pixel dimensions. In M1 it enables continuous rendering at a 60 FPS target; with the overlay off, the static wallpaper draws only when it needs an update.

## Boundaries

- **App** owns the SwiftUI lifecycle and persisted app settings.
- **Renderer** owns Metal resources, drawable presentation, and render diagnostics. UI does not encode Metal commands.
- **Wallpaper** owns user image selection, bookmarks, decoding, and texture upload.
- **UI** owns the window content, settings controls, and diagnostic overlay.
- Future **Simulation**, **Audio**, and **Weather** areas will own their respective state and services. They will feed the renderer through explicit data rather than reaching into its Metal internals.

Audio and weather integration are later milestones.
