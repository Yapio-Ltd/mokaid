import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Document, NodeIO } from '@gltf-transform/core';
import { cookCustom, validateEmbeddedGlb } from './cook-custom.mjs';

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
test('cooks a generated walking rig and adds a stationary idle pose',async()=>{
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
    const result=await cookCustom(input,output);const bytes=await readFile(output);
    assert.equal(bytes.toString('ascii',0,8),'MOKASSET');assert.equal(bytes.readUInt32LE(8),4);
    assert.deepEqual(result.animations,['walking','idle']);assert.equal(result.meshes,1);
    assert.ok(Math.abs(bytes.readFloatLE(28)-1.75)<.001);
  } finally {await rm(dir,{recursive:true,force:true});}
});
