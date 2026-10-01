#include <metal_stdlib>
using namespace metal;

struct FullscreenVertex {
    float4 position [[position]];
};

struct WallpaperUniforms {
    float2 viewportSize;
    float2 imageSize;
    uint scaleMode;
    float zoom;
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
    float2 imageUV = (screenUV - 0.5) / uniforms.zoom + 0.5;
    if (uniforms.scaleMode != 2) {
        float2 scaleRatio = uniforms.viewportSize / uniforms.imageSize;
        float scale = uniforms.scaleMode == 0 ? max(scaleRatio.x, scaleRatio.y) : min(scaleRatio.x, scaleRatio.y);
        float2 displayedSize = uniforms.imageSize * scale * uniforms.zoom;
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
    constant float2& viewportSize [[buffer(0)]],
    constant float& exposureEV [[buffer(1)]]
) {
    float4 color = background.sample(imageSampler, in.position.xy / viewportSize);
    return float4(color.rgb * exp2(exposureEV), 1);
}

struct DropletInstance {
    float4 geometry;
    float4 appearance;
};

struct TrailInstance {
    float4 geometry;
    float4 appearance;
    float4 style;
    float4 dropMask;
};

struct DropletVertex {
    float4 position [[position]];
    float2 local;
    float opacity;
    float4 shape;
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
    float2 point = drop.geometry.xy + local * drop.geometry.z * 1.12 *
        float2(1, drop.appearance.y * drop.geometry.w);
    DropletVertex out;
    out.position = float4(point.x / viewportPoints.x * 2 - 1, 1 - point.y / viewportPoints.y * 2, 0, 1);
    out.local = local * 1.12;
    out.opacity = drop.appearance.x;
    float irregularity = clamp((drop.geometry.z - 2.0) / 6.0, 0.0, 1.0) * 0.05;
    out.shape = float4(drop.appearance.z, irregularity, drop.geometry.w, drop.appearance.w);
    return out;
}

float dropletShapeDistance(float2 p, float4 shape) {
    float asymmetry = shape.x;
    float irregularity = shape.y;
    float stretch = shape.z;
    float variation = shape.w;
    float moving = saturate((stretch - 1.0) * 3.5);
    float upperNeck = 1.0 + (moving * 0.23 + irregularity * 1.1) * p.y;
    float2 warped = float2((p.x + asymmetry * (0.3 - p.y * p.y)) / upperNeck,
                           p.y + irregularity * (p.x * p.x - 0.25));
    return length(warped) + irregularity * p.x * p.y * (p.x + variation * p.y);
}

fragment float4 dropletFragment(DropletVertex in [[stage_in]]) {
    float2 p = in.local;
    float distance = dropletShapeDistance(p, in.shape);
    if (distance >= 1) { discard_fragment(); }

    float edge = smoothstep(0.68, 0.98, distance);
    float upperGlint = exp(-dot((p - float2(-0.38, -0.38)) * float2(2.8, 4.5),
                                (p - float2(-0.38, -0.38)) * float2(2.8, 4.5)) * 2.4);
    float darkRim = edge * (0.45 + 0.2 * p.y);
    float light = upperGlint * 0.55;
    float alpha = in.opacity * (0.025 + darkRim * 0.18 + light * 0.17);
    alpha *= 1 - smoothstep(0.97, 1.0, distance);
    float3 color = mix(float3(0.025, 0.035, 0.05), float3(0.96, 0.98, 1.0), light);
    return float4(color, saturate(alpha));
}

struct SplatInstance {
    float4 geometry;   // center, drawing radius, normalized age
    float4 appearance; // fade, drop radius, variation, unused
};

struct SplatVertexOut {
    float4 position [[position]];
    float2 local;
    float progress;
    float fade;
    float variation;
};

vertex SplatVertexOut splatVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant SplatInstance* splats [[buffer(0)]],
    constant float2& viewportPoints [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    SplatInstance splat = splats[instanceID];
    float2 local = corners[vertexID];
    float2 point = splat.geometry.xy + local * splat.geometry.z;
    SplatVertexOut out;
    out.position = float4(point.x / viewportPoints.x * 2 - 1,
                          1 - point.y / viewportPoints.y * 2, 0, 1);
    out.local = local;
    out.progress = splat.geometry.w;
    out.fade = splat.appearance.x;
    out.variation = splat.appearance.z;
    return out;
}

fragment float4 splatFragment(SplatVertexOut in [[stage_in]]) {
    float distance = length(in.local);
    float ringRadius = mix(0.28, 0.77, in.progress);
    float ring = 1 - smoothstep(0.025, 0.09, abs(distance - ringRadius));
    const float2 directions[4] = {
        float2(1, 0.12), float2(-0.72, 0.66),
        float2(0.34, -0.93), float2(-0.37, -0.8)
    };
    float satellites = 0;
    for (uint i = 0; i < 4; ++i) {
        float angle = (in.variation - 0.5) * 0.55 + float(i) * 0.13;
        float2 direction = float2(directions[i].x * cos(angle) - directions[i].y * sin(angle),
                                  directions[i].x * sin(angle) + directions[i].y * cos(angle));
        float2 center = direction * (0.4 + in.progress * (0.27 + float(i) * 0.035));
        satellites = max(satellites, 1 - smoothstep(0.035, 0.13, length(in.local - center)));
    }
    float alpha = in.fade * (ring * 0.2 + satellites * 0.19);
    return float4(0.84, 0.93, 0.98, saturate(alpha));
}

struct TrailVertex {
    float4 position [[position]];
    float2 local;
    float2 glassPosition;
    float4 dropMask;
    float opacity;
    float2 endpointWidths;
    float segmentLength;
    float style;
    float remaining;
};

vertex TrailVertex trailVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant TrailInstance* trails [[buffer(0)]],
    constant float2& viewportPoints [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1, 1), float2(1, -1), float2(1, 1)
    };
    TrailInstance trail = trails[instanceID];
    float2 start = trail.geometry.xy;
    float2 end = trail.geometry.zw;
    float segmentLength = max(length(end - start), 0.001);
    float2 tangent = (end - start) / segmentLength;
    float2 normal = float2(-tangent.y, tangent.x);
    float2 local = corners[vertexID];
    float maximumHalfWidth = max(trail.appearance.x, trail.appearance.y) * 0.5;
    float along = local.y < 0 ? -maximumHalfWidth : segmentLength + maximumHalfWidth;
    float2 point = start + tangent * along + normal * local.x * maximumHalfWidth;
    TrailVertex out;
    out.position = float4(point.x / viewportPoints.x * 2 - 1, 1 - point.y / viewportPoints.y * 2, 0, 1);
    out.local = float2(local.x * maximumHalfWidth, along);
    out.glassPosition = point;
    out.dropMask = trail.dropMask;
    out.opacity = trail.appearance.z;
    out.endpointWidths = trail.appearance.xy;
    out.segmentLength = segmentLength;
    out.style = trail.style.x;
    out.remaining = trail.appearance.w;
    return out;
}

