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

Build with the stable Rust toolchain and run `rainglass-desktop.exe`. RainGlass creates a tray icon and attempts to attach its surfaces to Explorer's WorkerW background, behind desktop icons. The menu provides wallpaper selection, pause, mute, presets, Settings, and Retry Desktop. Settings opens a compact separate controls window while desktop rain continues. It recreates the tray icon after Explorer restarts through `tray-icon`'s `TaskbarCreated` handling and checks the WorkerW parent periodically. Desktop placement uses an undocumented Explorer surface; verify icon clicks and retry after major Windows updates. `windows/RainGlass.iss` builds an Inno Setup installer.

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
rainglass-desktop --toggle-pause
rainglass-desktop --toggle-mute
rainglass-desktop --import-preset /path/to/preset.json
rainglass-desktop --export-preset "My preset" /path/to/export.json
rainglass-desktop --status
rainglass-desktop --settings
```

Preset imports accept the macOS version 1 scene JSON wrapper. Shared rain, atmosphere, audio, and frame fields are decoded with the same names and legacy defaults. Weather and lock-screen animation remain macOS-only for now.

## Verification status

Rust simulation tests and a GPU readback check for a blurred blue wallpaper run on macOS. The Windows target is type-checked from macOS. GitHub Actions builds and tests the native Windows and Linux targets. Desktop placement, GNOME Shell versions, Explorer restart behavior, multi-monitor scaling, and long-run performance still require hands-on testing on those operating systems before a release.
