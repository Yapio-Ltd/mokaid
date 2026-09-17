/** Measure standing body clearance after rolling chairs; no production edits. */
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const here=dirname(fileURLToPath(import.meta.url)),repo=resolve(here,'../..');
const require=createRequire(resolve(repo,'apps/desktop/tools/asset-cooker/package.json'));
const {NodeIO}=require('@gltf-transform/core'),{ALL_EXTENSIONS}=require('@gltf-transform/extensions'),draco=require('draco3dgltf');
const manifest=JSON.parse(await readFile(resolve(repo,'assets/office-desktop.json'),'utf8'));
const source=manifest.path;
const document=await new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({'draco3d.decoder':await draco.createDecoderModule()}).read(resolve(repo,source));
const seats=[
  {x:1.682,z:4.243,yaw:.0013,box:[1.32,2.05,3.89,4.59]},
  {x:5.157,z:2.781,yaw:-.0151,box:[4.79,5.52,2.43,3.13]},
  {x:-2.008,z:2.157,yaw:3.1053,box:[-2.37,-1.64,1.81,2.51]},
  {x:3.252,z:.540,yaw:1.7097,box:[2.90,3.60,.17,.91]},
  {x:1.750,z:.520,yaw:-1.7620,box:[1.40,2.10,.15,.89]},
  {x:-6.019,z:-.665,yaw:-Math.PI/2,box:[-6.38,-5.67,-1.04,-.30]},
  {x:-.854,z:-1.075,yaw:3.0795,box:[-1.22,-.49,-1.42,-.73]},
  {x:5.163,z:-1.445,yaw:-3.1329,box:[4.80,5.53,-1.79,-1.10]},
  {x:2.158,z:-3.190,yaw:3.1079,box:[1.79,2.52,-3.54,-2.84]},
];
const transform=(m,v)=>[-(m[0]*v[0]+m[4]*v[1]+m[8]*v[2]+m[12]),m[1]*v[0]+m[5]*v[1]+m[9]*v[2]+m[13],-(m[2]*v[0]+m[6]*v[1]+m[10]*v[2]+m[14])];
const clip=(poly,y,sign)=>{const out=[];for(let i=0;i<poly.length;i++){const a=poly[i],b=poly[(i+1)%poly.length],da=sign*(a[1]-y),db=sign*(b[1]-y);if(da>=0)out.push(a);if((da>=0)!==(db>=0)){const t=da/(da-db);out.push(a.map((v,k)=>v+t*(b[k]-v)));}}return out;};
const distance=(x,z,poly)=>{let inside=false,min=Infinity;for(let i=0;i<poly.length;i++){const a=poly[i],b=poly[(i+1)%poly.length],dx=b[0]-a[0],dz=b[2]-a[2],t=Math.max(0,Math.min(1,((x-a[0])*dx+(z-a[2])*dz)/(dx*dx+dz*dz||1)));min=Math.min(min,Math.hypot(x-a[0]-t*dx,z-a[2]-t*dz));if((a[2]>z)!==(b[2]>z)&&x<(b[0]-a[0])*(z-a[2])/(b[2]-a[2])+a[0])inside=!inside;}return inside?0:min;};
const round=n=>Math.round(n*10000)/10000;
const triangles=[];
const chairVertices=seats.map(()=>[]);
for(const node of document.getRoot().listNodes()) {
  if(!node.getMesh())continue;
  const matrix=node.getWorldMatrix();
  for(const primitive of node.getMesh().listPrimitives()) {
    const positions=primitive.getAttribute('POSITION'),indices=primitive.getIndices(),material=primitive.getMaterial()?.getName()||'';
    for(let i=0;i<(indices?.getCount()||positions.getCount());i+=3) {
      const triangle=[0,1,2].map(k=>transform(matrix,positions.getElement(indices?indices.getScalar(i+k):i+k,[])));
      let chair=-1;
      if(/^chair_[0-8]$/.test(node.getName()))chair=Number(node.getName().slice(6));
      if(chair>=0)chairVertices[chair].push(...triangle);
      const polygon=clip(clip(triangle,.12,1),1.55,-1);
      if(!polygon.length)continue;
      triangles.push({name:node.getName(),material,chair,polygon,minX:Math.min(...polygon.map(p=>p[0])),maxX:Math.max(...polygon.map(p=>p[0])),minZ:Math.min(...polygon.map(p=>p[2])),maxZ:Math.max(...polygon.map(p=>p[2]))});
    }
  }
}
function measure(index,rollback) {
  const s=seats[index],fx=-Math.sin(s.yaw),fz=-Math.cos(s.yaw),x=s.x+fx*(.4025-rollback),z=s.z+fz*(.4025-rollback);
  let closest={distance:Infinity};
  for(const triangle of triangles) {
    if(triangle.chair===index)continue;
    const broad=Math.hypot(Math.max(triangle.minX-x,0,x-triangle.maxX),Math.max(triangle.minZ-z,0,z-triangle.maxZ));
    if(broad>=closest.distance)continue;
    const d=distance(x,z,triangle.polygon);
    if(d<closest.distance)closest={distance:d,name:triangle.name,material:triangle.material,otherChair:triangle.chair};
  }
  const vertices=chairVertices[index].map(p=>[p[0]-fx*rollback,p[1],p[2]-fz*rollback]);
  const range=k=>[vertices.reduce((v,p)=>Math.min(v,p[k]),Infinity),vertices.reduce((v,p)=>Math.max(v,p[k]),-Infinity)];
  const boundX=range(0),boundZ=range(2);
  return {rollback:round(rollback),standingNativeXZ:[round(x),round(z)],clearance:round(closest.distance),clear35:closest.distance>=.35,closest,
    chairCenterNativeXZ:[round(s.x-fx*rollback),round(s.z-fz*rollback)],movedChairBounds:{x:boundX.map(round),z:boundZ.map(round)},
    chairCenterWithinNavRectangle:s.x-fx*rollback>=-6.95&&s.x-fx*rollback<=6.60&&s.z-fz*rollback>=-6&&s.z-fz*rollback<=6,
  };
}
const report={source,bodySlab:[.12,1.55],standingAdvance:.4025,radius:.35,
  note:'Exact projected triangle distance in the body slab, excluding only the actor-owned chair geometry. Chair-end bounds are reported separately; this is not a full swept 3D chair-mesh collision proof.',
  seats:seats.map((s,index)=>{const values=[.5,.6,.7,.8,.9,.92,.93].map(d=>measure(index,d));let minimum=null;for(let d=0;d<=1.501;d+=.01){const m=measure(index,d);if(m.clear35&&m.chairCenterWithinNavRectangle){minimum=m;break;}}return{index,socketNativeXZ:[s.x,s.z],yaw:s.yaw,ownChairTriangleCount:chairVertices[index].length/3,configured:measure(index,manifest.navigation.sockets[`desk_${index}`].pullback),values,minimumAtCentimeterResolution:minimum};})};
await writeFile(resolve(here,'chair-clearance.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report.seats.map(s=>({index:s.index,chairTriangles:s.ownChairTriangleCount,minimum:s.minimumAtCentimeterResolution,at:[.5,.6,.7,.8,.9,.92,.93].map((d,i)=>({rollback:d,clearance:s.values[i].clearance,blocker:s.values[i].closest.name}))})),null,2));
