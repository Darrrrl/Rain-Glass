use crate::mask::WaterMask;
use bytemuck::{Pod, Zeroable};
use rainglass_core::settings::{AppSettings, FitMode, FrameLayout};
use rainglass_core::simulation::Simulation;
use std::path::Path;
use wgpu::util::DeviceExt;

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct WallpaperUniform {
    viewport: [f32; 2],
    image: [f32; 2],
    fit: u32,
    zoom: f32,
    pad: [f32; 2],
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct BlurUniform {
    step: [f32; 2],
    output: [f32; 2],
    sigma: f32,
    pad: [f32; 3],
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct CompositeUniform {
    viewport: [f32; 2],
    refraction: f32,
    blur_enabled: f32,
    condensation: f32,
    haze: f32,
    imperfections: f32,
    fog_softness: f32,
    frame: [f32; 4],
}

fn texture(
    device: &wgpu::Device,
    label: &str,
    width: u32,
    height: u32,
    format: wgpu::TextureFormat,
) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::TEXTURE_BINDING
            | wgpu::TextureUsages::RENDER_ATTACHMENT
            | wgpu::TextureUsages::COPY_DST
            | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    })
}

fn uniform<T: Pod>(device: &wgpu::Device, label: &str, value: &T) -> wgpu::Buffer {
    device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some(label),
        contents: bytemuck::bytes_of(value),
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
    })
}

fn bind_layout(device: &wgpu::Device, label: &str, textures: usize) -> wgpu::BindGroupLayout {
    let mut entries = Vec::new();
    for i in 0..textures {
        entries.push(wgpu::BindGroupLayoutEntry {
            binding: i as u32,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                multisampled: false,
                view_dimension: wgpu::TextureViewDimension::D2,
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
            },
            count: None,
        });
    }
    entries.push(wgpu::BindGroupLayoutEntry {
        binding: textures as u32,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
        count: None,
    });
    entries.push(wgpu::BindGroupLayoutEntry {
        binding: textures as u32 + 1,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    });
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some(label),
        entries: &entries,
    })
}

fn bind(
    device: &wgpu::Device,
    layout: &wgpu::BindGroupLayout,
    label: &str,
    views: &[&wgpu::TextureView],
    sampler: &wgpu::Sampler,
    buffer: &wgpu::Buffer,
) -> wgpu::BindGroup {
    let mut entries = Vec::new();
    for (i, view) in views.iter().enumerate() {
        entries.push(wgpu::BindGroupEntry {
            binding: i as u32,
            resource: wgpu::BindingResource::TextureView(view),
        });
    }
    entries.push(wgpu::BindGroupEntry {
        binding: views.len() as u32,
        resource: wgpu::BindingResource::Sampler(sampler),
    });
    entries.push(wgpu::BindGroupEntry {
        binding: views.len() as u32 + 1,
        resource: buffer.as_entire_binding(),
    });
    device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some(label),
        layout,
        entries: &entries,
    })
}

fn pipeline(
    device: &wgpu::Device,
    shader: &wgpu::ShaderModule,
    layouts: &[&wgpu::BindGroupLayout],
    label: &str,
    entry: &str,
    format: wgpu::TextureFormat,
) -> wgpu::RenderPipeline {
    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some(label),
        bind_group_layouts: layouts,
        push_constant_ranges: &[],
    });
    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some(label),
        layout: Some(&pipeline_layout),
        vertex: wgpu::VertexState {
            module: shader,
            entry_point: Some("fullscreen"),
            buffers: &[],
            compilation_options: Default::default(),
        },
        fragment: Some(wgpu::FragmentState {
            module: shader,
            entry_point: Some(entry),
            targets: &[Some(wgpu::ColorTargetState {
                format,
                blend: None,
                write_mask: wgpu::ColorWrites::ALL,
            })],
            compilation_options: Default::default(),
        }),
        primitive: wgpu::PrimitiveState::default(),
        depth_stencil: None,
        multisample: wgpu::MultisampleState::default(),
        multiview: None,
        cache: None,
    })
}

pub struct SceneRenderer {
    _wallpaper: wgpu::Texture,
    wallpaper_view: wgpu::TextureView,
    image_size: [u32; 2],
    sampler: wgpu::Sampler,
    wallpaper_layout: wgpu::BindGroupLayout,
    blur_layout: wgpu::BindGroupLayout,
    composite_layout: wgpu::BindGroupLayout,
    wallpaper_pipeline: wgpu::RenderPipeline,
    blur_pipeline: wgpu::RenderPipeline,
    composite_pipeline: wgpu::RenderPipeline,
    sharp: wgpu::Texture,
    blurred_x: wgpu::Texture,
    blurred_y: wgpu::Texture,
    mask_texture: wgpu::Texture,
    mask: WaterMask,
    viewport: [u32; 2],
    output_size: [u32; 2],
    blur_size: [u32; 2],
    wallpaper_uniform: wgpu::Buffer,
    blur_x_uniform: wgpu::Buffer,
    blur_y_uniform: wgpu::Buffer,
    composite_uniform: wgpu::Buffer,
}

