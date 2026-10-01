#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

mod audio;
#[cfg(target_os = "windows")]
mod controls;
mod diagnostics;
mod mask;
mod renderer;
mod settings_store;
#[cfg(not(target_os = "windows"))]
mod settings_ui;
mod storm;
#[cfg(target_os = "windows")]
mod windows_desktop;

use rainglass_core::{
    settings::{AppSettings, Quality},
    simulation::Simulation,
};
use std::{
    path::Path,
    sync::Arc,
    time::{Duration, Instant, SystemTime},
};
use winit::{
    application::ApplicationHandler,
    dpi::PhysicalSize,
    event::WindowEvent,
    event_loop::{ActiveEventLoop, ControlFlow, EventLoop},
    window::{Window, WindowId},
};

struct Scene {
    window: Arc<Window>,
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    renderer: renderer::SceneRenderer,
    simulation: Simulation,
    last_frame: Instant,
    next_frame: Instant,
    refresh_millihertz: Option<u32>,
    stats: diagnostics::FrameStats,
    first_frame: bool,
    fps_started: Instant,
    fps_frames: u32,
    measured_fps: f64,
    adapter_target_high: bool,
    accumulator: f32,
    #[cfg(target_os = "windows")]
    parent: Option<windows_desktop::DesktopHost>,
    #[cfg(target_os = "windows")]
    desktop_position: winit::dpi::PhysicalPosition<i32>,
    #[cfg(target_os = "windows")]
    overlay: windows_desktop::DiagnosticsOverlay,
}

struct App {
    store: settings_store::SettingsStore,
    settings: AppSettings,
    modified: Option<SystemTime>,
    instance: wgpu::Instance,
    scenes: Vec<Scene>,
    audio: Option<audio::AudioWorker>,
    started: Instant,
    next_reload: Instant,
    next_desktop_retry: Instant,
    windowed: bool,
    profile_seconds: Option<f64>,
    monitor_signature: Vec<String>,
    last_error: Option<String>,
    recreate_scenes: bool,
    storm: storm::Storm,
    #[cfg(target_os = "windows")]
    controls: controls::Controls,
    #[cfg(target_os = "windows")]
    weather: controls::WeatherWorker,
    #[cfg(target_os = "windows")]
    next_weather: Instant,
    #[cfg(target_os = "windows")]
    next_snapshot: Instant,
    #[cfg(target_os = "windows")]
    save_at: Option<Instant>,
    #[cfg(target_os = "windows")]
    control_error: Option<String>,
    #[cfg(target_os = "windows")]
    weather_error: Option<String>,
    #[cfg(target_os = "windows")]
    weather_search: serde_json::Value,
    #[cfg(target_os = "windows")]
    pending_toggle: Option<(i32, i32)>,
    #[cfg(target_os = "windows")]
    selected_preset: String,
    #[cfg(target_os = "windows")]
    single_instance: Option<controls::SingleInstance>,
    #[cfg(target_os = "windows")]
    open_popup: bool,
    #[cfg(target_os = "windows")]
    tray: Option<windows_desktop::TrayControls>,
}

