/*
 * LIVING PIXELS
 *
 * Chunky monochrome cells driven by warped multi-octave value noise.
 * The image is intentionally HARD black/white: no gray pixels, no color.
 */

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);

    // Smooth interpolation keeps the large shapes organic.
    f = f * f * (3.0 - 2.0 * f);

    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;

    // A few octaves are enough to create large, readable structures
    // without making every cell flicker independently.
    for (int i = 0; i < 5; i++) {
        v += noise(p) * a;
        p = p * 2.03 + vec2(17.17, 9.31);
        a *= 0.5;
    }

    return v;
}

float warpedField(vec2 p, float t) {
    // Slow-moving domain warp. This makes the blobs feel alive rather
    // than simply scrolling through the screen.
    vec2 q = vec2(
        fbm(p + vec2(0.0, t * 0.10)),
        fbm(p + vec2(7.3, -t * 0.08))
    );

    q = (q - 0.5) * 2.0;

    p += q * 1.65;
    p += 0.18 * vec2(sin(t * 0.18), cos(t * 0.13));

    float a = fbm(p * 0.92 + vec2(t * 0.035, -t * 0.025));
    float b = fbm(p * 1.55 - vec2(t * 0.022, t * 0.018));

    // Interplay between two scales creates pockets that merge/split.
    return a * 0.72 + b * 0.28;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    float t = iTime;

    // Bigger value = fewer, chunkier pixels.
    // 24 works nicely around 1080p. Try 16, 20, 28, or 32 for different looks.
    const float pixelSize = 24.0;

    // Snap the sample position to a coarse screen grid.
    vec2 cell = floor(fragCoord / pixelSize);
    vec2 samplePx = cell * pixelSize + pixelSize * 0.5;
    vec2 uv = samplePx / iResolution.xy;

    // Correct for aspect ratio so the noise doesn't stretch horizontally.
    float aspect = iResolution.x / iResolution.y;
    vec2 p = uv * vec2(aspect, 1.0);

    // Center the field and gently zoom it out.
    p = (p - vec2(aspect * 0.5, 0.5)) * 4.2;

    // Very slow global drift.
    p += vec2(t * 0.012, -t * 0.009);

    float field = warpedField(p, t);

    // Add a second, larger structure to keep some giant regions intact.
    float large = fbm(p * 0.42 + vec2(-t * 0.012, t * 0.008));
    field = mix(field, field * 0.76 + large * 0.24, 0.55);

    // A moving threshold makes boundaries breathe and migrate.
    float threshold = 0.535 + 0.045 * sin(t * 0.17);
    float shape = step(threshold, field);

    // Sparse structural cuts: little voids appear/disappear within blobs.
    float cuts = noise(cell * 0.075 + vec2(t * 0.035, -t * 0.028));
    shape *= step(0.23, cuts + field * 0.15);

    // Optional very subtle edge breakup, still strictly binary.
    float micro = noise(cell * 0.19 + vec2(-t * 0.06, t * 0.05));
    shape *= step(0.08, field - micro * 0.08);

    // Pure monochrome. No antialiasing, no alpha tricks, no gray.
    vec3 bw = vec3(shape);

    fragColor = vec4(bw, 1.0);
}
