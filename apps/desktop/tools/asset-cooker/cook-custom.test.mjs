import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Document, NodeIO } from '@gltf-transform/core';
import sharp from 'sharp';
import { cookCustom, officeAnimationNames, validateEmbeddedGlb, validateOfficeCharacter } from './cook-custom.mjs';

function container(json) {
  const raw=Buffer.from(JSON.stringify(json));const padded=Buffer.concat([raw,Buffer.alloc((4-raw.length%4)%4,32)]);
  const header=Buffer.alloc(20);header.write('glTF');header.writeUInt32LE(2,4);header.writeUInt32LE(20+padded.length,8);
  header.writeUInt32LE(padded.length,12);header.writeUInt32LE(0x4e4f534a,16);return Buffer.concat([header,padded]);
}
test('rejects truncated containers and external resources before decoding',()=>{
  assert.throws(()=>validateEmbeddedGlb(Buffer.from('glTF')));
  for(const uri of ['https://example.com/image.png','file:///etc/passwd','../other.bin'])
    assert.throws(()=>validateEmbeddedGlb(container({asset:{version:'2.0'},images:[{uri}]})),/External/);
});
test('legacy walk-only conversion is explicit and production rejects incomplete characters',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'mokaid-cooker-'));
  try {
    const doc=new Document();const buffer=doc.createBuffer();
    const positions=doc.createAccessor().setType('VEC3').setBuffer(buffer).setArray(new Float32Array([-.2,0,0,.2,0,0,0,1.75,0]));
    const mesh=doc.createMesh().addPrimitive(doc.createPrimitive().setAttribute('POSITION',positions));
    const node=doc.createNode('body').setMesh(mesh);doc.createScene().addChild(node);
    const times=doc.createAccessor().setType('SCALAR').setBuffer(buffer).setArray(new Float32Array([0,1]));
    const values=doc.createAccessor().setType('VEC3').setBuffer(buffer).setArray(new Float32Array([0,0,0,0,.05,0]));
    const sampler=doc.createAnimationSampler().setInput(times).setOutput(values);
    doc.createAnimation('Walking_Armature').addSampler(sampler).addChannel(doc.createAnimationChannel().setTargetNode(node).setTargetPath('translation').setSampler(sampler));
    const input=join(dir,'model.glb'),output=join(dir,'model.mokaidasset');
    await writeFile(input,await new NodeIO().writeBinary(doc));
    await assert.rejects(cookCustom(input,output),/missing office animations/);
    await assert.rejects(readFile(output),{code:'ENOENT'});
    const result=await cookCustom(input,output,{requireOfficeAnimations:false});const bytes=await readFile(output);
    assert.equal(bytes.toString('ascii',0,8),'MOKASSET');assert.equal(bytes.readUInt32LE(8),4);
    assert.deepEqual(result.animations,['walking','idle']);assert.equal(result.meshes,1);
    assert.ok(Math.abs(bytes.readFloatLE(28)-1.75)<.001);
  } finally {await rm(dir,{recursive:true,force:true});}
});

function officeCharacter() {
  const doc=new Document(),buffer=doc.createBuffer();
  const accessor=(name,type,values,ArrayType=Float32Array)=>doc.createAccessor(name).setType(type).setBuffer(buffer).setArray(new ArrayType(values));
  const hips=doc.createNode('Hips'),head=doc.createNode('Head').setTranslation([0,1.5,0]);
  const cup=doc.createNode('cup_socket'),phone=doc.createNode('phone_socket'),dock=doc.createNode('phone_dock_socket');
  for(const node of [head,cup,phone,dock])hips.addChild(node);
  const joints=[hips,head,cup,phone,dock],skin=doc.createSkin();
  for(const node of joints)skin.addJoint(node);
  const identity=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1];
  skin.setInverseBindMatrices(accessor('Bind matrices','MAT4',joints.flatMap(()=>identity)));
  const scene=doc.createScene().addChild(hips),meshes=[];
  for(const [name,materialName,joint] of [['Body','Character albedo',0],['OfficeCoffeeCup','Ceramic',2],['OfficePhone','Desktop phone',3],['OfficePhoneDock','Desktop phone dock',4]]) {
    const material=doc.createMaterial(materialName).setMetallicFactor(0).setRoughnessFactor(.8);
    const primitive=doc.createPrimitive().setMaterial(material)
      .setAttribute('POSITION',accessor(name+' positions','VEC3',[-.2,0,0,.2,0,0,0,1.75,0]))
      .setAttribute('NORMAL',accessor(name+' normals','VEC3',[0,0,1,0,0,1,0,0,1]))
      .setAttribute('TEXCOORD_0',accessor(name+' UVs','VEC2',[0,0,1,0,.5,1]))
      .setAttribute('JOINTS_0',accessor(name+' joints','VEC4',[joint,0,0,0,joint,0,0,0,joint,0,0,0],Uint16Array))
      .setAttribute('WEIGHTS_0',accessor(name+' weights','VEC4',[1,0,0,0,1,0,0,0,1,0,0,0]));
    const mesh=doc.createMesh(name).addPrimitive(primitive);meshes.push(mesh);
    scene.addChild(doc.createNode(name).setMesh(mesh).setSkin(skin));
  }
  for(const name of officeAnimationNames) {
    const input=accessor(name+' times','SCALAR',[0,.5,1]);
    const output=accessor(name+' pelvis','VEC3',[0,0,0,0,.025,0,0,0,0]);
    const sampler=doc.createAnimationSampler().setInput(input).setOutput(output).setInterpolation('LINEAR');
    doc.createAnimation(name).addSampler(sampler).addChannel(doc.createAnimationChannel().setTargetNode(hips).setTargetPath('translation').setSampler(sampler));
  }
  return {doc,skin,hips,head,meshes};
}

