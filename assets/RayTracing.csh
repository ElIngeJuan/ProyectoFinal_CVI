
#ifdef METAL
#    include "RayQueryMtl.fxh"
#endif

#include "Structures.fxh"
#include "Utils.fxh"

// Vulkan and DirectX:
//   Resource indices are not allowed to vary within the wave by default.
//   When dynamic indexing is required, we have to use NonUniformResourceIndex() qualifier to avoid undefined behavior.
// Metal:
//   NonUniformResourceIndex() qualifier is not needed.
#ifndef DXCOMPILER
#    define NonUniformResourceIndex(x) x
#endif

#ifdef METAL
#    define TextureSample(Texture, Sampler, f2Coord, fLevel) Texture.sample(Sampler, f2Coord, level(fLevel))
#    define TextureLoad(Texture, u2Coord)                    Texture.read(u2Coord)
#    define TextureStore(Texture, u2Coord, f4Value)          Texture.write(f4Value, u2Coord)
#    define TextureDimensions(Texture, Dim)                  Dim=uint2(Texture.get_width(), Texture.get_height())

#    define TEXTURE(Name)                const texture2d<float>              Name
#    define TEXTURE_ARRAY(Name, Size)    const array<texture2d<float>, Size> Name
#    define WTEXTURE(Name)               texture2d<float, access::write>     Name
#    define SAMPLER_ARRAY(Name, Size)    const array<sampler, Size>          Name
#    define BUFFER(Name, Type)           const device Type*                  Name
#    define CONSTANT_BUFFER(Name, Type)  constant GlobalConstants&           Name
#else
#    define TextureSample(Texture, Sampler, f2Coord, fLevel) Texture.SampleLevel(Sampler, f2Coord, fLevel)
#    define TextureLoad(Texture, u2Coord)                    Texture.Load(int3(u2Coord, 0))
#    define TextureStore(Texture, u2Coord, f4Value)          Texture[u2Coord] = f4Value
#    define TextureDimensions(Texture, Dim)                  Texture.GetDimensions(Dim.x, Dim.y)

#    define TEXTURE(Name)                Texture2D<float4>      Name
#    define TEXTURE_ARRAY(Name, Size)    Texture2D<float4>      Name[Size]
#    define WTEXTURE(Name)               RWTexture2D<float4>    Name
#    define SAMPLER_ARRAY(Name, Size)    SamplerState           Name[Size]
#    define BUFFER(Name, Type)           StructuredBuffer<Type> Name
#    define CONSTANT_BUFFER(Name, Type)  ConstantBuffer<Type>   Name
#endif

// Returns 0 when occluder is found, and 1 otherwise
float CastShadow(float3 Origin, float3 RayDir, float MaxRayLength, RaytracingAccelerationStructure TLAS)
{
    RayDesc ShadowRay;
    ShadowRay.Origin    = Origin;
    ShadowRay.Direction = RayDir;
    ShadowRay.TMin      = 0.0;
    ShadowRay.TMax      = MaxRayLength;

    // Cull front faces to avaid self-intersections.
    // We don't use distance to occluder, so ray query can find any intersection and end search.
    RayQuery<RAY_FLAG_CULL_FRONT_FACING_TRIANGLES | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> ShadowQuery;

    // Setup ray tracing query
    ShadowQuery.TraceRayInline(TLAS,            // Acceleration Structure
                                RAY_FLAG_NONE,  // Ray Flags
                                ~0,             // Instance Inclusion Mask
                                ShadowRay);

    // Find the first intersection.
    // If a scene contains non-opaque objects then Proceed() may return TRUE until all intersections are processed or Abort() is called.
    // This behaviour is not supported by Metal RayQuery emulation, so Proceed() already returns FALSE.
    ShadowQuery.Proceed();
        
    // The scene contains only triangles, so we don't need to check COMMITTED_PROCEDURAL_PRIMITIVE_HIT
    return ShadowQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT ? 0.0 : 1.0;
}

struct ReflectionInputAttribs
{
    float3 Origin;
    float3 ReflectionRayDir;
    float  MaxReflectionRayLength;
    float  MaxShadowRayLength;
    float3 CameraPos;
    float3 LightDir;
};
struct ReflectionResult
{
    float4 BaseColor;
    float  NdotL;
    bool   Found;
};

#ifdef DXCOMPILER
// Without this struct, DXC fails to compile the shader with the following error:
//
//      error: variable has incomplete type 'SamplerState [2]'
//                SAMPLER_ARRAY(Samplers,      NUM_SAMPLERS   ),
//                              ^
//
// https://github.com/microsoft/DirectXShaderCompiler/issues/4666
struct _DXCBugWorkaround_
{
    SamplerState Samplers[2];
};
#endif

