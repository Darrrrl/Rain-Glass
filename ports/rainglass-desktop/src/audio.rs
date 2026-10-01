use rainglass_core::settings::AudioSettings;
use rodio::{Decoder, OutputStream, OutputStreamBuilder, Sink};
use std::io::Cursor;

const SOURCES: [[&[u8]; 3]; 4] = [
    [
        include_bytes!("../../../RainGlass/Resources/Audio/window-a.m4a"),
        include_bytes!("../../../RainGlass/Resources/Audio/window-b.m4a"),
        include_bytes!("../../../RainGlass/Resources/Audio/window-c.m4a"),
    ],
    [
        include_bytes!("../../../RainGlass/Resources/Audio/distant-a.m4a"),
        include_bytes!("../../../RainGlass/Resources/Audio/distant-b.m4a"),
        include_bytes!("../../../RainGlass/Resources/Audio/distant-c.m4a"),
    ],
    [
        include_bytes!("../../../RainGlass/Resources/Audio/wind-a.m4a"),
        include_bytes!("../../../RainGlass/Resources/Audio/wind-b.m4a"),
        include_bytes!("../../../RainGlass/Resources/Audio/wind-c.m4a"),
    ],
    [
        include_bytes!("../../../RainGlass/Resources/Audio/room-a.m4a"),
        include_bytes!("../../../RainGlass/Resources/Audio/room-b.m4a"),
        include_bytes!("../../../RainGlass/Resources/Audio/room-c.m4a"),
    ],
];

pub struct AmbientAudio {
    _stream: OutputStream,
    sinks: Vec<[Sink; 3]>,
    effects: Vec<(Sink, f32, bool)>,
}

pub struct AudioWorker {
    sender: std::sync::mpsc::SyncSender<AudioCommand>,
    latest: std::sync::Arc<std::sync::Mutex<(AudioSettings, f32, bool)>>,
    tap_times: std::sync::Mutex<Vec<std::time::Instant>>,
    pub status: std::sync::Arc<std::sync::Mutex<Option<String>>>,
}

enum AudioCommand {
    Thunder(crate::storm::Strike),
    Tap(rainglass_core::simulation::Arrival),
}

impl AudioWorker {
    pub fn start() -> Self {
        let (sender, receiver) = std::sync::mpsc::sync_channel::<AudioCommand>(64);
        let latest = std::sync::Arc::new(std::sync::Mutex::new((
            AudioSettings::default(),
            0.0,
            false,
        )));
        let worker_latest = latest.clone();
        let status = std::sync::Arc::new(std::sync::Mutex::new(Some("Initializing audio…".into())));
        let worker_status = status.clone();
        std::thread::spawn(move || {
            let started = std::time::Instant::now();
            match AmbientAudio::start() {
                Ok(mut audio) => {
                    *worker_status.lock().unwrap() = None;
                    eprintln!(
                        "RainGlass audio initialized in {:.1} ms",
                        started.elapsed().as_secs_f64() * 1000.0
                    );
                    loop {
                        let (settings, seconds, stopped) = *worker_latest.lock().unwrap();
                        audio.tick(&settings, seconds);
                        if stopped {
                            audio.effects.clear();
                        }
                        match receiver.recv_timeout(std::time::Duration::from_millis(20)) {
                            Ok(AudioCommand::Thunder(strike)) if !stopped => {
                                audio.thunder(&settings, strike)
                            }
                            Ok(AudioCommand::Tap(arrival)) if !stopped => {
                                audio.tap(&settings, arrival)
                            }
                            Ok(_) | Err(std::sync::mpsc::RecvTimeoutError::Timeout) => (),
                            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                        }
                    }
                }
                Err(e) => {
                    *worker_status.lock().unwrap() = Some(e.clone());
                    eprintln!("RainGlass audio: {e}");
                }
            }
        });
        Self {
            sender,
            latest,
            tap_times: std::sync::Mutex::new(Vec::new()),
            status,
        }
    }

