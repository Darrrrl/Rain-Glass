use rainglass_core::settings::{AppSettings, FitMode, PresetFile, Quality, RainParameters};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub struct SettingsStore {
    pub path: PathBuf,
}
impl SettingsStore {
    pub fn new() -> Result<Self, String> {
        let mut path = std::env::var_os("RAINGLASS_CONFIG_DIR")
            .map(PathBuf::from)
            .or_else(dirs::config_dir)
            .ok_or("Cannot find the user settings directory")?;
        if std::env::var_os("RAINGLASS_CONFIG_DIR").is_none() {
            path.push("RainGlass");
        }
        fs::create_dir_all(&path).map_err(|e| e.to_string())?;
        path.push("settings.json");
        Ok(Self { path })
    }
    pub fn load(&self) -> AppSettings {
        fs::read_to_string(&self.path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }
    pub fn save(&self, settings: &AppSettings) -> Result<(), String> {
        let json = serde_json::to_vec_pretty(settings).map_err(|e| e.to_string())?;
        let tmp = self.path.with_extension("json.tmp");
        fs::write(&tmp, json).map_err(|e| e.to_string())?;
        fs::rename(&tmp, &self.path).map_err(|e| e.to_string())
    }
    pub fn apply_command(&self, args: &[String]) -> Result<bool, String> {
        if args.is_empty() {
            return Ok(false);
        }
        let mut settings = self.load();
        match args[0].as_str() {
            "--wallpaper" => {
                let path = args.get(1).ok_or("Provide a wallpaper path")?;
                if !Path::new(path).is_file() {
                    return Err("Wallpaper file does not exist".into());
                }
                image::image_dimensions(path)
                    .map_err(|e| format!("Cannot decode wallpaper: {e}"))?;
                settings.wallpaper = Some(path.clone());
            }
            "--choose-wallpaper" => {
                let Some(path) = rfd::FileDialog::new()
                    .add_filter(
                        "Image",
                        &["jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff"],
                    )
                    .pick_file()
                else {
                    return Ok(true);
                };
                image::image_dimensions(&path)
                    .map_err(|e| format!("Cannot decode wallpaper: {e}"))?;
                settings.wallpaper = Some(path.to_string_lossy().into_owned());
            }
            "--toggle-pause" => settings.paused = !settings.paused,
            "--toggle-mute" => settings.audio.muted = !settings.audio.muted,
            "--blur" => settings.rain.blur = parse_range(args.get(1), 0.0, 64.0)?,
            "--zoom" => settings.zoom = parse_range(args.get(1), 1.0, 3.0)? as f32,
            "--volume" => settings.audio.master = parse_range(args.get(1), 0.0, 1.0)?,
            "--fit" => {
                settings.fit = match args.get(1).map(String::as_str) {
                    Some("fill") => FitMode::Fill,
                    Some("fit") => FitMode::Fit,
                    Some("stretch") => FitMode::Stretch,
                    _ => return Err("Fit mode must be fill, fit, or stretch".into()),
                }
            }
            "--quality" => {
                settings.quality = match args.get(1).map(String::as_str) {
                    Some("eco") => Quality::Eco,
                    Some("balanced") => Quality::Balanced,
                    Some("ultra") => Quality::Ultra,
                    _ => return Err("Quality must be eco, balanced, or ultra".into()),
                }
            }
            "--preset" => {
                let name = args.get(1).ok_or("Provide a preset name")?;
                if let Some(preset) = settings
                    .saved_presets
                    .iter()
                    .find(|p| p.name.eq_ignore_ascii_case(name))
                {
                    let p = preset.clone();
                    settings.rain = p.rain;
                    settings.atmosphere = p.atmosphere;
                    settings.audio = p.audio;
                    settings.frame = p.frame;
                } else {
                    apply_builtin(&mut settings, name)?;
                }
            }
            "--import-preset" => {
                let path = args.get(1).ok_or("Provide a preset JSON path")?;
                let data = fs::read_to_string(path).map_err(|e| e.to_string())?;
                let file = PresetFile::parse(&data)?;
                if settings
                    .saved_presets
                    .iter()
                    .any(|p| p.name.eq_ignore_ascii_case(&file.preset.name))
                {
                    return Err("A preset with that name already exists".into());
                }
                settings.saved_presets.push(file.preset);
            }
            "--export-preset" => {
                let name = args.get(1).ok_or("Provide a preset name")?;
                let path = args.get(2).ok_or("Provide an output JSON path")?;
                let preset = settings
                    .saved_presets
                    .iter()
                    .find(|p| p.name.eq_ignore_ascii_case(name))
                    .ok_or("Preset was not found")?;
                let json = serde_json::to_vec_pretty(&PresetFile {
                    version: 1,
                    preset: preset.clone(),
                })
                .map_err(|e| e.to_string())?;
                fs::write(path, json).map_err(|e| e.to_string())?;
                return Ok(true);
            }
            "--status" => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&settings).map_err(|e| e.to_string())?
                );
                return Ok(true);
            }
            "--help" | "-h" => {
                println!("RainGlass controls: --choose-wallpaper, --wallpaper PATH, --toggle-pause, --toggle-mute, --preset NAME, --blur 0..64, --zoom 1..3, --fit fill|fit|stretch, --volume 0..1, --quality eco|balanced|ultra, --import-preset FILE, --export-preset NAME FILE, --status");
                return Ok(true);
            }
            other => return Err(format!("Unknown option: {other}")),
        }
        self.save(&settings)?;
        Ok(true)
    }
}