function readCooked(bytes) {
  let offset=12;
  const u=()=>{const value=bytes.readUInt32LE(offset);offset+=4;return value;};
  const f=()=>{const value=bytes.readFloatLE(offset);offset+=4;return value;};
  const floats=count=>Array.from({length:count},f);
  const string=()=>{const count=u(),value=bytes.toString('utf8',offset,offset+count);offset+=count;return value;};
  floats(6);
  const textures=Array.from({length:u()},()=>{
    const srgb=u(),mips=Array.from({length:u()},()=>{const width=u(),height=u(),size=u();offset+=size;return {width,height};});
    return {srgb,mips};
  });
  const surfaces=Array.from({length:u()},()=>{offset+=56;return u();});
  const nodeCount=u();offset+=nodeCount*44;
  const skins=Array.from({length:u()},()=>{const count=u(),joints=Array.from({length:count},u);offset+=count*64;return joints;});
  for(let count=u();count>0;--count){offset+=12;const vertices=u();offset+=vertices*64;const indices=u();offset+=indices*4;}
  const animations=Array.from({length:u()},()=>{
    const name=string(),duration=f();
    const channels=Array.from({length:u()},()=>{const node=u(),path=u(),step=u(),count=u();return {node,path,step,times:floats(count),values:floats(count*4)};});
    return {name,duration,channels};
  });
  assert.equal(offset,bytes.length);
  return {textures,surfaces,skins,animations};
}

test('production contract matches all canonical office animation names',async()=>{
  const catalog=await readFile(new URL('../../../api/lib/mokaid/assets_3d.ex',import.meta.url),'utf8');
  const names=catalog.match(/@all_clips\s+~w\(([\s\S]*?)\)/)[1].trim().split(/\s+/);
  assert.equal(officeAnimationNames.length,48);
  assert.deepEqual([...officeAnimationNames].sort(),names.sort());
});

test('preserves all office clips, original atlas detail, pelvis palette and phone surfaces',async()=>{
  const dir=await mkdtemp(join(tmpdir(),'mokaid-office-cooker-'));
  try {
    const {doc}=officeCharacter();
    const image=await sharp({create:{width:2048,height:2,channels:4,background:'#7c4b9aff'}}).png().toBuffer();
    const texture=doc.createTexture('Generated character atlas').setImage(image).setMimeType('image/png');
    doc.getRoot().listMaterials()[0].setBaseColorTexture(texture);
    const input=join(dir,'model.glb'),output=join(dir,'model.mokaidasset');
    await writeFile(input,await new NodeIO().writeBinary(doc));
    const result=await cookCustom(input,output),cooked=readCooked(await readFile(output));
    assert.deepEqual(result.animations,officeAnimationNames);
    assert.equal(result.normals.primitives,1);
    assert.deepEqual(cooked.surfaces,[0,0,2,3,0]);
    assert.equal(cooked.skins[0][0],0);
    assert.equal(cooked.textures[0].mips[0].width,2048);
    assert.deepEqual(cooked.animations.map(animation=>animation.name),officeAnimationNames);
    const typing=cooked.animations.find(animation=>animation.name==='typing');
    assert.equal(typing.duration,1);
    assert.deepEqual(typing.channels[0].times,[0,.5,1]);
    assert.ok(Math.abs(typing.channels[0].values[5]-.025)<1e-6);
  } finally {await rm(dir,{recursive:true,force:true});}
});

test('rejects invalid pelvis ordering, missing props and malformed baked animation tracks',()=>{
  const wrongPelvis=officeCharacter();
  wrongPelvis.skin.removeJoint(wrongPelvis.hips).addJoint(wrongPelvis.hips);
  assert.throws(()=>validateOfficeCharacter(wrongPelvis.doc),/begin with the pelvis/);
  const missingProp=officeCharacter();
  missingProp.doc.getRoot().listNodes().find(node=>node.getName()==='cup_socket').setName('Unknown prop');
  assert.throws(()=>validateOfficeCharacter(missingProp.doc),/cup_socket/);
  const missingTag=officeCharacter();
  missingTag.doc.getRoot().listMaterials().find(material=>material.getName()==='Desktop phone dock').setName('Untagged dock');
  assert.throws(()=>validateOfficeCharacter(missingTag.doc),/tagged phone/);
  const frozen=officeCharacter();
  frozen.doc.getRoot().listAnimations()[0].listSamplers()[0].getInput().setArray(new Float32Array([0]));
  assert.throws(()=>validateOfficeCharacter(frozen.doc),/complete baked samples/);
  const backwards=officeCharacter();
  backwards.doc.getRoot().listAnimations()[0].listSamplers()[0].getInput().setArray(new Float32Array([0,.8,.4]));
  assert.throws(()=>validateOfficeCharacter(backwards.doc),/sample times must increase/);
});
