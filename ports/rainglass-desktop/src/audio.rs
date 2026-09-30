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
        })
    }
    pub fn tick(&self, settings: &AudioSettings, seconds: f32) {
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rodio::Source;
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