    pub fn tick(&self, settings: &AudioSettings, seconds: f32, stopped: bool) {
        let mut settings = *settings;
        if stopped {
            settings.muted = true;
        }
        *self.latest.lock().unwrap() = (settings, seconds, stopped);
    }
    pub fn thunder(&self, strike: crate::storm::Strike) {
        let _ = self.sender.try_send(AudioCommand::Thunder(strike));
    }
    pub fn tap(&self, arrival: rainglass_core::simulation::Arrival) {
        let (settings, _, stopped) = *self.latest.lock().unwrap();
        if stopped || settings.muted || settings.glass_taps == 0.0 {
            return;
        }
        let now = std::time::Instant::now();
        let mut times = self.tap_times.lock().unwrap();
        times.retain(|at| now.duration_since(*at).as_secs_f64() < 1.0);
        if times.len() >= 3
            || times
                .last()
                .is_some_and(|at| now.duration_since(*at).as_secs_f64() < 0.18)
        {
            return;
        }
        times.push(now);
        let _ = self.sender.try_send(AudioCommand::Tap(arrival));
    }
}

impl AmbientAudio {
    pub fn start() -> Result<Self, String> {
        let stream = OutputStreamBuilder::open_default_stream().map_err(|e| e.to_string())?;
        let mut sinks = Vec::new();
        for variants in SOURCES {
            let mut layer = Vec::new();
            for bytes in variants {
                let sink = Sink::connect_new(stream.mixer());
                let decoded = Decoder::builder()
                    .with_data(Cursor::new(bytes))
                    .with_mime_type("audio/mp4")
                    .with_byte_len(bytes.len() as u64)
                    .with_seekable(true)
                    .build_looped()
                    .map_err(|e| e.to_string())?;
                sink.append(decoded);
                sink.set_volume(0.0);
                layer.push(sink);
            }
            sinks.push(layer.try_into().map_err(|_| "Audio layer setup failed")?);
        }
        Ok(Self {
            _stream: stream,
            sinks,
            effects: Vec::new(),
        })
    }
    pub fn tick(&mut self, settings: &AudioSettings, seconds: f32) {
        let base = if settings.muted {
            0.0
        } else {
            settings.master.clamp(0.0, 1.0) as f32
        };
        let levels = [
            settings.window,
            settings.distant,
            settings.wind,
            settings.room,
        ];
        for (layer, sinks) in self.sinks.iter().enumerate() {
            let phase = seconds / 95.0 + layer as f32 * 0.17;
            let weights = [0, 1, 2].map(|variant| {
                let angle = (phase + variant as f32 / 3.0) * std::f32::consts::TAU;
                (0.5 + 0.5 * angle.cos()).powi(2)
            });
            let total = weights.iter().sum::<f32>().max(0.01);
            for (sink, weight) in sinks.iter().zip(weights) {
                sink.set_volume(
                    base * levels[layer].clamp(0.0, 1.0) as f32 * (weight / total).sqrt(),
                );
            }
        }
        self.effects.retain(|(sink, _, _)| !sink.empty());
        for (sink, gain, thunder) in &self.effects {
            sink.set_volume(
                base * if *thunder {
                    settings.thunder
                } else {
                    settings.glass_taps
                } as f32
                    * gain,
            );
        }
    }
    fn effect(&mut self, samples: Vec<f32>, settings: &AudioSettings, gain: f32, thunder: bool) {
        use rodio::buffer::SamplesBuffer;
        self.effects.retain(|(sink, _, _)| !sink.empty());
        let limit = if thunder { 2 } else { 4 };
        if self
            .effects
            .iter()
            .filter(|(_, _, kind)| *kind == thunder)
            .count()
            >= limit
        {
            if let Some(index) = self
                .effects
                .iter()
                .position(|(_, _, kind)| *kind == thunder)
            {
                self.effects.remove(index);
            }
        }
        let sink = Sink::connect_new(self._stream.mixer());
        sink.set_volume(if settings.muted {
            0.0
        } else {
            settings.master as f32
                * if thunder {
                    settings.thunder
                } else {
                    settings.glass_taps
                } as f32
                * gain
        });
        sink.append(SamplesBuffer::new(2, 44100, samples));
        self.effects.push((sink, gain, thunder));
    }
    fn thunder(&mut self, settings: &AudioSettings, strike: crate::storm::Strike) {
        let bytes: &[u8] = if strike.distance < 1500.0 {
            include_bytes!("../../../RainGlass/Resources/Audio/thunder-near.m4a")
        } else {
            include_bytes!("../../../RainGlass/Resources/Audio/thunder-far.m4a")
        };
        if let Ok(source) = Decoder::builder()
            .with_data(Cursor::new(bytes))
            .with_mime_type("audio/mp4")
            .with_byte_len(bytes.len() as u64)
            .with_seekable(true)
            .build()
        {
            // Assets share the macOS 44.1-kHz stereo format; use UniformSourceIterator for other encodings.
            let uniform = rodio::source::UniformSourceIterator::new(source, 2, 44100);
            let mut samples: Vec<f32> = uniform.collect();
            for pair in samples.chunks_exact_mut(2) {
                pair[0] *= (1.0 - strike.pan).min(1.0);
                pair[1] *= (1.0 + strike.pan).min(1.0);
            }
            self.effect(
                samples,
                settings,
                (600.0 / strike.distance.max(600.0)).max(0.16) as f32,
                true,
            );
        }
    }
    fn tap(&mut self, settings: &AudioSettings, arrival: rainglass_core::simulation::Arrival) {
        if settings.muted || settings.glass_taps == 0.0 {
            return;
        }
        let variant = (arrival.id % 6) as usize;
        let mut samples = tap_samples(variant);
        let pan = ((arrival.x * 2.0 - 1.0) * 0.45).clamp(-0.45, 0.45);
        for pair in samples.chunks_exact_mut(2) {
            pair[0] *= (1.0 - pan).min(1.0);
            pair[1] *= (1.0 + pan).min(1.0);
        }
        self.effect(
            samples,
            settings,
            (arrival.radius / 8.0).clamp(0.55, 1.0),
            false,
        );
    }
}

