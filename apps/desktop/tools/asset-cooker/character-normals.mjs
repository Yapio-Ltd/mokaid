/** Repair inconsistent surface orientation before baking character lighting.
 * UV seams are connected only when their positions and skin influences agree.
 * Nonmanifold edges are boundaries. Creases remain split unless the source
 * explicitly authored a continuous normal field across the coarse geometry.
 */
const dot=(a,b)=>a[0]*b[0]+a[1]*b[1]+a[2]*b[2];
const cross=(a,b)=>[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
const sub=(a,b)=>a.map((v,i)=>v-b[i]);
const mul=(a,s)=>a.map(v=>v*s);
const unit=(v,fallback=[0,1,0])=>{const l=Math.hypot(...v);return l>1e-15&&Number.isFinite(l)?mul(v,1/l):fallback;};

export function prepareCharacterNormals(document,{creaseAngle=Math.PI/3}={}) {
  const report={primitives:0,flippedTriangles:0,splitVertices:0,degenerateTriangles:0,ambiguousComponents:0,authoredSmoothEdges:0,headSmoothEdges:0};
  const visited=new Set();
  for(const node of document.getRoot().listNodes()) {
    const mesh=node.getMesh();
    if(!node.getSkin()||!mesh||/coffee|cup|mug|phone|prop/i.test(`${node.getName()} ${mesh.getName()}`))continue;
    for(const primitive of mesh.listPrimitives()) {
      if(visited.has(primitive)||primitive.getMode()!==4)continue;
      visited.add(primitive);
      const position=primitive.getAttribute('POSITION'),sourceNormal=primitive.getAttribute('NORMAL');
      const joints=primitive.getAttribute('JOINTS_0'),weights=primitive.getAttribute('WEIGHTS_0');
      if(!position||!joints||!weights)continue;
      const count=position.getCount(),positions=Array.from({length:count},(_,i)=>position.getElement(i,[]));
      const sourceNormals=Array.from({length:count},(_,i)=>sourceNormal?.getElement(i,[])??[0,1,0]);
      const skinJoints=node.getSkin().listJoints();
      const headNode=skinJoints.find(joint=>/(?:^|[|/:])head(?:\.x)?$/i.test(joint.getName()));
      const headJoints=new Set();
      if(headNode)skinJoints.forEach((joint,index)=>{
        for(let ancestor=joint;ancestor;ancestor=ancestor.getParentNode())if(ancestor===headNode){headJoints.add(index);break;}
      });
      const headVertices=Array.from({length:count},(_,i)=>{
        if(!headJoints.size)return false;
        const ids=joints.getElement(i,[]),influence=weights.getElement(i,[]);
        return ids.reduce((sum,id,slot)=>sum+(headJoints.has(id)?influence[slot]:0),0)>.35;
      });
      // Draco may decode the two sides of a UV seam one quantization step
      // apart. A very small spatial tolerance joins normals only, never moves
      // geometry, and still keeps nearby eyelids / garment layers separate.
      const low=[Infinity,Infinity,Infinity],high=[-Infinity,-Infinity,-Infinity];
      for(const p of positions)for(let k=0;k<3;k++){low[k]=Math.min(low[k],p[k]);high[k]=Math.max(high[k],p[k]);}
      const epsilon=Math.max(1e-8,Math.hypot(...sub(high,low))/32768);
      const buckets=new Map(),representatives=[],weld=[];
      for(let i=0;i<count;i++) {
        const js=joints.getElement(i,[]),ws=weights.getElement(i,[]),influences=new Map();
        js.forEach((j,k)=>{if(ws[k]>1e-7)influences.set(j,(influences.get(j)??0)+ws[k]);});
        const p=positions[i],cell=p.map(v=>Math.floor(v/epsilon));let match=-1,best=epsilon*epsilon;
        for(let x=-1;x<=1;x++)for(let y=-1;y<=1;y++)for(let z=-1;z<=1;z++) {
          const key=[cell[0]+x,cell[1]+y,cell[2]+z].join(',');
          for(const candidate of buckets.get(key)??[]) {
            const r=representatives[candidate],d=sub(p,r.p),distance=dot(d,d);
            if(distance>best)continue;
            const allJoints=new Set([...influences.keys(),...r.influences.keys()]);
            if([...allJoints].some(j=>Math.abs((influences.get(j)??0)-(r.influences.get(j)??0))>.0003))continue;
            match=candidate;best=distance;
          }
        }
        if(match<0) {
          match=representatives.length;representatives.push({p,influences});
          const key=cell.join(',');if(!buckets.has(key))buckets.set(key,[]);buckets.get(key).push(match);
        }
        weld.push(match);
      }
      const index=primitive.getIndices();
      const ids=index?Array.from({length:index.getCount()},(_,i)=>index.getScalar(i)):Array.from({length:count},(_,i)=>i);
      const faces=[],edges=new Map();
      for(let i=0;i+2<ids.length;i+=3) {
        const v=ids.slice(i,i+3),g=v.map(id=>weld[id]);
        const area=cross(sub(positions[v[1]],positions[v[0]]),sub(positions[v[2]],positions[v[0]]));
        const valid=new Set(g).size===3&&Math.hypot(...area)>1e-15;
        const f={v,g,area,n:unit(area),valid,neighbors:[],sign:0,component:-1};faces.push(f);
        if(!valid){report.degenerateTriangles++;continue;}
        for(let c=0;c<3;c++) {
          const a=g[c],b=g[(c+1)%3],key=a<b?`${a}/${b}`:`${b}/${a}`;
          if(!edges.has(key))edges.set(key,[]);
          edges.get(key).push({face:faces.length-1,a,b,corner:c});
        }
      }
      for(const edge of edges.values())if(edge.length===2) {
        const [a,b]=edge,relative=a.a===b.a?-1:1;
        faces[a.face].neighbors.push([b.face,relative]);faces[b.face].neighbors.push([a.face,relative]);
      }
      const components=[];
      for(let seed=0;seed<faces.length;seed++) {
        if(!faces[seed].valid||faces[seed].sign)continue;
        const component={faces:[],closed:true,conflict:false};const queue=[seed];faces[seed].sign=1;
        for(let q=0;q<queue.length;q++) {
          const id=queue[q],f=faces[id];f.component=components.length;component.faces.push(id);
          if(f.neighbors.length!==3)component.closed=false;
          for(const [next,relative]of f.neighbors) {
            const expected=f.sign*relative;
            if(!faces[next].sign){faces[next].sign=expected;queue.push(next);}
            else if(faces[next].sign!==expected)component.conflict=true;
          }
        }
        let volume=0,vote=0,voteMagnitude=0;
        const origin=positions[faces[seed].v[0]];
        for(const id of component.faces) {
          const f=faces[id],a=sub(positions[f.v[0]],origin),b=sub(positions[f.v[1]],origin),c=sub(positions[f.v[2]],origin);
          volume+=dot(a,cross(b,c))*f.sign;
          for(const v of f.v){const contribution=dot(f.area,sourceNormals[v])*f.sign;vote+=contribution;voteMagnitude+=Math.abs(contribution);}
        }
        // Closed components have an unambiguous exterior. Open surfaces retain
        // the authored majority orientation (e.g. an eyelid or jacket lapel).
        const seedFace=faces[seed];
        const seedVote=seedFace.v.reduce((sum,v)=>sum+dot(seedFace.area,sourceNormals[v]),0);
        const openVote=Math.abs(vote)>voteMagnitude*1e-4?vote:seedVote;
        const flip=(component.closed&&!component.conflict&&Math.abs(volume)>1e-15?volume:openVote)<0?-1:1;
        if(component.conflict)report.ambiguousComponents++;
        for(const id of component.faces)faces[id].sign*=flip;
        components.push(component);
      }
      // Corner islands let a shared source vertex acquire separate normals at
      // a real crease without modifying UVs, weights or any other attributes.
      const parent=Array.from({length:faces.length*3},(_,i)=>i);
      const find=i=>{while(parent[i]!==i){parent[i]=parent[parent[i]];i=parent[i];}return i;};
      const merge=(a,b)=>{a=find(a);b=find(b);if(a!==b)parent[b]=a;};
      const cosine=Math.cos(creaseAngle);
      for(const edge of edges.values())if(edge.length===2) {
        const [a,b]=edge,fa=faces[a.face],fb=faces[b.face];
        // A contradictory edge in an imported nonorientable patch stays split;
        // it must not turn the entire otherwise smooth body into flat shading.
        if(fa.sign*fb.sign!==(a.a===b.a?-1:1))continue;
        if(dot(fa.n,fb.n)*fa.sign*fb.sign<cosine) {
          // The stock rigs identify their facial/hair surface explicitly.
          // Smooth its connected triangle fan even when coarse eyelid/cheek
          // geometry exceeds the garment crease angle. Separate eye/lip shells
          // and nonmanifold boundaries still never merge.
          const headSurface=fa.v.every(v=>headVertices[v])&&fb.v.every(v=>headVertices[v]);
          // Low-poly cheeks and curls can turn sharply while their authored
          // shading is smooth. Preserve that intention after correcting the
          // winding sign; do not impose artificial rectangular facial creases.
          // Tangential/invalid source normals are not evidence of continuity.
          const authoredSmooth=[a.a,a.b].every(g=>{
            const na=unit(sourceNormals[fa.v[fa.g.indexOf(g)]]),nb=unit(sourceNormals[fb.v[fb.g.indexOf(g)]]);
            const da=dot(na,fa.n),db=dot(nb,fb.n);
            return Math.abs(da)>.25&&Math.abs(db)>.25&&dot(na,nb)*Math.sign(da*db)*fa.sign*fb.sign>.8;
          });
          if(!headSurface&&!authoredSmooth)continue;
          if(headSurface)report.headSmoothEdges++;
          else report.authoredSmoothEdges++;
        }
        for(const g of [a.a,a.b])merge(a.face*3+fa.g.indexOf(g),b.face*3+fb.g.indexOf(g));
      }
      const sums=new Map();
      for(let fi=0;fi<faces.length;fi++) {
        const f=faces[fi];
        if(!f.valid)continue;
        for(let c=0;c<3;c++) {
          const p=positions[f.v[c]],a=unit(sub(positions[f.v[(c+1)%3]],p)),b=unit(sub(positions[f.v[(c+2)%3]],p));
          const weight=Math.acos(Math.max(-1,Math.min(1,dot(a,b))));
          const key=find(fi*3+c),sum=sums.get(key)??[0,0,0];
          for(let k=0;k<3;k++)sum[k]+=f.n[k]*f.sign*weight;
          sums.set(key,sum);
        }
      }
      const remap=new Map(),sourceIds=[],normals=[],output=[];
      for(let fi=0;fi<faces.length;fi++) {
        const f=faces[fi],corners=f.sign<0?[0,2,1]:[0,1,2];
        if(f.sign<0)report.flippedTriangles++;
        for(const c of corners) {
          const source=f.v[c],island=find(fi*3+c),key=`${source}/${island}`;
          if(!remap.has(key)) {
            remap.set(key,sourceIds.length);sourceIds.push(source);
            normals.push(...unit(sums.get(island)??sourceNormals[source]));
          }
          output.push(remap.get(key));
        }
      }
      // Preserve unreferenced vertices too, so their authored bounds survive.
      const referenced=new Set(sourceIds);
      for(let i=0;i<count;i++)if(!referenced.has(i)){sourceIds.push(i);normals.push(...unit(sourceNormals[i]));}
      const copyAccessor=accessor=>{
        const array=accessor.getArray(),size=accessor.getElementSize(),copy=new array.constructor(sourceIds.length*size);
        sourceIds.forEach((source,i)=>copy.set(array.subarray(source*size,(source+1)*size),i*size));
        return document.createAccessor().copy(accessor).setArray(copy);
      };
      for(const semantic of primitive.listSemantics())if(semantic!=='NORMAL')primitive.setAttribute(semantic,copyAccessor(primitive.getAttribute(semantic)));
      for(const target of primitive.listTargets())for(const semantic of target.listSemantics())target.setAttribute(semantic,copyAccessor(target.getAttribute(semantic)));
      const buffer=position.getBuffer()??document.getRoot().listBuffers()[0]??document.createBuffer();
      primitive.setAttribute('NORMAL',document.createAccessor('Coherent character normals').setType('VEC3').setBuffer(buffer).setArray(new Float32Array(normals)));
      primitive.setIndices(document.createAccessor('Coherent character triangles').setType('SCALAR').setBuffer(buffer).setArray(new Uint32Array(output)));
      report.primitives++;report.splitVertices+=Math.max(0,sourceIds.length-count);
    }
  }
  return report;
}
