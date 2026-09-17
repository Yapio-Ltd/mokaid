#include "agent_indicator_model.hpp"
#include <QCoreApplication>
#include <QPersistentModelIndex>
#include <QRectF>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string_view>

using namespace mokaid;
namespace {
void expect(bool condition,const char *message){if(!condition)throw std::runtime_error(message);}
QRectF rectangle(AgentIndicatorModel &model,int row) {
  const auto i=model.index(row);
  return {model.data(i,AgentIndicatorModel::LabelX).toDouble(),model.data(i,AgentIndicatorModel::LabelY).toDouble(),
          model.data(i,AgentIndicatorModel::LabelWidth).toDouble(),model.data(i,AgentIndicatorModel::LabelHeight).toDouble()};
}
void readable(AgentIndicatorModel &model,QSizeF size) {
  for(int i=0;i<model.rowCount();++i){
    const auto box=rectangle(model,i);
    expect(model.data(model.index(i),AgentIndicatorModel::OnScreen).toBool(),"All nine projected actors retain visible labels");
    expect(box.height()==34&&box.width()>=96&&box.width()<=136,"Mini labels respect their compact height and width contract");
    expect(QRectF(QPointF(),size).contains(box),"Labels stay within the viewport");
    for(int j=0;j<i;++j)expect(!box.intersects(rectangle(model,j)),"Clustered labels remain readable without overlap");
  }
}
void denseMotion(engine::Frame frame,float seconds) {
  for(const auto size:{QSizeF(1063,491),QSizeF(653,491)}) {
    AgentIndicatorModel model;
    for(int step=0;step<static_cast<int>(seconds*30);++step) {
      const float time=static_cast<float>(step)/30;
      for(auto &a:frame.actorIndicators) {
        const float i=std::stof(a.id.substr(3));
        a.headWorld={.8F*std::sin(time*.06F)+.03F*std::sin(time+i),
                     .83F*std::cos(time*.05F)+.025F*std::sin(time*.7F+i),0};
      }
      if(step%3==0)std::reverse(frame.actorIndicators.begin(),frame.actorIndicators.end());
      model.sync(frame,size);readable(model,size);
      for(int i=0;i<9;++i)expect(model.data(model.index(i),AgentIndicatorModel::AgentId)==QString("id_%1").arg(i),
                                "Dense moving labels preserve layout priority independently of frame order");
    }
  }
}
}
int main(int argc,char **argv) {
  QCoreApplication app(argc,argv);
  try {
    AgentIndicatorModel model;
    engine::Frame frame;
    for(int i=0;i<9;++i)frame.actorIndicators.push_back({"id_"+std::to_string(i),"Agent "+std::to_string(i),"working",i+1,
      {-.18F+.06F*(i%3),-.05F+.035F*(i/3),0},0});
    int resets=0;
    QObject::connect(&model,&QAbstractItemModel::modelReset,[&]{++resets;});
    for(const auto size:{QSizeF(1063,491),QSizeF(653,491)}) {
      model.sync(frame,size);
      expect(model.rowCount()==9,"Every agent has a persistent label");
      readable(model,size);
    }
    // The camera can project a whole seated group close to any viewport edge.
    // Above-only candidates used to collapse onto the same top-edge row.
    for(const auto size:{QSizeF(1063,491),QSizeF(653,491)}) {
      for(const float x:{-.9F,0.F,.9F})for(const float y:{-.9F,0.F,.92F}) {
        auto clustered=frame;
        for(auto &actor:clustered.actorIndicators)actor.headWorld={x,y,0};
        model.sync(clustered,size);
        readable(model,size);
      }
    }
    const QPersistentModelIndex first(model.index(0));
    frame.actorIndicators.front().headWorld.x+=.1F;
    frame.actorIndicators.front().activity="preparing_coffee";
    frame.actorIndicators.front().level=7;
    model.sync(frame,{1063,491});
    expect(first.isValid()&&model.data(first,AgentIndicatorModel::AgentId)=="id_0","Moving actors keep their delegate identity");
    expect(model.data(first,AgentIndicatorModel::ActivityText)=="Coffee"&&model.data(first,AgentIndicatorModel::ActivityDetail)=="Preparing coffee"&&model.data(first,AgentIndicatorModel::AgentLevel)==7,"Compact activity preserves its full accessible detail and true level");
    QVector<QRectF> positions;for(int i=0;i<9;++i)positions.push_back(rectangle(model,i));
    std::reverse(frame.actorIndicators.begin(),frame.actorIndicators.end());
    model.sync(frame,{1063,491});
    expect(model.data(first,AgentIndicatorModel::AgentId)=="id_0"&&resets==0,"Refresh order does not reset labels or keyboard focus");
    for(int i=0;i<9;++i)expect(rectangle(model,i)==positions[i],"Reversing the frame order never reassigns label positions");
    auto same=frame;std::reverse(same.actorIndicators.begin(),same.actorIndicators.end());
    AgentIndicatorModel fresh,reordered;
    fresh.sync(same,{653,491});reordered.sync(frame,{653,491});
    for(int i=0;i<9;++i)expect(rectangle(fresh,i)==rectangle(reordered,i),"First placement is deterministic by actor ID");

    AgentIndicatorModel quiet;
    auto tiny=frame;for(auto &actor:tiny.actorIndicators)actor.headWorld={0,0,0};
    quiet.sync(tiny,{653,491});positions.clear();
    bool hasTether=false;
    for(int i=0;i<9;++i){positions.push_back(rectangle(quiet,i));hasTether|=quiet.data(quiet.index(i),AgentIndicatorModel::TetherVisible).toBool();}
    expect(hasTether,"Displaced crowded labels expose an ownership tether");
    for(int step=0;step<90;++step) {
      for(auto &actor:tiny.actorIndicators)actor.headWorld.x=.0008F*std::sin(static_cast<float>(step));
      quiet.sync(tiny,{653,491});readable(quiet,{653,491});
      for(int i=0;i<9;++i)expect((rectangle(quiet,i).topLeft()-positions[i].topLeft()).manhattanLength()<.001,
                                "Subpixel head motion does not make compact labels bounce");
    }
    AgentIndicatorModel single;
    auto isolated=frame;isolated.actorIndicators.resize(1);isolated.actorIndicators.front().headWorld={0,0,0};isolated.actorIndicators.front().name="Ada";
    single.sync(isolated,{653,491});
    expect(!single.data(single.index(0),AgentIndicatorModel::TetherVisible).toBool(),"An ordinary label directly above its head has no decorative tether");
    expect(rectangle(single,0).width()==96,"A short name uses the compact minimum width");
    isolated.actorIndicators.front().name="Alexandria Very Long Family Name";single.sync(isolated,{653,491});
    expect(rectangle(single,0).width()==136,"A long name uses the bounded maximum width before QML elision");
    expect(AgentIndicatorModel::activityText("waiting")=="Yielding"&&AgentIndicatorModel::activityText("talking_sofa_coffee_left")=="Chatting"&&AgentIndicatorModel::activityText("walking_coffee")=="Walking", "Activity summaries are concise and specific");
    const auto roles=model.roleNames();expect(roles.value(AgentIndicatorModel::LabelHeight)=="labelHeight"&&roles.value(AgentIndicatorModel::ActivityDetail)=="activityDetail"&&roles.value(AgentIndicatorModel::TetherVisible)=="tetherVisible","QML receives the complete mini-label role contract");

    const bool stress=argc>1&&std::string_view(argv[1])=="--stress";
    const auto began=std::chrono::steady_clock::now();denseMotion(frame,stress?120.F:3.F);
    std::cout<<"Dense projection "<<(stress?120:3)<<" seconds per viewport: "<<std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count()<<" s CPU\n";
    frame.actorIndicators.erase(std::remove_if(frame.actorIndicators.begin(),frame.actorIndicators.end(),[](const auto &a){return a.id=="id_0";}),frame.actorIndicators.end());
    model.sync(frame,{1063,491});
    expect(!first.isValid()&&model.rowCount()==8,"A removed agent leaves no stale label");
    frame.actorIndicators.front().headWorld.x=std::numeric_limits<float>::quiet_NaN();
    model.sync(frame,{1063,491});
    for(int i=0;i<model.rowCount();++i)if(model.data(model.index(i),AgentIndicatorModel::AgentId).toString()==QString::fromStdString(frame.actorIndicators.front().id))
      expect(!model.data(model.index(i),AgentIndicatorModel::OnScreen).toBool(),"Invalid projection is hidden rather than sent to QML geometry");
    const QPersistentModelIndex remaining(model.index(0));model.sync(frame,{70,35});
    expect(remaining.isValid(),"A temporarily unusable viewport does not destroy label identity");
    for(int i=0;i<model.rowCount();++i)expect(!model.data(model.index(i),AgentIndicatorModel::OnScreen).toBool(),"Unfit labels are hidden without overflowing a tiny viewport");
    model.clear();expect(model.rowCount()==0,"Clearing the workspace clears all labels");
    std::cout<<"Agent labels: projection, crowding, stable identity and live activity PASS\n";
    return 0;
  }catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 1;}
}