impl SceneRenderer {
    pub fn load(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        surface_format: wgpu::TextureFormat,
        path: &Path,
        output_size: [u32; 2],
        render_scale: f32,
    ) -> Result<Self, String> {
        let image = image::open(path)
            .map_err(|e| format!("Cannot open wallpaper: {e}"))?
            .to_rgba8();
        let (iw, ih) = image.dimensions();
        if iw == 0 || ih == 0 || iw > 16384 || ih > 16384 {
            return Err("Unsupported wallpaper size".into());
        }
        let wallpaper = texture(
            device,
            "Wallpaper sRGB",
            iw,
            ih,
            wgpu::TextureFormat::Rgba8UnormSrgb,
        );
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &wallpaper,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            image.as_raw(),
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(iw * 4),
                rows_per_image: Some(ih),
            },
            wgpu::Extent3d {
                width: iw,
                height: ih,
                depth_or_array_layers: 1,
            },
        );
        let wallpaper_view = wallpaper.create_view(&Default::default());
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("Scene linear clamp"),
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("RainGlass scene"),
            source: wgpu::ShaderSource::Wgsl(include_str!("../shaders/scene.wgsl").into()),
        });
        let wallpaper_layout = bind_layout(device, "Wallpaper layout", 1);
        let blur_layout = bind_layout(device, "Blur layout", 1);
        let composite_layout = bind_layout(device, "Composite layout", 3);
        let layouts = [&wallpaper_layout, &blur_layout, &composite_layout];
        let wallpaper_pipeline = pipeline(
            device,
            &shader,
            &layouts,
            "Wallpaper pass",
            "wallpaper_frag",
            wgpu::TextureFormat::Rgba16Float,
        );
        let blur_pipeline = pipeline(
            device,
            &shader,
            &layouts,
            "Linear Gaussian blur",
            "blur_frag",
            wgpu::TextureFormat::Rgba16Float,
        );
        let composite_pipeline = pipeline(
            device,
            &shader,
            &layouts,
            "Wet glass composite",
            "composite_frag",
            surface_format,
        );
        let output_size = [output_size[0].max(1), output_size[1].max(1)];
        let viewport = scaled(output_size, render_scale);
        let sharp = texture(
            device,
            "Sharp scene",
            viewport[0],
            viewport[1],
            wgpu::TextureFormat::Rgba16Float,
        );
        let blurred_x = texture(
            device,
            "Blur horizontal",
            viewport[0],
            viewport[1],
            wgpu::TextureFormat::Rgba16Float,
        );
        let blurred_y = texture(
            device,
            "Blur vertical",
            viewport[0],
            viewport[1],
            wgpu::TextureFormat::Rgba16Float,
        );
        let mask = WaterMask::new((viewport[0] / 2).max(1), (viewport[1] / 2).max(1));
        let mask_texture = texture(
            device,
            "Water and fog",
            mask.width,
            mask.height,
            wgpu::TextureFormat::Rgba8Unorm,
        );
        let wallpaper_uniform = uniform(
            device,
            "Wallpaper uniforms",
            &WallpaperUniform {
                viewport: [viewport[0] as f32, viewport[1] as f32],
                image: [iw as f32, ih as f32],
                fit: 0,
                zoom: 1.0,
                pad: [0.0; 2],
            },
        );
        let blur_x_uniform = uniform(
            device,
            "Horizontal blur uniforms",
            &BlurUniform {
                step: [1.0 / viewport[0] as f32, 0.0],
                output: [viewport[0] as f32, viewport[1] as f32],
                sigma: 0.0,
                pad: [0.0; 3],
            },
        );
        let blur_y_uniform = uniform(
            device,
            "Vertical blur uniforms",
            &BlurUniform {
                step: [0.0, 1.0 / viewport[1] as f32],
                output: [viewport[0] as f32, viewport[1] as f32],
                sigma: 0.0,
                pad: [0.0; 3],
            },
        );
        let composite_uniform = uniform(
            device,
            "Composite uniforms",
            &CompositeUniform {
                viewport: [viewport[0] as f32, viewport[1] as f32],
                refraction: 0.65,
                blur_enabled: 1.0,
                condensation: 0.45,
                haze: 0.0,
                imperfections: 0.0,
                fog_softness: 0.65,
                frame: [0.0; 4],
            },
        );
        Ok(Self {
            _wallpaper: wallpaper,
            wallpaper_view,
            image_size: [iw, ih],
            sampler,
            wallpaper_layout,
            blur_layout,
            composite_layout,
            wallpaper_pipeline,
            blur_pipeline,
            composite_pipeline,
            sharp,
            blurred_x,
            blurred_y,
            mask_texture,
            mask,
            viewport,
            output_size,
            blur_size: viewport,
            wallpaper_uniform,
            blur_x_uniform,
            blur_y_uniform,
            composite_uniform,
        })
    }

    pub fn resize(&mut self, device: &wgpu::Device, output_size: [u32; 2], render_scale: f32) {
        self.output_size = [output_size[0].max(1), output_size[1].max(1)];
        let viewport = scaled(self.output_size, render_scale);
        if viewport == self.viewport {
            return;
        }
        self.viewport = viewport;
        self.sharp = texture(
            device,
            "Sharp scene",
            viewport[0],
            viewport[1],
            wgpu::TextureFormat::Rgba16Float,
        );
        self.blurred_x = texture(
            device,
            "Blur horizontal",
            viewport[0],
            viewport[1],
            wgpu::TextureFormat::Rgba16Float,
        );
        self.blurred_y = texture(
            device,
            "Blur vertical",
            viewport[0],
            viewport[1],
            wgpu::TextureFormat::Rgba16Float,
        );
        self.blur_size = viewport;
        self.mask = WaterMask::new((viewport[0] / 2).max(1), (viewport[1] / 2).max(1));
        self.mask_texture = texture(
            device,
            "Water and fog",
            self.mask.width,
            self.mask.height,
            wgpu::TextureFormat::Rgba8Unorm,
        );
    }

    pub fn render(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        target: &wgpu::TextureView,
        sim: &Simulation,
        settings: &AppSettings,
        dt: f32,
    ) {
        let [width, height] = self.viewport;
        let blur = sim.parameters.blur as f32;
        let scale = if blur > 24.0 {
            8
        } else if blur > 12.0 {
            4
        } else if blur > 5.0 {
            2
        } else {
            1
        };
        let blur_size = [(width / scale).max(1), (height / scale).max(1)];
        if blur_size != self.blur_size {
            self.blur_size = blur_size;
            self.blurred_x = texture(
                device,
                "Blur horizontal",
                blur_size[0],
                blur_size[1],
                wgpu::TextureFormat::Rgba16Float,
            );
            self.blurred_y = texture(
                device,
                "Blur vertical",
                blur_size[0],
                blur_size[1],
                wgpu::TextureFormat::Rgba16Float,
            );
        }
        let fit = match settings.fit {
            FitMode::Fill => 0,
            FitMode::Fit => 1,
            FitMode::Stretch => 2,
        };
        queue.write_buffer(
            &self.wallpaper_uniform,
            0,
            bytemuck::bytes_of(&WallpaperUniform {
                viewport: [width as f32, height as f32],
                image: [self.image_size[0] as f32, self.image_size[1] as f32],
                fit,
                zoom: settings.zoom.clamp(1.0, 3.0),
                pad: [0.0; 2],
            }),
        );
        let sigma = (blur / scale as f32).clamp(0.0, 8.0);
        let output = [blur_size[0] as f32, blur_size[1] as f32];
        queue.write_buffer(
            &self.blur_x_uniform,
            0,
            bytemuck::bytes_of(&BlurUniform {
                step: [1.0 / output[0], 0.0],
                output,
                sigma,
                pad: [0.0; 3],
            }),
        );
        queue.write_buffer(
            &self.blur_y_uniform,
            0,
            bytemuck::bytes_of(&BlurUniform {
                step: [0.0, 1.0 / output[1]],
                output,
                sigma,
                pad: [0.0; 3],
            }),
        );
        let frame = match settings.frame.layout {
            FrameLayout::Off => [0.0, 0.0, 0.0, 0.0],
            FrameLayout::Two => [2.0, 1.0, settings.frame.thickness as f32, 1.0],
            FrameLayout::Four => [2.0, 2.0, settings.frame.thickness as f32, 1.0],
            FrameLayout::Six => [3.0, 2.0, settings.frame.thickness as f32, 1.0],
        };
        queue.write_buffer(
            &self.composite_uniform,
            0,
            bytemuck::bytes_of(&CompositeUniform {
                viewport: [self.output_size[0] as f32, self.output_size[1] as f32],
                refraction: sim.parameters.refraction as f32,
                blur_enabled: if blur > 0.0 { 1.0 } else { 0.0 },
                condensation: settings.atmosphere.condensation as f32,
                haze: settings.atmosphere.haze as f32,
                imperfections: settings.atmosphere.imperfections as f32,
                fog_softness: settings.atmosphere.fog_softness as f32,
                frame,
            }),
        );
        self.mask
            .update(sim, dt, settings.atmosphere.fog_return_time as f32);
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &self.mask_texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &self.mask.bytes,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(self.mask.width * 4),
                rows_per_image: Some(self.mask.height),
            },
            wgpu::Extent3d {
                width: self.mask.width,
                height: self.mask.height,
                depth_or_array_layers: 1,
            },
        );
        let sharp = self.sharp.create_view(&Default::default());
        let bx = self.blurred_x.create_view(&Default::default());
        let by = self.blurred_y.create_view(&Default::default());
        let mask = self.mask_texture.create_view(&Default::default());
        let wallpaper_bind = bind(
            device,
            &self.wallpaper_layout,
            "Wallpaper",
            &[&self.wallpaper_view],
            &self.sampler,
            &self.wallpaper_uniform,
        );
        let blur_x_bind = bind(
            device,
            &self.blur_layout,
            "Horizontal blur",
            &[&sharp],
            &self.sampler,
            &self.blur_x_uniform,
        );
        let blur_y_bind = bind(
            device,
            &self.blur_layout,
            "Vertical blur",
            &[&bx],
            &self.sampler,
            &self.blur_y_uniform,
        );
        let compose_bind = bind(
            device,
            &self.composite_layout,
            "Wet glass",
            &[&sharp, &by, &mask],
            &self.sampler,
            &self.composite_uniform,
        );
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("RainGlass frame"),
        });
        draw(
            &mut encoder,
            &sharp,
            &self.wallpaper_pipeline,
            &wallpaper_bind,
            0,
        );
        draw(&mut encoder, &bx, &self.blur_pipeline, &blur_x_bind, 1);
        draw(&mut encoder, &by, &self.blur_pipeline, &blur_y_bind, 1);
        draw(
            &mut encoder,
            target,
            &self.composite_pipeline,
            &compose_bind,
            2,
        );
        queue.submit([encoder.finish()]);
    }
}

