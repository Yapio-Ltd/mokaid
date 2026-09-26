#pragma once
#include "navigation.hpp"
#include "office_camera.hpp"
#include <string_view>

namespace mokaid::engine {
struct TourStop {
  std::string id, label;
  int seat{-1};
  Vec3 position, target;
};
struct TourEdge {
  std::string from, to;
  std::vector<Vec3> points;
};
struct TourState {
  bool available{}, active{}, moving{}, settling{};
  std::string currentStop, destination;
  Vec3 position;
  // Yaw zero faces -Z; positive yaw turns toward +X; positive pitch looks up.
  float yaw{}, pitch{}, progress{};
};

// The complete graph is baked once from collision geometry. Runtime input can
// select named destinations and change the view, but cannot create new paths.
class GuidedTour {
public:
  static constexpr float radius = .30F;
  static constexpr float eyeHeight = 1.62F;
  static constexpr float speed = 1.65F;
  static GuidedTour build(const Navigation &, std::vector<TourStop> candidates);
  bool enter();
  void exit();
  bool travelTo(std::string_view);
  void stop();
  void look(float deltaYaw, float deltaPitch);
  bool faceCurrentStop();
  void setReducedMotion(bool reduced) { reducedMotion_ = reduced; if (reduced) { autoLook_ = false; state_.settling = false; } }
  void advance(float seconds);
  OfficeCamera camera(float aspect) const;
  const TourState &state() const { return state_; }
  const std::vector<TourStop> &stops() const { return stops_; }
  const std::vector<TourEdge> &edges() const { return edges_; }

private:
  std::size_t index(std::string_view) const;
  std::vector<std::size_t> itinerary(std::size_t from, std::size_t to) const;
  void startNextEdge();
  void face(Vec3 target);
  std::vector<TourStop> stops_;
  std::vector<TourEdge> edges_;
  std::vector<std::vector<std::pair<std::size_t, std::size_t>>> neighbours_;
  std::vector<std::size_t> itinerary_;
  std::vector<Vec3> activePath_;
  std::size_t current_{}, edgeEnd_{}, waypoint_{};
  float travelled_{}, totalDistance_{}, desiredYaw_{}, desiredPitch_{}, travelSpeed_{};
  bool autoLook_{}, manualLook_{}, reducedMotion_{};
  TourState state_;
};
} // namespace mokaid::engine
