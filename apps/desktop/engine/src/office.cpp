#include <mokaid/engine/office.hpp>
#include <mokaid/engine/office_camera.hpp>
#include <iostream>
#include <unordered_set>

namespace mokaid::engine {
namespace {
bool freeAgent(const Agent &a) { return a.status.empty() || a.status == "idle" || a.status == "available"; }
std::uint32_t identitySeed(std::string_view id) {std::uint32_t value=2166136261U;for(const unsigned char c:id){value^=c;value*=16777619U;}return value?value:1;}
bool hasClip(const Scene &s,std::string_view name) {return resolveAnimation(s,name)==name;}
float ease(float value) { value = std::clamp(value, 0.F, 1.F); return value * value * (3 - 2 * value); }
float clipDuration(const Scene &scene, std::string_view name, float fallback) {
  const auto it = std::find_if(scene.animations.begin(), scene.animations.end(), [&](const auto &a) { return a.name == name; });
  return it == scene.animations.end() ? fallback : it->duration;
}
Vec3 rolledPosition(const Navigation::ActivitySocket &s) { return s.position-avatarForward(s.yaw)*s.pullback; }
Vec3 rolledApproach(const Navigation::ActivitySocket &s) { return s.approach-avatarForward(s.yaw)*s.pullback; }
std::string deskClip(const Agent &agent) {
  if (freeAgent(agent) || agent.status == "away" || agent.status == "offline" || agent.status == "celebrating") return "sitting";
  return agent.status;
}
constexpr float partnerReservationLeadSeconds=90.F;
constexpr float partnerArrivalTimeoutSeconds=150.F;
}
AgentPersonality agentPersonality(std::string_view id) {
  AgentPersonality profile;profile.seed=identitySeed(id);auto state=profile.seed;
  const auto random=[&]{state^=state<<13;state^=state>>17;state^=state<<5;return static_cast<float>(state&0x00ffffffU)/16777216.F;};
  profile.pace=.94F+random()*.10F;profile.focus=.75F+random()*.65F;profile.sociability=.3F+random()*.7F;return profile;
}
Office::Office(bool threaded) : frame_(std::make_shared<Frame>()) {
  if (threaded) worker_ = std::jthread([this](std::stop_token stop) { run(stop); });
}
Office::~Office() { if (worker_.joinable()) { worker_.request_stop(); worker_.join(); } }
void Office::load(const std::filesystem::path &root) {
  auto office = loadScene(root / "office.mokaidasset");
  std::vector<std::pair<std::string, std::shared_ptr<const Scene>>> avatars;
  for (const auto *key : {"male", "female", "corporate", "developer", "design", "finance", "research", "legal", "byte", "nyx", "moss"}) {
    auto path = root / (std::string("avatar_") + key + ".mokaidasset");
    if (std::filesystem::exists(path)) avatars.emplace_back(key, loadScene(path));
  }
  if (avatars.empty()) throw std::runtime_error("No cooked avatar assets found");
  auto navigation = Navigation::load(root / "office.mokaidnav");
  std::lock_guard lock(mutex_);
  std::lock_guard frameLock(frameMutex_);
  office_ = std::move(office); cameraPoints_.clear();
  const auto officePose = evaluatePose(*office_, "", 0);
  for (const auto &mesh : office_->meshes) {
    const auto matrix = trs({}, {0, 1, 0, 0}) * officePose.world[mesh.node];
    for (const auto &vertex : mesh.vertices) {
      const auto &v = vertex.position;
      const auto p = transform(matrix, {v.x, v.y, v.z, 1});
      cameraPoints_.push_back({p.x, p.y, p.z});
    }
  }
  cameraAspect_ = 0; avatars_ = std::move(avatars); navigation_ = std::move(navigation);
  sockets_.assign(navigation_.sockets().begin(), navigation_.sockets().end());
  if (sockets_.empty()) {
    // Legacy navigation packs can still show and leave their nine desks.
    for (std::size_t i = 0; i < seats.size(); ++i) {
      const auto &s = seats[i]; const Vec3 p{s.x, 0, s.z};
      sockets_.push_back({"desk_" + std::to_string(i), 0, p, p + avatarForward(s.yaw) * .4025F, s.yaw, deskSeatHeight, 12});
    }
  }
  socketRoutes_.clear();
  for (const auto &s : sockets_) {
    if (s.kind <= 1) {
      if(s.chairNode >= static_cast<int>(office_->nodes.size())) throw std::runtime_error("Invalid physical chair binding");
      auto route = navigation_.socketRoute(rolledPosition(s), rolledApproach(s), avatarForward(s.yaw), Traffic::radius,
                                          s.chairNode>=0?std::optional<Vec3>(s.position):std::nullopt);
      if (route.empty()) std::clog << "No safe socket exit: " << s.id << '\n';
      socketRoutes_.emplace(s.id, std::move(route));
    }
  }
  motion_.clear(); traffic_.clear(); claims_.clear(); chairOffsets_.fill(0); seconds_ = 0;
  frame_ = std::make_shared<Frame>();
}
void Office::setAgents(std::vector<Agent> agents) {
  std::unordered_set<int> occupied;
  std::erase_if(agents, [&](const auto &a) { return a.id.empty() || a.seat < 0 || a.seat >= 9 || !occupied.insert(a.seat).second; });
  std::sort(agents.begin(), agents.end(), [](const auto &a, const auto &b) { return a.seat < b.seat; });
  std::lock_guard lock(mutex_);
  std::vector<std::string> ids;
  for(const auto &previous:agents_) {
    const bool retained=std::any_of(agents.begin(),agents.end(),[&](const auto &a){return a.id==previous.id&&a.seat==previous.seat;});
    if(retained) ids.push_back(previous.id); else chairOffsets_[previous.seat]=0;
  }
  agents_ = std::move(agents);
  traffic_.retain(ids);
  std::erase_if(motion_, [&](const auto &p) { return std::find(ids.begin(), ids.end(), p.first) == ids.end(); });
  std::erase_if(claims_, [&](const auto &p) { return std::find(ids.begin(), ids.end(), p.second) == ids.end(); });
  tick(0); publishFrame();
}
void Office::setPaused(bool paused) { std::lock_guard lock(mutex_); paused_ = paused; }
const Navigation::ActivitySocket *Office::socket(std::string_view id) const {
  const auto found = std::find_if(sockets_.begin(), sockets_.end(), [&](const auto &s) { return s.id == id; });
  return found == sockets_.end() ? nullptr : &*found;
}
const Scene &Office::avatar(const Agent &agent) const {
  const auto it=std::find_if(avatars_.begin(),avatars_.end(),[&](const auto &v){return v.first==agent.assetType;});
  return *(it==avatars_.end()?avatars_.front().second:it->second);
}
float Office::random(Motion &m) {
  auto &x=m.randomState;x^=x<<13;x^=x>>17;x^=x<<5;return static_cast<float>(x&0x00ffffffU)/16777216.F;
}
void Office::updateDeskGesture(const Agent &a,Motion &m) {
  const auto &scene=avatar(a);
  const bool work=freeAgent(a)||a.status=="working"||a.status=="typing";
  const bool phone=m.deskGesture.starts_with("phone_");
  if(work&&!phone&&!m.deskGesture.starts_with("typing")&&m.deskGesture!="working"&&m.deskGesture!="thinking"&&!(freeAgent(a)&&m.deskGesture=="sitting")) {
    m.deskGesture="working";m.gestureStarted=seconds_;m.gestureUntil=seconds_+4+random(m)*8;
  }
  if(!work&&!phone) {m.deskGesture=deskClip(a);return;}
  if(!work&&m.deskGesture=="phone_call")m.gestureUntil=seconds_;
  if(seconds_<m.gestureUntil)return;
  const auto previousGesture=m.deskGesture;
  const auto chooseTyping=[&]{return hasClip(scene,"typing_focused")?(m.personality.focus>1?"typing_focused":"typing_relaxed"):"working";};
  if(m.deskGesture=="phone_pickup") {m.deskGesture="phone_call";m.gestureUntil=seconds_+5+random(m)*7;}
  else if(m.deskGesture=="phone_call") {m.deskGesture="phone_putdown";m.gestureUntil=seconds_+1;}
  else {
    const float choice=random(m);
    if(m.deskGesture=="phone_putdown")m.deskGesture=chooseTyping();
    else if(choice<.19F&&hasClip(scene,"phone_pickup"))m.deskGesture="phone_pickup";
    else if(choice<.42F)m.deskGesture="thinking";
    else m.deskGesture=chooseTyping();
    m.gestureUntil=seconds_+(m.deskGesture=="phone_pickup"?1.1F:(6+random(m)*10)*m.personality.focus);
  }
  if(m.deskGesture!=previousGesture) {m.gestureStarted=seconds_;m.gesturePhase=(oneShotAnimation(m.deskGesture)||m.deskGesture.starts_with("phone_"))?0:random(m)*3;}
}
std::vector<Navigation::Disc> Office::chairDiscs() const {
  std::vector<Navigation::Disc> result;
  for(const auto &s:sockets_)if(s.kind==0&&s.chairNode>=0) {
    const auto seat=static_cast<std::size_t>(std::stoi(s.id.substr(5)));
    if(chairOffsets_[seat]>.001F)result.push_back({s.position-avatarForward(s.yaw)*(s.pullback*chairOffsets_[seat]),.425F});
  }
  return result;
}
std::vector<Vec3> Office::sofaRoute(const Navigation::ActivitySocket &s,std::span<const Navigation::Disc> blocked) const {
  return navigation_.socketRoute(s.position,s.approach,avatarForward(s.yaw),Traffic::radius,std::nullopt,blocked);
}
// The isometric view places +X on the left. That cushion is a second sofa;
// the original seats stay on the screen-right lounge below this split.
static bool screenLeftLounge(const Navigation::ActivitySocket &s) { return s.position.x >= 4.F; }
bool Office::loungeReserved(bool screenLeft) const {
  return std::any_of(claims_.begin(),claims_.end(),[&](const auto &claim){
    const auto *place=socket(claim.first);return place&&place->kind==1&&screenLeftLounge(*place)==screenLeft;
  });
}
bool Office::loungeOpen(bool screenLeft) const {
  if(loungeReserved(screenLeft))return false;
  return std::any_of(sockets_.begin(),sockets_.end(),[&](const auto &s){
    if(s.kind!=1||screenLeftLounge(s)!=screenLeft||claims_.contains(s.id))return false;
    const auto route=socketRoutes_.find(s.id);
    return route!=socketRoutes_.end()&&!route->second.empty();
  });
}
void Office::startSocial(const Agent &a,Motion &m,Motion &other) {
  const auto *place=socket(m.socketId);if(!place)return;
  m.phase=other.phase=Motion::Phase::Activity;m.socialBeat=other.socialBeat=0;
  m.phaseStarted=other.phaseStarted=seconds_;m.socialOffset=0;other.socialOffset=1.1F;
  const bool sofa=place->kind==1,coffee=place->kind==4;
  if(sofa) {
    const bool looksPositive=traffic_.state(a.id).position.x<traffic_.state(m.partnerId).position.x;
    m.activity=looksPositive?"talking_sofa_coffee_left":"talking_sofa_coffee_right";
    other.activity=looksPositive?"talking_sofa_coffee_right":"talking_sofa_coffee_left";
  } else if(coffee)m.activity=other.activity="talking_coffee";
  else m.activity=other.activity=hasClip(avatar(a),"greeting")?"greeting":"playing_foosball";
  m.socialUntil=other.socialUntil=seconds_+(m.activity=="greeting"?1.32F:4.5F+random(m)*2);
  m.holdUntil=other.holdUntil=seconds_+(sofa?20.F:coffee?14.F:10.F)*(.8F+.2F*(m.personality.sociability+other.personality.sociability))+random(m)*5;
  if(m.activity=="greeting")other.socialOffset=-.12F;
}
void Office::updateSocial(const Agent &a,Motion &m) {
  const auto *place=socket(m.socketId);const auto found=motion_.find(m.partnerId);
  if(!place||found==motion_.end()||seconds_<m.socialUntil||m.returning)return;
  auto &other=found->second;
  const auto *otherPlace=socket(other.socketId);
  if(other.phase!=Motion::Phase::Activity||other.returning||!otherPlace||otherPlace->kind!=place->kind)return;
  const bool sofa=place->kind==1,coffee=place->kind==4;
  const auto previous=m.activity,otherPrevious=other.activity;
  if(!sofa&&!coffee) {m.activity=other.activity="playing_foosball";m.socialUntil=other.socialUntil=m.holdUntil;}
  else {
    ++m.socialBeat;other.socialBeat=m.socialBeat;
    const char *laugh=sofa?"laughing_sofa_coffee":"laughing_coffee";
    if(m.socialBeat==1&&hasClip(avatar(a),laugh)) {m.activity=other.activity=laugh;m.socialUntil=other.socialUntil=seconds_+3.12F;}
    else if(m.socialBeat==2) {
      m.activity=sofa?"drinking_sofa_coffee":"drinking_coffee";other.activity=sofa?"sitting_sofa_coffee":"carrying_coffee";
      m.socialUntil=other.socialUntil=seconds_+3.6F;
      m.holdUntil=other.holdUntil=std::max(m.holdUntil,m.socialUntil);
    } else if(m.socialBeat==3&&m.holdUntil-seconds_>=3.6F) {
      m.activity=sofa?"sitting_sofa_coffee":"carrying_coffee";other.activity=sofa?"drinking_sofa_coffee":"drinking_coffee";
      m.socialUntil=other.socialUntil=seconds_+3.6F;
    } else {
      if(sofa) {
        const bool positive=traffic_.state(a.id).position.x<traffic_.state(m.partnerId).position.x;
        m.activity=positive?"talking_sofa_coffee_left":"talking_sofa_coffee_right";other.activity=positive?"talking_sofa_coffee_right":"talking_sofa_coffee_left";
      }else m.activity=other.activity="talking_coffee";
      m.socialUntil=other.socialUntil=m.holdUntil;
    }
  }
  if(m.activity!=previous){m.phaseStarted=seconds_;m.socialOffset=0;}
  if(other.activity!=otherPrevious){other.phaseStarted=seconds_;other.socialOffset=oneShotAnimation(other.activity)?-.12F:other.activity.starts_with("drinking")?0.F:1.1F;}
}
bool Office::continueAtSofa(const Agent &a,Motion &m) {
  // Each sofa has its own narrow entrance. Admit one party per cushion until
  // its last member has left, and never split a coffee pair across both sofas.
  const auto peer=std::find_if(agents_.begin(),agents_.end(),[&](const auto &p){return p.id==m.partnerId;});
  if(peer==agents_.end()||!freeAgent(*peer)||!freeAgent(a)||!m.carrying||!hasClip(avatar(a),"sitting_sofa_coffee"))return false;
  auto &other=motion_.at(peer->id);const auto *otherPlace=socket(other.socketId);
  if(other.returning||!other.carrying||!otherPlace||otherPlace->kind!=4)return false;
  const auto furniture=chairDiscs();
  const bool wantLeft=((m.personality.seed+static_cast<std::uint64_t>(a.seat))%2)==1;
  for(int pass=0;pass<2;++pass) {
    const bool left=pass==0?wantLeft:!wantLeft;
    if(loungeReserved(left))continue;
  for(const auto &first:sockets_)for(auto secondIt=sockets_.rbegin();secondIt!=sockets_.rend();++secondIt) {
    const auto &second=*secondIt;
    if(first.kind!=1||second.kind!=1||screenLeftLounge(first)!=left||screenLeftLounge(second)!=left||first.id==second.id||claims_.contains(first.id)||claims_.contains(second.id))continue;
    auto firstBlocked=furniture;firstBlocked.push_back({traffic_.state(peer->id).position,Traffic::clearance-Traffic::radius});
    auto firstRoute=sofaRoute(first,firstBlocked);
    auto secondBlocked=furniture;secondBlocked.push_back({first.position,Traffic::clearance-Traffic::radius});
    auto secondRoute=sofaRoute(second,secondBlocked);
    if(firstRoute.empty()||secondRoute.empty()||navigation_.route(traffic_.state(a.id).position,firstRoute.back(),firstBlocked,Traffic::radius).empty()||
      navigation_.route(traffic_.state(peer->id).position,secondRoute.back(),secondBlocked,Traffic::radius).empty())continue;
    claim(first.id,a.id);claim(second.id,peer->id);m.sofaCoffee=other.sofaCoffee=true;
    m.chatId.clear();other.chatId.clear();m.targetId=first.id;other.targetId=second.id;
    m.arrivalSocket=first.id;m.arrivalRoute=std::move(firstRoute);other.arrivalSocket=second.id;other.arrivalRoute=std::move(secondRoute);
    // Reserve the second place while its colleague enters the tighter one.
    other.awaitSofaEntry=true;other.activity="carrying_coffee";other.holdUntil=seconds_+120;
    requestTravel(a,m);return true;
  }
  }
  return false;
}
std::size_t Office::committedLeisureAgents() const {
  return static_cast<std::size_t>(std::count_if(motion_.begin(),motion_.end(),[](const auto &entry) {
    const auto &m=entry.second;
    return m.phase!=Motion::Phase::Desk || !m.chatId.empty() || m.targetId!=m.socketId;
  }));
}
void Office::scheduleDeskRecovery(Motion &m) {
  m.leisureStartedAt=-1.F;
  // Recover any cumulative deficit, not only the latest trip. Five minutes
  // away therefore requires enough seated time to bring the entire measured
  // office session back to 85%, including travel and furniture transitions.
  const float deficit=deskRecoverySeconds(m.awaySeconds)-m.deskSeconds;
  m.holdUntil=seconds_+std::max(60.F,deficit);
}
bool Office::claim(std::string_view socketId, const std::string &agentId) {
  const auto [it, inserted] = claims_.try_emplace(std::string(socketId), agentId);
  return inserted || it->second == agentId;
}
void Office::release(const std::string &agentId, std::string_view except) {
  std::erase_if(claims_, [&](const auto &p) { return p.second == agentId && p.first != except; });
}
void Office::beginStand(const Agent &a, Motion &m) {
  const auto *origin = socket(m.socketId);
  if (!origin || m.exitRoute.empty()) { m.holdUntil = seconds_ + 5; return; }
  if(m.phase==Motion::Phase::Desk&&m.leisureStartedAt<0)m.leisureStartedAt=seconds_;
  m.phaseStarted = seconds_; m.phaseDistance=traffic_.state(a.id).distance; m.transitionStarted = false;
  traffic_.pin(a.id, false); traffic_.face(a.id, origin->yaw);
  if(origin->chairNode>=0 && chairOffsets_[a.seat]<.99F) {
    m.phase=Motion::Phase::Pullback;
    traffic_.requestSocket(a.id,{traffic_.state(a.id).position,rolledPosition(*origin)},origin->pullback/.5F,origin->yaw,true);
  } else {
    m.phase=Motion::Phase::Stand;
    traffic_.requestSocket(a.id,{traffic_.state(a.id).position,rolledApproach(*origin)},1.F,origin->yaw,origin->kind==0);
  }
}
void Office::returnToDesk(const Agent &a, Motion &m) {
  // Put the cup back down from the mouth before starting a walk or standing up.
  // A work interruption waits at most one sip, then keeps its normal priority.
  if(m.phase==Motion::Phase::Activity&&m.activity.starts_with("drinking")&&seconds_<m.phaseStarted+3.6F)return;
  m.returning = true;m.chatId.clear();
  const auto *physical=socket(m.socketId);
  if(physical&&physical->kind==2&&m.phase==Motion::Phase::Activity&&hasClip(avatar(a),"coffee_putdown")) {
    // Finish acquiring/depositing the cup already in the machine before leaving.
    m.returningCup=true;return;
  }
  m.returningCup=m.carrying&&hasClip(avatar(a),"coffee_putdown");
  // Finish the physical entry into this seat before changing its destination.
  // Otherwise Align would connect a sofa marker directly to a remote desk.
  const auto *destination=socket(m.targetId);
  if(m.phase==Motion::Phase::Enter || m.phase==Motion::Phase::Sit ||
     (m.phase==Motion::Phase::Align && destination && destination->kind<=1)) return;
  m.targetId = m.returningCup?"coffee_active":"desk_" + std::to_string(a.seat);
  claim(m.targetId, a.id);
  if (m.phase == Motion::Phase::Desk) return;
  if (m.phase == Motion::Phase::Stand || m.phase == Motion::Phase::Exit || m.phase == Motion::Phase::Enter || m.phase == Motion::Phase::Sit || m.phase == Motion::Phase::Pullback || m.phase == Motion::Phase::RollSettle || m.phase == Motion::Phase::PushIn) return;
  const auto *current = socket(m.socketId);
  if ((m.phase == Motion::Phase::Activity || m.phase == Motion::Phase::WaitPartner) && current && current->kind == 1) beginStand(a, m);
  else requestTravel(a, m);
}
bool Office::chooseMission(const Agent &a, Motion &m) {
  // The table's west side must be reached first: an east participant occupies
  // the narrow approach used to enter the west side. Its partner waits seated.
  if(const auto *reserved=socket(m.targetId);reserved&&reserved->kind==3&&!m.partnerId.empty()) {
    const auto partner=motion_.find(m.partnerId);
    if(partner==motion_.end()||partner->second.returning) {release(a.id,m.socketId);m.targetId=m.socketId;m.partnerId.clear();return false;}
    if(partner->second.socketId!="foosball_a"||partner->second.phase!=Motion::Phase::WaitPartner) return false;
    m.returning=false;beginStand(a,m);return m.phase==Motion::Phase::Pullback||m.phase==Motion::Phase::Stand;
  }
  const bool cupReturnsPending=std::any_of(motion_.begin(),motion_.end(),[](const auto &entry){return entry.second.returningCup;});
  // Completed drinks and work interruptions have priority over a new coffee.
  // The current preparation/deposit finishes; new customers stay at their desk.
  if (!m.chatId.empty()) {
    if(cupReturnsPending)return false;
    if (!claim("coffee_active", a.id)) return false;
    m.targetId = "coffee_active"; m.returning = false; beginStand(a, m); return m.phase == Motion::Phase::Stand || m.phase == Motion::Phase::Pullback;
  }
  const auto concurrentCap=std::min(maxConcurrentLeisureAgents,agents_.size());
  const auto committed=committedLeisureAgents();
  if(committed>=concurrentCap)return false;
  const auto available=concurrentCap-committed;
  for (std::size_t attempt = 0; attempt < 4; ++attempt) {
    const auto cycle=m.cycle++;
    const auto choice = (cycle + static_cast<std::size_t>(a.seat) + (cycle>=4?m.personality.seed%4:0)) % 4;
    if (choice == 3 || sockets_.size() == seats.size()) {
      m.targetId.clear(); m.returning = false; beginStand(a, m); return m.phase == Motion::Phase::Stand || m.phase == Motion::Phase::Pullback;
    }
    const std::uint32_t kind = choice == 0 ? 2 : choice == 1 ? 1 : 3;
    // Coffee conversations and foosball reserve two colleagues as one social
    // outing. Never let that reservation silently exceed the office-wide cap.
    if((kind==2||kind==3)&&agents_.size()>1&&available<2)continue;
    const bool wantLeftLounge=kind==1&&((cycle+static_cast<std::size_t>(a.seat))%2)==1;
    for (const auto &s : sockets_) {
      if (s.kind != kind || claims_.contains(s.id)) continue;
      if (kind == 1) {
        if (socketRoutes_.find(s.id) == socketRoutes_.end() || socketRoutes_.at(s.id).empty()) continue;
        const bool left=screenLeftLounge(s);
        if (loungeReserved(left)) continue;
        // Keep both lounges in the rotation. Fall back only when the preferred cushion is full.
        if (left != wantLeftLounge && loungeOpen(wantLeftLounge)) continue;
      }
      if (kind == 2) {
        if(cupReturnsPending)continue;
        const auto chat = std::find_if(sockets_.begin(), sockets_.end(), [&](const auto &slot) { return slot.kind == 4 && !claims_.contains(slot.id); });
        if (chat == sockets_.end()) continue;
        claim(chat->id, a.id); m.chatId = chat->id;
        // Recruit one free colleague now so conversations have two cups and
        // participants; they remain seated until the machine is released.
        for (const auto &peer : agents_) {
          if (peer.id == a.id || !freeAgent(peer)) continue;
          auto &other = motion_.at(peer.id);
          if (other.phase != Motion::Phase::Desk || other.holdUntil>seconds_+partnerReservationLeadSeconds ||
              other.deskGesture.starts_with("phone_") || !other.chatId.empty() ||
              (other.targetId!=other.socketId&&!other.partnerId.empty())) continue;
          const auto partnerSlot = std::find_if(sockets_.begin(), sockets_.end(), [&](const auto &slot) { return slot.kind == 4 && !claims_.contains(slot.id); });
          if (partnerSlot == sockets_.end()) break;
          claim(partnerSlot->id, peer.id); other.chatId = partnerSlot->id;
          other.partnerId = a.id; m.partnerId = peer.id;
          break;
        }
        if(agents_.size()>1&&m.partnerId.empty()) {
          release(a.id,m.socketId);m.chatId.clear();continue;
        }
      }
      if (kind == 3) {
        if(s.id!="foosball_a") continue;
        const auto otherSlot = std::find_if(sockets_.begin(), sockets_.end(), [&](const auto &slot) { return slot.kind == 3 && slot.id != s.id && !claims_.contains(slot.id); });
        auto peer = std::find_if(agents_.begin(), agents_.end(), [&](const auto &p) {
          const auto &other=motion_.at(p.id);
          return p.id!=a.id && freeAgent(p) && other.phase==Motion::Phase::Desk &&
            other.holdUntil<=seconds_+partnerReservationLeadSeconds && !other.deskGesture.starts_with("phone_") &&
            other.chatId.empty() && (other.targetId==other.socketId||other.partnerId.empty());
        });
        if (otherSlot == sockets_.end() || peer == agents_.end()) continue;
        auto &other = motion_.at(peer->id); other.targetId=otherSlot->id; other.returning=false;
        other.partnerId=a.id; m.partnerId=peer->id; claim(otherSlot->id,peer->id);
      }
      claim(s.id,a.id); m.targetId=s.id; m.returning=false; beginStand(a,m); return m.phase==Motion::Phase::Stand || m.phase==Motion::Phase::Pullback;
    }
  }
  return false;
}
void Office::requestTravel(const Agent &a, Motion &m) {
  traffic_.pin(a.id,false); m.phase=Motion::Phase::Travel; m.phaseStarted=seconds_;
  Vec3 goal;
  if (const auto *target=socket(m.targetId)) {
    if (target->kind<=1) {
      if(m.arrivalSocket!=target->id) {
        m.arrivalSocket=target->id;
        m.arrivalRoute=target->kind==1?sofaRoute(*target,chairDiscs()):socketRoutes_.at(target->id);
      }
      if(m.arrivalRoute.empty()) {
        m.phase=Motion::Phase::Activity;m.activity=m.carrying?"carrying_coffee":"idle";m.holdUntil=seconds_+3;
        m.socketId.clear();traffic_.cancel(a.id);return;
      }
      goal=m.arrivalRoute.back();
    } else goal=target->position;
  } else {
    const auto desired=navigation_.waypoint(static_cast<std::size_t>(a.seat),m.waypoint++);
    const auto reachable=navigation_.nearestReachable(desired,traffic_.state(a.id).position,2.F,Traffic::radius);
    if(!reachable) { m.returning=true; m.targetId="desk_"+std::to_string(a.seat); requestTravel(a,m); return; }
    goal=*reachable;
  }
  // A claim belongs to the actor until it physically starts departing. Traffic
  // still accounts for the body while a new owner waits outside the corridor.
  std::erase_if(claims_,[&](const auto &p){return p.second==a.id && p.first!=m.targetId && p.first!=m.chatId;});
  m.socketId.clear();
  const auto *target=socket(m.targetId);
  const float intended=m.carrying?.62F:m.returning?.9F:target&&target->kind==3?1.05F:.78F;
  traffic_.setSpeed(a.id,std::min(1.10F,intended*m.personality.pace));
  const auto &scene=avatar(a);
  m.gait=m.carrying?"walking_coffee":!m.returning&&target&&target->kind==3&&hasClip(scene,"walking_brisk")?"walking_brisk":!m.returning&&hasClip(scene,"walking_relaxed")?"walking_relaxed":"walking";
  traffic_.request(a.id,goal);
}
void Office::tick(float dt) {
  if (avatars_.empty()) return;
  const bool advancing=dt>0 && !paused_;
  if(advancing) seconds_+=dt;
  for(const auto &a:agents_) {
    auto [it,inserted]=motion_.try_emplace(a.id);
    if(inserted) {
      auto &m=it->second; m.socketId="desk_"+std::to_string(a.seat); m.targetId=m.socketId;
      m.personality=agentPersonality(a.id);m.randomState=m.personality.seed;
      // Build enough initial desk presence for a normal 30-second outing, and
      // stagger the roster so opening the office never empties all chairs.
      m.holdUntil=seconds_+deskRecoverySeconds(30.F)+random(m)*45.F+static_cast<float>(a.seat)*3.F;m.waypoint=static_cast<std::size_t>(a.seat);
      m.gestureUntil=seconds_+3+random(m)*9;m.gesturePhase=random(m)*4;m.deskGesture=deskClip(a);m.exitRoute=socketRoutes_.at(m.socketId);
      const auto &s=seats[static_cast<std::size_t>(a.seat)];
      const auto *authored=socket(m.socketId);
      traffic_.add(a.id,authored?authored->position:Vec3{s.x,0,s.z},authored?authored->yaw:s.yaw);
      traffic_.pin(a.id,true); claim(m.socketId,a.id);
    }
  }
  if(!advancing) return;
  for(const auto &a:agents_) {
    auto &m=motion_.at(a.id);
    if(m.phase==Motion::Phase::Desk)m.deskSeconds+=dt;
    else m.awaySeconds+=dt;
  }
  std::vector<Traffic::Furniture> furniture;
  for(const auto &s:sockets_) if(s.chairNode>=0 && s.kind==0) {
    const auto seat=static_cast<std::size_t>(std::stoi(s.id.substr(5)));
    if(chairOffsets_[seat]>.001F) {
      const auto owner=std::find_if(agents_.begin(),agents_.end(),[&](const auto &a){return a.seat==static_cast<int>(seat);});
      furniture.push_back({owner==agents_.end()?std::string{}:owner->id,s.position-avatarForward(s.yaw)*(s.pullback*chairOffsets_[seat]),.4F});
    }
  }
  traffic_.setFurniture(std::move(furniture));
  for(const auto &a:agents_) {
    auto &m=motion_.at(a.id); auto &body=traffic_.state(a.id);
    if(!freeAgent(a) && m.phase!=Motion::Phase::Desk && !m.returning) returnToDesk(a,m);
    if(m.phase==Motion::Phase::Desk) {
      if(!freeAgent(a)) {release(a.id,m.socketId);m.chatId.clear();m.partnerId.clear();m.targetId=m.socketId;}
      traffic_.pin(a.id,true);updateDeskGesture(a,m);
      if(freeAgent(a) && !m.deskGesture.starts_with("phone_") && seconds_>=m.holdUntil && !chooseMission(a,m)) m.holdUntil=seconds_+.75F;
    }
    if(m.awaitSofaEntry) {
      const auto peer=motion_.find(m.partnerId);
      if(m.returning||peer==motion_.end()||peer->second.returning) {m.awaitSofaEntry=false;returnToDesk(a,m);}
      else if(peer->second.phase==Motion::Phase::WaitPartner&&peer->second.sofaCoffee) {m.awaitSofaEntry=false;requestTravel(a,m);}
    }
    if(m.phase==Motion::Phase::RollSettle && seconds_>=m.holdUntil) beginStand(a,m);
    if(m.phase==Motion::Phase::Align) {
      const auto *s=socket(m.targetId); if(!s) { returnToDesk(a,m); continue; }
      traffic_.face(a.id,s->yaw);
      if(std::abs(std::remainder(body.yaw-s->yaw,6.283185307F))<.035F) {
        m.socketId=s->id;m.enteredAt=seconds_;if(s->kind<=1)m.exitRoute=m.arrivalRoute;
        if(s->kind<=1) {
          m.phase=Motion::Phase::Sit; m.phaseStarted=seconds_; m.transitionStarted=false;
          traffic_.requestSocket(a.id,{body.position,rolledPosition(*s)},s->kind==1?1.F:1.1F,s->yaw,s->kind==0);
        } else {
          traffic_.pin(a.id,true); m.phase=(s->kind==3||s->kind==4)?Motion::Phase::WaitPartner:Motion::Phase::Activity;
          m.activity=s->kind==2?(m.returningCup?"coffee_putdown":"preparing_coffee"):s->kind==3?"playing_foosball":"carrying_coffee";
          m.phaseStarted=seconds_;m.holdUntil=seconds_+(m.activity=="coffee_putdown"?1.1F:s->holdSeconds);
        }
      }
    }
    if(m.phase==Motion::Phase::WaitPartner) {
      const auto *ownSlot=socket(m.socketId);
      // Match the participants actually occupying this two-person activity.
      // Recruitment can change while another colleague is travelling or working.
      auto partner=std::find_if(motion_.begin(),motion_.end(),[&](const auto &entry){
        const auto *other=socket(entry.second.socketId);
        return entry.first!=a.id && ownSlot && other && ownSlot->kind==other->kind && (ownSlot->kind!=1||(m.sofaCoffee&&entry.second.sofaCoffee&&screenLeftLounge(*ownSlot)==screenLeftLounge(*other))) &&
          (entry.second.phase==Motion::Phase::WaitPartner||entry.second.phase==Motion::Phase::Activity)&&!entry.second.returning;
      });
      const auto *peerSlot=partner==motion_.end()?nullptr:socket(partner->second.socketId);
      if(partner!=motion_.end() && (partner->second.phase==Motion::Phase::WaitPartner||partner->second.phase==Motion::Phase::Activity) &&
         ownSlot && peerSlot && ownSlot->kind==peerSlot->kind && !partner->second.returning &&
         length(traffic_.state(partner->first).position-body.position)<2.3F) {
        auto &other=partner->second;m.partnerId=partner->first;other.partnerId=a.id;
        startSocial(a,m,other);
        if(ownSlot->kind==4) {const auto toward=traffic_.state(m.partnerId).position-body.position;traffic_.face(a.id,avatarYaw(toward));traffic_.face(m.partnerId,avatarYaw(toward*-1));}
      } else if(seconds_-m.phaseStarted>partnerArrivalTimeoutSeconds) {
        if(m.carrying) { m.phase=Motion::Phase::Activity; m.activity=ownSlot&&ownSlot->kind==1?"drinking_sofa_coffee":"drinking_coffee"; m.phaseStarted=seconds_; m.holdUntil=seconds_+3.6F; }
        else returnToDesk(a,m);
      }
    }
    if(m.phase==Motion::Phase::Activity)updateSocial(a,m);
    if(m.phase==Motion::Phase::Activity && seconds_>=m.holdUntil) {
      const auto *s=socket(m.socketId);
      if(s&&s->kind==2&&m.returningCup) {
        if(m.activity=="preparing_coffee") {m.carrying=true;m.activity="coffee_putdown";m.phaseStarted=seconds_;m.holdUntil=seconds_+1.1F;}
        else {m.carrying=false;m.returningCup=false;m.targetId="desk_"+std::to_string(a.seat);requestTravel(a,m);}
      } else if(s&&s->kind==2&&!m.returning) { m.carrying=true; m.targetId=m.chatId; requestTravel(a,m); }
      else if(s&&s->kind==4&&!m.returning&&continueAtSofa(a,m)) {}
      else returnToDesk(a,m);
    }
    if(m.phase==Motion::Phase::Travel && body.pending && body.waitingSeconds>(m.partnerId.empty()?45.F:120.F) && !m.returning) returnToDesk(a,m);
  }
  traffic_.step(dt);
  for(const auto &a:agents_) {
    auto &m=motion_.at(a.id); const auto &b=traffic_.state(a.id);
    if(m.phase==Motion::Phase::Pullback || m.phase==Motion::Phase::PushIn) {
      if(const auto *s=socket(m.socketId);s&&s->pullback>0)
        chairOffsets_[a.seat]=std::clamp(length(b.position-s->position)/s->pullback,0.F,1.F);
    }
    if(!b.arrived || b.pending || b.active) continue;
    if(m.phase==Motion::Phase::Pullback) {
      chairOffsets_[a.seat]=1; m.phase=Motion::Phase::RollSettle; m.holdUntil=seconds_+.22F; traffic_.pin(a.id,true);
    } else if(m.phase==Motion::Phase::PushIn) {
      chairOffsets_[a.seat]=0; m.phase=Motion::Phase::Desk; m.returning=false; m.carrying=false; m.activity="sitting";
      m.chatId.clear();m.partnerId.clear();m.sofaCoffee=false;m.awaitSofaEntry=false;m.arrivalSocket.clear();release(a.id,m.socketId);++m.trips;scheduleDeskRecovery(m);traffic_.pin(a.id,true);
    } else
    if(m.phase==Motion::Phase::Stand) {
      auto route=m.exitRoute;route.front()=b.position;
      m.phase=Motion::Phase::Exit;traffic_.requestSocket(a.id,std::move(route),0,0,socket(m.socketId)->kind==0);
    } else if(m.phase==Motion::Phase::Exit) requestTravel(a,m);
    else if(m.phase==Motion::Phase::Travel) {
      const auto *target=socket(m.targetId);
      if(!target) { m.phase=Motion::Phase::Activity; m.activity="idle"; m.holdUntil=seconds_+2; }
      else if(target->kind<=1) {
        auto route=m.arrivalRoute;std::reverse(route.begin(),route.end());route.front()=b.position;
        m.phase=Motion::Phase::Enter;traffic_.requestSocket(a.id,std::move(route),0,0,target->kind==0);
      } else { m.phase=Motion::Phase::Align; traffic_.face(a.id,target->yaw); }
    } else if(m.phase==Motion::Phase::Enter) {
      m.phase=Motion::Phase::Align; if(const auto *s=socket(m.targetId)) traffic_.face(a.id,s->yaw);
    } else if(m.phase==Motion::Phase::Sit) {
      const auto *s=socket(m.socketId); traffic_.pin(a.id,true);
      if(s&&s->kind==0 && s->chairNode>=0) {
        m.phase=Motion::Phase::PushIn;m.phaseStarted=seconds_;m.phaseDistance=b.distance;traffic_.pin(a.id,false);
        traffic_.requestSocket(a.id,{b.position,s->position},s->pullback/.5F,s->yaw,true);
      } else if(s&&s->kind==0) {
        m.phase=Motion::Phase::Desk; m.returning=false; m.carrying=false; m.activity="sitting";
        m.chatId.clear(); m.partnerId.clear();m.sofaCoffee=false;m.awaitSofaEntry=false;m.arrivalSocket.clear(); release(a.id,m.socketId); ++m.trips; scheduleDeskRecovery(m);
      } else {
        m.phase=m.sofaCoffee?Motion::Phase::WaitPartner:Motion::Phase::Activity;m.activity=m.sofaCoffee?"sitting_sofa_coffee":"sitting_sofa";
        m.phaseStarted=seconds_;m.socialUntil=seconds_+120;m.holdUntil=seconds_+(s?s->holdSeconds:8);
        if(m.returning) {m.targetId=m.returningCup?"coffee_active":"desk_"+std::to_string(a.seat);claim(m.targetId,a.id);beginStand(a,m);}
      }
    }
  }
}
void Office::publishFrame() {
  auto f=std::make_shared<Frame>(); f->sequence=sequence_++;f->sceneSeconds=seconds_;
  if(office_) {
    Instance room{office_,trs({}, {0,1,0,0}),"",0,{}};
    for(const auto &s:sockets_) if(s.chairNode>=0 && s.kind==0) {
      const auto seat=static_cast<std::size_t>(std::stoi(s.id.substr(5)));
      if(chairOffsets_[seat]>0) room.nodeTranslations.push_back({static_cast<std::uint32_t>(s.chairNode),s.chairLocalDelta*chairOffsets_[seat]});
    }
    f->instances.push_back(std::move(room));
  }
  for(const auto &a:agents_) {
    if(avatars_.empty()) break;
    const auto found=std::find_if(avatars_.begin(),avatars_.end(),[&](const auto &v){return v.first==a.assetType;});
    const auto scene=found==avatars_.end()?avatars_.front().second:found->second;
    auto &m=motion_.at(a.id); const auto &b=traffic_.state(a.id);
    const float scale=1.75F/std::max(.1F,scene->referenceHeight), standingY=-scene->referenceMinY*scale+navigation_.floorHeightAt(b.position);
    float y=standingY; std::string animation=m.carrying?"carrying_coffee":"idle"; float clipTime=seconds_;
    const auto *s=socket(m.socketId);
    if(m.phase==Motion::Phase::Desk) {animation=m.deskGesture;clipTime=(seconds_-m.gestureStarted)+m.gesturePhase;
      if(!hasClip(*scene,animation))animation=deskClip(a);
      y=(s?s->seatHeight:deskSeatHeight)-scene->sittingPelvisHeight;}
    else if(m.phase==Motion::Phase::Pullback||m.phase==Motion::Phase::PushIn||m.phase==Motion::Phase::RollSettle) {
      animation=b.translating?(m.phase==Motion::Phase::Pullback?"chair_pullback":"chair_pushin"):"sitting";
      y=(s?s->seatHeight:deskSeatHeight)-scene->sittingPelvisHeight;clipTime=(b.distance-m.phaseDistance)/.5F;
    }
    else if(m.phase==Motion::Phase::Stand||m.phase==Motion::Phase::Sit) {
      const bool sofa=s&&s->kind==1; const bool standing=m.phase==Motion::Phase::Stand;
      const auto clip=standing?(sofa?(m.carrying?"stand_up_sofa_coffee":"stand_up_sofa"):"stand_up"):(sofa?(m.carrying?"sit_down_sofa_coffee":"sit_down_sofa"):"sit_down");
      const float duration=clipDuration(*scene,clip,standing?1.F:sofa?1.F:1.1F);
      const float seatedY=(s?s->seatHeight:deskSeatHeight)-(sofa?scene->sofaPelvisHeight:scene->sittingPelvisHeight);
      const float progress=ease(b.motionSeconds/std::max(.01F,duration));
      y=standing?seatedY+(standingY-seatedY)*progress:standingY+(seatedY-standingY)*progress;
      animation=b.pending?(standing?(sofa?(m.carrying?"sitting_sofa_coffee":"sitting_sofa"):"sitting"):(m.carrying?"carrying_coffee":"idle")):clip;
      clipTime=b.motionSeconds;
    } else if(m.phase==Motion::Phase::Activity||m.phase==Motion::Phase::WaitPartner) {
      animation=m.phase==Motion::Phase::WaitPartner?(s&&s->kind==1?"sitting_sofa_coffee":m.carrying?"carrying_coffee":"idle"):m.activity;
      clipTime=seconds_-m.phaseStarted+((s&&s->kind!=2)?m.socialOffset:0);
      if(s&&s->kind==1) y=s->seatHeight-scene->sofaPelvisHeight;
    } else if(b.translating) animation=m.carrying?"walking_coffee":m.gait;
    m.animation.transition(*scene,animation,seconds_);
    auto samples=m.animation.sample(seconds_);
    // These authored one-shots start/end at the matching resting poses. Their
    // foot compensation must have the same weight as the runtime root motion.
    if((m.phase==Motion::Phase::Stand||m.phase==Motion::Phase::Sit)&&!b.pending)
      samples={{animation,clipTime,1}};
    for(auto &sample:samples) {
      if(sample.clip=="walking"||sample.clip=="walking_coffee") sample.seconds=b.distance;
      if(sample.clip=="walking_brisk")sample.seconds=b.distance/1.35F;
      if(sample.clip=="walking_relaxed")sample.seconds=b.distance/.70F;
      if(sample.clip=="chair_pullback"||sample.clip=="chair_pushin") sample.seconds=clipTime;
      if(sample.clip==animation && (m.phase==Motion::Phase::Stand||m.phase==Motion::Phase::Sit||m.phase==Motion::Phase::Desk||m.phase==Motion::Phase::Activity||oneShotAnimation(animation))) sample.seconds=clipTime;
    }
    const auto placement=trs({b.position.x,y,b.position.z},{0,std::sin(b.yaw*.5F),0,std::cos(b.yaw*.5F)},{scale,scale,-scale});
    const auto head=headPosition(*scene,samples);const auto projected=transform(placement,{head.x,head.y,head.z,1});
    const std::string activity=!freeAgent(a)&&(a.status=="offline"||a.status=="away")?a.status:
      m.phase==Motion::Phase::WaitPartner?"waiting_for_colleague":
      (m.phase==Motion::Phase::Travel||m.phase==Motion::Phase::Exit)&&b.pending&&!b.translating?"waiting":animation;
    const float activityLevel=b.translating?.6F:m.phase==Motion::Phase::Desk?(freeAgent(a)?.35F:.85F):m.phase==Motion::Phase::Activity?.7F:.25F;
    f->actorIndicators.push_back({a.id,a.name,activity,a.level,{projected.x,projected.y+.10F,projected.z},activityLevel});
    Instance body{scene,placement,animation,clipTime,a.id,std::move(samples)};
    const bool hasPhone=std::any_of(scene->materials.begin(),scene->materials.end(),[](const auto &material){return material.surfaceKind==2;});
    if(hasPhone) {
      const bool calling=m.phase==Motion::Phase::Desk&&m.deskGesture.starts_with("phone_");
      body.surfaceMask&=~((1U<<2)|(1U<<3));if(calling)body.surfaceMask|=1U<<2;
      const auto *desk=socket("desk_"+std::to_string(a.seat));
      if(desk) {
        const float propY=desk->seatHeight-scene->sittingPelvisHeight;
        Instance props{scene,trs({desk->position.x,propY,desk->position.z},{0,std::sin(desk->yaw*.5F),0,std::cos(desk->yaw*.5F)},{scale,scale,-scale}),"typing",0,{}};
        props.surfaceMask=(1U<<3)|(calling?0U:(1U<<2));f->instances.push_back(std::move(props));
      }
    }
    f->instances.push_back(std::move(body));
  }
  {std::lock_guard lock(frameMutex_);frame_=std::move(f);}
}
void Office::advance(float dt) {
  if(!std::isfinite(dt)||dt<0||dt>3600) throw std::invalid_argument("Invalid office simulation interval");
  std::lock_guard lock(mutex_);
  if(dt==0) {tick(0);publishFrame();return;}
  while(dt>0) { const float step=std::min(dt,1.F/60.F); tick(step);dt-=step; }
  publishFrame();
}
void Office::run(std::stop_token stop) {
  using clock=std::chrono::steady_clock; auto next=clock::now();
  while(!stop.stop_requested()) {
    next+=std::chrono::nanoseconds(16666667); advance(1.F/60.F);
    std::this_thread::sleep_until(next); if(next<clock::now()-std::chrono::milliseconds(100)) next=clock::now();
  }
}
std::vector<Office::MotionDebug> Office::debugMotion() const {
  std::lock_guard lock(mutex_); std::vector<MotionDebug> result;
  constexpr const char *phases[]={"desk","stand","exit","travel","enter","align","sit","activity","wait_partner","pullback","roll_settle","pushin"};
  for(const auto &a:agents_) { const auto it=motion_.find(a.id); if(it==motion_.end())continue; const auto &m=it->second; const auto &b=traffic_.state(a.id);
    const float total=m.deskSeconds+m.awaySeconds;
    result.push_back({a.id,phases[static_cast<int>(m.phase)],m.activity,m.socketId,b.position,b.yaw,b.distance,b.waitingSeconds,total>0?m.deskSeconds/total:1.F,b.translating,m.carrying,m.trips,b.yields}); }
  return result;
}
std::shared_ptr<const Frame> Office::snapshot(float aspect) const {
  std::lock_guard lock(frameMutex_);
  aspect = std::isfinite(aspect) ? std::max(.2F, aspect) : 1.F;
  auto f = std::make_shared<Frame>(*frame_);
  const Vec3 min = office_ ? Vec3{-office_->max.x, office_->min.y, -office_->max.z}
                          : Vec3{-7, 0, -7};
  const Vec3 max = office_ ? Vec3{-office_->min.x, office_->max.y, -office_->min.z}
                          : Vec3{7, 2.5F, 7};
  if (aspect != cameraAspect_) {
    camera_ = fitOfficeGeometry(frameOffice(min, max, aspect), cameraPoints_, aspect);
    cameraAspect_ = aspect;
  }
  f->viewProjection = camera_.viewProjection;
  f->camera = camera_.position;
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
  n += cameraPoints_.capacity() * sizeof(Vec3);
  for (const auto &a : avatars_)
    n += a.second->residentBytes;
  return n;
}
} // namespace mokaid::engine
