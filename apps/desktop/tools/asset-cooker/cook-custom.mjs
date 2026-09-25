/** Converts a self-contained generated GLB to the native format off the render thread. */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import draco from 'draco3dgltf';
import sharp from 'sharp';
import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { validateAnimationValues } from './source-policy.mjs';

// Fail before the decoder can resolve a remote or filesystem URI.
export function validateEmbeddedGlb(bytes) {
  if(bytes.length<20||bytes.length>64*1024*1024||bytes.toString('ascii',0,4)!=='glTF'||
     bytes.readUInt32LE(4)!==2||bytes.readUInt32LE(8)!==bytes.length||bytes.readUInt32LE(16)!==0x4e4f534a)
    throw Error('Invalid or oversized GLB');
  const length=bytes.readUInt32LE(12);
  if(length>bytes.length-20)throw Error('Truncated GLB document');
  const json=JSON.parse(bytes.toString('utf8',20,20+length));
  for(const item of [...(json.buffers??[]),...(json.images??[])])
    if(item.uri&&!/^data:[^,]+;base64,/.test(item.uri))throw Error('External GLB resources are not allowed');
  return json;
}
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
export async function cookCustom(input,output) {
  const inputBytes=await readFile(input);
  validateEmbeddedGlb(inputBytes);
  const io=new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({'draco3d.decoder':await draco.createDecoderModule()});
  const document=await io.readBinary(inputBytes);
  const animationsIn=document.getRoot().listAnimations();
  // Meshy's rigging endpoint returns a single walking take. Normalize its name
  // and add a held neutral frame for office activities without matching clips.
  if(animationsIn.length===1&&!['walking','idle'].includes(animationsIn[0].getName()))
    animationsIn[0].setName('walking');
  const walking=animationsIn.find(a=>a.getName()==='walking');
  if(walking&&!animationsIn.some(a=>a.getName()==='idle')) {
    const idle=document.createAnimation('idle');
    for(const channel of walking.listChannels()) {
      if(channel.getTargetPath()==='weights')continue;
      const original=channel.getSampler();
      const input=document.createAccessor().setType('SCALAR').setArray(new Float32Array([0]));
      const output=document.createAccessor().setType(original.getOutput().getType())
        .setArray(new Float32Array(original.getOutput().getElement(0,[])));
      const sampler=document.createAnimationSampler().setInput(input).setOutput(output).setInterpolation('STEP');
      idle.addSampler(sampler).addChannel(document.createAnimationChannel().setTargetNode(channel.getTargetNode())
        .setTargetPath(channel.getTargetPath()).setSampler(sampler));
    }
  }
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
  const materials=root.listMaterials();
  const textures=[...new Set(materials.flatMap(m=>[m.getBaseColorTexture(),m.getEmissiveTexture(),m.getMetallicRoughnessTexture()]).filter(Boolean))];
  const linearTextures=new Set(materials.map(m=>m.getMetallicRoughnessTexture()).filter(Boolean));
  if(textures.length>32||materials.length>128||nodes.length>4096)throw Error('Character scene exceeds limits');
  const fallback=document.createMaterial('default');materials.push(fallback);
  const skins=root.listSkins();const meshes=[];const min=[Infinity,Infinity,Infinity],max=[-Infinity,-Infinity,-Infinity];
  for(const n of nodes){const mesh=n.getMesh();if(!mesh)continue;const world=n.getWorldMatrix();for(const primitive of mesh.listPrimitives()){
    if(primitive.getMode()!==4)throw Error(`custom character: only triangle primitives are supported`);
    const p=primitive.getAttribute('POSITION');if(p&&p.getCount()>1000000)throw Error('Character exceeds vertex limit');if(!p)throw Error('Missing position');
    for(let i=0;i<p.getCount();++i){const v=transform(world,p.getElement(i,[]));for(let k=0;k<3;++k){min[k]=Math.min(min[k],v[k]);max[k]=Math.max(max[k],v[k]);}}
    meshes.push({node:n,primitive});
  }}
  const w=new Writer();w.raw(Buffer.from('MOKASSET'));w.u(4);w.floats(min);w.floats(max);
  w.u(textures.length);
  for(const texture of textures){const image=texture.getImage();if(!image)throw Error('Missing embedded image');
    const metadata=await sharp(image,{limitInputPixels:16777216}).metadata();let width=metadata.width,height=metadata.height;const maxSize=1024;
    const ratio=Math.min(1,maxSize/Math.max(width,height));width=Math.max(1,Math.round(width*ratio));height=Math.max(1,Math.round(height*ratio));
    const mips=[];while(true){const rgba=await sharp(image,{limitInputPixels:16777216}).resize(width,height).ensureAlpha().raw().toBuffer();mips.push({width,height,rgba});if(width===1&&height===1)break;width=Math.max(1,width>>1);height=Math.max(1,height>>1);}
    w.u(linearTextures.has(texture)?0:1);w.u(mips.length);for(const m of mips){w.u(m.width);w.u(m.height);w.u(m.rgba.length);w.raw(m.rgba);}
  }
  w.u(materials.length);for(const m of materials){w.floats(m.getBaseColorFactor());w.floats(m.getEmissiveFactor());w.f(m.getRoughnessFactor());w.f(m.getMetallicFactor());w.i(textures.indexOf(m.getBaseColorTexture()));w.i(textures.indexOf(m.getEmissiveTexture()));w.i(textures.indexOf(m.getMetallicRoughnessTexture()));w.u({OPAQUE:0,MASK:1,BLEND:2}[m.getAlphaMode()]);w.f(m.getAlphaCutoff());w.u(0);}
  w.u(nodes.length);for(const n of nodes){w.i(nodeIndex.get(n.getParentNode())??-1);w.floats(n.getTranslation());w.floats(n.getRotation());w.floats(n.getScale());}
  w.u(skins.length);for(const skin of skins){const joints=skin.listJoints();if(joints.length>128)throw Error('Skin exceeds 128-joint GPU palette');w.u(joints.length);for(const n of joints)w.u(nodeIndex.get(n));const inverse=skin.getInverseBindMatrices();for(let i=0;i<joints.length;++i)w.floats(element(inverse,i,[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]));}
  for(const mesh of meshes){const p=mesh.primitive;const texInfo=p.getMaterial()?.getBaseColorTextureInfo();if(texInfo?.getTexCoord()>0)throw Error(`custom character: base color TEXCOORD_1 requires explicit support`);}
  w.u(meshes.length);for(const {node,primitive:p}of meshes){w.u(nodeIndex.get(node));w.u(Math.max(0,materials.indexOf(p.getMaterial()??fallback)));w.i(skins.indexOf(node.getSkin()));
    const pos=p.getAttribute('POSITION'),normal=p.getAttribute('NORMAL'),uv=p.getAttribute('TEXCOORD_0'),joints=p.getAttribute('JOINTS_0'),weights=p.getAttribute('WEIGHTS_0');
    w.u(pos.getCount());for(let i=0;i<pos.getCount();++i){w.floats(pos.getElement(i,[]));w.floats(element(normal,i,[0,1,0]));w.floats(element(uv,i,[0,0]));w.floats(element(joints,i,[0,0,0,0]));w.floats(element(weights,i,[1,0,0,0]));}
    const indices=p.getIndices();w.u(indices?.getCount()??pos.getCount());for(let i=0;i<(indices?.getCount()??pos.getCount());++i)w.u(indices?indices.getScalar(i):i);
  }
  const animations=root.listAnimations();w.u(animations.length);
  for(const animation of animations){const channels=animation.listChannels().filter(c=>c.getTargetPath()!=='weights');let duration=0;for(const c of channels){const a=c.getSampler().getInput();duration=Math.max(duration,a.getScalar(a.getCount()-1));}w.string(animation.getName());w.f(duration);w.u(channels.length);
    for(const c of channels){const sampler=c.getSampler(),input=sampler.getInput(),values=sampler.getOutput(),path=c.getTargetPath();w.u(nodeIndex.get(c.getTargetNode()));w.u({translation:0,rotation:1,scale:2}[path]);w.u(sampler.getInterpolation()==='STEP'?1:0);
      if(sampler.getInterpolation()==='CUBICSPLINE')throw Error(`custom character: cubic animation must be resampled before cooking`);
      // Legacy desk-pose patching used another channel's sample count for
      // constant lower-body tracks. Reconcile only provably constant outputs;
      // never invent timing for a malformed, genuinely animated channel.
      validateAnimationValues(input.getCount(),values,`custom character/${animation.getName()}`);
      w.u(input.getCount());for(let i=0;i<input.getCount();++i)w.f(input.getScalar(i));for(let i=0;i<input.getCount();++i){const v=values.getElement(Math.min(i,values.getCount()-1),[]);w.floats(v.length===3?[...v,0]:v);}
    }
  }
  const bytes=w.finish();
  if(bytes.length>128*1024*1024)throw Error('Cooked character exceeds 128 MiB');
  await writeFile(output,bytes,{mode:0o600});
  return {bytes:bytes.length,meshes:meshes.length,animations:animations.map(a=>a.getName())};
}

if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href) {
  const [input,output]=process.argv.slice(2);
  if(!input||!output)throw Error('Usage: cook-custom.mjs input.glb output.mokaidasset');
  await cookCustom(input,output);
}
