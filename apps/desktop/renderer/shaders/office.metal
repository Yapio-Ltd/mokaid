#include <metal_stdlib>
using namespace metal;
struct Vertex {
  packed_float3 position;
  packed_float3 normal;
  packed_float2 uv;
  float4 joints;
  float4 weights;
};
struct Uniforms {
  float4x4 viewProjection;
  float4x4 model;
  float4 color;
  float4 emissive;
  float4 camera;
  float4 params;
};
struct Varying {
  float4 position [[position]];
  float3 world;
  float3 normal;
  float2 uv;
};
float3 transformedNormal(float4x4 matrix, float3 normal) {
  const float3 x = matrix[0].xyz, y = matrix[1].xyz, z = matrix[2].xyz;
  const float3 cofactorX = cross(y, z), cofactorY = cross(z, x), cofactorZ = cross(x, y);
  const float determinant = dot(x, cofactorX);
  if (abs(determinant) < 1e-10)
    return float3(0, 1, 0);
  return normalize((cofactorX * normal.x + cofactorY * normal.y + cofactorZ * normal.z) / determinant);
}
vertex Varying officeVertex(uint id [[vertex_id]],
                            device const Vertex *vertices [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]],
                            constant float4x4 *bones [[buffer(2)]]) {
  Vertex v = vertices[id];
  float4x4 skin = float4x4(1);
  if (u.params.x > 0.5)
    skin = bones[uint(v.joints.x)] * v.weights.x +
           bones[uint(v.joints.y)] * v.weights.y +
           bones[uint(v.joints.z)] * v.weights.z +
           bones[uint(v.joints.w)] * v.weights.w;
  const float4 world = u.model * skin * float4(v.position, 1);
  Varying o;
  o.position = u.viewProjection * world;
  o.world = world.xyz;
  o.normal = transformedNormal(u.model * skin, v.normal);
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
  const float distribution = a2 / max(M_PI_F * denominator * denominator, .0001);
  const float k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
  const float geometry = (nv / (nv * (1.0 - k) + k)) *
                         (nl / max(nl * (1.0 - k) + k, .001));
  const float3 f0 = mix(float3(.04), albedo, metallic);
  const float3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
  const float3 diffuse = (1.0 - fresnel) * (1.0 - metallic) * albedo / M_PI_F;
  const float3 specular = distribution * geometry * fresnel / max(4.0 * nv * nl, .001);
  return (diffuse + specular) * nl;
}
fragment float4 officeFragment(Varying v [[stage_in]],
                               constant Uniforms &u [[buffer(1)]],
                               texture2d<float> base [[texture(0)]],
                               texture2d<float> emission [[texture(1)]],
                               texture2d<float> material [[texture(2)]],
                               sampler sampleState [[sampler(0)]]) {
  float4 albedo = base.sample(sampleState, v.uv) * u.color;
  if (u.params.y > 0.5 && u.params.y < 1.5 && albedo.a < u.params.z)
    discard_fragment();
  const float3 n = normalize(v.normal);
  const float3 view = normalize(u.camera.xyz - v.world);
  const float4 mr = material.sample(sampleState, v.uv);
  const float metallic = clamp(mr.b * u.emissive.w, 0.0, 1.0);
  const float roughness = clamp(mr.g * u.params.w, .08, 1.0);
  const float hemi = .20 + .12 * max(n.y, 0.0);
  // Until the authored environment is cooked, use a bounded neutral indirect
  // term. Metals reflect it instead of receiving an incorrect Lambert diffuse.
  float3 color = albedo.rgb * (hemi * (1.0 - metallic) + .055 * metallic);
  color += directLight(n, view, normalize(float3(-.4, .85, -.3)), albedo.rgb, metallic, roughness) * 2.4;
  color += directLight(n, view, normalize(float3(.6, .4, .6)), albedo.rgb, metallic, roughness) * .7;
  color += emission.sample(sampleState, v.uv).rgb * u.emissive.xyz;
  // Qt's standard 2D composition consumes gamma-encoded RGBA8, so encode here.
  color = color / (1.0 + color * .22);
  return float4(pow(max(color, 0.0), float3(1.0 / 2.2)), albedo.a);
}
