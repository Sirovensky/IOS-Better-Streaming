#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Gentle, edge-weighted Liquid-Glass refraction of a rasterizable snapshot Image
// (NEVER the live UIKit TabView — that can't rasterize and renders the red
// "unrenderable" placeholder). The center stays calm/readable; bending and
// chromatic aberration are pushed into a thin rim band; a little procedural noise
// adds optical irregularity. The prismatic edge / bevel / top light live in a
// SwiftUI overlay (GlassRimOverlay), not here. Knobs (RootTabView.RefractionStrength):
// strength 5...9, chroma 0.8...2.0, noiseAmount 0.15...0.45.

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float sdRoundRect(float2 p, float2 halfSize, float radius) {
    radius = clamp(radius, 0.0, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - (halfSize - float2(radius));
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

float2 sdfNormal(float2 p, float2 halfSize, float radius) {
    float e = 1.0;
    float dx = sdRoundRect(p + float2(e, 0.0), halfSize, radius)
             - sdRoundRect(p - float2(e, 0.0), halfSize, radius);
    float dy = sdRoundRect(p + float2(0.0, e), halfSize, radius)
             - sdRoundRect(p - float2(0.0, e), halfSize, radius);
    float2 n = float2(dx, dy);
    return n / max(length(n), 0.0001);
}

float2 clampPoint(float2 p, float2 size) {
    return clamp(p, float2(0.5), max(size - float2(0.5), float2(0.5)));
}

[[ stitchable ]] half4 backdropRefract(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float strength,
    float chroma,
    float noiseAmount,
    float cornerRadius
) {
    float2 safeSize = max(size, float2(1.0));
    float2 uv = position / safeSize;
    float2 centered = position - safeSize * 0.5;
    float2 halfSize = safeSize * 0.5;

    float sdf = sdRoundRect(centered, halfSize, cornerRadius);
    float insideDistance = max(-sdf, 0.0);

    float rimWidth = clamp(min(safeSize.x, safeSize.y) * 0.10, 10.0, 44.0);
    float edge = 1.0 - smoothstep(1.0, rimWidth, insideDistance);
    edge = pow(edge, 1.35);

    float2 normal = sdfNormal(centered, halfSize, cornerRadius);

    constexpr float TAU = 6.28318530718;

    float n0 = valueNoise(uv * 2.8 + float2(7.1, 3.3)) - 0.5;
    float n1 = valueNoise(uv * 6.0 + float2(11.0, 19.0)) - 0.5;

    float2 flow = float2(
        sin((uv.y * 1.65 + uv.x * 0.18) * TAU) * 0.42 +
        sin((uv.y * 3.10 - uv.x * 0.27) * TAU + 1.7) * 0.16 +
        n0 * 0.18,

        cos((uv.x * 1.45 - uv.y * 0.12) * TAU + 0.4) * 0.42 +
        cos((uv.x * 2.70 + uv.y * 0.21) * TAU + 2.2) * 0.16 +
        n1 * 0.18
    );

    float centerDistance = distance(uv, float2(0.5));
    // Glassy everywhere — never fully calm in the center — ramping up toward the rim,
    // so the WHOLE surface reads like glass (not just a thin edge band).
    float surface = 0.35 + 0.65 * smoothstep(0.10, 0.70, centerDistance);
    float edgeOnly = pow(edge, 1.45);

    float2 displaced = position
        + flow * strength * 0.40 * surface
        + normal * strength * 1.05 * edgeOnly;

    float glassNoise = valueNoise(position * 0.33 + float2(41.0, 17.0)) - 0.5;
    displaced += (normal * edgeOnly + flow * 0.25) * glassNoise * noiseAmount;

    float2 displacement = displaced - position;
    float2 caDir = displacement + normal * (0.6 + edge * 0.4);
    caDir = caDir / max(length(caDir), 0.0001);

    // Prismatic chromatic split (in points): present across the surface, strongest at
    // the rim — the "edge-like" rainbow fringing the design calls for.
    float ca = chroma * (1.0 + 2.8 * edge);

    half4 r = layer.sample(clampPoint(displaced + caDir * ca, safeSize));
    half4 g = layer.sample(clampPoint(displaced, safeSize));
    half4 b = layer.sample(clampPoint(displaced - caDir * ca, safeSize));

    // SwiftUI layer samples are premultiplied. Unpremultiply per sample, combine
    // channels, then premultiply again — so edge samples that land on transparent
    // pixels never punch dark holes at the rim.
    float ar = max(float(r.a), 0.0001);
    float ag = max(float(g.a), 0.0001);
    float ab = max(float(b.a), 0.0001);
    float a = max(max(float(r.a), float(g.a)), float(b.a));

    float3 rgb = float3(float(r.r) / ar, float(g.g) / ag, float(b.b) / ab);

    float grain = (hash21(position * 0.83) - 0.5) * noiseAmount * 0.018;
    rgb = clamp(rgb + grain * (0.25 + edge * 0.75), 0.0, 1.0);

    return half4(half3(rgb * a), half(a));
}
