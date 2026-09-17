/** Geometric evidence only; this script does not change navigation or GLBs. */
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
const require = createRequire(resolve(repo, 'apps/desktop/tools/asset-cooker/package.json'));
const { NodeIO } = require('@gltf-transform/core');
const { ALL_EXTENSIONS } = require('@gltf-transform/extensions');
const draco = require('draco3dgltf');
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({ 'draco3d.decoder': await draco.createDecoderModule() });
const manifest = JSON.parse(await readFile(resolve(repo, 'assets/office-desktop.json'), 'utf8'));
const document = await io.read(resolve(repo, manifest.path));
const proposedTable = process.argv.includes('--proposed-table');
const deskAudit = process.argv.includes('--desks');
let movedTriangles=0;
const transform = (m, v) => [-(m[0]*v[0]+m[4]*v[1]+m[8]*v[2]+m[12]),m[1]*v[0]+m[5]*v[1]+m[9]*v[2]+m[13],-(m[2]*v[0]+m[6]*v[1]+m[10]*v[2]+m[14])];
const bounds = (points) => ({ min: [0,1,2].map(k=>points.reduce((v,p)=>Math.min(v,p[k]),Infinity)), max:[0,1,2].map(k=>points.reduce((v,p)=>Math.max(v,p[k]),-Infinity)) });
const round = v => Math.round(v*10000)/10000;
const clip = (polygon, y, sign) => {
  const result=[];
  for(let i=0;i<polygon.length;i++) {
    const a=polygon[i],b=polygon[(i+1)%polygon.length],da=sign*(a[1]-y),db=sign*(b[1]-y);
    if(da>=0)result.push(a);
    if((da>=0)!==(db>=0)){const t=da/(da-db);result.push(a.map((v,k)=>v+t*(b[k]-v)));}
  }
  return result;
};
const pointSegment = (p,a,b) => {
  const dx=b[0]-a[0],dz=b[2]-a[2];
  const t=Math.max(0,Math.min(1,((p[0]-a[0])*dx+(p[2]-a[2])*dz)/(dx*dx+dz*dz||1)));
  return Math.hypot(p[0]-a[0]-dx*t,p[2]-a[2]-dz*t);
};
const projectedDistance = (p,poly) => {
  let inside=false,min=Infinity;
  for(let i=0;i<poly.length;i++) {
    const a=poly[i],b=poly[(i+1)%poly.length];
    if((a[2]>p[2])!==(b[2]>p[2])&&p[0]<(b[0]-a[0])*(p[2]-a[2])/(b[2]-a[2])+a[0])inside=!inside;
    min=Math.min(min,pointSegment(p,a,b));
  }
  return inside?0:min;
};
const targets=deskAudit ? [
  {id:'desk8-socket',point:[2.158,0,-3.190]},
  {id:'desk8-back-near',point:[2.158,0,-3.70]},
  {id:'desk8-back-far',point:[2.158,0,-4.00]},
  {id:'desk8-left-exit',point:[1.45,0,-3.70]},
  {id:'desk8-right-exit',point:[3.05,0,-3.70]},
  {id:'desk5-socket',point:[-6.019,0,-.665]},
  {id:'desk5-back',point:[-6.330,0,-1.178]},
] : proposedTable ? [
  {id:'new-west-player',point:[-4.2308,0,-4.67]},
  {id:'new-east-player',point:[-1.9772,0,-4.67]},
  {id:'new-west-approach',point:[-4.30,0,-4.67]},
  {id:'new-east-approach',point:[-1.88,0,-4.67]},
  {id:'new-south-approach',point:[-3.10,0,-3.30]},
] : [{id:'west-player',point:[-2.72,0,-4.67]},{id:'east-player',point:[-.97,0,-4.67]},
  {id:'east-near',point:[-.97,0,-4.15]},{id:'east-far',point:[-.97,0,-5.15]},
  {id:'old-south-end',point:[-1.845,0,-3.68]}];
