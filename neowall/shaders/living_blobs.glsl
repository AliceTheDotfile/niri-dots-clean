/*
 * Living Blobs v13
 *
 * Chunky grayscale blob wallpaper for NeoWall/labwc.
 *
 * v13 changes:
 *   - All blobs are merged into ONE continuous metaball-style field before
 *     the grayscale gradient is calculated. When masses touch, their
 *     brightness behaves like one combined shape instead of separate blobs.
 *   - Several group centers intentionally travel partly off-screen.
 *   - Gradient brightness is quantized into hard grayscale bands.
 *   - The shader stays cheap: no noise, no exp(), no sqrt().
 *
 * Main controls:
 *   pixelSize        = square pixel size in screen pixels
 *   blobScale        = overall size of blob groups
 *   edgeBrightness   = brightness of the outside band (0..1)
 *   centerBrightness = brightness of the brightest band (1 = pure white)
 *   edgeThreshold    = where the blob begins
 *   whiteThreshold   = field strength that becomes the white center
 *   gradientSteps    = number of visible grayscale bands
 *   mergeStrength    = how strongly overlapping masses fuse together
 *   motionSpeed      = movement speed inside the shader
 */

const float pixelSize = 13;
const float blobScale = 2.5;
const float edgeBrightness = 0.18;
const float centerBrightness = 0.7;
const float edgeThreshold = 0.035;
const float whiteThreshold = 0.78;
const float gradientSteps = 4;
const float mergeStrength = 3;
const float motionSpeed = 0.5;

// Cheap compact-support blob. No exp(), no sqrt().
float blob(vec2 p, vec2 center, vec2 radius) {
    vec2 d = (p - center) / radius;
    float q = dot(d, d);
    return max(0.0, 1.0 - q);
}

vec2 groupCenter(float id, float t) {
    vec2 base;
    if (id < 0.5) {
        // Intentionally starts partly off the left edge.
        base = vec2(-2.00, -0.55);
    } else if (id < 1.5) {
        // Intentionally starts near/above the top edge.
        base = vec2(0.15, 1.82);
    } else if (id < 2.5) {
        // Intentionally starts partly off the right edge.
        base = vec2(2.02, -0.20);
    } else {
        // Intentionally starts near/below the bottom-left.
        base = vec2(-1.15, -1.82);
    }

    float phase = id * 1.93 + 0.7;

    // Whole groups slowly travel around, including beyond screen bounds.
    vec2 drift = vec2(
        0.62 * sin(t * (0.23 + id * 0.015) + phase) +
        0.18 * sin(t * 0.51 + phase * 1.7),
        0.48 * cos(t * (0.19 + id * 0.012) + phase * 1.31) +
        0.15 * sin(t * 0.43 + phase * 2.1)
    );

    return base + drift;
}

float blobGroup(vec2 p, float id, float t) {
    vec2 c = groupCenter(id, t);
    float phase = id * 3.17 + 0.35;

    vec2 a = vec2(
        cos(t * 0.58 + phase),
        sin(t * 0.49 + phase * 1.37)
    );
    vec2 b = vec2(
        cos(t * 0.39 + phase * 1.8),
        sin(t * 0.45 + phase * 0.73)
    );

    float pulse = 0.94 + 0.10 * sin(t * 0.34 + phase);
    float s = blobScale * pulse;
    float field = 0.0;

    // Three overlapping lobes make one irregular moving mass.
    field += blob(p, c + a * (0.25 * s), vec2(0.54, 0.43) * s);
    field += blob(p, c - a * (0.24 * s) + b * (0.12 * s), vec2(0.47, 0.49) * s);
    field += blob(p, c + b * (0.28 * s), vec2(0.43, 0.37) * s);

    // Gentle angular silhouette deformation, still trig-only.
    vec2 q = p - c;
    float angle = atan(q.y, q.x);
    float morph = 1.0
        + 0.08 * sin(angle * 3.0 + t * 0.50 + phase)
        + 0.04 * sin(angle * 5.0 - t * 0.32 + phase * 1.9);

    return field * morph;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    float t = iTime * motionSpeed;

    // One computed value per square pixel cell.
    vec2 cell = floor(fragCoord / pixelSize);
    vec2 samplePx = cell * pixelSize + pixelSize * 0.5;

    float aspect = iResolution.x / iResolution.y;
    vec2 uv = samplePx / iResolution.xy;
    vec2 p = (uv - 0.5) * vec2(aspect, 1.0) * 3.35;

    // Cheap shared warp.
    float wx = 0.075 * sin(p.y * 2.1 + t * 0.22)
             + 0.035 * sin(p.y * 4.3 - t * 0.17);
    float wy = 0.065 * sin(p.x * 1.8 - t * 0.19)
             + 0.030 * sin(p.x * 3.7 + t * 0.15);
    p += vec2(wx, wy);

    // IMPORTANT: build ONE global field first.
    // This is what makes touching blobs behave like one merged mass.
    float rawField = 0.0;
    rawField += blobGroup(p, 0.0, t);
    rawField += blobGroup(p, 1.0, t);
    rawField += blobGroup(p, 2.0, t);
    rawField += blobGroup(p, 3.0, t);

    // Cheap metaball-style saturation. Overlapping masses reinforce each
    // other, while the field stays bounded and smooth enough to band.
    float mergedField = (rawField * mergeStrength) /
                        (1.0 + rawField * mergeStrength);

    // Wide gradient across the whole merged field.
    float depth = clamp(
        (mergedField - edgeThreshold) /
        (whiteThreshold - edgeThreshold),
        0.0,
        1.0
    );

    // Hard grayscale bands. No smooth interpolation between shades.
    float bandCount = max(2.0, gradientSteps);
    float band = floor(depth * (bandCount - 1.0) + 0.5) /
                 (bandCount - 1.0);
    band = clamp(band, 0.0, 1.0);

    float value = edgeBrightness +
                  (centerBrightness - edgeBrightness) * band;

    // Hard silhouette; inside the silhouette the outside band is still gray.
    if (mergedField < edgeThreshold) {
        value = 0.0;
    }

    fragColor = vec4(vec3(value), 1.0);
}
