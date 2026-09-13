#pragma once
#include "math.hpp"
#include <cstdint>
#include <filesystem>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace mokaid::engine {
constexpr std::uint32_t assetVersion = 3;
constexpr std::size_t maxSkinJoints = 128;
struct Vertex {
  Vec3 position, normal;
  float u{}, v{};
  Vec4 joints, weights;
};
static_assert(sizeof(Vertex) == 64);
struct TextureMip {
  std::uint32_t width{}, height{};
  std::vector<std::uint8_t> rgba;
};
struct Texture {
  bool srgb{true};
  std::vector<TextureMip> mips;
};
struct Material {
  Vec4 color{1, 1, 1, 1};
  Vec3 emissive{};
  float roughness{1}, metallic{};
  std::int32_t texture{-1};
  std::int32_t emissiveTexture{-1};
  std::int32_t metallicRoughnessTexture{-1};
  std::uint32_t alphaMode{};
  float alphaCutoff{.5F};
};
struct Node {
  std::int32_t parent{-1};
  Vec3 translation{};
  Vec4 rotation{0, 0, 0, 1};
  Vec3 scale{1, 1, 1};
};
struct Mesh {
  std::uint32_t node{}, material{};
  std::int32_t skin{-1};
  std::vector<Vertex> vertices;
  std::vector<std::uint32_t> indices;
};
struct Skin {
  std::vector<std::uint32_t> joints;
  std::vector<Mat4> inverseBind;
};
enum class ChannelPath : std::uint32_t { Translation, Rotation, Scale };
struct Channel {
  std::uint32_t node{};
  ChannelPath path{};
  bool step{};
  std::vector<float> times;
  std::vector<Vec4> values;
};
struct Animation {
  std::string name;
  float duration{};
  std::vector<Channel> channels;
};
struct Scene {
  std::vector<Texture> textures;
  std::vector<Material> materials;
  std::vector<Node> nodes;
  std::vector<Mesh> meshes;
  std::vector<Skin> skins;
  std::vector<Animation> animations;
  Vec3 min{}, max{};
  // Reference animation bounds include the skin deformation. Some glTF rigs
  // store centimetre-scaled mesh nodes with metre-scaled joint palettes.
  float referenceMinY{}, referenceHeight{};
  float sittingPelvisHeight{.58F};
  std::uint64_t residentBytes{};
};
struct Pose {
  std::vector<Mat4> world;
};
struct AnimationSample {
  std::string clip;
  float seconds{}, weight{1};
};
inline constexpr float animationBlendSeconds = .28F;
// Retains the current weighted pose on interruption, including more than two
// active clips. Missing states resolving to idle do not restart the idle phase.
class AnimationMixer {
public:
  void transition(const Scene &, std::string_view state, float seconds);
  std::vector<AnimationSample> sample(float seconds) const;

private:
  struct Track {
    std::string clip;
    float started{}, fromWeight{};
  };
  std::vector<Track> tracks_;
  std::string target_;
  float transitionStarted_{};
};
std::string_view resolveAnimation(const Scene &, std::string_view state);
std::shared_ptr<const Scene> loadScene(const std::filesystem::path &path);
Pose evaluatePose(const Scene &, std::string_view animation, float seconds);
std::pair<Vec3,Vec3> poseBounds(const Scene&, const Pose&);
std::array<Mat4, maxSkinJoints> skinMatrices(const Scene &, const Mesh &,
                                             const Pose &);
struct Instance {
  std::shared_ptr<const Scene> scene;
  Mat4 transform;
  std::string animation;
  float animationTime{};
  std::string agentId;
  std::vector<AnimationSample> animationSamples{};
};
Pose evaluateInstancePose(const Instance &);
struct Frame {
  std::vector<Instance> instances;
  Mat4 viewProjection;
  Vec3 camera;
  std::uint64_t sequence{};
};
} // namespace mokaid::engine
