// Vertex uniforms live in space1 for SDL_gpu's HLSL binding model.
cbuffer Viewport : register(b0, space1)
{
    float2 viewport_size;
};

struct VSInput
{
    float2 pos   : TEXCOORD0; // pixels, top-left origin
    float4 color : TEXCOORD1;
};

struct VSOutput
{
    float4 color    : TEXCOORD0;
    float4 position : SV_Position;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    // Pixel coords -> NDC, Y flipped so (0,0) is the top-left.
    float2 ndc = (input.pos / viewport_size) * 2.0 - 1.0;
    output.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    output.color = input.color;
    return output;
}
