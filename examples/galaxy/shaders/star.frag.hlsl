// Infinite procedural starfield.

struct PSInput
{
    float2 world              : TEXCOORD0;
    nointerpolation float ppw : TEXCOORD1; // pixels per world unit
};

float h21(float2 p)
{
    p  = frac(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return frac(p.x * p.y);
}

float2 h22(float2 p)
{
    float n = dot(p, float2(127.1, 311.7));
    return frac(sin(float2(n, n + 1.7)) * 43758.5453);
}

// One grid layer: `cell` world units per cell, a star in a cell iff its hash
// beats `thresh`. Brighter stars for higher hashes.
float3 star_layer(float2 world, float cell, float ppw, float thresh, float3 tint)
{
    float2 g    = world / cell;
    float2 base = floor(g);
    float2 f    = frac(g);
    float3 c    = float3(0.0, 0.0, 0.0);
    for (int oy = -1; oy <= 1; oy++) {
        for (int ox = -1; ox <= 1; ox++) {
            float2 nc = base + float2(ox, oy);
            float  r  = h21(nc);
            if (r > thresh) {
                float2 sp     = float2(ox, oy) + 0.15 + 0.7 * h22(nc);
                float  dpx    = length(f - sp) * cell * ppw;      // fragment->star, in pixels
                float  bright = (r - thresh) / (1.0 - thresh);
                float  glow   = 1.0 - smoothstep(0.0, 1.7, dpx);  // ~1.7px radius
                c += tint * (glow * glow * (0.30 + 0.70 * bright));
            }
        }
    }
    return c;
}

float4 main(PSInput input) : SV_Target0
{
    float3 col = float3(0.0, 0.0, 0.0);
    col += star_layer(input.world,  46.0, input.ppw, 0.80, float3(0.85, 0.92, 1.00));
    col += star_layer(input.world,  90.0, input.ppw, 0.68, float3(1.00, 0.94, 0.85));
    col += star_layer(input.world, 200.0, input.ppw, 0.50, float3(0.95, 0.90, 1.00));
    return float4(col, 1.0);   // additive over the cleared background
}