ReflectionResult Reflection(TEXTURE_ARRAY(Textures,      NUM_TEXTURES   ),
                            SAMPLER_ARRAY(Samplers,      NUM_SAMPLERS   ),
                            BUFFER(       VertexBuffer,  Vertex         ),
                            BUFFER(       IndexBuffer,   uint           ),
                            BUFFER(       Objects,       ObjectAttribs  ),
                            BUFFER(       Materials,     MaterialAttribs),
                            RaytracingAccelerationStructure TLAS,
                            ReflectionInputAttribs          In)
{
    RayDesc ReflRay;
    ReflRay.Origin    = In.Origin;
    ReflRay.Direction = In.ReflectionRayDir;
    ReflRay.TMin      = 0.0;
    ReflRay.TMax      = In.MaxReflectionRayLength;

    // Rasterization PSO uses back-face culling, so we use the same culling for ray traced reflections.
    RayQuery<RAY_FLAG_CULL_BACK_FACING_TRIANGLES> ReflQuery;

    // Trace the reflection ray in the scene.
    ReflQuery.TraceRayInline(TLAS,           // Acceleration Structure
                             RAY_FLAG_NONE,  // Ray Flags
                             ~0,             // Instance Inclusion Mask
                             ReflRay);
    ReflQuery.Proceed();

    ReflectionResult Result;
    Result.BaseColor = float4(0.0, 0.0, 0.0, 0.0);
    Result.NdotL     = 0.0;
    Result.Found     = false;

    // Sample texture at the intersection point if we hit a triangle
    if (ReflQuery.CommittedStatus() == COMMITTED_TRIANGLE_HIT)
    {
        uint InstId = ReflQuery.CommittedInstanceID();
        ObjectAttribs Obj = Objects[InstId];
        MaterialAttribs Mtr = Materials[Obj.MaterialId];

        // Read triangle vertices and calculate barycentric coordinates
        uint PrimInd = ReflQuery.CommittedPrimitiveIndex();
        uint3 TriangleInd = uint3(IndexBuffer[Obj.FirstIndex + PrimInd * 3 + 0],
                                  IndexBuffer[Obj.FirstIndex + PrimInd * 3 + 1],
                                  IndexBuffer[Obj.FirstIndex + PrimInd * 3 + 2]);

        Vertex Vert0 = VertexBuffer[TriangleInd.x + Obj.FirstVertex];
        Vertex Vert1 = VertexBuffer[TriangleInd.y + Obj.FirstVertex];
        Vertex Vert2 = VertexBuffer[TriangleInd.z + Obj.FirstVertex];

        float3 Barycentrics;
        Barycentrics.yz = ReflQuery.CommittedTriangleBarycentrics();
        Barycentrics.x  = 1.0 - Barycentrics.y - Barycentrics.z;

        // Calculate UV and normal for the intersection point.
        float2 UV = float2(Vert0.U, Vert0.V) * Barycentrics.x +
                    float2(Vert1.U, Vert1.V) * Barycentrics.y +
                    float2(Vert2.U, Vert2.V) * Barycentrics.z;

        float3 Norm = float3(Vert0.NormX, Vert0.NormY, Vert0.NormZ) * Barycentrics.x +
                      float3(Vert1.NormX, Vert1.NormY, Vert1.NormZ) * Barycentrics.y +
                      float3(Vert2.NormX, Vert2.NormY, Vert2.NormZ) * Barycentrics.z;

        // Transform normal to world space
        Norm = normalize(mul(Norm, (float3x3)Obj.NormalMat));

        // Sample the texture at the intersection point
        const float DefaultLOD = 0.0;
        Result.BaseColor = Mtr.BaseColorMask *
            TextureSample(Textures[NonUniformResourceIndex(Mtr.BaseColorTexInd)],
                          Samplers[NonUniformResourceIndex(Mtr.SampInd)],
                          UV,
                          DefaultLOD);

        // Compute lighting factor (dot product)
        Result.NdotL = max(0.0, dot(In.LightDir, Norm));
        Result.Found = true;

        // Cast shadow if the reflection is non-zero
        if (Result.NdotL > 0.0)
        {
            // Calculate the world-space position for the intersection point used as ray origin for shadow tracing
            float3 ReflWPos = ReflRay.Origin + ReflRay.Direction * ReflQuery.CommittedRayT();

            Result.NdotL *= CastShadow(ReflWPos + Norm * SMALL_OFFSET * length(ReflWPos - In.CameraPos),
                                       In.LightDir,
                                       In.MaxShadowRayLength,
                                       TLAS);
        }
    }

    return Result;
}


