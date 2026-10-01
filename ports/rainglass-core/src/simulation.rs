use crate::settings::RainParameters;
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Vec2 {
    pub x: f32,
    pub y: f32,
}
impl Vec2 {
    fn distance(self, other: Self) -> f32 {
        ((self.x - other.x).powi(2) + (self.y - other.y).powi(2)).sqrt()
    }
}

#[derive(Clone, Debug)]
pub struct Drop {
    pub id: u64,
    pub pos: Vec2,
    pub anchor: Vec2,
    pub radius: f32,
    pub velocity: Vec2,
    pub mass: f32,
    pub age: f32,
    pub lifetime: f32,
    pub pinned: bool,
    pub opacity: f32,
    pub birth_delay: f32,
    pub birth_duration: f32,
    pub birth_fade: f32,
    pub shape_aspect: f32,
    pub shape_asymmetry: f32,
    pub shape_phase: f32,
    pub trail_width: f32,
    friction: f32,
    resistance: f32,
    drift: f32,
    sample_clock: f32,
}

#[derive(Clone, Debug)]
pub struct Trail {
    pub parent_id: u64,
    pub start: Vec2,
    pub end: Vec2,
    pub start_width: f32,
    pub end_width: f32,
    pub strength: f32,
    pub age: f32,
    pub lifetime: f32,
}

#[derive(Clone, Copy, Debug)]
pub struct Bridge {
    pub first_id: u64,
    pub second_id: u64,
    pub start: Vec2,
    pub end: Vec2,
    pub width: f32,
}

#[derive(Clone, Copy, Debug)]
pub struct Arrival {
    pub id: u64,
    pub radius: f32,
    pub x: f32,
}

#[derive(Clone)]
struct SplitMix64(u64);
impl SplitMix64 {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E3779B97F4A7C15);
        let mut v = self.0;
        v = (v ^ (v >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        v = (v ^ (v >> 27)).wrapping_mul(0x94D049BB133111EB);
        v ^ (v >> 31)
    }
    fn unit(&mut self) -> f32 {
        (self.next() >> 40) as f32 / 16_777_216.0
    }
    fn range(&mut self, lo: f32, hi: f32) -> f32 {
        lo + (hi - lo) * self.unit()
    }
}

pub struct Simulation {
    pub drops: Vec<Drop>,
    pub trails: Vec<Trail>,
    pub bridges: Vec<Bridge>,
    pub width: f32,
    pub height: f32,
    pub parameters: RainParameters,
    target: RainParameters,
    seed: u64,
    random: SplitMix64,
    next_id: u64,
    spawn_credit: f32,
    collision_credit: f32,
    startup_remaining: f32,
    arrivals: Vec<Arrival>,
    grid: HashMap<(i32, i32), Vec<usize>>,
}

