#include <mokaid/engine/office.hpp>
#include <chrono>
#include <ctime>
#include <iostream>
#include <set>
#include <stdexcept>

using namespace mokaid::engine;
namespace {
void expect(bool condition,const char *message){if(!condition)throw std::runtime_error(message);}
void checkStep(const std::vector<Office::MotionDebug> &before,const std::vector<Office::MotionDebug> &after,float dt) {
  for(std::size_t i=0;i<after.size();++i) {
    const auto delta=after[i].position-before[i].position;
    expect(length(delta)<=1.3F*dt+.001F,"Activity transitions and recovery never teleport");
    if(after[i].moving && length(delta)>.00001F && after[i].phase!="sit" && after[i].phase!="stand" && after[i].phase!="pullback" && after[i].phase!="pushin" && before[i].phase!="pushin")
      expect(dot(normalized(delta),avatarForward(after[i].yaw))>.80F,"Activities never walk backwards outside an authored seat transition");
    for(std::size_t j=0;j<i;++j)
      expect(length(after[i].position-after[j].position)>=2*Traffic::radius-.001F,"Nine actors never overlap during activities or socket transitions");
  }
}
void livingCases(Office &office) {
  const auto initial=office.snapshot(1.6F);
  const auto actor=std::find_if(initial->instances.begin(),initial->instances.end(),[](const auto &i){return !i.agentId.empty();});
  if(actor==initial->instances.end()||resolveAnimation(*actor->scene,"coffee_putdown")!="coffee_putdown")return;
  office.setPaused(false);
  std::vector<Agent> working;
  const char *types[]={"male","corporate","developer","design","finance","research","legal","female","male"};
  for(int i=0;i<9;++i)working.push_back({"desk_living_"+std::to_string(i),"Colleague "+std::to_string(i),"working",types[i],i,i+1});
  office.setAgents(working);std::set<std::string> deskClips;std::set<std::string> simultaneous;
  std::unordered_map<std::string,std::pair<std::string,float>> gestureClock;
  for(float time=0;time<180;time+=.1F) {
    office.advance(.1F);const auto frame=office.snapshot(1.6F);simultaneous.clear();
    expect(frame->actorIndicators.size()==9,"One persistent indicator per actor, not per phone prop");
    for(const auto &indicator:frame->actorIndicators)expect(indicator.level>=1&&indicator.level<=9,"Indicator exposes the real supplied level");
    for(const auto &instance:frame->instances)if(!instance.agentId.empty()) {
      deskClips.insert(instance.animation);simultaneous.insert(instance.animation);
      const auto sample=std::find_if(instance.animationSamples.begin(),instance.animationSamples.end(),[&](const auto &s){return s.clip==instance.animation;});
      if(sample!=instance.animationSamples.end()) {
        const auto previous=gestureClock.find(instance.agentId);
        if(previous!=gestureClock.end()&&previous->second.first==instance.animation)expect(sample->seconds>=previous->second.second-.001F,"Repeated random selection of the same desk clip never resets its pose clock");
        gestureClock[instance.agentId]={instance.animation,sample->seconds};
      }
      const bool phone=instance.animation.starts_with("phone_");
      expect(((instance.surfaceMask&(1U<<2))!=0)==phone,"Phone is in the moving character only during pickup/call/putdown");
    }
  }
  for(const char *clip:{"phone_pickup","phone_call","phone_putdown","typing_focused","typing_relaxed","thinking"})
    expect(deskClips.contains(clip),"Distinct desk personalities complete phone and keyboard/reflection gestures");
  expect(simultaneous.size()>1,"Colleagues are not synchronised to a common gesture clock");
  office.setAgents({{"living_cafe_0","Alice","idle","male",0,3},{"living_cafe_1","Bob","idle","design",1,8}});
  std::set<std::string> cafeClips,sofaDrinkers;bool completed=false;constexpr float dt=1.F/30.F;
  std::unordered_map<std::string,float> sipStarted;
  for(float t=0;t<360;t+=dt) {
    const auto before=office.debugMotion();office.advance(dt);const auto after=office.debugMotion();checkStep(before,after,dt);
    const auto frame=office.snapshot(1.6F);
    int drinkingTogether=0;
    for(const auto &instance:frame->instances)if(!instance.agentId.empty()) {
      cafeClips.insert(instance.animation);
      if(instance.animation=="drinking_sofa_coffee") {sofaDrinkers.insert(instance.agentId);++drinkingTogether;}
      if(instance.animation.starts_with("drinking"))sipStarted.try_emplace(instance.agentId,frame->sceneSeconds);
      else if(const auto sip=sipStarted.find(instance.agentId);sip!=sipStarted.end()) {
        expect(frame->sceneSeconds-sip->second>=3.6F-dt-.001F,"A social break cannot expire while the cup is still at the mouth");
        sipStarted.erase(sip);
      }
    }
    expect(drinkingTogether<=1,"Sofa colleagues take turns drinking while the other listens");
    completed=std::all_of(after.begin(),after.end(),[](const auto &m){return m.trips>0;});
    if(completed&&cafeClips.contains("laughing_sofa_coffee")&&cafeClips.contains("coffee_putdown"))break;
  }
  std::cout<<"Living cafe clips:";for(const auto &clip:cafeClips)std::cout<<' '<<clip;std::cout<<'\n';
  expect(completed,"A coordinated cafe/sofa meeting ends with both participants back at their desks");
  expect(sofaDrinkers.size()==2,"Both sofa participants get a complete turn to drink their coffee");
  for(const char *clip:{"walking_coffee","talking_coffee","laughing_coffee","sit_down_sofa_coffee","talking_sofa_coffee_left","talking_sofa_coffee_right","laughing_sofa_coffee","stand_up_sofa_coffee","coffee_putdown"})
    expect(cafeClips.contains(clip),"The whole coffee/sofa/deposit lifecycle must preserve the authored cup poses");
}
void interruptionCases(const char *root) {
  Office office(false);office.load(root);
  Agent agent{"interrupted","Agent","idle","male",1};office.setAgents({agent});
  constexpr float dt=1.F/30.F;bool entering=false;
  for(float t=0;t<300;t+=dt) {office.advance(dt);if(office.debugMotion().front().phase=="enter"){entering=true;break;}}
  expect(entering,"Interruption fixture reaches the sofa entry corridor");
  agent.status="working";office.setAgents({agent});bool returned=false;
  for(float t=0;t<90;t+=dt) {
    const auto before=office.debugMotion();office.advance(dt);const auto after=office.debugMotion();checkStep(before,after,dt);
    if(after.front().phase=="desk") {expect(after.front().socket=="desk_1","Interrupted sofa activity returns to its own physical desk");returned=true;break;}
  }
  expect(returned,"Work interrupt during sofa entry completes without a cross-room seated shortcut");
  agent={"departing","Agent","idle","male",0};office.setAgents({agent});bool rolling=false;
  for(float t=0;t<300;t+=dt) {office.advance(dt);if(!office.snapshot(1.6F)->instances.front().nodeTranslations.empty()){rolling=true;break;}}
  expect(rolling,"Replacement fixture has physically moved its chair");
  agent.id="replacement";agent.status="working";office.setAgents({agent});
  expect(office.snapshot(1.6F)->instances.front().nodeTranslations.empty(),"Replacing an occupant restores its chair and seated placement together");
  agent.seat=1;office.setAgents({agent});
  expect(office.debugMotion().front().socket=="desk_1","Reassigning the same actor resets its old physical seat binding");
}
}
int main(int argc,char **argv) {
  try {
    expect(argc==2,"Activity test requires the cooked office directory");
    expect(std::abs(deskRecoverySeconds(30.F)/(deskRecoverySeconds(30.F)+30.F)-deskPresenceTarget)<1e-6F,
           "Desk recovery math preserves the 85/15 office presence contract");
    Office office(false);office.load(argv[1]);
    std::vector<Agent> agents;
    const char *types[]={"male","corporate","developer","design","finance","research","legal","female","male"};
    for(int i=0;i<9;++i)agents.push_back({"agent_"+std::to_string(i),"Agent","idle",types[i],i});
    office.setAgents(agents);
    std::set<std::string> clips;
    constexpr float dt=1.F/30.F;
    const auto began=std::chrono::steady_clock::now();
    const auto beganCpu=std::clock();
    std::vector<double> advanceMilliseconds,advanceCpuMilliseconds;
    float simulated=0,nextReport=30; bool allReturned=false;
    for(;simulated<1800;simulated+=dt) {
      const auto before=office.debugMotion();const auto stepStart=std::chrono::steady_clock::now();const auto cpuStart=std::clock();office.advance(dt);
      advanceMilliseconds.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-stepStart).count());
      advanceCpuMilliseconds.push_back(1000.*static_cast<double>(std::clock()-cpuStart)/CLOCKS_PER_SEC);
      const auto after=office.debugMotion();checkStep(before,after,dt);
      for(std::size_t i=0;i<after.size();++i)if(before[i].phase=="desk"&&after[i].phase!="desk")
        expect(before[i].deskShare+.0001F>=deskPresenceTarget,"An agent cannot start another break before recovering 85% workstation presence");
      const auto away=std::count_if(after.begin(),after.end(),[](const auto &m){return m.phase!="desk";});
      expect(away<=static_cast<int>(maxConcurrentLeisureAgents),"At most two colleagues may be away from their workstations together");
      if(simulated>=nextReport) {std::cerr<<"Activity progress "<<simulated<<" s\n";for(const auto &m:after)std::cerr<<m.id<<":"<<m.phase<<":"<<m.socket<<"("<<m.position.x<<","<<m.position.z<<") trips="<<m.trips<<" wait="<<m.waitingSeconds<<"\n";nextReport+=30;}
      const auto frame=office.snapshot(1.6F);
      for(const auto &instance:frame->instances)if(!instance.agentId.empty())clips.insert(instance.animation);
      allReturned=std::all_of(after.begin(),after.end(),[](const auto &m){return m.trips>0;});
      if(allReturned && clips.contains("talking_coffee") && clips.contains("playing_foosball") && clips.contains("sitting_sofa"))break;
    }
    for(const auto &m:office.debugMotion())std::cout<<m.id<<" phase="<<m.phase<<" activity="<<m.activity<<" socket="<<m.socket<<" position="<<m.position.x<<','<<m.position.z<<" trips="<<m.trips<<" wait="<<m.waitingSeconds<<" desk_share="<<m.deskShare<<" yields="<<m.yields<<'\n';
    std::cout<<"Observed clips:";for(const auto &clip:clips)std::cout<<' '<<clip;std::cout<<"\nSimulation "<<simulated<<" s; wall "<<std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count()<<" s; process CPU "<<static_cast<double>(std::clock()-beganCpu)/CLOCKS_PER_SEC<<" s\n";
    std::sort(advanceMilliseconds.begin(),advanceMilliseconds.end());
    std::sort(advanceCpuMilliseconds.begin(),advanceCpuMilliseconds.end());
    std::cout<<"Advance two fixed ticks wall ms: p95="<<advanceMilliseconds[advanceMilliseconds.size()*95/100]<<" max="<<advanceMilliseconds.back()<<'\n';
    std::cout<<"Advance two fixed ticks process CPU ms: p95="<<advanceCpuMilliseconds[advanceCpuMilliseconds.size()*95/100]<<" max="<<advanceCpuMilliseconds.back()<<'\n';
    expect(allReturned,"Every one of nine agents completes an activity and returns to its own desk within thirty simulated minutes");
    for(const char *clip:{"walking","sit_down","stand_up","sitting_sofa","preparing_coffee","walking_coffee","talking_coffee","playing_foosball","chair_pullback","chair_pushin"})
      expect(clips.contains(clip),"Every authored office activity must actually run on the real layout");
    // A business task preempts leisure. Everyone must finish safe local motions,
    // then reach their own desk rather than restarting another idle mission.
    for(auto &a:agents)a.status="working";
    office.setAgents(agents);
    bool settled=false;
    for(float t=0;t<150;t+=dt) {
      const auto before=office.debugMotion();office.advance(dt);const auto after=office.debugMotion();checkStep(before,after,dt);
      settled=std::all_of(after.begin(),after.end(),[](const auto &m){return m.phase=="desk";});
      if(settled)break;
    }
    expect(settled,"New work always returns all agents to their desks in bounded time");
    const auto settledFrame=office.snapshot(1.6F);
    for(const auto &instance:settledFrame->instances)if(!instance.agentId.empty())expect(instance.animation=="working"||instance.animation.starts_with("typing")||instance.animation=="thinking"||instance.animation.starts_with("phone_"),"Business work uses only seated professional gestures");
    for(const auto &marker:settledFrame->actorIndicators)expect(marker.activityLevel>=.8F,"Business task stays the active purpose during desk gesture variation");
    expect(office.snapshot(1.6F)->instances.front().nodeTranslations.empty(),"Every physical chair returns to its authored working position");
    office.setPaused(true);const auto stopped=office.debugMotion();office.advance(30);const auto paused=office.debugMotion();
    for(std::size_t i=0;i<paused.size();++i)expect(length(paused[i].position-stopped[i].position)<1e-8F,"Paused simulation stays still");
    expect(office.snapshot(1.6F)->sceneSeconds==settledFrame->sceneSeconds,"Paused screen and indicator time remains coherent with the completed frame");
    interruptionCases(argv[1]);
    livingCases(office);
    std::cout<<"Real office activities PASS\n";return 0;
  } catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 1;}
}
