use crate::settings_store::SettingsStore;
use eframe::egui;
#[cfg(target_os = "windows")]
use rainglass_core::settings::Quality;
use rainglass_core::settings::{AppSettings, FitMode, FrameLayout, ScenePreset};
use std::path::Path;

pub fn show(store: SettingsStore) -> Result<(), String> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("RainGlass Settings")
            .with_inner_size([420.0, 650.0])
            .with_min_inner_size([360.0, 460.0]),
        ..Default::default()
    };
    eframe::run_native(
        "RainGlass Settings",
        options,
        Box::new(move |_context| {
            Ok(Box::new(SettingsPanel {
                settings: store.load(),
                store,
                status: String::new(),
                preset_name: String::new(),
                selected_preset: None,
            }))
        }),
    )
    .map_err(|e| e.to_string())
}

struct SettingsPanel {
    store: SettingsStore,
    settings: AppSettings,
    status: String,
    preset_name: String,
    selected_preset: Option<String>,
}

impl SettingsPanel {
    fn save(&mut self) {
        if let Err(error) = self.store.save(&self.settings) {
            self.status = error;
        }
    }
    fn built_in(&mut self, name: &str) {
        match self.store.apply_command(&["--preset".into(), name.into()]) {
            Ok(_) => {
                self.settings = self.store.load();
                self.status = format!("Applied {name}");
            }
            Err(error) => self.status = error,
        }
    }
    fn choose_wallpaper(&mut self) {
        if let Some(path) = rfd::FileDialog::new()
            .add_filter(
                "Image",
                &["jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff"],
            )
            .pick_file()
        {
            if image::image_dimensions(&path).is_ok() {
                self.settings.wallpaper = Some(path.to_string_lossy().into_owned());
                self.status = "Wallpaper updated".into();
            } else {
                self.status = "This image could not be decoded".into();
            }
        }
    }
    fn save_preset(&mut self) {
        let name = self.preset_name.trim();
        if name.is_empty() || name.chars().count() > 40 {
            self.status = "Enter a preset name up to 40 characters".into();
            return;
        }
        if self
            .settings
            .saved_presets
            .iter()
            .any(|p| p.name.eq_ignore_ascii_case(name))
        {
            self.status = "That preset name already exists".into();
            return;
        }
        let preset = ScenePreset {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.into(),
            rain: self.settings.rain,
            atmosphere: self.settings.atmosphere,
            audio: self.settings.audio,
            frame: self.settings.frame,
        };
        self.selected_preset = Some(preset.name.clone());
        self.settings.saved_presets.push(preset);
        self.preset_name.clear();
        self.status = "Preset saved".into();
    }
}

