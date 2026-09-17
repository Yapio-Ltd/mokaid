#include <mokaid/engine/traffic.hpp>
#include <chrono>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace mokaid::engine;
namespace {
void expect(bool condition, const char *message) { if (!condition) throw std::runtime_error(message); }
float separation(Vec3 a, Vec3 b, Vec3 nextA, Vec3 nextB) {
  const auto relative = a - b, movement = (nextA - a) - (nextB - b);
  const float t = std::clamp(-dot(relative, movement) / std::max(1e-9F, dot(movement, movement)), 0.F, 1.F);
  return length(relative + movement * t);
}
struct Result { std::vector<TrafficState> actors; float seconds; };
Result simulate(const Navigation &nav, const std::vector<Vec3> &starts,
                const std::vector<Vec3> &goals, float deadline, bool reverseInsertion = false) {
  Traffic traffic(nav);
  for (std::size_t n=0;n<starts.size();++n) {
    const auto i=reverseInsertion?starts.size()-1-n:n;
    traffic.add(std::to_string(i),starts[i],avatarYaw((goals[i]-starts[i])*-1));
    constexpr float profiles[]{.62F,1.05F,.78F,.90F};
    traffic.setSpeed(std::to_string(i),profiles[i%4]);
  }
  for(std::size_t i=0;i<starts.size();++i) traffic.request(std::to_string(i),goals[i]);
  float seconds=0;
  for(;seconds<deadline;seconds+=1.F/60.F) {
    const auto before=traffic.snapshot(); traffic.step(1.F/60.F); const auto after=traffic.snapshot();
    for(std::size_t i=0;i<after.size();++i) {
      const auto delta=after[i].position-before[i].position;
      expect(length(delta)<=Traffic::maxSpeed/60.F+.0001F,"No teleport or excessive speed");
      expect(after[i].currentSpeed>=0&&after[i].currentSpeed<=Traffic::maxSpeed+.0001F,"Walking speed stays within its safe bound");
      if(!after[i].active) expect(after[i].currentSpeed==0,"Waiting and arrived actors have no retained walking speed");
      expect(nav.segmentWalkable(before[i].position,after[i].position,Traffic::radius),"Every swept step clears static geometry");
      if(length(delta)>1e-5F) expect(dot(normalized(delta),avatarForward(after[i].yaw))>.94F,"Translation only after facing the actual reflected model forward");
      for(std::size_t j=0;j<i;++j)
        expect(separation(before[i].position,before[j].position,after[i].position,after[j].position)>=2*Traffic::radius-.0001F,"Swept actor discs never intersect");
    }
    if(std::all_of(after.begin(),after.end(),[](const auto &s){return s.completions>0&&!s.pending&&!s.active;})) {
      for(const auto &s:after) expect(length(s.position-goals[static_cast<std::size_t>(std::stoi(s.id))])<.002F,"Yielding actors resume and actually reach their original destination");
      return {after,seconds};
    }
  }
  for(const auto &s:traffic.snapshot()) std::cerr<<s.id<<" pos="<<s.position.x<<','<<s.position.z<<" pending="<<s.pending<<" active="<<s.active<<" done="<<s.completions<<" yields="<<s.yields<<'\n';
  throw std::runtime_error("All traffic requests must make bounded progress");
}
void speedTests(const Navigation &open) {
  constexpr float dt=.01F;
  Traffic straight(open);
  straight.add("walker",{-3,0,0},avatarYaw({1,0,0}));
  straight.setSpeed("walker",1.05F);
  straight.request("walker",{3,0,0});
  bool cruising=false,braking=false,arrived=false;
  float lastStep=0;
  for(int frame=0;frame<1000;++frame) {
    const auto before=straight.state("walker");
    straight.step(dt);
    const auto after=straight.state("walker");
    const float movement=length(after.position-before.position);
    expect(after.currentSpeed-before.currentSpeed<=Traffic::acceleration*dt+.0001F,"Walking accelerates within its physical limit");
    expect(before.currentSpeed-after.currentSpeed<=Traffic::braking*dt+.0001F,"Destination braking stays smooth through the final frame");
    expect(movement<=Traffic::maxSpeed*dt+.0001F,"Final approach never jumps to the destination");
    if(frame==0) expect(after.currentSpeed>0&&after.currentSpeed<.02F,"Walking starts with a small acceleration step");
    if(after.currentSpeed>1.049F) cruising=true;
    if(after.currentSpeed<before.currentSpeed-.0001F) braking=true;
    if(!braking) expect(after.currentSpeed+.0001F>=before.currentSpeed,"Initial acceleration is monotonic");
    else expect(after.currentSpeed<=before.currentSpeed+.0001F,"Final approach decelerates monotonically");
    if(movement>1e-6F) lastStep=movement;
    if(after.arrived) {
      arrived=true;
      expect(length(after.position-Vec3{3,0,0})<1e-5F,"Braking preserves the exact destination");
      expect(after.currentSpeed==0&&lastStep<.001F,"Arrival has zero speed and a submillimetre final step");
      break;
    }
  }
  expect(cruising&&braking&&arrived,"Walking reaches cruise, brakes in advance, and finishes within ten seconds");

  Traffic changing(open);
  changing.add("walker",{-5,0,0},avatarYaw({1,0,0}));
  changing.setSpeed("walker",9.F);
  changing.request("walker",{5,0,0});
  changing.step(1);
  expect(std::abs(changing.state("walker").currentSpeed-Traffic::maxSpeed)<.0001F,"Excessive speed targets are clamped");
  changing.setSpeed("walker",.50F);
  float previous=changing.state("walker").currentSpeed;
  for(int frame=0;frame<40;++frame) {
    changing.step(dt);
    const auto &s=changing.state("walker");
    expect(s.currentSpeed<=previous+.0001F&&previous-s.currentSpeed<=Traffic::braking*dt+.0001F,"A lower requested speed decelerates instead of snapping");
    previous=s.currentSpeed;
  }
  expect(std::abs(previous-.50F)<.0001F,"A changed profile settles at its requested speed");
  changing.setSpeed("walker",0);
  for(int frame=0;frame<30;++frame) {
    changing.step(dt);
    const auto &s=changing.state("walker");
    expect(previous-s.currentSpeed<=Traffic::braking*dt+.0001F,"A zero target brakes smoothly");
    previous=s.currentSpeed;
  }
  const auto stopped=changing.state("walker");
  changing.step(.20F);
  expect(stopped.currentSpeed==0&&length(changing.state("walker").position-stopped.position)<1e-6F,"A zero target holds position without consuming the route");
  changing.setSpeed("walker",.62F);
  changing.step(dt);
  expect(changing.state("walker").currentSpeed>0&&changing.state("walker").currentSpeed<=Traffic::acceleration*dt+.0001F,"Walking resumes with a new acceleration ramp");
  for(const float invalid : {-1.F,std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()}) {
    bool rejected=false;
    try { changing.setSpeed("walker",invalid); } catch(const std::invalid_argument&) { rejected=true; }
    expect(rejected,"Speed targets reject negative and nonfinite values");
  }

  Traffic corner(open);
  corner.add("walker",{0,0,0},avatarYaw({1,0,0}));
  corner.setSpeed("walker",1.05F);
  corner.requestSocket("walker",{{0,0,0},{2,0,0},{2,0,2}});
  bool slowsBeforeCorner=false,turnsAtRest=false,secondLeg=false;
  for(int frame=0;frame<1000;++frame) {
    const auto before=corner.state("walker");
    corner.step(dt);
    const auto after=corner.state("walker");
    const float movement=length(after.position-before.position);
    expect(movement<=Traffic::maxSpeed*dt+.0001F,"Turning at a corner cannot introduce a translation jump");
    if(before.position.x>1.7F&&before.position.x<1.99F&&after.currentSpeed<before.currentSpeed-.0001F) slowsBeforeCorner=true;
    if(movement<1e-6F&&std::abs(after.yaw-before.yaw)>.001F) {
      turnsAtRest=true;
      expect(after.currentSpeed==0,"Rotation in place reports zero walking speed");
    }
    if(movement>1e-5F) expect(dot(normalized(after.position-before.position),avatarForward(after.yaw))>=std::cos(.32F)-.0001F,"No translation outside the facing tolerance");
    if(after.position.z>.01F) secondLeg=true;
    if(after.arrived) break;
  }
  expect(slowsBeforeCorner&&turnsAtRest&&secondLeg&&corner.state("walker").arrived,"A sharp corner is approached slowly, turned at rest, and completed");

  Traffic gentleSocket(open);
  const Vec3 preciseCorner{.373F,0,0};
  gentleSocket.add("walker",{0,0,0},avatarYaw({1,0,0}));
  gentleSocket.requestSocket("walker",{{0,0,0},preciseCorner,{1.2F,0,.1F}});
  bool visitedCorner=false;
  for(int frame=0;frame<300;++frame) {
    gentleSocket.step(.017F);
    visitedCorner|=length(gentleSocket.state("walker").position-preciseCorner)<1e-6F;
    if(gentleSocket.state("walker").arrived)break;
  }
  expect(visitedCorner&&gentleSocket.state("walker").arrived,"Even a gentle caller-verified socket corner must be visited exactly, without an unverified shortcut chord");

  Traffic timed(open);
  const float facing=avatarYaw({1,0,0});
  timed.add("seated",{0,0,0},facing);
  timed.setSpeed("seated",.10F);
  timed.requestSocket("seated",{{0,0,0},{1,0,0}},2.F,facing);
  for(int frame=1;frame<=200;++frame) {
    timed.step(dt);
    const float u=std::min(1.F,static_cast<float>(frame)*dt/2.F);
    expect(std::abs(timed.state("seated").position.x-u*u*(3-2*u))<.00001F,"Per-actor walking speeds do not alter authored socket smoothstep timing");
  }
  timed.step(dt);
  expect(timed.state("seated").arrived&&timed.state("seated").currentSpeed==0,"Timed pose completion reports no remaining translation speed");
}
void continuousCornerTests() {
  const auto slalom=Navigation::fromGeometry({{-3.2F,-2.4F,-6.F,1.2F},
      {-.4F,.4F,-1.2F,6.F},{2.4F,3.2F,-6.F,1.2F}});
  const Vec3 start{-5,0,-4},goal{5,0,4};
  const auto route=slalom.route(start,goal,{},Traffic::radius);
  expect(route.size()>5,"Slalom exercises several actual navigation corners");
  Traffic traffic(slalom);traffic.add("walker",start,avatarYaw(route[1]-start));
  traffic.request("walker",goal);
  constexpr float dt=1.F/60.F;int stops=0;float minForward=1,maxDistanceError=0;
  bool arrived=false;
  for(int frame=0;frame<2400;++frame) {
    const auto before=traffic.state("walker");traffic.step(dt);const auto after=traffic.state("walker");
    const auto delta=after.position-before.position;const float movement=length(delta);
    expect(slalom.segmentWalkable(before.position,after.position,Traffic::radius),"Rounded multi-point steps cannot clip the inside of an obstacle");
    expect(after.currentSpeed-before.currentSpeed<=Traffic::acceleration*dt+.0001F,"Curve entry preserves bounded acceleration");
    expect(before.currentSpeed-after.currentSpeed<=Traffic::braking*dt+.0001F,"Curvature is anticipated early enough for smooth braking");
    expect(std::abs(std::remainder(after.yaw-before.yaw,6.283185307F))<=Traffic::turnSpeed*dt+.0001F,"Interpolated tangent never snaps the actor's rotation");
    if(after.distance>.4F&&length(after.position-goal)>.4F&&movement<1e-6F)++stops;
    if(movement>1e-6F)minForward=std::min(minForward,dot(normalized(delta),avatarForward(after.yaw)));
    const float expectedDistance=(before.currentSpeed+after.currentSpeed)*.5F*dt;
    maxDistanceError=std::max(maxDistanceError,std::abs(movement-expectedDistance));
    if(after.arrived){arrived=true;break;}
  }
  expect(arrived&&stops==0,"An unobstructed slalom has continuous turns without stop-turn-go at waypoints");
  expect(minForward>.97F,"Facing follows the curved trajectory throughout movement");
  expect(maxDistanceError<.0001F,"Distance remaining after a curve sample is carried into the following segment");
  simulate(slalom,{start,goal},{goal,start},120);
  std::cout<<"Continuous corners PASS: internal stopped frames="<<stops<<", minimum forward dot="<<minForward<<", maximum distance-budget error="<<maxDistanceError<<" m\n";
}
void tests() {
  const auto open=Navigation::fromGeometry({});
  speedTests(open);
  continuousCornerTests();
  // The two goals are initially occupied. One actor must really step aside,
  // preserve its destination, and resume after the colleague has passed.
  const auto headOn=simulate(open,{{-2,0,0},{2,0,0}},{{2,0,0},{-2,0,0}},35);
  expect(headOn.actors[0].yields+headOn.actors[1].yields>0,"Head-on swap uses a physical pull-aside");
  const auto crossing=simulate(open,{{-3,0,0},{0,0,-3},{3,0,0},{0,0,3}},{{3,0,0},{0,0,3},{-3,0,0},{0,0,-3}},75);
  expect(crossing.seconds<75,"Intersection drains fairly");
  std::vector<Vec3> starts,goals;
  for(int i=0;i<9;++i) { const float angle=i*6.283185307F/9; starts.push_back({std::cos(angle)*4,0,std::sin(angle)*4}); }
  for(int i=0;i<9;++i) goals.push_back(starts[(i+4)%9]);
  const auto crowd=simulate(open,starts,goals,180);
  const auto reordered=simulate(open,starts,goals,180,true);
  expect(std::abs(crowd.seconds-reordered.seconds)<.001F,"Simulation independent of container insertion order");
  for(std::size_t i=0;i<crowd.actors.size();++i)
    expect(length(crowd.actors[i].position-reordered.actors[i].position)<.001F,"Deterministic final actor positions");
  // An actual pinch point: approaching from both sides must not tunnel through
  // the partition while looking for a pull-aside.
  const auto doorway=Navigation::fromGeometry({{-.25F,.25F,-6, -.65F},{-.25F,.25F,.65F,6}});
  simulate(doorway,{{-3,0,0},{3,0,0}},{{3,0,0},{-3,0,0}},60);
  Traffic strict(open); strict.add("actor",{0,0,0},0);
  bool rejected=false;
  try { strict.requestSocket("actor",{{0,0,0},{1,0,1},{2,0,0}},1,0); } catch(const std::invalid_argument&) { rejected=true; }
  expect(rejected,"Timed socket motions cannot cut a polyline corner");
  rejected=false;
  try { strict.requestSocket("actor",{{1,0,0},{2,0,0}}); } catch(const std::invalid_argument&) { rejected=true; }
  expect(rejected,"Stale socket paths never relocate their starting point");
  Traffic furniture(open);
  furniture.add("owner",{-1,0,0},avatarYaw({1,0,0}));
  furniture.setFurniture({{"owner",{0,0,0},.4F}});
  furniture.requestSocket("owner",{{-1,0,0},{1,0,0}});
  furniture.step(1);
  expect(furniture.state("owner").pending&&furniture.state("owner").position.x==-1,
         "A sofa corridor cannot ignore the actor's desk chair by ownership alone");
  furniture.requestSocket("owner",{{-1,0,0},{1,0,0}},0,0,true);
  furniture.step(4);
  expect(furniture.state("owner").arrived&&furniture.state("owner").position.x>.999F,
         "An explicitly verified desk corridor can overlap its own moved chair");
  furniture.requestSocket("owner",{{1,0,0},{-1,0,0}});
  furniture.step(1);
  expect(furniture.state("owner").pending,
         "Desk chair ownership never leaks into the next generic socket motion");
  furniture.setFurniture({{"colleague",{0,0,0},.4F}});
  furniture.requestSocket("owner",{{1,0,0},{-1,0,0}},0,0,true);
  furniture.step(1);
  expect(furniture.state("owner").pending,
         "An owned desk corridor still respects every colleague's furniture");
  furniture.clear();
  furniture.add("owner",{-2,0,0},avatarYaw({1,0,0}));
  furniture.requestSocket("owner",{{-2,0,0},{2,0,0}});
  furniture.step(.1F);
  expect(furniture.state("owner").active,"The unobstructed socket route is already reserved");
  furniture.setFurniture({{"owner",{0,0,0},.4F}});
  furniture.step(5);
  expect(furniture.state("owner").position.x<=-.7499F&&furniture.state("owner").currentSpeed==0,
         "A newly occupied own-chair disc also blocks the swept guard of a generic socket route");
  std::cout<<"Traffic PASS: head-on "<<headOn.seconds<<" s, crossing "<<crossing.seconds<<" s, nine actors "<<crowd.seconds<<" s\n";
}
}
int main() { try {const auto start=std::chrono::steady_clock::now();tests();std::cout<<"CPU elapsed "<<std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()<<" s\n";return 0;} catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 1;} }