float trailHalfWidth(TrailVertex in) {
    float progress = clamp(in.local.y / in.segmentLength, 0.0, 1.0);
    float width = mix(in.endpointWidths.x, in.endpointWidths.y, progress);
    float neck = in.style > 0.5 ? 1.0 - 0.38 * (4.0 * progress * (1.0 - progress)) : 1.0;
    return max(0.01, width * 0.5 * neck);
}

float trailCoverage(TrailVertex in) {
    float halfWidth = trailHalfWidth(in);
    float beyond = max(max(-in.local.y, in.local.y - in.segmentLength), 0.0) / halfWidth;
    float cross = in.local.x / halfWidth;
    float distanceSquared = cross * cross + beyond * beyond;
    return 1.0 - smoothstep(0.52, 1.08, distanceSquared);
}

float trailOutsideParent(TrailVertex in) {
    if (in.dropMask.z <= 0.0) { return 1.0; }
    float2 offset = (in.glassPosition - in.dropMask.xy) / in.dropMask.zw;
    // Let the drop replace its own tail, with a narrow soft join at the rim.
    return smoothstep(0.78, 1.04, length(offset));
}

fragment float4 trailFragment(TrailVertex in [[stage_in]]) {
    float coverage = trailCoverage(in);
    float across = abs(in.local.x / trailHalfWidth(in));
    float rim = smoothstep(0.45, 0.8, across);
    float alpha = coverage * trailOutsideParent(in) * in.opacity *
                  (in.style > 0.5 ? 0.004 : mix(0.04, 0.075, rim));
    float3 color = mix(float3(0.12, 0.14, 0.17), float3(0.9, 0.94, 1.0), rim);
    return float4(color, alpha);
}

fragment float4 waterDropletFragment(DropletVertex in [[stage_in]]) {
    float distance = dropletShapeDistance(in.local, in.shape);
    if (distance >= 1) { discard_fragment(); }
    float height = sqrt(max(0.0, 1.0 - distance * distance)) * in.opacity;
    return float4(height, 0, 0, 1);
}

