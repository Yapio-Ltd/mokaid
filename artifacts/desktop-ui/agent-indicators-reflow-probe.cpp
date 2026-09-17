#include "agent_indicator_model.hpp"
#include <QGuiApplication>
#include <QQuickView>
#include <QQuickItem>
#include <QQmlContext>
#include <QTest>
#include <QDebug>
#include <QImage>
#include <QElapsedTimer>
#include <algorithm>
#include <cmath>

QList<QQuickItem*> badges(QQuickItem*root){
    QList<QQuickItem*> pending{root},out;
    for(int i=0;i<pending.size();++i){
        const auto item=pending[i];pending.append(item->childItems());
        if(item->parentItem()&&item->parentItem()->property("agentId").isValid()&&item->property("hoverEnabled").isValid())out.append(item);
    }
    return out;
}
int main(int argc,char**argv){
    QGuiApplication app(argc,argv);QQuickView view;mokaid::AgentIndicatorModel model;mokaid::engine::Frame frame;
    for(int i=0;i<9;++i)frame.actorIndicators.push_back({"id_"+std::to_string(i),"Agent "+std::to_string(i),"working",i+1,{0,0,0},0});
    auto update=[&](int step){
        const float time=float(step)/30;
        for(auto&a:frame.actorIndicators){float i=std::stof(a.id.substr(3));a.headWorld={.8F*std::sin(time*.06F)+.03F*std::sin(time+i),.83F*std::cos(time*.05F)+.025F*std::sin(time*.7F+i),0};}
        if(step%3==0)std::reverse(frame.actorIndicators.begin(),frame.actorIndicators.end());
        model.sync(frame,{700,600});
    };
    update(0);view.rootContext()->setContextProperty("indicatorModel",&model);
    view.setSource(QUrl::fromLocalFile("/private/tmp/mokaid-indicator-reflow/Reflow.qml"));
    if(view.status()==QQuickView::Error)return 2;
    view.show();QTest::qWait(120);const auto items=badges(view.rootObject());if(items.size()!=9)return 3;
    int samples=0,collisions=0,targetCollisions=0;QElapsedTimer timer;timer.start();int step=0;
    while(timer.elapsed()<2000){
        if(timer.elapsed()*30/1000>step){update(++step);
            for(int i=0;i<9;++i)for(int j=0;j<i;++j){
                auto rect=[&](int r){auto index=model.index(r);return QRectF(model.data(index,mokaid::AgentIndicatorModel::LabelX).toReal(),model.data(index,mokaid::AgentIndicatorModel::LabelY).toReal(),model.data(index,mokaid::AgentIndicatorModel::LabelWidth).toReal(),34);};
                if(rect(i).intersects(rect(j)))++targetCollisions;
            }
        }
        QTest::qWait(4);++samples;bool overlap=false;
        for(int i=0;i<9;++i)for(int j=0;j<i;++j)overlap|=items[i]->mapRectToScene(items[i]->boundingRect()).intersects(items[j]->mapRectToScene(items[j]->boundingRect()));
        if(overlap){if(!collisions)view.grabWindow().save("/Users/olimservice/mokaid/artifacts/desktop-ui/agent-indicators-reflow-before.png");++collisions;}
    }
    qInfo()<<"Dense QML rendered-position samples"<<samples<<"overlap samples"<<collisions<<"model target overlaps"<<targetCollisions;
    if(!collisions)view.grabWindow().save("/Users/olimservice/mokaid/artifacts/desktop-ui/agent-indicators-reflow-after.png");
    return collisions||targetCollisions?1:0;
}
