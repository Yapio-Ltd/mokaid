#include <mokaid/engine/office.hpp>
#include <fstream>
#include <iostream>

int main(int argc, char **argv) {
  using namespace mokaid::engine;
  if(argc!=2)return 2;
  Office office(false);office.load(argv[1]);
  std::vector<Agent> agents;
  const char *types[]={"male","corporate","developer","design","finance","research","legal","female","male"};
  for(int i=0;i<9;++i)agents.push_back({"agent_"+std::to_string(i),"Agent","idle",types[i],i});
  office.setAgents(agents);
  float maxX=0,maxY=0;unsigned outside=0,samples=0;
  for(int step=0;step<640;++step) {
    office.advance(.25F);
    const auto motion=office.debugMotion();
    for(const float aspect:{.75F,1.33F,2.16F,3.F}) {
      const auto frame=office.snapshot(aspect);
      for(const auto &marker:frame->actorIndicators) {
        for(const auto point:{marker.headWorld,
              Vec3{marker.headWorld.x,0,marker.headWorld.z}}) {
          const auto p=transform(frame->viewProjection,{point.x,point.y,point.z,1});
          const float x=std::abs(p.x/p.w),y=std::abs(p.y/p.w);
          maxX=std::max(maxX,x);maxY=std::max(maxY,y);++samples;
          if(p.w<=0||x>=.985F||y>=.985F)++outside;
        }
      }
    }
  }
  std::cout<<"{\"simulationSeconds\":160,\"actors\":9,\"aspects\":[0.75,1.33,2.16,3],"
           <<"\"projectedHeadAndGroundSamples\":"<<samples<<",\"outOfView\":"<<outside
           <<",\"maxAbsNdcX\":"<<maxX<<",\"maxAbsNdcY\":"<<maxY<<"}\n";
  return outside?1:0;
}
