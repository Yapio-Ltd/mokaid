#include <mokaid/engine/surrounding_offices.hpp>
#include <mokaid/engine/office_screens.hpp>
#include <cmath>
#include <iostream>
#include <stdexcept>

using namespace mokaid::engine;
namespace {
void expect(bool condition,const char *message) {
  if(!condition)throw std::runtime_error(message);
}
bool missingMonitorVolume(Vec3 point) {
  for(const int index:{4,5}) {
    const auto &seat=seats[static_cast<std::size_t>(index)];
    const auto target=Vec3{seat.x,0,seat.z}+avatarForward(seat.yaw)*(index==4?.70F:.75F);
    const auto delta=Vec3{point.x-target.x,0,point.z-target.z};
    if(length(delta)<.43F&&point.y>.75F&&point.y<1.40F)return true;
  }
  return false;
}
void check(const Scene &scene, bool hasSource=false) {
  expect(scene.nodes.size()==1 && scene.animations.empty() && scene.skins.empty(),
         "Surroundings must stay static and material-batched");
  expect(scene.meshes.size()<=30,"Surroundings exceeded the additional draw budget");
  expect(scene.min.x<=-16 && scene.max.x>=16 && scene.min.z<=-14 && scene.max.z>=14,
         "Adjacent offices must cover every side of the main room");
  std::size_t triangles=0;
  std::vector<int> liveSeats;
  for(const auto &mesh:scene.meshes) {
    triangles+=mesh.indices.size()/3;
    expect(mesh.material<scene.materials.size() && mesh.node==0 && mesh.skin<0,
           "Invalid static background mesh reference");
    for(const auto index:mesh.indices)expect(index<mesh.vertices.size(),"Invalid background vertex index");
    if(scene.materials[mesh.material].surfaceKind==1)
      liveSeats.push_back(officeScreenSeat(mesh,Mat4::identity()));
    for(const auto &v:mesh.vertices) {
      expect(std::isfinite(v.position.x)&&std::isfinite(v.position.y)&&std::isfinite(v.position.z),
             "Background vertex is nonfinite");
      expect(std::abs(length(v.normal)-1)<.001F,"Transformed background normal must be normalized");
      const bool overhead=scene.materials[mesh.material].surfaceKind==4&&v.position.y>=4.2F;
      expect(v.position.y<0 || std::abs(v.position.x)>7.45F || std::abs(v.position.z)>6.55F || overhead ||
             missingMonitorVolume(v.position),
             "Central additions must stay inside the two missing desktop monitor volumes");
    }
  }
  std::sort(liveSeats.begin(),liveSeats.end());
  expect(liveSeats==(hasSource?std::vector<int>{4,5}:std::vector<int>{}),
         "Exactly the two missing hero-room seats must receive independent live displays");
  expect(std::any_of(scene.materials.begin(),scene.materials.end(),
         [](const auto &material){return material.surfaceKind==4;}),
         "Immersion requires an independently maskable architectural ceiling");
  expect(triangles<100000,"Surroundings exceeded the additional triangle budget");
  expect(scene.residentBytes<24*1024*1024,"Background atlases must use bounded resolution mipchains");
  for(const auto &texture:scene.textures)
    expect(!texture.mips.empty()&&texture.mips.front().width<=256&&texture.mips.front().height<=256,
           "Adjacent furniture must not duplicate full-resolution hero atlases");
  for(const auto &material:scene.materials) {
    expect(material.surfaceKind<=1||material.surfaceKind==4,
           "Only standard surfaces, added live monitors and maskable canopy are permitted");
    for(const int index:{material.texture,material.emissiveTexture,material.metallicRoughnessTexture})
      expect(index>=-1 && index<static_cast<int>(scene.textures.size()),"Invalid remapped furniture texture");
  }
  std::cout<<"Surroundings: "<<scene.meshes.size()<<" draws, "<<triangles<<" triangles, "
           <<scene.residentBytes<<" bytes\n";
}
}
int main(int argc,char **argv) {
  try {
    Scene empty;
    check(*makeSurroundingOffices(empty));
    if(argc>1) {
      const auto office=loadScene(std::filesystem::path(argv[1])/"office.mokaidasset");
      const auto min=office->min,max=office->max;
      const auto surroundings=makeSurroundingOffices(*office);
      check(*surroundings,true);
      std::size_t triangles=0;
      for(const auto &mesh:surroundings->meshes)triangles+=mesh.indices.size()/3;
      expect(triangles>25000 && !surroundings->textures.empty(),
             "Real authored workstation furniture must survive the scene extraction");
      expect(office->min.x==min.x&&office->max.z==max.z,"Background creation must preserve the hero camera bounds");
    }
    return 0;
  } catch(const std::exception &error) {std::cerr<<error.what()<<'\n';return 1;}
}
