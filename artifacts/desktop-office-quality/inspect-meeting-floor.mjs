/** Read-only floor-height verification at meeting-room action sockets. */
import {createRequire} from 'node:module';
import {readFile, writeFile} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
const req = createRequire(resolve(repo, 'apps/desktop/tools/asset-cooker/package.json'));
const {NodeIO} = req('@gltf-transform/core');
const {ALL_EXTENSIONS} = req('@gltf-transform/extensions');
const draco = req('draco3dgltf');
const source = process.argv[2] || JSON.parse(await readFile(resolve(repo,'assets/office-desktop.json'),'utf8')).path;
const doc = await new NodeIO().registerExtensions(ALL_EXTENSIONS)
  .registerDependencies({'draco3d.decoder': await draco.createDecoderModule()})
  .read(resolve(repo, source));
const queries = [
  {label:'seat5 original socket', point:[-6.019,-.665]},
  {label:'seat5 rolled back .925 m', point:[-6.944,-.665]},
  {label:'seat5 standing after .4025 m advance', point:[-6.5415,-.665]},
  {label:'meeting table center', point:[-5.72,-.17]},
  {label:'meeting-room aisle', point:[-5.5,-2]},
];
const results = queries.map(q=>({...q,hits:[]}));
const transform = (m,v)=>[-(m[0]*v[0]+m[4]*v[1]+m[8]*v[2]+m[12]),m[1]*v[0]+m[5]*v[1]+m[9]*v[2]+m[13],-(m[2]*v[0]+m[6]*v[1]+m[10]*v[2]+m[14])];
for (const node of doc.getRoot().listNodes()) {
  if (!node.getMesh()) continue;
  const matrix=node.getWorldMatrix();
  for (const primitive of node.getMesh().listPrimitives()) {
    const positions=primitive.getAttribute('POSITION'),indices=primitive.getIndices();
    for(let i=0;i<(indices?.getCount()||positions.getCount());i+=3) {
      const [a,b,c]=[0,1,2].map(k=>transform(matrix,positions.getElement(indices?indices.getScalar(i+k):i+k,[])));
      const lo=Math.min(a[1],b[1],c[1]),hi=Math.max(a[1],b[1],c[1]);
      if(lo<-.02||hi>.15||hi-lo>.015)continue;
      const denominator=(b[2]-c[2])*(a[0]-c[0])+(c[0]-b[0])*(a[2]-c[2]);
      if(Math.abs(denominator)<1e-10)continue;
      for(const result of results) {
        const [x,z]=result.point;
        const u=((b[2]-c[2])*(x-c[0])+(c[0]-b[0])*(z-c[2]))/denominator;
        const v=((c[2]-a[2])*(x-c[0])+(a[0]-c[0])*(z-c[2]))/denominator;
        const w=1-u-v;
        if(u>=-1e-6&&v>=-1e-6&&w>=-1e-6)result.hits.push({
          node:node.getName(),material:primitive.getMaterial()?.getName(),
          y:u*a[1]+v*b[1]+w*c[1],triangle:[a,b,c],
        });
      }
    }
  }
}
const report={source,method:'Barycentric vertical-ray intersections of actual triangles below Y=.15 m, with triangle height variation <=.015 m. Coordinates are native world.',results};
await writeFile(resolve(here,'meeting-floor.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(results.map(r=>({label:r.label,point:r.point,surfaces:r.hits.map(h=>({node:h.node,material:h.material,y:h.y}))})),null,2));