fn scaled(output: [u32; 2], scale: f32) -> [u32; 2] {
    let scale = scale.clamp(0.4, 1.0);
    [
        ((output[0] as f32 * scale).round() as u32).max(1),
        ((output[1] as f32 * scale).round() as u32).max(1),
    ]
}

fn draw(
    encoder: &mut wgpu::CommandEncoder,
    target: &wgpu::TextureView,
    pipeline: &wgpu::RenderPipeline,
    bind: &wgpu::BindGroup,
    group: u32,
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("Scene pass"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: target,
            resolve_target: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                store: wgpu::StoreOp::Store,
            },
        })],
        depth_stencil_attachment: None,
        occlusion_query_set: None,
        timestamp_writes: None,
    });
    pass.set_pipeline(pipeline);
    pass.set_bind_group(group, bind, &[]);
    pass.draw(0..3, 0..1);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn blur_preserves_blue_channel() {
        let instance = wgpu::Instance::default();
        let Some(adapter) =
            pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions::default()))
        else {
            return;
        };
        let (device, queue) =
            pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default(), None))
                .unwrap();
        let path = std::env::temp_dir().join(format!("rainglass-blue-{}.png", std::process::id()));
        image::RgbaImage::from_pixel(64, 64, image::Rgba([12, 40, 230, 255]))
            .save(&path)
            .unwrap();
        let target = texture(
            &device,
            "Test target",
            64,
            64,
            wgpu::TextureFormat::Rgba8UnormSrgb,
        );
        let view = target.create_view(&Default::default());
        let mut renderer = SceneRenderer::load(
            &device,
            &queue,
            wgpu::TextureFormat::Rgba8UnormSrgb,
            &path,
            [64, 64],
            1.0,
        )
        .unwrap();
        let mut sim = Simulation::new(42, 64.0, 64.0);
        let mut settings = AppSettings::default();
        settings.rain.blur = 16.0;
        settings.rain.drop_count = 0.0;
        settings.atmosphere.condensation = 0.0;
        sim.set_parameters(settings.rain);
        for _ in 0..120 {
            sim.step(1.0 / 60.0);
        }
        renderer.render(&device, &queue, &view, &sim, &settings, 1.0 / 60.0);
        let readback = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("Blue output"),
            size: 64 * 64 * 4,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder =
            device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &target,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(256),
                    rows_per_image: Some(64),
                },
            },
            wgpu::Extent3d {
                width: 64,
                height: 64,
                depth_or_array_layers: 1,
            },
        );
        queue.submit([encoder.finish()]);
        let (tx, rx) = std::sync::mpsc::channel();
        readback
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                let _ = tx.send(result);
            });
        device.poll(wgpu::Maintain::Wait);
        rx.recv().unwrap().unwrap();
        let bytes = readback.slice(..).get_mapped_range();
        let center = (32 * 64 + 32) * 4;
        assert!(
            bytes[center + 2] > bytes[center] * 3,
            "blurred blue wallpaper changed hue: {:?}",
            &bytes[center..center + 4]
        );
        let _ = std::fs::remove_file(path);
    }
}
