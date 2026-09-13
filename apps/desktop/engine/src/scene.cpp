#include <bit>
#include <cstring>
#include <fstream>
#include <limits>
#include <mokaid/engine/scene.hpp>

namespace mokaid::engine {
namespace {
class Reader {
  std::ifstream in_;
  std::uint64_t remaining_;

public:
  explicit Reader(const std::filesystem::path &p)
      : in_(p, std::ios::binary), remaining_(std::filesystem::file_size(p)) {
    if (!in_ || remaining_ > 1024ULL * 1024 * 1024)
      throw std::runtime_error("Asset is missing or exceeds 1 GiB");
  }
  void bytes(void *out, std::size_t n) {
    if (n > remaining_ ||
        !in_.read(static_cast<char *>(out), static_cast<std::streamsize>(n)))
      throw std::runtime_error("Truncated asset");
    remaining_ -= n;
  }
  template <class T> T value() {
    static_assert(std::endian::native == std::endian::little);
    T t{};
    bytes(&t, sizeof t);
    return t;
  }
  std::uint32_t count(std::uint32_t limit) {
    auto c = value<std::uint32_t>();
    if (c > limit)
      throw std::runtime_error("Asset count exceeds limit");
    return c;
  }
  template <class T> std::vector<T> vector(std::uint32_t limit) {
    auto c = count(limit);
    if (static_cast<std::uint64_t>(c) * sizeof(T) > remaining_)
      throw std::runtime_error("Asset array exceeds remaining bytes");
    std::vector<T> v(c);
    bytes(v.data(), v.size() * sizeof(T));
    return v;
  }
  std::string string() {
    auto v = vector<char>(4096);
    return {v.begin(), v.end()};
  }
  bool ended() const { return remaining_ == 0; }
};
bool finite(Vec3 v) {
  return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}
bool finite(Vec4 v) {
  return finite(Vec3{v.x, v.y, v.z}) && std::isfinite(v.w);
}
} // namespace
std::shared_ptr<const Scene> loadScene(const std::filesystem::path &path) {
  Reader r(path);
  char magic[8]{};
  r.bytes(magic, 8);
  if (std::memcmp(magic, "MOKASSET", 8) ||
      r.value<std::uint32_t>() != assetVersion)
    throw std::runtime_error("Unsupported Mokaid asset format");
  auto s = std::make_shared<Scene>();
  s->residentBytes = std::filesystem::file_size(path);
  s->min = r.value<Vec3>();
  s->max = r.value<Vec3>();
  if (!finite(s->min) || !finite(s->max) || s->min.x > s->max.x ||
      s->min.y > s->max.y || s->min.z > s->max.z)
    throw std::runtime_error("Invalid asset bounds");
  s->textures.resize(r.count(1024));
  for (auto &t : s->textures) {
    t.srgb = r.count(1) != 0;
    t.mips.resize(r.count(16));
    if (t.mips.empty())
      throw std::runtime_error("Empty texture");
    for (auto &m : t.mips) {
      m.width = r.count(8192);
      m.height = r.count(8192);
      if (!m.width || !m.height)
        throw std::runtime_error("Empty mip");
      m.rgba = r.vector<std::uint8_t>(8192 * 8192 * 4);
      if (m.rgba.size() != static_cast<std::uint64_t>(m.width) * m.height * 4)
        throw std::runtime_error("Invalid texture byte count");
    }
    auto width = t.mips.front().width;
    auto height = t.mips.front().height;
    for (std::size_t level = 1; level < t.mips.size(); ++level) {
      if (width == 1 && height == 1)
        throw std::runtime_error("Texture has excessive mip levels");
      width = std::max(1U, width / 2);
      height = std::max(1U, height / 2);
      if (t.mips[level].width != width || t.mips[level].height != height)
        throw std::runtime_error("Invalid mip dimensions");
    }
  }
  s->materials.resize(r.count(4096));
  for (auto &m : s->materials) {
    m.color = r.value<Vec4>();
    m.emissive = r.value<Vec3>();
    m.roughness = r.value<float>();
    m.metallic = r.value<float>();
    m.texture = r.value<std::int32_t>();
    m.emissiveTexture = r.value<std::int32_t>();
    m.metallicRoughnessTexture = r.value<std::int32_t>();
    m.alphaMode = r.value<std::uint32_t>();
    m.alphaCutoff = r.value<float>();
    if (!finite(m.color) || !finite(m.emissive) ||
        !std::isfinite(m.roughness) || m.roughness < 0 || m.roughness > 1 ||
        !std::isfinite(m.metallic) || m.metallic < 0 || m.metallic > 1 ||
        !std::isfinite(m.alphaCutoff) || m.alphaMode > 2 || m.texture < -1 ||
        m.texture >= static_cast<std::int32_t>(s->textures.size()) ||
        m.emissiveTexture < -1 ||
        m.emissiveTexture >= static_cast<std::int32_t>(s->textures.size()) ||
        m.metallicRoughnessTexture < -1 ||
        m.metallicRoughnessTexture >= static_cast<std::int32_t>(s->textures.size()))
      throw std::runtime_error("Invalid material texture");
  }
  s->nodes.resize(r.count(100000));
  for (std::size_t i = 0; i < s->nodes.size(); ++i) {
    auto &n = s->nodes[i];
    n.parent = r.value<std::int32_t>();
    n.translation = r.value<Vec3>();
    n.rotation = r.value<Vec4>();
    n.scale = r.value<Vec3>();
    if (n.parent < -1 || n.parent >= static_cast<std::int32_t>(i) ||
        !finite(n.translation) || !finite(n.rotation) || !finite(n.scale))
      throw std::runtime_error("Invalid node hierarchy");
  }
  s->skins.resize(r.count(512));
  for (auto &sk : s->skins) {
    sk.joints = r.vector<std::uint32_t>(maxSkinJoints);
    sk.inverseBind.resize(sk.joints.size());
    r.bytes(sk.inverseBind.data(), sk.inverseBind.size() * sizeof(Mat4));
    for (const auto &matrix : sk.inverseBind)
      for (const auto value : matrix.m)
        if (!std::isfinite(value))
          throw std::runtime_error("Nonfinite inverse bind matrix");
    for (auto j : sk.joints)
      if (j >= s->nodes.size())
        throw std::runtime_error("Invalid skin joint");
  }
  s->meshes.resize(r.count(100000));
  for (auto &m : s->meshes) {
    m.node = r.value<std::uint32_t>();
    m.material = r.value<std::uint32_t>();
    m.skin = r.value<std::int32_t>();
    m.vertices = r.vector<Vertex>(10000000);
    m.indices = r.vector<std::uint32_t>(30000000);
    if (m.node >= s->nodes.size() || m.material >= s->materials.size() ||
        m.skin < -1 || m.skin >= static_cast<std::int32_t>(s->skins.size()) ||
        m.indices.size() % 3)
      throw std::runtime_error("Invalid mesh reference");
    for (auto idx : m.indices)
      if (idx >= m.vertices.size())
        throw std::runtime_error("Invalid vertex index");
    for (const auto &v : m.vertices) {
      if (!finite(v.position) || !finite(v.normal) || !std::isfinite(v.u) ||
          !std::isfinite(v.v) || !finite(v.joints) || !finite(v.weights))
        throw std::runtime_error("Nonfinite vertex");
      if (m.skin >= 0) {
        const auto jointCount =
            s->skins[static_cast<std::size_t>(m.skin)].joints.size();
        for (const float joint :
             {v.joints.x, v.joints.y, v.joints.z, v.joints.w})
          if (joint < 0 || joint >= static_cast<float>(jointCount) ||
              std::floor(joint) != joint)
            throw std::runtime_error("Vertex joint outside skin palette");
        if (v.weights.x < 0 || v.weights.y < 0 || v.weights.z < 0 ||
            v.weights.w < 0 ||
            v.weights.x + v.weights.y + v.weights.z + v.weights.w < .01F)
          throw std::runtime_error("Invalid skin weights");
      }
    }
  }
  s->animations.resize(r.count(256));
  for (auto &a : s->animations) {
    a.name = r.string();
    a.duration = r.value<float>();
    if (!std::isfinite(a.duration) || a.duration < 0)
      throw std::runtime_error("Invalid animation duration");
    a.channels.resize(r.count(10000));
    for (auto &c : a.channels) {
      c.node = r.value<std::uint32_t>();
      c.path = static_cast<ChannelPath>(r.count(2));
      c.step = r.value<std::uint32_t>() != 0;
      c.times = r.vector<float>(1000000);
      c.values.resize(c.times.size());
      r.bytes(c.values.data(), c.values.size() * sizeof(Vec4));
      if (c.node >= s->nodes.size() || c.times.empty() ||
          !std::is_sorted(c.times.begin(), c.times.end()) ||
          std::any_of(
              c.times.begin(), c.times.end(),
              [](float time) { return !std::isfinite(time) || time < 0; }) ||
          std::any_of(c.values.begin(), c.values.end(),
                      [](Vec4 value) { return !finite(value); }))
        throw std::runtime_error("Invalid animation");
    }
  }
  if (!r.ended())
    throw std::runtime_error("Unexpected trailing asset data");
  s->referenceMinY = s->min.y;
  s->referenceHeight = s->max.y - s->min.y;
  if (!s->skins.empty()) {
    const auto [min, max] = poseBounds(*s, evaluatePose(*s, "idle", 0));
    s->referenceMinY = min.y;
    s->referenceHeight = max.y - min.y;
    const bool hasSitting = std::any_of(
        s->animations.begin(), s->animations.end(),
        [](const auto &animation) { return animation.name == "sitting"; });
    // The cooker verifies the avatar palette starts at the pelvis. Match the
    // web's first-frame sitting measurement and its bounded fallback.
    if (hasSitting && !s->skins.front().joints.empty()) {
      const auto sitting = evaluatePose(*s, "sitting", 0);
      const float height =
          sitting.world[s->skins.front().joints.front()].m[13] * 1.75F /
          std::max(.1F, s->referenceHeight);
      if (height > .2F && height < 1.3F)
        s->sittingPelvisHeight = height;
    }
  }
  return s;
}
std::pair<Vec3, Vec3> poseBounds(const Scene &s, const Pose &pose) {
  Vec3 min{1e9F, 1e9F, 1e9F}, max{-1e9F, -1e9F, -1e9F};
  for (const auto &mesh : s.meshes) {
    const auto palette = skinMatrices(s, mesh, pose);
    for (const auto &vertex : mesh.vertices) {
      Vec4 position{vertex.position.x, vertex.position.y, vertex.position.z, 1};
      if (mesh.skin >= 0) {
        Mat4 skin;
        skin.m.fill(0);
        const float joints[] = {vertex.joints.x, vertex.joints.y,
                                vertex.joints.z, vertex.joints.w};
        const float weights[] = {vertex.weights.x, vertex.weights.y,
                                 vertex.weights.z, vertex.weights.w};
        for (int joint = 0; joint < 4; ++joint)
          for (int element = 0; element < 16; ++element)
            skin.m[element] +=
                palette[static_cast<std::size_t>(joints[joint])].m[element] *
                weights[joint];
        position = transform(skin, position);
      }
      position = transform(pose.world[mesh.node], position);
      min = {std::min(min.x, position.x), std::min(min.y, position.y),
             std::min(min.z, position.z)};
      max = {std::max(max.x, position.x), std::max(max.y, position.y),
             std::max(max.z, position.z)};
    }
  }
  return {min, max};
}
std::string_view resolveAnimation(const Scene &s, std::string_view state) {
  for (const auto &animation : s.animations)
    if (animation.name == state)
      return animation.name;
  for (const auto &animation : s.animations)
    if (animation.name == "idle")
      return animation.name;
  return {};
}
void AnimationMixer::transition(const Scene &scene, std::string_view state,
                                float seconds) {
  const auto next = resolveAnimation(scene, state);
  if (!tracks_.empty() && next == target_)
    return;
  const auto previous = sample(seconds);
  tracks_.clear();
  for (const auto &layer : previous)
    tracks_.push_back({layer.clip, seconds - layer.seconds, layer.weight});
  if (std::none_of(tracks_.begin(), tracks_.end(),
                   [next](const auto &track) { return track.clip == next; }))
    tracks_.push_back({std::string(next), seconds, previous.empty() ? 1.F : 0.F});
  target_ = next;
  transitionStarted_ = seconds;
}
std::vector<AnimationSample> AnimationMixer::sample(float seconds) const {
  const float progress = std::clamp(
      (seconds - transitionStarted_) / animationBlendSeconds, 0.F, 1.F);
  const float eased = progress * progress * (3 - 2 * progress);
  std::vector<AnimationSample> result;
  result.reserve(tracks_.size());
  for (const auto &track : tracks_) {
    const float target = track.clip == target_ ? 1.F : 0.F;
    const float weight = track.fromWeight + (target - track.fromWeight) * eased;
    if (weight > 0)
      result.push_back({track.clip, std::max(0.F, seconds - track.started), weight});
  }
  return result;
}
namespace {
std::vector<Node> animatedNodes(const Scene &s, std::string_view name,
                                 float seconds) {
  auto nodes = s.nodes;
  name = resolveAnimation(s, name);
  auto it = std::find_if(s.animations.begin(), s.animations.end(),
                         [name](const auto &a) { return a.name == name; });
  if (it != s.animations.end()) {
    const auto &a = *it;
    const float t =
        a.duration > 0 ? std::fmod(std::max(0.F, seconds), a.duration) : 0;
    for (const auto &c : a.channels) {
      const auto upper = std::upper_bound(c.times.begin(), c.times.end(), t);
      const std::size_t lo = upper == c.times.begin()
                                 ? 0
                                 : static_cast<std::size_t>(
                                       upper - c.times.begin() - 1),
                        hi = std::min(lo + 1, c.times.size() - 1);
      const float dt = c.times[hi] - c.times[lo];
      const float k =
          c.step || dt <= 0 ? 0 : std::clamp((t - c.times[lo]) / dt, 0.F, 1.F);
      const auto &x = c.values[lo];
      const auto &y = c.values[hi];
      const Vec4 v = c.path == ChannelPath::Rotation
                         ? slerp(x, y, k)
                         : Vec4{x.x + (y.x - x.x) * k, x.y + (y.y - x.y) * k,
                                x.z + (y.z - x.z) * k, x.w + (y.w - x.w) * k};
      auto &n = nodes[c.node];
      switch (c.path) {
      case ChannelPath::Translation:
        n.translation = {v.x, v.y, v.z};
        break;
      case ChannelPath::Rotation:
        n.rotation = v;
        break;
      case ChannelPath::Scale:
        n.scale = {v.x, v.y, v.z};
        break;
      }
    }
  }
  return nodes;
}
Pose composePose(std::span<const Node> nodes) {
  Pose p;
  p.world.reserve(nodes.size());
  for (const auto &n : nodes) {
    const auto local = trs(n.translation, n.rotation, n.scale);
    p.world.push_back(n.parent >= 0
                          ? p.world[static_cast<std::size_t>(n.parent)] * local
                          : local);
  }
  return p;
}
} // namespace
Pose evaluatePose(const Scene &s, std::string_view name, float seconds) {
  return composePose(animatedNodes(s, name, seconds));
}
Pose evaluateInstancePose(const Instance &instance) {
  const auto &scene = *instance.scene;
  if (instance.animationSamples.empty())
    return evaluatePose(scene, instance.animation, instance.animationTime);
  std::vector<Node> blended;
  float accumulated = 0;
  for (const auto &layer : instance.animationSamples) {
    if (layer.weight <= 0)
      continue;
    auto nodes = animatedNodes(scene, layer.clip, layer.seconds);
    if (blended.empty()) {
      blended = std::move(nodes);
      accumulated = layer.weight;
      continue;
    }
    const float factor = layer.weight / (accumulated + layer.weight);
    for (std::size_t index = 0; index < nodes.size(); ++index) {
      auto &target = blended[index];
      const auto &source = nodes[index];
      target.translation = target.translation * (1 - factor) + source.translation * factor;
      target.scale = target.scale * (1 - factor) + source.scale * factor;
      target.rotation = slerp(target.rotation, source.rotation, factor);
    }
    accumulated += layer.weight;
  }
  return blended.empty() ? evaluatePose(scene, instance.animation, instance.animationTime)
                         : composePose(blended);
}
std::array<Mat4, maxSkinJoints> skinMatrices(const Scene &s, const Mesh &m,
                                             const Pose &p) {
  std::array<Mat4, maxSkinJoints> result{};
  if (m.skin < 0)
    return result;
  const auto &sk = s.skins[static_cast<std::size_t>(m.skin)];
  const auto meshInverse = inverse(p.world[m.node]);
  for (std::size_t i = 0; i < sk.joints.size(); ++i)
    result[i] = meshInverse * p.world[sk.joints[i]] * sk.inverseBind[i];
  return result;
}
} // namespace mokaid::engine
