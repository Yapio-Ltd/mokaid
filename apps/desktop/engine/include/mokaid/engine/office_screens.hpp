#pragma once
#include "office.hpp"
#include <limits>

namespace mokaid::engine {
// The nine explicitly authored display faces are bound spatially to stable
// physical seats, never to roster order or a material's incidental glTF index.
inline int officeScreenSeat(const Mesh& mesh, const Mat4& world) {
  if (mesh.vertices.empty()) return -1;
  Vec3 center{};
  for (const auto& vertex : mesh.vertices) center = center + vertex.position;
  center = center * (1.F / static_cast<float>(mesh.vertices.size()));
  const auto position = transform(world, {center.x, center.y, center.z, 1});
  float nearest = 2.25F;
  int result = -1;
  for (std::size_t i = 0; i < seats.size(); ++i) {
    const auto dx = position.x - seats[i].x, dz = position.z - seats[i].z;
    const auto distance = dx * dx + dz * dz;
    if (distance < nearest) { nearest = distance; result = static_cast<int>(i); }
  }
  return result;
}
}