#ifdef METAL
#   define BEGIN_SHADER_DECLARATION(Name) kernel void Name(
#   define END_SHADER_DECLARATION(Name, GroupXSize, GroupYSize) uint2 DTid [[thread_position_in_grid]])
#   define MTL_BINDING(type, index) [[type(index)]]
#   define END_ARG ,
#else
#   define BEGIN_SHADER_DECLARATION(Name)
#   define END_SHADER_DECLARATION(Name, GroupXSize, GroupYSize) [numthreads(GroupXSize, GroupYSize, 1)] void Name(uint2 DTid : SV_DispatchThreadID)
#   define MTL_BINDING(type, index)
#   define END_ARG ;
#endif

BEGIN_SHADER_DECLARATION(CSMain)

    // m_pRayTracingSceneResourcesSign
    RaytracingAccelerationStructure g_TLAS                              MTL_BINDING(buffer,  0)  END_ARG
    CONSTANT_BUFFER(                g_Constants,       GlobalConstants) MTL_BINDING(buffer,  1)  END_ARG
    BUFFER(                         g_ObjectAttribs,   ObjectAttribs)   MTL_BINDING(buffer,  2)  END_ARG     
    BUFFER(                         g_MaterialAttribs, MaterialAttribs) MTL_BINDING(buffer,  3)  END_ARG
    BUFFER(                         g_VertexBuffer,    Vertex)          MTL_BINDING(buffer,  4)  END_ARG
    BUFFER(                         g_IndexBuffer,     uint)            MTL_BINDING(buffer,  5)  END_ARG
    TEXTURE_ARRAY(                  g_Textures,        NUM_TEXTURES)    MTL_BINDING(texture, 0)  END_ARG
    SAMPLER_ARRAY(                  g_Samplers,        NUM_SAMPLERS)    MTL_BINDING(sampler, 0)  END_ARG

    // m_pRayTracingScreenResourcesSign
    WTEXTURE(                       g_RayTracedTex)                     MTL_BINDING(texture, 5)  END_ARG
    TEXTURE(                        g_GBuffer_Normal)                   MTL_BINDING(texture, 6)  END_ARG
    TEXTURE(                        g_GBuffer_Depth)                    MTL_BINDING(texture, 7)  END_ARG
   
