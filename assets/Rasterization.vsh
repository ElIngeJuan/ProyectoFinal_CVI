#include "Structures.fxh"

struct VSInput
{
    float3 Pos  : ATTRIB0;
    float3 Norm : ATTRIB1;
    float2 UV   : ATTRIB2;
};

struct PSInput
{
    float4 Pos  : SV_POSITION;
    float4 WPos : WORLD_POS;
    float3 Norm : NORMAL;
    float2 UV   : TEX_COORD;
    nointerpolation uint MatId : MATERIAL;
};

ConstantBuffer<GlobalConstants>   g_Constants;
ConstantBuffer<ObjectConstants>   g_ObjectConst;
StructuredBuffer<ObjectAttribs>   g_ObjectAttribs;

void main(in VSInput  VSIn,
          in uint     InstanceId : SV_InstanceID,
          out PSInput PSIn)
{
    ObjectAttribs Obj = g_ObjectAttribs[g_ObjectConst.ObjectAttribsOffset + InstanceId];
    
    float4 pos = float4(VSIn.Pos, 1.0);
    
    // Aplicar ondas solo para agua
    if (Obj.MaterialId == g_Constants.WaterMaterialId) {
        float wave = sin(pos.x * 0.5 + g_Constants.Time) * 0.2 +
                     sin(pos.z * 0.8 + g_Constants.Time * 1.5) * 0.15;
        pos.y += wave;
    }

    PSIn.WPos  = mul(pos, Obj.ModelMat);
    PSIn.Pos   = mul(PSIn.WPos, g_Constants.ViewProj);
    PSIn.Norm  = mul(VSIn.Norm, (float3x3)Obj.NormalMat);
    PSIn.UV    = VSIn.UV;
    PSIn.MatId = Obj.MaterialId;
}