impl App {
    fn reload(&mut self) {
        #[cfg(target_os = "windows")]
        if self.save_at.is_some() {
            return;
        }
        let modified = std::fs::metadata(&self.store.path)
            .and_then(|m| m.modified())
            .ok();
        if modified == self.modified {
            return;
        }
        self.modified = modified;
        let next = self.store.load();
        #[cfg(target_os = "windows")]
        let next = {
            let mut next = next;
            next.start_at_login = controls::startup_enabled();
            next
        };
        self.apply_settings(next);
    }
    fn apply_settings(&mut self, next: AppSettings) {
        let seed_changed = next.seed != self.settings.seed;
        let image_changed = next.wallpaper != self.settings.wallpaper;
        if image_changed && self.scenes.is_empty() {
            self.recreate_scenes = true;
        }
        let quality_changed = next.quality != self.settings.quality;
        let rate_changed = next.frame_rate != self.settings.frame_rate;
        #[cfg(target_os = "windows")]
        if rate_changed
            && self.scenes.iter().any(|scene| {
                next.frame_rate.hz(scene.refresh_millihertz) > 60.0 && !scene.adapter_target_high
            })
        {
            self.recreate_scenes = true;
        }
        for (index, scene) in self.scenes.iter_mut().enumerate() {
            if seed_changed {
                scene.simulation = Simulation::new(
                    next.seed.wrapping_add(index as u64),
                    scene.config.width as f32,
                    scene.config.height as f32,
                );
            }
            if rate_changed {
                scene.next_frame = Instant::now();
                scene.last_frame = Instant::now();
                scene.accumulator = 0.0;
                scene.fps_started = Instant::now();
                scene.fps_frames = 0;
            }
            scene
                .simulation
                .set_parameters(next.weather.effective(next.rain));
            if quality_changed {
                scene.renderer.resize(
                    &scene.device,
                    [scene.config.width, scene.config.height],
                    render_scale([scene.config.width, scene.config.height], next.quality),
                );
            }
            if image_changed {
                if let Some(path) = &next.wallpaper {
                    match renderer::SceneRenderer::load(
                        &scene.device,
                        &scene.queue,
                        scene.config.format,
                        Path::new(path),
                        [scene.config.width, scene.config.height],
                        render_scale([scene.config.width, scene.config.height], next.quality),
                    ) {
                        Ok(renderer) => scene.renderer = renderer,
                        Err(e) => eprintln!("RainGlass wallpaper: {e}"),
                    }
                }
            }
        }
        #[cfg(target_os = "windows")]
        if next.weather.city != self.settings.weather.city
            || next.weather.enabled != self.settings.weather.enabled
        {
            self.next_weather = Instant::now();
        }
        self.settings = next;
    }
    #[cfg(target_os = "windows")]
    fn controls_tick(&mut self, event_loop: &ActiveEventLoop, now: Instant) {
        self.controls.ensure_running();
        let anchor = self.tray.as_ref().and_then(|t| t.anchor()).or_else(|| {
            event_loop.primary_monitor().map(|m| {
                (
                    m.position().x + m.size().width as i32 - 24,
                    m.position().y + m.size().height as i32 - 48,
                )
            })
        });
        if self.open_popup {
            if let Some(anchor) = anchor {
                self.pending_toggle = Some(anchor);
                self.open_popup = false;
                self.next_snapshot = now;
            }
        }
        if self
            .single_instance
            .as_ref()
            .is_some_and(|i| i.take_open_request())
        {
            self.pending_toggle = anchor;
            self.next_snapshot = now;
        }
        if let Some(anchor) = self.tray.as_ref().and_then(|tray| tray.poll()) {
            self.pending_toggle = Some(anchor);
            self.next_snapshot = now;
        }
        let commands: Vec<_> = self.controls.commands.try_iter().collect();
        for command in commands {
            let name = command["command"].as_str().unwrap_or("");
            self.control_error = None;
            match name {
                "quit" => {
                    if self.save_at.take().is_some() {
                        let _ = self.store.save(&self.settings);
                    }
                    event_loop.exit();
                    return;
                }
                "retry_desktop" => self.recreate_scenes = true,
                "retry_audio" => self.audio = Some(audio::AudioWorker::start()),
                "test_lightning" => self.storm.trigger(self.started.elapsed().as_secs_f64()),
                "search_weather" => {
                    self.weather.search(command["data"].as_str().unwrap_or(""));
                }
                "refresh_weather" => self.next_weather = now,
                _ => match controls::edit(&self.settings, &command) {
                    Ok(Some(next)) => {
                        self.selected_preset = if name == "preset" {
                            command["data"].as_str().unwrap_or("Custom").into()
                        } else if name == "save_preset" {
                            command["data"].as_str().unwrap_or("Custom").trim().into()
                        } else if name == "delete_preset"
                            && command["data"].as_str() == Some(self.selected_preset.as_str())
                        {
                            "Custom".into()
                        } else if name == "patch"
                            && command["data"].as_object().is_some_and(|values| {
                                values.keys().any(|key| {
                                    ["rain.", "audio.", "atmosphere.", "frame."]
                                        .iter()
                                        .any(|prefix| key.starts_with(prefix))
                                })
                            })
                        {
                            "Custom".into()
                        } else {
                            self.selected_preset.clone()
                        };
                        self.apply_settings(next);
                        self.save_at = Some(now + Duration::from_millis(200));
                    }
                    Ok(None) => (),
                    Err(e) => self.control_error = Some(e),
                },
            }
            self.next_snapshot = now;
        }
        if self.save_at.is_some_and(|at| now >= at) {
            self.save_at = None;
            if let Err(e) = self.store.save(&self.settings) {
                self.control_error = Some(e);
            }
            self.modified = std::fs::metadata(&self.store.path)
                .and_then(|m| m.modified())
                .ok();
        }
        for result in self.weather.results.try_iter() {
            match result {
                controls::WeatherResult::Search(_query, result) => match result {
                    Ok(results) => {
                        self.weather_search = results;
                        self.weather_error = None;
                    }
                    Err(e) => self.weather_error = Some(format!("City search failed: {e}")),
                },
                controls::WeatherResult::Current(city, result)
                    if self.settings.weather.enabled
                        && self.settings.weather.city.as_ref() == Some(&city) =>
                {
                    match result {
                        Ok(conditions) => {
                            self.settings.weather.cached = Some(conditions);
                            self.weather_error = None;
                            self.save_at = Some(now + Duration::from_millis(200));
                        }
                        Err(e) => {
                            self.weather_error = Some(format!(
                                "Weather update failed; using cached conditions: {e}"
                            ))
                        }
                    }
                }
                _ => (),
            }
            self.next_snapshot = now;
        }
        if now >= self.next_weather {
            self.next_weather = now + Duration::from_secs(15 * 60);
            if self.settings.weather.enabled {
                if let Some(city) = &self.settings.weather.city {
                    self.weather.refresh(city);
                }
            }
        }
        let effective = self.settings.weather.effective(self.settings.rain);
        for scene in &mut self.scenes {
            scene.simulation.set_parameters(effective);
            let fps = if self.settings.paused
                || self.settings.frame_rate.hz(scene.refresh_millihertz) == 0.0
                || scene.fps_started.elapsed().as_secs_f64() > 2.0
            {
                0.0
            } else {
                scene.measured_fps
            };
            scene.overlay.update(self.settings.diagnostics_overlay, format!("RainGlass  |  {} x {} native\r\n{:.1} FPS  |  {:.1} Hz  |  {} drops\r\nSeed {}", scene.config.width, scene.config.height, fps, rainglass_core::settings::FrameRate::Monitor.hz(scene.refresh_millihertz), scene.simulation.drops.len(), self.settings.seed));
        }
        if self.recreate_scenes {
            self.recreate_scenes = false;
            self.scenes.clear();
            self.resumed(event_loop);
        }
        if now >= self.next_snapshot {
            self.next_snapshot = now + Duration::from_millis(500);
            let audio_error = self
                .audio
                .as_ref()
                .and_then(|a| a.status.lock().ok().and_then(|s| s.clone()));
            let error = self
                .control_error
                .as_ref()
                .or(self.controls.error.as_ref())
                .or(self.last_error.as_ref())
                .or(audio_error.as_ref());
            if let Some(tray) = &self.tray {
                tray.set_status(
                    error
                        .map(String::as_str)
                        .unwrap_or("RainGlass — click for controls"),
                );
            }
            let displays: Vec<_> = event_loop.available_monitors().map(|m| serde_json::json!({"x":m.position().x,"y":m.position().y,"width":m.size().width,"height":m.size().height,"hz": rainglass_core::settings::FrameRate::Monitor.hz(m.refresh_rate_millihertz())})).collect();
            let weather_status = self.weather_error.clone().unwrap_or_else(|| {
                if let Some(c) = &self.settings.weather.cached {
                    let age = SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs()
                        .saturating_sub(c.fetched_at);
                    format!(
                        "{} · {:.1} mm/h rain · {:.0} km/h wind · {:.0}% cloud{}",
                        self.settings
                            .weather
                            .city
                            .as_ref()
                            .map(|c| c.name.as_str())
                            .unwrap_or(""),
                        c.precipitation,
                        c.wind_speed,
                        c.cloud_cover,
                        if age > 1800 {
                            " · cached, older than 30 minutes"
                        } else {
                            ""
                        }
                    )
                } else {
                    "Choose a city to use live weather.".into()
                }
            });
            let fps = self
                .scenes
                .iter()
                .map(|s| {
                    format!(
                        "{}×{}: {:.1} FPS / {:.1} Hz",
                        s.config.width,
                        s.config.height,
                        if self.settings.paused
                            || self.settings.frame_rate.hz(s.refresh_millihertz) == 0.0
                            || s.fps_started.elapsed().as_secs_f64() > 2.0
                        {
                            0.0
                        } else {
                            s.measured_fps
                        },
                        rainglass_core::settings::FrameRate::Monitor.hz(s.refresh_millihertz)
                    )
                })
                .collect::<Vec<_>>()
                .join(" · ");
            self.controls.send(serde_json::json!({"version":1, "settings":self.settings, "status": if self.settings.paused { "Visuals paused" } else { "RainGlass running" }, "error":error,
                "preset":self.selected_preset, "monitors":displays, "weather_results":self.weather_search, "weather_status":weather_status, "fps_status":fps,
                "toggle":self.pending_toggle.take().map(|(x,y)| serde_json::json!({"x":x,"y":y}))}));
        }
    }
    fn create_scene(
        &self,
        event_loop: &ActiveEventLoop,
        index: usize,
        monitor: Option<winit::monitor::MonitorHandle>,
        path: &Path,
    ) -> Result<Scene, String> {
        let started = Instant::now();
        let size = monitor
            .as_ref()
            .map(|m| m.size())
            .unwrap_or(PhysicalSize::new(1200, 800));
        #[allow(unused_mut)]
        let mut attrs = Window::default_attributes()
            .with_title(format!("RainGlass Background {index}"))
            .with_inner_size(size)
            .with_decorations(self.windowed)
            .with_visible(false);
        #[cfg(target_os = "linux")]
        {
            use winit::platform::wayland::WindowAttributesExtWayland;
            attrs = attrs.with_name("rainglass-renderer", "rainglass-renderer");
        }
        #[cfg(target_os = "windows")]
        let parent = if self.windowed {
            None
        } else {
            Some(windows_desktop::desktop_host()?)
        };
        #[cfg(target_os = "windows")]
        {
            use winit::platform::windows::WindowAttributesExtWindows;
            attrs = attrs
                .with_skip_taskbar(!self.windowed)
                .with_active(self.windowed);
            if let Some(ref monitor) = monitor {
                attrs = attrs.with_position(monitor.position());
            }
            if let Some(host) = parent {
                attrs = host
                    .attributes(attrs)
                    .with_resizable(false)
                    .with_enabled_buttons(winit::window::WindowButtons::empty());
            }
        }
        let window = Arc::new(event_loop.create_window(attrs).map_err(|e| e.to_string())?);
        #[cfg(target_os = "windows")]
        let desktop_position = monitor
            .as_ref()
            .map(|m| m.position())
            .unwrap_or(winit::dpi::PhysicalPosition::new(0, 0));
        #[cfg(target_os = "windows")]
        if let Some(host) = parent {
            windows_desktop::attach(&window, host, desktop_position, size)?;
        }
        let surface = self
            .instance
            .create_surface(window.clone())
            .map_err(|e| e.to_string())?;
        let adapter = if let Ok(name) = std::env::var("RAINGLASS_GPU") {
            self.instance
                .enumerate_adapters(wgpu::Backends::all())
                .into_iter()
                .find(|adapter| {
                    adapter.is_surface_supported(&surface)
                        && adapter
                            .get_info()
                            .name
                            .to_lowercase()
                            .contains(&name.to_lowercase())
                })
                .ok_or_else(|| format!("No compatible GPU matches {name}"))?
        } else {
            pollster::block_on(
                self.instance.request_adapter(&wgpu::RequestAdapterOptions {
                    power_preference: if cfg!(target_os = "windows")
                        && self
                            .settings
                            .frame_rate
                            .hz(monitor.as_ref().and_then(|m| m.refresh_rate_millihertz()))
                            > 60.0
                    {
                        wgpu::PowerPreference::HighPerformance
                    } else {
                        wgpu::PowerPreference::LowPower
                    },
                    compatible_surface: Some(&surface),
                    force_fallback_adapter: false,
                }),
            )
            .ok_or("No compatible GPU")?
        };
        eprintln!(
            "RainGlass display {index}: adapter {:?}, selection {:.1} ms",
            adapter.get_info(),
            started.elapsed().as_secs_f64() * 1000.0
        );
        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("RainGlass GPU"),
                required_features: if std::env::var_os("RAINGLASS_DIAGNOSTICS").is_some() {
                    diagnostics::timestamp_features(&adapter)
                } else {
                    wgpu::Features::empty()
                },
                required_limits: wgpu::Limits::default(),
                memory_hints: wgpu::MemoryHints::MemoryUsage,
            },
            None,
        ))
        .map_err(|e| e.to_string())?;
        let caps = surface.get_capabilities(&adapter);
        let format = caps
            .formats
            .iter()
            .copied()
            .find(|format| format.is_srgb())
            .ok_or("The display does not offer an sRGB surface")?;
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::Fifo,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);
        let load_started = Instant::now();
        let renderer = renderer::SceneRenderer::load(
            &device,
            &queue,
            format,
            path,
            [config.width, config.height],
            render_scale([config.width, config.height], self.settings.quality),
        )?;
        eprintln!(
            "RainGlass display {index}: image and pipelines {:.1} ms, native {}x{}",
            load_started.elapsed().as_secs_f64() * 1000.0,
            config.width,
            config.height
        );
        let sim_started = Instant::now();
        let mut simulation = Simulation::new(
            self.settings.seed.wrapping_add(index as u64),
            config.width as f32,
            config.height as f32,
        );
        simulation.set_parameters(self.settings.weather.effective(self.settings.rain));
        simulation.parameters = self
            .settings
            .weather
            .effective(self.settings.rain)
            .clamped();
        eprintln!(
            "RainGlass display {index}: simulation initialization {:.1} ms",
            sim_started.elapsed().as_secs_f64() * 1000.0
        );
        window.set_visible(true);
        #[cfg(target_os = "windows")]
        if let Some(host) = parent {
            windows_desktop::attach(&window, host, desktop_position, size)?;
        }
        Ok(Scene {
            #[cfg(target_os = "windows")]
            overlay: windows_desktop::DiagnosticsOverlay::new(&window),
            window,
            surface,
            device,
            queue,
            config,
            renderer,
            simulation,
            last_frame: Instant::now(),
            next_frame: Instant::now(),
            refresh_millihertz: monitor.as_ref().and_then(|m| m.refresh_rate_millihertz()),
            stats: diagnostics::FrameStats::new(),
            first_frame: true,
            fps_started: Instant::now(),
            fps_frames: 0,
            measured_fps: 0.0,
            adapter_target_high: self
                .settings
                .frame_rate
                .hz(monitor.as_ref().and_then(|m| m.refresh_rate_millihertz()))
                > 60.0,
            accumulator: 0.0,
            #[cfg(target_os = "windows")]
            parent,
            #[cfg(target_os = "windows")]
            desktop_position,
        })
    }
    fn frame_interval(&self, scene: &Scene) -> Duration {
        #[cfg(target_os = "linux")]
        {
            let _ = scene;
            Duration::from_secs_f64(1.0 / 30.0)
        }
        #[cfg(not(target_os = "linux"))]
        {
            Duration::from_secs_f64(
                1.0 / self
                    .settings
                    .frame_rate
                    .hz(scene.refresh_millihertz)
                    .max(1.0),
            )
        }
    }
}

