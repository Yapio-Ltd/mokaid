/** Deterministic offline glTF decoder. No glTF, Draco or image codec executes in the render loop. */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import draco from 'draco3dgltf';
import sharp from 'sharp';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { avatarKeys, parseAvatarCatalog, catalogEntry, validateAnimationValues } from './source-policy.mjs';
import { prepareOfficeMaterials } from './office-materials.mjs';
import { activitySockets, overrideActivitySockets, chairDelta, removeVerifiedObstacles } from './activity-sockets.mjs';
import { surfaceKind } from './surface-kinds.mjs';

const here=dirname(fileURLToPath(import.meta.url));
const repo=resolve(here,'../../../..');
const output=resolve(process.argv[2] ?? join(here,'../../build/assets'));
const source=resolve(process.argv[3] ?? join(repo,'assets/optimized'));
// Source the shipped avatar revisions, not unversioned authoring intermediates.
// Several optimized/*.glb files predate the seated/rest-pose fixes in the catalog.
const catalogText=await readFile(join(repo,'apps/api/lib/mokaid/assets_3d.ex'),'utf8');
const catalog=parseAvatarCatalog(catalogText);
await mkdir(output,{recursive:true});
const io=new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({'draco3d.decoder':await draco.createDecoderModule()});
class Writer {
  chunks=[];
  raw(b){this.chunks.push(Buffer.from(b));}
  u(n){const b=Buffer.alloc(4);b.writeUInt32LE(n);this.raw(b);}
  i(n){const b=Buffer.alloc(4);b.writeInt32LE(n);this.raw(b);}
  f(n){if(!Number.isFinite(n))throw Error('Nonfinite cooked number');const b=Buffer.alloc(4);b.writeFloatLE(n);this.raw(b);}
  floats(values){for(const n of values)this.f(n);}
  string(s){const b=Buffer.from(s);this.u(b.length);this.raw(b);}
  finish(){return Buffer.concat(this.chunks);}
}
function element(a,i,fallback){return a?a.getElement(i,[]):fallback;}
function transform(m,v){return [m[0]*v[0]+m[4]*v[1]+m[8]*v[2]+m[12],m[1]*v[0]+m[5]*v[1]+m[9]*v[2]+m[13],m[2]*v[0]+m[6]*v[1]+m[10]*v[2]+m[14]];}
const manifest={format:4,coordinateSystem:'glTF right-handed Y-up; office root PI rotation on Y; web sockets reflected on Z',textureFormat:'rgba8-mipchain-color-space-tagged',assets:[]};
const officeChairNodes=new Map();
const emitterIntensity={base:2.4,'dividing wall N':2.8,additional:22,Monitor:1.35,'Lap Top':1.4,Candles:7,'Table Light':9,'Desktop rim':1.4};
const softenedAlbedo={'plant pot N':.78,'Material.002':.88,'Material.003':.88};
for(const key of ['office',...avatarKeys,'avatar_female']) {
  let input=join(source,`${key}.glb`);
  let expectedSha256;
  if(key==='office'&&!process.argv[3]){
    const desktopOffice=JSON.parse(await readFile(join(repo,'assets/office-desktop.json'),'utf8'));
    input=join(repo,desktopOffice.path);
    expectedSha256=desktopOffice.sha256;
  } else if(!process.argv[3]) {
    const entry=catalogEntry(catalog,key);
    input=join(repo,'apps/web/public',entry.path);
    expectedSha256=entry.sha256;
  }
  const inputBytes=await readFile(input);
  const sourceSha256=createHash('sha256').update(inputBytes).digest('hex');
  if(expectedSha256&&sourceSha256!==expectedSha256)throw Error(`Source hash mismatch for catalog asset ${key}`);
  const document=await io.readBinary(inputBytes);
  // Keep accessor normalization and node transforms. Expand authored instance
  // transforms into draw nodes; the binary geometry remains the same glTF data.
  for(const node of [...document.getRoot().listNodes()]){
    const inst=node.getExtension('EXT_mesh_gpu_instancing');if(!inst)continue;
    const t=inst.getAttribute('TRANSLATION'),r=inst.getAttribute('ROTATION'),s=inst.getAttribute('SCALE');
    const count=t?.getCount()??r?.getCount()??s?.getCount()??0;
    for(let i=0;i<count;++i){const child=document.createNode(`${node.getName()}_${i}`).setMesh(node.getMesh());if(t)child.setTranslation(t.getElement(i,[]));if(r)child.setRotation(r.getElement(i,[]));if(s)child.setScale(s.getElement(i,[]));node.addChild(child);}
    node.setMesh(null).setExtension('EXT_mesh_gpu_instancing',null);
  }
  const root=document.getRoot();const nodes=[];const seen=new Set();
  function visit(n){if(seen.has(n))return;seen.add(n);nodes.push(n);for(const c of n.listChildren())visit(c);}
  for(const n of root.listNodes())if(!n.getParentNode())visit(n);
  for(const n of root.listNodes())visit(n);
  const nodeIndex=new Map(nodes.map((n,i)=>[n,i]));
  if(key==='office') for(const node of nodes) if(/^chair_[0-8]$/.test(node.getName())) {
    if(officeChairNodes.has(node.getName())) throw Error('Duplicate office chair node');
    officeChairNodes.set(node.getName(),{index:nodeIndex.get(node),parent:node.getParentNode()?.getWorldMatrix()??[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]});
  }
  const materials=root.listMaterials();
  if(key==='office')for(const m of materials){const name=m.getName().trim().replace(/\.\d+$/,'');const strength=emitterIntensity[name]??emitterIntensity[m.getName().trim()]??0;m.setEmissiveFactor(m.getEmissiveFactor().map(v=>v*strength));if(!strength)m.setEmissiveTexture(null);const soften=softenedAlbedo[name]??softenedAlbedo[m.getName().trim()]??1;m.setBaseColorFactor(m.getBaseColorFactor().map((v,i)=>i<3?v*soften:v));}
  if(key==='office') await prepareOfficeMaterials(document);
  const textures=[...new Set(materials.flatMap(m=>[m.getBaseColorTexture(),m.getEmissiveTexture(),m.getMetallicRoughnessTexture()]).filter(Boolean))];
  const linearTextures=new Set(materials.map(m=>m.getMetallicRoughnessTexture()).filter(Boolean));
  const fallback=document.createMaterial('default');materials.push(fallback);
  const skins=root.listSkins();const meshes=[];const min=[Infinity,Infinity,Infinity],max=[-Infinity,-Infinity,-Infinity];
  if(key.startsWith('avatar_'))for(const skin of skins){const first=skin.listJoints()[0]?.getName().split(/[|/:]/).pop()?.toLowerCase();if(!['hips','root.x','pelvis'].includes(first))throw Error(`${key}: skin must begin with the pelvis for seated socket calibration`);}
  for(const n of nodes){const mesh=n.getMesh();if(!mesh)continue;const world=n.getWorldMatrix();for(const primitive of mesh.listPrimitives()){
    if(primitive.getMode()!==4)throw Error(`${key}: only triangle primitives are supported`);
    const p=primitive.getAttribute('POSITION');if(!p)throw Error('Missing position');
    for(let i=0;i<p.getCount();++i){const v=transform(world,p.getElement(i,[]));for(let k=0;k<3;++k){min[k]=Math.min(min[k],v[k]);max[k]=Math.max(max[k],v[k]);}}
    meshes.push({node:n,primitive});
  }}
  const w=new Writer();w.raw(Buffer.from('MOKASSET'));w.u(4);w.floats(min);w.floats(max);
  w.u(textures.length);
  for(const texture of textures){const image=texture.getImage();if(!image)throw Error('Missing embedded image');
    const metadata=await sharp(image).metadata();let width=metadata.width,height=metadata.height;const maxSize=key==='office'?1024:1024;
    const ratio=Math.min(1,maxSize/Math.max(width,height));width=Math.max(1,Math.round(width*ratio));height=Math.max(1,Math.round(height*ratio));
    const mips=[];while(true){const rgba=await sharp(image).resize(width,height).ensureAlpha().raw().toBuffer();mips.push({width,height,rgba});if(width===1&&height===1)break;width=Math.max(1,width>>1);height=Math.max(1,height>>1);}
    w.u(linearTextures.has(texture)?0:1);w.u(mips.length);for(const m of mips){w.u(m.width);w.u(m.height);w.u(m.rgba.length);w.raw(m.rgba);}
  }
  w.u(materials.length);for(const m of materials){w.floats(m.getBaseColorFactor());w.floats(m.getEmissiveFactor());w.f(m.getRoughnessFactor());w.f(m.getMetallicFactor());w.i(textures.indexOf(m.getBaseColorTexture()));w.i(textures.indexOf(m.getEmissiveTexture()));w.i(textures.indexOf(m.getMetallicRoughnessTexture()));w.u({OPAQUE:0,MASK:1,BLEND:2}[m.getAlphaMode()]);w.f(m.getAlphaCutoff());w.u(surfaceKind(m.getName(),key==='office'));}
  w.u(nodes.length);for(const n of nodes){w.i(nodeIndex.get(n.getParentNode())??-1);w.floats(n.getTranslation());w.floats(n.getRotation());w.floats(n.getScale());}
  w.u(skins.length);for(const skin of skins){const joints=skin.listJoints();if(joints.length>128)throw Error('Skin exceeds 128-joint GPU palette');w.u(joints.length);for(const n of joints)w.u(nodeIndex.get(n));const inverse=skin.getInverseBindMatrices();for(let i=0;i<joints.length;++i)w.floats(element(inverse,i,[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]));}
  for(const mesh of meshes){const p=mesh.primitive;const texInfo=p.getMaterial()?.getBaseColorTextureInfo();if(texInfo?.getTexCoord()>0)throw Error(`${key}: base color TEXCOORD_1 requires explicit support`);}
  w.u(meshes.length);for(const {node,primitive:p}of meshes){w.u(nodeIndex.get(node));w.u(Math.max(0,materials.indexOf(p.getMaterial()??fallback)));w.i(skins.indexOf(node.getSkin()));
    const pos=p.getAttribute('POSITION'),normal=p.getAttribute('NORMAL'),uv=p.getAttribute('TEXCOORD_0'),joints=p.getAttribute('JOINTS_0'),weights=p.getAttribute('WEIGHTS_0');
    w.u(pos.getCount());for(let i=0;i<pos.getCount();++i){w.floats(pos.getElement(i,[]));w.floats(element(normal,i,[0,1,0]));w.floats(element(uv,i,[0,0]));w.floats(element(joints,i,[0,0,0,0]));w.floats(element(weights,i,[1,0,0,0]));}
    const indices=p.getIndices();w.u(indices?.getCount()??pos.getCount());for(let i=0;i<(indices?.getCount()??pos.getCount());++i)w.u(indices?indices.getScalar(i):i);
  }
  const animations=root.listAnimations();w.u(animations.length);
  for(const animation of animations){const channels=animation.listChannels().filter(c=>c.getTargetPath()!=='weights');let duration=0;for(const c of channels){const a=c.getSampler().getInput();duration=Math.max(duration,a.getScalar(a.getCount()-1));}w.string(animation.getName());w.f(duration);w.u(channels.length);
    for(const c of channels){const sampler=c.getSampler(),input=sampler.getInput(),values=sampler.getOutput(),path=c.getTargetPath();w.u(nodeIndex.get(c.getTargetNode()));w.u({translation:0,rotation:1,scale:2}[path]);w.u(sampler.getInterpolation()==='STEP'?1:0);
      if(sampler.getInterpolation()==='CUBICSPLINE')throw Error(`${key}: cubic animation must be resampled before cooking`);
      // Legacy desk-pose patching used another channel's sample count for
      // constant lower-body tracks. Reconcile only provably constant outputs;
      // never invent timing for a malformed, genuinely animated channel.
      validateAnimationValues(input.getCount(),values,`${key}/${animation.getName()}`);
      w.u(input.getCount());for(let i=0;i<input.getCount();++i)w.f(input.getScalar(i));for(let i=0;i<input.getCount();++i){const v=values.getElement(Math.min(i,values.getCount()-1),[]);w.floats(v.length===3?[...v,0]:v);}
    }
  }
  const bytes=w.finish(),file=`${key}.mokaidasset`;await writeFile(join(output,file),bytes);
  const asset={id:key,file,sha256:createHash('sha256').update(bytes).digest('hex'),sourceSha256,sourcePath:relative(repo,input),bytes:bytes.length,meshes:meshes.length,vertices:meshes.reduce((n,m)=>n+m.primitive.getAttribute('POSITION').getCount(),0),animations:animations.map(a=>a.getName())};manifest.assets.push(asset);console.log(`${key}: ${asset.meshes} primitives, ${asset.vertices} vertices, ${(bytes.length/1048576).toFixed(1)} MiB`);
}
const navigationText=await readFile(join(repo,'apps/web/src/three/office-navdata.ts'),'utf8');
const pathsText=await readFile(join(repo,'apps/web/src/three/office-paths.ts'),'utf8');
const obstacleBlock=navigationText.match(/export const OFFICE_OBSTACLES[^=]*=\s*\[([\s\S]*?)\n\];/)[1];
const boxes=[...obstacleBlock.matchAll(/minX:\s*([-\d.]+),\s*maxX:\s*([-\d.]+),\s*minZ:\s*([-\d.]+),\s*maxZ:\s*([-\d.]+)/g)].map(m=>m.slice(1).map(Number));
const anchorBlock=navigationText.match(/export const OFFICE_NAV_NODES[^=]*=\s*\[([\s\S]*?)\n\];/)[1];
const anchors=[...anchorBlock.matchAll(/id:\s*"([^"]+)",\s*x:\s*([-\d.]+),\s*z:\s*([-\d.]+)/g)].map(m=>({id:m[1],x:Number(m[2]),z:-Number(m[3])}));
const lanes=[...pathsText.matchAll(/loopPath\("[^"]+",\s*\[([^\]]+)\]/g)].map(m=>[...m[1].matchAll(/"([^"]+)"/g)].map(n=>anchors.findIndex(a=>a.id===n[1])));
if(boxes.length<100||anchors.length<10||lanes.length<9||lanes.some(l=>l.some(i=>i<0)))throw Error('Office navigation source changed: review the cooker parser');
const navOverrides=process.argv[3]?{}:JSON.parse(await readFile(join(repo,'assets/office-desktop.json'),'utf8')).navigation??{};
const nativeBoxes=removeVerifiedObstacles(boxes.map(([minX,maxX,minZ,maxZ])=>[minX,maxX,-maxZ,-minZ]),navOverrides.removeObstacles);
for(const replacement of navOverrides.obstacles??[]){
  if(!Array.isArray(replacement.old)||!Array.isArray(replacement.new)||replacement.old.length!==4||replacement.new.length!==4||![...replacement.old,...replacement.new].every(Number.isFinite))throw Error('Invalid native navigation obstacle override');
  const index=nativeBoxes.findIndex(box=>box.every((v,i)=>Math.abs(v-replacement.old[i])<.0001));
  if(index<0)throw Error(`Native navigation obstacle not found: ${replacement.old}`);
  nativeBoxes[index]=replacement.new;
}
for(const [id,position] of Object.entries(navOverrides.anchors??{})){
  const anchor=anchors.find(a=>a.id===id);
  if(!anchor||!Number.isFinite(position.x)||!Number.isFinite(position.z))throw Error(`Invalid native anchor override: ${id}`);
  anchor.x=position.x;anchor.z=position.z;
}
const sockets=overrideActivitySockets(activitySockets(navigationText),navOverrides.sockets);
for(const socket of sockets) {
  socket.chairNode=-1;socket.chairLocalDelta=[0,0,0];socket.pullback??=0;
  if(socket.chairName) {
    const binding=officeChairNodes.get(socket.chairName);
    if(!binding) throw Error(`Missing physical chair node ${socket.chairName}`);
    socket.chairNode=binding.index;socket.chairLocalDelta=chairDelta(binding.parent,socket.yaw,socket.pullback);
  }
}
const floors=navOverrides.floorSurfaces??[];
for(const f of floors) if(![f.minX,f.maxX,f.minZ,f.maxZ,f.height].every(Number.isFinite)||f.minX>=f.maxX||f.minZ>=f.maxZ||f.height<0||f.height>1) throw Error('Invalid floor surface');
const nav=new Writer();nav.raw(Buffer.from('MOKANAV3'));nav.u(nativeBoxes.length);for(const box of nativeBoxes)nav.floats(box);nav.u(anchors.length);for(const a of anchors)nav.floats([a.x,a.z]);nav.u(lanes.length);for(const l of lanes){nav.u(l.length);for(const i of l)nav.u(i);}
nav.u(sockets.length);for(const s of sockets){nav.string(s.id);nav.u(s.kind);nav.floats([s.x,s.z,s.approachX,s.approachZ,s.yaw,s.seatHeight,s.holdSeconds]);nav.i(s.chairNode);nav.f(s.pullback);nav.floats(s.chairLocalDelta);}
nav.u(floors.length);for(const f of floors)nav.floats([f.minX,f.maxX,f.minZ,f.maxZ,f.height]);
const navBytes=nav.finish();await writeFile(join(output,'office.mokaidnav'),navBytes);manifest.navigation={file:'office.mokaidnav',sha256:createHash('sha256').update(navBytes).digest('hex'),obstacles:nativeBoxes.length,lanes:lanes.length,sockets,floorSurfaces:floors};
await writeFile(join(output,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
