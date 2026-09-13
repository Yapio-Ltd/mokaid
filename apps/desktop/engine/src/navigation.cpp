#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <mokaid/engine/navigation.hpp>
#include <queue>

namespace mokaid::engine {
namespace {
constexpr float cell = .15F, minX = -7.3F, minZ = -6.35F;
constexpr int cols = 96, rows = 85, total = cols * rows;
Vec3 point(int index) {
  return {minX + static_cast<float>(index % cols) * cell, 0,
          minZ + static_cast<float>(index / cols) * cell};
}
int index(Vec3 p) {
  return std::clamp(static_cast<int>(std::round((p.x - minX) / cell)), 0,
                    cols - 1) +
         std::clamp(static_cast<int>(std::round((p.z - minZ) / cell)), 0,
                    rows - 1) *
             cols;
}
template <class T> T read(std::ifstream &f) {
  T v{};
  if (!f.read(reinterpret_cast<char *>(&v), sizeof v))
    throw std::runtime_error("Truncated navigation pack");
  return v;
}
std::uint32_t count(std::ifstream &f, std::uint32_t limit) {
  const auto v = read<std::uint32_t>(f);
  if (v > limit)
    throw std::runtime_error("Invalid navigation count");
  return v;
}
} // namespace
Navigation Navigation::load(const std::filesystem::path &p) {
  std::ifstream f(p, std::ios::binary);
  char magic[8]{};
  if (!f.read(magic, 8) || std::memcmp(magic, "MOKANAV1", 8))
    throw std::runtime_error("Invalid navigation pack");
  Navigation nav;
  nav.obstacles_.resize(count(f, 10000));
  for (auto &b : nav.obstacles_)
    b = read<Box>(f);
  nav.anchors_.resize(count(f, 10000));
  for (auto &a : nav.anchors_) {
    a.x = read<float>(f);
    a.z = read<float>(f);
  }
  nav.lanes_.resize(count(f, 128));
  for (auto &lane : nav.lanes_) {
    lane.resize(count(f, 1000));
    for (auto &i : lane) {
      i = read<std::uint32_t>(f);
      if (i >= nav.anchors_.size())
        throw std::runtime_error("Navigation anchor out of bounds");
    }
  }
  nav.grid_.resize(total);
  for (int i = 0; i < total; ++i)
    nav.grid_[i] = nav.walkable(point(i));
  return nav;
}
bool Navigation::walkable(Vec3 p) const {
  if (p.x < minX + .35F || p.x > 6.95F - .35F || p.z < minZ + .35F ||
      p.z > 6.35F - .35F)
    return false;
  for (const auto &b : obstacles_) {
    const float inset =
        std::min(b.maxX - b.minX, b.maxZ - b.minZ) < .12F ? 0.F : .14F;
    const float loX = b.minX + inset, hiX = b.maxX - inset,
                loZ = b.minZ + inset, hiZ = b.maxZ - inset;
    if (hiX <= loX + .04F || hiZ <= loZ + .04F)
      continue;
    const float dx = std::max({loX - p.x, 0.F, p.x - hiX}),
                dz = std::max({loZ - p.z, 0.F, p.z - hiZ});
    if (dx * dx + dz * dz < .35F * .35F)
      return false;
  }
  return true;
}
Vec3 Navigation::nearest(Vec3 p) const {
  float best = std::numeric_limits<float>::max();
  Vec3 result = p;
  for (int i = 0; i < total; ++i) {
    const auto v = point(i);
    const auto d = dot(v - p, v - p);
    if (d < best && (grid_.empty() ? walkable(v) : grid_[i])) {
      best = d;
      result = v;
    }
  }
  return result;
}
Vec3 Navigation::waypoint(std::size_t seat, std::size_t n) const {
  if (empty())
    return {};
  const auto &lane = lanes_[seat % lanes_.size()];
  return lane.empty() ? anchors_.front() : anchors_[lane[n % lane.size()]];
}
std::vector<Vec3> Navigation::route(Vec3 start, Vec3 goal) const {
  start = nearest(start);
  goal = nearest(goal);
  const int first = index(start), last = index(goal);
  std::vector<float> distance(total, std::numeric_limits<float>::max());
  std::vector<int> parent(total, -1);
  std::vector<bool> closed(total, false);
  using Entry = std::pair<float, int>;
  std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> open;
  distance[first] = 0;
  open.emplace(0, first);
  while (!open.empty()) {
    const int current = open.top().second;
    open.pop();
    if (closed[current])
      continue;
    closed[current] = true;
    if (current == last)
      break;
    const int x = current % cols, z = current / cols;
    for (int dz = -1; dz <= 1; ++dz)
      for (int dx = -1; dx <= 1; ++dx) {
        if ((!dx && !dz) || x + dx < 0 || x + dx >= cols || z + dz < 0 ||
            z + dz >= rows)
          continue;
        const int next = current + dx + dz * cols;
        if (closed[next] || !grid_[next])
          continue;
        if (dx && dz && (!grid_[current + dx] || !grid_[current + dz * cols]))
          continue;
        const float cost =
            distance[current] + (dx && dz ? 1.41421356F : 1.F) * cell;
        if (cost >= distance[next])
          continue;
        distance[next] = cost;
        parent[next] = current;
        open.emplace(cost + length(point(next) - goal), next);
      }
  }
  if (first != last && parent[last] < 0)
    return {};
  std::vector<Vec3> path;
  for (int i = last; i >= 0; i = parent[i]) {
    path.push_back(point(i));
    if (i == first)
      break;
  }
  std::reverse(path.begin(), path.end());
  return path;
}
} // namespace mokaid::engine