END_SHADER_DECLARATION(CSMain, 8, 8)
{
    uint2 Dim;
    TextureDimensions(g_RayTracedTex, Dim);

    if (DTid.x >= Dim.x || DTid.y >= Dim.y)
        return;

    float  Depth = TextureLoad(g_GBuffer_Depth, DTid).x;
    if (Depth == 1.0)
    {
        // Calcular direcci�n del cielo correctamente
        float2 ScreenUV = (float2(DTid) + 0.5) / float2(Dim);
        float3 WPos = ScreenPosToWorldPos(ScreenUV, 1.0, g_Constants.ViewProjInv);
        float3 SkyDir = normalize(WPos - g_Constants.CameraPos.xyz);
    
        // Obtener color del cielo y almacenarlo
        float3 SkyColor = GetSkyColor(SkyDir, g_Constants.LightDir.xyz);
        TextureStore(g_RayTracedTex, DTid, float4(SkyColor, 1.0));
        return;
    }

    float3 WPos        = ScreenPosToWorldPos((float2(DTid) + 0.5) / float2(Dim), Depth, g_Constants.ViewProjInv);
    float3 LightDir    = g_Constants.LightDir.xyz;
    float3 ViewRayDir  = normalize(WPos - g_Constants.CameraPos.xyz);
    float4 NormData    = TextureLoad(g_GBuffer_Normal, DTid);
    float3 WNormal     = normalize(NormData.xyz * 2.0 - 1.0);
    float  Reflectivity= NormData.a;
    float  NdotL       = max(0.0, dot(LightDir, WNormal));
    float4 Color       = float4(0.0, 0.0, 0.0, 1.0);

    // Cast shadow
    if (NdotL > 0.0)
    {
        float DisToCamera = distance(WPos, g_Constants.CameraPos.xyz);
        NdotL *= CastShadow(WPos + WNormal * SMALL_OFFSET * DisToCamera,
                          LightDir,
                          g_Constants.MaxRayLength,
                          g_TLAS);
    }

   if (Reflectivity > 0.0 && g_Constants.WaterMaterialId != INVALID_MATERIAL_ID)
    {
        MaterialAttribs waterMaterial = g_MaterialAttribs[g_Constants.WaterMaterialId];
        float3 ViewDir = normalize(g_Constants.CameraPos.xyz - WPos);
        float3 IncomingDir = -ViewDir;
        float NdotI = dot(WNormal, IncomingDir);

        // 1. C�lculo de Reflexi�n
        ReflectionInputAttribs ReflAttribs;
        ReflAttribs.Origin = WPos + WNormal * SMALL_OFFSET;
        ReflAttribs.ReflectionRayDir = reflect(IncomingDir, WNormal);
        ReflAttribs.MaxReflectionRayLength = g_Constants.MaxRayLength;
        ReflAttribs.MaxShadowRayLength = g_Constants.MaxRayLength;
        ReflAttribs.CameraPos = g_Constants.CameraPos.xyz;
        ReflAttribs.LightDir = LightDir;

        ReflectionResult Refl = Reflection(g_Textures, g_Samplers, g_VertexBuffer, 
                                         g_IndexBuffer, g_ObjectAttribs, g_MaterialAttribs,
                                         g_TLAS, ReflAttribs);

        // 2. C�lculo de Refracci�n Corregida
        ReflectionInputAttribs RefrAttribs;
        float eta = (NdotI > 0.0) ? (1.0 / waterMaterial.RefractiveIndex) : waterMaterial.RefractiveIndex;
        float3 RefractDir = refract(IncomingDir, WNormal, eta);

        // Manejar reflexi�n interna total
        if (length(RefractDir) < 0.001)
        {
            RefractDir = reflect(IncomingDir, WNormal);
        }

        RefrAttribs.Origin = WPos - WNormal * SMALL_OFFSET * sign(NdotI);
        RefrAttribs.ReflectionRayDir = RefractDir;
        RefrAttribs.MaxReflectionRayLength = g_Constants.MaxRayLength;
        RefrAttribs.MaxShadowRayLength = g_Constants.MaxRayLength;
        RefrAttribs.CameraPos = g_Constants.CameraPos.xyz;
        RefrAttribs.LightDir = LightDir;

        ReflectionResult Refr = Reflection(g_Textures, g_Samplers, g_VertexBuffer,
                                         g_IndexBuffer, g_ObjectAttribs, g_MaterialAttribs,
                                         g_TLAS, RefrAttribs);

        // 3. C�lculo Fresnel Mejorado
        float cosTheta = saturate(dot(IncomingDir, WNormal));
        float fresnelFactor = pow(1.0 - cosTheta, waterMaterial.FresnelPower);
        float Fresnel = lerp(waterMaterial.FresnelBias, 1.0, fresnelFactor);
        Fresnel *= waterMaterial.Reflectivity;

        // 4. Obtenci�n de colores con fallbacks
        float3 ReflectionColor = Refl.Found ? 
            Refl.BaseColor.rgb * max(g_Constants.AmbientLight, Refl.NdotL) : 
            GetSkyColor(ReflAttribs.ReflectionRayDir, LightDir).rgb;

        float3 RefractionColor = Refr.Found ? 
            lerp(waterMaterial.BaseColorMask.rgb, Refr.BaseColor.rgb, waterMaterial.Transparency) * 
            max(g_Constants.AmbientLight, Refr.NdotL) : 
            GetSkyColor(RefractDir, LightDir).rgb;

        // 5. Mezcla Final con Efectos Complejos
        Color.rgb = lerp(RefractionColor, ReflectionColor, Fresnel);
    
        // 6. Transparencia Adaptativa
        Color.a = waterMaterial.Transparency * saturate(1.0 - Fresnel);
    
        // 7. Brillo Especular F�sicamente Realista
        float3 HalfVec = normalize(LightDir + ViewDir);
        float Specular = pow(saturate(dot(WNormal, HalfVec)), 128.0);
        Color.rgb += Specular * Fresnel * waterMaterial.Reflectivity * 
                    lerp(1.0, Refr.BaseColor.a, waterMaterial.Transparency);

        // 8. Ajuste Final de Color
        Color.rgb = saturate(Color.rgb);
        Color.a = lerp(Color.a, 1.0, Fresnel * 0.3);  // Aumentar opacidad en bordes
    }
    else
    {
        // Materiales regulares
        ReflectionInputAttribs ReflAttribs;
        ReflAttribs.Origin                 = WPos + WNormal * SMALL_OFFSET;
        ReflAttribs.ReflectionRayDir       = reflect(-ViewRayDir, WNormal);
        ReflAttribs.MaxReflectionRayLength = g_Constants.MaxRayLength;
        ReflAttribs.MaxShadowRayLength     = g_Constants.MaxRayLength;
        ReflAttribs.CameraPos              = g_Constants.CameraPos.xyz;
        ReflAttribs.LightDir               = LightDir;

        ReflectionResult Refl = Reflection(g_Textures, g_Samplers, g_VertexBuffer,
                                         g_IndexBuffer, g_ObjectAttribs, g_MaterialAttribs,
                                         g_TLAS, ReflAttribs);

        Color = Refl.Found ? 
            Refl.BaseColor * max(g_Constants.AmbientLight, Refl.NdotL) : 
            GetSkyColor(ReflAttribs.ReflectionRayDir, LightDir);
        
        Color.a = max(g_Constants.AmbientLight, NdotL);
    }

    TextureStore(g_RayTracedTex, DTid, Color);
}