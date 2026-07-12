// Reuses the galaxy's Camera uniform. We only need center/world_scale (to invert
// the world->NDC map) and viewport (to size stars in pixels).
cbuffer Camera : register(b0, space1)
{
    float2 center;
    float2 world_scale;
    float2 point_ndc;   // galaxy particle size, unused here
    float2 viewport;    // pixels (w, h)
};

struct VSOutput
{
    float2 world              : TEXCOORD0;
    nointerpolation float ppw : TEXCOORD1; // pixels per world unit
    float4 position           : SV_Position;
};

VSOutput main(uint vertex_id : SV_VertexID)
{
    VSOutput output;

    // Fullscreen triangle from the vertex index, no vertex buffer needed.
    float2 p   = float2(float((vertex_id << 1) & 2), float(vertex_id & 2));
    float2 ndc = p * 2.0 - 1.0;   // (-1,-1), (3,-1), (-1,3)
    output.position = float4(ndc, 0.0, 1.0);

    // Invert world -> NDC (ndc = (world - center) * world_scale).
    output.world = center + ndc / world_scale;
    // world_scale.y = 1/half, so this is isotropic px per world unit.
    output.ppw   = world_scale.y * viewport.y * 0.5;

    return output;
}
