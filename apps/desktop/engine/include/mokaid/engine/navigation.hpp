#pragma once
#include "math.hpp"
#include <cstdint>
#include <filesystem>
#include <vector>

namespace mokaid::engine {
class Navigation {
  struct Box {
    float minX, maxX, minZ, maxZ;
  };
  std::vector<Box> obstacles_;
  std::vector<Vec3> anchors_;
  std::vector<std::vector<std::uint32_t>> lanes_;
  std::vector<bool> grid_;

public:
  static Navigation load(const std::filesystem::path &);
  bool walkable(Vec3) const;
  Vec3 nearest(Vec3) const;
  std::vector<Vec3> route(Vec3 start, Vec3 goal) const;
  Vec3 waypoint(std::size_t seat, std::size_t index) const;
  bool empty() const { return anchors_.empty() || lanes_.empty(); }
};
} // namespace mokaid::engine
