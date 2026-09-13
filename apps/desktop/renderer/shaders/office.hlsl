cbuffer Draw : register(b0) {
  column_major float4x4 viewProjection;
  column_major float4x4 model;
  float4 baseColor;
  float4 emissive;
  float4 camera;
  float4 params;
};
cbuffer Skin : register(b1) { column_major float4x4 bones[128]; };
Texture2D<float4> baseTexture : register(t0);
Texture2D<float4> emissionTexture : register(t1);
Texture2D<float4> materialTexture : register(t2);
SamplerState linearSampler : register(s0);
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
                   float metallic, float roughness) {
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
  return (diffuse + specular) * nl;
}
float4 psMain(Varying v) : SV_TARGET {
  float4 albedo = baseTexture.Sample(linearSampler, v.uv) * baseColor;
  if (params.y > .5 && params.y < 1.5)
    clip(albedo.a - params.z);
  float3 n = normalize(v.normal);
  const float3 view = normalize(camera.xyz - v.world);
  const float4 mr = materialTexture.Sample(linearSampler, v.uv);
  const float metallic = saturate(mr.b * emissive.w);
  const float roughness = clamp(mr.g * params.w, .08, 1.0);
  const float hemi = .20 + .12 * max(n.y, 0.0);
  float3 color = albedo.rgb * (hemi * (1.0 - metallic) + .055 * metallic);
  color += directLight(n, view, normalize(float3(-.4, .85, -.3)), albedo.rgb, metallic, roughness) * 2.4;
  color += directLight(n, view, normalize(float3(.6, .4, .6)), albedo.rgb, metallic, roughness) * .7;
  color += emissionTexture.Sample(linearSampler, v.uv).rgb * emissive.rgb;
  color = color / (1 + color * .22);
  return float4(pow(max(color, 0), 1 / 2.2), albedo.a);
}