impl Simulation {
    pub const MAX_DROPS: usize = 6000;
    pub const MAX_TRAILS: usize = 36000;
    pub fn new(seed: u64, width: f32, height: f32) -> Self {
        let mut sim = Self {
            drops: Vec::new(),
            trails: Vec::new(),
            bridges: Vec::new(),
            width,
            height,
            parameters: RainParameters::default(),
            target: RainParameters::default(),
            seed,
            random: SplitMix64(seed),
            next_id: 0,
            spawn_credit: 0.0,
            collision_credit: 0.0,
            startup_remaining: 2.0,
            arrivals: Vec::new(),
            grid: HashMap::new(),
        };
        sim.populate_initial();
        sim
    }
    pub fn set_parameters(&mut self, target: RainParameters) {
        self.target = target.clamped();
    }
    pub fn resize(&mut self, width: f32, height: f32) {
        if width <= 0.0 || height <= 0.0 || width == self.width && height == self.height {
            return;
        }
        let sx = width / self.width.max(1.0);
        let sy = height / self.height.max(1.0);
        for d in &mut self.drops {
            d.pos.x *= sx;
            d.pos.y *= sy;
            d.anchor.x *= sx;
            d.anchor.y *= sy;
        }
        for t in &mut self.trails {
            t.start.x *= sx;
            t.end.x *= sx;
            t.start.y *= sy;
            t.end.y *= sy;
        }
        for b in &mut self.bridges {
            b.start.x *= sx;
            b.end.x *= sx;
            b.start.y *= sy;
            b.end.y *= sy;
        }
        self.width = width;
        self.height = height;
        self.arrivals.clear();
        if self.drops.is_empty() {
            self.populate_initial();
        }
    }
    pub fn drain_arrivals(&mut self) -> Vec<Arrival> {
        std::mem::take(&mut self.arrivals)
    }
    pub fn step(&mut self, dt: f32) {
        if self.width <= 0.0 || self.height <= 0.0 {
            return;
        }
        let dt = dt.clamp(0.0, 1.0 / 20.0);
        let old_size = self.parameters.droplet_size;
        let old_persistence = self.parameters.trail_persistence;
        self.parameters.approach(&self.target, dt);
        let size_ratio = (self.parameters.droplet_size / old_size.max(0.01)) as f32;
        let persistence_ratio =
            (self.parameters.trail_persistence / old_persistence.max(0.01)) as f32;
        for d in &mut self.drops {
            d.radius *= size_ratio;
            d.mass *= size_ratio.powi(3);
        }
        for t in &mut self.trails {
            t.lifetime *= persistence_ratio;
        }
        let mut expired = Vec::new();
        for i in 0..self.drops.len() {
            let d = &mut self.drops[i];
            if d.birth_delay > 0.0 {
                d.birth_delay = (d.birth_delay - dt).max(0.0);
                continue;
            }
            d.age += dt;
            let old_fade = d.birth_fade;
            d.birth_fade = (d.birth_fade + dt / d.birth_duration).min(1.0);
            if old_fade < 0.5
                && d.birth_fade >= 0.5
                && self.startup_remaining <= 0.0
                && d.radius >= 3.5
                && Self::pair_hash(self.seed ^ 0xC6BC279692B5CC83, d.id) % 4 == 0
            {
                self.arrivals.push(Arrival {
                    id: d.id,
                    radius: d.radius,
                    x: d.pos.x / self.width,
                });
            }
            if !d.pinned && d.birth_fade >= 1.0 {
                let grip = surface_noise(
                    self.seed,
                    d.pos.x / 56.0,
                    d.pos.y / 56.0,
                    0xA0761D6478BD642F,
                );
                let flow = surface_noise(
                    self.seed,
                    d.pos.x / 105.0,
                    d.pos.y / 105.0,
                    0xE7037ED1A0B428DB,
                );
                d.sample_clock -= dt;
                if d.sample_clock <= 0.0 {
                    d.resistance = 0.55 + grip * 1.9;
                    d.drift = flow * 2.0 - 1.0;
                    d.sample_clock += 0.1;
                }
                let gravity =
                    (self.parameters.gravity * (0.75 + self.parameters.intensity * 0.5)) as f32;
                let size_speed = (d.radius / 4.0).max(0.3).powf(1.3);
                let adhesion = d.friction / 55.0 * d.resistance;
                let speed = if gravity > 0.0 {
                    (26.0 * gravity * size_speed / adhesion.max(0.3) - 3.0).clamp(0.0, 95.0)
                } else {
                    0.0
                };
                d.velocity.y += (speed - d.velocity.y)
                    * (1.0 - (-dt * (1.8 + d.radius.min(12.0) * 0.12)).exp());
                if speed < 0.8 && d.velocity.y < 0.5 && d.radius < 2.6 {
                    d.pinned = true;
                    d.velocity = Vec2::default();
                }
                let slope =
                    ((self.parameters.wind as f32) * 0.16 + d.drift * 0.11).clamp(-0.25, 0.25);
                d.velocity.x += (d.velocity.y * slope - d.velocity.x) * (1.0 - (-dt * 2.5).exp());
                d.velocity.x = d
                    .velocity
                    .x
                    .clamp(-d.velocity.y * 0.25, d.velocity.y * 0.25);
                d.pos.x += d.velocity.x * dt;
                d.pos.y += d.velocity.y * dt;
                let segment_len = (d.radius * 2.5).clamp(9.0, 20.0);
                if d.anchor.distance(d.pos) >= segment_len {
                    let new_width = trail_width(d);
                    self.trails.push(Trail {
                        parent_id: d.id,
                        start: d.anchor,
                        end: d.pos,
                        start_width: d.trail_width,
                        end_width: new_width,
                        strength: (d.radius / 3.0).clamp(0.4, 1.0) * d.birth_fade,
                        age: 0.0,
                        lifetime: self.parameters.trail_persistence as f32,
                    });
                    d.anchor = d.pos;
                    d.trail_width = new_width;
                }
            }
            if d.age >= d.lifetime || d.pos.y - d.radius > self.height + 16.0 {
                expired.push(i);
            }
        }
        for i in expired {
            self.drops[i] = self.make_drop(true, false);
        }
        self.collision_credit += dt;
        if self.collision_credit >= 1.0 / 30.0 {
            self.merge_collisions();
            self.collision_credit = 0.0;
        }
        for t in &mut self.trails {
            t.age += dt;
        }
        self.trails.retain(|t| t.age < t.lifetime);
        if self.trails.len() > Self::MAX_TRAILS {
            self.trails.drain(..self.trails.len() - Self::MAX_TRAILS);
        }
        self.replenish(dt);
    }
    fn target_count(&self) -> usize {
        ((self.parameters.drop_count * self.parameters.intensity) as usize).min(Self::MAX_DROPS)
    }
    fn populate_initial(&mut self) {
        let initial = ((self.target_count() as f32) * 0.25) as usize;
        for _ in 0..initial.max(1) {
            let d = self.make_drop(false, true);
            self.drops.push(d);
        }
    }
    fn replenish(&mut self, dt: f32) {
        let target = self.target_count();
        let startup = self.startup_remaining > 0.0;
        self.startup_remaining = (self.startup_remaining - dt).max(0.0);
        self.spawn_credit += dt
            * if startup {
                target as f32 * 0.375
            } else {
                target.max(self.drops.len()).max(60) as f32
            };
        let count = (self.spawn_credit as usize).min(36);
        self.spawn_credit -= count as f32;
        for _ in 0..count.min(target.saturating_sub(self.drops.len())) {
            let d = self.make_drop(true, false);
            self.drops.push(d);
        }
        if self.drops.len() > target {
            self.drops.truncate(target);
        }
    }
    fn rebuild_grid(&mut self) {
        self.grid.clear();
        for (i, d) in self.drops.iter().enumerate() {
            self.grid
                .entry((
                    (d.pos.x / 64.0).floor() as i32,
                    (d.pos.y / 64.0).floor() as i32,
                ))
                .or_default()
                .push(i);
        }
    }
    fn open_position(&mut self, radius: f32) -> Vec2 {
        self.rebuild_grid();
        let mut best = Vec2::default();
        let mut best_clearance = f32::NEG_INFINITY;
        for _ in 0..6 {
            let p = Vec2 {
                x: self.random.range(0.0, self.width),
                y: self.random.range(0.0, self.height),
            };
            let cx = (p.x / 64.0).floor() as i32;
            let cy = (p.y / 64.0).floor() as i32;
            let mut clearance = 64.0f32;
            for y in cy - 1..=cy + 1 {
                for x in cx - 1..=cx + 1 {
                    if let Some(indices) = self.grid.get(&(x, y)) {
                        for &index in indices {
                            let d = &self.drops[index];
                            clearance =
                                clearance.min(p.distance(d.pos) - (radius + d.radius) * 1.25);
                        }
                    }
                }
            }
            if clearance > best_clearance {
                best = p;
                best_clearance = clearance;
            }
            if clearance >= radius * 2.0 {
                break;
            }
        }
        best
    }
    fn make_drop(&mut self, fade: bool, small: bool) -> Drop {
        let roll = self.random.unit();
        let scale = self.parameters.droplet_size as f32;
        let radius = if small {
            self.random.range(0.8, 2.5)
        } else if roll < 0.83 {
            self.random.range(0.8, 2.8)
        } else if roll < 0.96 {
            self.random.range(2.8, 5.2)
        } else {
            self.random.range(6.0, 15.0)
        } * scale;
        let id = self.next_id;
        self.next_id += 1;
        let pinned = Self::pair_hash(self.seed, id) % 10 < 3;
        let lifetime = if pinned {
            self.random.range(45.0, 125.0)
        } else {
            self.random.range(14.0, 40.0)
        };
        let mut pos = self.open_position(radius);
        if pinned && Self::pair_hash(self.seed ^ 0xE7037ED1A0B428DB, id) % 10 == 0 {
            for _ in 0..8 {
                if self.drops.is_empty() {
                    break;
                }
                let index = ((self.random.unit() * self.drops.len() as f32) as usize)
                    .min(self.drops.len() - 1);
                let neighbor = &self.drops[index];
                if !neighbor.pinned
                    || radius.min(neighbor.radius) / radius.max(neighbor.radius) < 0.62
                {
                    continue;
                }
                let angle = self.random.range(0.0, std::f32::consts::TAU);
                let separation = (radius + neighbor.radius) * self.random.range(0.9, 1.08);
                let candidate = Vec2 {
                    x: neighbor.pos.x + angle.cos() * separation,
                    y: neighbor.pos.y + angle.sin() * separation,
                };
                if candidate.x >= 0.0
                    && candidate.x <= self.width
                    && candidate.y >= 0.0
                    && candidate.y <= self.height
                {
                    pos = candidate;
                    break;
                }
            }
        }
        let friction = self.random.range(28.0, 85.0);
        let phase = self.random.range(0.0, std::f32::consts::TAU);
        let opacity = if pinned {
            self.random.range(0.28, 0.55)
        } else {
            self.random.range(0.5, 0.78)
        };
        let strength = ((radius - 2.0) / 6.0).clamp(0.0, 1.0);
        let aspect =
            1.0 + self.random.range(-0.015, 0.015) + self.random.range(-0.03, 0.14) * strength;
        let asymmetry = self.random.range(-0.1, 0.1) * strength;
        let shape_phase = self.random.range(-1.0, 1.0);
        let resistance =
            0.55 + surface_noise(self.seed, pos.x / 56.0, pos.y / 56.0, 0xA0761D6478BD642F) * 1.9;
        let drift =
            surface_noise(self.seed, pos.x / 105.0, pos.y / 105.0, 0xE7037ED1A0B428DB) * 2.0 - 1.0;
        let trail_width =
            (radius * 0.65 * (0.94 + phase / std::f32::consts::TAU * 0.12) * 1.25).clamp(2.2, 9.0);
        Drop {
            id,
            pos,
            anchor: pos,
            radius,
            velocity: Vec2::default(),
            mass: radius.powi(3),
            age: if fade {
                0.0
            } else {
                self.random.range(0.0, lifetime * 0.7)
            },
            lifetime,
            pinned,
            opacity,
            birth_delay: if fade {
                self.random.range(0.0, 0.35)
            } else {
                0.0
            },
            birth_duration: if fade {
                self.random.range(0.25, 0.45)
            } else {
                0.3
            },
            birth_fade: if fade { 0.0 } else { 1.0 },
            shape_aspect: aspect,
            shape_asymmetry: asymmetry,
            shape_phase,
            trail_width,
            friction,
            resistance,
            drift,
            sample_clock: self.random.range(0.0, 0.1),
        }
    }
    fn pair_hash(a: u64, b: u64) -> u64 {
        let mut v =
            a.min(b).wrapping_mul(0x9E3779B97F4A7C15) ^ a.max(b).wrapping_mul(0xBF58476D1CE4E5B9);
        v = (v ^ (v >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        v = (v ^ (v >> 27)).wrapping_mul(0x94D049BB133111EB);
        v ^ (v >> 31)
    }
    fn merge_collisions(&mut self) {
        self.bridges.clear();
        let mut cells: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
        for (i, d) in self.drops.iter().enumerate() {
            if d.birth_delay <= 0.0 && d.birth_fade >= 0.5 {
                cells
                    .entry((
                        (d.pos.x / 32.0).floor() as i32,
                        (d.pos.y / 32.0).floor() as i32,
                    ))
                    .or_default()
                    .push(i);
            }
        }
        let mut consumed = vec![false; self.drops.len()];
        let mut degree = vec![0u8; self.drops.len()];
        let maximum_radius = self.drops.iter().map(|d| d.radius).fold(0.0, f32::max);
        for i in 0..self.drops.len() {
            if consumed[i] || self.drops[i].birth_delay > 0.0 || self.drops[i].birth_fade < 0.5 {
                continue;
            }
            let p = self.drops[i].pos;
            let cx = (p.x / 32.0).floor() as i32;
            let cy = (p.y / 32.0).floor() as i32;
            let reach =
                ((1.6 * (self.drops[i].radius + maximum_radius) / 32.0).ceil() as i32).max(1);
            'neighbors: for y in cy - reach..=cy + reach {
                for x in cx - reach..=cx + reach {
                    if let Some(candidates) = cells.get(&(x, y)) {
                        for &j in candidates {
                            if j <= i || consumed[j] {
                                continue;
                            }
                            let a = &self.drops[i];
                            let b = &self.drops[j];
                            let distance = a.pos.distance(b.pos);
                            let combined = a.radius + b.radius;
                            if a.pinned
                                && b.pinned
                                && distance >= combined * 0.68
                                && distance < combined * 1.2
                                && a.radius.min(b.radius) / a.radius.max(b.radius) >= 0.62
                                && Self::pair_hash(a.id, b.id) % 2 == 0
                                && degree[i] < 2
                                && degree[j] < 2
                                && self.bridges.len() < 280
                            {
                                self.bridges.push(Bridge {
                                    first_id: a.id,
                                    second_id: b.id,
                                    start: a.pos,
                                    end: b.pos,
                                    width: (a.radius.min(b.radius) * 0.18).clamp(1.0, 2.0),
                                });
                                degree[i] += 1;
                                degree[j] += 1;
                                continue;
                            }
                            if distance >= (a.radius + b.radius) * 0.82 {
                                continue;
                            }
                            let survivor = if a.pinned != b.pinned {
                                if a.pinned {
                                    j
                                } else {
                                    i
                                }
                            } else if a.pinned {
                                if a.radius >= b.radius {
                                    i
                                } else {
                                    j
                                }
                            } else if a.pos.y >= b.pos.y {
                                i
                            } else {
                                j
                            };
                            let loser = if survivor == i { j } else { i };
                            let mass = a.mass + b.mass;
                            let vy =
                                ((a.velocity.y * a.mass + b.velocity.y * b.mass) / mass).max(0.0);
                            let vx = (a.velocity.x * a.mass + b.velocity.x * b.mass) / mass;
                            let friction = (a.friction * a.mass + b.friction * b.mass) / mass;
                            let pinned = a.pinned && b.pinned && mass.cbrt() < 4.8;
                            let life = a.lifetime.max(b.lifetime);
                            let s = &mut self.drops[survivor];
                            s.mass = mass;
                            s.radius = mass.cbrt();
                            s.velocity = Vec2 { x: vx, y: vy };
                            s.friction = friction;
                            s.pinned = pinned;
                            s.lifetime = life;
                            consumed[loser] = true;
                            if loser == i {
                                break 'neighbors;
                            }
                        }
                    }
                }
            }
        }
        let mut index = 0;
        self.drops.retain(|_| {
            let keep = !consumed[index];
            index += 1;
            keep
        });
        self.bridges.retain(|b| {
            self.drops.iter().any(|d| d.id == b.first_id)
                && self.drops.iter().any(|d| d.id == b.second_id)
        });
    }
}

fn trail_width(d: &Drop) -> f32 {
    (d.radius * 0.65 * (1.25 - (d.velocity.y / 95.0).min(1.0) * 0.4)).clamp(2.2, 9.0)
}

fn surface_noise(seed: u64, x: f32, y: f32, salt: u64) -> f32 {
    fn sample(seed: u64, x: i32, y: i32, salt: u64) -> f32 {
        let mut v = seed
            ^ salt
            ^ (x as i64 as u64).wrapping_mul(0x9E3779B97F4A7C15)
            ^ (y as i64 as u64).wrapping_mul(0xBF58476D1CE4E5B9);
        v = (v ^ (v >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        v = (v ^ (v >> 27)).wrapping_mul(0x94D049BB133111EB);
        ((v ^ (v >> 31)) >> 40) as f32 / 16_777_216.0
    }
    let ix = x.floor() as i32;
    let iy = y.floor() as i32;
    let fx = x - ix as f32;
    let fy = y - iy as f32;
    let fx = fx * fx * (3.0 - 2.0 * fx);
    let fy = fy * fy * (3.0 - 2.0 * fy);
    let top = sample(seed, ix, iy, salt) * (1.0 - fx) + sample(seed, ix + 1, iy, salt) * fx;
    let bottom =
        sample(seed, ix, iy + 1, salt) * (1.0 - fx) + sample(seed, ix + 1, iy + 1, salt) * fx;
    top * (1.0 - fy) + bottom * fy
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn consumed_drop_cannot_merge_again_in_another_cell() {
        let mut sim = Simulation::new(1, 1920.0, 1080.0);
        sim.drops.truncate(3);
        for (drop, pos) in sim.drops.iter_mut().zip([
            Vec2 { x: 31.0, y: 31.0 },
            Vec2 { x: 32.0, y: 32.0 },
            Vec2 { x: 31.0, y: 46.0 },
        ]) {
            drop.pos = pos;
            drop.radius = 10.0;
            drop.mass = 1000.0;
            drop.pinned = false;
            drop.birth_delay = 0.0;
            drop.birth_fade = 1.0;
        }
        sim.merge_collisions();
        assert!((sim.drops.iter().map(|d| d.mass).sum::<f32>() - 3000.0).abs() < 0.01);
    }
    #[test]
    fn seeded_runs_match_and_stay_bounded() {
        let mut a = Simulation::new(42, 1920.0, 1080.0);
        let mut b = Simulation::new(42, 1920.0, 1080.0);
        // These five values are from Swift RainSimulation(seed: 42) at 1920×1080.
        let swift = [
            (660.84607, 41.07256, 1.0718477, true),
            (951.3574, 100.90181, 1.1458397, false),
            (1613.7916, 698.8622, 1.9801018, false),
            (617.0713, 91.24032, 2.1171312, true),
            (61.93966, 279.8794, 1.7451404, true),
        ];
        for (drop, (x, y, r, pinned)) in a.drops.iter().zip(swift) {
            assert!((drop.pos.x - x).abs() < 0.0001);
            assert!((drop.pos.y - y).abs() < 0.0001);
            assert!((drop.radius - r).abs() < 0.0001);
            assert_eq!(drop.pinned, pinned);
        }
        for _ in 0..240 {
            a.step(1.0 / 60.0);
            b.step(1.0 / 60.0);
        }
        assert_eq!(a.drops.len(), b.drops.len());
        assert!(a.drops.len() <= Simulation::MAX_DROPS);
        assert!(a.trails.len() <= Simulation::MAX_TRAILS);
        for (x, y) in a.drops.iter().zip(b.drops.iter()) {
            assert_eq!((x.id, x.pos, x.radius), (y.id, y.pos, y.radius));
            assert!(x.velocity.y >= 0.0);
        }
    }
    #[test]
    fn resize_preserves_existing_drop_ids() {
        let mut s = Simulation::new(2, 100.0, 100.0);
        let id = s.drops[0].id;
        s.resize(200.0, 200.0);
        assert_eq!(s.drops[0].id, id);
    }
}
