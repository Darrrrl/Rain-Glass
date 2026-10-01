use std::time::Instant;

pub struct FrameStats {
    started: Instant,
    last_report: Instant,
    frames: u64,
    simulation_ms: f64,
    mask_ms: f64,
    encode_ms: f64,
    present_ms: f64,
    max_frame_ms: f64,
    gpu_ms: Option<f64>,
    enabled: bool,
}

impl FrameStats {
    pub fn new() -> Self {
        let now = Instant::now();
        Self {
            started: now,
            last_report: now,
            frames: 0,
            simulation_ms: 0.0,
            mask_ms: 0.0,
            encode_ms: 0.0,
            present_ms: 0.0,
            max_frame_ms: 0.0,
            gpu_ms: None,
            enabled: std::env::var_os("RAINGLASS_DIAGNOSTICS").is_some(),
        }
    }

    pub fn record(
        &mut self,
        simulation_ms: f64,
        render: crate::renderer::RenderTimings,
        present_ms: f64,
        total_ms: f64,
    ) {
        if !self.enabled {
            return;
        }
        self.frames += 1;
        self.simulation_ms += simulation_ms;
        self.mask_ms += render.mask_ms;
        self.encode_ms += render.encode_ms;
        self.present_ms += present_ms;
        self.max_frame_ms = self.max_frame_ms.max(total_ms);
        self.gpu_ms = render.gpu_ms.or(self.gpu_ms);
        let now = Instant::now();
        if now.duration_since(self.last_report).as_secs_f64() >= 5.0 {
            let n = self.frames as f64;
            eprintln!("RainGlass profile t={:.1}s: {:.1} FPS, simulation={:.2}ms mask={:.2}ms encode/upload={:.2}ms acquire/present={:.2}ms max_cpu_frame={:.2}ms gpu_sample={:?}ms",
                now.duration_since(self.started).as_secs_f64(), n / now.duration_since(self.last_report).as_secs_f64(),
                self.simulation_ms / n, self.mask_ms / n, self.encode_ms / n, self.present_ms / n, self.max_frame_ms, self.gpu_ms);
            self.last_report = now;
            self.frames = 0;
            self.simulation_ms = 0.0;
            self.mask_ms = 0.0;
            self.encode_ms = 0.0;
            self.present_ms = 0.0;
            self.max_frame_ms = 0.0;
        }
    }
}

pub fn timestamp_features(adapter: &wgpu::Adapter) -> wgpu::Features {
    let features =
        wgpu::Features::TIMESTAMP_QUERY | wgpu::Features::TIMESTAMP_QUERY_INSIDE_ENCODERS;
    if adapter.features().contains(features) {
        features
    } else {
        wgpu::Features::empty()
    }
}

pub struct GpuTimer {
    pub queries: wgpu::QuerySet,
    resolve: wgpu::Buffer,
    readback: wgpu::Buffer,
    pending: Option<std::sync::mpsc::Receiver<Result<(), wgpu::BufferAsyncError>>>,
    pub last_ms: Option<f64>,
    frames: u64,
}

impl GpuTimer {
    pub fn new(device: &wgpu::Device) -> Option<Self> {
        if !device
            .features()
            .contains(wgpu::Features::TIMESTAMP_QUERY_INSIDE_ENCODERS)
        {
            return None;
        }
        Some(Self {
            queries: device.create_query_set(&wgpu::QuerySetDescriptor {
                label: Some("Frame GPU timing"),
                ty: wgpu::QueryType::Timestamp,
                count: 2,
            }),
            resolve: device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("GPU timestamps"),
                size: 256,
                usage: wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC,
                mapped_at_creation: false,
            }),
            readback: device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("GPU timing readback"),
                size: 16,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            }),
            pending: None,
            last_ms: None,
            frames: 0,
        })
    }

    pub fn sample(&mut self, device: &wgpu::Device, queue: &wgpu::Queue) -> bool {
        if let Some(receiver) = &self.pending {
            device.poll(wgpu::Maintain::Poll);
            if let Ok(result) = receiver.try_recv() {
                if result.is_ok() {
                    let data = self.readback.slice(..).get_mapped_range();
                    let start = u64::from_le_bytes(data[0..8].try_into().unwrap());
                    let end = u64::from_le_bytes(data[8..16].try_into().unwrap());
                    self.last_ms = Some(
                        end.saturating_sub(start) as f64 * f64::from(queue.get_timestamp_period())
                            / 1_000_000.0,
                    );
                    drop(data);
                    self.readback.unmap();
                }
                self.pending = None;
            }
        }
        self.frames += 1;
        self.pending.is_none() && self.frames % 60 == 1
    }

    pub fn resolve(&self, encoder: &mut wgpu::CommandEncoder) {
        encoder.resolve_query_set(&self.queries, 0..2, &self.resolve, 0);
        encoder.copy_buffer_to_buffer(&self.resolve, 0, &self.readback, 0, 16);
    }

    pub fn read(&mut self) {
        let (sender, receiver) = std::sync::mpsc::channel();
        self.readback
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                let _ = sender.send(result);
            });
        self.pending = Some(receiver);
    }
}
