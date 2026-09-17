#include "screen_content.h"
cbuffer Draw : register(b0) {
  column_major float4x4 viewProjection;
  column_major float4x4 model;
  float4 baseColor;
  float4 emissive;
  float4 camera;
  float4 params;
  float4 display;
};
cbuffer Skin : register(b1) { column_major float4x4 bones[128]; };
struct OfficeLight { float4 position; float4 color; float4 direction; };
cbuffer OfficeLighting : register(b2) { OfficeLight lights[16]; float4 contacts[9]; };
cbuffer Post : register(b3) { float2 outputSize; float2 blurDirection; };
Texture2D<float4> baseTexture : register(t0);
Texture2D<float4> emissionTexture : register(t1);
Texture2D<float4> materialTexture : register(t2);
SamplerState linearSampler : register(s0);
SamplerState postSampler : register(s1);
struct Vertex {
  float3 position : POSITION;
  float3 normal : NORMAL;
  float2 uv : TEXCOORD0;
  float4 joints : BLENDINDICES;
  float4 weights : BLENDWEIGHT;
};
struct Varying {
  float4 position : SV_POSITION;
  float3 normal : NORMAL;
  float2 uv : TEXCOORD0;
  float3 world : TEXCOORD1;
};
float3 transformedNormal(float4x4 transformMatrix, float3 normal) {
  // HLSL matrix indexing addresses rows even for column-major storage.
  const float3 x = float3(transformMatrix[0][0], transformMatrix[1][0], transformMatrix[2][0]);
  const float3 y = float3(transformMatrix[0][1], transformMatrix[1][1], transformMatrix[2][1]);
  const float3 z = float3(transformMatrix[0][2], transformMatrix[1][2], transformMatrix[2][2]);
  const float3 cofactorX = cross(y, z), cofactorY = cross(z, x), cofactorZ = cross(x, y);
  const float determinant = dot(x, cofactorX);
  if (abs(determinant) < 1e-10)
    return float3(0, 1, 0);
  return normalize((cofactorX * normal.x + cofactorY * normal.y + cofactorZ * normal.z) / determinant);
}
Varying vsMain(Vertex v) {
  float4x4 skin = float4x4(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1);
  if (params.x > .5)
    skin = bones[(uint)v.joints.x] * v.weights.x +
           bones[(uint)v.joints.y] * v.weights.y +
           bones[(uint)v.joints.z] * v.weights.z +
           bones[(uint)v.joints.w] * v.weights.w;
  Varying o;
  const float4 world = mul(model, mul(skin, float4(v.position, 1)));
  o.position = mul(viewProjection, world);
  o.world = world.xyz;
  o.normal = transformedNormal(mul(model, skin), v.normal);
  o.uv = v.uv;
  return o;
}
float3 directLight(float3 n, float3 view, float3 light, float3 albedo,
                   float metallic, float roughness, float specularScale) {
  const float3 halfway = normalize(view + light);
  const float nl = max(dot(n, light), 0.0);
  const float nv = max(dot(n, view), .001);
  const float nh = max(dot(n, halfway), 0.0);
  const float vh = max(dot(view, halfway), 0.0);
  const float a2 = pow(roughness, 4.0);
  const float denominator = nh * nh * (a2 - 1.0) + 1.0;
  const float distribution = a2 / max(3.14159265 * denominator * denominator, .0001);
  const float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
  const float geometry = (nv / (nv * (1.0 - k) + k)) *
                         (nl / max(nl * (1.0 - k) + k, .001));
  const float3 f0 = lerp(float3(.04, .04, .04), albedo, metallic);
  const float3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
  const float3 diffuse = (1.0 - fresnel) * (1.0 - metallic) * albedo / 3.14159265;
  const float3 specular = distribution * geometry * fresnel / max(4.0 * nv * nl, .001);
  return (diffuse + specular * specularScale) * nl;
}
struct Surface { float4 color : SV_TARGET0; float4 emission : SV_TARGET1; };
Surface psMain(Varying v) {
  if (display.x > .5 && display.x < 1.5) {
    const float3 pixels = ambientScreen(v.uv, display.y, display.z);
    Surface screen;
    screen.color = float4(pixels, 1);
    screen.emission = float4(pixels, 1);
    return screen;
  }
  float4 albedo = baseTexture.Sample(linearSampler, v.uv) * baseColor;
  if (params.y > .5 && params.y < 1.5)
    clip(albedo.a - params.z);
  float3 n = normalize(v.normal);
  const float3 view = normalize(camera.xyz - v.world);
  const float4 mr = materialTexture.Sample(linearSampler, v.uv);
  const float metallic = saturate(mr.b * emissive.w);
  const float roughness = clamp(mr.g * params.w, .08, 1.0);
  const float hemi = .055 + .075 * max(n.y, 0.0);
  float contact = 1.0;
  if (v.world.y < .12 && n.y > .65) {
    for (uint i = 0; i < 9; ++i) {
      const float4 foot = contacts[i];
      if (foot.w > 0.0) {
        const float2 delta = (v.world.xz - foot.xz) / foot.w;
        contact *= 1.0 - .35 * exp(-dot(delta, delta) * 2.0);
      }
    }
  }
  float3 color = albedo.rgb * (hemi * (1.0 - metallic) + .04 * metallic) * contact;
  color += directLight(n, view, normalize(float3(-.4, .85, -.3)), albedo.rgb, metallic, roughness, 1.0) * .7;
  color += directLight(n, view, normalize(float3(.6, .4, .6)), albedo.rgb, metallic, roughness, 1.0) * float3(.16, .18, .25);
  for (uint i = 0; i < 16; ++i) {
    const OfficeLight light = lights[i];
    const float3 delta = light.position.xyz - v.world;
    const float d2 = max(dot(delta, delta), .09);
    const float d = sqrt(d2);
    const float3 direction = delta / d;
    float attenuation = pow(max(1.0 - pow(d / light.position.w, 4.0), 0.0), 2.0) / d2;
    if (light.direction.w > .5)
      attenuation *= smoothstep(.45, .92, dot(-direction, light.direction.xyz));
    else
      attenuation *= smoothstep(.35, .7, v.world.y);
    color += directLight(n, view, direction, albedo.rgb, metallic, roughness,
                         light.direction.w > .5 ? .25 : .2) * light.color.rgb * light.color.w * attenuation;
  }
  const float3 emitted = emissionTexture.Sample(linearSampler, v.uv).rgb * emissive.rgb;
  Surface result;
  result.color = float4(max(color + emitted, 0.0), albedo.a);
  result.emission = float4(max(emitted, 0.0), albedo.a);
  return result;
}

