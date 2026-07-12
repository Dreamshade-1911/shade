struct PSInput
{
    float2 uv    : TEXCOORD0; // [-1, 1] across the quad
    float4 color : TEXCOORD1;
};

float4 main(PSInput input) : SV_Target0
{
    float d    = length(input.uv);                 // 0 at center, ~1 at the disc edge
    float core = 1.0 - smoothstep(0.0, 1.0, d);
    // Bright, tight core fading to a transparent rim; additive blend then blooms
    // wherever dots overlap.
    float a = core * core * input.color.a;
    // Premultiplied output for the additive blend (src=ONE, dst=ONE).
    return float4(input.color.rgb * a, a);
}
