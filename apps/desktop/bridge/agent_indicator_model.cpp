#include "agent_indicator_model.hpp"
#include <QRectF>
#include <algorithm>
#include <cmath>
#include <limits>

namespace mokaid {
namespace {
constexpr qreal labelHeight=34, gap=5, margin=3, headGap=7;
QString tone(std::string_view activity) {
  if(activity.find("coffee")!=activity.npos) return QStringLiteral("#e6be82");
  if(activity.find("phone")!=activity.npos) return QStringLiteral("#86cce9");
  if(activity.find("foosball")!=activity.npos) return QStringLiteral("#82d7b4");
  if(activity=="greeting"||activity=="laughing"||activity=="talking"||activity=="meeting"||activity=="social") return QStringLiteral("#c9afff");
  if(activity=="blocked") return QStringLiteral("#f5be86");
  return QStringLiteral("#b5b9cd");
}
qreal textWidth(QStringView text) {
  // QtCore-only estimate for the compact 11px name. QML elides against the
  // final available width; this intentionally budgets generously for glyphs.
  qreal width=0;
  for(const auto c:text) {
    if(c.isLowSurrogate())continue;
    if(c.isHighSurrogate()||c.unicode()>=0x2e80)width+=11;
    else if(c.isSpace())width+=3.5;
    else if(QStringView(u"ilI.,'!:|").contains(c))width+=3.5;
    else if(QStringView(u"MWmw@#%").contains(c))width+=9;
    else width+=6.5;
  }
  return width;
}
}
QString AgentIndicatorModel::activityText(std::string_view value) {
  if(value=="waiting"||value=="yielding")return tr("Yielding");
  if(value=="waiting_for_colleague")return tr("Waiting");
  if(value.starts_with("walking"))return tr("Walking");
  if(value.starts_with("talking")||value=="social")return tr("Chatting");
  if(value.starts_with("laughing"))return tr("Laughing");
  if(value.starts_with("stand_up"))return tr("Getting up");
  if(value.starts_with("sit_down"))return tr("Sitting");
  if(value.find("coffee")!=value.npos)return tr("Coffee");
  if(value.starts_with("phone"))return tr("On a call");
  if(value.starts_with("typing"))return tr("Typing");
  if(value=="working")return tr("Working");
  if(value=="thinking")return tr("Thinking");
  if(value=="playing_foosball")return tr("Foosball");
  if(value=="greeting")return tr("Greeting");
  if(value=="meeting")return tr("Meeting");
  if(value=="blocked")return tr("Attention");
  if(value=="requesting_approval")return tr("Approval");
  if(value=="reviewing")return tr("Reviewing");
  if(value=="learning")return tr("Learning");
  if(value=="offline")return tr("Offline");
  if(value=="away")return tr("Away");
  if(value=="chair_pullback")return tr("Leaving");
  if(value=="chair_pushin")return tr("Settling");
  if(value=="sitting")return tr("At desk");
  if(value.starts_with("sitting")||value=="resting")return tr("Relaxing");
  return tr("Idle");
}
QString AgentIndicatorModel::activityDetail(std::string_view value) {
  static const std::pair<std::string_view,const char*> labels[]={
    {"working","Working"},{"typing","Typing"},{"thinking","Thinking"},
    {"preparing_coffee","Preparing coffee"},{"carrying_coffee","Carrying coffee"},
    {"drinking_coffee","Enjoying coffee"},{"talking_coffee","Coffee & conversation"},
    {"walking_coffee","Walking with coffee"},{"sitting_coffee","Coffee break"},
    {"talking","Talking"},{"laughing","Laughing together"},{"greeting","Saying hello"},
    {"walking","On the move"},{"playing_foosball","Playing foosball"},
    {"meeting","Meeting"},{"phone_pickup","Picking up phone"},{"phone_call","On a call"},
    {"phone_putdown","Putting down phone"},{"phone","On a call"},
    {"resting","Taking a break"},{"waiting","Letting someone pass"},{"yielding","Letting someone pass"},
    {"waiting_for_colleague","Waiting for a colleague"},{"coffee_putdown","Putting down coffee"},
    {"offline","Offline"},{"blocked","Needs attention"},{"reviewing","Reviewing"},
    {"learning","Learning"},{"social","Catching up"},{"idle","Taking a moment"},
    {"sitting","At the desk"},{"sitting_sofa","On the sofa"},
    {"stand_up","Getting up"},{"sit_down","Taking a seat"},
    {"stand_up_sofa","Getting up"},{"sit_down_sofa","Taking a seat"},
    {"away","Away"},{"requesting_approval","Waiting for approval"},
    {"chair_pullback","Leaving the desk"},{"chair_pushin","Settling at the desk"}
  };
  for(const auto &[code,label]:labels) if(value==code)return tr(label);
  if(value.find("sofa_coffee")!=value.npos) {
    if(value.starts_with("talking"))return tr("Coffee & conversation");
    if(value.starts_with("laughing"))return tr("Laughing together");
    if(value.starts_with("drinking"))return tr("Enjoying coffee");
    if(value.starts_with("sit_down"))return tr("Taking a seat");
    if(value.starts_with("stand_up"))return tr("Getting up");
    return tr("Coffee on the sofa");
  }
  if(value.starts_with("typing"))return tr("Typing");
  if(value.starts_with("walking"))return tr("On the move");
  if(value.starts_with("laughing"))return tr("Laughing together");
  if(value.starts_with("talking"))return tr("Talking");
  if(value.starts_with("sitting"))return tr("Taking a break");
  return tr("Taking a moment");
}
int AgentIndicatorModel::rowCount(const QModelIndex &parent) const {return parent.isValid()?0:rows_.size();}
QVariant AgentIndicatorModel::data(const QModelIndex &index,int role) const {
  if(!index.isValid()||index.row()<0||index.row()>=rows_.size())return {};
  const auto &r=rows_[index.row()];
  switch(role) {
  case AgentId:return r.id;case AgentName:return r.name;case AgentLevel:return r.level;
  case ActivityText:return r.activity;case ActivityDetail:return r.detail;case ActivityTone:return r.tone;
  case LabelX:return r.label.x();case LabelY:return r.label.y();
  case AnchorX:return r.anchor.x();case AnchorY:return r.anchor.y();
  case LabelWidth:return r.width;case LabelHeight:return labelHeight;
  case OnScreen:return r.visible;case TetherVisible:return r.tether;default:return {};
  }
}
QHash<int,QByteArray> AgentIndicatorModel::roleNames() const {
  return {{AgentId,"agentId"},{AgentName,"agentName"},{AgentLevel,"agentLevel"},
          {ActivityText,"activityText"},{ActivityTone,"activityTone"},{LabelX,"labelX"},
          {LabelY,"labelY"},{AnchorX,"anchorX"},{AnchorY,"anchorY"},
          {LabelWidth,"labelWidth"},{LabelHeight,"labelHeight"},{OnScreen,"onScreen"},
          {ActivityDetail,"activityDetail"},{TetherVisible,"tetherVisible"}};
}
void AgentIndicatorModel::clear() {viewport_={};if(rows_.isEmpty())return;beginResetModel();rows_.clear();endResetModel();}
void AgentIndicatorModel::sync(const engine::Frame &frame,QSizeF viewport) {
  const bool usable=std::isfinite(viewport.width())&&std::isfinite(viewport.height())&&
    viewport.width()>=96+2*margin&&viewport.height()>=labelHeight+2*margin;
  const bool sameViewport=viewport==viewport_;
  QVector<Row> next;
  next.reserve(frame.actorIndicators.size());
  for(const auto &actor:frame.actorIndicators) {
    const auto p=engine::transform(frame.viewProjection,{actor.headWorld.x,actor.headWorld.y,actor.headWorld.z,1});
    Row row;row.id=QString::fromStdString(actor.id);row.name=QString::fromStdString(actor.name);
    if(row.id.isEmpty()||std::any_of(next.begin(),next.end(),[&](const auto &r){return r.id==row.id;}))continue;
    row.level=actor.level;row.activity=activityText(actor.activity);row.detail=activityDetail(actor.activity);row.tone=tone(actor.activity);
    row.width=std::clamp(std::ceil((textWidth(row.name)+textWidth(QString::number(row.level))+36)/2)*2,96.,136.);
    row.visible=usable&&row.width+2*margin<=viewport.width()&&std::isfinite(p.w)&&p.w>0;
    if(row.visible){
      row.anchor={(p.x/p.w*.5+.5)*viewport.width(),(.5-p.y/p.w*.5)*viewport.height()};
      row.visible=std::isfinite(row.anchor.x())&&std::isfinite(row.anchor.y())&&QRectF(-20,-40,viewport.width()+40,viewport.height()+80).contains(row.anchor);
    }
    if(!row.visible)row.anchor={};
    next.push_back(std::move(row));
  }
  // The incumbent row order is layout priority. Network/frame order never
  // changes it, and simultaneous new actors join deterministically by ID.
  const auto rank=[&](const QString &id){
    const auto found=std::find_if(rows_.begin(),rows_.end(),[&](const auto &r){return r.id==id;});
    return std::distance(rows_.begin(),found);
  };
  std::sort(next.begin(),next.end(),[&](const auto &a,const auto &b){
    const auto x=rank(a.id),y=rank(b.id);return x!=y?x<y:a.id<b.id;
  });
  const bool unchangedGeometry=sameViewport&&next.size()==rows_.size()&&std::all_of(next.begin(),next.end(),[&](const auto &r){
    const auto old=std::find_if(rows_.begin(),rows_.end(),[&](const auto &p){return p.id==r.id;});
    return old!=rows_.end()&&old->visible==r.visible&&old->anchor==r.anchor&&old->width==r.width;
  });
  // Closely grouped colleagues retain readable labels. Above-head placements
  // are preferred; a thin tether preserves ownership when a label shifts aside.
  QVector<QRectF> occupied;
  for(auto &r:next){
    if(!r.visible)continue;
    auto previous=std::find_if(rows_.begin(),rows_.end(),[&](const auto &old){return old.id==r.id&&old.visible;});
    if(unchangedGeometry){r.label=previous->label;r.placementAnchor=previous->placementAnchor;r.tether=previous->tether;continue;}
    const bool tracking=sameViewport&&previous!=rows_.end();
    r.placementAnchor=r.anchor;
    if(tracking) {
      const auto delta=r.anchor-previous->placementAnchor;
      const auto distance=std::hypot(delta.x(),delta.y());
      if(distance<.75)r.placementAnchor=previous->placementAnchor;
      else if(distance<24)r.placementAnchor=previous->placementAnchor+delta*.25;
    }
    const QPointF ideal(r.placementAnchor.x()-r.width/2,r.placementAnchor.y()-labelHeight-headGap);
    const QPointF priorOffset=tracking?previous->label-QPointF(previous->placementAnchor.x()-previous->width/2,
                                                             previous->placementAnchor.y()-labelHeight-headGap):QPointF();
    qreal best=std::numeric_limits<qreal>::max();QPointF chosen;
    bool foundPlacement=false,preferredSafe=false;QPointF preferred;
    qreal preferredCost=0;
    const auto consider=[&](QPointF p) {
      p={std::clamp(p.x(),margin,viewport.width()-r.width-margin),
         std::clamp(p.y(),margin,viewport.height()-labelHeight-margin)};
      const QRectF rectangle(p,QSizeF(r.width,labelHeight));
      for(const auto &other:occupied)
        if(rectangle.adjusted(-gap,-gap,gap,gap).intersects(other))return;
      const auto displacement=p-ideal;
      qreal cost=displacement.x()*displacement.x()+displacement.y()*displacement.y()*1.4;
      if(tracking) {
        const auto change=displacement-priorOffset;
        cost+=.6*(change.x()*change.x()+change.y()*change.y());
      }
      if(cost<best){best=cost;chosen=p;foundPlacement=true;}
    };
    if(tracking) {
      consider(ideal+priorOffset);
      preferredSafe=foundPlacement;preferred=chosen;preferredCost=best;
    }
    for(int tier:{0,-1,1,-2,2,-3,3,-4,4,-5,5}) for(int side:{0,-1,1,-2,2,-3,3}) {
      consider({ideal.x()+side*(r.width+gap),ideal.y()+tier*(labelHeight+gap)});
    }
    // At a viewport edge, clamping can collapse several candidates onto the
    // same spot. Search the remaining area if the nearby placements are full.
    if(!foundPlacement) {
      QVector<qreal> xs{margin,viewport.width()-r.width-margin},ys{margin,viewport.height()-labelHeight-margin};
      for(const auto &other:occupied) {
        xs.push_back(other.left()-r.width-gap);xs.push_back(other.right()+gap);
        ys.push_back(other.top()-labelHeight-gap);ys.push_back(other.bottom()+gap);
      }
      for(const auto y:ys)for(const auto x:xs)consider({x,y});
    }
    if(!foundPlacement){r.visible=false;continue;}
    // Minor cost changes never flip a readable label to the other side of its
    // actor. When the crowd clears, a substantial improvement returns it home.
    if(preferredSafe&&preferredCost-best<256)chosen=preferred;
    r.label=chosen;occupied.push_back(QRectF(chosen,QSizeF(r.width,labelHeight)));
    const QPointF rawIdeal(r.anchor.x()-r.width/2,r.anchor.y()-labelHeight-headGap);
    const auto offset=chosen-rawIdeal;
    r.tether=std::hypot(offset.x(),offset.y())>(tracking&&previous->tether?8:12);
  }
  // Remove/insert only actual membership changes; a moving label does not
  // recreate its delegate, lose keyboard focus, or replay an entrance effect.
  for(int i=rows_.size()-1;i>=0;--i) {
    if(std::none_of(next.begin(),next.end(),[&](const auto &r){return r.id==rows_[i].id;})){
      beginRemoveRows({},i,i);rows_.removeAt(i);endRemoveRows();
    }
  }
  for(const auto &r:next){
    auto found=std::find_if(rows_.begin(),rows_.end(),[&](const auto &old){return old.id==r.id;});
    if(found==rows_.end()){const int row=rows_.size();beginInsertRows({},row,row);rows_.push_back(r);endInsertRows();}
    else if(*found!=r){const int row=std::distance(rows_.begin(),found);*found=r;emit dataChanged(index(row),index(row));}
  }
  viewport_=viewport;
}
} // namespace mokaid
