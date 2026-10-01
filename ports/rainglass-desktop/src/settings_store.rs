use rainglass_core::settings::{
    AppSettings, FitMode, FrameRate, PresetFile, Quality, RainParameters,
};
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
            .and_then(|s| decode_settings(&s).ok())
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
            "--fps" => {
                settings.frame_rate = match args.get(1).map(String::as_str) {
                    Some("30") => FrameRate::Fps30,
                    Some("60") => FrameRate::Fps60,
                    Some("monitor") => FrameRate::Monitor,
                    Some(value) => FrameRate::Fixed(
                        value
                            .parse::<u32>()
                            .map_err(|_| "Frame rate must be a non-negative integer or monitor")?,
                    ),
                    _ => return Err("Frame rate must be a non-negative integer or monitor".into()),
                };
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
                println!("RainGlass controls: --choose-wallpaper, --wallpaper PATH, --toggle-pause, --toggle-mute, --preset NAME, --blur 0..64, --zoom 1..3, --fit fill|fit|stretch, --volume 0..1, --quality eco|balanced|ultra, --fps 30|60|monitor, --import-preset FILE, --export-preset NAME FILE, --status");
                return Ok(true);
            }
            other => return Err(format!("Unknown option: {other}")),
        }
        self.save(&settings)?;
        Ok(true)
    }
}

fn decode_settings(json: &str) -> Result<AppSettings, serde_json::Error> {
    let mut value: serde_json::Value = serde_json::from_str(json)?;
    if let Some(object) = value.as_object_mut() {
        if !object.contains_key("frame_rate") {
            let rate = match object.get("quality").and_then(|v| v.as_str()) {
                Some("eco") => "30",
                Some("ultra") => "120",
                _ => "60",
            };
            object.insert("frame_rate".into(), rate.into());
        }
        if let Some(rain) = object.get_mut("rain").and_then(|v| v.as_object_mut()) {
            if !rain.contains_key("thunderProbability") {
                let frequency = rain
                    .get("stormFrequency")
                    .and_then(|v| v.as_f64())
                    .unwrap_or(0.0);
                rain.insert(
                    "thunderProbability".into(),
                    serde_json::json!(frequency / 3600.0),
                );
            }
        }
    }
    serde_json::from_value(value)
}

#[cfg(test)]
mod frame_rate_tests {
    use super::*;

    #[test]
    fn migrates_rates_and_preserves_explicit_blur() {
        for (quality, expected) in [("eco", 30.0), ("balanced", 60.0), ("ultra", 120.0)] {
            let settings = decode_settings(&format!(
                r#"{{"quality":"{quality}","rain":{{"blur":16}}}}"#
            ))
            .unwrap();
            assert_eq!(settings.frame_rate.hz(None), expected);
            assert_eq!(settings.rain.blur, 16.0);
        }
        #[cfg(target_os = "windows")]
        assert_eq!(AppSettings::default().rain.blur, 0.0);
    }

    #[test]
    fn monitor_rate_round_trips_independently_of_quality() {
        let settings = decode_settings(r#"{"quality":"eco","frame_rate":"monitor"}"#).unwrap();
        assert_eq!(settings.frame_rate.hz(Some(165000)), 165.0);
        assert_eq!(settings.frame_rate.hz(None), 60.0);
        assert_eq!(settings.frame_rate.hz(Some(0)), 60.0);
        assert_eq!(
            decode_settings(&serde_json::to_string(&settings).unwrap())
                .unwrap()
                .frame_rate,
            FrameRate::Monitor
        );
    }

    #[test]
    fn custom_zero_and_legacy_storm_migrate_without_changing_audio() {
        let settings = decode_settings(r#"{"frame_rate":{"fixed":0},"rain":{"stormFrequency":12,"blur":64},"audio":{"muted":true,"master":0.8}}"#).unwrap();
        assert_eq!(settings.frame_rate.hz(Some(165000)), 0.0);
        assert_eq!(settings.rain.thunder_probability, Some(12.0 / 3600.0));
        assert!(settings.audio.muted);
        assert_eq!(settings.audio.master, 0.8);
        for fps in [30, 60, 165, 240] {
            let mut s = settings.clone();
            s.frame_rate = FrameRate::Fixed(fps);
            assert_eq!(
                decode_settings(&serde_json::to_string(&s).unwrap())
                    .unwrap()
                    .frame_rate
                    .hz(None),
                fps as f64
            );
        }
    }

    #[test]
    fn frame_rate_commands_persist_and_reject_invalid_values() {
        let folder = std::env::temp_dir().join(format!("rainglass-rate-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&folder).unwrap();
        let store = SettingsStore {
            path: folder.join("settings.json"),
        };
        for (value, expected) in [
            ("30", FrameRate::Fps30),
            ("60", FrameRate::Fps60),
            ("monitor", FrameRate::Monitor),
        ] {
            store
                .apply_command(&["--fps".into(), value.into()])
                .unwrap();
            assert_eq!(store.load().frame_rate, expected);
        }
        assert!(store.apply_command(&["--fps".into(), "-1".into()]).is_err());
        assert_eq!(store.load().frame_rate, FrameRate::Monitor);
        store
            .apply_command(&["--quality".into(), "eco".into()])
            .unwrap();
        assert_eq!(store.load().frame_rate, FrameRate::Monitor);
        fs::remove_file(&store.path).unwrap();
        fs::remove_dir(folder).unwrap();
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

pub fn apply_builtin(settings: &mut AppSettings, name: &str) -> Result<(), String> {
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
