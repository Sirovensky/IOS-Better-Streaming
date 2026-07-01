# Apple Liquid Glass Full-Screen Player Advice

Target the Image #3 look for the actual music player: readable center, quiet lensing, glassy bevel, soft top light, and edge-only chromatic color. Image #1 is useful as transition inspiration, but it is too distorted for a settled Now Playing surface.

## Practical Targets

Use these as starting values:

```swift
let refractStrength: CGFloat = 6.0      // 5...9, not 36
let chromaStrength: CGFloat = 1.35      // 0.8...2.0
let noiseAmount: CGFloat = 0.28         // 0.15...0.45
let maxSampleOffset = CGSize(width: 18, height: 18)
```

The center should stay readable. Most of the optical behavior should live in an edge band around `16...36pt` wide. The "Liquid Glass" feel comes more from rim light, inner bevel, prismatic edge, and soft global highlight than from aggressive warping.

## Revised Metal Shader

This shader keeps displacement gentle, pushes stronger bending toward the rim, samples RGB channels separately for chromatic aberration, and adds cheap procedural texture.

It assumes a rounded-rect SDF. If `LiquidShape` has a flat-top custom outline, this is still a good approximation for optical weighting, but the SwiftUI rim overlay should use the exact shape.

```metal
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

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

    float wideEdge = 1.0 - smoothstep(rimWidth, rimWidth * 3.0, insideDistance);
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
    float centerCalm = smoothstep(0.18, 0.75, centerDistance);
    float edgeOnly = pow(edge, 1.45);

    float2 displaced = position
        + flow * strength * 0.18 * centerCalm
        + normal * strength * 0.85 * edgeOnly;

    float glassNoise = valueNoise(position * 0.33 + float2(41.0, 17.0)) - 0.5;
    displaced += (normal * edgeOnly + flow * 0.25) * glassNoise * noiseAmount;

    float2 displacement = displaced - position;
    float2 caDir = displacement + normal * (0.65 + edge * 0.35);
    caDir = caDir / max(length(caDir), 0.0001);

    float ca = chroma * pow(edge, 1.70)
             * (0.45 + 0.55 * clamp(length(displacement) / max(strength, 1.0), 0.0, 1.0));

    half4 r = layer.sample(clampPoint(displaced + caDir * ca, safeSize));
    half4 g = layer.sample(clampPoint(displaced, safeSize));
    half4 b = layer.sample(clampPoint(displaced - caDir * ca, safeSize));

    // SwiftUI layer samples are premultiplied. Unpremultiply per sample, combine
    // channels, then premultiply again.
    float ar = max(float(r.a), 0.0001);
    float ag = max(float(g.a), 0.0001);
    float ab = max(float(b.a), 0.0001);
    float a = max(max(float(r.a), float(g.a)), float(b.a));

    float3 rgb = float3(float(r.r) / ar, float(g.g) / ag, float(b.b) / ab);

    float grain = (hash21(position * 0.83) - 0.5) * noiseAmount * 0.018;
    rgb = clamp(rgb + grain * (0.25 + edge * 0.75), 0.0, 1.0);

    return half4(half3(rgb * a), half(a));
}
```

## SwiftUI Shader Modifier

Prefer `isEnabled` over structurally swapping the content when possible. It avoids changing the view tree while still skipping the shader when the value is effectively zero.

```swift
struct BackdropRefraction: ViewModifier, Animatable {
    var strength: CGFloat
    var chroma: CGFloat = 1.35
    var noise: CGFloat = 0.28
    var cornerRadius: CGFloat
    var size: CGSize

    var animatableData: CGFloat {
        get { strength }
        set { strength = newValue }
    }

    func body(content: Content) -> some View {
        content.layerEffect(
            ShaderLibrary.backdropRefract(
                .float2(size),
                .float(Float(strength)),
                .float(Float(chroma)),
                .float(Float(noise)),
                .float(Float(cornerRadius))
            ),
            maxSampleOffset: CGSize(width: 18, height: 18),
            isEnabled: strength > 0.05
        )
    }
}
```

If you still see edge artifacts, raise `maxSampleOffset` to `24x24`. With the gentler shader, `80x80` is unnecessary.

## Rim, Specular, And Global Light

Put the glass edge in SwiftUI overlays, not the refraction shader. The shader should bend the snapshot. The overlay should sell the object: white bevel, prismatic rim, subtle inner stroke, and a top light.

