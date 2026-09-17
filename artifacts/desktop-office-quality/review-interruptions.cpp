// Independent read-only runtime audit through the public Office API.
#include <mokaid/engine/office.hpp>
#include <iostream>
#include <string>
using namespace mokaid::engine;
int main(int argc,char **argv) {
  if(argc!=3)return 64;
  Office office(false);office.load(argv[1]);
  const std::string mode=argv[2];
  constexpr float dt=1.F/60.F;
  if(mode=="replace") {
    office.setAgents({{"old","Old","idle","male",0}});
    bool rolled=false;
    for(float t=0;t<30;t+=dt) {
      office.advance(dt);
      const auto room=office.snapshot(1.6F)->instances.front();
      if(!room.nodeTranslations.empty()&&length(room.nodeTranslations.front().delta)>.2F){rolled=true;break;}
    }
    if(!rolled){std::cerr<<"Did not reach rolling phase\n";return 3;}
    office.setAgents({});
    office.setAgents({{"new","New","working","male",0}});
    office.advance(.1F);
    const auto actor=office.debugMotion().front();
    const auto room=office.snapshot(1.6F)->instances.front();
    std::cout<<"replacement phase="<<actor.phase<<" socket="<<actor.socket<<" body="<<actor.position.x<<','<<actor.position.z
             <<" movedChairs="<<room.nodeTranslations.size();
    if(!room.nodeTranslations.empty())std::cout<<" chairDisplacement="<<length(room.nodeTranslations.front().delta);
    std::cout<<'\n';
    return actor.phase=="desk"&&!room.nodeTranslations.empty()?2:0;
  }
  if(mode=="enter") {
    std::vector<Agent> actors{{"a","A","idle","male",1}};
    office.setAgents(actors);
    bool interrupted=false;float maxSpeed=0;
    for(float t=0;t<150;t+=dt) {
      const auto before=office.debugMotion().front();
      if(!interrupted&&before.phase=="enter") {
        interrupted=true; actors.front().status="working";office.setAgents(actors);
        std::cout<<"Interrupted enter at="<<before.position.x<<','<<before.position.z<<'\n';
      }
      office.advance(dt);
      const auto after=office.debugMotion().front();
      if(interrupted) {
        const float speed=length(after.position-before.position)/dt;
        maxSpeed=std::max(maxSpeed,speed);
        if(speed>2)std::cout<<"excess speed="<<speed<<" phase="<<after.phase<<" socket="<<after.socket<<'\n';
        if(after.phase=="desk")break;
      }
    }
    const auto final=office.debugMotion().front();
    std::cout<<"enterInterruption="<<interrupted<<" maxSpeed="<<maxSpeed<<" finalPhase="<<final.phase<<" socket="<<final.socket<<'\n';
    return !interrupted?3:(maxSpeed>2||final.phase!="desk"||final.socket!="desk_1")?2:0;
  }
  if(mode=="chairs") {
    const auto navigation=Navigation::load(std::filesystem::path(argv[1])/"office.mokaidnav");
    const auto scene=loadScene(std::filesystem::path(argv[1])/"office.mokaidasset");
    Instance room{scene,trs({}, {0,1,0,0}),"",0,{}};
    const auto initial=evaluateInstancePose(room);
    for(const auto &socket:navigation.sockets()) {
      if(socket.chairNode<0)continue;
      room.nodeTranslations={{static_cast<std::uint32_t>(socket.chairNode),socket.chairLocalDelta}};
      const auto posed=evaluateInstancePose(room);
      const auto before=transform(room.transform*initial.world[socket.chairNode],{0,0,0,1});
      const auto after=transform(room.transform*posed.world[socket.chairNode],{0,0,0,1});
      const Vec3 delta{after.x-before.x,after.y-before.y,after.z-before.z};
      const auto expected=avatarForward(socket.yaw)*-socket.pullback;
      const auto error=length(delta-expected);
      std::cout<<socket.id<<" nativeDeltaError="<<error<<'\n';
      if(error>.0001F)return 2;
    }
    return 0;
  }
  return 64;
}
