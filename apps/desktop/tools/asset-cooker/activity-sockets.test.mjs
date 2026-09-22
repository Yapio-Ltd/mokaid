import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { activitySockets, overrideActivitySockets, chairDelta, removeVerifiedObstacles } from './activity-sockets.mjs';
const source=await readFile(new URL('../../../web/src/three/office-navdata.ts',import.meta.url),'utf8');
test('cooks nine desks, real leisure sockets, and two facing coffee places',()=>{
  const sockets=activitySockets(source);
  assert.equal(sockets.length,20);
  const leftLounge=sockets.filter(s=>s.id.startsWith('sofa_')&&s.x>4);
  assert.equal(leftLounge.length,3);
  assert(leftLounge.every(s=>Math.abs(s.seatHeight-.6)<1e-8));
  for(const socket of sockets.filter(s=>s.kind<=1)) {
    const expected=socket.kind===0?.4025:.245;
    assert(Math.abs(Math.hypot(socket.approachX-socket.x,socket.approachZ-socket.z)-expected)<1e-8);
    assert(Math.abs(socket.approachX-socket.x+Math.sin(socket.yaw)*expected)<1e-8);
    assert(Math.abs(socket.approachZ-socket.z+Math.cos(socket.yaw)*expected)<1e-8);
  }
  const chats=sockets.filter(s=>s.kind===4);
  assert(Math.abs(Math.cos(chats[0].yaw-chats[1].yaw)+1)<1e-8);
});
test('native layout overrides update pose entries without modifying the web source',()=>{
  const sourceSockets=activitySockets(source), original=JSON.stringify(sourceSockets);
  const modified=overrideActivitySockets(sourceSockets,{desk_5:{x:-6.07081,z:-.750534},coffee_chat_0:{x:-2.74,z:5.1},coffee_chat_1:{x:-.85,z:4.9}});
  assert.equal(JSON.stringify(sourceSockets),original);
  const seat=modified.find(s=>s.id==='desk_5');
  assert.equal(seat.x,-6.07081);
  assert(Math.abs(Math.hypot(seat.approachX-seat.x,seat.approachZ-seat.z)-.4025)<1e-8);
  const chats=modified.filter(s=>s.kind===4);
  assert(Math.abs(Math.cos(chats[0].yaw-chats[1].yaw)+1)<1e-8);
  assert.throws(()=>overrideActivitySockets(sourceSockets,{typo:{x:2}}));
  assert.throws(()=>overrideActivitySockets(sourceSockets,{desk_5:{x:NaN}}));
});

test('chair world translation survives rotated and scaled parent hierarchy',()=>{
  const parent=[0,0,-2,0,0,3,0,0,4,0,0,0,12,5,10,1];
  const yaw=-Math.PI/2,distance=.925,local=chairDelta(parent,yaw,distance);
  const raw=[parent[0]*local[0]+parent[4]*local[1]+parent[8]*local[2],parent[1]*local[0]+parent[5]*local[1]+parent[9]*local[2],parent[2]*local[0]+parent[6]*local[1]+parent[10]*local[2]];
  assert(Math.abs(-raw[0]-Math.sin(yaw)*distance)<1e-8);
  assert(Math.abs(-raw[2]-Math.cos(yaw)*distance)<1e-8);
  assert(Math.abs(raw[1])<1e-8);
  assert.throws(()=>chairDelta(Array(16).fill(0),yaw,distance));
  const sockets=overrideActivitySockets(activitySockets(source),{desk_5:{chairNode:'chair_5',pullback:.925,yaw}});
  assert.equal(sockets[5].chairName,'chair_5');
  assert.throws(()=>overrideActivitySockets(activitySockets(source),{desk_5:{pullback:.925}}));
});

test('obstacle migration removes only measured matching fragments',()=>{
  const source=[[0,1,2,3],[4,5,6,7]];
  assert.deepEqual(removeVerifiedObstacles(source,[[0,1,2,3]]),[[4,5,6,7]]);
  assert.equal(source.length,2);
  assert.throws(()=>removeVerifiedObstacles(source,[[0,1,2,4]]));
  assert.throws(()=>removeVerifiedObstacles(source,[[0,1,2,3],[0,1,2,3]]));
});
