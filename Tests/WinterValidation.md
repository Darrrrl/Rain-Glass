# Winter validation — 2026-10-04

## Snow on glass and cracked frost update — 2026-10-05

- Snow now uses a soft Gaussian flake without a hard center. Seeded near flakes sometimes leave bounded, stationary 3–7 arm marks that fade in under one second; the simulation check measures contact frequency at 1440 × 900 Balanced, and checks determinism, pause, resize, bounds, and release.
- A separate contact texture composites over condensation and edge frost. Its allocation is included in winter texture diagnostics and is released with the snow. Frost uses irregular seeded fracture cells with shorter detail branches while retaining the edge veil and coverage animation.
- Runtime Metal checks passed for dark, bright, snow-only, frost-only, combined, and rain-plus-winter samples, pane layouts, quality modes, cache reuse, seed repeatability, and zero-effect texture release. The generated PNG samples were visually inspected. The 4K Balanced optional winter passes averaged about 0.14 ms GPU over 30 warmed frames in this run; this excludes final glass compositing and display presentation.
- Focused rain simulation and screen saver scene checks passed. Both screen saver transfer and stored-scene startup passed in a temporary preview. Debug and Release app and screen saver builds passed.
- A user-run desktop check remains: inspect snow and frost over the current wallpaper on the actual display, including contact timing and pane edges. The synthetic Metal samples cannot establish appearance over that wallpaper or on a full desktop session.

## Passed

- Swift typecheck of all app and screen saver sources with complete concurrency diagnostics. Existing audio deprecation and concurrency warnings remain.
- SnowSimulationCheck: seeded repeatability, three layers, particle bounds, pause, resize, fade-out, reset and invalid settings.
- ScenePresetCheck: winter/legacy persistence, version selection, invalid values, imports preserving selection, preset application and returning to rain.
- ScreenSaverSceneCheck: version 1 defaults, version 2 winter round trip, unknown versions and image path validation.
- WeatherCheck and WeatherRaceCheck: mapping, manual restoration, cache retention, overlapping searches, cancelled results, city changes, disabled refresh and stale timestamps.
- Existing RainSimulationCheck, RainWaterPolishCheck, RainArrivalCheck, RainSettingsCheck and LightningTimingCheck.
- Runtime Metal compilation and WinterRenderCheck: snowfall/frost rendering, combined rain/fog/winter, dark/bright backgrounds, seed repeatability, all pane layouts and quality modes, cache reuse and resource release. Generated PNG samples were visually inspected; frost contrast was reduced after the first pass.
- Existing FogHistoryCheck, TrailJunctionCheck, WallpaperZoomCheck and WallpaperColorCheck using runtime shader compilation.
- Five Rust core tests, including rejection of version 2 winter presets.
- `git diff --check`.
- Debug and Release Xcode app/saver builds with Metal Toolchain 27A266a installed; packaged Metal shaders and all 14 bundled audio files pass their focused checks.
- ScreenSaverTransferCheck passes both version 2 stored-scene and direct-transfer startup using isolated temporary storage.
- RenderDiagnosticsCheck verifies that size, GPU, and frame metrics publish once after the view update instead of synchronously during it.

## Limited performance sample

At a 3840 × 2160 drawable in Balanced quality, the optional winter passes used 11,980,800 texture bytes and averaged approximately 0.029 ms GPU over 30 warmed samples. Disabled winter used zero winter texture bytes and encoded no winter passes. This measures the optional passes only: it excludes the final glass composite, initial frost generation, application/UI work and display presentation. It is not an application FPS or power-use benchmark.

## Still requires desktop acceptance

The app and saver bundle build, and a temporary preview verifies both saver loading paths. Installed desktop/saver handoff, mixed-scale monitors, sleep/wake, Spaces, full-screen applications, and real display frame pacing remain unverified. The user is controlling the running app; the paused-wallpaper fix is awaiting their visual confirmation after reopening the rebuilt version. Reinstall the newly built saver before testing it through macOS System Settings. No long-duration power or thermal run was performed.
