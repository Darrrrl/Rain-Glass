use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RainParameters {
    pub intensity: f64,
    pub droplet_size: f64,
    pub drop_count: f64,
    pub gravity: f64,
    pub wind: f64,
    pub blur: f64,
    pub refraction: f64,
    pub trail_persistence: f64,
    pub lightning_enabled: bool,
    pub storm_frequency: f64,
    // None retains compatibility with macOS presets expressed in strikes/hour.
    pub thunder_probability: Option<f64>,
    pub lightning_intensity: f64,
}

impl Default for RainParameters {
    fn default() -> Self {
        Self {
            intensity: 0.72,
            droplet_size: 1.0,
            drop_count: 4800.0,
            gravity: 1.0,
            wind: 0.0,
            blur: 2.0,
            refraction: 0.65,
            trail_persistence: 4.5,
            lightning_enabled: false,
            storm_frequency: 0.0,
            thunder_probability: None,
            lightning_intensity: 1.0,
        }
    }
}

impl RainParameters {
    pub fn clamped(mut self) -> Self {
        self.intensity = self.intensity.clamp(0.0, 1.0);
        self.droplet_size = self.droplet_size.clamp(0.5, 2.0);
        self.drop_count = self.drop_count.clamp(0.0, 6000.0);
        self.gravity = self.gravity.clamp(0.0, 2.0);
        self.wind = self.wind.clamp(-1.0, 1.0);
        self.blur = self.blur.clamp(0.0, 64.0);
        self.refraction = self.refraction.clamp(0.0, 1.0);
        self.trail_persistence = self.trail_persistence.clamp(0.5, 15.0);
        self.storm_frequency = self.storm_frequency.clamp(0.0, 30.0);
        self.thunder_probability = self.thunder_probability.map(|p| p.clamp(0.0, 1.0));
        self.lightning_intensity = self.lightning_intensity.clamp(0.0, 1.0);
        self
    }

    pub fn approach(&mut self, target: &Self, dt: f32) {
        let t = 1.0 - (-f64::from(dt) * 2.2).exp();
        macro_rules! blend {
            ($field:ident) => {
                self.$field += (target.$field - self.$field) * t
            };
        }
        blend!(intensity);
        blend!(droplet_size);
        blend!(drop_count);
        blend!(gravity);
        blend!(wind);
        blend!(blur);
        blend!(refraction);
        blend!(trail_persistence);
        blend!(storm_frequency);
        self.lightning_enabled = target.lightning_enabled;
        self.thunder_probability = target.thunder_probability;
        self.lightning_intensity = target.lightning_intensity;
    }

