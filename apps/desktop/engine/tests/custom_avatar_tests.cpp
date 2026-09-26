#include <mokaid/engine/office.hpp>
#include <iostream>
int main(int argc,char **argv) {
  using namespace mokaid::engine;
  if(argc!=3) return 2;
  try {
    const auto scene=loadScene(argv[2]);
    if(scene->meshes.empty()||!std::isfinite(scene->referenceHeight)||scene->referenceHeight<=0) return 3;
    if(resolveAnimation(*scene,"walking")!="walking"||resolveAnimation(*scene,"idle")!="idle") return 4;
    Office office(false);office.load(argv[1]);
    office.setAgents({{"generated-agent","Custom","idle","custom:test",0,1}});
    office.setCustomAvatar("custom:test",scene);office.advance(.2F);
    const auto frame=office.snapshot(1.5F);
    for(const auto &instance:frame->instances) if(instance.agentId=="generated-agent") {
      if(instance.scene!=scene) return 5;
      const auto [min,max]=poseBounds(*scene,evaluatePose(*scene,"idle",0));
      const auto height=(max.y-min.y)*1.75F/scene->referenceHeight;
      if(std::abs(height-1.75F)>.01F) return 6;
      std::cout<<"Custom character loaded in Office at "<<height<<" metres, "<<scene->meshes.size()<<" meshes\n";
      return 0;
    }
    return 7;
  } catch(const std::exception &e) {std::cerr<<e.what()<<'\n';return 1;}
}
