#include <mokaid/engine/navigation.hpp>
#include <mokaid/engine/traffic.hpp>
#include <iostream>
#include <chrono>
using namespace mokaid::engine;
float planar(Vec3 a,Vec3 b){a.y=b.y=0;return length(a-b);}
int sharp(const std::vector<Vec3>&path){int count=0;for(size_t i=1;i+1<path.size();++i){Vec3 a=path[i]-path[i-1],b=path[i+1]-path[i];a.y=b.y=0;if(length(a)>.00001F&&length(b)>.00001F&&dot(normalized(a),normalized(b))<std::cos(.32F))++count;}return count;}
int main(){const auto began=std::chrono::steady_clock::now();const auto nav=Navigation::load("/Users/olimservice/mokaid/apps/desktop/build/assets/office.mokaidnav");std::vector<Vec3>points;for(int i=0;i<9;++i)for(int j=0;j<3;++j){const auto p=nav.waypoint(i,j);if(std::none_of(points.begin(),points.end(),[&](auto q){return planar(p,q)<.001F;}))points.push_back(p);}for(const auto&s:nav.sockets())if(s.kind>1)points.push_back(s.position);
std::vector<Navigation::Disc>blocked;for(const auto&s:nav.sockets())if(s.id=="desk_0"||s.id=="desk_1")blocked.push_back({s.position-avatarForward(s.yaw)*s.pullback,.425F});
for(int occupancy=0;occupancy<2;++occupancy){int routes=0,rounds=0,oldSharp=0,newSharp=0;size_t maxPoints=0;double smoothMs=0;for(size_t i=0;i<points.size();++i)for(size_t j=i+1;j<points.size();++j){const auto discs=occupancy?std::span<const Navigation::Disc>{blocked}:std::span<const Navigation::Disc>{};const auto route=nav.route(points[i],points[j],discs,.35F);if(route.empty())continue;const auto start=std::chrono::steady_clock::now();const auto smooth=nav.smoothRoute(route,discs,.35F);smoothMs+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();if(smooth.empty()||planar(smooth.front(),route.front())!=0||planar(smooth.back(),route.back())!=0)return 2;for(size_t k=1;k<smooth.size();++k)if(!nav.segmentWalkable(smooth[k-1],smooth[k],.35F,discs))return 3;++routes;rounds+=smooth.size()>route.size();oldSharp+=sharp(route);newSharp+=sharp(smooth);maxPoints=std::max(maxPoints,smooth.size());}std::cout<<"occupancy="<<occupancy<<" routes="<<routes<<" rounded="<<rounds<<" sharpBefore="<<oldSharp<<" sharpAfter="<<newSharp<<" maxPoints="<<maxPoints<<" smoothingMs="<<smoothMs<<'\n';}
std::cout<<"elapsed="<<std::chrono::duration<double>(std::chrono::steady_clock::now()-began).count()<<'\n';
}
