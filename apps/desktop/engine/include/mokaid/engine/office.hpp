#pragma once
#include "navigation.hpp"
#include "scene.hpp"
#include "office_camera.hpp"
#include "traffic.hpp"
#include <array>
#include <chrono>
#include <mutex>
#include <string_view>
#include <thread>
#include <unordered_map>

namespace mokaid::engine {
struct Seat {
  float x, z, yaw;
};
inline constexpr float deskSeatHeight = .51F;
inline constexpr float deskPresenceTarget = .85F;
inline constexpr std::size_t maxConcurrentLeisureAgents = 2;

constexpr float deskRecoverySeconds(float awaySeconds) {
  return awaySeconds * deskPresenceTarget / (1.F - deskPresenceTarget);
}
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
  int level{};
};
struct AgentPersonality {float pace{1},focus{1},sociability{.5F};std::uint32_t seed{};};
AgentPersonality agentPersonality(std::string_view id);
// /api/agents carries business status, which is not an animation name. Match
// the web's active/busy task mapping before constructing render instances.
inline std::string_view agentVisualState(std::string_view status,
                                        std::string_view presence, bool hasTask) {
  if (status == "active") return hasTask ? "working" : "idle";
  if (status == "busy") return hasTask ? "working" : "typing";
  if (status == "archived") return "offline";
  if (status == "idle") return presence == "online" ? "idle" : "offline";
  if (status.empty() || status == "available") return "idle";
  return status;
}
class Office {
public:
  explicit Office(bool threaded = true);
  ~Office();
  Office(const Office &) = delete;
  Office &operator=(const Office &) = delete;
  void load(const std::filesystem::path &);
  void setAgents(std::vector<Agent>);
  void setCustomAvatar(std::string key, std::shared_ptr<const Scene> scene);
  void setPaused(bool);
  // Headless fixtures use Office(false) and the same fixed-step simulation.
  void advance(float seconds);
  struct MotionDebug {
    std::string id, phase, activity, socket;
    Vec3 position;
    float yaw{}, distance{}, waitingSeconds{}, deskShare{1.F};
    bool moving{}, carrying{};
    std::uint64_t trips{}, yields{};
  };
  std::vector<MotionDebug> debugMotion() const;
  std::shared_ptr<const Frame> snapshot(float aspect) const;
  std::string pick(float normalizedX, float normalizedY, float aspect) const;
  std::uint64_t residentBytes() const;

private:
  void run(std::stop_token);
  void tick(float seconds);
  void publishFrame();
  const Navigation::ActivitySocket *socket(std::string_view id) const;
  mutable std::mutex mutex_;
  // Rendering reads only completed immutable frames, never waits for A*.
  mutable std::mutex frameMutex_;
  std::shared_ptr<const Scene> office_;
  std::vector<Vec3> cameraPoints_;
  mutable float cameraAspect_{};
  mutable OfficeCamera camera_;
  std::vector<std::pair<std::string, std::shared_ptr<const Scene>>> avatars_;
  std::vector<Agent> agents_;
  std::shared_ptr<const Frame> frame_;
  struct Motion {
    enum class Phase { Desk, Stand, Exit, Travel, Enter, Align, Sit, Activity, WaitPartner, Pullback, RollSettle, PushIn };
    Phase phase{Phase::Desk};
    std::string socketId, targetId, chatId, partnerId, activity{"sitting"};
    std::string deskGesture{"typing"},gait{"walking"};
    AgentPersonality personality;
    std::uint32_t randomState{};
    float gestureUntil{},gestureStarted{},gesturePhase{},socialUntil{},socialOffset{};
    std::size_t socialBeat{};
    bool sofaCoffee{},greetingDone{},returningCup{},awaitSofaEntry{};
    std::string arrivalSocket;
    std::vector<Vec3> arrivalRoute,exitRoute;
    float phaseStarted{}, holdUntil{}, enteredAt{}, phaseDistance{};
    float leisureStartedAt{-1.F}, deskSeconds{}, awaySeconds{};
    std::size_t cycle{}, waypoint{};
    std::uint64_t trips{};
    bool carrying{}, returning{}, transitionStarted{};
    AnimationMixer animation;
  };
  float random(Motion &);
  void updateDeskGesture(const Agent &,Motion &);
  const Scene &avatar(const Agent &) const;
  std::vector<Navigation::Disc> chairDiscs() const;
  std::vector<Vec3> sofaRoute(const Navigation::ActivitySocket &,std::span<const Navigation::Disc>) const;
  bool loungeReserved(bool screenLeft) const;
  bool loungeOpen(bool screenLeft) const;
  void startSocial(const Agent &,Motion &,Motion &);
  void updateSocial(const Agent &,Motion &);
  bool continueAtSofa(const Agent &,Motion &);
  std::size_t committedLeisureAgents() const;
  void scheduleDeskRecovery(Motion &);
  void beginStand(const Agent &, Motion &);
  bool chooseMission(const Agent &, Motion &);
  void requestTravel(const Agent &, Motion &);
  void returnToDesk(const Agent &, Motion &);
  bool claim(std::string_view socketId, const std::string &agentId);
  void release(const std::string &agentId, std::string_view except = {});
  Navigation navigation_;
  Traffic traffic_{navigation_};
  std::vector<Navigation::ActivitySocket> sockets_;
  std::unordered_map<std::string, std::vector<Vec3>> socketRoutes_;
  std::unordered_map<std::string, std::string> claims_;
  std::array<float,9> chairOffsets_{};
  std::unordered_map<std::string, Motion> motion_;
  bool paused_{};
  float seconds_{};
  std::uint64_t sequence_{};
  std::jthread worker_;
};
} // namespace mokaid::engine