fn parse_range(value: Option<&String>, min: f64, max: f64) -> Result<f64, String> {
    let v = value
        .ok_or("Missing numeric value")?
        .parse::<f64>()
        .map_err(|e| e.to_string())?;
    if !v.is_finite() || v < min || v > max {
        return Err(format!("Value must be between {min} and {max}"));
    }
    Ok(v)
}

fn apply_builtin(settings: &mut AppSettings, name: &str) -> Result<(), String> {
    let was_muted = settings.audio.muted;
    settings.rain = RainParameters::default();
    settings.atmosphere = Default::default();
    settings.audio = Default::default();
    settings.frame = Default::default();
    settings.audio.muted = was_muted;
    match name.to_ascii_lowercase().as_str() {
        "cozy window" | "cozy" => {
            settings.rain.intensity = 0.58;
            settings.rain.drop_count = 3200.0;
            settings.rain.droplet_size = 1.1;
            settings.rain.gravity = 0.85;
            settings.atmosphere.condensation = 0.58;
            settings.atmosphere.haze = 0.12;
            settings.atmosphere.fog_return_time = 22.0;
        }
        "light drizzle" | "drizzle" => {
            settings.rain.intensity = 0.30;
            settings.rain.droplet_size = 0.75;
            settings.rain.drop_count = 2800.0;
            settings.rain.gravity = 0.75;
            settings.rain.blur = 1.2;
            settings.rain.refraction = 0.42;
            settings.rain.trail_persistence = 3.0;
            settings.atmosphere.condensation = 0.3;
            settings.audio.master = 0.25;
            settings.audio.wind = 0.05;
        }
        "autumn storm" | "storm" => {
            settings.rain.intensity = 1.0;
            settings.rain.drop_count = 6000.0;
            settings.rain.droplet_size = 1.35;
            settings.rain.gravity = 1.55;
            settings.rain.wind = 0.6;
            settings.rain.blur = 3.8;
            settings.rain.refraction = 0.9;
            settings.rain.trail_persistence = 7.0;
            settings.rain.lightning_enabled = true;
            settings.rain.storm_frequency = 6.0;
            settings.atmosphere.condensation = 0.64;
            settings.atmosphere.haze = 0.25;
            settings.atmosphere.fog_return_time = 12.0;
            settings.audio.master = 0.5;
            settings.audio.wind = 0.4;
        }
        "night rain" | "night" => {
            settings.rain.intensity = 0.55;
            settings.rain.drop_count = 3600.0;
            settings.atmosphere.haze = 0.35;
            settings.atmosphere.condensation = 0.48;
            settings.audio.master = 0.28;
            settings.audio.room = 0.22;
        }
        "sleep" => {
            settings.rain.intensity = 0.28;
            settings.rain.drop_count = 2000.0;
            settings.atmosphere.haze = 0.16;
            settings.atmosphere.condensation = 0.38;
            settings.atmosphere.fog_return_time = 24.0;
            settings.audio.master = 0.18;
            settings.audio.wind = 0.03;
            settings.audio.thunder = 0.0;
        }
        _ => return Err("Preset was not found".into()),
    }
    Ok(())
}
