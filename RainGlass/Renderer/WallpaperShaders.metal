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

struct DropletInstance {
    float4 geometry;
    float4 appearance;
};

struct DropletVertex {
    float4 position [[position]];
    float2 local;
    float opacity;
    float phase;
};

vertex DropletVertex dropletVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant DropletInstance* droplets [[buffer(0)]],
    constant float2& viewportPoints [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    DropletInstance drop = droplets[instanceID];
    float2 local = corners[vertexID];
    float2 point = drop.geometry.xy + local * drop.geometry.z * float2(1, drop.geometry.w);
    DropletVertex out;
    out.position = float4(point.x / viewportPoints.x * 2 - 1, 1 - point.y / viewportPoints.y * 2, 0, 1);
    out.local = local;
    out.opacity = drop.appearance.x;
    out.phase = drop.appearance.y;
    return out;
}

fragment float4 dropletFragment(DropletVertex in [[stage_in]]) {
    float2 p = in.local;
    float distance = length(p);
    if (distance >= 1) { discard_fragment(); }

    float edge = smoothstep(0.68, 0.98, distance);
    float upperGlint = exp(-dot((p - float2(-0.36, -0.43)) * float2(2.4, 3.8),
                                (p - float2(-0.36, -0.43)) * float2(2.4, 3.8)) * 2.1);
    float lowerGlint = exp(-dot((p - float2(0.27, 0.73)) * float2(2.5, 9.0),
                                (p - float2(0.27, 0.73)) * float2(2.5, 9.0)) * 1.5);
    float darkRim = edge * (0.45 + 0.25 * p.y);
    float light = saturate(upperGlint * 0.8 + lowerGlint * 0.5);
    float alpha = in.opacity * (0.09 + darkRim * 0.44 + light * 0.63);
    alpha *= 1 - smoothstep(0.97, 1.0, distance);
    float3 color = mix(float3(0.025, 0.035, 0.05), float3(0.96, 0.98, 1.0), light);
    return float4(color, saturate(alpha));
}

struct TrailVertex {
    float4 position [[position]];
    float2 local;
    float opacity;
};

vertex TrailVertex trailVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant DropletInstance* trails [[buffer(0)]],
    constant float2& viewportPoints [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    DropletInstance trail = trails[instanceID];
    float2 start = trail.geometry.xy;
    float2 end = trail.geometry.zw;
    float2 tangent = normalize(end - start + float2(0.0001, 0));
    float2 normal = float2(-tangent.y, tangent.x);
    float2 local = corners[vertexID];
    float2 point = mix(start, end, (local.y + 1) * 0.5) + normal * local.x * trail.appearance.x;
    TrailVertex out;
    out.position = float4(point.x / viewportPoints.x * 2 - 1, 1 - point.y / viewportPoints.y * 2, 0, 1);
    out.local = local;
    out.opacity = trail.appearance.y;
    return out;
}

fragment float4 trailFragment(TrailVertex in [[stage_in]]) {
    float ridge = 1 - smoothstep(0.35, 1, abs(in.local.x));
    float rim = smoothstep(0.65, 1, abs(in.local.x));
    float alpha = in.opacity * (ridge * 0.10 + rim * 0.16);
    float3 color = mix(float3(0.95), float3(0.025, 0.035, 0.05), rim);
    return float4(color, alpha);
}
