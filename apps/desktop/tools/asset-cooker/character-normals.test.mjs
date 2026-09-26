import test from 'node:test';
import assert from 'node:assert/strict';
import { Document } from '@gltf-transform/core';
import { prepareCharacterNormals } from './character-normals.mjs';

function character(positions,indices,{name='Body',normals,uv,weights}={}) {
  const document=new Document(),buffer=document.createBuffer(),count=positions.length/3;
  const accessor=(type,array)=>document.createAccessor().setBuffer(buffer).setType(type).setArray(array);
  const primitive=document.createPrimitive().setAttribute('POSITION',accessor('VEC3',new Float32Array(positions)))
    .setAttribute('NORMAL',accessor('VEC3',new Float32Array(normals??positions.map((_,i)=>i%3===2?1:0))))
    .setAttribute('JOINTS_0',accessor('VEC4',new Uint16Array(count*4)))
    .setAttribute('WEIGHTS_0',accessor('VEC4',new Float32Array(weights??Array.from({length:count*4},(_,i)=>i%4===0?1:0))))
    .setIndices(accessor('SCALAR',new Uint32Array(indices)));
  if(uv)primitive.setAttribute('TEXCOORD_0',accessor('VEC2',new Float32Array(uv)));
  const joint=document.createNode('Root'),skin=document.createSkin().addJoint(joint);
  const node=document.createNode(name).setSkin(skin).setMesh(document.createMesh(name).addPrimitive(primitive));
  document.createScene().addChild(joint).addChild(node);
  return {document,primitive};
}
function normalList(primitive){const a=primitive.getAttribute('NORMAL');return Array.from({length:a.getCount()},(_,i)=>a.getElement(i,[]));}

test('repairs a reversed triangle across a UV seam without changing UV or skin values',()=>{
  const {document,primitive}=character([0,0,0,1,0,0,1,1,0,0,0,0,1,1,0,0,1,0],[0,1,2,3,5,4],
    {normals:[0,0,1,0,0,1,0,0,1,0,0,-1,0,0,-1,0,0,-1],uv:[0,0,1,0,1,1,.5,.5,0,1,1,1]});
  const before=Array.from(primitive.getAttribute('TEXCOORD_0').getArray());
  const report=prepareCharacterNormals(document);
  assert.equal(report.flippedTriangles,1);
  for(const n of normalList(primitive))assert.ok(n[2]>.999);
  const p=primitive.getAttribute('POSITION'),uv=primitive.getAttribute('TEXCOORD_0');
  // All six source vertices, including separate UV values at a shared position,
  // remain represented even though index order was repaired.
  assert.equal(p.getCount(),6);assert.deepEqual([...uv.getArray()].sort(),before.sort());
  assert.ok([...primitive.getAttribute('WEIGHTS_0').getArray()].every((v,i)=>v===(i%4===0?1:0)));
});

test('orients a closed shell outward even when all authored normals point inward',()=>{
  const {document,primitive}=character([1,1,1,-1,-1,1,-1,1,-1,1,-1,-1],[0,2,1,0,1,3,0,3,2,1,2,3],
    {normals:[-1,-1,-1,1,1,-1,1,-1,1,-1,1,1]});
  prepareCharacterNormals(document,{creaseAngle:Math.PI});
  const p=primitive.getAttribute('POSITION'),n=primitive.getAttribute('NORMAL');
  for(let i=0;i<p.getCount();i++)assert.ok(p.getElement(i,[]).reduce((s,v,k)=>s+v*n.getElement(i,[])[k],0)>0);
});

test('splits a shared vertex at a right-angle garment crease, preserving normalized attributes',()=>{
  const {document,primitive}=character([0,0,0,1,0,0,0,1,0,0,0,1],[0,1,2,1,0,3]);
  primitive.setAttribute('COLOR_0',document.createAccessor().setBuffer(document.getRoot().listBuffers()[0]).setType('VEC4').setNormalized(true).setArray(new Uint8Array([1,2,3,255,4,5,6,255,7,8,9,255,10,11,12,255])));
  const report=prepareCharacterNormals(document);
  assert.equal(report.splitVertices,2);assert.equal(primitive.getAttribute('COLOR_0').getNormalized(),true);
  assert.equal(primitive.getAttribute('COLOR_0').getArray().constructor,Uint8Array);
  const normals=normalList(primitive);
  assert.ok(normals.some(n=>n[2]>.999));assert.ok(normals.some(n=>n[1]>.999));
});

