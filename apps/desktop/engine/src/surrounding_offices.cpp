#include <mokaid/engine/surrounding_offices.hpp>
#include <mokaid/engine/office.hpp>
#include <array>
#include <limits>
#include <unordered_map>

namespace mokaid::engine {
namespace {
constexpr float pi = 3.14159265358979323846F;
Texture backgroundTexture(const Texture &source) {
  // Reuse the cooker's filtered mipchain. A desktop atlas can be 4K; copying
  // its full-resolution levels for a distant suite would waste >100 MiB.
  const auto first=std::find_if(source.mips.begin(),source.mips.end(),
      [](const auto &mip) { return mip.width<=256 && mip.height<=256; });
  if(first!=source.mips.end())return {source.srgb,{first,source.mips.end()}};
  if(source.mips.empty())return source;
  const auto &input=source.mips.back();
  TextureMip mip;
  const float scale=256.F/std::max(input.width,input.height);
  mip.width=std::max(1U,static_cast<std::uint32_t>(input.width*scale));
  mip.height=std::max(1U,static_cast<std::uint32_t>(input.height*scale));
  mip.rgba.resize(mip.width*mip.height*4);
  for(std::uint32_t y=0;y<mip.height;++y)for(std::uint32_t x=0;x<mip.width;++x) {
    const auto sx=std::min(input.width-1,static_cast<std::uint32_t>((x+.5F)/scale));
    const auto sy=std::min(input.height-1,static_cast<std::uint32_t>((y+.5F)/scale));
    std::copy_n(input.rgba.begin()+(sy*input.width+sx)*4,4,mip.rgba.begin()+(y*mip.width+x)*4);
  }
  return {source.srgb,{std::move(mip)}};
}
struct Bounds {
  Vec3 min, max;
  bool contains(Vec3 v) const {
    return v.x >= min.x && v.x <= max.x && v.y >= min.y &&
           v.y <= max.y && v.z >= min.z && v.z <= max.z;
  }
};

class Builder {
public:
  std::shared_ptr<Scene> scene = std::make_shared<Scene>();
  Builder() { scene->nodes.emplace_back(); }

  std::uint32_t material(Vec3 color, float roughness, float metallic = 0,
                         Vec3 emission = {}, float alpha = 1) {
    Material m;
    m.color = {color.x, color.y, color.z, alpha};
    m.roughness = roughness; m.metallic = metallic; m.emissive = emission;
    m.alphaMode = alpha < 1 ? 2 : 0;
    scene->materials.push_back(m);
    return static_cast<std::uint32_t>(scene->materials.size() - 1);
  }

  Mesh &batch(std::uint32_t material) {
    const auto found = std::find_if(scene->meshes.begin(), scene->meshes.end(),
        [&](const Mesh &mesh) { return mesh.material == material; });
    if (found != scene->meshes.end()) return *found;
    scene->meshes.push_back({0, material, -1, {}, {}});
    return scene->meshes.back();
  }

  void quad(std::uint32_t material, Vec3 a, Vec3 b, Vec3 c, Vec3 d) {
    auto &mesh = batch(material);
    const auto start = static_cast<std::uint32_t>(mesh.vertices.size());
    const auto normal = normalized(cross(b - a, c - a));
    mesh.vertices.push_back({a, normal, 0, 0, {}, {}});
    mesh.vertices.push_back({b, normal, 1, 0, {}, {}});
    mesh.vertices.push_back({c, normal, 1, 1, {}, {}});
    mesh.vertices.push_back({d, normal, 0, 1, {}, {}});
    for (const auto index : {0U, 1U, 2U, 0U, 2U, 3U})
      mesh.indices.push_back(start + index);
  }