struct PostVarying { float4 position : SV_POSITION; };
PostVarying postVertex(uint id : SV_VertexID) {
  const float2 uv = float2((id << 1) & 2, id & 2);
  PostVarying result;
  result.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
  return result;
}
float4 bloomDownsample(PostVarying v) : SV_TARGET {
  uint sourceWidth, sourceHeight;
  baseTexture.GetDimensions(sourceWidth, sourceHeight);
  const float2 uv = v.position.xy / outputSize;
  const float2 texel = 1.0 / float2(sourceWidth, sourceHeight);
  float3 value = 0;
  for (int y = -1; y <= 1; y += 2)
    for (int x = -1; x <= 1; x += 2)
      value += baseTexture.SampleLevel(postSampler, uv + float2(x, y) * texel * .5, 0).rgb * .25;
  const float brightness = max(value.r, max(value.g, value.b));
  float knee = saturate(brightness - .5);
  knee = knee * knee * .5;
  value *= max(brightness - 1.0, knee) / max(brightness, .0001);
  return float4(min(value, 8.0), 1);
}
float4 bloomBlur(PostVarying v) : SV_TARGET {
  uint sourceWidth, sourceHeight;
  baseTexture.GetDimensions(sourceWidth, sourceHeight);
  const float2 uv = v.position.xy / outputSize;
  const float2 step = blurDirection / float2(sourceWidth, sourceHeight);
  float3 value = baseTexture.SampleLevel(postSampler, uv, 0).rgb * .227027;
  value += (baseTexture.SampleLevel(postSampler, uv + step * 1.384615, 0).rgb + baseTexture.SampleLevel(postSampler, uv - step * 1.384615, 0).rgb) * .316216;
  value += (baseTexture.SampleLevel(postSampler, uv + step * 3.230769, 0).rgb + baseTexture.SampleLevel(postSampler, uv - step * 3.230769, 0).rgb) * .070270;
  return float4(value, 1);
}
float3 acesDisplay(float3 x) {
  x *= 1.08;
  return saturate((x * (2.51 * x + .03)) / (x * (2.43 * x + .59) + .14));
}
float4 officeComposite(PostVarying v) : SV_TARGET {
  const float2 uv = v.position.xy / outputSize;
  const float3 linearColor = baseTexture.Load(int3(uint2(v.position.xy), 0)).rgb + emissionTexture.SampleLevel(postSampler, uv, 0).rgb * .24;
  const float3 mapped = acesDisplay(linearColor);
  const float3 encoded = float3(
      mapped.r <= .0031308 ? mapped.r * 12.92 : 1.055 * pow(mapped.r, 1.0 / 2.4) - .055,
      mapped.g <= .0031308 ? mapped.g * 12.92 : 1.055 * pow(mapped.g, 1.0 / 2.4) - .055,
      mapped.b <= .0031308 ? mapped.b * 12.92 : 1.055 * pow(mapped.b, 1.0 / 2.4) - .055);
  const float noise = frac(sin(dot(floor(v.position.xy), float2(12.9898, 78.233))) * 43758.5453) - .5;
  return float4(saturate(encoded + noise / 255.0), 1);
}