test('finite fallback for degenerate triangles, missing or zero normals; props remain untouched',()=>{
  const {document,primitive}=character([0,0,0,0,0,0,0,0,0],[0,1,2],{normals:new Array(9).fill(0)});
  assert.equal(prepareCharacterNormals(document).degenerateTriangles,1);
  for(const n of normalList(primitive))assert.ok(n.every(Number.isFinite)&&Math.abs(Math.hypot(...n)-1)<1e-6);
  const prop=character([0,0,0,1,0,0,0,1,0],[0,2,1],{name:'OfficeCoffeeCup'});
  const indices=prop.primitive.getIndices(),normal=prop.primitive.getAttribute('NORMAL');
  assert.equal(prepareCharacterNormals(prop.document).primitives,0);
  assert.equal(prop.primitive.getIndices(),indices);assert.equal(prop.primitive.getAttribute('NORMAL'),normal);
});

test('does not smooth a seam whose coincident vertices have different rig influences',()=>{
  const {document,primitive}=character([0,0,0,1,0,0,1,1,0,0,0,0,1,1,0,0,1,.2],[0,1,2,3,4,5]);
  const joints=primitive.getAttribute('JOINTS_0');for(let i=3;i<6;i++)joints.setElement(i,[1,0,0,0]);
  prepareCharacterNormals(document);
  const p=primitive.getAttribute('POSITION'),n=primitive.getAttribute('NORMAL'),atOrigin=[];
  for(let i=0;i<p.getCount();i++)if(p.getElement(i,[]).every(v=>v===0))atOrigin.push(n.getElement(i,[]));
  assert.equal(atOrigin.length,2);assert.ok(Math.abs(atOrigin[0][0]-atOrigin[1][0])>.1);
});

test('joins one-grid UV seam gaps for lighting while preserving exact positions and animation references',()=>{
  const {document,primitive}=character([0,0,0,1,0,0,1,1,0,.00002,0,0,1.00002,1,0,0,1,0],[0,1,2,3,5,4],
    {normals:[0,0,1,0,0,1,0,0,1,0,0,-1,0,0,-1,0,0,-1]});
  const before=[...primitive.getAttribute('POSITION').getArray()].sort();
  const target=document.getRoot().listNodes()[0],buffer=document.getRoot().listBuffers()[0];
  const input=document.createAccessor().setBuffer(buffer).setType('SCALAR').setArray(new Float32Array([0,1]));
  const output=document.createAccessor().setBuffer(buffer).setType('VEC3').setArray(new Float32Array([0,0,0,0,.1,0]));
  const sampler=document.createAnimationSampler().setInput(input).setOutput(output);
  const channel=document.createAnimationChannel().setTargetNode(target).setTargetPath('translation').setSampler(sampler);
  document.createAnimation('idle').addSampler(sampler).addChannel(channel);
  assert.equal(prepareCharacterNormals(document).flippedTriangles,1);
  assert.deepEqual([...primitive.getAttribute('POSITION').getArray()].sort(),before);
  for(const n of normalList(primitive))assert.ok(n[2]>.999);
  assert.equal(channel.getTargetNode(),target);assert.equal(channel.getSampler(),sampler);
  assert.equal(sampler.getInput(),input);assert.equal(sampler.getOutput(),output);
});


test('smooths coarse head surfaces without applying the facial rule to garment creases',()=>{
  const {document,primitive}=character([0,0,0,1,0,0,0,1,0,0,0,1],[0,1,2,1,0,3]);
  const skin=document.getRoot().listSkins()[0],neck=skin.listJoints()[0];
  const head=document.createNode('mixamorig:Head'),face=document.createNode('headfront');
  neck.addChild(head);head.addChild(face);skin.addJoint(head).addJoint(face);
  const joints=primitive.getAttribute('JOINTS_0'),weights=primitive.getAttribute('WEIGHTS_0');
  for(let i=0;i<joints.getCount();i++){joints.setElement(i,[0,2,0,0]);weights.setElement(i,[.6,.4,0,0]);}
  const report=prepareCharacterNormals(document);
  assert.equal(report.headSmoothEdges,1);assert.equal(report.splitVertices,0);
  const p=primitive.getAttribute('POSITION'),n=primitive.getAttribute('NORMAL');
  for(let i=0;i<p.getCount();i++)if(p.getElement(i,[]).every(v=>v===0)) {
    const value=n.getElement(i,[]);assert.ok(value[1]>.6&&value[2]>.6);
  }
});
