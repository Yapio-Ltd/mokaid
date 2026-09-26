#pragma once
#include "math.hpp"
#include <span>

namespace mokaid::engine {
struct OfficeCamera {
  Mat4 viewProjection;
  Vec3 position;
};
// Fit the complete authored room at the reference isometric angle. A fixed
// distance cropped desks when the viewport became narrow beside the chat panel.
inline OfficeCamera frameOffice(Vec3 min, Vec3 max, float aspect) {
  aspect = std::max(.2F, aspect);
  const Vec3 target{(min.x + max.x) * .5F, (min.y + max.y) * .5F,
                    (min.z + max.z) * .5F};
  // The wide desktop viewport needs a shallower elevation. Restore the more
  // overhead view beside chat so the room retains useful depth in a narrow pane.
  const float wide = std::clamp((aspect - 1.45F) / .65F, 0.F, 1.F);
  // Move the viewpoint five degrees to its left around the room center.
  const Vec3 back = normalized({8.423F, 7.32F - 2.10F * wide, -13.020F});
  const Vec3 right = normalized(cross({0, 1, 0}, back));
  const Vec3 up = cross(back, right);
  // A wider lens brings the camera physically closer while fitting the room,
  // giving the foreground desks more depth in the full office view.
  const float fov = .5F + .20F * wide;
  const float tangent = std::tan(fov * .5F);
  float distance = 1;
  for (int corner = 0; corner < 8; ++corner) {
    const Vec3 p{corner & 1 ? max.x : min.x, corner & 2 ? max.y : min.y,
                 corner & 4 ? max.z : min.z};
    const Vec3 relative = p - target;
    const float depth = dot(relative, back);
    distance = std::max(distance, depth + std::max(
        std::abs(dot(relative, right)) / (tangent * aspect * .94F),
        std::abs(dot(relative, up)) / (tangent * .94F)));
  }
  const Vec3 position = target + back * distance;
  return {perspective(fov, aspect, .1F, std::max(200.F, distance + 50.F)) *
              lookAt(position, target), position};
}

inline OfficeCamera fitOfficeGeometry(OfficeCamera camera, std::span<const Vec3> points,
                                     float aspect) {
  if (points.empty()) return camera;
  float minX = 1, maxX = -1, minY = 1, maxY = -1;
  for (const auto point : points) {
    const auto p = transform(camera.viewProjection, {point.x, point.y, point.z, 1});
    if (p.w <= 0) continue;
    minX = std::min(minX, p.x / p.w); maxX = std::max(maxX, p.x / p.w);
    minY = std::min(minY, p.y / p.w); maxY = std::max(maxY, p.y / p.w);
  }
  const float wide = std::clamp((aspect - 1.45F) / .65F, 0.F, 1.F);
  // Keep the authored office dominant while showing the connected circulation
  // and adjacent workspaces at its perimeter. Only the overview uses this fit;
  // the immersive camera retains its human-height field of view.
  const float span = (2.135F + .325F * wide) * .80F;
  const float scale = span / std::max({maxX - minX, maxY - minY, .01F});
  const float cx = (minX + maxX) * .5F, cy = (minY + maxY) * .5F;
  const float horizontalOffset = .05F * wide;
  for (int c = 0; c < 4; ++c) {
    camera.viewProjection.m[c * 4] = scale * (camera.viewProjection.m[c * 4] - cx * camera.viewProjection.m[c * 4 + 3])
        + horizontalOffset * camera.viewProjection.m[c * 4 + 3];
    camera.viewProjection.m[c * 4 + 1] = scale * (camera.viewProjection.m[c * 4 + 1] - cy * camera.viewProjection.m[c * 4 + 3]);
  }
  return camera;
}
} // namespace mokaid::engine
