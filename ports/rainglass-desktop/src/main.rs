mod audio;
mod mask;
mod renderer;
mod settings_store;
mod settings_ui;
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
    accumulator: f32,
    #[cfg(target_os = "windows")]
    parent: isize,
    #[cfg(target_os = "windows")]
    desktop_position: winit::dpi::PhysicalPosition<i32>,
}

struct App {
    store: settings_store::SettingsStore,
    settings: AppSettings,
    modified: Option<SystemTime>,
    instance: wgpu::Instance,
    scenes: Vec<Scene>,
    audio: Option<audio::AmbientAudio>,
    started: Instant,
    next_reload: Instant,
    windowed: bool,
    monitor_signature: Vec<String>,
    last_error: Option<String>,
    #[cfg(target_os = "windows")]
    tray: Option<windows_desktop::TrayControls>,
}

impl App {
    fn reload(&mut self) {
        let modified = std::fs::metadata(&self.store.path)
            .and_then(|m| m.modified())
            .ok();
        if modified == self.modified {
            return;
        }
        self.modified = modified;
        let next = self.store.load();
        let image_changed = next.wallpaper != self.settings.wallpaper;
        let quality_changed = next.quality != self.settings.quality;
        for scene in &mut self.scenes {
            scene.simulation.set_parameters(next.rain);
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
        self.settings = next;
    }
    fn create_scene(
        &self,
        event_loop: &ActiveEventLoop,
        index: usize,
        monitor: Option<winit::monitor::MonitorHandle>,
        path: &Path,
    ) -> Result<Scene, String> {
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
        if let Some(ref monitor) = monitor {
            attrs = attrs.with_position(monitor.position());
        }
        let window = Arc::new(event_loop.create_window(attrs).map_err(|e| e.to_string())?);
        let surface = self
            .instance
            .create_surface(window.clone())
            .map_err(|e| e.to_string())?;
        let adapter =
            pollster::block_on(self.instance.request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::LowPower,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            }))
            .ok_or("No compatible GPU")?;
        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("RainGlass GPU"),
                required_features: wgpu::Features::empty(),
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
        let renderer = renderer::SceneRenderer::load(
            &device,
            &queue,
            format,
            path,
            [config.width, config.height],
            render_scale([config.width, config.height], self.settings.quality),
        )?;
        let mut simulation = Simulation::new(
            self.settings.seed.wrapping_add(index as u64),
            config.width as f32,
            config.height as f32,
        );
        simulation.set_parameters(self.settings.rain);
        #[cfg(target_os = "windows")]
        let desktop_position = monitor
            .as_ref()
            .map(|m| m.position())
            .unwrap_or(winit::dpi::PhysicalPosition::new(0, 0));
        #[cfg(target_os = "windows")]
        let parent = if self.windowed {
            0
        } else {
            windows_desktop::attach(&window, desktop_position, size)?
        };
        window.set_visible(true);
        Ok(Scene {
            window,
            surface,
            device,
            queue,
            config,
            renderer,
            simulation,
            last_frame: Instant::now(),
            accumulator: 0.0,
            #[cfg(target_os = "windows")]
            parent,
            #[cfg(target_os = "windows")]
            desktop_position,
        })
    }
    fn fps(&self) -> u32 {
        #[cfg(target_os = "linux")]
        {
            30
        }
        #[cfg(not(target_os = "linux"))]
        {
            match self.settings.quality {
                Quality::Eco => 30,
                Quality::Balanced => 60,
                Quality::Ultra => 120,
            }
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
                .map(|m| format!("{:?}:{:?}", m.position(), m.size()))
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
            match audio::AmbientAudio::start() {
                Ok(audio) => self.audio = Some(audio),
                Err(e) => eprintln!("RainGlass audio: {e}"),
            }
        }
    }
    fn window_event(&mut self, _event_loop: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
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
            WindowEvent::RedrawRequested if !self.settings.paused => {
                let now = Instant::now();
                let dt = (now - scene.last_frame).as_secs_f32().min(0.1);
                scene.last_frame = now;
                scene.accumulator += dt;
                let mut steps = 0;
                while scene.accumulator >= 1.0 / 60.0 && steps < 6 {
                    scene.simulation.step(1.0 / 60.0);
                    scene.accumulator -= 1.0 / 60.0;
                    steps += 1;
                }
                if steps == 6 {
                    scene.accumulator = 0.0;
                }
                match scene.surface.get_current_texture() {
                    Ok(frame) => {
                        let view = frame.texture.create_view(&Default::default());
                        scene.renderer.render(
                            &scene.device,
                            &scene.queue,
                            &view,
                            &scene.simulation,
                            &self.settings,
                            dt,
                        );
                        frame.present();
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
        if now >= self.next_reload {
            let old_wallpaper = self.settings.wallpaper.clone();
            self.reload();
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
                    .map(|m| format!("{:?}:{:?}", m.position(), m.size()))
                    .collect();
                if signature != self.monitor_signature {
                    self.monitor_signature = signature;
                    self.scenes.clear();
                    self.resumed(event_loop);
                }
            }
            #[cfg(target_os = "windows")]
            {
                let commands = self
                    .tray
                    .as_ref()
                    .map(|tray| tray.poll())
                    .unwrap_or_default();
                for command in commands {
                    if command.first().map(String::as_str) == Some("--quit") {
                        event_loop.exit();
                        continue;
                    }
                    if matches!(
                        command.first().map(String::as_str),
                        Some("--settings" | "--choose-wallpaper")
                    ) {
                        if let Ok(exe) = std::env::current_exe() {
                            if let Err(e) = std::process::Command::new(exe).args(&command).spawn() {
                                eprintln!("RainGlass control: {e}");
                            }
                        }
                        continue;
                    }
                    if command.first().map(String::as_str) == Some("--retry") {
                        self.scenes.clear();
                        self.resumed(event_loop);
                        continue;
                    }
                    if let Err(e) = self.store.apply_command(&command) {
                        eprintln!("RainGlass control: {e}");
                    }
                    self.reload();
                    if self.scenes.is_empty() && self.settings.wallpaper.is_some() {
                        self.resumed(event_loop);
                    }
                }
                for scene in &mut self.scenes {
                    if !self.windowed && !windows_desktop::parent_alive(scene.parent) {
                        match windows_desktop::reattach(
                            &scene.window,
                            scene.desktop_position,
                            PhysicalSize::new(scene.config.width, scene.config.height),
                        ) {
                            Ok(parent) => scene.parent = parent,
                            Err(e) => {
                                let message = format!("Desktop placement failed: {e}");
                                eprintln!("RainGlass {message}");
                                self.last_error = Some(message.clone());
                                if let Some(tray) = &self.tray {
                                    tray.set_status(&message);
                                }
                            }
                        }
                    }
                }
            }
        }
        if let Some(audio) = &self.audio {
            audio.tick(&self.settings.audio, self.started.elapsed().as_secs_f32());
        }
        let interval = Duration::from_secs_f32(1.0 / self.fps() as f32);
        let mut visible_scene = false;
        if !self.settings.paused {
            for scene in &self.scenes {
                #[cfg(target_os = "windows")]
                if !self.windowed
                    && windows_desktop::covered(
                        scene.desktop_position,
                        PhysicalSize::new(scene.config.width, scene.config.height),
                    )
                {
                    continue;
                }
                visible_scene = true;
                if now.duration_since(scene.last_frame) >= interval {
                    scene.window.request_redraw();
                }
            }
        }
        event_loop.set_control_flow(ControlFlow::WaitUntil(
            now + if visible_scene {
                interval
            } else {
                Duration::from_millis(250)
            },
        ));
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
    if args.iter().any(|arg| arg == "--settings") {
        if let Err(e) = settings_ui::show(store) {
            eprintln!("RainGlass settings: {e}");
        }
        return;
    }
    let windowed = args.iter().any(|arg| arg == "--windowed");
    let commands: Vec<String> = args.into_iter().filter(|arg| arg != "--windowed").collect();
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
    let now = Instant::now();
    let mut app = App {
        settings: store.load(),
        store,
        modified: None,
        instance: wgpu::Instance::default(),
        scenes: Vec::new(),
        audio: None,
        started: now,
        next_reload: now,
        windowed,
        monitor_signature: Vec::new(),
        last_error: None,
        #[cfg(target_os = "windows")]
        tray: None,
    };
    EventLoop::new()
        .expect("Cannot start window event loop")
        .run_app(&mut app)
        .expect("RainGlass window event loop failed");
}