  void box(std::uint32_t material, Vec3 center, Vec3 size) {
    const auto a = center - size * .5F, b = center + size * .5F;
    quad(material, {a.x,b.y,a.z}, {a.x,b.y,b.z}, {b.x,b.y,b.z}, {b.x,b.y,a.z});
    quad(material, {a.x,a.y,b.z}, {a.x,a.y,a.z}, {b.x,a.y,a.z}, {b.x,a.y,b.z});
    quad(material, {a.x,a.y,a.z}, {a.x,b.y,a.z}, {b.x,b.y,a.z}, {b.x,a.y,a.z});
    quad(material, {b.x,a.y,b.z}, {b.x,b.y,b.z}, {a.x,b.y,b.z}, {a.x,a.y,b.z});
    quad(material, {a.x,a.y,b.z}, {a.x,b.y,b.z}, {a.x,b.y,a.z}, {a.x,a.y,a.z});
    quad(material, {b.x,a.y,a.z}, {b.x,b.y,a.z}, {b.x,b.y,b.z}, {b.x,a.y,b.z});
  }

  void pot(std::uint32_t material, Vec3 center) {
    constexpr int segments = 24;
    for (int i = 0; i < segments; ++i) {
      const float a = i * 2 * pi / segments, b = (i + 1) * 2 * pi / segments;
      quad(material, center + Vec3{std::cos(a)*.23F,0,std::sin(a)*.23F},
          center + Vec3{std::cos(a)*.30F,.40F,std::sin(a)*.30F},
          center + Vec3{std::cos(b)*.30F,.40F,std::sin(b)*.30F},
          center + Vec3{std::cos(b)*.23F,0,std::sin(b)*.23F});
    }
  }

