#pragma once
#include "navigation.hpp"
#include <span>
#include <string>
#include <vector>

namespace mokaid::engine {
// glTF faces +Z; the native instance's Z reflection makes forward -Z.
inline Vec3 avatarForward(float yaw) { return {-std::sin(yaw), 0, -std::cos(yaw)}; }
inline float avatarYaw(Vec3 direction) { return std::atan2(-direction.x, -direction.z); }

struct TrafficState {
  std::string id;
  Vec3 position{};
  float yaw{}, distance{}, waitingSeconds{}, motionSeconds{};
  float currentSpeed{};
  bool active{}, pending{}, arrived{true}, yielding{}, pinned{}, translating{};
  std::uint64_t completions{}, yields{};
};

// Central, deterministic corridor reservations. Disjoint routes run together;
// intersecting routes wait FIFO, and a parked blocker can physically pull aside.
class Traffic {
public:
  explicit Traffic(const Navigation &navigation) : navigation_(navigation) {}
  void add(std::string id, Vec3 position, float yaw);
  void retain(std::span<const std::string> ids);
  void clear();
  TrafficState &state(const std::string &id);
  const TrafficState &state(const std::string &id) const;
  void pin(const std::string &id, bool pinned);
  void face(const std::string &id, float yaw);
  // Walking target in m/s. Changes ramp smoothly; timed socket poses retain
  // their authored translation curve. Values above maxSpeed are clamped.
  void setSpeed(const std::string &id, float metresPerSecond);
  void cancel(const std::string &id);
  void request(const std::string &id, Vec3 goal);
  // Caller verifies this short furniture socket corridor with Navigation.
  // Duration >0 synchronizes its smoothstep translation to a Blender transition.
  // Only an explicitly owned desk corridor may overlap its moved chair.
  void requestSocket(const std::string &id, std::vector<Vec3> path,
                     float duration = 0, float facing = 0, bool ownsChair = false);
  struct Furniture { std::string owner; Vec3 position; float radius{.40F}; };
  void setFurniture(std::vector<Furniture> furniture) { furniture_ = std::move(furniture); }
  void step(float seconds);
  std::vector<TrafficState> snapshot() const;
  static constexpr float radius = .35F;
  static constexpr float clearance = radius * 2 + .10F;
  static constexpr float speed = .90F;
  static constexpr float maxSpeed = 1.10F;
  static constexpr float acceleration = 1.6F;
  static constexpr float braking = 2.F;
  static constexpr float turnSpeed = 2.8F;

private:
  struct Body {
    TrafficState state;
    Vec3 goal{}, resumeGoal{};
    std::vector<Vec3> path, requestedPath, resumePath;
    std::size_t cursor{};
    std::uint64_t ticket{};
    float retryAt{}, elapsed{}, duration{}, lockedYaw{}, facingTarget{};
    float targetSpeed{speed};
    bool socket{}, resumeSocket{}, hasFacing{}, resumePending{}, ownsChair{};
  };
  Body &body(const std::string &id);
  const Body &body(const std::string &id) const;
  bool conflicts(std::span<const Vec3> route, const Body &other) const;
  bool reserve(Body &);
  bool makeRoom(Body &requester);
  void finish(Body &);
  const Navigation &navigation_;
  std::vector<Body> bodies_;
  std::vector<Furniture> furniture_;
  float time_{};
  std::uint64_t nextTicket_{1};
};
} // namespace mokaid::engine
