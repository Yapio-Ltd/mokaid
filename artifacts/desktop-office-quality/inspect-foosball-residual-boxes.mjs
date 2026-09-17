/** Exact source/final triangle evidence for four former foosball raster boxes. */
import {createRequire} from 'node:module';
import {readFile,writeFile} from 'node:fs/promises';
import {dirname,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const here=dirname(fileURLToPath(import.meta.url)),repo=resolve(here,'../..');
const require=createRequire(resolve(repo,'apps/desktop/tools/asset-cooker/package.json'));
const {NodeIO}=require('@gltf-transform/core'),{ALL_EXTENSIONS}=require('@gltf-transform/extensions'),draco=require('draco3dgltf');
const io=new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({'draco3d.decoder':await draco.createDecoderModule()});
const manifest=JSON.parse(await readFile(resolve(repo,'assets/office-desktop.json'),'utf8'));
const boxes=[{id:176,x:[-2.35,-2.25],z:[-5.35,-4.15]},{id:178,x:[-2.35,-1.25],z:[-4.15,-4.05]},{id:179,x:[-2.25,-1.35],z:[-5.35,-5.25]},{id:186,x:[-1.45,-1.25],z:[-5.05,-4.15]}];
const transform=(m,v)=>[-(m[0]*v[0]+m[4]*v[1]+m[8]*v[2]+m[12]),m[1]*v[0]+m[5]*v[1]+m[9]*v[2]+m[13],-(m[2]*v[0]+m[6]*v[1]+m[10]*v[2]+m[14])];
const clip=(poly,k,value,sign)=>{const out=[];for(let i=0;i<poly.length;i++){const a=poly[i],b=poly[(i+1)%poly.length],da=sign*(a[k]-value),db=sign*(b[k]-value);if(da>=0)out.push(a);if((da>=0)!==(db>=0)){const t=da/(da-db);out.push(a.map((v,j)=>v+t*(b[j]-v)));}}return out;};
const pointPoly=(p,poly)=>{let min=Infinity,inside=false;for(let i=0;i<poly.length;i++){const a=poly[i],b=poly[(i+1)%poly.length],dx=b[0]-a[0],dz=b[2]-a[2],t=Math.max(0,Math.min(1,((p[0]-a[0])*dx+(p[2]-a[2])*dz)/(dx*dx+dz*dz||1)));min=Math.min(min,Math.hypot(p[0]-a[0]-t*dx,p[2]-a[2]-t*dz));if((a[2]>p[2])!==(b[2]>p[2])&&p[0]<(b[0]-a[0])*(p[2]-a[2])/(b[2]-a[2])+a[0])inside=!inside;}return inside?0:min;};
const distance=(box,poly)=>{
  let inside=clip(clip(clip(clip(poly,0,box.x[0],1),0,box.x[1],-1),2,box.z[0],1),2,box.z[1],-1);
  if(inside.length)return 0;
  let minimum=Infinity;
  for(const p of poly)minimum=Math.min(minimum,Math.hypot(Math.max(box.x[0]-p[0],0,p[0]-box.x[1]),Math.max(box.z[0]-p[2],0,p[2]-box.z[1])));
  for(const x of box.x)for(const z of box.z)minimum=Math.min(minimum,pointPoly([x,0,z],poly));
  return minimum;
};
async function inspect(source){
  const document=await io.read(resolve(repo,source));
  const results=boxes.map(box=>({...box,intersectingTriangleCount:0,intersectionsWithinOriginalTableBounds:0,intersectingMeshes:{},closest:{distance:Infinity}}));
  for(const node of document.getRoot().listNodes()){
    if(!node.getMesh())continue;
    const matrix=node.getWorldMatrix();
    for(const primitive of node.getMesh().listPrimitives()){
      const positions=primitive.getAttribute('POSITION'),indices=primitive.getIndices(),material=primitive.getMaterial()?.getName();
      for(let i=0;i<(indices?.getCount()||positions.getCount());i+=3){
        const triangle=[0,1,2].map(k=>transform(matrix,positions.getElement(indices?indices.getScalar(i+k):i+k,[])));
        const polygon=clip(clip(triangle,1,.12,1),1,1.55,-1);if(!polygon.length)continue;
        for(const result of results){
          const d=distance(result,polygon);
          if(d===0){result.intersectingTriangleCount++;if(node.getName()==='wall 1'&&triangle.every(p=>p[0]>=-2.28&&p[0]<=-1.42&&p[2]>=-5.22&&p[2]<=-4.13&&p[1]>=-.03&&p[1]<=.65))result.intersectionsWithinOriginalTableBounds++;const key=`${node.getName()} / ${material}`;result.intersectingMeshes[key]=(result.intersectingMeshes[key]||0)+1;}
          if(d<result.closest.distance)result.closest={distance:d,node:node.getName(),material,triangle};
        }
      }
    }
  }
  return {source,boxes:results};
}
const report={method:'Actual triangles clipped to native body band Y .12..1.55, then clipped against exact XZ rectangle. No collider removed or modified.',source:await inspect(manifest.sourcePath),final:await inspect(manifest.path)};
await writeFile(resolve(here,'foosball-residual-boxes.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify([report.source,report.final].map(r=>({source:r.source,boxes:r.boxes.map(({closest,...box})=>({...box,closest:{distance:closest.distance,node:closest.node,material:closest.material}}))})),null,2));
