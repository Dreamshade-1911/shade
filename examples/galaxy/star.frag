#version 450

// Infinite procedural starfield.

layout(location = 0) in vec2      v_world;
layout(location = 1) flat in float v_ppw;   // pixels per world unit

layout(location = 0) out vec4 frag;

float h21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

vec2 h22(vec2 p) {
    float n = dot(p, vec2(127.1, 311.7));
    return fract(sin(vec2(n, n + 1.7)) * 43758.5453);
}

// One grid layer: `cell` world units per cell, a star in a cell iff its hash
// beats `thresh`. Brighter stars for higher hashes.
vec3 star_layer(vec2 world, float cell, float ppw, float thresh, vec3 tint) {
    vec2 g    = world / cell;
    vec2 base = floor(g);
    vec2 f    = fract(g);
    vec3 c    = vec3(0.0);
    for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
            vec2  nc = base + vec2(ox, oy);
            float r  = h21(nc);
            if (r > thresh) {
                vec2  sp     = vec2(ox, oy) + 0.15 + 0.7 * h22(nc);
                float dpx    = length(f - sp) * cell * ppw;      // fragment->star, in pixels
                float bright = (r - thresh) / (1.0 - thresh);
                float glow   = 1.0 - smoothstep(0.0, 1.7, dpx);  // ~1.7px radius
                c += tint * (glow * glow * (0.30 + 0.70 * bright));
            }
        }
    }
    return c;
}

void main() {
    vec3 col = vec3(0.0);
    col += star_layer(v_world,  46.0, v_ppw, 0.80, vec3(0.85, 0.92, 1.00));
    col += star_layer(v_world,  90.0, v_ppw, 0.68, vec3(1.00, 0.94, 0.85));
    col += star_layer(v_world, 200.0, v_ppw, 0.50, vec3(0.95, 0.90, 1.00));
    frag = vec4(col, 1.0);   // additive over the cleared background
}
