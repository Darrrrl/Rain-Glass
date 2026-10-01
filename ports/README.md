# RainGlass desktop ports

This workspace builds a Rust desktop renderer for Windows 11 and GNOME Wayland. The macOS app remains in the repository root. The port shares one seeded simulation, settings format, audio mix, and wgpu/WGSL renderer; it does not run the macOS SwiftUI or Metal code.

## Build and try

```sh
cd ports
cargo test --locked --workspace
cargo run --release -p rainglass-desktop -- --windowed
```

`--windowed` is a diagnostic preview. For a desktop session, build with `cargo build --release -p rainglass-desktop`, then launch `target/release/rainglass-desktop` without arguments. The first launch asks for a wallpaper. JPEG, PNG, WebP, GIF, BMP, and TIFF are supported. The app saves its settings under the user config directory as `RainGlass/settings.json`.

The renderer samples an sRGB image into linear floating point wallpaper and Gaussian blur targets, then composites water, fog, and the optional frame into an sRGB display surface. It runs one scene per monitor. The Linux host caps at 30 FPS and reduces its internal resolution according to display size; the final surface stays at display resolution.

## Windows 11

Build with the stable Rust toolchain and .NET 10 SDK using `powershell -File ports/windows/build.ps1` from the repository root. It publishes a self-contained WPF companion beside the Rust engine and produces `ports/RainGlass-Windows.zip`; with Inno Setup 6 installed it also produces an installer. Extract the whole ZIP, retaining the `ui` directory, and run `rainglass-desktop.exe`. Installed and portable releases do not require a separately installed .NET runtime.

Either tray-button click toggles a 420-DIP WPF popup with Scene, Image, Sound and App tabs. Escape or clicking outside dismisses it while the wallpaper continues. File dialogs keep the popup alive. There is no context menu, taskbar button or Alt-Tab entry. System/Light/Dark themes are saved; System follows the Windows app theme. `--settings` opens the popup; launching another desktop instance opens the existing instance instead of creating duplicate wallpaper surfaces. RainGlass recreates the tray icon after Explorer restarts and checks its actual desktop parent periodically. Explorer placement uses an undocumented desktop surface, so icon clicks and shell recovery still need acceptance on each supported Windows release.

The popup covers rain, atmospheric fog, optional frames, image fitting/zoom, built-in and saved presets, import/export, six sound layers, mute/master volume, live weather, login startup, reconnect, audio retry, rain seed and a diagnostics overlay. Rust owns settings and engine state; the WPF companion uses a versioned, current-user-only named pipe and coalesces slider updates. Persistence is debounced. If the companion exits, the engine restarts it without stopping the wallpaper. No Windows screen saver is included.

Thunder uses one probability trial per second, globally across monitors: 0% never strikes and 100% strikes once per second. Lightning intensity and thunder volume are independent. Near/far thunder playback follows the flash after a distance-dependent delay. Glass taps use the macOS synthesis, with at most three arrivals per second. Live weather uses Open-Meteo city search/current conditions and retains manual values; weather overrides effective rain, wind, blur and storm frequency while enabled. Cached conditions remain available after request failures.

Launch without `--windowed` for the desktop background. The renderer is created as an Explorer child from the start, with no frame, activation, minimize button, taskbar button, or Alt-Tab entry. Both the older WorkerW layout and Windows 11's raised desktop under Progman are supported. The embedded Windows compatibility manifest enables layered child windows and per-monitor DPI awareness. After Explorer destroys or detaches a surface, RainGlass recreates its window and GPU surface. An attachment failure stays available as a tray error with Retry Desktop. Windows controls whether the tray icon appears beside the clock or inside the overflow menu.

Windows renders the sharp wallpaper and final output at the monitor's native physical resolution, independently of effects quality: 2560 × 1440 on a 1440p monitor and 3840 × 2160 on a 4K monitor. Use a sufficiently detailed source image; native output cannot restore detail missing from the image. Eco/Balanced/Ultra scale only the water/fog mask. The sharp wallpaper and Gaussian blur are cached until their inputs change. New Windows configurations start with blur off; previously saved values remain intact. The popup maps 0–100% blur onto the macOS 0–64 range.

The FPS slider spans zero to the popup monitor's refresh rate. Custom whole-number targets may exceed that rate; Monitor follows each display independently, with a 60-Hz fallback. VSync and GPU throughput can limit actual presentation. The saved `frame_rate` accepts legacy `"30"`, `"60"`, `"120"`, `"monitor"` and arbitrary `{"fixed":60}` targets. Existing quality-based targets and saved audio/blur values migrate without changing their meaning. Legacy thunder strikes/hour convert to probability/second. Fresh configurations default to 60 FPS. Zero freezes the current output and silences audio without changing mute/volume; Pause freezes visuals only.

Windows initially prefers Intel at 30/60 FPS and RTX for higher targets. Selecting a higher target can move an Intel scene to RTX. Lowering the target keeps the current adapter, avoiding measured multi-second stalls during rapid changes; restarting at 30/60 FPS restores the low-power preference. Fully covering applications pause visual rendering, and Explorer itself is excluded from that check. Audio initializes and mixes on its own thread.

### Windows diagnostics and earlier GPU comparison

