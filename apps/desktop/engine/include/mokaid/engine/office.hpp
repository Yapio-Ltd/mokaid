#pragma once
#include "navigation.hpp"
#include "scene.hpp"
#include <array>
#include <chrono>
#include <mutex>
#include <thread>
#include <unordered_map>

namespace mokaid::engine {
struct Seat {
  float x, z, yaw;
};
inline constexpr float deskSeatHeight = .51F;
// Stable physical seat indices from office-navdata.ts; glTF RH uses reflected
// Z.
inline constexpr std::array<Seat, 9> seats = {{{1.682F, 4.243F, .0013F},
                                               {5.157F, 2.781F, -.0151F},
                                               {-2.008F, 2.157F, 3.1053F},
                                               {3.252F, .540F, 1.7097F},
                                               {1.750F, .520F, -1.7620F},
                                               {-6.019F, -.665F, -2.5970F},
                                               {-.854F, -1.075F, 3.0795F},
                                               {5.163F, -1.445F, -3.1329F},
                                               {2.158F, -3.190F, 3.1079F}}};
struct Agent {
  std::string id, name, status, assetType;
  int seat{-1};
};
class Office {
public:
  Office();
  ~Office();
  Office(const Office &) = delete;
  Office &operator=(const Office &) = delete;
  void load(const std::filesystem::path &);
  void setAgents(std::vector<Agent>);
  void setPaused(bool);
  std::shared_ptr<const Frame> snapshot(float aspect) const;
  std::string pick(float normalizedX, float normalizedY, float aspect) const;
  std::uint64_t residentBytes() const;

private:
  void run(std::stop_token);
  mutable std::mutex mutex_;
  std::shared_ptr<const Scene> office_;
  std::vector<std::pair<std::string, std::shared_ptr<const Scene>>> avatars_;
  std::vector<Agent> agents_;
  std::shared_ptr<const Frame> frame_;
  struct Motion {
    Vec3 position;
    float yaw{}, restUntil{};
    bool atDesk{true}, wasWorking{};
    std::vector<Vec3> route;
    std::size_t routeIndex{}, waypoint{};
    AnimationMixer animation;
  };
  Navigation navigation_;
  std::unordered_map<std::string, Motion> motion_;
  bool paused_{};
  float seconds_{};
  std::uint64_t sequence_{};
  std::jthread worker_;
};
} // namespace mokaid::engine
