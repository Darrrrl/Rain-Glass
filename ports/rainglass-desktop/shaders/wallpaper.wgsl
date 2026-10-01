struct WallpaperUniforms {
    viewport: vec2<f32>,
    image_size: vec2<f32>,
    fit: u32,
    zoom: f32,
    _pad: vec2<f32>,
};
@group(0) @binding(0) var wallpaper: texture_2d<f32>;
@group(0) @binding(1) var wallpaper_sampler: sampler;
@group(0) @binding(2) var<uniform> wallpaper_uniforms: WallpaperUniforms;

@fragment fn wallpaper_frag(input: VertexOut) -> @location(0) vec4<f32> {
    var uv = (input.position.xy / wallpaper_uniforms.viewport - vec2<f32>(0.5)) / wallpaper_uniforms.zoom + vec2<f32>(0.5);
    if wallpaper_uniforms.fit != 2u {
        let ratio = wallpaper_uniforms.viewport / wallpaper_uniforms.image_size;
        let scale = select(min(ratio.x,ratio.y),max(ratio.x,ratio.y),wallpaper_uniforms.fit == 0u);
        let size = wallpaper_uniforms.image_size * scale * wallpaper_uniforms.zoom;
        uv = (input.position.xy - (wallpaper_uniforms.viewport-size)*0.5) / size;
    }
    if any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0)) {
        return vec4<f32>(0.045,0.055,0.075,1.0);
    }
    // Rgba8UnormSrgb sampling decodes to linear light before this RGBA16Float write.
    let sample = textureSample(wallpaper,wallpaper_sampler,uv);
    let fallback = vec3<f32>(0.045,0.055,0.075);
    return vec4<f32>(mix(fallback,sample.rgb,sample.a),1.0);
}
