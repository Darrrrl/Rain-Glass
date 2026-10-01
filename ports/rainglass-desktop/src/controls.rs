//! The WPF companion serves a CurrentUserOnly pipe; the engine owns all state.
use serde_json::{json, Value};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::{
    fs::OpenOptions,
    io::{Read, Write},
    process::{Child, Command},
    sync::{mpsc, Arc, Mutex},
    time::{Duration, Instant},
};

pub struct Controls {
    pub commands: mpsc::Receiver<Value>,
    outgoing: Arc<Mutex<Option<Value>>>,
    child: Option<Child>,
    pipe: String,
    next_launch: Instant,
    pub error: Option<String>,
}

pub struct SingleInstance {
    mutex: windows_sys::Win32::Foundation::HANDLE,
    event: windows_sys::Win32::Foundation::HANDLE,
}
impl SingleInstance {
    pub fn acquire(path: &std::path::Path) -> Result<Option<Self>, String> {
        use std::hash::{Hash, Hasher};
        use windows_sys::Win32::{
            Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS},
            System::Threading::{CreateEventW, CreateMutexW, SetEvent},
        };
        let mut hash = std::collections::hash_map::DefaultHasher::new();
        path.hash(&mut hash);
        let name = format!("Local\\RainGlass-{:x}", hash.finish());
        let mutex_name: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        let event_name: Vec<u16> = format!("{name}-open")
            .encode_utf16()
            .chain(Some(0))
            .collect();
        unsafe {
            let mutex = CreateMutexW(std::ptr::null(), 0, mutex_name.as_ptr());
            if mutex.is_null() {
                return Err(std::io::Error::last_os_error().to_string());
            }
            let exists = GetLastError() == ERROR_ALREADY_EXISTS;
            let event = CreateEventW(std::ptr::null(), 0, 0, event_name.as_ptr());
            if event.is_null() {
                CloseHandle(mutex);
                return Err(std::io::Error::last_os_error().to_string());
            }
            if exists {
                SetEvent(event);
                CloseHandle(event);
                CloseHandle(mutex);
                return Ok(None);
            }
            Ok(Some(Self { mutex, event }))
        }
    }
    pub fn take_open_request(&self) -> bool {
        unsafe { windows_sys::Win32::System::Threading::WaitForSingleObject(self.event, 0) == 0 }
    }
}
impl Drop for SingleInstance {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.event);
            windows_sys::Win32::Foundation::CloseHandle(self.mutex);
        }
    }
}
impl Controls {
    pub fn new() -> Self {
        let pipe = format!("RainGlass-{}", std::process::id());
        let path = format!(r"\\.\pipe\{pipe}");
        let outgoing = Arc::new(Mutex::new(None::<Value>));
        let shared = outgoing.clone();
        let (tx, commands) = mpsc::channel();
        std::thread::spawn(move || loop {
            let Ok(mut writer) = OpenOptions::new().read(true).write(true).open(&path) else {
                std::thread::sleep(Duration::from_millis(200));
                continue;
            };
            eprintln!("RainGlass controls connected: {path}");
            let mut incoming = Vec::new();
            loop {
                let message = shared.lock().unwrap().take();
                if let Some(message) = message {
                    let line = format!("{message}\n");
                    if writer.write_all(line.as_bytes()).is_err() {
                        break;
                    }
                }
                // A synchronous Windows pipe handle serializes reads and writes even
                // after DuplicateHandle. Peek and read on this one worker to avoid
                // a blocking reader preventing snapshots from reaching WPF.
                let mut available = 0u32;
                let alive = unsafe {
                    windows_sys::Win32::System::Pipes::PeekNamedPipe(
                        writer.as_raw_handle(),
                        std::ptr::null_mut(),
                        0,
                        std::ptr::null_mut(),
                        &mut available,
                        std::ptr::null_mut(),
                    )
                };
                if alive == 0 {
                    break;
                }
                if available > 0 {
                    let mut buffer = [0u8; 4096];
                    let size = (available as usize).min(buffer.len());
                    match writer.read(&mut buffer[..size]) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => incoming.extend_from_slice(&buffer[..n]),
                    }
                    let Ok(frames) = decode_frames(&mut incoming) else {
                        break;
                    };
                    for value in frames {
                        let _ = tx.send(value);
                    }
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        Self {
            commands,
            outgoing,
            child: None,
            pipe,
            next_launch: Instant::now(),
            error: None,
        }
    }
    pub fn ensure_running(&mut self) {
        if self
            .child
            .as_mut()
            .is_some_and(|child| matches!(child.try_wait(), Ok(None)))
        {
            return;
        }
        if Instant::now() < self.next_launch {
            return;
        }
        self.next_launch = Instant::now() + Duration::from_secs(5);
        let path = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .join("ui/RainGlass.Controls.exe");
        match Command::new(&path)
            .args([
                "--pipe",
                &self.pipe,
                "--engine",
                &std::process::id().to_string(),
            ])
            .creation_flags(0x08000000)
            .spawn()
        {
            Ok(child) => {
                self.child = Some(child);
                self.error = None;
            }
            Err(e) => self.error = Some(format!("Cannot open controls at {}: {e}", path.display())),
        }
    }
    pub fn send(&self, mut value: Value) {
        if !value["toggle"].is_null() {
            if let Some(child) = &self.child {
                unsafe {
                    windows_sys::Win32::UI::WindowsAndMessaging::AllowSetForegroundWindow(
                        child.id(),
                    );
                }
            }
        }
        let mut outgoing = self.outgoing.lock().unwrap();
        if value["toggle"].is_null() {
            if let Some(old) = outgoing.as_ref() {
                value["toggle"] = old["toggle"].clone();
            }
        }
        *outgoing = Some(value);
    }
}

fn decode_frames(incoming: &mut Vec<u8>) -> Result<Vec<Value>, String> {
    if incoming.len() > 1_048_576 {
        return Err("Oversized controls message".into());
    }
    let mut frames = Vec::new();
    while let Some(end) = incoming.iter().position(|b| *b == b'\n') {
        let frame: Vec<_> = incoming.drain(..=end).collect();
        if let Ok(value) = serde_json::from_slice::<Value>(&frame) {
            if value["version"] == 1 {
                frames.push(value);
            }
        }
    }
    Ok(frames)
}

pub fn edit(
    settings: &rainglass_core::settings::AppSettings,
    command: &Value,
) -> Result<Option<rainglass_core::settings::AppSettings>, String> {
    use rainglass_core::settings::{PresetFile, ScenePreset};
    let mut next = settings.clone();
    let data = &command["data"];
    match command["command"].as_str().unwrap_or("") {
        "patch" => {
            let mut json = serde_json::to_value(&next).unwrap();
            for (path, value) in data.as_object().ok_or("Invalid settings patch")? {
                let parts: Vec<_> = path.split('.').collect();
                let allowed = match parts.as_slice() {
                    ["rain", field] => [
                        "intensity",
                        "dropletSize",
                        "dropCount",
                        "gravity",
                        "wind",
                        "blur",
                        "refraction",
                        "trailPersistence",
                        "lightningEnabled",
                        "thunderProbability",
                        "lightningIntensity",
                    ]
                    .contains(field),
                    ["audio", field] => [
                        "master",
                        "muted",
                        "window",
                        "distant",
                        "wind",
                        "room",
                        "thunder",
                        "glassTaps",
                    ]
                    .contains(field),
                    ["atmosphere", field] => [
                        "condensation",
                        "haze",
                        "imperfections",
                        "fogSoftness",
                        "fogReturnTime",
                    ]
                    .contains(field),
                    ["frame", field] => ["layout", "thickness"].contains(field),
                    ["weather", field] => ["enabled", "city"].contains(field),
                    [field] => [
                        "fit",
                        "zoom",
                        "quality",
                        "frame_rate",
                        "seed",
                        "paused",
                        "theme",
                        "start_at_login",
                        "diagnostics_overlay",
                    ]
                    .contains(field),
                    _ => false,
                };
                if !allowed {
                    return Err(format!("Unknown setting {path}"));
                }
                let mut target = &mut json;
                for part in &parts[..parts.len() - 1] {
                    target = &mut target[*part];
                }
                target[parts[parts.len() - 1]] = value.clone();
            }
            next = serde_json::from_value(json).map_err(|e| e.to_string())?;
            if next.weather.city != settings.weather.city {
                next.weather.cached = None;
            }
        }
        "preset" => {
            let name = data.as_str().ok_or("Missing preset name")?;
            if let Some(p) = next.saved_presets.iter().find(|p| p.name == name).cloned() {
                next.rain = p.rain;
                next.atmosphere = p.atmosphere;
                next.audio = p.audio;
                next.audio.muted = settings.audio.muted;
                next.frame = p.frame;
            } else {
                crate::settings_store::apply_builtin(&mut next, name)?;
            }
        }
        "save_preset" => {
            let name = data.as_str().unwrap_or("").trim();
            if name.is_empty() || name.chars().count() > 40 {
                return Err("Preset name must contain 1–40 characters".into());
            }
            if next
                .saved_presets
                .iter()
                .any(|p| p.name.eq_ignore_ascii_case(name))
            {
                return Err("A preset with that name already exists".into());
            }
            next.saved_presets.push(ScenePreset {
                id: uuid::Uuid::new_v4().to_string(),
                name: name.into(),
                rain: next.rain,
                atmosphere: next.atmosphere,
                audio: next.audio,
                frame: next.frame,
            });
        }
        "delete_preset" => {
            next.saved_presets
                .retain(|p| Some(p.name.as_str()) != data.as_str());
        }
        "import_preset" => {
            let contents = std::fs::read_to_string(data.as_str().ok_or("Missing preset path")?)
                .map_err(|e| e.to_string())?;
            let file = PresetFile::parse(&contents)?;
            if next
                .saved_presets
                .iter()
                .any(|p| p.name.eq_ignore_ascii_case(&file.preset.name))
            {
                return Err("A preset with that name already exists".into());
            }
            next.saved_presets.push(file.preset);
        }
        "export_preset" => {
            let p = next
                .saved_presets
                .iter()
                .find(|p| Some(p.name.as_str()) == data["name"].as_str())
                .ok_or("Select a saved preset to export")?;
            let file = PresetFile {
                version: 1,
                preset: p.clone(),
            };
            std::fs::write(
                data["path"].as_str().ok_or("Missing export path")?,
                serde_json::to_vec_pretty(&file).unwrap(),
            )
            .map_err(|e| e.to_string())?;
            return Ok(None);
        }
        "wallpaper" => {
            let path = data.as_str().ok_or("Missing image path")?;
            image::image_dimensions(path).map_err(|e| format!("Cannot decode image: {e}"))?;
            next.wallpaper = Some(path.into());
        }
        _ => return Ok(None),
    }
    if !["system", "light", "dark"].contains(&next.theme.as_str())
        || !(1.0..=3.0).contains(&next.zoom)
    {
        return Err("Invalid theme or zoom".into());
    }
    if let Some(city) = &next.weather.city {
        if !city.latitude.is_finite()
            || !city.longitude.is_finite()
            || !(-90.0..=90.0).contains(&city.latitude)
            || !(-180.0..=180.0).contains(&city.longitude)
        {
            return Err("Invalid weather location".into());
        }
    }
    let validation = PresetFile {
        version: 1,
        preset: ScenePreset {
            id: "validation".into(),
            name: "Validation".into(),
            rain: next.rain,
            atmosphere: next.atmosphere,
            audio: next.audio,
            frame: next.frame,
        },
    };
    PresetFile::parse(&serde_json::to_string(&validation).unwrap())?;
    if next.start_at_login != settings.start_at_login {
        set_startup(next.start_at_login)?;
    }
    Ok(Some(next))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn patches_are_atomic_and_validate_ranges() {
        let settings = rainglass_core::settings::AppSettings::default();
        let next = edit(&settings, &json!({"command":"patch", "data":{"rain.blur":64, "audio.master":0.8, "frame_rate":{"fixed":0}}})).unwrap().unwrap();
        assert_eq!(next.rain.blur, 64.0);
        assert_eq!(next.frame_rate.hz(None), 0.0);
        assert!(edit(
            &settings,
            &json!({"command":"patch", "data":{"audio.master":2, "rain.blur":12}})
        )
        .is_err());
        assert!(edit(
            &settings,
            &json!({"command":"patch", "data":{"weather.cached":{}}})
        )
        .is_err());
        assert_eq!(settings.audio.master, 0.35);
    }
    #[test]
    fn framing_preserves_batched_messages_and_rejects_oversize() {
        let mut incoming =
            b"{\"version\":1,\"a\":1}\n{\"version\":1,\"a\":2}\n{\"version\":1".to_vec();
        let frames = decode_frames(&mut incoming).unwrap();
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0]["a"], 1);
        assert_eq!(frames[1]["a"], 2);
        incoming.extend_from_slice(b",\"a\":3}\n");
        assert_eq!(decode_frames(&mut incoming).unwrap()[0]["a"], 3);
        assert!(decode_frames(&mut vec![b'a'; 1_048_577]).is_err());
    }
}
impl Drop for Controls {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            let _ = child.kill();
        }
    }
}

