struct PSInput
{
    float4 color : TEXCOORD0;
};

float4 main(PSInput input) : SV_Target0
{
    return input.color; // straight alpha; the HUD pipeline blends SRC_ALPHA.
}