const nearest=targets.map(t=>({...t,meshes:[]}));
const components=[];
const seatCushions=[];
for(const node of document.getRoot().listNodes()) {
  const mesh=node.getMesh();if(!mesh)continue;
  const matrix=node.getWorldMatrix();
  const triangles=[];
  for(const primitive of mesh.listPrimitives()) {
    const positions=primitive.getAttribute('POSITION'),indices=primitive.getIndices();
    for(let i=0;i<(indices?.getCount()||positions.getCount());i+=3) {
      let triangle=[0,1,2].map(k=>transform(matrix,positions.getElement(indices?indices.getScalar(i+k):i+k,[])));
      if(proposedTable && node.getName()==='wall 1' && triangle.every(p=>p[0]>=-2.28&&p[0]<=-1.42&&p[2]>=-5.22&&p[2]<=-4.13&&p[1]>=-.03&&p[1]<=.65)) {
        triangle=triangle.map(p=>[-3.10+(p[0]+1.845)*1.6,p[1]*1.6,-4.67+(p[2]+4.67)*1.6]);
        movedTriangles++;
      }
      const clipped=clip(clip(triangle,.12,1),1.55,-1);
      triangles.push({triangle,clipped,material:primitive.getMaterial()?.getName()||''});
    }
  }
  for(let i=0;i<targets.length;i++) {
    let closest=null;
    for(const t of triangles) {
      if(!t.clipped.length)continue;
      const distance=projectedDistance(targets[i].point,t.clipped);
      if(!closest||distance<closest.distance)closest={name:node.getName(),material:t.material,distance,triangle:t.triangle};
    }
    if(closest&&closest.distance<1)nearest[i].meshes.push({...closest,distance:round(closest.distance),triangle:closest.triangle.map(p=>p.map(round))});
  }
  if(deskAudit&&node.getName()==='Object_122.012')for(const target of [[-6.019,-.665],[-6.03,.197]]) {
    let sum=0,count=0,center=[0,0,0];const points=[];
    for(const {triangle:q,material} of triangles) {
      if(!material.includes('Leather')||q.some(p=>p[1]<.43||p[1]>.65))continue;
      const u=q[1].map((v,k)=>v-q[0][k]),v=q[2].map((x,k)=>x-q[0][k]);
      const cross=[u[1]*v[2]-u[2]*v[1],u[2]*v[0]-u[0]*v[2],u[0]*v[1]-u[1]*v[0]],area=Math.hypot(...cross)/2;
      const centroid=[0,1,2].map(k=>(q[0][k]+q[1][k]+q[2][k])/3);
      if(cross[1]/(area*2)<.7||Math.hypot(centroid[0]-target[0],centroid[2]-target[1])>.4)continue;
      count++;sum+=area;points.push(...q);center=center.map((n,k)=>n+area*centroid[k]);
    }
    if(sum>0){const b=bounds(points);seatCushions.push({node:node.getName(),targetNativeXZ:target,upwardTriangles:count,area:round(sum),centroid:center.map(n=>round(n/sum)),bounds:{min:b.min.map(round),max:b.max.map(round)}});}
  }
  if(deskAudit ? !['wall 1','Plane.005','Object_122.012','instance_3','Cube.003'].includes(node.getName()) : node.getName()!=='wall 1')continue;
  // Weld only coincident positions for a topological connected-component audit.
  const parent=triangles.map((_,i)=>i),owners=new Map();
  const find=i=>{while(parent[i]!==i){parent[i]=parent[parent[i]];i=parent[i];}return i;};
  for(let i=0;i<triangles.length;i++)for(const p of triangles[i].triangle){
    const key=p.map(v=>Math.round(v*10000)).join(',');
    if(owners.has(key))parent[find(i)]=find(owners.get(key));else owners.set(key,i);
  }
  const groups=new Map();
  for(let i=0;i<triangles.length;i++){const root=find(i);if(!groups.has(root))groups.set(root,[]);groups.get(root).push(triangles[i]);}
  for(const group of groups.values()){
    const points=group.flatMap(t=>t.clipped);if(!points.length)continue;
    const b=bounds(points);
    const relevant=deskAudit
      ? ((b.min[0]<3.8&&b.max[0]>.4&&b.min[2]<-1.8&&b.max[2]>-4.8)||(b.min[0]<-5.4&&b.max[0]>-6.8&&b.min[2]<.7&&b.max[2]>-1.6))
      : b.min[0]<=1.3&&b.max[0]>=-3.5&&b.min[2]<=-1.8&&b.max[2]>=-5.6;
    if(!relevant)continue;
    components.push({node:node.getName(),triangles:group.length,bodySlabBounds:{min:b.min.map(round),max:b.max.map(round)},distanceToSecondTarget:round(Math.min(...group.filter(t=>t.clipped.length).map(t=>projectedDistance(targets[1].point,t.clipped))))});
  }
}
for(const target of nearest)target.meshes.sort((a,b)=>a.distance-b.distance);
const report={source:manifest.path,proposedTable,deskAudit,movedTriangles,coordinates:'Native right-handed X,Y,Z',bodySlab:[.12,1.55],note:'Distances are between horizontal point and triangle projection clipped to body slab; components weld positions at0.1mm. Proposed table, when enabled, virtually scales only the original isolated foosball triangle bounds1.6x and translates its center to(-3.10,-4.67).',nearest,components,seatCushions};
await writeFile(resolve(here,deskAudit?'desk-egress-geometry.json':proposedTable?'foosball-proposed-geometry.json':'foosball-geometry.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));