    pub fn probability_per_second(&self) -> f64 {
        self.thunder_probability
            .unwrap_or(self.storm_frequency / 3600.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AtmosphereSettings {
    pub condensation: f64,
    pub haze: f64,
    pub imperfections: f64,
    pub fog_softness: f64,
    pub fog_return_time: f64,
}

impl Default for AtmosphereSettings {
    fn default() -> Self {
        Self {
            condensation: 0.45,
            haze: 0.0,
            imperfections: 0.0,
            fog_softness: 0.65,
            fog_return_time: 18.0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AudioSettings {
    pub master: f64,
    pub muted: bool,
    pub window: f64,
    pub distant: f64,
    pub wind: f64,
    pub room: f64,
    pub thunder: f64,
    pub glass_taps: f64,
}

impl Default for AudioSettings {
    fn default() -> Self {
        Self {
            master: 0.35,
            muted: false,
            window: 0.65,
            distant: 0.45,
            wind: 0.16,
            room: 0.08,
            thunder: 0.65,
            glass_taps: 0.2,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FrameLayout {
    #[default]
    Off,
    Two,
    Four,
    Six,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct WindowFrameSettings {
    pub layout: FrameLayout,
    pub thickness: f64,
}
impl Default for WindowFrameSettings {
    fn default() -> Self {
        Self {
            layout: FrameLayout::Off,
            thickness: 12.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScenePreset {
    pub id: String,
    pub name: String,
    pub rain: RainParameters,
    pub atmosphere: AtmosphereSettings,
    pub audio: AudioSettings,
    #[serde(default)]
    pub frame: WindowFrameSettings,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PresetFile {
    pub version: u32,
    pub preset: ScenePreset,
}

impl PresetFile {
    pub fn parse(source: &str) -> Result<Self, String> {
        let file: Self = serde_json::from_str(source).map_err(|e| e.to_string())?;
        if file.version != 1 {
            return Err("Unsupported preset version".into());
        }
        if file.preset.name.trim().is_empty() || file.preset.name.chars().count() > 40 {
            return Err("Invalid preset name".into());
        }
        let r = file.preset.rain;
        let a = file.preset.atmosphere;
        let s = file.preset.audio;
        let values = [
            r.intensity,
            r.droplet_size,
            r.drop_count,
            r.gravity,
            r.wind,
            r.blur,
            r.refraction,
            r.trail_persistence,
            r.storm_frequency,
            a.condensation,
            a.haze,
            a.imperfections,
            a.fog_softness,
            a.fog_return_time,
            s.master,
            s.window,
            s.distant,
            s.wind,
            s.room,
            s.thunder,
            s.glass_taps,
            file.preset.frame.thickness,
        ];
        if values.iter().any(|v| !v.is_finite())
            || r != r.clamped()
            || !(0.0..=1.0).contains(&a.condensation)
            || !(0.0..=1.0).contains(&a.haze)
            || !(0.0..=1.0).contains(&a.imperfections)
            || !(0.0..=1.0).contains(&a.fog_softness)
            || !(8.0..=35.0).contains(&a.fog_return_time)
            || !(6.0..=24.0).contains(&file.preset.frame.thickness)
            || [
                s.master,
                s.window,
                s.distant,
                s.wind,
                s.room,
                s.thunder,
                s.glass_taps,
            ]
            .iter()
            .any(|v| !(0.0..=1.0).contains(v))
        {
            return Err("Preset values are out of range".into());
        }
        Ok(file)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FitMode {
    Fill,
    Fit,
    Stretch,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Quality {
    Eco,
    Balanced,
    Ultra,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub enum FrameRate {
    #[serde(rename = "30")]
    Fps30,
    #[serde(rename = "60")]
    Fps60,
    // Kept for configurations saved before independent frame-rate selection.
    #[serde(rename = "120")]
    Legacy120,
    #[serde(rename = "monitor")]
    Monitor,
    #[serde(rename = "fixed")]
    Fixed(u32),
}

impl FrameRate {
    pub fn hz(self, refresh_millihertz: Option<u32>) -> f64 {
        match self {
            Self::Fps30 => 30.0,
            Self::Fps60 => 60.0,
            Self::Legacy120 => 120.0,
            Self::Fixed(fps) => f64::from(fps),
            Self::Monitor => refresh_millihertz
                .filter(|hz| *hz > 0)
                .map(|hz| f64::from(hz) / 1000.0)
                .unwrap_or(60.0),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct AppSettings {
    pub wallpaper: Option<String>,
    pub fit: FitMode,
    pub zoom: f32,
    pub quality: Quality,
    pub frame_rate: FrameRate,
    pub seed: u64,
    pub paused: bool,
    pub rain: RainParameters,
    pub atmosphere: AtmosphereSettings,
    pub audio: AudioSettings,
    pub frame: WindowFrameSettings,
    pub saved_presets: Vec<ScenePreset>,
    pub theme: String,
    pub start_at_login: bool,
    pub diagnostics_overlay: bool,
    pub weather: WeatherSettings,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            wallpaper: None,
            fit: FitMode::Fill,
            zoom: 1.0,
            quality: Quality::Balanced,
            frame_rate: FrameRate::Fps60,
            seed: 0x5241494e474c4153,
            paused: false,
            rain: RainParameters {
                blur: if cfg!(target_os = "windows") {
                    0.0
                } else {
                    RainParameters::default().blur
                },
                ..RainParameters::default()
            },
            atmosphere: AtmosphereSettings::default(),
            audio: AudioSettings::default(),
            frame: WindowFrameSettings::default(),
            saved_presets: Vec::new(),
            theme: "system".into(),
            start_at_login: false,
            diagnostics_overlay: false,
            weather: WeatherSettings::default(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct WeatherSettings {
    pub enabled: bool,
    pub city: Option<WeatherCity>,
    pub cached: Option<WeatherConditions>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WeatherCity {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub country: String,
    pub latitude: f64,
    pub longitude: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WeatherConditions {
    pub precipitation: f64,
    pub wind_speed: f64,
    pub wind_direction: f64,
    pub cloud_cover: f64,
    pub weather_code: u32,
    pub fetched_at: u64,
}

impl WeatherSettings {
    pub fn effective(&self, base: RainParameters) -> RainParameters {
        let Some(c) = self
            .cached
            .as_ref()
            .filter(|_| self.enabled && self.city.is_some())
        else {
            return base;
        };
        let mut r = base;
        let rain = c.precipitation.max(0.0);
        let level = (rain / 5.0).min(1.0);
        r.intensity = if rain < 0.05 {
            0.0
        } else {
            0.22 + level * 0.78
        };
        r.drop_count = if rain < 0.05 {
            0.0
        } else {
            2000.0 + level * 4000.0
        };
        r.droplet_size = 0.75 + level * 0.75;
        r.gravity = 0.8 + level * 0.9;
        r.wind = (-c.wind_direction.to_radians().sin() * c.wind_speed / 40.0).clamp(-1.0, 1.0);
        r.blur = 1.0 + c.cloud_cover.clamp(0.0, 100.0) / 100.0 * 2.0;
        r.lightning_enabled = (95..=99).contains(&c.weather_code);
        r.storm_frequency = if r.lightning_enabled {
            3.0 + level * 9.0
        } else {
            0.0
        };
        r.thunder_probability = Some(r.storm_frequency / 3600.0);
        r.clamped()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn weather_overrides_effective_settings_and_preserves_manual_values() {
        let base = RainParameters {
            intensity: 0.4,
            wind: 0.2,
            blur: 64.0,
            thunder_probability: Some(1.0),
            ..Default::default()
        };
        let mut weather = WeatherSettings {
            enabled: true,
            city: Some(WeatherCity {
                id: 1,
                name: "Test".into(),
                country: "AT".into(),
                latitude: 48.2,
                longitude: 16.3,
            }),
            cached: Some(WeatherConditions {
                precipitation: 5.0,
                wind_speed: 40.0,
                wind_direction: 90.0,
                cloud_cover: 100.0,
                weather_code: 95,
                fetched_at: 1,
            }),
        };
        let effective = weather.effective(base);
        assert_eq!(effective.intensity, 1.0);
        assert_eq!(effective.wind, -1.0);
        assert_eq!(effective.blur, 3.0);
        assert_eq!(effective.thunder_probability, Some(12.0 / 3600.0));
        weather.enabled = false;
        assert_eq!(weather.effective(base), base);
    }
    #[test]
    fn imports_legacy_macos_preset_defaults() {
        let json = r#"{
          "version":1,
          "preset":{
            "id":"7F59F5A8-E331-41BA-A641-B606DB34D31A",
            "name":"Old Rain",
            "rain":{"intensity":0.6,"dropletSize":1.0,"dropCount":3500,
                    "gravity":1.0,"wind":0.0,"blur":4.0,"refraction":0.65,
                    "trailPersistence":4.5},
            "atmosphere":{"condensation":0.4,"haze":0.0,"imperfections":0.0},
            "audio":{"master":0.35,"muted":false,"window":0.65,
                     "distant":0.45,"wind":0.16,"room":0.08,"thunder":0.65}
          }
        }"#;
        let file = PresetFile::parse(json).unwrap();
        assert_eq!(file.preset.audio.glass_taps, 0.2);
        assert_eq!(file.preset.frame.layout, FrameLayout::Off);
        assert_eq!(file.preset.atmosphere.fog_return_time, 18.0);
    }
    #[test]
    fn invalid_preset_values_are_rejected() {
        let mut value = serde_json::to_value(PresetFile {
            version: 1,
            preset: ScenePreset {
                id: "0".into(),
                name: "Bad".into(),
                rain: RainParameters::default(),
                atmosphere: AtmosphereSettings::default(),
                audio: AudioSettings::default(),
                frame: WindowFrameSettings::default(),
            },
        })
        .unwrap();
        value["preset"]["rain"]["blur"] = serde_json::json!(100);
        assert!(PresetFile::parse(&value.to_string()).is_err());
    }
}
