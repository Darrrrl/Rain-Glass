use rainglass_core::simulation::{Simulation, Vec2};

/// Low resolution water height and persistent condensation. RGBA8 is used so
/// upload rows are naturally aligned after width is rounded to 64 pixels.
pub struct WaterMask {
    pub width: u32,
    pub height: u32,
    pub bytes: Vec<u8>,
    fog: Vec<f32>,
}

impl WaterMask {
    pub fn new(width: u32, height: u32) -> Self {
        let width = ((width.max(1) + 63) / 64) * 64;
        let height = height.max(1);
        let count = (width * height) as usize;
        Self {
            width,
            height,
            bytes: vec![0; count * 4],
            fog: vec![1.0; count],
        }
    }

    pub fn update(&mut self, sim: &Simulation, dt: f32, fog_return: f32) {
        let sx = self.width as f32 / sim.width.max(1.0);
        let sy = self.height as f32 / sim.height.max(1.0);
        let return_rate = (dt / fog_return.max(1.0)).clamp(0.0, 1.0);
        for (i, fog) in self.fog.iter_mut().enumerate() {
            *fog += (1.0 - *fog) * return_rate;
            self.bytes[i * 4] = 0;
        }
        for trail in &sim.trails {
            let alpha = ((1.0 - trail.age / trail.lifetime) * trail.strength).clamp(0.0, 1.0);
            self.paint_segment(
                trail.start,
                trail.end,
                trail.start_width,
                trail.end_width,
                alpha,
                sx,
                sy,
            );
        }
        for bridge in &sim.bridges {
            self.paint_segment(
                bridge.start,
                bridge.end,
                bridge.width,
                bridge.width,
                0.4,
                sx,
                sy,
            );
        }
        for d in &sim.drops {
            if d.birth_delay > 0.0 {
                continue;
            }
            let scale = d.birth_fade * d.birth_fade * (3.0 - 2.0 * d.birth_fade);
            self.paint_drop(
                d.pos,
                d.radius * (0.9 + 0.1 * scale),
                d.shape_aspect,
                d.shape_asymmetry,
                d.opacity * scale,
                sx,
                sy,
            );
            if !d.pinned && d.anchor.distance_to(d.pos) > 0.1 {
                self.paint_segment(
                    d.anchor,
                    d.pos,
                    d.trail_width,
                    d.trail_width,
                    (d.radius / 3.0).clamp(0.4, 1.0) * scale,
                    sx,
                    sy,
                );
            }
        }
        for (i, fog) in self.fog.iter().enumerate() {
            self.bytes[i * 4 + 1] = (fog * 255.0) as u8;
            self.bytes[i * 4 + 2] = 0;
            self.bytes[i * 4 + 3] = 255;
        }
    }

    fn paint_drop(
        &mut self,
        pos: Vec2,
        radius: f32,
        aspect: f32,
        asymmetry: f32,
        opacity: f32,
        sx: f32,
        sy: f32,
    ) {
        let cx = pos.x * sx;
        let cy = pos.y * sy;
        let rx = (radius * sx).max(0.5);
        let ry = (radius * aspect * sy).max(0.5);
        let left = (cx - rx * 1.2).floor().max(0.0) as u32;
        let right = (cx + rx * 1.2).ceil().min(self.width as f32) as u32;
        let top = (cy - ry * 1.2).floor().max(0.0) as u32;
        let bottom = (cy + ry * 1.2).ceil().min(self.height as f32) as u32;
        for y in top..bottom {
            for x in left..right {
                let dy = (y as f32 + 0.5 - cy) / ry;
                let dx = (x as f32 + 0.5 - cx) / rx + asymmetry * (0.3 - dy * dy);
                let r2 = dx * dx + dy * dy;
                if r2 >= 1.0 {
                    continue;
                }
                let height = (1.0 - r2).sqrt() * opacity;
                let i = (y * self.width + x) as usize;
                self.bytes[i * 4] = self.bytes[i * 4].max((height * 255.0).clamp(0.0, 255.0) as u8);
                self.fog[i] = (self.fog[i] - height * 0.35).max(0.0);
            }
        }
    }

    fn paint_segment(
        &mut self,
        start: Vec2,
        end: Vec2,
        w0: f32,
        w1: f32,
        opacity: f32,
        sx: f32,
        sy: f32,
    ) {
        let ax = start.x * sx;
        let ay = start.y * sy;
        let bx = end.x * sx;
        let by = end.y * sy;
        let max_width = w0.max(w1) * sx.max(sy);
        let left = (ax.min(bx) - max_width).floor().max(0.0) as u32;
        let right = (ax.max(bx) + max_width).ceil().min(self.width as f32) as u32;
        let top = (ay.min(by) - max_width).floor().max(0.0) as u32;
        let bottom = (ay.max(by) + max_width).ceil().min(self.height as f32) as u32;
        let vx = bx - ax;
        let vy = by - ay;
        let len2 = (vx * vx + vy * vy).max(0.0001);
        for y in top..bottom {
            for x in left..right {
                let px = x as f32 + 0.5 - ax;
                let py = y as f32 + 0.5 - ay;
                let t = ((px * vx + py * vy) / len2).clamp(0.0, 1.0);
                let dx = px - vx * t;
                let dy = py - vy * t;
                let width = (w0 + (w1 - w0) * t) * 0.5 * sx.max(sy);
                let distance = (dx * dx + dy * dy).sqrt() / width.max(0.4);
                if distance >= 1.0 {
                    continue;
                }
                let coverage = (1.0 - distance * distance) * opacity;
                let i = (y * self.width + x) as usize;
                self.bytes[i * 4] =
                    self.bytes[i * 4].max((coverage * 0.55 * 255.0).clamp(0.0, 255.0) as u8);
                self.fog[i] = (self.fog[i] - coverage * 0.28).max(0.0);
            }
        }
    }
}

trait Distance {
    fn distance_to(self, other: Self) -> f32;
}
impl Distance for Vec2 {
    fn distance_to(self, other: Self) -> f32 {
        ((self.x - other.x).powi(2) + (self.y - other.y).powi(2)).sqrt()
    }
}
