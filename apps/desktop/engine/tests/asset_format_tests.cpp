#include <mokaid/engine/scene.hpp>
#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace mokaid::engine;
int main() {
  const auto path=std::filesystem::temp_directory_path()/(
      "mokaid-surface-format-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())+".mokaidasset");
  struct Cleanup{std::filesystem::path path;~Cleanup(){std::error_code error;std::filesystem::remove(path,error);}} cleanup{path};
  const auto fixture=[&](std::uint32_t version,std::uint32_t kind){
    std::ofstream stream(path,std::ios::binary);
    const auto write=[&](const auto &value){stream.write(reinterpret_cast<const char*>(&value),sizeof value);};
    stream.write("MOKASSET",8);write(version);write(Vec3{});write(Vec3{1,1,1});
    write(std::uint32_t{0}); // textures
    write(std::uint32_t{1}); // materials
    write(Vec4{1,1,1,1});write(Vec3{});write(1.F);write(0.F);
    write(std::int32_t{-1});write(std::int32_t{-1});write(std::int32_t{-1});
    write(std::uint32_t{0});write(.5F);
    if(version>=4)write(kind);
    write(std::uint32_t{1});write(std::int32_t{-1});write(Vec3{});write(Vec4{0,0,0,1});write(Vec3{1,1,1});
    write(std::uint32_t{0});write(std::uint32_t{0});write(std::uint32_t{0}); // skins, meshes, animations
  };
  try {
    fixture(3,0);
    if(loadScene(path)->materials.front().surfaceKind!=0)throw std::runtime_error("Legacy v3 material must remain ordinary PBR");
    for(std::uint32_t kind=0;kind<=3;++kind){
      fixture(4,kind);
      if(loadScene(path)->materials.front().surfaceKind!=kind)throw std::runtime_error("v4 surface semantic lost during decoding");
    }
    fixture(4,4);bool rejected=false;
    try{(void)loadScene(path);}catch(const std::runtime_error&){rejected=true;}
    if(!rejected)throw std::runtime_error("Unknown surface semantics must fail before GPU work");
    std::cout<<"Asset v3/v4 surface compatibility passed\n";return 0;
  }catch(const std::exception &error){std::cerr<<error.what()<<'\n';return 1;}
}
