[3:40 PM, 5/6/2025] Juan David Rios: #include "Structures.fxh"

#ifndef DXCOMPILER
#    define NonUniformResourceIndex(x) x
#endif

ConstantBuffer<GlobalConstants> g_Constants;
ConstantBuffer<ObjectConstants> g_ObjectConst;
StructuredBuffer<ObjectAttribs> g_ObjectAttribs;

struct VSInput
{
    float3 Pos  : ATTRIB0;
    float3 Norm : ATTRIB1;
    float2 UV   : ATTRIB2;
};

struct PSInput
{
    float4 Pos  : SV_POSITION;
    float4 WPos : WORLD_POS; // world-space position
    float3 Norm : NORMAL;    // world-space normal
    float2 UV   : TEX_COORD;
    nointerpolation uint MatId : MATERIAL; // single material ID per triangle
};

void main(in VSInput  VSIn,
          in uint     InstanceId : SV_InstanceID,
          out PSInput PSIn)
{
    ObjectAttribs Obj = g_ObjectAttribs[g_ObjectConst.Obje…
[3:42 PM, 5/6/2025] Juan David Rios: #include "Structures.fxh"

#ifndef DXCOMPILER
#    define NonUniformResourceIndex(x) x
#endif

// Recursos existentes
Texture2D    g_Textures[NUM_TEXTURES];
SamplerState g_Samplers[NUM_SAMPLERS];
TextureCube  g_ReflectionMap : register(t11);
SamplerState g_ReflectionSampler;

ConstantBuffer<GlobalConstants> g_Constants;
ConstantBuffer<ObjectConstants> g_ObjectConst;
StructuredBuffer<ObjectAttribs> g_ObjectAttribs;

// Normal map del agua
Texture2D    g_WaterNormalMap : register(t10);

cbuffer WaterCB
{
    float  g_Time;
    float2 g_UVSpeed;
    float  g_Reflectivity;
};

struct VSInput
{
    float3 Pos   : ATTRIB0;
    float3 Norm  : ATTRIB1;
    float2 UV    : ATTRIB2;
};

struct PSInput
{
    float4 Pos   : SV_POSITION;
    float4 WPos  : WORLD_POS;
    float3 Norm  : NORMAL;
    float2 UV    : TEX_COORD;
    nointerpolation uint MatId : MATERIAL;
};

// Vertex Shader adaptado con instanciación para agua en cubo
void VSWaterInstanced(in VSInput VSIn,
                      in uint    InstanceId : SV_InstanceID,
                      out PSInput PSIn)
{
    // Obtiene la matriz de modelo de la instancia
    ObjectAttribs Obj = g_ObjectAttribs[g_ObjectConst.ObjectAttribsOffset + InstanceId];

    // Calcula posición en espacio mundial
    PSIn.WPos  = mul(float4(VSIn.Pos, 1.0), Obj.ModelMat);
    // Proyección a clip space
    PSIn.Pos   = mul(PSIn.WPos, g_Constants.ViewProj);
    
    // Normal transformada y normalizada
    PSIn.Norm  = normalize(mul(VSIn.Norm, (float3x3)Obj.NormalMat));

    // Desplazamiento animado de UV para simular movimiento del agua
    PSIn.UV    = VSIn.UV + g_Time * g_UVSpeed;

    // Agua utiliza siempre el material 0 (normal map sampler)
    PSIn.MatId = 0;
}

// Pixel Shader de agua sobre cubo
PSOutput PSWater(PSInput PSIn)
{
    PSOutput PSOut;
    // Muestreo de normal map para perturbación
    float3 nrmSample = g_WaterNormalMap.Sample(
        g_Samplers[NonUniformResourceIndex(PSIn.MatId)], PSIn.UV).xyz * 2.0 - 1.0;
    float3 perturbedNormal = normalize(nrmSample);

    // Dirección de la cámara
    float3 viewDir = normalize(g_Constants.CameraPos - PSIn.WPos.xyz);
    // Cálculo de reflexión
    float3 reflDir = reflect(-viewDir, perturbedNormal);
    float4 reflectionColor = g_ReflectionMap.Sample(g_ReflectionSampler, reflDir);

    // Color base semitransparente azul del agua
    float4 baseColor = float4(0.0, 0.3, 0.5, 0.5);

    // Mezcla entre base y reflejo
    PSOut.Color = lerp(baseColor, reflectionColor, g_Reflectivity);
    PSOut.Norm  = float4(perturbedNormal, 0.0);
    return PSOut;
}

Technique WaterCubeTech
{
    Pass P0
    {
        SetVertexShader(   CompileShader(VS, VSWaterInstanced()));
        SetPixelShader(    CompileShader(PS, PSWater()));
        SetBlendState(     AlphaBlend);
        SetDepthStencilState( DepthEnable, DepthWriteDisable );
    }
}