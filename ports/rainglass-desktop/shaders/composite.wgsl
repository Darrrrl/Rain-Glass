struct CompositeUniforms {
    viewport: vec2<f32>,
    refraction: f32,
    blur_enabled: f32,
    condensation: f32,
    haze: f32,
    imperfections: f32,
    fog_softness: f32,
    frame: vec4<f32>, // columns, rows, thickness in pixels, enabled
};

@group(0) @binding(0) var sharp: texture_2d<f32>;
@group(0) @binding(1) var blurred: texture_2d<f32>;
@group(0) @binding(2) var water_fog: texture_2d<f32>; // R=water height, G=fog density
@group(0) @binding(3) var scene_sampler: sampler;
@group(0) @binding(4) var<uniform> scene: CompositeUniforms;

fn frame_coverage(point: vec2<f32>) -> f32 {
    if scene.frame.w < 0.5 { return 0.0; }
    let thickness = scene.frame.z;
    let border = min(min(point.x,scene.viewport.x-point.x),min(point.y,scene.viewport.y-point.y));
    var coverage = 1.0-smoothstep(thickness-1.0,thickness+1.0,border);
    for (var col = 1.0; col < scene.frame.x; col += 1.0) {
        let dx = abs(point.x-scene.viewport.x*col/scene.frame.x);
        coverage = max(coverage,1.0-smoothstep(thickness*0.5-1.0,thickness*0.5+1.0,dx));
    }
    for (var row = 1.0; row < scene.frame.y; row += 1.0) {
        let dy = abs(point.y-scene.viewport.y*row/scene.frame.y);
        coverage = max(coverage,1.0-smoothstep(thickness*0.5-1.0,thickness*0.5+1.0,dy));
    }
    return coverage;
}

@fragment fn composite_frag(input: VertexOut) -> @location(0) vec4<f32> {
    let uv = input.position.xy / scene.viewport;
    let mask = textureSample(water_fog,scene_sampler,uv);
    let px = 1.0/vec2<f32>(textureDimensions(water_fog));
    let slope = vec2<f32>(
        textureSample(water_fog,scene_sampler,uv+vec2<f32>(px.x,0.0)).r-textureSample(water_fog,scene_sampler,uv-vec2<f32>(px.x,0.0)).r,
        textureSample(water_fog,scene_sampler,uv+vec2<f32>(0.0,px.y)).r-textureSample(water_fog,scene_sampler,uv-vec2<f32>(0.0,px.y)).r
    );
    let warped = clamp(uv-slope*scene.refraction*0.018,vec2<f32>(0.0),vec2<f32>(1.0));
    let clear_color = textureSample(sharp,scene_sampler,warped).rgb;
    let soft_color = textureSample(blurred,scene_sampler,uv).rgb;
    let focus = clamp(mask.r*1.7,0.0,1.0);
    var color = mix(soft_color,clear_color,select(1.0,focus,scene.blur_enabled>0.5));
    let fog = clamp(scene.condensation*mask.g*(1.0-smoothstep(0.08,0.5,mask.r)),0.0,1.0);
    if fog > 0.001 {
        let spread = scene.fog_softness * 0.008;
        let fogged = (soft_color * 2.0
            + textureSample(blurred,scene_sampler,uv+vec2<f32>(spread,0.0)).rgb
            + textureSample(blurred,scene_sampler,uv-vec2<f32>(spread,0.0)).rgb
            + textureSample(blurred,scene_sampler,uv+vec2<f32>(0.0,spread)).rgb
            + textureSample(blurred,scene_sampler,uv-vec2<f32>(0.0,spread)).rgb) / 6.0;
        color = mix(color,fogged,fog*0.75);
    }
    let luma = dot(color,vec3<f32>(0.2126,0.7152,0.0722));
    color = mix(color,vec3<f32>(luma),fog*0.08);
    color += scene.haze*(mask.g-0.5)*0.025;
    color *= 1.0-smoothstep(0.91,0.995,mask.g)*scene.imperfections*0.02;
    let edge = clamp(length(slope)*0.35,0.0,1.0);
    color = color*(1.0-edge*0.09)+vec3<f32>(0.012)*edge;
    let bar = frame_coverage(input.position.xy);
    color = mix(color,vec3<f32>(0.035,0.041,0.049),bar*0.96);
    return vec4<f32>(color,1.0);
}
