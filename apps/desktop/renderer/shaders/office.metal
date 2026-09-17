#include <metal_stdlib>
using namespace metal;
#include "screen_content.h"
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
  float4 display;
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
                   float metallic, float roughness, float specularScale) {
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
  return (diffuse + specular * specularScale) * nl;
}
struct OfficeLight { float4 position, color, direction; };
struct OfficeLighting { OfficeLight lights[16]; float4 contacts[9]; };
struct Surface { float4 color [[color(0)]]; float4 emission [[color(1)]]; };
fragment Surface officeFragment(Varying v [[stage_in]],
                               constant Uniforms &u [[buffer(1)]],
                               texture2d<float> base [[texture(0)]],
                               texture2d<float> emission [[texture(1)]],
                               texture2d<float> material [[texture(2)]],
                               sampler sampleState [[sampler(0)]],
                               constant OfficeLighting &lighting [[buffer(3)]]) {
  if (u.display.x > .5 && u.display.x < 1.5) {
    const float3 pixels = ambientScreen(v.uv, u.display.y, u.display.z);
    Surface screen;
    screen.color = float4(pixels, 1);
    screen.emission = float4(pixels, 1);
    return screen;
  }
  float4 albedo = base.sample(sampleState, v.uv) * u.color;
  if (u.params.y > 0.5 && u.params.y < 1.5 && albedo.a < u.params.z)
    discard_fragment();
  const float3 n = normalize(v.normal);
  const float3 view = normalize(u.camera.xyz - v.world);
  const float4 mr = material.sample(sampleState, v.uv);
  const float metallic = clamp(mr.b * u.emissive.w, 0.0, 1.0);
  const float roughness = clamp(mr.g * u.params.w, .08, 1.0);
  const float hemi = .055 + .075 * max(n.y, 0.0);
  float contact = 1.0;
  // Bounded soft floor contact below each body. No dark disks on desktops.
  if (v.world.y < .12 && n.y > .65) {
    for (uint i = 0; i < 9; ++i) {
      const float4 foot = lighting.contacts[i];
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
    const OfficeLight light = lighting.lights[i];
    const float3 delta = light.position.xyz - v.world;
    const float d2 = max(dot(delta, delta), .09);
    const float d = sqrt(d2);
    const float3 direction = delta / d;
    float attenuation = pow(max(1.0 - pow(d / light.position.w, 4.0), 0.0), 2.0) / d2;
    if (light.direction.w > .5)
      attenuation *= smoothstep(.45, .92, dot(-direction, light.direction.xyz));
    else
      // Lamp pools stay above the desk surface; prevent light leaking through it.
      attenuation *= smoothstep(.35, .7, v.world.y);
    color += directLight(n, view, direction, albedo.rgb, metallic, roughness,
                         light.direction.w > .5 ? .25 : .2) * light.color.rgb * light.color.w * attenuation;
  }
  const float3 emitted = emission.sample(sampleState, v.uv).rgb * u.emissive.xyz;
  Surface result;
  result.color = float4(max(color + emitted, 0.0), albedo.a);
  // A separate emission target keeps white walls, paper and skin out of bloom.
  result.emission = float4(max(emitted, 0.0), albedo.a);
  return result;
}

kernel void bloomDownsample(texture2d<float, access::sample> source [[texture(0)]],
                            texture2d<float, access::write> target [[texture(1)]],
                            uint2 id [[thread_position_in_grid]]) {
  if (id.x >= target.get_width() || id.y >= target.get_height()) return;
  constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
  const float2 uv = (float2(id) + .5) / float2(target.get_width(), target.get_height());
  const float2 texel = 1.0 / float2(source.get_width(), source.get_height());
  float3 value = float3(0);
  for (int y = -1; y <= 1; y += 2)
    for (int x = -1; x <= 1; x += 2)
      value += source.sample(linearClamp, uv + float2(x, y) * texel * .5).rgb * .25;
  const float brightness = max(value.r, max(value.g, value.b));
  float knee = clamp(brightness - .5, 0.0, 1.0);
  knee = knee * knee * .5;
  value *= max(brightness - 1.0, knee) / max(brightness, .0001);
  target.write(float4(min(value, float3(8)), 1), id);
}
kernel void bloomBlur(texture2d<float, access::sample> source [[texture(0)]],
                       texture2d<float, access::write> target [[texture(1)]],
                       constant float2 &direction [[buffer(0)]],
                       uint2 id [[thread_position_in_grid]]) {
  if (id.x >= target.get_width() || id.y >= target.get_height()) return;
  constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
  const float2 uv = (float2(id) + .5) / float2(target.get_width(), target.get_height());
  const float2 step = direction / float2(source.get_width(), source.get_height());
  float3 value = source.sample(linearClamp, uv).rgb * .227027;
  value += (source.sample(linearClamp, uv + step * 1.384615).rgb + source.sample(linearClamp, uv - step * 1.384615).rgb) * .316216;
  value += (source.sample(linearClamp, uv + step * 3.230769).rgb + source.sample(linearClamp, uv - step * 3.230769).rgb) * .070270;
  target.write(float4(value, 1), id);
}
float3 acesDisplay(float3 x) {
  x *= 1.08;
  return clamp((x * (2.51 * x + .03)) / (x * (2.43 * x + .59) + .14), 0.0, 1.0);
}
kernel void officeComposite(texture2d<float, access::read> source [[texture(0)]],
                             texture2d<float, access::sample> bloom [[texture(1)]],
                             texture2d<float, access::write> target [[texture(2)]],
                             uint2 id [[thread_position_in_grid]]) {
  if (id.x >= target.get_width() || id.y >= target.get_height()) return;
  constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
  const float2 uv = (float2(id) + .5) / float2(target.get_width(), target.get_height());
  float3 linear = source.read(id).rgb + bloom.sample(linearClamp, uv).rgb * .24;
  float3 mapped = acesDisplay(linear);
  // Exact sRGB transfer: the shared Qt surface is gamma-encoded RGBA8.
  float3 encoded = select(1.055 * pow(mapped, float3(1.0 / 2.4)) - .055, mapped * 12.92, mapped <= .0031308);
  const float noise = fract(sin(dot(float2(id), float2(12.9898, 78.233))) * 43758.5453) - .5;
  target.write(float4(clamp(encoded + noise / 255.0, 0.0, 1.0), 1), id);
}