impl eframe::App for SettingsPanel {
    fn update(&mut self, context: &egui::Context, _frame: &mut eframe::Frame) {
        let previous = serde_json::to_vec(&self.settings).unwrap_or_default();
        egui::CentralPanel::default().show(context, |ui| {
            ui.heading("RainGlass");
            ui.label("Changes appear on the desktop automatically.");
            ui.separator();
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.heading("Scene");
                ui.horizontal_wrapped(|ui| {
                    for (label, name) in [
                        ("Cozy Window", "cozy"),
                        ("Light Drizzle", "drizzle"),
                        ("Autumn Storm", "storm"),
                        ("Night Rain", "night"),
                        ("Sleep", "sleep"),
                    ] {
                        if ui.button(label).clicked() {
                            self.built_in(name);
                        }
                    }
                });
                ui.add(
                    egui::Slider::new(&mut self.settings.rain.intensity, 0.0..=1.0)
                        .text("Rain amount"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.rain.droplet_size, 0.5..=2.0)
                        .text("Drop size"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.rain.drop_count, 0.0..=6000.0)
                        .text("Drop count"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.rain.gravity, 0.0..=2.0).text("Gravity"),
                );
                ui.add(egui::Slider::new(&mut self.settings.rain.wind, -1.0..=1.0).text("Wind"));
                ui.add(
                    egui::Slider::new(&mut self.settings.rain.refraction, 0.0..=1.0)
                        .text("Refraction"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.rain.trail_persistence, 0.5..=15.0)
                        .text("Trail persistence"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.atmosphere.condensation, 0.0..=1.0)
                        .text("Condensation"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.atmosphere.fog_softness, 0.0..=1.0)
                        .text("Fog softness"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.atmosphere.fog_return_time, 8.0..=35.0)
                        .text("Fog return"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.atmosphere.haze, 0.0..=1.0).text("Haze"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.atmosphere.imperfections, 0.0..=1.0)
                        .text("Glass texture"),
                );
                ui.separator();
                ui.heading("Wallpaper");
                ui.label(
                    self.settings
                        .wallpaper
                        .as_deref()
                        .and_then(|path| Path::new(path).file_name())
                        .map(|name| name.to_string_lossy())
                        .unwrap_or_default(),
                );
                if ui.button("Choose Image…").clicked() {
                    self.choose_wallpaper();
                }
                ui.add(
                    egui::Slider::new(&mut self.settings.rain.blur, 0.0..=64.0)
                        .text("Background blur"),
                );
                ui.add(egui::Slider::new(&mut self.settings.zoom, 1.0..=3.0).text("Zoom"));
                ui.horizontal(|ui| {
                    ui.label("Fit");
                    ui.selectable_value(&mut self.settings.fit, FitMode::Fill, "Fill");
                    ui.selectable_value(&mut self.settings.fit, FitMode::Fit, "Fit");
                    ui.selectable_value(&mut self.settings.fit, FitMode::Stretch, "Stretch");
                });
                ui.separator();
                ui.heading("Window frame");
                ui.horizontal_wrapped(|ui| {
                    for (layout, label) in [
                        (FrameLayout::Off, "Off"),
                        (FrameLayout::Two, "Two"),
                        (FrameLayout::Four, "Four"),
                        (FrameLayout::Six, "Six"),
                    ] {
                        ui.selectable_value(&mut self.settings.frame.layout, layout, label);
                    }
                });
                ui.add(
                    egui::Slider::new(&mut self.settings.frame.thickness, 6.0..=24.0)
                        .text("Thickness"),
                );
                ui.separator();
                ui.heading("Sound");
                ui.checkbox(&mut self.settings.audio.muted, "Mute");
                ui.add(
                    egui::Slider::new(&mut self.settings.audio.master, 0.0..=1.0).text("Master"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.audio.window, 0.0..=1.0)
                        .text("Window rain"),
                );
                ui.add(
                    egui::Slider::new(&mut self.settings.audio.distant, 0.0..=1.0)
                        .text("Distant rain"),
                );
                ui.add(egui::Slider::new(&mut self.settings.audio.wind, 0.0..=1.0).text("Wind"));
                ui.add(egui::Slider::new(&mut self.settings.audio.room, 0.0..=1.0).text("Room"));
                ui.separator();
                ui.heading("App");
                ui.checkbox(&mut self.settings.paused, "Pause rain");
                #[cfg(target_os = "windows")]
                ui.horizontal(|ui| {
                    ui.label("Quality");
                    ui.selectable_value(&mut self.settings.quality, Quality::Eco, "Eco");
                    ui.selectable_value(&mut self.settings.quality, Quality::Balanced, "Balanced");
                    ui.selectable_value(&mut self.settings.quality, Quality::Ultra, "Ultra");
                });
                #[cfg(target_os = "linux")]
                ui.label("GNOME renders at 30 FPS with adaptive resolution.");
                ui.separator();
                ui.heading("Presets");
                ui.horizontal(|ui| {
                    ui.text_edit_singleline(&mut self.preset_name);
                    if ui.button("Save current").clicked() {
                        self.save_preset();
                    }
                });
                egui::ComboBox::from_label("Saved preset")
                    .selected_text(self.selected_preset.as_deref().unwrap_or("Choose…"))
                    .show_ui(ui, |ui| {
                        for preset in &self.settings.saved_presets {
                            ui.selectable_value(
                                &mut self.selected_preset,
                                Some(preset.name.clone()),
                                &preset.name,
                            );
                        }
                    });
                ui.horizontal(|ui| {
                    if ui.button("Apply").clicked() {
                        if let Some(name) = self.selected_preset.clone() {
                            self.built_in(&name);
                        }
                    }
                    if ui.button("Delete").clicked() {
                        if let Some(name) = self.selected_preset.take() {
                            self.settings.saved_presets.retain(|p| p.name != name);
                        }
                    }
                    if ui.button("Import…").clicked() {
                        if let Some(path) = rfd::FileDialog::new()
                            .add_filter("Scene preset", &["json"])
                            .pick_file()
                        {
                            match self.store.apply_command(&[
                                "--import-preset".into(),
                                path.to_string_lossy().into_owned(),
                            ]) {
                                Ok(_) => self.settings = self.store.load(),
                                Err(error) => self.status = error,
                            }
                        }
                    }
                    if ui.button("Export…").clicked() {
                        if let Some(name) = self.selected_preset.clone() {
                            if let Some(path) = rfd::FileDialog::new()
                                .set_file_name(format!("{name}.json"))
                                .save_file()
                            {
                                if let Err(error) = self.store.apply_command(&[
                                    "--export-preset".into(),
                                    name,
                                    path.to_string_lossy().into_owned(),
                                ]) {
                                    self.status = error;
                                }
                            }
                        }
                    }
                });
            });
            if !self.status.is_empty() {
                ui.separator();
                ui.label(&self.status);
            }
        });
        if serde_json::to_vec(&self.settings).unwrap_or_default() != previous {
            self.save();
        }
    }
}
