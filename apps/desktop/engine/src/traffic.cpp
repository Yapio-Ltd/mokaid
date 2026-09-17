#include <mokaid/engine/traffic.hpp>
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace mokaid::engine {
namespace {
float planarDistance(Vec3 a, Vec3 b) { a.y = b.y = 0; return length(a - b); }
float pointSegment(Vec3 p, Vec3 a, Vec3 b) {
  const auto delta = b - a;
  const float t = std::clamp(dot(p - a, delta) / std::max(1e-8F, dot(delta, delta)), 0.F, 1.F);
  return planarDistance(p, a + delta * t);
}
float cross2(Vec3 a, Vec3 b) { return a.x * b.z - a.z * b.x; }
float segmentDistance(Vec3 a, Vec3 b, Vec3 c, Vec3 d) {
  const auto u = b - a, v = d - c;
  const float denominator = cross2(u, v);
  if (std::abs(denominator) > 1e-7F) {
    const float t = cross2(c - a, v) / denominator;
    const float s = cross2(c - a, u) / denominator;
    if (t >= 0 && t <= 1 && s >= 0 && s <= 1) return 0;
  }
  return std::min({pointSegment(a, c, d), pointSegment(b, c, d),
                   pointSegment(c, a, b), pointSegment(d, a, b)});
}
bool nearRoute(Vec3 position, std::span<const Vec3> path, float separation) {
  if (path.empty()) return false;
  if (path.size() == 1) return planarDistance(position, path.front()) < separation;
  for (std::size_t i = 1; i < path.size(); ++i)
    if (pointSegment(position, path[i - 1], path[i]) < separation) return true;
  return false;
}
float turn(float current, float goal, float amount) {
  return current + std::clamp(std::remainder(goal - current, 6.283185307F), -amount, amount);
}
float cornerSpeed(std::span<const Vec3> path, std::size_t index) {
  if(index+1>=path.size())return 0;
  if(index==0)return Traffic::maxSpeed;
  const auto incoming=path[index]-path[index-1],outgoing=path[index+1]-path[index];
  const float a=length(incoming),b=length(outgoing);
  if(a<1e-6F||b<1e-6F)return Traffic::maxSpeed;
  const float angle=std::acos(std::clamp(dot(incoming,outgoing)/(a*b),-1.F,1.F));
  // Unroundable furniture/socket corners retain a genuine stop. A sampled
  // smooth arc instead has small tangent changes and a finite curvature.
  if(angle>.32F)return 0;
  const float curvature=4.F*std::sin(angle*.5F)/(a+b);
  if(curvature<1e-4F)return Traffic::maxSpeed;
  return std::min({Traffic::maxSpeed,Traffic::turnSpeed*.8F/curvature,
                   std::sqrt(1.4F/curvature)});
}
float routeHeading(std::span<const Vec3> path,std::size_t cursor,Vec3 position) {
  const auto leg=path[cursor]-path[cursor-1];
  const float heading=avatarYaw(leg);
  float from=heading,to=heading;
  if(cursor>1) {
    const float prior=avatarYaw(path[cursor-1]-path[cursor-2]);
    const float bend=std::remainder(heading-prior,6.283185307F);
    if(std::abs(bend)<=.32F)from=heading-bend*.5F;
  }
  if(cursor+1<path.size()) {
    const float following=avatarYaw(path[cursor+1]-path[cursor]);
    const float bend=std::remainder(following-heading,6.283185307F);
    if(std::abs(bend)<=.32F)to=heading+bend*.5F;
  }
  const float u=std::clamp(dot(position-path[cursor-1],leg)/std::max(1e-9F,dot(leg,leg)),0.F,1.F);
  return from+std::remainder(to-from,6.283185307F)*u;
}
float walkingSpeed(float previous, float target, Vec3 position,
                   std::span<const Vec3> path,std::size_t cursor,float seconds) {
  // Reserve enough distance to brake after this very step, whose displacement
  // is the mean of its start/end speeds. Looking only at sqrt(2*b*d) delays
  // braking by one frame and produces an abrupt final stop.
  const float brakeStep = Traffic::braking * seconds;
  float limit=target,distance=planarDistance(position,path[cursor]);
  // Look ahead to every upcoming speed constraint. This brakes before the
  // curve, rather than discovering its tighter radius at the next waypoint.
  for(std::size_t i=cursor;i<path.size();++i) {
    const float atCorner=cornerSpeed(path,i);
    const float stoppingLimit=std::max(0.F,std::sqrt(std::max(0.F,
        brakeStep*brakeStep*.25F+2.F*Traffic::braking*distance+
        atCorner*atCorner-brakeStep*previous))-brakeStep*.5F);
    limit=std::min(limit,stoppingLimit);
    if(i+1<path.size())distance+=planarDistance(path[i],path[i+1]);
  }
  return std::clamp(limit, std::max(0.F, previous - brakeStep),
                    previous + Traffic::acceleration * seconds);
}
} // namespace
Traffic::Body &Traffic::body(const std::string &id) {
  const auto it = std::find_if(bodies_.begin(), bodies_.end(), [&](const auto &b) { return b.state.id == id; });
  if (it == bodies_.end()) throw std::out_of_range("Unknown traffic actor");
  return *it;
}
const Traffic::Body &Traffic::body(const std::string &id) const {
  const auto it = std::find_if(bodies_.begin(), bodies_.end(), [&](const auto &b) { return b.state.id == id; });
  if (it == bodies_.end()) throw std::out_of_range("Unknown traffic actor");
  return *it;
}
TrafficState &Traffic::state(const std::string &id) { return body(id).state; }
const TrafficState &Traffic::state(const std::string &id) const { return body(id).state; }
void Traffic::add(std::string id, Vec3 position, float yaw) {
  if (std::any_of(bodies_.begin(), bodies_.end(), [&](const auto &b) { return b.state.id == id; })) return;
  Body b;
  b.state.id = std::move(id); b.state.position = position; b.state.yaw = yaw; b.goal = position;
  bodies_.push_back(std::move(b));
  std::sort(bodies_.begin(), bodies_.end(), [](const auto &a, const auto &b) { return a.state.id < b.state.id; });
}
void Traffic::retain(std::span<const std::string> ids) {
  std::erase_if(bodies_, [&](const auto &b) { return std::find(ids.begin(), ids.end(), b.state.id) == ids.end(); });
}
void Traffic::clear() { bodies_.clear(); furniture_.clear(); time_ = 0; nextTicket_ = 1; }
void Traffic::pin(const std::string &id, bool value) { body(id).state.pinned = value; }
void Traffic::face(const std::string &id, float yaw) { auto &b = body(id); b.facingTarget = yaw; b.hasFacing = true; }
void Traffic::setSpeed(const std::string &id, float metresPerSecond) {
  if (!std::isfinite(metresPerSecond) || metresPerSecond < 0)
    throw std::invalid_argument("Traffic speed must be finite and nonnegative");
  body(id).targetSpeed = std::min(metresPerSecond, maxSpeed);
}
void Traffic::cancel(const std::string &id) {
  auto &b = body(id);
  b.path.clear(); b.requestedPath.clear(); b.resumePath.clear();
  b.state.active = b.state.pending = b.state.yielding = b.state.translating = false;
  b.state.arrived = true; b.state.waitingSeconds = 0; b.goal = b.state.position;
  b.state.motionSeconds = 0;
  b.state.currentSpeed = 0;
}
void Traffic::request(const std::string &id, Vec3 goal) {
  auto &b = body(id);
  cancel(id); b.goal = goal; b.socket = false; b.ownsChair = false; b.duration = 0;
  b.state.pending = true; b.state.arrived = false; b.state.pinned = false;
  b.ticket = nextTicket_++; b.retryAt = time_;
}
void Traffic::requestSocket(const std::string &id, std::vector<Vec3> path, float duration, float facing, bool ownsChair) {
  if (path.empty()) return;
  if ((duration > 0 && path.size() != 2) ||
      planarDistance(path.front(), state(id).position) > .002F)
    throw std::invalid_argument("Socket motion must start at the actor; timed transitions require two endpoints");
  request(id, path.back());
  auto &b = body(id);
  b.requestedPath = std::move(path); b.socket = true; b.ownsChair = ownsChair;
  b.duration = std::max(0.F, duration); b.lockedYaw = facing;
}
bool Traffic::conflicts(std::span<const Vec3> route, const Body &other) const {
  if (nearRoute(other.state.position, route, clearance)) return true;
  if (!other.state.active) return false;
  Vec3 previous = other.state.position;
  for (std::size_t j = other.cursor; j < other.path.size(); ++j) {
    for (std::size_t i = 1; i < route.size(); ++i)
      if (segmentDistance(route[i - 1], route[i], previous, other.path[j]) < clearance) return true;
    previous = other.path[j];
  }
  return false;
}
bool Traffic::reserve(Body &b) {
  std::vector<Vec3> path;
  if (b.socket) path = b.requestedPath;
  else {
    std::vector<Navigation::Disc> occupied;
    for (const auto &other : bodies_)
      if (other.state.id != b.state.id) occupied.push_back({other.state.position, clearance-radius});
    for (const auto &item : furniture_) occupied.push_back({item.position,item.radius+.025F});
    path = navigation_.smoothRoute(navigation_.route(b.state.position, b.goal, occupied, radius),occupied,radius);
  }
  if (path.empty()) return false;
  if (path.size() == 1) path.insert(path.begin(), b.state.position);
  for (const auto &other : bodies_)
    if (other.state.id != b.state.id && conflicts(path, other)) return false;
  for (const auto &item : furniture_)
    if ((!b.socket || !b.ownsChair || item.owner != b.state.id) && nearRoute(item.position,path,radius+item.radius+.025F)) return false;
  b.path = std::move(path); b.cursor = 1; b.elapsed = 0; b.state.motionSeconds = 0;
  b.state.currentSpeed = 0;
  b.state.active = true; b.state.pending = false; b.state.waitingSeconds = 0;
  return true;
}
bool Traffic::makeRoom(Body &requester) {
  if (requester.socket) return false;
  const auto direct = navigation_.route(requester.state.position, requester.goal, {}, radius);
  if (direct.empty()) return false;
  // The oldest blocked request keeps its ticket. A temporary pull-aside inherits
  // that priority; once parked the blocker resumes its original goal and ticket.
  for (auto &other : bodies_) {
    if (&other == &requester || other.state.active || other.state.pinned || other.state.yielding || other.socket ||
        !nearRoute(other.state.position, direct, clearance + .06F)) continue;
    std::vector<Navigation::Disc> occupied;
    for (const auto &b : bodies_)
      if (&b != &other) occupied.push_back({b.state.position, clearance-radius});
    for (const auto &item : furniture_) occupied.push_back({item.position,item.radius+.025F});
    std::vector<Vec3> best;
    float bestCost = std::numeric_limits<float>::max();
    for (const float range : {.75F, 1.1F, 1.5F, 2.1F}) {
      for (int direction = 0; direction < 16; ++direction) {
        const float angle = static_cast<float>(direction) * .392699082F;
        const Vec3 target = other.state.position + Vec3{std::sin(angle) * range, 0, std::cos(angle) * range};
        if (!navigation_.walkable(target, radius) || nearRoute(target, direct, clearance + .10F)) continue;
        auto path = navigation_.smoothRoute(navigation_.route(other.state.position, target, occupied, radius),occupied,radius);
        if (path.empty()) continue;
        bool conflict = false;
        for (const auto &b : bodies_)
          if (&b != &other && conflicts(path, b)) { conflict = true; break; }
        if (conflict) continue;
        float cost = 0;
        for (std::size_t i = 1; i < path.size(); ++i) cost += planarDistance(path[i - 1], path[i]);
        if (cost < bestCost) { bestCost = cost; best = std::move(path); }
      }
      if (!best.empty()) break;
    }
    if (best.empty()) continue;
    other.resumeGoal = other.goal; other.resumePath = other.requestedPath;
    other.resumeSocket = other.socket; other.resumePending = true;
    other.path = std::move(best); other.cursor = 1; other.elapsed = 0; other.duration = 0;
    other.state.yielding = other.state.active = true; other.state.pending = false;
    other.state.arrived = false; ++other.state.yields;
    return true;
  }
  return false;
}
void Traffic::finish(Body &b) {
  b.path.clear(); b.state.active = false; b.state.translating = false;
  b.state.currentSpeed = 0;
  if (b.state.yielding) {
    b.state.yielding = false; b.goal = b.resumeGoal; b.requestedPath = std::move(b.resumePath);
    b.socket = b.resumeSocket; b.state.pending = b.resumePending;
    b.state.arrived = !b.resumePending; b.retryAt = time_ + .4F;
  } else { b.state.arrived = true; ++b.state.completions; }
}
void Traffic::step(float seconds) {
  if (!std::isfinite(seconds) || seconds <= 0) return;
  // Bound swept steps even when a caller advances a long offline interval.
  if (seconds > .02001F) { const int count = static_cast<int>(std::ceil(seconds / .02F)); for (int i = 0; i < count; ++i) step(seconds / count); return; }
  time_ += seconds;
  std::vector<Body *> waiting;
  for (auto &b : bodies_) {
    b.state.translating = false;
    if (!b.state.active) b.state.currentSpeed = 0;
    if (b.state.pending) { b.state.waitingSeconds += seconds; if (time_ >= b.retryAt) waiting.push_back(&b); }
    if (!b.state.active && b.hasFacing) b.state.yaw = turn(b.state.yaw, b.facingTarget, turnSpeed * seconds);
  }
  std::sort(waiting.begin(), waiting.end(), [](const auto *a, const auto *b) {
    return a->ticket != b->ticket ? a->ticket < b->ticket : a->state.id < b->state.id;
  });
  for (auto *b : waiting) {
    if (!b->state.pending) continue;
    if (!reserve(*b)) {
      if (b->state.waitingSeconds > .5F) makeRoom(*b);
      b->retryAt = time_ + .3F;
    }
  }
  for (auto &b : bodies_) {
    if (!b.state.active || b.cursor >= b.path.size()) continue;
    const auto old = b.state.position;
    Vec3 next = old;
    auto nextCursor=b.cursor;
    float nextSpeed = 0;
    if (b.duration > 0 && !b.state.yielding) {
      b.state.yaw = turn(b.state.yaw, b.lockedYaw, turnSpeed * seconds);
      if (std::abs(std::remainder(b.lockedYaw - b.state.yaw, 6.283185307F)) > .05F) {
        b.state.currentSpeed = 0;
        continue;
      }
      b.elapsed = std::min(b.duration, b.elapsed + seconds);
      b.state.motionSeconds = b.elapsed;
      const float u = b.elapsed / b.duration, eased = u * u * (3 - 2 * u);
      next = b.path.front() + (b.path.back() - b.path.front()) * eased;
      nextSpeed = planarDistance(b.path.front(), b.path.back()) * 6.F * u * (1.F - u) / b.duration;
    } else {
      while (b.cursor < b.path.size() && planarDistance(old, b.path[b.cursor]) < 1e-5F) ++b.cursor;
      if (b.cursor >= b.path.size()) { finish(b); continue; }
      const auto delta = b.path[b.cursor] - old;
      const float desired = b.socket?avatarYaw(delta):routeHeading(b.path,b.cursor,old);
      b.state.yaw = turn(b.state.yaw, desired, turnSpeed * seconds);
      const float error = std::abs(std::remainder(avatarYaw(delta) - b.state.yaw, 6.283185307F));
      // Never translate while the character is facing away or making a tight turn.
      if (error > .32F) {
        b.state.currentSpeed = 0;
        continue;
      }
      const float previousSpeed = b.state.currentSpeed;
      nextSpeed = walkingSpeed(previousSpeed, b.targetSpeed * std::cos(error),
                               old,b.path,b.cursor,seconds);
      float travel = (previousSpeed + nextSpeed) * .5F * seconds;
      nextCursor=b.cursor;
      // Preserve the distance budget across curve samples. Throwing the
      // remainder away at every point creates visible acceleration pulses.
      while(travel>0 && nextCursor<b.path.size()) {
        const auto toward=b.path[nextCursor]-next;
        const float remaining=length(toward);
        if(remaining>travel) {next=next+toward*(travel/remaining);break;}
        next=b.path[nextCursor];travel-=remaining;++nextCursor;
        if(b.socket || (nextCursor<b.path.size()&&cornerSpeed(b.path,nextCursor-1)==0))break;
      }
      // The chord between render frames also has to stay inside the valid
      // corridor when a step crosses two sampled segments near furniture.
      if(!b.socket&&!navigation_.segmentWalkable(old,next,radius)) {
        const float budget=(previousSpeed+nextSpeed)*.5F*seconds;
        next=old+normalized(delta)*std::min(length(delta),budget);
        nextCursor=b.cursor+(planarDistance(next,b.path[b.cursor])<1e-5F?1:0);
      }
      if(planarDistance(old,next)>1e-6F&&dot(normalized(next-old),avatarForward(b.state.yaw))<std::cos(.32F)) {
        b.state.currentSpeed=0;continue;
      }
    }
    // Swept-disc guard covers the entire segment, not just the destination.
    bool safe = true;
    for (const auto &other : bodies_)
      if (&other != &b && pointSegment(other.state.position, old, next) < 2 * radius - 1e-4F) { safe = false; break; }
    for (const auto &item : furniture_)
      if ((!b.socket || !b.ownsChair || item.owner != b.state.id) && pointSegment(item.position,old,next)<radius+item.radius-1e-4F) { safe=false; break; }
    if (!safe) {
      b.elapsed = std::max(0.F, b.elapsed - seconds);
      b.state.currentSpeed = 0;
      continue;
    }
    b.state.distance += planarDistance(old, next);
    b.state.position = next;
    if(b.duration<=0||b.state.yielding)b.cursor=nextCursor;
    b.state.currentSpeed = nextSpeed;
    b.state.translating = planarDistance(old, next) > 1e-6F;
    if (b.duration > 0 && !b.state.yielding && b.elapsed >= b.duration) finish(b);
    else if (planarDistance(next, b.path.back()) < 1e-5F) finish(b);
  }
}
std::vector<TrafficState> Traffic::snapshot() const {
  std::vector<TrafficState> result;
  result.reserve(bodies_.size()); for (const auto &b : bodies_) result.push_back(b.state);
  return result;
}
} // namespace mokaid::engine
