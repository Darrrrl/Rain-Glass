struct BlurUniforms {
    texel_step: vec2<f32>,
    output_size: vec2<f32>,
    sigma: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};
@group(0) @binding(0) var blur_source: texture_2d<f32>;
@group(0) @binding(1) var blur_sampler: sampler;
@group(0) @binding(2) var<uniform> blur_uniforms: BlurUniforms;
@fragment fn blur_frag(input: VertexOut) -> @location(0) vec4<f32> {
    let uv = input.position.xy / blur_uniforms.output_size;
    if blur_uniforms.sigma <= 0.01 { return textureSample(blur_source,blur_sampler,uv); }
    var sum = vec4<f32>(0.0);
    var total = 0.0;
    // Separable, normalized Gaussian; all calculations remain in linear light.
    for (var i = -8; i <= 8; i = i + 1) {
        let x = f32(i);
        let weight = exp(-0.5*x*x/(blur_uniforms.sigma*blur_uniforms.sigma));
        sum += textureSample(blur_source,blur_sampler,uv+blur_uniforms.texel_step*x)*weight;
        total += weight;
    }
    return sum / total;
}