fn tap_samples(variant: usize) -> Vec<f32> {
    let mut samples = Vec::new();
    let mut noise = 0x9e37u32 + variant as u32 * 997;
    for frame in 0..((0.065 + variant as f64 * 0.014) * 44100.0) as usize {
        let t = frame as f64 / 44100.0;
        noise = noise.wrapping_mul(1664525).wrapping_add(1013904223);
        let hiss = (noise >> 16) as f64 / 32768.0 - 1.0;
        let tone = (std::f64::consts::TAU * (850.0 + variant as f64 * 85.0) * t).sin() * 0.7
            + (std::f64::consts::TAU * (1500.0 + variant as f64 * 62.0) * t).sin() * 0.25;
        let sample = (0.13
            * (1.0 - (-t / 0.002).exp())
            * (-t * (36.0 + variant as f64 * 3.0)).exp()
            * (tone + hiss * (-t * 100.0).exp() * 0.25)) as f32;
        samples.extend([sample, sample]);
    }
    samples
}

#[cfg(test)]
mod tests {
    use super::*;
    use rodio::Source;
    #[test]
    fn thunder_and_synthesized_taps_are_valid_stereo_audio() {
        for bytes in [
            include_bytes!("../../../RainGlass/Resources/Audio/thunder-near.m4a").as_slice(),
            include_bytes!("../../../RainGlass/Resources/Audio/thunder-far.m4a").as_slice(),
        ] {
            let decoder = Decoder::builder()
                .with_data(Cursor::new(bytes))
                .with_mime_type("audio/mp4")
                .with_byte_len(bytes.len() as u64)
                .with_seekable(true)
                .build()
                .unwrap();
            assert!(decoder.sample_rate() > 0);
            assert!(decoder.take(1024).all(|s| s.is_finite()));
        }
        for variant in 0..6 {
            let samples = tap_samples(variant);
            assert_eq!(samples.len() % 2, 0);
            assert!(!samples.is_empty());
            assert!(samples.iter().all(|s| s.is_finite() && s.abs() <= 1.0));
        }
    }
    #[test]
    fn bundled_aac_loops_decode() {
        for layer in SOURCES {
            for bytes in layer {
                let decoder = Decoder::builder()
                    .with_data(Cursor::new(bytes))
                    .with_mime_type("audio/mp4")
                    .with_byte_len(bytes.len() as u64)
                    .with_seekable(true)
                    .build_looped()
                    .unwrap();
                assert!(decoder.sample_rate() > 0);
            }
        }
    }
}
