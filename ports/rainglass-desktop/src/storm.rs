use rainglass_core::settings::RainParameters;

#[derive(Clone, Copy, Debug)]
pub struct Strike {
    pub at: f64,
    pub distance: f64,
    pub pan: f32,
}
impl Strike {
    pub fn thunder_at(self) -> f64 {
        self.at + self.distance / 343.0
    }
    pub fn flash(self, now: f64) -> f32 {
        let t = now - self.at;
        if !(0.0..=0.65).contains(&t) {
            return 0.0;
        }
        let pulse = |center: f64, width: f64, gain: f64| {
            gain * (-(t - center).powi(2) / (2.0 * width * width)).exp()
        };
        ((pulse(0.05, 0.055, 1.5) + pulse(0.17, 0.045, 0.55) + pulse(0.28, 0.10, 0.3))
            * (1200.0 / self.distance).clamp(0.25, 1.0)) as f32
    }
}

pub struct Storm {
    next_trial: f64,
    random: u64,
    pending: Vec<Strike>,
    latest: Option<Strike>,
    running: bool,
    test_event: bool,
}
impl Storm {
    pub fn new(seed: u64) -> Self {
        Self {
            next_trial: 0.0,
            random: seed,
            pending: Vec::new(),
            latest: None,
            running: false,
            test_event: false,
        }
    }
    fn unit(&mut self) -> f64 {
        self.random = self.random.wrapping_add(0x9e3779b97f4a7c15);
        let mut v = self.random;
        v = (v ^ (v >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        v = (v ^ (v >> 27)).wrapping_mul(0x94d049bb133111eb);
        ((v ^ (v >> 31)) >> 11) as f64 / (1u64 << 53) as f64
    }
    pub fn trigger(&mut self, now: f64) {
        self.test_event = true;
        let strike = Strike {
            at: now,
            distance: 1000.0,
            pan: 0.0,
        };
        self.latest = Some(strike);
        self.pending.push(strike);
        self.running = true;
        self.next_trial = now + 1.0;
    }
    fn strike(&mut self, now: f64) {
        let distance = 300.0 + self.unit() * 4700.0;
        let pan = (self.unit() * 1.3 - 0.65) as f32;
        let strike = Strike {
            at: now,
            distance,
            pan,
        };
        self.latest = Some(strike);
        self.pending.push(strike);
    }
    pub fn tick(&mut self, now: f64, parameters: RainParameters, running: bool) -> Vec<Strike> {
        if !running || (!parameters.lightning_enabled && !self.test_event) {
            self.pending.clear();
            self.latest = None;
            self.running = false;
            self.test_event = false;
            return Vec::new();
        }
        if !self.running || now - self.next_trial > 2.0 {
            self.next_trial = now + 1.0;
            self.pending.clear();
            self.latest = None;
        }
        self.running = true;
        if parameters.lightning_enabled && now >= self.next_trial {
            self.next_trial += 1.0;
            if self.unit() < parameters.probability_per_second() {
                self.strike(now);
            }
        }
        let mut due = Vec::new();
        self.pending.retain(|s| {
            if now >= s.thunder_at() {
                if now - s.thunder_at() < 2.0 {
                    due.push(*s);
                }
                false
            } else {
                true
            }
        });
        if self.pending.is_empty() {
            self.test_event = false;
        }
        due
    }
    pub fn flash(&self, now: f64, intensity: f64) -> f32 {
        self.latest
            .map(|s| s.flash(now) * intensity as f32)
            .unwrap_or(0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn probability_and_delays_do_not_depend_on_frame_rate() {
        for fps in [30, 60, 165, 240] {
            let mut storm = Storm::new(1);
            let p = RainParameters {
                lightning_enabled: true,
                thunder_probability: Some(1.0),
                ..Default::default()
            };
            let mut count = 0;
            for frame in 0..=fps * 30 {
                count += storm.tick(frame as f64 / fps as f64, p, true).len();
            }
            assert!(count >= 15 && count <= 30);
            assert_eq!(storm.latest.unwrap().at, 30.0);
            storm.tick(31.0, p, false);
            assert!(storm.pending.is_empty());
            storm.tick(120.0, p, true);
            assert!(storm.latest.is_none());
        }
    }
    #[test]
    fn zero_never_strikes_and_flash_and_sound_are_separate() {
        let mut storm = Storm::new(2);
        let p = RainParameters {
            lightning_enabled: true,
            thunder_probability: Some(0.0),
            ..Default::default()
        };
        for second in 0..60 {
            assert!(storm.tick(second as f64, p, true).is_empty());
        }
        assert!(storm.latest.is_none());
        storm.trigger(60.0);
        assert_eq!(storm.flash(60.05, 0.0), 0.0);
        assert!(storm.flash(60.05, 1.0) > 0.0);
        assert!(storm.pending[0].thunder_at() > 60.0);
    }
}
