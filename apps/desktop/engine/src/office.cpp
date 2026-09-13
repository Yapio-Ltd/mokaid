#include <mokaid/engine/office.hpp>
#include <unordered_set>

namespace mokaid::engine {
namespace {
constexpr Vec3 cameraTarget{-.146F, -.36F, .804F};
const Vec3 cameraPosition =
    cameraTarget + (Vec3{7.11F, 6.96F, -12.9F} - cameraTarget) * .93F;
Mat4 camera(float aspect) {
  return perspective(.5F, std::max(.2F, aspect)) *
         lookAt(cameraPosition, cameraTarget);
}
} // namespace
Office::Office()
    : frame_(std::make_shared<Frame>()),
      worker_([this](std::stop_token stop) { run(stop); }) {}
Office::~Office() {
  worker_.request_stop();
  worker_.join();
}
void Office::load(const std::filesystem::path &root) {
  auto office = loadScene(root / "office.mokaidasset");
  std::vector<std::pair<std::string, std::shared_ptr<const Scene>>> avatars;
  for (const auto *key : {"male", "female", "corporate", "developer", "design",
                          "finance", "research", "legal"}) {
    auto p = root / (std::string("avatar_") + key + ".mokaidasset");
    if (std::filesystem::exists(p))
      avatars.emplace_back(key, loadScene(p));
  }
  if (avatars.empty())
    throw std::runtime_error("No cooked avatar assets found");
  auto navigation = Navigation::load(root / "office.mokaidnav");
  std::lock_guard lock(mutex_);
  office_ = std::move(office);
  avatars_ = std::move(avatars);
  navigation_ = std::move(navigation);
  motion_.clear();
  frame_ = std::make_shared<Frame>();
}
void Office::setAgents(std::vector<Agent> agents) {
  std::unordered_set<int> occupied;
  std::erase_if(agents, [&](const auto &a) {
    return a.id.empty() || a.seat < 0 || a.seat >= 9 ||
           !occupied.insert(a.seat).second;
  });
  std::lock_guard lock(mutex_);
  agents_ = std::move(agents);
  std::erase_if(motion_, [&](const auto &p) {
    return std::none_of(agents_.begin(), agents_.end(),
                        [&](const auto &a) { return a.id == p.first; });
  });
}
void Office::setPaused(bool paused) {
  std::lock_guard lock(mutex_);
  paused_ = paused;
}
void Office::run(std::stop_token stop) {
  using clock = std::chrono::steady_clock;
  auto next = clock::now();
  while (!stop.stop_requested()) {
    next += std::chrono::nanoseconds(16666667);
    {
      std::lock_guard lock(mutex_);
      if (!paused_)
        seconds_ += 1.F / 60.F;
      auto f = std::make_shared<Frame>();
      f->sequence = sequence_++;
      f->camera = cameraPosition;
      // Babylon's glTF root combines a PI Y rotation with a Z reflection.
      // Converting that left-handed scene back to our RH world cancels Z's
      // reflection and leaves the PI rotation. Socket coordinates use RH -Z.
      if (office_)
        f->instances.push_back({office_, trs({}, {0, 1, 0, 0}), "", 0, {}});
      for (const auto &a : agents_) {
        if (avatars_.empty())
          break;
        auto found =
            std::find_if(avatars_.begin(), avatars_.end(),
                         [&](const auto &v) { return v.first == a.assetType; });
        const auto scene =
            found == avatars_.end() ? avatars_.front().second : found->second;
        const auto &seat = seats[static_cast<std::size_t>(a.seat)];
        const float scale = 1.75F / std::max(.1F, scene->referenceHeight);
        const bool patrol = a.status == "idle" || a.status == "available" ||
                            a.status == "waiting" || a.status.empty();
        const bool working = !patrol;
        auto [it, inserted] = motion_.try_emplace(a.id);
        auto &m = it->second;
        if (inserted) {
          m.position = {seat.x, 0, seat.z};
          m.yaw = seat.yaw;
          m.restUntil = seconds_ + 3 + static_cast<float>(a.seat);
          m.waypoint = static_cast<std::size_t>(a.seat);
          m.wasWorking = working;
        }
        if (!paused_ && !navigation_.empty()) {
          if (working && !m.wasWorking) {
            m.route = navigation_.route(m.position, {seat.x, 0, seat.z});
            m.routeIndex = 0;
          }
          if (patrol && seconds_ >= m.restUntil && m.route.empty()) {
            m.route = navigation_.route(
                m.position,
                navigation_.waypoint(static_cast<std::size_t>(a.seat),
                                     m.waypoint++));
            m.routeIndex = 0;
            m.atDesk = false;
            if (!m.route.empty() && !navigation_.walkable(m.position))
              m.position = m.route.front();
            if (m.route.empty())
              m.restUntil = seconds_ + 2;
          }
          if (m.routeIndex < m.route.size()) {
            const Vec3 delta = m.route[m.routeIndex] - m.position;
            const float distance = length(delta);
            if (distance < .04F) {
              ++m.routeIndex;
            } else {
              const auto direction = normalized(delta);
              const auto nextPosition =
                  m.position + direction * std::min(distance, .018F);
              bool occupied = false;
              for (const auto &[id, other] : motion_)
                if (id != a.id && !other.atDesk &&
                    length(nextPosition - other.position) < .55F) {
                  occupied = true;
                  break;
                }
              if (!occupied) {
                m.position = nextPosition;
                const float desired = std::atan2(direction.x, direction.z);
                float turn = std::remainder(desired - m.yaw, 6.2831853F);
                m.yaw += std::clamp(turn, -.08F, .08F);
              }
            }
            if (m.routeIndex >= m.route.size()) {
              m.route.clear();
              m.routeIndex = 0;
              m.restUntil = seconds_ + 3;
              if (working) {
                m.position = {seat.x, 0, seat.z};
                m.yaw = seat.yaw;
                m.atDesk = true;
              }
            }
          }
          m.wasWorking = working;
        }
        const std::string animation =
            !m.route.empty() ? "walking"
            : working        ? (a.status == "busy" ? "working" : a.status)
            : m.atDesk       ? "sitting"
                             : "idle";
        const float y = m.atDesk && m.route.empty()
                            ? deskSeatHeight - scene->sittingPelvisHeight
                            : -scene->referenceMinY * scale;
        const Vec3 t{m.position.x, y, m.position.z};
        m.animation.transition(*scene, animation, seconds_);
        f->instances.push_back(
            {scene,
             trs(t, {0, std::sin(m.yaw * .5F), 0, std::cos(m.yaw * .5F)},
                 {scale, scale, -scale}),
             animation, seconds_, a.id, m.animation.sample(seconds_)});
      }
      frame_ = std::move(f);
    }
    std::this_thread::sleep_until(next);
    if (next < clock::now() - std::chrono::milliseconds(100))
      next = clock::now();
  }
}
std::shared_ptr<const Frame> Office::snapshot(float aspect) const {
  std::lock_guard lock(mutex_);
  auto f = std::make_shared<Frame>(*frame_);
  f->viewProjection = camera(aspect);
  return f;
}
std::string Office::pick(float x, float y, float aspect) const {
  auto f = snapshot(aspect);
  float best = .004F;
  std::string id;
  for (const auto &i : f->instances) {
    if (i.agentId.empty())
      continue;
    const auto foot = transform(i.transform, {0, 0, 0, 1});
    const auto p =
        transform(f->viewProjection, {foot.x, foot.y + 1, foot.z, 1});
    if (p.w <= 0)
      continue;
    const float dx = p.x / p.w * .5F + .5F - x, dy = .5F - p.y / p.w * .5F - y,
                d = dx * dx + dy * dy;
    if (d < best) {
      best = d;
      id = i.agentId;
    }
  }
  return id;
}
std::uint64_t Office::residentBytes() const {
  std::lock_guard lock(mutex_);
  std::uint64_t n = office_ ? office_->residentBytes : 0;
  for (const auto &a : avatars_)
    n += a.second->residentBytes;
  return n;
}
} // namespace mokaid::engine