  void finish() {
    scene->min = {1000,1000,1000}; scene->max = {-1000,-1000,-1000};
    for (const auto &mesh : scene->meshes) {
      scene->residentBytes += mesh.vertices.size()*sizeof(Vertex) + mesh.indices.size()*sizeof(std::uint32_t);
      for (const auto &v : mesh.vertices) {
        scene->min = {std::min(scene->min.x,v.position.x),std::min(scene->min.y,v.position.y),std::min(scene->min.z,v.position.z)};
        scene->max = {std::max(scene->max.x,v.position.x),std::max(scene->max.y,v.position.y),std::max(scene->max.z,v.position.z)};
      }
    }
    for (const auto &texture : scene->textures)
      for (const auto &mip : texture.mips) scene->residentBytes += mip.rgba.size();
    scene->referenceMinY = scene->min.y;
    scene->referenceHeight = scene->max.y - scene->min.y;
  }
};

// Select only complete triangles inside an authored furniture footprint. Large
// floor/wall triangles are excluded; neither room walls nor navigation objects
// become copied fragments. Normals use inverse transpose (source nodes may have
// nonuniform scale), and reused vertices keep the background geometry compact.
std::vector<Mesh> furniture(const Scene &source, const Pose &pose, Bounds bounds,
                            bool wholeMesh = false) {
  std::vector<Mesh> result;
  for (const auto &mesh : source.meshes) {
    if (mesh.skin >= 0) continue;
    const auto world = trs({}, {0,1,0,0}) * pose.world[mesh.node];
    const auto inv = inverse(world);
    std::vector<Vertex> vertices;
    vertices.reserve(mesh.vertices.size());
    for (auto v : mesh.vertices) {
      const auto p = transform(world, {v.position.x,v.position.y,v.position.z,1});
      const auto n = v.normal;
      v.position = {p.x,p.y,p.z};
      v.normal = normalized({inv.m[0]*n.x+inv.m[1]*n.y+inv.m[2]*n.z,
                             inv.m[4]*n.x+inv.m[5]*n.y+inv.m[6]*n.z,
                             inv.m[8]*n.x+inv.m[9]*n.y+inv.m[10]*n.z});
      vertices.push_back(v);
    }
    if (wholeMesh && !std::all_of(vertices.begin(),vertices.end(),
                                [&](const auto &v) { return bounds.contains(v.position); })) continue;
    Mesh selected{0,mesh.material,-1,{}, {}};
    std::unordered_map<std::uint32_t,std::uint32_t> remap;
    for (std::size_t i=0; i<mesh.indices.size(); i+=3) {
      const auto a=mesh.indices[i], b=mesh.indices[i+1], c=mesh.indices[i+2];
      if (!bounds.contains(vertices[a].position) || !bounds.contains(vertices[b].position) ||
          !bounds.contains(vertices[c].position)) continue;
      for (const auto index : {a,b,c}) {
        const auto [entry,inserted] = remap.try_emplace(index, static_cast<std::uint32_t>(selected.vertices.size()));
        if (inserted) selected.vertices.push_back(vertices[index]);
        selected.indices.push_back(entry->second);
      }
    }
    if (!selected.indices.empty()) result.push_back(std::move(selected));
  }
  return result;
}
} // namespace

std::shared_ptr<const Scene> makeSurroundingOffices(const Scene &office) {
  Builder b;
  const auto floor=b.material({.070F,.086F,.12F},.48F,.18F);
  const auto inset=b.material({.045F,.062F,.083F},.72F,.08F);
  const auto wall=b.material({.048F,.062F,.087F},.62F,.1F);
  const auto frame=b.material({.095F,.12F,.16F},.27F,.72F);
  const auto warm=b.material({.7F,.50F,.26F},.35F,0,{1.25F,.80F,.39F});
  const auto cool=b.material({.22F,.40F,.54F},.3F,0,{.34F,.76F,1.05F});
  const auto glass=b.material({.065F,.14F,.21F},.12F,.55F,{},.15F);

  // A continuous building floor and four connected suites replace the black
  // void. Their top sits just below the main room floor, avoiding coplanarity.
  b.box(floor,{0,-.26F,0},{42,.12F,38});
  for (const float side : {-1.F,1.F}) {
    b.box(floor,{side*12.75F,-.07F,0},{10.4F,.1F,13.2F});
    b.box(floor,{0,-.07F,side*11.8F},{36,.1F,10.4F});
    b.box(inset,{side*12.1F,-.013F,.25F},{6.3F,.008F,12.5F});
    b.box(inset,{0,-.013F,side*11.5F},{14.8F,.008F,6.7F});
    // Narrow inlays describe circulation instead of boxing the hero office in.
    b.box(cool,{side*8.3F,-.003F,0},{.026F,.015F,18.5F});
    b.box(warm,{0,-.003F,side*7.4F},{16.6F,.015F,.023F});
  }

  // The two rear facades are full-height; camera-side partitions stay low so
  // they do not occlude workstations when orbiting or entering the office.
  for (int section=0; section<6; ++section) {
    const float x=-15.F+section*5.5F;
    b.box(wall,{x,1.35F,15.2F},{5.42F,2.74F,.16F});
    b.box(frame,{x,2.74F,15.1F},{5.45F,.12F,.16F});
    b.box(frame,{x-2.7F,2.74F,12.3F},{.08F,.12F,5.8F});
    b.box(warm,{x,2.67F,14.98F},{3.65F,.022F,.04F});
    b.box(frame,{x-2.7F,1.35F,9.4F},{.06F,2.75F,.065F});
    b.box(glass,{x,1.39F,9.4F},{5.35F,2.65F,.018F});
    b.box(frame,{x,.035F,9.4F},{5.4F,.07F,.08F});
    b.box(frame,{x,2.74F,9.4F},{5.4F,.065F,.08F});
  }
  for (int section=0; section<4; ++section) {
    const float z=-6.F+section*5.2F;
    b.box(wall,{-16.6F,1.35F,z},{.16F,2.74F,5.1F});
    b.box(frame,{-16.5F,2.74F,z},{.16F,.12F,5.1F});
    b.box(frame,{-14.6F,2.74F,z+2.55F},{4.1F,.12F,.08F});
    b.box(cool,{-16.36F,2.66F,z},{.04F,.022F,3.2F});
    b.box(frame,{-9.15F,1.32F,z-2.55F},{.065F,2.7F,.06F});
    b.box(glass,{-9.15F,1.33F,z},{.018F,2.62F,5.04F});
    b.box(frame,{-9.15F,2.7F,z},{.07F,.065F,5.1F});
  }
  // Slatted dividers and shallow cabinetry keep the near wings recognizably
  // occupied without erecting walls across the hero room's sight lines.
  for (const float z : {-5.F,.2F,5.4F}) {
    b.box(wall,{14.3F,.46F,z},{.48F,.96F,3.6F});
    b.box(frame,{14.3F,.96F,z},{.53F,.05F,3.64F});
    for (int slat=0; slat<12; ++slat)
      b.box(frame,{14.04F,.47F,z-1.62F+slat*.294F},{.018F,.84F,.016F});
  }
  for (const float x : {-5.F,0.F,5.F}) {
    b.box(wall,{x,.24F,-13.45F},{3.4F,.5F,.42F});
    b.box(warm,{x,.5F,-13.23F},{2.3F,.018F,.025F});
  }

  const auto pose=evaluatePose(office,"",0);
  const auto desk=furniture(office,pose,{{4.F,-.001F,1.35F},{6.35F,1.5F,3.4F}});
  const auto leaves=furniture(office,pose,{{3.90F,.18F,-3.81F},{4.87F,1.05F,-2.75F}},true);
  std::unordered_map<std::uint32_t,std::uint32_t> materials;
  std::unordered_map<std::int32_t,std::int32_t> textures;
  const auto texture=[&](std::int32_t source) {
    if(source<0) return -1;
    const auto [entry,inserted]=textures.try_emplace(source,static_cast<std::int32_t>(b.scene->textures.size()));
    if(inserted)b.scene->textures.push_back(backgroundTexture(office.textures[static_cast<std::size_t>(source)]));
    return entry->second;
  };
  const auto copyFurniture=[&](const std::vector<Mesh> &parts,Vec3 origin,Vec3 destination,float yaw) {
    const auto placement=trs(destination,{0,std::sin(yaw*.5F),0,std::cos(yaw*.5F)})*trs(origin*-1.F);
    for (const auto &part : parts) {
      const auto [entry,inserted]=materials.try_emplace(part.material,static_cast<std::uint32_t>(b.scene->materials.size()));
      if (inserted) {
        auto m=office.materials[part.material];
        m.color.x*=.64F; m.color.y*=.69F; m.color.z*=.76F;
        m.emissive=m.emissive*.22F;
        if(m.surfaceKind==1) {m.emissive={.08F,.21F,.30F};m.color={.055F,.10F,.14F,1};}
        // Adjacent empty offices never receive main-agent activity screens.
        m.surfaceKind=0;
        m.texture=texture(m.texture);m.emissiveTexture=texture(m.emissiveTexture);
        m.metallicRoughnessTexture=texture(m.metallicRoughnessTexture);
        b.scene->materials.push_back(m);
      }
      auto &mesh=b.batch(entry->second);
      const auto start=static_cast<std::uint32_t>(mesh.vertices.size());
      for(auto v : part.vertices) {
        const auto p=transform(placement,{v.position.x,v.position.y,v.position.z,1});
        const auto n=transform(placement,{v.normal.x,v.normal.y,v.normal.z,0});
        v.position={p.x,p.y,p.z};v.normal=normalized({n.x,n.y,n.z});
        mesh.vertices.push_back(v);
      }
      for(auto index:part.indices)mesh.indices.push_back(start+index);
    }
  };
  // These are the authored complete desks, chairs, monitors and small props,
  // with two orientations and staggered positions to avoid a tiled-room look.
  for (const float z : {-4.8F,.2F,5.2F}) {
    copyFurniture(desk,{5.17F,0,2.2F},{-10.8F,0,z},pi*.5F);
    copyFurniture(desk,{5.17F,0,2.2F},{10.4F,0,z+.6F},-pi*.5F);
  }
  for (const float x : {-5.3F,.1F,5.4F}) {
    copyFurniture(desk,{5.17F,0,2.2F},{x,0,10.9F},pi);
    copyFurniture(desk,{5.17F,0,2.2F},{x+.5F,0,-9.3F},0);
  }
  for (const Vec3 p : std::array<Vec3,6>{{{-9.9F,0,7.8F},{-9.9F,0,-7.5F},{9.9F,0,7.8F},
                                        {10.F,0,-7.8F},{-2.7F,0,10.6F},{3.F,0,-13.2F}}}) {
    b.pot(frame,p);
    copyFurniture(leaves,{4.38F,0,-3.29F},p,0);
  }

  // The authored source contains two displays at desk 6 but none facing desk 4
  // or the meeting-room seat. Reuse one complete authored monitor assembly to
  // fill those two physical gaps. Keep each screen in its own draw mesh so the
  // live atlas binds its real seat rather than averaging two screen positions.
  const auto monitor=furniture(office,pose,{{1.30F,.75F,3.12F},{2.06F,1.35F,3.36F}},true);
  for(const int seatIndex : {4,5}) {
    const auto &seat=seats[static_cast<std::size_t>(seatIndex)];
    const float reach=seatIndex==4?.70F:.75F;
    const auto target=Vec3{seat.x,seatIndex==5?.0573F:0.F,seat.z}+avatarForward(seat.yaw)*reach;
    // Desk 4 faces the existing desk-3 screen back-to-back. Align the two shells
    // with their common tabletop axis, leaving a gap instead of intersecting.
    const float yaw=seatIndex==4?-pi*.5F:seat.yaw;
    const auto placement=trs(target,{0,std::sin(yaw*.5F),0,std::cos(yaw*.5F)})*
                         trs({-1.681435F,0,-3.239347F});
    for(const auto &part:monitor) {
      auto material=office.materials[part.material];
      material.texture=texture(material.texture);
      material.emissiveTexture=texture(material.emissiveTexture);
      material.metallicRoughnessTexture=texture(material.metallicRoughnessTexture);
      const auto materialIndex=static_cast<std::uint32_t>(b.scene->materials.size());
      b.scene->materials.push_back(material);
      auto &mesh=b.batch(materialIndex);
      for(auto vertex:part.vertices) {
        const auto p=transform(placement,{vertex.position.x,vertex.position.y,vertex.position.z,1});
        const auto n=transform(placement,{vertex.normal.x,vertex.normal.y,vertex.normal.z,0});
        vertex.position={p.x,p.y,p.z};vertex.normal=normalized({n.x,n.y,n.z});
        mesh.vertices.push_back(vertex);
      }
      mesh.indices=part.indices;
    }
  }

  // Human-height views need an actual building envelope above the cutaway
  // room. These three batches are masked out by Office's overview instance;
  // they are regular PBR geometry, not a screen or a sky backdrop.
  const auto ceiling=b.material({.18F,.20F,.255F},.82F,.04F,{.014F,.018F,.028F});
  const auto ceilingWarm=b.material({.30F,.26F,.20F},.5F,0,{.42F,.31F,.20F});
  const auto ceilingCool=b.material({.20F,.25F,.31F},.5F,0,{.18F,.29F,.42F});
  for(const auto material:{ceiling,ceilingWarm,ceilingCool})
    b.scene->materials[material].surfaceKind=4;
  b.box(ceiling,{0,4.57F,0},{42,.14F,38});
  for(const float side:{-1.F,1.F}) {
    b.box(ceiling,{side*20.9F,2.15F,0},{.20F,4.70F,38});
    b.box(ceiling,{0,2.15F,side*18.9F},{42,4.70F,.20F});
    b.box(ceiling,{side*7.75F,4.40F,0},{.22F,.20F,33});
    b.box(ceilingWarm,{side*7.70F,4.294F,0},{.027F,.012F,15.5F});
  }
  for(const float z:{-6.9F,6.9F}) {
    b.box(ceiling,{0,4.40F,z},{15.4F,.20F,.18F});
    b.box(ceilingCool,{0,4.294F,z-.045F},{10.8F,.012F,.025F});
  }
  b.finish();
  return b.scene;
}
} // namespace mokaid::engine
