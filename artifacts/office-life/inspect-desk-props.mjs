/** Vertical intersections against the actual native room, for authored props. */
import {createRequire} from 'node:module';
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
const repo=process.cwd(),req=createRequire(resolve(repo,'apps/desktop/tools/asset-cooker/package.json'));
const {NodeIO}=req('@gltf-transform/core'),{ALL_EXTENSIONS}=req('@gltf-transform/extensions'),draco=req('draco3dgltf');
const manifest=JSON.parse(await readFile('assets/office-desktop.json','utf8'));
const doc=await new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({'draco3d.decoder':await draco.createDecoderModule()}).read(manifest.path);
const seats=[[1.682,4.243,.0013],[5.157,2.781,-.0151],[-2.008,2.157,3.1053],[3.252,.540,1.7097],[1.750,.520,-1.7620],[-6.019,-.665,-Math.PI/2],[-.854,-1.075,3.0795],[5.163,-1.445,-3.1329],[2.158,-3.190,3.1079]];
const queries=seats.flatMap(([x,z,yaw],seat)=>[.4,.5,.6,.7].flatMap(forward=>[-.3,-.2,0,.2,.3].map(right=>({seat,forward,right,point:[x-Math.sin(yaw)*forward+Math.cos(yaw)*right,z-Math.cos(yaw)*forward-Math.sin(yaw)*right],hits:[]}))));
queries.push(...[.5,.55,.6,.65,.7,.8].flatMap(forward=>[-.3,-.2,-.1,0,.1,.2,.3].map(right=>({seat:'coffee',forward,right,point:[-1.79-right,5.08+forward],hits:[]}))));
const transform=(m,v)=>[-(m[0]*v[0]+m[4]*v[1]+m[8]*v[2]+m[12]),m[1]*v[0]+m[5]*v[1]+m[9]*v[2]+m[13],-(m[2]*v[0]+m[6]*v[1]+m[10]*v[2]+m[14])];
for(const node of doc.getRoot().listNodes()) {
 if(!node.getMesh())continue;
 const matrix=node.getWorldMatrix();
 for(const p of node.getMesh().listPrimitives()){
  const pos=p.getAttribute('POSITION'),ind=p.getIndices();
  for(let i=0;i<(ind?.getCount()||pos.getCount());i+=3){
   const [a,b,c]=[0,1,2].map(k=>transform(matrix,pos.getElement(ind?ind.getScalar(i+k):i+k,[])));
   if(Math.min(a[1],b[1],c[1])<.6||Math.max(a[1],b[1],c[1])>1.6||Math.max(a[1],b[1],c[1])-Math.min(a[1],b[1],c[1])>.025)continue;
   const den=(b[2]-c[2])*(a[0]-c[0])+(c[0]-b[0])*(a[2]-c[2]);if(Math.abs(den)<1e-10)continue;
   for(const q of queries){const[x,z]=q.point,u=((b[2]-c[2])*(x-c[0])+(c[0]-b[0])*(z-c[2]))/den,v=((c[2]-a[2])*(x-c[0])+(a[0]-c[0])*(z-c[2]))/den,w=1-u-v;
    if(u>=0&&v>=0&&w>=0)q.hits.push({node:node.getName(),material:p.getMaterial()?.getName(),height:u*a[1]+v*b[1]+w*c[1]});
   }
  }
 }
}
await writeFile('artifacts/office-life/desk-prop-surfaces.json',JSON.stringify({source:manifest.path,queries},null,2)+'\n');
for(const seat of [...Array(9).keys(),'coffee'])console.log(JSON.stringify({seat,points:queries.filter(q=>q.seat===seat&&q.right===(seat==='coffee'?-.2:.2)).map(q=>({f:q.forward,r:q.right,h:q.hits}))}));