fragment float4 waterTrailFragment(TrailVertex in [[stage_in]]) {
    float coverage = trailCoverage(in);
    float ridge = max(0.0, 1.0 - abs(in.local.x / trailHalfWidth(in)));
    float strength = in.style > 0.5 ? 0.18 : 0.55;
    return float4(coverage * trailOutsideParent(in) * ridge * in.opacity * strength, 0, 0, 1);
}

fragment float4 fogWipeDropletFragment(DropletVertex in [[stage_in]]) {
    float distance = dropletShapeDistance(in.local, in.shape);
    float coverage = 1.0 - smoothstep(0.78, 1.04, distance);
    return float4(coverage * saturate(in.opacity * 1.8), 0, 0, 1);
}

fragment float4 fogWipeTrailFragment(TrailVertex in [[stage_in]]) {
    return float4(trailCoverage(in) * in.opacity, 0, 0, 1);
}

fragment float4 wetGlassFragment(
    FullscreenVertex in [[stage_in]],
    texture2d<float> sharp [[texture(0)]],
    texture2d<float> blurred [[texture(1)]],
    texture2d<float> water [[texture(2)]],
    texture2d<float> fog [[texture(3)]],
    texture2d<float> fogged [[texture(4)]],
    sampler imageSampler [[sampler(0)]],
    constant float4& settings [[buffer(0)]],
    constant float& exposureEV [[buffer(1)]],
    constant float4& glass [[buffer(2)]]
) {
    float2 uv = in.position.xy / settings.xy;
    if (settings.z <= 0.0 && glass.x <= 0.0 && glass.y <= 0.0 && glass.z <= 0.0) {
        return float4(blurred.sample(imageSampler, uv).rgb * exp2(exposureEV), 1);
    }
    float2 pixel = 1.0 / float2(water.get_width(), water.get_height());
    float height = water.sample(imageSampler, uv).r;
    float2 slope = float2(
        water.sample(imageSampler, uv + float2(pixel.x, 0)).r - water.sample(imageSampler, uv - float2(pixel.x, 0)).r,
        water.sample(imageSampler, uv + float2(0, pixel.y)).r - water.sample(imageSampler, uv - float2(0, pixel.y)).r
    );
    float2 refractedUV = clamp(uv - slope * settings.z * 0.018, 0.0, 1.0);
    float3 clearColor = sharp.sample(imageSampler, refractedUV).rgb;
    float3 softColor = blurred.sample(imageSampler, uv).rgb;
    float focus = saturate(height * 1.7);
    float3 color = mix(softColor, clearColor, settings.w > 0 ? focus : 1.0);
    if (glass.x > 0.0 || glass.y > 0.0 || glass.z > 0.0) {
        float fogValue = fog.sample(imageSampler, uv).r;
        float condensation = saturate(glass.x * fogValue *
                                      (1.0 - smoothstep(0.08, 0.5, height)));
        color = mix(color, fogged.sample(imageSampler, uv).rgb, condensation * glass.w);
        float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = mix(color, float3(luma), condensation * 0.08);
        color += glass.y * (fogValue - 0.5) * 0.025;
        float imperfections = smoothstep(0.91, 0.995, fogValue);
        color *= 1.0 - imperfections * glass.z * 0.02;
    }
    float edge = saturate(length(slope) * 0.35);
    color *= 1 - edge * 0.09;
    color += float3(0.012) * edge;
    return float4(color * exp2(exposureEV), 1);
}

float fogHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float fogNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(fogHash(i), fogHash(i + float2(1, 0)), f.x),
               mix(fogHash(i + float2(0, 1)), fogHash(i + 1.0), f.x), f.y);
}

kernel void fogEvolutionKernel(texture2d<float, access::sample> previous [[texture(0)]],
                               texture2d<float, access::sample> wipe [[texture(1)]],
                               texture2d<float, access::write> output [[texture(2)]],
                               constant float4& settings [[buffer(0)]],
                               uint2 id [[thread_position_in_grid]]) {
    if (id.x >= output.get_width() || id.y >= output.get_height()) { return; }
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 uv = (float2(id) + 0.5) / float2(output.get_width(), output.get_height());
    float broad = fogNoise(uv * 7.0);
    float fine = fogNoise(uv * 29.0);
    float base = saturate(0.78 + (broad * 0.7 + fine * 0.3 - 0.5) * 0.3);
    float oldDensity = settings.z > 0.5 ? previous.sample(linearSampler, uv).r : base;
    float recovered = base + (oldDensity - base) * exp(-settings.x * 3.0 / max(settings.y, 1.0));
    float cleared = wipe.sample(linearSampler, uv).r;
    output.write(float4(min(recovered, base * (1.0 - cleared)), 0, 0, 1), id);
}
