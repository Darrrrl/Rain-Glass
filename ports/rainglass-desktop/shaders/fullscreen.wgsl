struct VertexOut { @builtin(position) position: vec4<f32> };
@vertex fn fullscreen(@builtin(vertex_index) index: u32) -> VertexOut {
    var corners = array<vec2<f32>, 3>(vec2<f32>(-1.0,-1.0),vec2<f32>(3.0,-1.0),vec2<f32>(-1.0,3.0));
    var out: VertexOut;
    out.position = vec4<f32>(corners[index],0.0,1.0);
    return out;
}