Set `RAINGLASS_DIAGNOSTICS=1` before launching to log startup stages and five-second frame statistics: simulation, CPU mask, encoding/upload, acquisition/presentation, and sampled GPU timestamps when supported. `RAINGLASS_GPU=Intel` or `NVIDIA` selects a matching compatible adapter for comparison; `WGPU_BACKEND` can select a wgpu backend. Set `RAINGLASS_PROFILE_SECONDS=135` for a timed diagnostic session that renders even when covered and exits automatically. Use `RAINGLASS_CONFIG_DIR` for an isolated test configuration.

On 2026-10-01, the raised-desktop path was exercised on Windows 11 build 26200 at 2560 × 1440 / 165 Hz with Intel UHD and an RTX 4070 Laptop GPU (Vulkan backend). Isolated runs used Balanced effects, blur/condensation off, muted audio, and forced rendering behind other windows. The selected photograph was only 597 × 335 pixels; the separate 4K readback test uses a native 3840 × 2160 test image:

| Adapter / target | First five seconds | After 120 seconds / later samples |
| --- | --- | --- |
| Intel / 60 FPS | 59.3 FPS | 60.0 FPS through 130 seconds |
| RTX 4070 / 60 FPS | 59.9 FPS | 60.0 FPS through 130 seconds |
| Intel / 165 Hz | Higher target limited by presentation | About 103 FPS in the 10–30 second samples |
| RTX 4070 / 165 Hz | 162.3 FPS | 164–165 FPS in the 10–30 second samples |

The Intel adapter's acquisition/presentation cost rose to about 4.3 ms at the 165-Hz target; the RTX avoided that bottleneck. Automatic selection chose the RTX at 165 Hz and switched to Intel when 60 FPS was selected during playback. A final startup run presented its first frame after 3.34 seconds, including 2.11 seconds of GPU-instance initialization. The saved 30-FPS mode measured 29.8 FPS in its first five-second rendering sample. Both adapters attached without exposing an ordinary background window. The settings UI's frame-rate selection persisted, and closing Settings left the background process alive. A GPU readback test verifies one-pixel detail at 3840 × 2160 with Eco scaling, cached frames, blur toggles, zoom changes, and texture resizing. A physical 4K display, desktop icon/context-menu interactions, Win+D, Explorer restart, mixed-DPI monitors, and standby/wake still require manual acceptance. These measurements are not a promise of 60 FPS at 4K on every GPU.

### Popup verification (2026-10-01)

The final Windows run passed all 18 Rust workspace tests and the WPF self-tests. Coverage includes settings migration, weather/manual restoration, deterministic thunder scheduling, audio decoding, native 4K readback with blur/flash/resource changes, pipe framing and popup window styles. Both themes and all four tabs were rendered for inspection. An end-to-end run verified rapid slider changes, FPS 0/30/60/165/240/Monitor, preset import/export and live Vienna weather; original manual settings were restored.

With a 3840 × 2160 source image and native 2560 × 1440 output, a fresh process presented its first frame after 1.89 seconds, averaged 58.3 FPS in the first five-second sample and 60.0 FPS thereafter. A heavier scene with 4,800 drops and active audio held 59.9–60.1 FPS through 140 seconds. A collision-loop bug repeatedly merging consumed drops caused the observed CPU slowdown; a mass-conservation regression test now covers it. Terminating only the companion confirmed its recovery while the engine maintained 60 FPS. Lowering FPS now retains the current GPU, superseding the earlier automatic switch back to Intel described above.

The portable ZIP includes the .NET runtime. Inno Setup was unavailable locally, so the installer was not compiled here; its source and CI are updated. Physical 4K output, mixed-DPI placement, actual tray/outside-click and file-dialog interactions, desktop icon clicks, Win+D, Explorer restart and standby/wake remain manual acceptance checks. Hardware limits at 165 Hz are recorded above.

## GNOME 46–50 on Wayland

Install build requirements for GTK 3, ALSA, Wayland and Rust, then run `./install-gnome.sh`. Log out and back in, and enable `rainglass@dev.rainglass.app` in GNOME Extensions. The extension launches the renderer and places its compositor actors in GNOME Shell's background group; its top-bar menu provides wallpaper, pause, mute, presets, Settings, and Retry controls. Settings opens a separate controls window while rain keeps rendering. Disabling the extension releases those actors and stops its renderer process. The extension uses GNOME Shell's internal background group, which needs testing for each Shell release.

GNOME 49 and 50 expose a window-list hiding API on `Meta.Window`; GNOME 46–48 use `Meta.WaylandClient`. Both paths need a Shell-session acceptance pass before release.

## Commands

The desktop process notices setting changes within half a second. These commands can be run while it is open:

```sh
rainglass-desktop --choose-wallpaper
rainglass-desktop --wallpaper /path/to/image.jpg
rainglass-desktop --preset cozy
rainglass-desktop --blur 16
rainglass-desktop --zoom 1.5
rainglass-desktop --fps monitor
rainglass-desktop --toggle-pause
rainglass-desktop --toggle-mute
rainglass-desktop --import-preset /path/to/preset.json
rainglass-desktop --export-preset "My preset" /path/to/export.json
rainglass-desktop --status
rainglass-desktop --settings
```

Preset imports accept the macOS version 1 scene JSON wrapper. Shared rain, atmosphere, audio, and frame fields retain their names and legacy defaults. Live weather is available on Windows; the screen saver remains outside this change.

## Verification status

Rust simulation, configuration migration/persistence, audio decoding, and GPU readback tests run on Windows. GitHub Actions builds and tests the native Windows and Linux targets. The Windows measurements and remaining acceptance checks are listed above. GNOME Shell versions, multi-monitor scaling, and long-run performance still require hands-on testing before a release.
