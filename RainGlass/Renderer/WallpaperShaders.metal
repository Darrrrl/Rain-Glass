#include <metal_stdlib>
using namespace metal;

struct FullscreenVertex {
    float4 position [[position]];
};

struct WallpaperUniforms {
    float2 viewportSize;
    float2 imageSize;
    uint scaleMode;
};

vertex FullscreenVertex fullscreenVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    FullscreenVertex out;
    out.position = float4(positions[vertexID], 0, 1);
    return out;
}

fragment float4 wallpaperFragment(
    FullscreenVertex in [[stage_in]],
    texture2d<float> wallpaper [[texture(0)]],
    sampler imageSampler [[sampler(0)]],
    constant WallpaperUniforms& uniforms [[buffer(0)]]
) {
    float2 screenUV = in.position.xy / uniforms.viewportSize;
    float2 imageUV = screenUV;
    if (uniforms.scaleMode != 2) {
        float2 scaleRatio = uniforms.viewportSize / uniforms.imageSize;
        float scale = uniforms.scaleMode == 0 ? max(scaleRatio.x, scaleRatio.y) : min(scaleRatio.x, scaleRatio.y);
        float2 displayedSize = uniforms.imageSize * scale;
        imageUV = (in.position.xy - (uniforms.viewportSize - displayedSize) * 0.5) / displayedSize;
    }
    if (any(imageUV < 0) || any(imageUV > 1)) {
        return float4(0.045, 0.055, 0.075, 1);
    }
    return wallpaper.sample(imageSampler, imageUV);
}

fragment float4 displayBackgroundFragment(
    FullscreenVertex in [[stage_in]],
    texture2d<float> background [[texture(0)]],
    sampler imageSampler [[sampler(0)]],
    constant float2& viewportSize [[buffer(0)]]
) {
    return background.sample(imageSampler, in.position.xy / viewportSize);
}