impl ApplicationHandler for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if !self.scenes.is_empty() {
            return;
        }
        self.last_error = None;
        if !self.windowed {
            self.monitor_signature = event_loop
                .available_monitors()
                .map(|m| {
                    format!(
                        "{:?}:{:?}:{:?}:{}",
                        m.position(),
                        m.size(),
                        m.refresh_rate_millihertz(),
                        m.scale_factor()
                    )
                })
                .collect();
        }
        #[cfg(target_os = "windows")]
        if self.tray.is_none() {
            match windows_desktop::TrayControls::new() {
                Ok(tray) => self.tray = Some(tray),
                Err(e) => eprintln!("RainGlass tray: {e}"),
            }
        }
        let path = match &self.settings.wallpaper {
            Some(p) if Path::new(p).is_file() => p.clone(),
            _ => {
                #[cfg(target_os = "windows")]
                {
                    self.last_error = Some("Choose a wallpaper in the RainGlass popup.".into());
                    return;
                }
                #[cfg(not(target_os = "windows"))]
                {
                    let Some(path) = rfd::FileDialog::new()
                        .add_filter("Image", &["jpg", "jpeg", "png", "webp", "bmp", "tiff"])
                        .pick_file()
                    else {
                        eprintln!("Choose a wallpaper from the RainGlass menu");
                        return;
                    };
                    let p = path.to_string_lossy().into_owned();
                    self.settings.wallpaper = Some(p.clone());
                    if let Err(e) = self.store.save(&self.settings) {
                        eprintln!("RainGlass settings: {e}");
                    }
                    p
                }
            }
        };
        let monitors: Vec<_> = if self.windowed {
            vec![None]
        } else {
            event_loop.available_monitors().map(Some).collect()
        };
        for (index, monitor) in monitors.into_iter().enumerate() {
            match self.create_scene(event_loop, index, monitor, Path::new(&path)) {
                Ok(scene) => self.scenes.push(scene),
                Err(e) => {
                    eprintln!("RainGlass display {index}: {e}");
                    self.last_error = Some(format!("Display {index}: {e}"));
                }
            }
        }
        if self.scenes.is_empty() && self.last_error.is_none() {
            self.last_error = Some("No desktop displays found".into());
        }
        #[cfg(target_os = "windows")]
        if let Some(tray) = &self.tray {
            tray.set_status(self.last_error.as_deref().unwrap_or("RainGlass running"));
        }
        if self.audio.is_none() {
            self.audio = Some(audio::AudioWorker::start());
        }
    }
    fn window_event(&mut self, event_loop: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        let Some(scene) = self.scenes.iter_mut().find(|scene| scene.window.id() == id) else {
            return;
        };
        match event {
            WindowEvent::Resized(size) if size.width > 0 && size.height > 0 => {
                scene.config.width = size.width;
                scene.config.height = size.height;
                scene.surface.configure(&scene.device, &scene.config);
                scene.renderer.resize(
                    &scene.device,
                    [size.width, size.height],
                    render_scale([size.width, size.height], self.settings.quality),
                );
                scene
                    .simulation
                    .resize(size.width as f32, size.height as f32);
            }
            WindowEvent::RedrawRequested
                if scene.first_frame
                    || (!self.settings.paused
                        && self.settings.frame_rate.hz(scene.refresh_millihertz) > 0.0) =>
            {
                let now = Instant::now();
                let dt = if self.settings.paused
                    || self.settings.frame_rate.hz(scene.refresh_millihertz) == 0.0
                {
                    0.0
                } else {
                    (now - scene.last_frame).as_secs_f32().min(0.1)
                };
                scene.last_frame = now;
                scene.accumulator += dt;
                let simulation_started = Instant::now();
                let mut steps = 0;
                while scene.accumulator >= 1.0 / 60.0 && steps < 2 {
                    scene.simulation.step(1.0 / 60.0);
                    scene.accumulator -= 1.0 / 60.0;
                    steps += 1;
                }
                if scene.accumulator >= 1.0 / 60.0 {
                    scene.accumulator %= 1.0 / 60.0;
                }
                if let Some(audio) = &self.audio {
                    for arrival in scene.simulation.drain_arrivals() {
                        audio.tap(arrival);
                    }
                }
                scene.renderer.set_lightning(self.storm.flash(
                    self.started.elapsed().as_secs_f64(),
                    self.settings.rain.lightning_intensity,
                ));
                let simulation_ms = simulation_started.elapsed().as_secs_f64() * 1000.0;
                let present_started = Instant::now();
                match scene.surface.get_current_texture() {
                    Ok(frame) => {
                        let acquire_ms = present_started.elapsed().as_secs_f64() * 1000.0;
                        let view = frame.texture.create_view(&Default::default());
                        let result = scene.renderer.render(
                            &scene.device,
                            &scene.queue,
                            &view,
                            &scene.simulation,
                            &self.settings,
                            dt,
                        );
                        let timings = match result {
                            Ok(timings) => timings,
                            Err(error) => {
                                drop(view);
                                drop(frame);
                                eprintln!("RainGlass: {error}");
                                self.last_error = Some(error);
                                event_loop.exit();
                                return;
                            }
                        };
                        let present_started = Instant::now();
                        frame.present();
                        scene.fps_frames += 1;
                        if scene.fps_started.elapsed().as_secs_f64() >= 1.0 {
                            scene.measured_fps =
                                scene.fps_frames as f64 / scene.fps_started.elapsed().as_secs_f64();
                            scene.fps_frames = 0;
                            scene.fps_started = Instant::now();
                        }
                        if scene.first_frame {
                            scene.first_frame = false;
                            eprintln!(
                                "RainGlass first presentation after {:.1} ms",
                                self.started.elapsed().as_secs_f64() * 1000.0
                            );
                        }
                        scene.stats.record(
                            simulation_ms,
                            timings,
                            acquire_ms + present_started.elapsed().as_secs_f64() * 1000.0,
                            now.elapsed().as_secs_f64() * 1000.0,
                        );
                    }
                    Err(wgpu::SurfaceError::Lost | wgpu::SurfaceError::Outdated) => {
                        scene.surface.configure(&scene.device, &scene.config)
                    }
                    Err(e) => eprintln!("RainGlass surface: {e}"),
                }
            }
            WindowEvent::CloseRequested if self.windowed => std::process::exit(0),
            _ => {}
        }
    }
    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        let now = Instant::now();
        if let Some(seconds) = self.profile_seconds {
            if self.started.elapsed().as_secs_f64() >= seconds {
                event_loop.exit();
                return;
            }
        }
        #[cfg(target_os = "windows")]
        self.controls_tick(event_loop, now);
        if now >= self.next_reload {
            let old_wallpaper = self.settings.wallpaper.clone();
            self.reload();
            if self.recreate_scenes {
                self.recreate_scenes = false;
                self.scenes.clear();
                self.resumed(event_loop);
            }
            self.next_reload = now + Duration::from_millis(500);
            if old_wallpaper != self.settings.wallpaper
                && self.scenes.is_empty()
                && self.settings.wallpaper.is_some()
            {
                self.resumed(event_loop);
            }
            if !self.windowed {
                let signature: Vec<String> = event_loop
                    .available_monitors()
                    .map(|m| {
                        format!(
                            "{:?}:{:?}:{:?}:{}",
                            m.position(),
                            m.size(),
                            m.refresh_rate_millihertz(),
                            m.scale_factor()
                        )
                    })
                    .collect();
                if signature != self.monitor_signature {
                    self.monitor_signature = signature;
                    self.scenes.clear();
                    self.resumed(event_loop);
                }
            }
            #[cfg(target_os = "windows")]
            {
                if !self.windowed && now >= self.next_desktop_retry {
                    self.next_desktop_retry = now + Duration::from_secs(2);
                    if self.scenes.is_empty()
                        || self.scenes.iter().any(|scene| {
                            !scene
                                .parent
                                .map(|host| windows_desktop::attached(&scene.window, host))
                                .unwrap_or(false)
                        })
                    {
                        // Explorer can destroy child HWNDs; a new surface must own a new HWND.
                        self.scenes.clear();
                        self.resumed(event_loop);
                    }
                }
            }
        }
        let stopped = self.settings.frame_rate.hz(None) == 0.0;
        let elapsed = self.started.elapsed().as_secs_f64();
        if let Some(audio) = &self.audio {
            audio.tick(&self.settings.audio, elapsed as f32, stopped);
        }
        for strike in self.storm.tick(
            elapsed,
            self.settings.weather.effective(self.settings.rain),
            !stopped && !self.settings.paused,
        ) {
            if let Some(audio) = &self.audio {
                audio.thunder(strike);
            }
        }
        let mut wake_at = self.next_reload;
        let mut visible_scene = false;
        for scene in &self.scenes {
            if scene.first_frame {
                scene.window.request_redraw();
            }
        }
        if !self.settings.paused && !stopped {
            for index in 0..self.scenes.len() {
                let interval = self.frame_interval(&self.scenes[index]);
                let scene = &mut self.scenes[index];
                #[cfg(target_os = "windows")]
                if !self.windowed
                    && self.profile_seconds.is_none()
                    && windows_desktop::covered(
                        scene.desktop_position,
                        PhysicalSize::new(scene.config.width, scene.config.height),
                    )
                {
                    scene.last_frame = now;
                    scene.accumulator = 0.0;
                    scene.next_frame = now;
                    continue;
                }
                visible_scene = true;
                if now >= scene.next_frame {
                    scene.window.request_redraw();
                    scene.next_frame += interval;
                    if scene.next_frame <= now {
                        scene.next_frame = now + interval;
                    }
                }
                wake_at = wake_at.min(scene.next_frame);
            }
        }
        if !visible_scene {
            wake_at = wake_at.min(now + Duration::from_millis(250));
        }
        #[cfg(target_os = "windows")]
        {
            wake_at = wake_at.min(now + Duration::from_millis(20));
        }
        event_loop.set_control_flow(ControlFlow::WaitUntil(wake_at));
    }
}

