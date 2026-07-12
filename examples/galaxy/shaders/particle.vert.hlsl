// Vertex uniforms live in space1 for SDL_gpu's HLSL binding model.
cbuffer Camera : register(b0, space1)
{
    float2 center;       // world-space center of the view
    float2 world_scale;  // world units -> NDC
    float2 point_ndc;    // half-size of a particle quad in NDC (constant pixels)
    float2 _pad;
};

struct VSInput
{
    float2 corner : TEXCOORD0; // static unit-quad corner, [-1, 1]
    float2 pos    : TEXCOORD1; // per-instance world position
    float4 color  : TEXCOORD2; // per-instance color
};

struct VSOutput
{
    float2 uv       : TEXCOORD0;
    float4 color    : TEXCOORD1;
    float4 position : SV_Position;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    float2 c = (input.pos - center) * world_scale;  // particle center in NDC
    float2 p = c + input.corner * point_ndc;        // expand to a fixed-pixel quad
    output.position = float4(p, 0.0, 1.0);
    output.uv    = input.corner;
    output.color = input.color;
    return output;
}