```swift
struct GlassRimOverlay<S: InsettableShape>: View {
    var shape: S
    var intensity: CGFloat = 1

    var body: some View {
        shape
            .fill(.white.opacity(0.045 * intensity))
            .blendMode(.screen)
            .overlay {
                shape
                    .strokeBorder(.white.opacity(0.45 * intensity), lineWidth: 0.8)
                    .blendMode(.screen)
            }
            .overlay {
                shape.strokeBorder(
                    AngularGradient(colors: [
                        .cyan.opacity(0.45),
                        .white.opacity(0.75),
                        .pink.opacity(0.42),
                        .yellow.opacity(0.30),
                        .cyan.opacity(0.45)
                    ], center: .center),
                    lineWidth: 2.0
                )
                .blur(radius: 0.35)
                .opacity(0.35 * intensity)
                .blendMode(.screen)
            }
            .overlay {
                shape.fill(
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0.22 * intensity), location: 0.00),
                        .init(color: .white.opacity(0.08 * intensity), location: 0.12),
                        .init(color: .clear, location: 0.42)
                    ], startPoint: .top, endPoint: .center)
                )
                .blendMode(.screen)
            }
            .overlay {
                shape.inset(by: 2)
                    .strokeBorder(
                        LinearGradient(colors: [
                            .white.opacity(0.50 * intensity),
                            .clear,
                            .white.opacity(0.14 * intensity)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
                    .blendMode(.screen)
            }
            .allowsHitTesting(false)
    }
}
```

If your `LiquidShape` is only `Shape`, either make it `InsettableShape` or replace `strokeBorder` with `stroke`.

## Robust Compositing Structure

The snapshot should be an explicit fixed full-screen layer. The player should behave like a moving window looking into that snapshot.

Avoid this as the primary structure:

```swift
Color.clear
    .frame(width: w, height: h)
    .background(snapshotImage.modifier(BackdropRefraction(...)))
```

Prefer this:

```swift
ZStack {
    Image(uiImage: snapshot)
        .resizable()
        .scaledToFill()
        .frame(width: screenSize.width, height: screenSize.height)
        .offset(
            x: screenSize.width / 2 - currentFrame.midX,
            y: screenSize.height / 2 - currentFrame.midY
        )
        .frame(width: currentFrame.width, height: currentFrame.height)
        .clipped()
        .modifier(BackdropRefraction(
            strength: refractStrength,
            chroma: chromaStrength,
            noise: noiseAmount,
            cornerRadius: cornerRadius,
            size: currentFrame.size
        ))

    Color.clear
        .glassEffect(.clear, in: shape)

    NowPlayingView(...)

    GlassRimOverlay(shape: shape, intensity: p)
}
.frame(width: currentFrame.width, height: currentFrame.height)
.clipShape(shape)
.compositingGroup()
```

This keeps the raster source stable across the morph. The shader always samples a real image, then the result is clipped to the player shape.

## Full-Open Black Backdrop Bug

Most likely cause: the snapshot is attached as the `.background` of a morphing clear view, so sizing, clipping, or compositing changes at `p = 1` make the raster source empty or misaligned.

Less likely causes:

- `maxSampleOffset` outside the image: possible at edges, but it should not make the entire full-screen backdrop black if the source is correctly sized.
- Delayed fade: possible if state changes zero out strength or swap the view tree at settle, but that would usually remove refraction, not black the source.
- `Glass.clear` over full bleed: possible interaction, but the snapshot should still be visible if it is an explicit layer behind the clear glass.
- Snapshot not filling: very plausible if the `Image` is resizable but not `scaledToFill`, not clipped, or only sized by `.background`.

Fix:

1. Capture the snapshot at screen/window size.
2. Render it as a fixed full-screen image.
3. Align that image behind the current morphing frame.
4. Apply `layerEffect` to the snapshot layer.
5. Clip the result to `LiquidShape`.
6. Put `.glassEffect(.clear, in: shape)` and controls above it.

## Glass Noise

Use procedural shader noise for optical irregularity. Keep it low. The texture should be felt, not seen.

Good shader values:

```swift
noiseAmount = 0.15...0.45
```

If you want visible glass texture, use a separate overlay rather than another shader sample:

```swift
Image("glass-noise-tile")
    .resizable(resizingMode: .tile)
    .opacity(0.025)
    .blendMode(.softLight)
    .clipShape(shape)
    .allowsHitTesting(false)
```

Do not animate the noise after the morph settles. Static glass texture is cheaper and reads more like material than like a video effect.

## Performance

One full-screen `layerEffect` with three texture samples is reasonable on a high-end phone if you keep the effect calm.

Recommended:

- `strength`: `5...9`
- `chroma`: `0.8...2.0`
- `noise`: `0.15...0.45`
- `maxSampleOffset`: `18x18`, or `24x24` if edge samples clip
- Avoid `80x80` unless you return to very large displacement
- Avoid live time-varying shader animation after the player settles
- Avoid applying the shader to the live `TabView`; keep using a snapshot image

## Visual Priority

Order of importance:

1. Fixed full-screen snapshot behind the player.
2. Gentle edge-weighted refraction.
3. Edge-only chromatic aberration.
4. SwiftUI prismatic rim and white bevel.
5. Soft top/global light.
6. Very subtle noise.

If the result feels too weak, raise rim/highlight opacity first. Do not raise displacement first.
