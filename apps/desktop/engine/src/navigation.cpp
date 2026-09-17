#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <mokaid/engine/navigation.hpp>
#include <queue>
#include <unordered_set>

namespace mokaid::engine {
namespace {
constexpr float cell = .15F, defaultRadius = .30F;
constexpr float socketReach = 1.5F;
bool finite(Vec3 p) {
  return std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z);
}
bool validRadius(float radius) { return std::isfinite(radius) && radius >= 0; }
bool validBox(const Navigation::Box &b) {
  return std::isfinite(b.minX) && std::isfinite(b.maxX) &&
         std::isfinite(b.minZ) && std::isfinite(b.maxZ) && b.minX < b.maxX &&
         b.minZ < b.maxZ;
}
float distanceSquared(Vec3 a, Vec3 b) {
  const float x = a.x - b.x, z = a.z - b.z;
  return x * x + z * z;
}
float pointBoxDistanceSquared(Vec3 p, const Navigation::Box &b) {
  const float x = std::max({b.minX - p.x, 0.F, p.x - b.maxX}),
              z = std::max({b.minZ - p.z, 0.F, p.z - b.maxZ});
  return x * x + z * z;
}
float pointSegmentDistanceSquared(Vec3 p, Vec3 a, Vec3 b) {
  const float x = b.x - a.x, z = b.z - a.z, square = x * x + z * z;
  const float t = square > 1e-12F
                      ? std::clamp(((p.x - a.x) * x + (p.z - a.z) * z) / square,
                                   0.F, 1.F)
                      : 0.F;
  return distanceSquared(p, {a.x + x * t, 0, a.z + z * t});
}
bool segmentIntersectsBox(Vec3 a, Vec3 b, const Navigation::Box &box) {
  float first = 0, last = 1;
  const auto slab = [&](float origin, float delta, float lo, float hi) {
    if (std::abs(delta) < 1e-12F)
      return origin >= lo && origin <= hi;
    float near = (lo - origin) / delta, far = (hi - origin) / delta;
    if (near > far)
      std::swap(near, far);
    first = std::max(first, near);
    last = std::min(last, far);
    return first <= last;
  };
  return slab(a.x, b.x - a.x, box.minX, box.maxX) &&
         slab(a.z, b.z - a.z, box.minZ, box.maxZ);
}
float segmentBoxDistanceSquared(Vec3 a, Vec3 b, const Navigation::Box &box) {
  if (segmentIntersectsBox(a, b, box))
    return 0;
  float result = std::min(pointBoxDistanceSquared(a, box),
                          pointBoxDistanceSquared(b, box));
  for (const float x : {box.minX, box.maxX})
    for (const float z : {box.minZ, box.maxZ})
      result = std::min(result, pointSegmentDistanceSquared({x, 0, z}, a, b));
  return result;
}
bool clearsBox(Vec3 a, Vec3 b, const Navigation::Box &box, float radius) {
  // Most office furniture is nowhere near this sweep. Reject it before the
  // exact capsule/rectangle calculation, including rounded corner clearance.
  if (std::max(a.x, b.x) + radius < box.minX ||
      std::min(a.x, b.x) - radius > box.maxX ||
      std::max(a.z, b.z) + radius < box.minZ ||
      std::min(a.z, b.z) - radius > box.maxZ)
    return true;
  if (radius == 0)
    return !segmentIntersectsBox(a, b, box);
  return segmentBoxDistanceSquared(a, b, box) >= radius * radius;
}
bool insideBounds(Vec3 p, const Navigation::Box &box, float radius) {
  return p.x >= box.minX + radius && p.x <= box.maxX - radius &&
         p.z >= box.minZ + radius && p.z <= box.maxZ - radius;
}
bool clearsDiscs(Vec3 a, Vec3 b, float radius,
                 std::span<const Navigation::Disc> blocked) {
  for (const auto &disc : blocked) {
    if (!finite(disc.center) || !validRadius(disc.radius))
      return false;
    const float clearance = radius + disc.radius;
    if (pointSegmentDistanceSquared(disc.center, a, b) < clearance * clearance)
      return false;
  }
  return true;
}
// The signed distance to a convex rectangle is convex along a straight line.
// A nonnegative initial directional derivative therefore proves that the
// entire socket exit moves out of this existing overlap, never deeper into it.
bool leavesBox(Vec3 socket, Vec3 approach, const Navigation::Box &b) {
  const float dx = approach.x - socket.x, dz = approach.z - socket.z;
  const float nx = socket.x - std::clamp(socket.x, b.minX, b.maxX),
              nz = socket.z - std::clamp(socket.z, b.minZ, b.maxZ);
  if (nx != 0 || nz != 0)
    return nx * dx + nz * dz >= -1e-7F;
  const float distances[] = {socket.x - b.minX, b.maxX - socket.x,
                             socket.z - b.minZ, b.maxZ - socket.z};
  const float slopes[] = {-dx, dx, -dz, dz};
  const float nearest = *std::min_element(std::begin(distances), std::end(distances));
  for (int face = 0; face < 4; ++face)
    if (distances[face] <= nearest + 1e-6F && slopes[face] >= 0)
      return true;
  return false;
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
std::string readString(std::ifstream &f) {
  std::string value(count(f, 128), '\0');
  if (!f.read(value.data(), static_cast<std::streamsize>(value.size())))
    throw std::runtime_error("Truncated navigation socket id");
  return value;
}
} // namespace

Navigation Navigation::load(const std::filesystem::path &p) {
  std::ifstream f(p, std::ios::binary);
  char magic[8]{};
  if (!f.read(magic, 8) || (std::memcmp(magic, "MOKANAV1", 8) &&
                           std::memcmp(magic, "MOKANAV2", 8) &&
                           std::memcmp(magic, "MOKANAV3", 8)))
    throw std::runtime_error("Invalid navigation pack");
  const bool hasSockets = magic[7] >= '2', hasChairs = magic[7] == '3';
  std::vector<Box> boxes(count(f, 10000));
  for (auto &box : boxes) {
    box = read<Box>(f);
    if (!validBox(box))
      throw std::runtime_error("Invalid navigation obstacle");
  }
  // These asset bounds include castors and desk overhangs. The correction is
  // shared with office-navdata.ts; thin walls and dividers stay exact.
  for (auto &box : boxes) {
    const float inset = std::min(box.maxX - box.minX, box.maxZ - box.minZ) < .12F
                            ? 0.F : .14F;
    box.minX += inset;
    box.maxX -= inset;
    box.minZ += inset;
    box.maxZ -= inset;
  }
  std::erase_if(boxes, [](const Box &b) {
    return b.maxX <= b.minX + .04F || b.maxZ <= b.minZ + .04F;
  });
  std::vector<Vec3> anchors(count(f, 10000));
  for (auto &a : anchors) {
    a.x = read<float>(f);
    a.z = read<float>(f);
  }
  std::vector<std::vector<std::uint32_t>> lanes(count(f, 128));
  for (auto &lane : lanes) {
    lane.resize(count(f, 1000));
    for (auto &i : lane)
      i = read<std::uint32_t>(f);
  }
  if (boxes.empty() || anchors.empty() || lanes.empty())
    throw std::runtime_error("Navigation pack has no usable office layout");
  std::vector<ActivitySocket> sockets;
  if (hasSockets) {
    sockets.resize(count(f, 256));
    for (auto &socket : sockets) {
      socket.id = readString(f);
      socket.kind = read<std::uint32_t>(f);
      socket.position.x = read<float>(f);
      socket.position.z = read<float>(f);
      socket.approach.x = read<float>(f);
      socket.approach.z = read<float>(f);
      socket.yaw = read<float>(f);
      socket.seatHeight = read<float>(f);
      socket.holdSeconds = read<float>(f);
      if (hasChairs) {
        socket.chairNode = read<std::int32_t>(f);
        socket.pullback = read<float>(f);
        socket.chairLocalDelta.x = read<float>(f);
        socket.chairLocalDelta.y = read<float>(f);
        socket.chairLocalDelta.z = read<float>(f);
      }
    }
  }
  std::vector<FloorSurface> floors;
  if (hasChairs) {
    floors.resize(count(f, 256));
    for (auto &floor : floors) {
      floor.bounds = read<Box>(f);
      floor.height = read<float>(f);
    }
  }
  if (f.peek() != std::char_traits<char>::eof())
    throw std::runtime_error("Trailing navigation pack data");
  auto nav = fromGeometry(std::move(boxes), std::move(anchors), std::move(lanes),
                           {-7.3F, 6.95F, -6.35F, 6.35F}, std::move(sockets),
                           std::move(floors));
  nav.officeFootprint_ = true;
  nav.buildGrid();
  return nav;
}
Navigation Navigation::fromGeometry(
    std::vector<Box> obstacles, std::vector<Vec3> anchors,
    std::vector<std::vector<std::uint32_t>> lanes, Box bounds,
    std::vector<ActivitySocket> sockets, std::vector<FloorSurface> floors) {
  if (!validBox(bounds) || bounds.maxX - bounds.minX > 100.F ||
      bounds.maxZ - bounds.minZ > 100.F || obstacles.size() > 10000 ||
      anchors.size() > 10000 || lanes.size() > 128 || sockets.size() > 256 ||
      floors.size() > 256)
    throw std::runtime_error("Invalid navigation geometry");
  for (const auto &box : obstacles)
    if (!validBox(box))
      throw std::runtime_error("Invalid navigation obstacle");
  for (const auto &anchor : anchors)
    if (!finite(anchor) || !insideBounds(anchor, bounds, 0))
      throw std::runtime_error("Invalid navigation anchor");
  for (const auto &lane : lanes) {
    if (lane.empty() || lane.size() > 1000)
      throw std::runtime_error("Empty or oversized navigation lane");
    for (const auto i : lane)
      if (i >= anchors.size())
        throw std::runtime_error("Navigation anchor out of bounds");
  }
  std::unordered_set<std::string> ids;
  for (const auto &socket : sockets) {
    if (socket.id.empty() || socket.id.size() > 128 ||
        std::any_of(socket.id.begin(), socket.id.end(), [](unsigned char c) {
          return c < 33 || c > 126;
        }) || !ids.insert(socket.id).second || socket.kind > 4 ||
        !finite(socket.position) || !finite(socket.approach) ||
        !insideBounds(socket.position, bounds, 0) ||
        !insideBounds(socket.approach, bounds, 0) ||
        !std::isfinite(socket.yaw) || !std::isfinite(socket.seatHeight) ||
        socket.seatHeight < 0 || socket.seatHeight > 3 ||
        !std::isfinite(socket.holdSeconds) || socket.holdSeconds < 0 ||
        socket.holdSeconds > 3600 || socket.chairNode < -1 ||
        socket.chairNode > 100000 || !std::isfinite(socket.pullback) ||
        socket.pullback < 0 || socket.pullback > socketReach ||
        !finite(socket.chairLocalDelta))
      throw std::runtime_error("Invalid navigation activity socket");
  }
  for (const auto &floor : floors)
    if (!validBox(floor.bounds) || !std::isfinite(floor.height) ||
        floor.height < 0 || floor.height > 10)
      throw std::runtime_error("Invalid navigation floor surface");
  Navigation nav;
  nav.bounds_ = bounds;
  nav.obstacles_ = std::move(obstacles);
  nav.anchors_ = std::move(anchors);
  nav.lanes_ = std::move(lanes);
  nav.sockets_ = std::move(sockets);
  nav.floors_ = std::move(floors);
  nav.buildGrid();
  return nav;
}
float Navigation::floorHeightAt(Vec3 point) const {
  float height = 0;
  if (!finite(point))
    return height;
  for (const auto &floor : floors_)
    if (insideBounds(point, floor.bounds, 0))
      height = std::max(height, floor.height);
  return height;
}
Vec3 Navigation::gridPoint(int index) const {
  return {bounds_.minX + static_cast<float>(index % columns_) * cell, 0,
          bounds_.minZ + static_cast<float>(index / columns_) * cell};
}
void Navigation::buildGrid() {
  columns_ = static_cast<int>(std::floor((bounds_.maxX - bounds_.minX) / cell)) + 1;
  rows_ = static_cast<int>(std::floor((bounds_.maxZ - bounds_.minZ) / cell)) + 1;
  grid_.resize(static_cast<std::size_t>(columns_ * rows_));
  grid35_.resize(grid_.size());
  for (std::size_t i = 0; i < grid_.size(); ++i) {
    const auto point = gridPoint(static_cast<int>(i));
    grid_[i] = walkable(point);
    grid35_[i] = walkable(point, .35F);
  }
}
bool Navigation::gridWalkable(std::size_t index, float radius) const {
  // Both usual body sizes are immutable static geometry. Replanning for other
  // agents must not repeat thousands of furniture tests for every retry.
  if (radius == defaultRadius)
    return grid_[index];
  if (radius == .35F)
    return grid35_[index];
  return walkable(gridPoint(static_cast<int>(index)), radius);
}
bool Navigation::walkable(Vec3 p, float radius) const {
  if (grid_.empty() || !finite(p) || !validRadius(radius) ||
      !withinFootprint(p, radius))
    return false;
  for (const auto &box : obstacles_)
    if (!clearsBox(p, p, box, radius))
      return false;
  return true;
}
bool Navigation::withinFootprint(Vec3 p, float radius) const {
  const float clearance = officeFootprint_ ? std::max(radius, .35F) : radius;
  if (!insideBounds(p, bounds_, clearance))
    return false;
  // The office has a slanted right edge and a bevel at the front corner.
  // Both are half-planes; checking a segment's endpoints covers its sweep.
  return !officeFootprint_ ||
         (p.x - .24676F * p.z <=
              7.4021F - clearance * std::sqrt(1.F + .24676F * .24676F) &&
          p.x - p.z <= 11.2F - clearance * std::sqrt(2.F));
}
bool Navigation::segmentWalkable(Vec3 start, Vec3 goal, float radius,
                                  std::span<const Disc> blocked) const {
  if (grid_.empty() || !finite(start) || !finite(goal) || !validRadius(radius) ||
      !withinFootprint(start, radius) || !withinFootprint(goal, radius))
    return false;
  for (const auto &box : obstacles_)
    if (!clearsBox(start, goal, box, radius))
      return false;
  return clearsDiscs(start, goal, radius, blocked);
}
Vec3 Navigation::nearest(Vec3 p) const {
  if (!finite(p) || walkable(p))
    return p;
  float best = std::numeric_limits<float>::max();
  Vec3 result = p;
  for (std::size_t i = 0; i < grid_.size(); ++i) {
    if (!grid_[i])
      continue;
    const auto v = gridPoint(static_cast<int>(i));
    const auto distance = distanceSquared(v, p);
    if (distance < best) {
      best = distance;
      result = v;
    }
  }
  return result;
}
Vec3 Navigation::waypoint(std::size_t seat, std::size_t n) const {
  if (anchors_.empty() || lanes_.empty())
    return {};
  const auto &lane = lanes_[seat % lanes_.size()];
  return anchors_[lane[n % lane.size()]];
}
std::vector<Vec3> Navigation::route(Vec3 start, Vec3 goal,
                                    std::span<const Disc> blocked,
                                    float radius) const {
  if (!segmentWalkable(start, start, radius, blocked) ||
      !segmentWalkable(goal, goal, radius, blocked))
    return {};
  if (start.x == goal.x && start.y == goal.y && start.z == goal.z)
    return {start};
  if (segmentWalkable(start, goal, radius, blocked))
    return {start, goal};
  const auto total = grid_.size();
  std::vector<bool> usable(total), finish(total), closed(total);
  std::vector<float> distance(total, std::numeric_limits<float>::max());
  std::vector<int> parent(total, -1);
  using Entry = std::pair<float, int>;
  std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> open;
  // Attach the exact endpoints through short checked edges. Rounding an
  // endpoint onto the grid can put it on the other side of a thin wall.
  constexpr float attachment = cell * 3;
  for (std::size_t i = 0; i < total; ++i) {
    const auto point = gridPoint(static_cast<int>(i));
    usable[i] = gridWalkable(i, radius) &&
                clearsDiscs(point, point, radius, blocked);
    if (!usable[i])
      continue;
    if (distanceSquared(point, start) <= attachment * attachment &&
        segmentWalkable(start, point, radius, blocked)) {
      distance[i] = std::sqrt(distanceSquared(point, start));
      open.emplace(distance[i] + std::sqrt(distanceSquared(point, goal)),
                   static_cast<int>(i));
    }
    finish[i] = distanceSquared(point, goal) <= attachment * attachment &&
                segmentWalkable(point, goal, radius, blocked);
  }
  int last = -1;
  while (!open.empty()) {
    const int current = open.top().second;
    open.pop();
    if (closed[current])
      continue;
    closed[current] = true;
    if (finish[current]) {
      last = current;
      break;
    }
    const int x = current % columns_, z = current / columns_;
    for (int dz = -1; dz <= 1; ++dz)
      for (int dx = -1; dx <= 1; ++dx) {
        if ((!dx && !dz) || x + dx < 0 || x + dx >= columns_ || z + dz < 0 ||
            z + dz >= rows_)
          continue;
        const int next = current + dx + dz * columns_;
        if (closed[next] || !usable[next] ||
            !segmentWalkable(gridPoint(current), gridPoint(next), radius, blocked))
          continue;
        const float cost = distance[current] +
                            (dx && dz ? 1.41421356F : 1.F) * cell;
        if (cost >= distance[next])
          continue;
        distance[next] = cost;
        parent[next] = current;
        open.emplace(cost + std::sqrt(distanceSquared(gridPoint(next), goal)), next);
      }
  }
  if (last < 0)
    return {};
  std::vector<Vec3> path{goal};
  for (int i = last; i >= 0; i = parent[i])
    path.push_back(gridPoint(i));
  path.push_back(start);
  std::reverse(path.begin(), path.end());
  std::vector<Vec3> simplified{start};
  for (std::size_t anchor = 0; anchor + 1 < path.size();) {
    std::size_t next = path.size() - 1;
    while (next > anchor + 1 &&
           !segmentWalkable(path[anchor], path[next], radius, blocked))
      --next;
    simplified.push_back(path[next]);
    anchor = next;
  }
  return simplified;
}
std::vector<Vec3> Navigation::smoothRoute(std::span<const Vec3> path,
                                          std::span<const Disc> blocked,
                                          float radius, float cornerRadius) const {
  if (path.empty() || !validRadius(radius) || !validRadius(cornerRadius) ||
      cornerRadius <= 0)
    return {};
  for (std::size_t i = 0; i < path.size(); ++i)
    if (!segmentWalkable(path[i ? i - 1 : 0], path[i], radius, blocked))
      return {};
  if (path.size() < 3)
    return {path.begin(), path.end()};

  std::vector<Vec3> result{path.front()};
  const float minimumRadius = std::min(.20F, cornerRadius);
  for (std::size_t i = 1; i + 1 < path.size(); ++i) {
    const auto previous = path[i - 1], corner = path[i], next = path[i + 1];
    const float before = std::sqrt(distanceSquared(previous, corner)),
                after = std::sqrt(distanceSquared(corner, next));
    if (before < 1e-5F || after < 1e-5F) {
      result.push_back(corner);
      continue;
    }
    const Vec3 incoming{(corner.x - previous.x) / before, 0,
                        (corner.z - previous.z) / before},
               outgoing{(next.x - corner.x) / after, 0,
                        (next.z - corner.z) / after};
    const float angle = std::acos(std::clamp(dot(incoming, outgoing), -1.F, 1.F));
    // Near-collinear legs need no fillet; a reversal needs a physical turn.
    if (angle < .025F || angle > 3.0F) {
      result.push_back(corner);
      continue;
    }
    const float tangent = std::tan(angle * .5F);
    // Adjacent fillets each use at most 45% of a leg, so they cannot overlap
    // or reverse their connecting tangent even on very short A* segments.
    const float maximum = std::min(cornerRadius, .45F * std::min(before, after) / tangent);
    const float orientation = incoming.x * outgoing.z - incoming.z * outgoing.x > 0 ? 1.F : -1.F;
    bool rounded = false;
    for (float bendRadius = maximum; bendRadius >= minimumRadius - 1e-6F;) {
      const float trim = bendRadius * tangent;
      const Vec3 first = corner + (previous - corner) * (trim / before),
                 last = corner + (next - corner) * (trim / after),
                 center{first.x - incoming.z * orientation * bendRadius, 0,
                        first.z + incoming.x * orientation * bendRadius};
      const int samples = std::max(2, static_cast<int>(std::ceil(
          angle / std::min(.10F, .06F / bendRadius))));
      std::vector<Vec3> arc;
      arc.reserve(static_cast<std::size_t>(samples + 1));
      arc.push_back(first);
      for (int sample = 1; sample < samples; ++sample) {
        const float t = static_cast<float>(sample) / static_cast<float>(samples),
                    rotation = orientation * angle * t,
                    cosine = std::cos(rotation), sine = std::sin(rotation);
        const auto offset = first - center;
        arc.push_back({center.x + offset.x * cosine - offset.z * sine,
                       first.y + (last.y - first.y) * t,
                       center.z + offset.x * sine + offset.z * cosine});
      }
      arc.push_back(last);
      bool safe = segmentWalkable(result.back(), first, radius, blocked);
      for (std::size_t sample = 1; safe && sample < arc.size(); ++sample)
        safe = segmentWalkable(arc[sample - 1], arc[sample], radius, blocked);
      if (safe) {
        result.insert(result.end(), arc.begin(), arc.end());
        rounded = true;
        break;
      }
      if (bendRadius <= minimumRadius)
        break;
      bendRadius = std::max(minimumRadius, bendRadius * .75F);
    }
    if (!rounded)
      result.push_back(corner);
  }
  result.push_back(path.back());
  // Includes original sharp corners and tangent connectors, not only arcs.
  for (std::size_t i = 1; i < result.size(); ++i)
    if (!segmentWalkable(result[i - 1], result[i], radius, blocked))
      return {path.begin(), path.end()};
  return result;
}
std::vector<bool> Navigation::reachableGrid(std::span<const Vec3> starts,
                                            float radius,
                                            std::span<const Disc> blocked) const {
  const auto total = grid_.size();
  std::vector<bool> usable(total), seen(total);
  std::queue<int> open;
  for (std::size_t i = 0; i < total; ++i) {
    const auto point = gridPoint(static_cast<int>(i));
    usable[i] = gridWalkable(i, radius) && clearsDiscs(point, point, radius, blocked);
    if (usable[i] && std::any_of(starts.begin(), starts.end(), [&](Vec3 from) {
          return distanceSquared(point, from) <= cell * cell * 9 &&
                 segmentWalkable(from, point, radius, blocked);
        })) {
      seen[i] = true;
      open.push(static_cast<int>(i));
    }
  }
  while (!open.empty()) {
    const int current = open.front();
    open.pop();
    const auto point = gridPoint(current);
    const int x = current % columns_, z = current / columns_;
    for (int dz = -1; dz <= 1; ++dz)
      for (int dx = -1; dx <= 1; ++dx) {
        if ((!dx && !dz) || x + dx < 0 || x + dx >= columns_ || z + dz < 0 ||
            z + dz >= rows_)
          continue;
        const int next = current + dx + dz * columns_;
        if (seen[next] || !usable[next] ||
            !segmentWalkable(point, gridPoint(next), radius, blocked))
          continue;
        seen[next] = true;
        open.push(next);
      }
  }
  return seen;
}
std::optional<Vec3> Navigation::nearestReachable(Vec3 desired, Vec3 from,
                                                float maxDistance,
                                                float radius) const {
  if (!finite(desired) || !walkable(from, radius) || !std::isfinite(maxDistance) ||
      maxDistance < 0 || !validRadius(radius))
    return std::nullopt;
  if (walkable(desired, radius) && !route(from, desired, {}, radius).empty())
    return desired;
  const auto reachable = reachableGrid({&from, 1}, radius);
  float best = maxDistance * maxDistance;
  std::optional<Vec3> result;
  if (distanceSquared(from, desired) <= best) {
    result = from;
    best = distanceSquared(from, desired);
  }
  for (std::size_t i = 0; i < reachable.size(); ++i) {
    if (!reachable[i])
      continue;
    const auto point = gridPoint(static_cast<int>(i));
    const float distance = distanceSquared(point, desired);
    if (distance <= best) {
      best = distance;
      result = point;
    }
  }
  return result;
}
bool Navigation::socketSegmentWalkable(Vec3 socket, Vec3 approach,
                                        float radius) const {
  return walkable(approach, radius) &&
         socketSegmentWalkable(socket, socket, socket, approach, radius);
}
bool Navigation::socketSegmentWalkable(Vec3 socket, Vec3 entry, Vec3 start,
                                        Vec3 goal, float radius,
                                        std::optional<Vec3> ownerSocket) const {
  if (grid_.empty() || !finite(socket) || !finite(entry) || !finite(start) ||
      !finite(goal) || (ownerSocket && !finite(*ownerSocket)) ||
      !validRadius(radius) || !withinFootprint(socket, radius) ||
      !withinFootprint(start, radius) || !withinFootprint(goal, radius) ||
      distanceSquared(socket, entry) > .65F * .65F ||
      distanceSquared(socket, start) > socketReach * socketReach ||
      distanceSquared(socket, goal) > socketReach * socketReach)
    return false;
  const Vec3 ownerPosition = ownerSocket.value_or(socket);
  const auto forward = entry - socket;
  const float forwardLength = std::sqrt(distanceSquared(entry, socket));
  if (forwardLength > .01F) {
    const auto frontDistance = [&](Vec3 p) {
      return ((p.x - socket.x) * forward.x + (p.z - socket.z) * forward.z) /
                 forwardLength - std::min(.08F, forwardLength);
    };
    const float a = frontDistance(start), b = frontDistance(goal);
    if (a < 0 || b < 0) {
      // Walking around the chair is legitimate once its backrest is cleared.
      // Check the entire rearward part of this sweep, not only its endpoints:
      // two safe lateral points must not form a shortcut through the chair.
      const float first = a >= 0 ? a / (a - b) : 0.F;
      const float last = b >= 0 ? a / (a - b) : 1.F;
      if (pointSegmentDistanceSquared(socket, start + (goal - start) * first,
                                      start + (goal - start) * last) < .75F * .75F)
        return false;
    }
  }
  const auto known = std::find_if(sockets_.begin(), sockets_.end(), [&](const auto &s) {
    return distanceSquared(s.position, ownerPosition) < .0001F;
  });
  const auto kind = known == sockets_.end() ? 0U : known->kind;
  for (const auto &box : obstacles_) {
    if (clearsBox(start, goal, box, radius))
      continue;
    // Chair meshes also occur as short rasterised shell fragments in legacy
    // packs. Only the compact hull around the occupied seat is exempted.
    const float farX = std::max(std::abs(box.minX - ownerPosition.x),
                                std::abs(box.maxX - ownerPosition.x)),
                farZ = std::max(std::abs(box.minZ - ownerPosition.z),
                                std::abs(box.maxZ - ownerPosition.z));
    const bool chairHull = kind == 0 && farX * farX + farZ * farZ <= .72F * .72F &&
                            box.maxX - box.minX <= 1.1F &&
                            box.maxZ - box.minZ <= 1.1F;
    const bool sofaHull = kind == 1 && !clearsBox(ownerPosition, ownerPosition, box, radius) &&
                           box.maxX - box.minX <= 3.5F &&
                           box.maxZ - box.minZ <= .9F;
    if (chairHull || sofaHull)
      continue;
    // A rolled chair is actually moved by the renderer. Its new standing
    // marker must clear the tabletop completely before the body stands up.
    if (ownerSocket)
      return false;
    bool pairedTableFragment = false;
    if (std::min(box.maxX - box.minX, box.maxZ - box.minZ) < .12F) {
      for (const auto &owner : obstacles_) {
        if (std::min(owner.maxX - owner.minX, owner.maxZ - owner.minZ) < .25F ||
            std::max(owner.maxX - owner.minX, owner.maxZ - owner.minZ) < 1.1F ||
            clearsBox(entry, entry, owner, radius) ||
            !leavesBox(start, goal, owner))
          continue;
        // Legacy rasterisation leaves a narrow duplicate border outside some
        // tabletop mesh bounds. It belongs to the same initially overlapped
        // table; leaving that table must still be monotone for every edge.
        constexpr float rasterBorder = .30F;
        if (box.minX >= owner.minX - rasterBorder &&
            box.maxX <= owner.maxX + rasterBorder &&
            box.minZ >= owner.minZ - rasterBorder &&
            box.maxZ <= owner.maxZ + rasterBorder) {
          pairedTableFragment = true;
          break;
        }
      }
    }
    if (pairedTableFragment)
      continue;
    // A standing marker may already overlap the paired tabletop's broad
    // collision hull. Permit only motion away from that initial overlap.
    if (clearsBox(entry, entry, box, radius) || !leavesBox(start, goal, box))
      return false;
  }
  return true;
}
std::vector<Vec3> Navigation::socketRoute(Vec3 socket, Vec3 entry,
                                          Vec3 preferredDirection,
                                          float radius,
                                          std::optional<Vec3> ownerSocket,
                                          std::span<const Disc> blocked) const {
  const auto localClear = [&](Vec3 start, Vec3 goal) {
    return socketSegmentWalkable(socket, entry, start, goal, radius, ownerSocket) &&
           clearsDiscs(start, goal, radius, blocked);
  };
  if (!finite(preferredDirection) ||
      !localClear(entry, entry))
    return {};
  constexpr float chairExitClearance = .80F;
  if (walkable(entry, radius) &&
      distanceSquared(socket, entry) >= chairExitClearance * chairExitClearance)
    return {entry};
  // Releasing the actor outside the chair radius is insufficient if the only
  // way out of that pocket crosses the chair again. Its final walking route
  // must remain in the aisle component with that real moved chair present.
  std::vector<Disc> aisleObstacles(blocked.begin(), blocked.end());
  if (ownerSocket)
    aisleObstacles.push_back({socket, .425F}); // .40 m chair plus .025 m body gap.
  const auto aisle = std::find_if(anchors_.begin(), anchors_.end(), [&](Vec3 p) {
    return segmentWalkable(p, p, radius, aisleObstacles);
  });
  if (!anchors_.empty() && aisle == anchors_.end())
    return {};
  const auto reachable = aisle == anchors_.end()
                             ? std::vector<bool>{}
                             : reachableGrid({&*aisle, 1}, radius, aisleObstacles);
  const auto reachesAisle = [&](Vec3 point) {
    if (reachable.empty())
      return true;
    const int x = static_cast<int>((point.x - bounds_.minX) / cell),
              z = static_cast<int>((point.z - bounds_.minZ) / cell);
    for (int dz = -3; dz <= 3; ++dz)
      for (int dx = -3; dx <= 3; ++dx) {
        if (x + dx < 0 || x + dx >= columns_ || z + dz < 0 || z + dz >= rows_)
          continue;
        const int index = x + dx + (z + dz) * columns_;
        if (reachable[index] && segmentWalkable(point, gridPoint(index), radius, aisleObstacles))
          return true;
      }
    return false;
  };
  constexpr float localCell = .05F;
  constexpr int localColumns = static_cast<int>(socketReach * 2 / localCell) + 1;
  constexpr auto total = static_cast<std::size_t>(localColumns * localColumns);
  const auto localPoint = [&](int index) -> Vec3 {
    return {socket.x - socketReach + static_cast<float>(index % localColumns) * localCell,
            0, socket.z - socketReach + static_cast<float>(index / localColumns) * localCell};
  };
  std::vector<bool> closed(total);
  std::vector<float> distance(total, std::numeric_limits<float>::max());
  std::vector<int> parent(total, -1);
  using Entry = std::pair<float, int>;
  std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> open;
  for (std::size_t i = 0; i < total; ++i) {
    const auto point = localPoint(static_cast<int>(i));
    if (distanceSquared(point, entry) <= localCell * localCell * 4 &&
        localClear(entry, point)) {
      distance[i] = std::sqrt(distanceSquared(point, entry));
      open.emplace(distance[i], static_cast<int>(i));
    }
  }
  int last = -1;
  float best = std::numeric_limits<float>::max();
  const float preferredLength = std::sqrt(distanceSquared(preferredDirection, {}));
  while (!open.empty()) {
    const auto [cost, current] = open.top();
    open.pop();
    if (cost > best)
      break;
    if (closed[current])
      continue;
    closed[current] = true;
    const auto point = localPoint(current);
    const float fromSocket = std::sqrt(distanceSquared(point, socket));
    if (walkable(point, radius) && fromSocket >= chairExitClearance) {
      const auto delta = point - socket;
      const float alignment = preferredLength > 1e-6F
                                  ? (delta.x * preferredDirection.x +
                                     delta.z * preferredDirection.z) /
                                        (fromSocket * preferredLength)
                                  : 1.F;
      const float score = cost + (1.F - alignment) * .35F;
      if (score < best && reachesAisle(point)) {
        best = score;
        last = current;
      }
    }
    const int x = current % localColumns, z = current / localColumns;
    for (int dz = -1; dz <= 1; ++dz)
      for (int dx = -1; dx <= 1; ++dx) {
        if ((!dx && !dz) || x + dx < 0 || x + dx >= localColumns || z + dz < 0 ||
            z + dz >= localColumns)
          continue;
        const int next = current + dx + dz * localColumns;
        if (closed[next] ||
            !localClear(point, localPoint(next)))
          continue;
        const float nextCost = cost + (dx && dz ? 1.41421356F : 1.F) * localCell;
        if (nextCost >= distance[next])
          continue;
        distance[next] = nextCost;
        parent[next] = current;
        open.emplace(nextCost, next);
      }
  }
  if (last < 0)
    return {};
  std::vector<Vec3> path;
  for (int i = last; i >= 0; i = parent[i])
    path.push_back(localPoint(i));
  path.push_back(entry);
  std::reverse(path.begin(), path.end());
  std::vector<Vec3> simplified{entry};
  for (std::size_t anchor = 0; anchor + 1 < path.size();) {
    std::size_t next = path.size() - 1;
    while (next > anchor + 1 &&
           !localClear(path[anchor], path[next]))
      --next;
    simplified.push_back(path[next]);
    anchor = next;
  }
  return simplified;
}
std::optional<Vec3> Navigation::socketApproach(Vec3 socket, Vec3 preferredDirection,
                                              float maxDistance,
                                              float radius) const {
  if (!finite(socket) || !finite(preferredDirection) || !std::isfinite(maxDistance) ||
      maxDistance < 0 || !validRadius(radius))
    return std::nullopt;
  if (walkable(socket, radius))
    return socket;
  maxDistance = std::min(maxDistance, socketReach);
  float best = std::numeric_limits<float>::max();
  std::optional<Vec3> result;
  const float preferredLength = std::sqrt(distanceSquared(preferredDirection, {}));
  for (std::size_t i = 0; i < grid_.size(); ++i) {
    const auto point = gridPoint(static_cast<int>(i));
    const auto delta = point - socket;
    const float distance = std::sqrt(distanceSquared(point, socket));
    if (distance > maxDistance || distance < 1e-6F ||
        !gridWalkable(i, radius))
      continue;
    const float alignment = preferredLength > 1e-6F
                                ? (delta.x * preferredDirection.x +
                                   delta.z * preferredDirection.z) /
                                      (distance * preferredLength)
                                : 1.F;
    const float score = distance + (1.F - alignment) * .35F;
    if (score < best && socketSegmentWalkable(socket, point, radius)) {
      best = score;
      result = point;
    }
  }
  return result;
}
} // namespace mokaid::engine