fn render_scale(size: [u32; 2], quality: Quality) -> f32 {
    #[cfg(target_os = "linux")]
    {
        let pixels = u64::from(size[0]) * u64::from(size[1]);
        if pixels > 3840 * 2160 {
            0.5
        } else if pixels > 2560 * 1440 {
            0.65
        } else {
            0.85
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = size;
        match quality {
            Quality::Eco => 0.6,
            Quality::Balanced => 0.85,
            Quality::Ultra => 1.0,
        }
    }
}

fn main() {
    let store = match settings_store::SettingsStore::new() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("RainGlass: {e}");
            return;
        }
    };
    let args: Vec<String> = std::env::args().skip(1).collect();
    #[cfg(not(target_os = "windows"))]
    if args.iter().any(|arg| arg == "--settings") {
        if let Err(e) = settings_ui::show(store) {
            eprintln!("RainGlass settings: {e}");
        }
        return;
    }
    let windowed = args.iter().any(|arg| arg == "--windowed");
    #[cfg(target_os = "windows")]
    let open_popup = args.iter().any(|arg| arg == "--settings");
    let commands: Vec<String> = args
        .into_iter()
        .filter(|arg| arg != "--windowed" && !(cfg!(target_os = "windows") && arg == "--settings"))
        .collect();
    if !commands.is_empty() {
        match store.apply_command(&commands) {
            Ok(true) => return,
            Ok(false) => {}
            Err(e) => {
                eprintln!("RainGlass: {e}");
                return;
            }
        }
    }
    #[cfg(target_os = "windows")]
    let single_instance = if windowed {
        None
    } else {
        match controls::SingleInstance::acquire(&store.path) {
            Ok(Some(instance)) => Some(instance),
            Ok(None) => return,
            Err(e) => {
                eprintln!("RainGlass: {e}");
                return;
            }
        }
    };
    let now = Instant::now();
    let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor::from_env_or_default());
    eprintln!(
        "RainGlass GPU instance initialized in {:.1} ms",
        now.elapsed().as_secs_f64() * 1000.0
    );
    let mut app = App {
        settings: store.load(),
        store,
        modified: None,
        instance,
        scenes: Vec::new(),
        audio: None,
        started: now,
        next_reload: now,
        next_desktop_retry: now + Duration::from_secs(2),
        windowed,
        profile_seconds: std::env::var("RAINGLASS_PROFILE_SECONDS")
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .filter(|v| v.is_finite() && *v > 0.0),
        monitor_signature: Vec::new(),
        last_error: None,
        recreate_scenes: false,
        storm: storm::Storm::new(0x5448554e444552),
        #[cfg(target_os = "windows")]
        controls: controls::Controls::new(),
        #[cfg(target_os = "windows")]
        weather: controls::WeatherWorker::new(),
        #[cfg(target_os = "windows")]
        next_weather: now,
        #[cfg(target_os = "windows")]
        next_snapshot: now,
        #[cfg(target_os = "windows")]
        save_at: None,
        #[cfg(target_os = "windows")]
        control_error: None,
        #[cfg(target_os = "windows")]
        weather_error: None,
        #[cfg(target_os = "windows")]
        weather_search: serde_json::json!([]),
        #[cfg(target_os = "windows")]
        pending_toggle: None,
        #[cfg(target_os = "windows")]
        selected_preset: "Custom".into(),
        #[cfg(target_os = "windows")]
        single_instance,
        #[cfg(target_os = "windows")]
        open_popup,
        #[cfg(target_os = "windows")]
        tray: None,
    };
    #[cfg(target_os = "windows")]
    {
        app.settings.start_at_login = controls::startup_enabled();
        app.open_popup |= app.settings.wallpaper.is_none();
    }
    EventLoop::new()
        .expect("Cannot start window event loop")
        .run_app(&mut app)
        .expect("RainGlass window event loop failed");
}
