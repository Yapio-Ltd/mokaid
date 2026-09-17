#pragma once
#include "math.hpp"
#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace mokaid::engine {
class Navigation {
public:
  struct Box {
    float minX, maxX, minZ, maxZ;
  };
  struct Disc {
    Vec3 center;
    float radius{.30F};
  };
  struct ActivitySocket {
    std::string id;
    std::uint32_t kind{}; // desk=0, sofa=1, coffee=2, foosball=3, chat=4.
    Vec3 position, approach;
    float yaw{}, seatHeight{}, holdSeconds{};
    std::int32_t chairNode{-1};
    float pullback{};
    Vec3 chairLocalDelta{};
  };
  struct FloorSurface {
    Box bounds;
    float height{};
  };

private:
  std::vector<Box> obstacles_;
  std::vector<Vec3> anchors_;
  std::vector<std::vector<std::uint32_t>> lanes_;
  std::vector<bool> grid_;
  std::vector<bool> grid35_;
  std::vector<ActivitySocket> sockets_;
  std::vector<FloorSurface> floors_;
  Box bounds_{-7.3F, 6.95F, -6.35F, 6.35F};
  int columns_{}, rows_{};
  bool officeFootprint_{};
  Vec3 gridPoint(int) const;
  bool gridWalkable(std::size_t, float radius) const;
  bool withinFootprint(Vec3, float radius) const;
  std::vector<bool> reachableGrid(std::span<const Vec3>, float radius,
                                  std::span<const Disc> blocked = {}) const;
  void buildGrid();

public:
  static Navigation load(const std::filesystem::path &);
  // Geometry supplied by tests or other scenes is already a collision hull.
  // Only load() applies the measured office furniture bounds correction.
  static Navigation fromGeometry(
      std::vector<Box> obstacles, std::vector<Vec3> anchors = {},
      std::vector<std::vector<std::uint32_t>> lanes = {},
      Box bounds = {-7.3F, 6.95F, -6.35F, 6.35F},
      std::vector<ActivitySocket> sockets = {},
      std::vector<FloorSurface> floors = {});
  bool walkable(Vec3, float radius = .30F) const;
  bool segmentWalkable(Vec3 start, Vec3 goal, float radius = .30F,
                       std::span<const Disc> blocked = {}) const;
  // Projection is explicit; route() never silently relocates either endpoint.
  Vec3 nearest(Vec3) const;
  std::optional<Vec3> nearestReachable(Vec3 desired, Vec3 from,
                                       float maxDistance = 1.5F,
                                       float radius = .30F) const;
  std::vector<Vec3> route(Vec3 start, Vec3 goal,
                          std::span<const Disc> blocked = {},
                          float radius = .30F) const;
  // Explicitly smooth ordinary walking routes; socket corridors stay authored.
  // Tangent circular arcs target cornerRadius and may shrink to .20 m. A tight
  // or obstructed corner remains unchanged. Every emitted chord clears the
  // full body/disc sweep, with arc chords <= .06 m and heading steps <= .10 rad.
  // Preserves exact endpoints; invalid or obstructed input returns no route.
  std::vector<Vec3> smoothRoute(std::span<const Vec3> path,
                                std::span<const Disc> blocked = {},
                                float radius = .30F,
                                float cornerRadius = .65F) const;
  // A seat may overlap its own chair. Short corridors handle that local hull
  // explicitly; unrelated furniture always blocks movement.
  bool socketSegmentWalkable(Vec3 socket, Vec3 approach,
                             float radius = .30F) const;
  bool socketSegmentWalkable(Vec3 socket, Vec3 entry, Vec3 start, Vec3 goal,
                             float radius = .30F,
                             std::optional<Vec3> ownerSocket = {}) const;
  // Entry is the authored feet-locked standing marker. The result begins at
  // that exact marker and exits the local chair/sofa hull into the aisle.
  // Explicit blocked discs constrain the entire local corridor. A moved owned
  // chair is added separately when checking connection to the ordinary aisle.
  std::vector<Vec3> socketRoute(Vec3 socket, Vec3 entry, Vec3 preferredDirection,
                                float radius = .30F,
                                std::optional<Vec3> ownerSocket = {},
                                std::span<const Disc> blocked = {}) const;
  std::optional<Vec3> socketApproach(Vec3 socket, Vec3 preferredDirection,
                                    float maxDistance = 1.5F,
                                    float radius = .30F) const;
  Vec3 waypoint(std::size_t seat, std::size_t index) const;
  std::span<const ActivitySocket> sockets() const { return sockets_; }
  float floorHeightAt(Vec3) const;
  bool empty() const { return grid_.empty(); }
};
} // namespace mokaid::engine
