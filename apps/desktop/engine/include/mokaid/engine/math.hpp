#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>

namespace mokaid::engine {
struct Vec3 {
  float x{}, y{}, z{};
};
struct Vec4 {
  float x{}, y{}, z{}, w{};
};
inline Vec3 operator+(Vec3 a, Vec3 b) {
  return {a.x + b.x, a.y + b.y, a.z + b.z};
}
inline Vec3 operator-(Vec3 a, Vec3 b) {
  return {a.x - b.x, a.y - b.y, a.z - b.z};
}
inline Vec3 operator*(Vec3 a, float b) { return {a.x * b, a.y * b, a.z * b}; }
inline float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 cross(Vec3 a, Vec3 b) {
  return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline float length(Vec3 v) { return std::sqrt(dot(v, v)); }
inline Vec3 normalized(Vec3 v) {
  const float n = length(v);
  return n > 1e-8F ? v * (1 / n) : Vec3{0, 1, 0};
}
inline Vec4 slerp(Vec4 a, Vec4 b, float t) {
  float d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
  if (d < 0) {
    b = {-b.x, -b.y, -b.z, -b.w};
    d = -d;
  }
  float u = 1 - t, v = t;
  if (d < 0.9995F) {
    const float angle = std::acos(std::clamp(d, -1.F, 1.F));
    u = std::sin((1 - t) * angle) / std::sin(angle);
    v = std::sin(t * angle) / std::sin(angle);
  }
  Vec4 q{a.x * u + b.x * v, a.y * u + b.y * v, a.z * u + b.z * v,
         a.w * u + b.w * v};
  const float n = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  return n > 1e-8F ? Vec4{q.x / n, q.y / n, q.z / n, q.w / n}
                   : Vec4{0, 0, 0, 1};
}
struct Mat4 {
  std::array<float, 16> m{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
  static Mat4 identity() { return {}; }
};
inline Mat4 operator*(const Mat4 &a, const Mat4 &b) {
  Mat4 c;
  c.m.fill(0);
  for (int j = 0; j < 4; ++j)
    for (int i = 0; i < 4; ++i)
      for (int k = 0; k < 4; ++k)
        c.m[j * 4 + i] += a.m[k * 4 + i] * b.m[j * 4 + k];
  return c;
}
inline Vec4 transform(const Mat4 &m, Vec4 v) {
  return {m.m[0] * v.x + m.m[4] * v.y + m.m[8] * v.z + m.m[12] * v.w,
          m.m[1] * v.x + m.m[5] * v.y + m.m[9] * v.z + m.m[13] * v.w,
          m.m[2] * v.x + m.m[6] * v.y + m.m[10] * v.z + m.m[14] * v.w,
          m.m[3] * v.x + m.m[7] * v.y + m.m[11] * v.z + m.m[15] * v.w};
}
inline Mat4 trs(Vec3 t, Vec4 q = {0, 0, 0, 1}, Vec3 s = {1, 1, 1}) {
  const float x = q.x, y = q.y, z = q.z, w = q.w;
  return {{{(1 - 2 * y * y - 2 * z * z) * s.x, (2 * x * y + 2 * w * z) * s.x,
            (2 * x * z - 2 * w * y) * s.x, 0, (2 * x * y - 2 * w * z) * s.y,
            (1 - 2 * x * x - 2 * z * z) * s.y, (2 * y * z + 2 * w * x) * s.y, 0,
            (2 * x * z + 2 * w * y) * s.z, (2 * y * z - 2 * w * x) * s.z,
            (1 - 2 * x * x - 2 * y * y) * s.z, 0, t.x, t.y, t.z, 1}}};
}
inline Mat4 inverse(const Mat4 &a) {
  float b[4][8]{};
  for (int r = 0; r < 4; ++r)
    for (int c = 0; c < 4; ++c) {
      b[r][c] = a.m[c * 4 + r];
      b[r][c + 4] = (r == c ? 1.F : 0.F);
    }
  for (int c = 0; c < 4; ++c) {
    int p = c;
    for (int r = c + 1; r < 4; ++r)
      if (std::abs(b[r][c]) > std::abs(b[p][c]))
        p = r;
    if (std::abs(b[p][c]) < 1e-10F)
      throw std::runtime_error("Singular scene transform");
    if (p != c)
      for (int k = 0; k < 8; ++k)
        std::swap(b[p][k], b[c][k]);
    const float d = b[c][c];
    for (float &v : b[c])
      v /= d;
    for (int r = 0; r < 4; ++r)
      if (r != c) {
        const float f = b[r][c];
        for (int k = 0; k < 8; ++k)
          b[r][k] -= f * b[c][k];
      }
  }
  Mat4 result;
  for (int r = 0; r < 4; ++r)
    for (int c = 0; c < 4; ++c)
      result.m[c * 4 + r] = b[r][c + 4];
  return result;
}
inline Mat4 lookAt(Vec3 eye, Vec3 target) {
  const auto z = normalized(eye - target), x = normalized(cross({0, 1, 0}, z)),
             y = cross(z, x);
  return {{{x.x, y.x, z.x, 0, x.y, y.y, z.y, 0, x.z, y.z, z.z, 0, -dot(x, eye),
            -dot(y, eye), -dot(z, eye), 1}}};
}
// Right handed camera, depth [0,1] shared by Metal and Direct3D.
inline Mat4 perspective(float fov, float aspect, float nearPlane = .1F,
                        float farPlane = 500.F) {
  const float f = 1 / std::tan(fov * .5F);
  Mat4 p;
  p.m.fill(0);
  p.m[0] = f / aspect;
  p.m[5] = f;
  p.m[10] = farPlane / (nearPlane - farPlane);
  p.m[11] = -1;
  p.m[14] = nearPlane * farPlane / (nearPlane - farPlane);
  return p;
}
} // namespace mokaid::engine
