// Independent read-only audit of the production indicator model.
#include "agent_indicator_model.hpp"
#include <mokaid/engine/office.hpp>
#include <QCoreApplication>
#include <QRectF>
#include <iostream>
using namespace mokaid;
QRectF box(AgentIndicatorModel &m,int n) {
 const auto i=m.index(n);
 return {m.data(i,AgentIndicatorModel::LabelX).toDouble(),m.data(i,AgentIndicatorModel::LabelY).toDouble(),
         m.data(i,AgentIndicatorModel::LabelWidth).toDouble(),42};
}
int overlaps(AgentIndicatorModel &m) {
 int n=0;
 for(int i=0;i<m.rowCount();++i)if(m.data(m.index(i),AgentIndicatorModel::OnScreen).toBool())
  for(int j=0;j<i;++j)if(m.data(m.index(j),AgentIndicatorModel::OnScreen).toBool()&&box(m,i).intersects(box(m,j)))++n;
 return n;
}
int main(int argc,char **argv) {
 QCoreApplication app(argc,argv);
 for(auto size:{QSizeF(1063,491),QSizeF(653,491)}) {
  AgentIndicatorModel model;engine::Frame frame;
  for(int i=0;i<9;++i)frame.actorIndicators.push_back({"id_"+std::to_string(i),"Agent "+std::to_string(i),"working",1,
    {-.18F+.06F*(i%3),1.F-40.F/491.F,0},0});
  model.sync(frame,size);
  std::cout<<"edge width="<<size.width()<<" anchorY=20 overlapPairs="<<overlaps(model)<<" labelY=";
  for(int i=0;i<9;++i)std::cout<<box(model,i).y()<<',';
  std::cout<<'\n';
 }
 if(argc<2)return 0;
 engine::Office office(false);office.load(argv[1]);
 std::vector<engine::Agent> actors;
 for(int i=0;i<9;++i)actors.push_back({"id_"+std::to_string(i),"Agent "+std::to_string(i),"idle",i%2?"female":"male",i,1});
 office.setAgents(actors);
 AgentIndicatorModel wide,narrow;int hits[2]={},peak[2]={};float first[2]={-1,-1};
 for(int tick=0;tick<7200;++tick) {
  office.advance(1.F/60.F);if(tick%30)continue;
  int k=0;for(auto size:{QSizeF(1063,491),QSizeF(653,491)}) {
   auto &model=k?narrow:wide;model.sync(*office.snapshot(size.width()/size.height()),size);
   const int n=overlaps(model);hits[k]+=n>0;peak[k]=std::max(peak[k],n);
   if(n&&first[k]<0)first[k]=tick/60.F;++k;
  }
 }
 for(int k=0;k<2;++k)std::cout<<"runtime width="<<(k?653:1063)<<" sampledFrames=240 overlapFrames="<<hits[k]<<" peakOverlapPairs="<<peak[k]<<" firstTime="<<first[k]<<'\n';
}
