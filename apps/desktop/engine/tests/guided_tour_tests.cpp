#include <mokaid/engine/guided_tour.hpp>
#include <mokaid/engine/office.hpp>
#include <cmath>
#include <iostream>
#include <limits>
#include <map>
#include <stdexcept>

using namespace mokaid::engine;
namespace {
void expect(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
bool near(Vec3 a, Vec3 b) { return length(a - b) < .001F; }
float distanceToSegment(Vec3 p, Vec3 a, Vec3 b) {
  const auto delta = b - a;
  const float square = dot(delta, delta);
  return length(p - (a + delta * (square > 0 ? std::clamp(dot(p - a, delta) / square, 0.F, 1.F) : 0.F)));
}
bool onNetwork(Vec3 point, const std::vector<TourEdge> &edges) {
  for (const auto &edge : edges)
    for (std::size_t i = 1; i < edge.points.size(); ++i)
      if (distanceToSegment(point, edge.points[i - 1], edge.points[i]) < .001F) return true;
  return false;
}
void networkTests() {
  const auto nav = Navigation::fromGeometry({{-.15F, .15F, -3, 1}}, {}, {}, {-4, 4, -4, 4});
  const std::vector<TourStop> stops{
    {"entrance", "Entrance", -1, {-2, 0, -2}, {0, 1, 0}},
    {"desk_0", "Desk", 0, {2, 0, -2}, {2, 1.25F, -3}},
    {"lounge", "Lounge", -1, {-2, 0, 2}, {-2, 1, 3}},
    {"coffee", "Coffee", -1, {2, 0, 2}, {3, 1, 2}}
  };
  auto tour = GuidedTour::build(nav, stops);
  const auto same = GuidedTour::build(nav, stops);
  expect(tour.state().available && tour.stops().size() == 4, "Every authored destination is available");
  expect(tour.edges().size() == same.edges().size(), "Network generation is deterministic");
  for (std::size_t e = 0; e < tour.edges().size(); ++e) {
    const auto &edge = tour.edges()[e]; const auto &again = same.edges()[e];
    expect(edge.from == again.from && edge.to == again.to && edge.points.size() == again.points.size(), "Stable edges for the same geometry");
    for (std::size_t i = 1; i < edge.points.size(); ++i) {
      expect(near(edge.points[i], again.points[i]), "Stable route points");
      expect(nav.segmentWalkable(edge.points[i - 1], edge.points[i], GuidedTour::radius), "Every fixed path sweeps clear of furniture");
    }
  }
  expect(!tour.travelTo("desk_0") && !tour.state().active, "Overview never moves a visitor");
  expect(tour.enter(), "A connected office supports immersion");
  for (const auto &stop : tour.stops()) {
    expect(tour.travelTo(stop.id), "All destinations are reachable");
    for (int i = 0; tour.state().moving && i < 10000; ++i) {
      tour.advance(1.F / 60.F);
      expect(onNetwork(tour.state().position, tour.edges()), "Visitor cannot leave the visible baked network");
      expect(nav.walkable(tour.state().position), "Visitor never enters furniture");
    }
    expect(!tour.state().moving && near(tour.state().position, stop.position), "Travel arrives exactly at the selected stop");
  }
  const auto beforeInvalid = tour.state().position;
  expect(!tour.travelTo("arbitrary_floor_coordinate") && near(beforeInvalid, tour.state().position), "Unknown paths fail closed");
  tour.travelTo("entrance"); tour.advance(.25F); tour.stop();
  const auto paused = tour.state().position;
  const auto pausedLook = tour.state();
  tour.advance(10);
  expect(near(tour.state().position, paused), "Stop freezes position immediately");
  expect(tour.state().yaw == pausedLook.yaw && tour.state().pitch == pausedLook.pitch, "Stop also freezes automatic looking while interacting with an agent");
  expect(tour.travelTo("desk_0"), "Retargeting a paused visitor resumes along existing edges");
  tour.look(.7F, .2F);
  const auto manual = tour.state();
  for (int i = 0; tour.state().moving && i < 10000; ++i) {
    tour.advance(1.F / 60.F);
    expect(onNetwork(tour.state().position, tour.edges()), "Retargeting never creates a shortcut from mid-edge");
    expect(tour.state().yaw == manual.yaw && tour.state().pitch == manual.pitch, "Manual viewing survives turns and intermediate stops");
  }
  tour.look(0, 1000); expect(tour.state().pitch <= 1.15F, "Vertical look is ergonomic and bounded");
  const auto beforeNan = tour.state();
  tour.look(std::numeric_limits<float>::quiet_NaN(), 0); tour.advance(std::numeric_limits<float>::infinity());
  expect(tour.state().yaw == beforeNan.yaw && near(tour.state().position, beforeNan.position), "Nonfinite input cannot poison the camera");
  tour.setReducedMotion(true); tour.travelTo("entrance");
  const auto reduced = tour.state(); tour.advance(100);
  expect(tour.state().yaw == reduced.yaw && tour.state().pitch == reduced.pitch, "Reduced motion disables automatic camera rotation");
  tour.look(.7F, .2F);
  expect(tour.faceCurrentStop() && !tour.state().settling, "An explicitly requested reduced-motion conversation frames the destination instantly");
  const auto destination = std::find_if(tour.stops().begin(), tour.stops().end(), [&](const auto &stop) { return stop.id == tour.state().currentStop; });
  const auto toTarget = destination->target - (tour.state().position + Vec3{0, GuidedTour::eyeHeight, 0});
  expect(std::abs(std::remainder(tour.state().yaw - std::atan2(toTarget.x, -toTarget.z), 6.283185307F)) < .001F,
      "Reduced motion still permits face-to-face conversations without a rotating camera");
  const auto camera = tour.camera(1.7F);
  expect(near(camera.position, tour.state().position + Vec3{0, GuidedTour::eyeHeight, 0}), "First-person eye stays at human height");
  tour.exit(); expect(!tour.state().active && !tour.state().moving, "Exit cancels navigation");
  auto missing = GuidedTour::build({}, stops); expect(!missing.enter(), "Missing geometry cannot enable unsafe navigation");

  const auto divided = Navigation::fromGeometry({{-.1F, .1F, -4, 4}}, {}, {}, {-4, 4, -4, 4});
  const auto partial = GuidedTour::build(divided, stops);
  for (const auto &stop : partial.stops()) expect(stop.position.x < 0, "Unreachable rooms never expose an unsafe destination");
}
void edgeBoundaryTests() {
  const auto nav = Navigation::fromGeometry({}, {}, {}, {-4, 4, -4, 4});
  auto tour = GuidedTour::build(nav, {
    {"start", "Start", -1, {-1, 0, 0}, {0, 1, 0}},
    {"end", "End", -1, {1, 0, 0}, {0, 1, 0}},
    {"duplicate", "Same location", -1, {1, 0, 0}, {0, 1, 0}}
  });
  tour.enter(); tour.travelTo("end");
  const auto initial = tour.state().position;
  tour.advance(1.F / 60.F);
  expect(length(tour.state().position - initial) < GuidedTour::speed / 120.F,
      "Walking accelerates gently instead of jumping to full speed");
  tour.advance(4.F);
  expect(!tour.state().moving && tour.state().currentStop == "end", "Arrival is normalized eagerly after a large frame");
  expect(tour.travelTo("start"), "Immediate retarget after exact arrival is safe");
  tour.advance(4.F);
  expect(tour.travelTo("duplicate"), "Co-located destination remains selectable");
  tour.advance(20);
  expect(!tour.state().moving && tour.state().currentStop == "duplicate", "Zero-length edges complete without out-of-range waypoints");
  expect(tour.travelTo("start"), "Retarget after a zero-length edge is safe");
}
std::vector<Vec3> skinPositions(const Scene &scene, const Mesh &mesh, const Pose &pose) {
  const auto palette = skinMatrices(scene, mesh, pose);
  std::vector<Vec3> points;
  points.reserve(mesh.vertices.size());
  for (const auto &vertex : mesh.vertices) {
    const std::array joints{vertex.joints.x, vertex.joints.y, vertex.joints.z, vertex.joints.w};
    const std::array weights{vertex.weights.x, vertex.weights.y, vertex.weights.z, vertex.weights.w};
    Vec4 skinned{};
    for (std::size_t influence = 0; influence < joints.size(); ++influence) {
      const auto point = transform(palette[static_cast<std::size_t>(joints[influence])],
          {vertex.position.x, vertex.position.y, vertex.position.z, 1});
      skinned.x += point.x * weights[influence]; skinned.y += point.y * weights[influence];
      skinned.z += point.z * weights[influence]; skinned.w += point.w * weights[influence];
    }
    const auto world = transform(pose.world[mesh.node], skinned);
    points.push_back({world.x, world.y, world.z});
  }
  return points;
}
void gazePreservesSkin(const std::shared_ptr<const Scene> &scene, std::string_view assetKey) {
  Instance actor{scene, Mat4::identity(), "sitting", .37F, {}};
  const auto resting = evaluateInstancePose(actor);
  const auto pelvis = scene->skins.front().joints.front();
  const float metersPerSourceUnit = 1.75F / scene->referenceHeight;
  // Test the full permitted turn in both directions, including UV seams where
  // the source stores separate vertices at the same surface position.
  for (const float angle : {-1.48F, 1.48F}) {
    actor.nodeRotations = {
      {static_cast<std::uint32_t>(scene->gazeChest), {0, std::sin(angle * .35F / 2), 0, std::cos(angle * .35F / 2)}},
      {static_cast<std::uint32_t>(scene->gazeHead), {0, std::sin(angle * .65F / 2), 0, std::cos(angle * .65F / 2)}}
    };
    const auto turned = evaluateInstancePose(actor);
    expect(resting.world[pelvis].m == turned.world[pelvis].m,
        "Conversation turns keep the seated pelvis and feet anchored");
    std::size_t checkedSeams = 0;
    for (const auto &mesh : scene->meshes) {
      if (mesh.skin < 0) continue;
      const auto before = skinPositions(*scene, mesh, resting), after = skinPositions(*scene, mesh, turned);
      std::map<std::array<float, 3>, std::size_t> firstAtPosition;
      for (std::size_t index = 0; index < mesh.vertices.size(); ++index) {
        const auto &point = after[index];
        expect(std::isfinite(point.x) && std::isfinite(point.y) && std::isfinite(point.z),
            "Conversation poses produce finite skinned geometry for every avatar");
        const auto &source = mesh.vertices[index].position;
        const auto [found, inserted] = firstAtPosition.emplace(std::array{source.x, source.y, source.z}, index);
        if (!inserted && length(before[index] - before[found->second]) * metersPerSourceUnit < .00001F) {
          // Authored duplicate vertices can differ by 0.02% skin weight after
          // compression (male neck seams), producing a measured 14µm shift at
          // full gaze. Reject visible openings at 0.1mm in world units, while
          // preserving those existing quantized influences.
          const auto gap = length(after[index] - after[found->second]) * metersPerSourceUnit;
          if (gap >= .0001F)
            throw std::runtime_error(std::string(assetKey) + ": conversation seam drift " + std::to_string(gap)
                + " at vertices " + std::to_string(index) + "," + std::to_string(found->second)
                + " (source height " + std::to_string(scene->referenceHeight) + ")");
          ++checkedSeams;
        }
      }
    }
    expect(checkedSeams > 0, "The asset regression exercised duplicated surface vertices");
  }
}
void realOffice(const std::filesystem::path &root) {
  for (const auto *key : {"male", "female", "corporate", "developer", "design", "finance", "research", "legal", "byte", "nyx", "moss"}) {
    const auto avatar = loadScene(root / (std::string("avatar_") + key + ".mokaidasset"));
    expect(avatar->gazeHead >= 0 && avatar->gazeChest >= 0,
        "Every stock avatar has a verified head/chest chain, including rigs without a crown tip");
    gazePreservesSkin(avatar, key);
  }
  Office office(false); office.setTourReducedMotion(true); office.load(root);
  const auto nav = Navigation::load(root / "office.mokaidnav");
  expect(office.tourState().available, "Real office has a connected guided network");
  const auto stops = office.tourStops(), repeatedStops = office.tourStops();
  expect(stops.size() == 17 && stops.size() == repeatedStops.size(), "All nine desks and eight common areas are present");
  for (int seat = 0; seat < 9; ++seat)
    expect(std::any_of(stops.begin(), stops.end(), [&](const auto &stop) { return stop.seat == seat; }), "Every physical desk has a visit stop");
  const auto edges = office.tourEdges();
  for (const auto &edge : edges)
    for (std::size_t p = 1; p < edge.points.size(); ++p)
      expect(nav.segmentWalkable(edge.points[p - 1], edge.points[p], GuidedTour::radius), "Real office paths never cross furniture or the footprint");
  std::vector<Agent> agents;
  for (int seat = 0; seat < 9; ++seat) agents.push_back({"agent_" + std::to_string(seat), "Agent", "working", "developer", seat, 1});
  office.setAgents(agents); office.advance(0); office.setPaused(true);
  const auto overview = office.snapshot(1.7F);
  expect(office.enterTour(), "Real office enters first-person");
  for (const float aspect : {.8F, 1.2F, 1.7F, 2.4F}) {
    const auto entered = office.snapshot(aspect);
    bool visibleAnchor = false;
    for (const auto &stop : office.visibleTourStops()) {
      const auto p = transform(entered->viewProjection,
          {stop.position.x, stop.position.y + .065F, stop.position.z, 1});
      visibleAnchor = visibleAnchor || (p.w > .05F && p.z >= 0 && p.z < p.w &&
          std::abs(p.x / p.w) < .9F && std::abs(p.y / p.w) < .9F);
    }
    expect(visibleAnchor, "Entering the office frames at least one clear clickable floor anchor at every desktop aspect");
  }
  const auto firstLook = office.tourState();
  office.travelTourTo("center"); office.advance(100);
  expect(office.tourState().yaw == firstLook.yaw && office.tourState().pitch == firstLook.pitch, "Reduced motion set before asynchronous loading survives network construction");
  office.setTourReducedMotion(false); office.exitTour(); office.enterTour();
  for (const auto &stop : stops) {
    expect(office.travelTourTo(stop.id), "Real destination selectable");
    office.advance(100);
    const auto state = office.tourState();
    expect(!state.moving && near(state.position, stop.position), "Camera moves independently of paused agent simulation");
    const auto frame = office.snapshot(1.7F);
    expect(near(frame->camera, state.position + Vec3{0, GuidedTour::eyeHeight, 0}), "Snapshot uses active first-person camera");
    if (stop.seat >= 0) {
      const auto body = office.debugMotion()[static_cast<std::size_t>(stop.seat)];
      const auto towardVisitor = stop.position - body.position;
      const float faceTurn = std::abs(std::remainder(avatarYaw(towardVisitor) - body.yaw, 6.283185307F));
      expect(faceTurn < 1.396264F && length(towardVisitor) >= .95F && length(towardVisitor) <= 2.5F,
          "Every conversation viewpoint is a clear front quarter within a natural seated turn");
      const auto id = "agent_" + std::to_string(stop.seat);
      const auto actor = std::find_if(frame->actorIndicators.begin(), frame->actorIndicators.end(), [&](const auto &a) { return a.id == id; });
      expect(actor != frame->actorIndicators.end(), "Posed agent is available to inspect");
      const auto head = actor->headWorld - Vec3{0, .1F, 0};
      const auto projected = transform(frame->viewProjection, {head.x, head.y, head.z, 1});
      expect(projected.w > 0 && std::abs(projected.x / projected.w) < 1 && std::abs(projected.y / projected.w) < 1, "A desk visit frames the seated agent's face");
      expect(office.pick(projected.x / projected.w * .5F + .5F, .5F - projected.y / projected.w * .5F, 1.7F) == id, "Clicking a close-up agent uses the rendered camera and posed head");
    }
  }
  // Changing aspect in immersion must not overwrite overview framing.
  office.snapshot(.6F); office.exitTour();
  const auto restored = office.snapshot(1.7F);
  expect(overview->viewProjection.m == restored->viewProjection.m && near(overview->camera, restored->camera), "Exit restores the exact original overview camera");
  expect(office.pick(-1, .5F, 1.7F).empty(), "Off-viewport clicks cannot select an agent");
  office.setPaused(false);
  expect(office.enterTour() && office.travelTourTo("desk_0"), "Conversation has a safe side-of-desk viewpoint");
  office.advance(100);
  const auto beforeChat = office.debugMotion().front();
  office.setConversationAgent("agent_0");
  for (int i = 0; i < 90; ++i) office.advance(1.F / 60.F);
  const auto chatting = office.snapshot(1.7F);
  const auto actor = std::find_if(chatting->instances.begin(), chatting->instances.end(),
      [](const auto &instance) { return instance.agentId == "agent_0"; });
  expect(actor != chatting->instances.end() && actor->nodeRotations.size() == 2,
      "Conversation distributes a smooth turn between chest and head");
  expect(actor->animation == "sitting", "Hands leave the keyboard before the torso turns");
  const auto afterChat = office.debugMotion().front();
  expect(near(beforeChat.position, afterChat.position) && beforeChat.yaw == afterChat.yaw,
      "A seated conversation never rotates the pelvis through the desk or chair");
  auto resting = *actor; resting.nodeRotations.clear();
  const auto basePose = evaluateInstancePose(resting), turnedPose = evaluateInstancePose(*actor);
  const auto pelvis = actor->scene->skins.front().joints.front();
  expect(basePose.world[pelvis].m == turnedPose.world[pelvis].m,
      "Additive conversation poses preserve the authored seated pelvis");
  for (const auto &matrix : turnedPose.world)
    for (const auto value : matrix.m) expect(std::isfinite(value), "Turned rig matrices remain finite");
  office.setConversationAgent("");
  for (int i = 0; i < 240; ++i) office.advance(1.F / 60.F);
  const auto resumed = office.snapshot(1.7F);
  const auto returned = std::find_if(resumed->instances.begin(), resumed->instances.end(),
      [](const auto &instance) { return instance.agentId == "agent_0"; });
  expect(returned != resumed->instances.end() && returned->nodeRotations.empty() && returned->animation != "sitting",
      "Closing conversation naturally returns the agent to its real work animation");
  for (const auto &stop : office.visibleTourStops())
    expect(length(stop.position - office.tourState().position) > .6F &&
        nav.segmentWalkable(office.tourState().position, stop.position, 0.F),
        "In-scene anchors do not appear through obstructing furniture");
  agents[0].status = "idle"; office.setAgents(agents);
  for (int i = 0; i < 900 && office.debugMotion().front().phase == "desk"; ++i) office.advance(.1F);
  expect(office.debugMotion().front().phase != "desk", "Fixture agent can leave its desk for normal office life");
  office.setConversationAgent("agent_0");
  for (int i = 0; i < 1800 && office.debugMotion().front().phase != "desk"; ++i) office.advance(.1F);
  expect(office.debugMotion().front().phase == "desk", "An approached leisure agent returns safely to its desk for the conversation");
  std::cout << "Real tour: " << stops.size() << " stops, " << edges.size() << " fixed connections\n";
}
}
int main(int argc, char **argv) {
  try {
    networkTests(); edgeBoundaryTests();
    if (argc > 1) realOffice(argv[1]);
    std::cout << "Guided tour tests passed\n";
    return 0;
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
