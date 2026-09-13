#include <cmath>
#include <fstream>
#include <iostream>
#include <mokaid/engine/office.hpp>
#include <stdexcept>

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
  s.skins.push_back({{1}, {inverse(pose.world[1])}});
  Mesh mesh;
  mesh.node = 0;
  mesh.skin = 0;
  const auto skin = skinMatrices(s, mesh, pose);
  expect(near(skin[0].m[13], 0), "Bind pose skin palette");
}
void fixtures() {
  using namespace mokaid::engine;
  expect(seats.size() == 9, "Nine fixed desks");
  expect(near(seats[8].x, 2.158F) && near(seats[8].z, -3.190F),
         "Seat 8 coordinates reflected from web");
  expect(near(seats[0].z, 4.243F), "Far lounge seat index remains stable");
  expect(near(deskSeatHeight,.51F), "Authored chair cushion height");
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
void assets(const char *root) {
  using namespace mokaid::engine;
  std::uint64_t triangles = 0;
  for (const auto *key :
       {"office", "avatar_male", "avatar_female", "avatar_corporate",
        "avatar_developer", "avatar_design", "avatar_finance",
        "avatar_research", "avatar_legal"}) {
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
      expect(s->animations.size() >= 10, "Expected authored avatar animations");
      expect(s->referenceHeight>.5F&&s->referenceHeight<3.F,"Avatar scale uses deformed reference bounds");
      expect(s->sittingPelvisHeight>.2F&&s->sittingPelvisHeight<1.3F,"Seated pelvis bounded to real avatar height");
    }
    std::cout << key << ": " << s->meshes.size() << " primitives, "
              << s->animations.size() << " clips\n";
  }
  expect(triangles > 10000, "Actual office and avatar triangle data");
}
} // namespace
int main(int argc, char **argv) {
  try {
    mathTests();
    animationTests();
    blendTests();
    fixtures();
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