pub fn set_startup(enabled: bool) -> Result<(), String> {
    use winreg::{enums::HKEY_CURRENT_USER, RegKey};
    let (key, _) = RegKey::predef(HKEY_CURRENT_USER)
        .create_subkey(r"Software\Microsoft\Windows\CurrentVersion\Run")
        .map_err(|e| e.to_string())?;
    if enabled {
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        key.set_value("RainGlass", &format!("\"{}\"", exe.display()))
            .map_err(|e| e.to_string())
    } else {
        match key.delete_value("RainGlass") {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}
pub fn startup_enabled() -> bool {
    use winreg::{enums::HKEY_CURRENT_USER, RegKey};
    RegKey::predef(HKEY_CURRENT_USER)
        .open_subkey(r"Software\Microsoft\Windows\CurrentVersion\Run")
        .and_then(|k| k.get_value::<String, _>("RainGlass"))
        .is_ok()
}

pub enum WeatherResult {
    Search(String, Result<Value, String>),
    Current(
        rainglass_core::settings::WeatherCity,
        Result<rainglass_core::settings::WeatherConditions, String>,
    ),
}
pub struct WeatherWorker {
    sender: mpsc::Sender<(String, Value)>,
    pub results: mpsc::Receiver<WeatherResult>,
}
impl WeatherWorker {
    pub fn new() -> Self {
        let (sender, jobs) = mpsc::channel::<(String, Value)>();
        let (tx, results) = mpsc::channel();
        std::thread::spawn(move || {
            let client = reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(12))
                .build();
            while let Ok((kind, value)) = jobs.recv() {
                let request = |url: &str, query: &[(&str, String)]| -> Result<Value, String> {
                    client
                        .as_ref()
                        .map_err(|e| e.to_string())?
                        .get(url)
                        .query(query)
                        .send()
                        .map_err(|e| e.to_string())?
                        .error_for_status()
                        .map_err(|e| e.to_string())?
                        .json()
                        .map_err(|e| e.to_string())
                };
                if kind == "search" {
                    let query = value.as_str().unwrap_or("").to_owned();
                    let result = request(
                        "https://geocoding-api.open-meteo.com/v1/search",
                        &[("name", query.clone()), ("count", "8".into())],
                    )
                    .map(|v| v.get("results").cloned().unwrap_or(json!([])));
                    let _ = tx.send(WeatherResult::Search(query, result));
                } else if let Ok(city) =
                    serde_json::from_value::<rainglass_core::settings::WeatherCity>(value)
                {
                    let result = request("https://api.open-meteo.com/v1/forecast", &[("latitude", city.latitude.to_string()), ("longitude", city.longitude.to_string()),
                        ("current", "rain,showers,wind_speed_10m,wind_direction_10m,cloud_cover,weather_code".into())]).and_then(|v| {
                        let c = &v["current"];
                        let n = |key| c[key].as_f64().filter(|n| n.is_finite()).ok_or_else(|| format!("Weather response missing {key}"));
                        Ok(rainglass_core::settings::WeatherConditions { precipitation: (n("rain")?+n("showers")?)*4.0,
                            wind_speed: n("wind_speed_10m")?, wind_direction: n("wind_direction_10m")?, cloud_cover: n("cloud_cover")?,
                            weather_code: c["weather_code"].as_u64().ok_or("Missing weather code")? as u32,
                            fetched_at: std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs() })
                    });
                    let _ = tx.send(WeatherResult::Current(city, result));
                }
            }
        });
        Self { sender, results }
    }
    pub fn search(&self, query: &str) {
        let _ = self.sender.send(("search".into(), json!(query)));
    }
    pub fn refresh(&self, city: &rainglass_core::settings::WeatherCity) {
        let _ = self
            .sender
            .send(("current".into(), serde_json::to_value(city).unwrap()));
    }
}
