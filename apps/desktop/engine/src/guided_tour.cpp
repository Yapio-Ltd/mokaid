#include <mokaid/engine/guided_tour.hpp>
#include <limits>
#include <numeric>
#include <queue>
#include <unordered_set>

namespace mokaid::engine {
namespace {
constexpr std::size_t missing = std::numeric_limits<std::size_t>::max();
constexpr float tau = 6.283185307F;
bool finite(Vec3 p) { return std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z); }
float pathLength(std::span<const Vec3> path) {
  float total = 0;
  for (std::size_t i = 1; i < path.size(); ++i) total += length(path[i] - path[i - 1]);
  return total;
}
}
GuidedTour GuidedTour::build(const Navigation &nav, std::vector<TourStop> candidates) {
  GuidedTour tour;
  if (nav.empty() || candidates.empty()) return tour;
  std::unordered_set<std::string> ids;
  for (auto stop : candidates) {
    if (stop.id.empty() || !ids.insert(stop.id).second || !finite(stop.position) || !finite(stop.target)) continue;
    // Projection happens only during construction, never in response to a floor
    // click. Every destination belongs to the entrance's connected component.
    if (tour.stops_.empty()) {
      const auto projected = nav.nearest(stop.position);
      if (!nav.walkable(projected, radius) || length(projected - stop.position) > 2.F) continue;
      stop.position = projected;
    } else {
      const auto projected = nav.nearestReachable(stop.position, tour.stops_.front().position, 2.F, radius);
      if (!projected) continue;
      stop.position = *projected;
    }
    stop.position.y = nav.floorHeightAt(stop.position);
    tour.stops_.push_back(std::move(stop));
  }
  if (tour.stops_.size() < 2) { tour.stops_.clear(); return tour; }
  struct Candidate { std::size_t from, to; float distance; std::vector<Vec3> points; };
  std::vector<Candidate> connections;
  for (std::size_t a = 0; a < tour.stops_.size(); ++a) {
    for (std::size_t b = a + 1; b < tour.stops_.size(); ++b) {
      auto points = nav.route(tour.stops_[a].position, tour.stops_[b].position, {}, radius);
      if (points.empty()) continue;
      const auto rounded = nav.smoothRoute(points, {}, radius, .55F);
      if (!rounded.empty()) points = rounded;
      for (auto &p : points) p.y = nav.floorHeightAt(p);
      bool safe = true;
      for (std::size_t i = 1; i < points.size(); ++i)
        safe = safe && nav.segmentWalkable(points[i - 1], points[i], radius);
      if (safe) connections.push_back({a, b, pathLength(points), std::move(points)});
    }
  }
  std::sort(connections.begin(), connections.end(), [](const auto &a, const auto &b) {
    if (a.distance != b.distance) return a.distance < b.distance;
    if (a.from != b.from) return a.from < b.from;
    return a.to < b.to;
  });
  const auto count = tour.stops_.size();
  tour.neighbours_.resize(count);
  std::vector<std::size_t> component(count), degree(count);
  std::iota(component.begin(), component.end(), 0);
  const auto root = [&](std::size_t v) { while (component[v] != v) v = component[v]; return v; };
  std::vector<bool> chosen(connections.size());
  const auto connect = [&](std::size_t i) {
    const auto &c = connections[i];
    const auto e = tour.edges_.size();
    tour.edges_.push_back({tour.stops_[c.from].id, tour.stops_[c.to].id, c.points});
    tour.neighbours_[c.from].emplace_back(c.to, e);
    tour.neighbours_[c.to].emplace_back(c.from, e);
    ++degree[c.from]; ++degree[c.to]; chosen[i] = true;
  };
  // Minimum spanning connections guarantee every stop is reachable. Add local
  // links to permit loops and short visits without a dense web of long chords.
  for (std::size_t i = 0; i < connections.size(); ++i) {
    const auto &c = connections[i]; const auto a = root(c.from), b = root(c.to);
    if (a != b) { component[b] = a; connect(i); }
  }
  for (std::size_t i = 0; i < count; ++i)
    if (root(i) != root(0)) return {};
  for (std::size_t i = 0; i < connections.size(); ++i) {
    const auto &c = connections[i];
    if (!chosen[i] && (degree[c.from] < 3 || degree[c.to] < 3) && c.distance < 7.F) connect(i);
  }
  tour.state_.available = true;
  tour.state_.position = tour.stops_.front().position;
  tour.state_.currentStop = tour.stops_.front().id;
  return tour;
}
std::size_t GuidedTour::index(std::string_view id) const {
  for (std::size_t i = 0; i < stops_.size(); ++i) if (stops_[i].id == id) return i;
  return missing;
}
std::vector<std::size_t> GuidedTour::itinerary(std::size_t from, std::size_t to) const {
  std::vector<float> distances(stops_.size(), std::numeric_limits<float>::infinity());
  std::vector<std::size_t> previous(stops_.size(), missing);
  using Entry = std::pair<float, std::size_t>;
  std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> pending;
  distances[from] = 0; pending.emplace(0, from);
  while (!pending.empty()) {
    const auto [distance, at] = pending.top(); pending.pop();
    if (distance != distances[at]) continue;
    if (at == to) break;
    for (const auto &[next, edge] : neighbours_[at]) {
      const float candidate = distance + pathLength(edges_[edge].points);
      if (candidate < distances[next]) { distances[next] = candidate; previous[next] = at; pending.emplace(candidate, next); }
    }
  }
  std::vector<std::size_t> result;
  if (!std::isfinite(distances[to])) return result;
  for (auto at = to; at != from; at = previous[at]) result.push_back(at);
  std::reverse(result.begin(), result.end());
  return result;
}
void GuidedTour::face(Vec3 target) {
  const auto toward = target - (state_.position + Vec3{0, eyeHeight, 0});
  desiredYaw_ = std::atan2(toward.x, -toward.z);
  desiredPitch_ = std::clamp(std::atan2(toward.y, std::hypot(toward.x, toward.z)), -.75F, .65F);
  autoLook_ = !manualLook_ && !reducedMotion_;
  state_.settling = autoLook_;
}
bool GuidedTour::enter() {
  if (!state_.available) return false;
  if (state_.active) return true;
  current_ = edgeEnd_ = 0; waypoint_ = 0; activePath_.clear(); itinerary_.clear();
  travelSpeed_ = 0;
  manualLook_ = false;
  state_.active = true; state_.moving = false; state_.position = stops_[0].position;
  state_.currentStop = stops_[0].id; state_.destination.clear(); state_.progress = 0;
  face(stops_[0].target); state_.yaw = desiredYaw_; state_.pitch = desiredPitch_; autoLook_ = false; state_.settling = false;
  return true;
}
void GuidedTour::exit() {
  state_.active = false; state_.moving = false; state_.settling = false; state_.destination.clear();
  activePath_.clear(); itinerary_.clear(); autoLook_ = false; travelSpeed_ = 0;
}
bool GuidedTour::travelTo(std::string_view id) {
  const auto destination = index(id);
  if (!state_.active || destination == missing) return false;
  // While between stops, finish the current baked edge before rerouting. A
  // paused visitor resumes that exact edge; there is never a new diagonal.
  itinerary_ = itinerary(activePath_.empty() ? current_ : edgeEnd_, destination);
  state_.destination = stops_[destination].id;
  manualLook_ = false;
  travelled_ = 0; totalDistance_ = 0; state_.progress = 0;
  if (!activePath_.empty()) {
    totalDistance_ = length(activePath_[waypoint_] - state_.position);
    for (std::size_t i = waypoint_ + 1; i < activePath_.size(); ++i) totalDistance_ += length(activePath_[i] - activePath_[i - 1]);
  }
  auto previous = activePath_.empty() ? current_ : edgeEnd_;
  for (const auto next : itinerary_) {
    for (const auto &[neighbour, edge] : neighbours_[previous])
      if (neighbour == next) { totalDistance_ += pathLength(edges_[edge].points); break; }
    previous = next;
  }
  state_.moving = !activePath_.empty() || !itinerary_.empty();
  if (activePath_.empty()) startNextEdge();
  if (!state_.moving) { state_.progress = 1; face(stops_[destination].target); }
  return true;
}
void GuidedTour::startNextEdge() {
  if (itinerary_.empty()) {
    state_.moving = false; state_.progress = 1;
    face(stops_[current_].target);
    return;
  }
  edgeEnd_ = itinerary_.front(); itinerary_.erase(itinerary_.begin());
  for (const auto &[next, edge] : neighbours_[current_]) {
    if (next != edgeEnd_) continue;
    activePath_ = edges_[edge].points;
    if (edges_[edge].from != stops_[current_].id) std::reverse(activePath_.begin(), activePath_.end());
    waypoint_ = 1;
    if (activePath_.size() < 2) {
      current_ = edgeEnd_; state_.currentStop = stops_[current_].id;
      activePath_.clear(); startNextEdge(); return;
    }
    // Orient gently along the route only until the visitor takes over looking.
    if (activePath_.size() > 1) {
      const auto direction = activePath_[1] - state_.position;
      desiredYaw_ = std::atan2(direction.x, -direction.z); desiredPitch_ = -.06F;
      autoLook_ = !manualLook_ && !reducedMotion_;
    }
    return;
  }
}
void GuidedTour::stop() {
  if (state_.active) { state_.moving = false; state_.settling = false; autoLook_ = false; travelSpeed_ = 0; }
}
void GuidedTour::look(float yaw, float pitch) {
  if (!state_.active || !std::isfinite(yaw) || !std::isfinite(pitch)) return;
  state_.yaw = std::remainder(state_.yaw + yaw, tau);
  state_.pitch = std::clamp(state_.pitch + pitch, -1.15F, 1.15F);
  autoLook_ = false; manualLook_ = true; state_.settling = false;
}
bool GuidedTour::faceCurrentStop() {
  if (!state_.active || state_.moving || current_ >= stops_.size()) return false;
  manualLook_ = false;
  face(stops_[current_].target);
  // This is an explicit request to face the selected person. Reduced motion
  // uses an immediate view change, while ordinary route following keeps the
  // visitor's reduced-motion orientation unchanged.
  if (reducedMotion_) { state_.yaw = desiredYaw_; state_.pitch = desiredPitch_; }
  state_.settling = autoLook_ && (std::abs(std::remainder(desiredYaw_ - state_.yaw, tau)) > .02F ||
      std::abs(desiredPitch_ - state_.pitch) > .015F);
  return true;
}
void GuidedTour::advance(float seconds) {
  if (!state_.active || !std::isfinite(seconds) || seconds <= 0) return;
  const float remainingDistance = std::max(0.F, totalDistance_ - travelled_);
  const float targetSpeed = state_.moving ? std::min(speed, std::sqrt(2.F * 2.8F * remainingDistance)) : 0.F;
  const float previousSpeed = travelSpeed_;
  travelSpeed_ += std::clamp(targetSpeed - travelSpeed_, -2.8F * seconds, 2.8F * seconds);
  float distance = std::min(remainingDistance, (previousSpeed + travelSpeed_) * .5F * seconds);
  // Finish the final millimetres on the baked polyline, including the small
  // accumulation error between its measured length and many fixed steps.
  if (state_.moving && remainingDistance < .002F) distance = .003F;
  while (state_.moving && !activePath_.empty() && (distance > 0 ||
      waypoint_ >= activePath_.size() || length(activePath_[waypoint_] - state_.position) < .000001F)) {
    if (waypoint_ >= activePath_.size()) {
      current_ = edgeEnd_; state_.currentStop = stops_[current_].id;
      activePath_.clear(); startNextEdge(); continue;
    }
    const auto delta = activePath_[waypoint_] - state_.position;
    const auto remaining = length(delta);
    const auto move = std::min(distance, remaining);
    if (remaining > .000001F) {
      state_.position = state_.position + delta * (move / remaining);
      if (autoLook_) {
        desiredYaw_ = std::atan2(delta.x, -delta.z);
        // Anticipate the destination in the last metre and a half, so arrival
        // presents the person rather than the heading of the corridor.
        const auto destination = index(state_.destination);
        if (destination != missing && remainingDistance < 1.5F) {
          const auto toward = stops_[destination].target - (state_.position + Vec3{0, eyeHeight, 0});
          float anticipation = std::clamp(1.F - remainingDistance / 1.5F, 0.F, 1.F);
          anticipation = anticipation * anticipation * (3.F - 2.F * anticipation);
          const float finalYaw = std::atan2(toward.x, -toward.z);
          const float finalPitch = std::clamp(std::atan2(toward.y, std::hypot(toward.x, toward.z)), -.75F, .65F);
          desiredYaw_ += std::remainder(finalYaw - desiredYaw_, tau) * anticipation;
          desiredPitch_ = -.06F + (finalPitch + .06F) * anticipation;
        }
      }
    }
    distance -= move; travelled_ += move;
    state_.progress = totalDistance_ > 0 ? std::clamp(travelled_ / totalDistance_, 0.F, 1.F) : 1.F;
    if (remaining <= move + .000001F) { state_.position = activePath_[waypoint_]; ++waypoint_; }
    else break;
  }
  if (state_.moving && waypoint_ >= activePath_.size()) {
    current_ = edgeEnd_; state_.currentStop = stops_[current_].id;
    activePath_.clear(); startNextEdge();
  }
  if (!state_.moving) travelSpeed_ = 0;
  if (autoLook_) {
    const float ease = 1.F - std::exp(-seconds * 4.F);
    state_.yaw = std::remainder(state_.yaw + std::remainder(desiredYaw_ - state_.yaw, tau) * ease, tau);
    state_.pitch += (desiredPitch_ - state_.pitch) * ease;
  }
  state_.settling = autoLook_ && (std::abs(std::remainder(desiredYaw_ - state_.yaw, tau)) > .02F ||
      std::abs(desiredPitch_ - state_.pitch) > .015F);
}
OfficeCamera GuidedTour::camera(float aspect) const {
  aspect = std::isfinite(aspect) ? std::max(.2F, aspect) : 1.F;
  const Vec3 eye = state_.position + Vec3{0, eyeHeight, 0};
  const Vec3 direction{std::sin(state_.yaw) * std::cos(state_.pitch), std::sin(state_.pitch), -std::cos(state_.yaw) * std::cos(state_.pitch)};
  return {perspective(1.12F, aspect, .055F, 100.F) * lookAt(eye, eye + direction), eye};
}
} // namespace mokaid::engine
