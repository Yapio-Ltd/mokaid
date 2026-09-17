#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <mokaid/engine/office.hpp>
#include <mokaid/engine/office_camera.hpp>
#include <stdexcept>
#include <thread>

namespace {
void expect(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}
bool near(float a, float b) { return std::abs(a - b) < .001F; }
void mathTests() {
  using namespace mokaid::engine;
  const auto m = trs({3, -2, 7}, {0, .38268343F, 0, .92387953F}, {2, 3, 4});
  const auto identity = inverse(m) * m;
  for (int i = 0; i < 16; ++i)
    expect(near(identity.m[i], i % 5 == 0 ? 1.F : 0.F), "TRS inverse");
  const auto v = transform(perspective(1, 1, .1F, 100), {0, 0, -.1F, 1});
  expect(near(v.z / v.w, 0), "Depth near plane must be zero");
  const auto f = transform(perspective(1, 1, .1F, 100), {0, 0, -100, 1});
  expect(near(f.z / f.w, 1), "Depth far plane must be one");
  const auto q = slerp({0, 0, 0, 1}, {0, 0, 0, -1}, .5F);
  expect(near(std::abs(q.w), 1), "Quaternion shortest arc");
  for (float aspect : {.5F, 1.F, 1.5F, 2.4F}) {
    const auto camera = frameOffice({-7, -.15F, -7}, {7.5F, 2.5F, 6.5F}, aspect);
    for (int corner = 0; corner < 8; ++corner) {
      const auto point = transform(camera.viewProjection,
          {corner & 1 ? 7.5F : -7, corner & 2 ? 2.5F : -.15F,
           corner & 4 ? 6.5F : -7, 1});
      expect(point.w > 0 && std::abs(point.x / point.w) <= .941F &&
             std::abs(point.y / point.w) <= .941F,
             "All room corners fit with margin at narrow and wide aspect ratios");
    }
  }
}
void animationTests() {
  using namespace mokaid::engine;
  Scene s;
  s.nodes.resize(2);
  s.nodes[1].parent = 0;
  s.nodes[1].translation = {0, 2, 0};
  Channel c;
  c.node = 0;
  c.path = ChannelPath::Translation;
  c.times = {0, 1};
  c.values = {{0, 0, 0, 0}, {4, 0, 0, 0}};
  s.animations.push_back({"idle", 2, {c}});
  auto pose = evaluatePose(s, "missing", .5F);
  expect(near(pose.world[1].m[12], 2) && near(pose.world[1].m[13], 2),
         "Parent animation and idle fallback");
  s.animations[0].channels[0].step = true;
  pose = evaluatePose(s, "idle", .5F);
  expect(near(pose.world[1].m[12], 0), "STEP interpolation");
  s.animations.push_back({"sit_down", 1, {c}});
  const auto seatedEnd = evaluatePose(s, "sit_down", 1);
  const auto seatedAfter = evaluatePose(s, "sit_down", 5);
  expect(near(seatedEnd.world[0].m[12], 4) && near(seatedAfter.world[0].m[12], 4),
         "One-shot seated transitions hold the last key instead of wrapping");
  s.skins.push_back({{1}, {inverse(pose.world[1])}});
  Mesh mesh;
  mesh.node = 0;
  mesh.skin = 0;
  const auto skin = skinMatrices(s, mesh, pose);
  expect(near(skin[0].m[13], 0), "Bind pose skin palette");
}
void physicalChairPoseTest() {
  using namespace mokaid::engine;
  auto scene=std::make_shared<Scene>();scene->nodes.resize(3);
  scene->nodes[0].rotation={0,.70710678F,0,.70710678F};
  scene->nodes[1].parent=0;scene->nodes[2].parent=1;scene->nodes[2].translation={0,1,0};
  Instance room;room.scene=scene;room.nodeTranslations={{1,{.6F,0,0}}};
  const auto moved=evaluateInstancePose(room);
  expect(near(moved.world[1].m[14],-.6F)&&near(moved.world[2].m[14],-.6F),"Chair local offset moves rigid mesh and children through the parent hierarchy");
  expect(near(moved.world[2].m[13],1)&&near(scene->nodes[1].translation.x,0),"Chair motion preserves height and immutable shared scene");
}
void fixtures() {
  using namespace mokaid::engine;
  expect(seats.size() == 9, "Nine fixed desks");
  const auto first=agentPersonality("agent-alpha"),again=agentPersonality("agent-alpha"),other=agentPersonality("agent-beta");
  expect(first.seed==again.seed&&first.pace==again.pace&&first.focus==again.focus,"Personality is stable across replay and process-independent identity hashing");
  expect(first.seed!=other.seed&&first.pace!=other.pace,"Different identities have individual pace and focus");
  for(int i=0;i<100;++i){const auto profile=agentPersonality(std::to_string(i));expect(profile.pace>=.94F&&profile.pace<=1.04F&&profile.focus>=.75F&&profile.focus<=1.4F,"Personality traits remain within authored movement and timing bounds");}
  expect(near(seats[8].x, 2.158F) && near(seats[8].z, -3.190F),
         "Seat 8 coordinates reflected from web");
  expect(near(seats[0].z, 4.243F), "Far lounge seat index remains stable");
  expect(near(deskSeatHeight,.51F), "Authored chair cushion height");
  expect(agentVisualState("active", "online", true) == "working", "An active task uses the working clip");
  expect(agentVisualState("active", "online", false) == "idle", "A free active agent uses idle, not a missing active clip");
  expect(agentVisualState("busy", "online", false) == "typing", "Busy without a task matches the web typing state");
  expect(agentVisualState("waiting", "online", true) == "waiting", "Pending approval remains a desk activity");
  expect(agentVisualState("idle", "offline", false) == "offline", "Offline linked members do not patrol");
}
void blendTests() {
  using namespace mokaid::engine;
  auto scene = std::make_shared<Scene>();
  scene->nodes.resize(2);
  scene->nodes[1].parent = 0;
  scene->nodes[1].translation = {0, 1, 0};
  const auto constant = [](float x) {
    Channel channel;
    channel.times = {0, 1};
    channel.values = {{x, 0, 0, 0}, {x, 0, 0, 0}};
    channel.path = ChannelPath::Translation;
    return channel;
  };
  scene->animations = {{"idle", 1, {constant(0)}},
                       {"working", 1, {constant(4)}},
                       {"thinking", 1, {constant(-3)}}};
  auto rotation = constant(0);
  rotation.path = ChannelPath::Rotation;
  rotation.values = {{0, 0, 1, 0}, {0, 0, 1, 0}};
  scene->animations[1].channels.push_back(rotation);
  AnimationMixer mixer;
  mixer.transition(*scene, "idle", 0);
  mixer.transition(*scene, "working", 1);
  Instance instance;
  instance.scene = scene;
  const auto position = [&](float time) {
    instance.animationSamples = mixer.sample(time);
    float total = 0;
    for (const auto &sample : instance.animationSamples)
      total += sample.weight;
    expect(near(total, 1), "Animation blend weights remain normalized");
    return evaluateInstancePose(instance).world[0].m[12];
  };
  expect(near(position(1), 0), "Crossfade starts at the previous pose");
  expect(near(position(1 + animationBlendSeconds / 2), 2), "Smoothstep midpoint");
  const auto halfway = evaluateInstancePose(instance);
  expect(near(length(Vec3{halfway.world[1].m[12] - halfway.world[0].m[12],
                          halfway.world[1].m[13] - halfway.world[0].m[13],
                          halfway.world[1].m[14] - halfway.world[0].m[14]}), 1),
         "Blend local TRS, never shrinking interpolated world matrices");
  const float interrupted = position(1.1F);
  const auto poseBeforeInterrupt = evaluateInstancePose(instance);
  mixer.transition(*scene, "thinking", 1.1F);
  expect(near(position(1.1F), interrupted), "Interrupted blends preserve the weighted pose");
  const auto poseAfterInterrupt = evaluateInstancePose(instance);
  for (std::size_t node = 0; node < poseBeforeInterrupt.world.size(); ++node)
    for (std::size_t element = 0; element < 16; ++element)
      expect(near(poseBeforeInterrupt.world[node].m[element],
                   poseAfterInterrupt.world[node].m[element]),
             "Interrupted blend preserves local rotation and child hierarchy");
  expect(std::abs(position(1.10001F) - interrupted) < .001F, "No jump after transition interruption");
  expect(near(position(1.1F + animationBlendSeconds), -3), "Crossfade reaches the target in 0.28 seconds");
  mixer.transition(*scene, "missing-state", 2);
  expect(near(position(2 + animationBlendSeconds), 0), "Missing clip resolves to idle");
  const auto before = mixer.sample(3);
  mixer.transition(*scene, "another-missing-state", 3);
  const auto after = mixer.sample(3);
  expect(before.size() == 1 && after.size() == 1 &&
             near(before[0].seconds, after[0].seconds),
         "Two missing states preserve the same idle phase");
}
void malformedAssets() {
  using namespace mokaid::engine;
  const auto directory = std::filesystem::temp_directory_path() /
      ("mokaid-engine-test-" + std::to_string(
          std::chrono::steady_clock::now().time_since_epoch().count()));
  expect(std::filesystem::create_directory(directory), "Create asset fixture directory");
  struct Cleanup {
    std::filesystem::path directory;
    ~Cleanup() {
      std::error_code ignored;
      std::filesystem::remove(directory / "invalid.mokaidasset", ignored);
      std::filesystem::remove(directory, ignored);
    }
  } cleanup{directory};
  const auto path = directory / "invalid.mokaidasset";
  for (int scenario = 0; scenario < 4; ++scenario) {
    {
      std::ofstream stream(path, std::ios::binary);
      auto write = [&stream](const auto &value) {
        stream.write(reinterpret_cast<const char *>(&value), sizeof value);
      };
      stream.write("MOKASSET", 8);
      write(scenario == 0 ? assetVersion + 1 : assetVersion);
      write(Vec3{});
      write(Vec3{1, 1, 1});
      write(std::uint32_t{1}); // texture count
      write(std::uint32_t{scenario == 1 ? 2U : 1U}); // invalid color-space tag
      write(std::uint32_t{scenario == 2 ? 17U : 2U}); // invalid mip count
      for (int mip = 0; mip < 2; ++mip) {
        write(std::uint32_t{1});
        write(std::uint32_t{1});
        write(std::uint32_t{4});
        write(std::uint32_t{0xffffffff});
      } // scenario 3 repeats 1x1, which is invalid GPU mip allocation
    }
    bool rejected = false;
    try { (void)loadScene(path); }
    catch (const std::runtime_error &) { rejected = true; }
    expect(rejected, "Reject malformed assets before GPU resource allocation");
  }
}
void seatedGroundContact(const char *root, bool atypical = false) {
  using namespace mokaid::engine;
  Office office(false);
  office.setPaused(true);
  const auto navigation=Navigation::load(std::filesystem::path(root)/"office.mokaidnav");
  office.load(root);
  std::vector<Agent> agents;
  const auto variants = atypical ? std::vector<const char *>{"byte", "nyx", "moss"}
      : std::vector<const char *>{"male", "female", "corporate", "developer", "design",
                                  "finance", "research", "legal"};
  for (const auto *type : variants)
    agents.push_back({type, type, "working", type, static_cast<int>(agents.size())});
  office.setAgents(agents);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  std::shared_ptr<const Frame> frame;
  do {
    frame = office.snapshot(1.6F);
    if (frame->actorIndicators.size() == agents.size()) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  } while (std::chrono::steady_clock::now() < deadline);
  expect(frame->actorIndicators.size() == agents.size(), "All catalog variants reach their desk with one indicator each");
  for (float aspect : {.75F, 1.F, 1.33F, 1.6F, 2.16F, 2.4F, 3.F}) {
    const auto view = office.snapshot(aspect);
    for (const auto &socket : navigation.sockets()) {
      // A modest immersion crop can trim the outer plinth, but must keep a
      // full standing person at every desk, sofa, coffee and foosball position.
      for (float y : {0.F, 1.9F}) {
        for (const auto offset : {Vec3{-.35F, y, 0}, Vec3{.35F, y, 0},
                                  Vec3{0, y, -.35F}, Vec3{0, y, .35F}}) {
          const auto p = socket.position + offset;
          const auto clip = transform(view->viewProjection, {p.x, p.y, p.z, 1});
          expect(clip.w > 0 && std::abs(clip.x / clip.w) < .985F &&
                                  std::abs(clip.y / clip.w) < .985F,
                 "Immersive camera keeps full actors at every activity in view");
        }
      }
    }
  }
  for (const auto &instance : frame->instances) {
    if (instance.agentId.empty()) continue;
    const auto &scene = *instance.scene;
    expect(!scene.skins.empty() && !scene.skins.front().joints.empty(),
           "Every seated catalog variant has a pelvis skin joint");
    const auto pose = evaluateInstancePose(instance);
    const auto [min, max] = poseBounds(scene, pose);
    // The renderer applies this final placement after skinning. Raw posed Y
    // alone includes the avatar's reference foot offset and is not floor error.
    const float soleY = transform(instance.transform, {min.x, min.y, min.z, 1}).y;
    const auto pelvis = instance.transform * pose.world[scene.skins.front().joints.front()];
    std::cout << instance.agentId << ": final desk sole Y=" << soleY
              << ", pelvis Y=" << pelvis.m[13] << '\n';
    const auto found=std::find_if(agents.begin(),agents.end(),[&](const auto &a){return a.id==instance.agentId;});
    const auto socketId="desk_"+std::to_string(found->seat);
    const auto socket=std::find_if(navigation.sockets().begin(),navigation.sockets().end(),[&](const auto &s){return s.id==socketId;});
    const auto point=Vec3{instance.transform.m[12],0,instance.transform.m[14]};
    const float floor=navigation.floorHeightAt(point),height=socket==navigation.sockets().end()?deskSeatHeight:socket->seatHeight;
    const auto marker=std::find_if(frame->actorIndicators.begin(),frame->actorIndicators.end(),[&](const auto &indicator){return indicator.id==instance.agentId;});
    const float crownY=transform(instance.transform,{max.x,max.y,max.z,1}).y;
    expect(marker!=frame->actorIndicators.end()&&marker->level==0,"Indicators preserve absent level instead of inventing one");
    expect(marker->headWorld.y>crownY-.06F&&marker->headWorld.y<crownY+.25F,"Cached head marker follows the seated head, independently of props");
    expect(std::abs(soleY-floor) <= .003F, "Seated soles stay within 3 mm of the physical local floor");
    expect(std::abs(pelvis.m[13] - height) <= .003F,
           "Seated pelvis aligns with the authored chair cushion");
  }
}
void assets(const char *root) {
  using namespace mokaid::engine;
  std::uint64_t triangles = 0;
  for (const auto *key :
       {"office", "avatar_male", "avatar_female", "avatar_corporate",
        "avatar_developer", "avatar_design", "avatar_finance",
        "avatar_research", "avatar_legal", "avatar_byte", "avatar_nyx", "avatar_moss"}) {
    auto s = loadScene(std::filesystem::path(root) /
                       (std::string(key) + ".mokaidasset"));
    expect(!s->meshes.empty(), "Real geometry required");
    auto pose = evaluatePose(*s, "walking", .72F);
    for (const auto &m : s->meshes) {
      triangles += m.indices.size() / 3;
      const auto palette = skinMatrices(*s, m, pose);
      for (const auto &matrix : palette)
        for (float n : matrix.m)
          expect(std::isfinite(n), "Finite GPU skin palette");
    }
    if (std::string_view(key) != "office") {
      for (const auto *clip : {"idle", "walking", "typing", "working", "thinking",
           "talking", "waiting", "requesting_approval", "blocked", "celebrating",
           "away", "offline", "reviewing", "learning", "sitting",
           "preparing_coffee", "playing_foosball", "sitting_sofa",
           "sit_down", "stand_up", "sit_down_sofa", "stand_up_sofa", "walking_coffee", "carrying_coffee", "drinking_coffee", "talking_coffee", "chair_pullback", "chair_pushin",
           "walking_brisk", "walking_relaxed", "typing_focused", "typing_relaxed",
           "phone_pickup", "phone_call", "phone_putdown", "greeting", "laughing",
           "laughing_coffee", "talking_standing", "sitting_sofa_coffee", "talking_sofa_coffee",
           "drinking_sofa_coffee", "laughing_sofa_coffee", "sit_down_sofa_coffee", "stand_up_sofa_coffee",
           "talking_sofa_coffee_left", "talking_sofa_coffee_right", "coffee_putdown"})
        expect(resolveAnimation(*s, clip) == clip, "Every avatar must include all 48 authored clips without fallback");
      expect(std::any_of(s->materials.begin(),s->materials.end(),[](const auto &m){return m.surfaceKind==2;}),"Every avatar includes the tagged phone mesh");
      expect(std::any_of(s->materials.begin(),s->materials.end(),[](const auto &m){return m.surfaceKind==3;}),"Every avatar includes the tagged static phone dock");
      for (const auto &mesh : s->meshes) {
        if (mesh.skin < 0) continue;
        for (const auto &vertex : mesh.vertices) {
          const auto w = vertex.weights;
          expect(std::abs(w.x + w.y + w.z + w.w - 1) < .001F,
                 "Exported GPU skin weights are normalized");
        }
      }
      expect(s->referenceHeight>.5F&&s->referenceHeight<3.F,"Avatar scale uses deformed reference bounds");
      expect(s->sittingPelvisHeight>.2F&&s->sittingPelvisHeight<1.3F,"Seated pelvis bounded to real avatar height");
    }
    std::cout << key << ": " << s->meshes.size() << " primitives, "
              << s->animations.size() << " clips\n";
  }
  expect(triangles > 10000, "Actual office and avatar triangle data");
  seatedGroundContact(root);
  seatedGroundContact(root, true);
}
} // namespace
int main(int argc, char **argv) {
  try {
    mathTests();
    animationTests();
    blendTests();
    fixtures();
    physicalChairPoseTest();
    malformedAssets();
    if (argc == 2) {
      assets(argv[1]);
      const auto nav = mokaid::engine::Navigation::load(
          std::filesystem::path(argv[1]) / "office.mokaidnav");
      expect(!nav.empty(), "Real office navigation");
      std::size_t connected = 0;
      for (std::size_t lane = 0; lane < 9; ++lane) {
        const auto path =
            nav.route(nav.waypoint(lane, 0), nav.waypoint(lane, 1));
        if (!path.empty())
          ++connected;
        for (const auto &p : path)
          expect(nav.walkable(p), "Patrol must remain outside furniture");
      }
      expect(connected >= 7, "Office patrol anchors remain connected");
    }
    std::cout << "Native engine checks passed\n";
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
