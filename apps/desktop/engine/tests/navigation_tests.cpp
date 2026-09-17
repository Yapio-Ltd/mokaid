#include <mokaid/engine/navigation.hpp>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <unordered_set>

using namespace mokaid::engine;
namespace {
void expect(bool value, const char *message) {
  if (!value) throw std::runtime_error(message);
}
bool exact(Vec3 a, Vec3 b) { return a.x == b.x && a.y == b.y && a.z == b.z; }
constexpr Navigation::Box bounds{-3, 3, -3, 3};
void validatePath(const Navigation &nav, const std::vector<Vec3> &path,
                  Vec3 start, Vec3 goal, std::span<const Navigation::Disc> blocked = {},
                  float radius = .30F) {
  expect(!path.empty(), "Expected connected route");
  expect(exact(path.front(), start) && exact(path.back(), goal),
         "Routing must preserve the caller's exact endpoints");
  for (std::size_t i = 1; i < path.size(); ++i)
    expect(nav.segmentWalkable(path[i - 1], path[i], radius, blocked),
           "Every simplified route segment must clear its full swept disc");
}
void sweptGeometry() {
  const auto nav = Navigation::fromGeometry({{-.001F, .001F, -.6F, .6F}}, {}, {}, bounds);
  expect(nav.walkable({-1, 0, 0}) && nav.walkable({1, 0, 0}), "Sweep endpoints clear");
  expect(!nav.segmentWalkable({-1, 0, 0}, {1, 0, 0}),
         "A thin divider between clear endpoints must block a continuous sweep");
  expect(!nav.segmentWalkable({-1, 0, .85F}, {1, 0, .85F}),
         "The complete disc must clear the divider's rounded end");
  expect(nav.segmentWalkable({-1, 0, .91F}, {1, 0, .91F}),
         "A capsule with full clearance can pass the divider end");
  expect(!nav.walkable({2.8F, 0, 0}), "Radius is included at footprint edges");
  expect(!nav.walkable({0, 0, 0}, 0), "Zero-radius points inside walls remain blocked");
  expect(!nav.segmentWalkable({0, 0, 2}, {0, 0, 2}, -.1F), "Negative radius rejected");
  const float nan = std::numeric_limits<float>::quiet_NaN();
  expect(!nav.walkable({nan, 0, 0}) && !nav.segmentWalkable({}, {0, nan, 0}),
         "Nonfinite coordinates fail closed");
  expect(Navigation{}.route({}, {1, 0, 1}).empty(), "Unloaded navigation cannot route");
}
void routing() {
  const auto nav = Navigation::fromGeometry({{-.15F, .15F, -2.F, 1.1F}}, {}, {}, bounds);
  const Vec3 start{-1.873F, 0, -.917F}, goal{1.823F, 0, -.963F};
  auto route = nav.route(start, goal);
  validatePath(nav, route, start, goal);
  expect(route.size() > 2 && route.size() < 15, "Safe line-of-sight simplification removes grid jitter");
  expect(nav.route({0, 0, 0}, goal).empty(), "Blocked starts cannot be silently projected");
  expect(nav.route(start, {0, 0, 0}).empty(), "Blocked goals cannot be silently projected");
  const auto blocked = Navigation::fromGeometry({{-.1F, .1F, -3.F, 3.F}}, {}, {}, bounds);
  expect(blocked.route(start, goal).empty(), "A wall across the room has no route");
  const auto nearest = blocked.nearestReachable(goal, start, 3.F);
  expect(nearest && nearest->x < -.39F && !blocked.route(start, *nearest).empty(),
         "Nearest reachable point must stay in the source's connected component");
  expect(!blocked.nearestReachable(goal, start, .1F), "Projection distance is bounded");
  const auto open = Navigation::fromGeometry({}, {}, {}, bounds);
  expect(!open.empty(), "Synthetic navigation works without patrol lanes");
  validatePath(open, open.route(start, goal), start, goal);
  expect(open.route(start, start).size() == 1, "Already arrived route stays exact");
  const std::vector<Navigation::Disc> discs{{{0, 0, 0}, .5F}};
  const Vec3 a{-2, 0, 0}, b{2, 0, 0};
  const auto detour = open.route(a, b, discs, .35F);
  validatePath(open, detour, a, b, discs, .35F);
  expect(detour.size() > 2, "Dynamic occupancy must affect route choice");
  for (std::size_t i = 1; i < detour.size(); ++i)
    for (int sample = 0; sample <= 200; ++sample) {
      const auto p = detour[i - 1] + (detour[i] - detour[i - 1]) * (sample / 200.F);
      expect(p.x * p.x + p.z * p.z >= .8499F * .8499F,
             "Detour body radius must remain outside another agent's body");
    }
}
void narrowAisle() {
  // The office's right-hand aisle has one usable lattice column beside a
  // furniture edge. Rounding the lattice multiply and add separately used to
  // put that entire column inside the wall on x86, isolating two real desks.
  const auto nav = Navigation::fromGeometry(
      {{-7.3F, 6.15F, -.9F, .9F}}, {}, {},
      {-7.3F, 6.95F, -6.35F, 6.35F});
  const Vec3 start{5, 0, -2}, goal{5, 0, 2};
  expect(!nav.segmentWalkable(start, goal, .35F),
         "The narrow-aisle route must go around the furniture");
  validatePath(nav, nav.route(start, goal, {}, .35F), start, goal, {}, .35F);
}
void roundedWalkingRoutes() {
  const auto open = Navigation::fromGeometry({}, {}, {}, bounds);
  const std::vector<Vec3> corner{{-2, .1F, 0}, {0, .2F, 0}, {0, .3F, 2}};
  const auto rounded = open.smoothRoute(corner, {}, .35F);
  validatePath(open, rounded, corner.front(), corner.back(), {}, .35F);
  expect(rounded.size() > 10, "A walking corner becomes a sampled circular arc");
  expect(std::abs(rounded[1].x + .65F) < .0001F &&
             std::abs(rounded[rounded.size() - 2].z - .65F) < .0001F,
         "The default walking arc uses a .65 metre turning radius");
  const auto direction = [](Vec3 from, Vec3 to) {
    auto delta = to - from; delta.y = 0; return normalized(delta);
  };
  const auto smoothHeadings = [&](const std::vector<Vec3> &path) {
    for (std::size_t i = 1; i + 1 < path.size(); ++i)
      expect(dot(direction(path[i - 1], path[i]), direction(path[i], path[i + 1])) >= std::cos(.1001F),
             "Sampled arcs and their tangent joins turn by at most .10 radians per point");
  };
  smoothHeadings(rounded);
  for (std::size_t i = 1; i + 1 < rounded.size(); ++i) {
    const float x = rounded[i].x + .65F, z = rounded[i].z - .65F;
    expect(std::abs(std::sqrt(x * x + z * z) - .65F) < .0001F,
           "Arc samples follow the tangent circle with constant curvature");
    if (i > 1) {
      auto delta = rounded[i] - rounded[i - 1]; delta.y = 0;
      expect(length(delta) <= .06001F, "Arc chord length is bounded for smooth steering");
    }
  }
  const std::vector<Vec3> bends{{-2, 0, -1}, {0, 0, -1}, {0, 0, 1}, {2, 0, 1}};
  const auto multi = open.smoothRoute(bends, {}, .35F);
  validatePath(open, multi, bends.front(), bends.back(), {}, .35F);
  smoothHeadings(multi);
  expect(multi.size() > 20, "Consecutive opposite turns both receive tangent arcs");

  const auto furniture = Navigation::fromGeometry({{-1, -.35F, .35F, 1}}, {}, {}, bounds);
  const auto narrow = furniture.smoothRoute(corner, {}, .35F);
  validatePath(furniture, narrow, corner.front(), corner.back(), {}, .35F);
  expect(narrow.size() > 3 && narrow[1].x > -.60F,
         "A rounded furniture corner shrinks the arc instead of cutting its body clearance");
  smoothHeadings(narrow);
  const std::vector<Navigation::Disc> colleague{{{-.60F, 0, .60F}, .25F}};
  const auto occupied = open.smoothRoute(corner, colleague, .35F);
  validatePath(open, occupied, corner.front(), corner.back(), colleague, .35F);
  expect(occupied.size() > 3 && occupied[1].x > -.60F,
         "Dynamic discs constrain the fillet itself, not just its endpoints");
  smoothHeadings(occupied);

  const std::vector<Vec3> shortLeg{{-1, 0, 0}, {0, 0, 0}, {0, 0, .05F}, {1, 0, .05F}};
  const auto tight = open.smoothRoute(shortLeg, {}, .35F);
  expect(tight.size() == shortLeg.size(), "Turns with insufficient tangent distance remain explicit sharp corners");
  for (std::size_t i = 0; i < tight.size(); ++i)
    expect(exact(tight[i], shortLeg[i]), "Tight corners are never moved to manufacture clearance");
  const std::vector<Vec3> reversal{{-1, 0, 0}, {0, 0, 0}, {-1, 0, .001F}};
  expect(open.smoothRoute(reversal, {}, .35F).size() == reversal.size(),
         "A near reversal requires the original physical stop and turn");
  const std::vector<Vec3> straight{{-.7F, 0, 0}, {.7F, 0, 0}};
  const auto unchanged = open.smoothRoute(straight, {}, .35F);
  expect(unchanged.size() == 2 && exact(unchanged.front(), straight.front()) && exact(unchanged.back(), straight.back()),
         "Straight routes preserve their exact authored endpoints");
  const std::vector<Navigation::Disc> occupiedGoal{{corner.back(), .45F}};
  expect(open.smoothRoute(corner, occupiedGoal, .35F).empty(),
         "Smoothing cannot rescue a route whose destination is occupied");
  const auto divider = Navigation::fromGeometry({{-.02F, .02F, -1, 1}}, {}, {}, bounds);
  expect(divider.smoothRoute(straight, {}, .35F).empty(),
         "Input routes that cross a wall fail closed before smoothing");
  expect(open.smoothRoute(corner, {}, .35F, std::numeric_limits<float>::quiet_NaN()).empty(),
         "Nonfinite turning radii are rejected");
}
void socketCorridors() {
  const Vec3 socket{0, 0, 0}, entry{0, 0, .4025F};
  const auto nav = Navigation::fromGeometry({{-.2F, .2F, -.2F, .2F},
                                             {-.8F, .8F, .7F, 1.2F}}, {}, {}, bounds);
  const auto route = nav.socketRoute(socket, entry, {0, 0, 1}, .35F);
  expect(!route.empty() && exact(route.front(), entry), "Seat egress preserves the authored feet marker");
  expect(nav.walkable(route.back(), .35F), "Seat egress must finish in ordinary walkable space");
  for (std::size_t i = 1; i < route.size(); ++i) {
    expect(route[i].z >= .08F || route[i].x * route[i].x + route[i].z * route[i].z >= .75F * .75F,
           "A rearward exit must go around the full chair hull");
    expect(nav.socketSegmentWalkable(socket, entry, route[i - 1], route[i], .35F),
           "Each egress edge obeys the local furniture ownership rules");
  }
  expect(!nav.socketSegmentWalkable(socket, entry, entry, {0, 0, -.6F}, .35F),
         "Rearward shortcut through the chair is forbidden");
  expect(!nav.socketSegmentWalkable(socket, entry, {-.85F, 0, -.3F}, {.85F, 0, -.3F}, .35F),
         "Two clear endpoints cannot conceal a sweep through the backrest");
  expect(nav.socketSegmentWalkable(socket, entry, {.8F, 0, -.3F}, {.8F, 0, -.8F}, .35F),
         "Walking around the outside of a chair is allowed");
  expect(!nav.socketSegmentWalkable(socket, entry, entry, {0, 0, .85F}, .35F),
         "Initial tabletop overlap may only be exited, never entered more deeply");
  const auto strict = Navigation::fromGeometry({{-.2F, .2F, -.2F, .2F},
                                                {-.4F, .4F, 1.F, 1.3F}}, {}, {}, bounds);
  expect(!strict.socketSegmentWalkable(socket, entry, entry, {0, 0, 1.4F}, .35F),
         "A local seat corridor cannot cross unrelated furniture");
  expect(nav.socketRoute(socket, entry, {0, 0, 1}, .35F, socket).empty(),
         "A rolled-chair standing marker cannot remain under the tabletop");
  const Vec3 movedSocket{0, 0, -.6F}, movedEntry{0, 0, -.1975F};
  const auto rolled = nav.socketRoute(movedSocket, movedEntry, {0, 0, 1}, .35F, socket);
  expect(!rolled.empty() && exact(rolled.front(), movedEntry),
         "Moving the physical chair removes only its old local hull");
  for (std::size_t i = 1; i < rolled.size(); ++i)
    expect(nav.socketSegmentWalkable(movedSocket, movedEntry, rolled[i - 1], rolled[i], .35F, socket),
           "A rolled chair exit clears every unrelated obstacle");
  const auto doorway = Navigation::fromGeometry(
      {{-.2F, .2F, -.2F, .2F}, {-.15F, .15F, -3.F, -.55F},
       {-.15F, .15F, .55F, 3.F}}, {{2, 0, 0}}, {{0}}, bounds);
  expect(doorway.socketRoute({}, {-.4025F, 0, 0}, {-1, 0, 0}, .35F, Vec3{}).empty(),
         "A socket exit cannot strand its actor behind its own moved chair in a doorway");
  Navigation::ActivitySocket sofa{"sofa", 1, socket, {0, 0, .245F}, 0, .48F, 4};
  const auto lounge = Navigation::fromGeometry({{-1.2F, 1.2F, -.5F, .1F},
                                                {-1.3F, 1.3F, .1F, .2F}}, {}, {}, bounds, {sofa});
  const auto sofaRoute = lounge.socketRoute(socket, sofa.approach, {0, 0, 1}, .35F);
  expect(!sofaRoute.empty() && exact(sofaRoute.front(), sofa.approach) &&
             lounge.walkable(sofaRoute.back(), .35F),
         "A known sofa exits its own cushion and front lip into the aisle");
  const auto clearFloor = Navigation::fromGeometry({}, {}, {}, bounds);
  const std::vector<Navigation::Disc> chair{{{0, 0, 1.1F}, .425F}};
  expect(!clearFloor.segmentWalkable(sofaRoute.back(), sofaRoute.back(), .35F, chair),
         "The fixture's moved chair occupies the original sofa terminus");
  const auto detour = lounge.socketRoute(socket, sofa.approach, {0, 0, 1}, .35F, {}, chair);
  expect(!detour.empty() && exact(detour.front(), sofa.approach) &&
             lounge.walkable(detour.back(), .35F),
         "A dynamic chair selects an alternative sofa exit without relocating its standing marker");
  for (std::size_t i = 1; i < detour.size(); ++i) {
    expect(lounge.socketSegmentWalkable(socket, sofa.approach, detour[i - 1], detour[i], .35F),
           "Alternative sofa exits keep the same static furniture constraints");
    expect(clearFloor.segmentWalkable(detour[i - 1], detour[i], .35F, chair),
           "Every simplified sofa exit segment respects dynamic furniture discs");
  }
  const std::vector<Navigation::Disc> occupiedEntry{{sofa.approach, .45F}};
  expect(lounge.socketRoute(socket, sofa.approach, {0, 0, 1}, .35F, {}, occupiedEntry).empty(),
         "An occupied standing marker cannot be projected through another actor");
  const std::vector<Navigation::Disc> invalid{{{}, std::numeric_limits<float>::quiet_NaN()}};
  expect(lounge.socketRoute(socket, sofa.approach, {0, 0, 1}, .35F, {}, invalid).empty(),
         "Invalid dynamic socket blockers fail closed");
}
struct Pack {
  std::vector<char> bytes;
  explicit Pack(const char *magic) : bytes(magic, magic + 8) {}
  template<class T> void add(T value) {
    const auto *p = reinterpret_cast<const char *>(&value);
    bytes.insert(bytes.end(), p, p + sizeof value);
  }
  void text(const std::string &value) {
    add(static_cast<std::uint32_t>(value.size()));
    bytes.insert(bytes.end(), value.begin(), value.end());
  }
  void minimalGeometry() {
    add(1U);
    for (float value : {-6.F, -5.F, -5.F, -4.F}) add(value);
    add(1U); add(0.F); add(0.F);
    add(1U); add(1U); add(0U);
  }
};
void packValidation() {
  const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
  const auto path = std::filesystem::temp_directory_path() /
                    ("mokaid-navigation-" + std::to_string(stamp) + ".pack");
  struct Cleanup { std::filesystem::path p; ~Cleanup() { std::error_code ec; std::filesystem::remove(p, ec); } } cleanup{path};
  const auto write = [&](const Pack &p) { std::ofstream f(path, std::ios::binary); f.write(p.bytes.data(), p.bytes.size()); };
  const auto rejected = [&](const Pack &p) {
    write(p);
    try { (void)Navigation::load(path); return false; }
    catch (const std::runtime_error &) { return true; }
  };
  Pack v1("MOKANAV1"); v1.minimalGeometry(); write(v1);
  expect(!Navigation::load(path).empty(), "Legacy MOKANAV1 packs stay readable");
  expect(!Navigation::load(path).walkable({6.3F, 0, -5.5F}),
         "The real office bevel is enforced independently of obstacle boxes");
  expect(Navigation::fromGeometry({}).walkable({6.3F, 0, -5.5F}),
         "Synthetic scenes do not inherit the office's bevel");
  Pack v2("MOKANAV2"); v2.minimalGeometry(); v2.add(1U); v2.text("desk_0");
  const auto kindOffset = v2.bytes.size(); v2.add(0U);
  for (float value : {1.F, 2.F, 1.2F, 2.3F, .25F, .51F, 8.F}) v2.add(value);
  write(v2); const auto nav = Navigation::load(path);
  expect(nav.sockets().size() == 1 && nav.sockets()[0].id == "desk_0" &&
             nav.sockets()[0].position.z == 2.F && nav.sockets()[0].approach.x == 1.2F &&
             nav.sockets()[0].seatHeight == .51F,
         "MOKANAV2 preserves authored socket coordinates and timing");
  auto v3 = v2; v3.bytes[7] = '3';
  v3.add(std::int32_t{42}); v3.add(.65F);
  v3.add(.1F); v3.add(0.F); v3.add(.6F);
  v3.add(1U);
  for (float value : {-7.381761F, -4.393354F, -2.386491F, 1.822855F, .064917F}) v3.add(value);
  write(v3); const auto movable = Navigation::load(path);
  expect(movable.sockets()[0].chairNode == 42 &&
             movable.sockets()[0].pullback == .65F &&
             movable.sockets()[0].chairLocalDelta.z == .6F,
         "MOKANAV3 preserves the physical chair node and pullback transform");
  expect(movable.floorHeightAt({-6, 0, 0}) == .064917F &&
             movable.floorHeightAt({0, 0, 0}) == 0,
         "Raised platform height comes from its actual authored footprint");
  auto invalidFloor = v3;
  const float nonfiniteHeight = std::numeric_limits<float>::quiet_NaN();
  std::memcpy(invalidFloor.bytes.data() + invalidFloor.bytes.size() - 4, &nonfiniteHeight, 4);
  expect(rejected(invalidFloor), "Nonfinite floor heights rejected");
  auto invalidChair = v3;
  const std::int32_t missing = -2;
  std::memcpy(invalidChair.bytes.data() + v2.bytes.size(), &missing, sizeof missing);
  expect(rejected(invalidChair), "Invalid physical chair node rejected");
  auto truncated = v2; truncated.bytes.pop_back(); expect(rejected(truncated), "Truncated socket packs rejected");
  auto trailing = v1; trailing.add(1U); expect(rejected(trailing), "Trailing navigation data rejected");
  Pack nan("MOKANAV1"); nan.add(1U);
  for (float value : {std::numeric_limits<float>::quiet_NaN(), 1.F, 0.F, 1.F}) nan.add(value);
  nan.add(0U); nan.add(0U); expect(rejected(nan), "Nonfinite obstacle extents rejected");
  auto lane = v1; const std::uint32_t invalidIndex = 1;
  std::memcpy(lane.bytes.data() + lane.bytes.size() - 4, &invalidIndex, 4);
  expect(rejected(lane), "Invalid lane anchor index rejected");
  auto emptyLane = v1; emptyLane.bytes.resize(emptyLane.bytes.size() - 4);
  const std::uint32_t noAnchors = 0;
  std::memcpy(emptyLane.bytes.data() + emptyLane.bytes.size() - 4, &noAnchors, 4);
  expect(rejected(emptyLane), "Empty lanes rejected before modulo operations");
  auto invalidKind = v2;
  const std::uint32_t kind = 5; std::memcpy(invalidKind.bytes.data() + kindOffset, &kind, sizeof kind);
  expect(rejected(invalidKind), "Unknown socket kinds rejected");
  Pack empty("MOKANAV1"); empty.add(0U); empty.add(0U); empty.add(0U);
  expect(rejected(empty), "A broken empty office pack cannot make furniture disappear from navigation");
}
void realAssets(const std::filesystem::path &root) {
  const auto nav = Navigation::load(root / "office.mokaidnav");
  expect(nav.sockets().size() >= 17, "Real navigation must contain the full activity socket catalog");
  std::unordered_set<std::int32_t> chairNodes;
  std::vector<Vec3> coffeeGroup;
  std::vector<float> foosballYaw;
  std::size_t desks = 0, sofas = 0, standing = 0;
  for (const auto &s : nav.sockets()) {
    const Vec3 forward{-std::sin(s.yaw), 0, -std::cos(s.yaw)};
    if (s.kind <= 1) {
      Vec3 moved = s.position, entry = s.approach;
      std::optional<Vec3> owner;
      if (s.kind == 0) {
        ++desks;
        expect(s.chairNode >= 0 && s.pullback > 0 && chairNodes.insert(s.chairNode).second,
               "Every desk must own a separate movable chair");
        moved = s.position - forward * s.pullback;
        entry = moved + forward * .4025F;
        owner = s.position;
        expect(nav.socketSegmentWalkable(s.position, s.position, s.position, moved, .35F),
               "The occupied chair must roll out without entering another obstacle");
      } else {
        ++sofas;
      }
      const auto route = nav.socketRoute(moved, entry, forward, .35F, owner);
      if (route.empty()) throw std::runtime_error("No safe real socket exit: " + s.id);
      expect(exact(route.front(), entry) && nav.walkable(route.back(), .35F),
             "Real socket exits preserve their standing marker and end in walkable space");
      expect(length(route.back() - moved) >= .7999F,
             "Walking starts beyond the moved chair's dynamic collision disc");
      for (std::size_t i = 1; i < route.size(); ++i)
        expect(nav.socketSegmentWalkable(moved, entry, route[i - 1], route[i], .35F, owner),
               "A real socket exit segment must remain within its checked furniture corridor");
      const std::vector<Navigation::Disc> chair = owner
          ? std::vector<Navigation::Disc>{{moved, .425F}} : std::vector<Navigation::Disc>{};
      // A different anchor may be needed when this particular chair occupies
      // a sofa-side anchor; the route must reach at least one real patrol lane.
      bool connected = false;
      for (std::size_t lane = 0; lane < 9 && !connected; ++lane)
        connected = !nav.route(route.back(), nav.waypoint(lane, 0), chair, .35F).empty();
      expect(connected,
             "Real socket exits must reach the main office aisle");
    } else {
      ++standing;
      if (!nav.walkable(s.position, .35F))
        throw std::runtime_error("Blocked standing activity socket: " + s.id);
      if (nav.route(s.position, nav.waypoint(0, 0), {}, .35F).empty())
        throw std::runtime_error("Disconnected standing activity socket: " + s.id);
      if (s.kind == 2 || s.kind == 4) coffeeGroup.push_back(s.position);
      if (s.kind == 3) foosballYaw.push_back(s.yaw);
    }
  }
  expect(desks == 9 && sofas == 3 && standing >= 5, "Real office contains nine desks, three sofa seats and five standing activities");
  for (std::size_t i = 0; i < coffeeGroup.size(); ++i)
    for (std::size_t j = 0; j < i; ++j)
      expect(length(coffeeGroup[i] - coffeeGroup[j]) >= .85F,
             "Coffee and conversation slots must leave room for occupied agents");
  expect(foosballYaw.size() == 2 &&
             std::abs(std::abs(std::remainder(foosballYaw[0] - foosballYaw[1], 6.2831853F)) - 3.14159265F) < .05F,
         "Foosball players must face one another across opposite sides");
  std::cout << "Real navigation: " << desks << " movable desks, " << sofas
            << " sofa exits and " << standing << " standing activities verified\n";
}
}
int main(int argc, char **argv) {
  try {
    sweptGeometry(); routing(); narrowAisle(); roundedWalkingRoutes(); socketCorridors(); packValidation();
    if (argc == 2) realAssets(argv[1]);
  }
  catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
  std::cout << "Navigation sweep, route, socket and pack validation checks passed\n";
}
