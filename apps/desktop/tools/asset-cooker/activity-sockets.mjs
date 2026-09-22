/** Compile the existing authored web sockets into native RH activity metadata. */
export function activitySockets(source) {
  const number = value => {
    const text = value.trim();
    const pi = text.match(/^Math\.PI(?:\s*\/\s*(\d+(?:\.\d+)?))?$/);
    const result = pi ? Math.PI / Number(pi[1] ?? 1) : Number(text);
    if (!Number.isFinite(result)) throw Error(`Unsupported socket scalar: ${text}`);
    return result;
  };
  const constant = name => {
    const match = source.match(new RegExp(`export const ${name} = ([\\d.]+);`));
    if (!match) throw Error(`Missing socket height ${name}`);
    return Number(match[1]);
  };
  const deskBlock = source.match(/export const OFFICE_DESK_SLOTS[^=]*=\s*\[([\s\S]*?)\n\];/)?.[1];
  const poiBlock = source.match(/export const OFFICE_POIS[^=]*=\s*\[([\s\S]*?)\n\];/)?.[1];
  if (!deskBlock || !poiBlock) throw Error('Missing authored activity sockets');
  const sockets = [];
  const add = (id, kind, x, webZ, facing, seatHeight, holdSeconds) => {
    const yaw = -facing, z = -webZ;
    const entryDistance = kind === 0 ? .4025 : kind === 1 ? .245 : 0;
    sockets.push({id, kind, x, z, approachX:x-Math.sin(yaw)*entryDistance,
      approachZ:z-Math.cos(yaw)*entryDistance, yaw, seatHeight, holdSeconds});
  };
  for (const m of deskBlock.matchAll(/\{\s*x:\s*([-\d.]+),\s*z:\s*([-\d.]+),\s*facing:\s*([-\d.]+),\s*seatHeight:\s*DESK_SEAT_HEIGHT\s*\}/g))
    add(`desk_${sockets.length}`,0,Number(m[1]),Number(m[2]),Number(m[3]),constant('DESK_SEAT_HEIGHT'),12);
  if (sockets.length !== 9) throw Error('Expected nine authored desk sockets');
  const sofaHeight = new Map();
  for (const m of poiBlock.matchAll(/id:\s*"(sofa_[a-z])",[\s\S]*?seatHeight:\s*(SOFA_SEAT_HEIGHT|\d+(?:\.\d+)?)/g))
    sofaHeight.set(m[1], m[2] === 'SOFA_SEAT_HEIGHT' ? constant('SOFA_SEAT_HEIGHT') : Number(m[2]));
  for (const m of poiBlock.matchAll(/id:\s*"(sofa_[a-z]|coffee_active|foosball_[ab])",[\s\S]*?position:\s*\{\s*x:\s*([-\d.]+),\s*z:\s*([-\d.]+)\s*\},\s*facing:\s*([^,]+),/g)) {
    const kind = m[1].startsWith('sofa_') ? 1 : m[1].startsWith('coffee_') ? 2 : 3;
    const height = kind === 1 ? sofaHeight.get(m[1]) : 0;
    if (kind === 1 && !Number.isFinite(height)) throw Error(`Missing sofa seat height ${m[1]}`);
    add(m[1],kind,Number(m[2]),Number(m[3]),number(m[4]),height,kind===2?4:9);
  }
  if (sockets.length !== 18) throw Error('Expected nine authored leisure sockets');
  const queue = poiBlock.match(/id:\s*"coffee",[\s\S]*?queueSlots:\s*\[([\s\S]*?)\]/)?.[1];
  const chat = [...(queue ?? '').matchAll(/x:\s*([-\d.]+),\s*z:\s*([-\d.]+)/g)].map(m=>({x:Number(m[1]),z:-Number(m[2])}));
  if (chat.length !== 2) throw Error('Expected two coffee conversation places');
  chat.forEach((p,i)=>{
    const other=chat[1-i],yaw=Math.atan2(p.x-other.x,p.z-other.z);
    sockets.push({id:`coffee_chat_${i}`,kind:4,x:p.x,z:p.z,approachX:p.x,approachZ:p.z,yaw,seatHeight:0,holdSeconds:8});
  });
  return sockets;
}

export function overrideActivitySockets(sockets, overrides = {}) {
  const result = sockets.map(socket => ({...socket}));
  for (const [id, values] of Object.entries(overrides)) {
    const socket = result.find(s => s.id === id);
    if (!socket) throw Error(`Unknown native activity socket ${id}`);
    for (const key of ['x','z','yaw','seatHeight','holdSeconds','pullback']) {
      if (values[key] === undefined) continue;
      if (!Number.isFinite(values[key])) throw Error(`Invalid native socket ${id}/${key}`);
      socket[key] = values[key];
    }
    if (values.chairNode !== undefined) {
      if (socket.kind !== 0 || typeof values.chairNode !== 'string' || !/^chair_[0-8]$/.test(values.chairNode)) throw Error(`Invalid chair binding ${id}`);
      socket.chairName = values.chairNode;
    }
    if (socket.pullback !== undefined && (!(socket.pullback > 0) || socket.pullback > 1.5 || !socket.chairName)) throw Error(`Invalid chair travel ${id}`);
    const distance = socket.kind === 0 ? .4025 : socket.kind === 1 ? .245 : 0;
    socket.approachX = socket.x-Math.sin(socket.yaw)*distance;
    socket.approachZ = socket.z-Math.cos(socket.yaw)*distance;
  }
  const chats=result.filter(s=>s.kind===4);
  if(chats.length===2) chats.forEach((s,i)=>{const other=chats[1-i];s.yaw=Math.atan2(s.x-other.x,s.z-other.z);});
  return result;
}

// Convert a native-world chair displacement through the office PI-Y root and
// its glTF parent. Translation vectors deliberately exclude matrix translation.
export function chairDelta(parent, yaw, distance) {
  const a=parent[0],b=parent[4],c=parent[8],d=parent[1],e=parent[5],f=parent[9],g=parent[2],h=parent[6],i=parent[10];
  const det=a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g);
  if (!Number.isFinite(det) || Math.abs(det)<1e-10) throw Error('Noninvertible chair parent');
  const x=-Math.sin(yaw)*distance,z=-Math.cos(yaw)*distance;
  return [((e*i-f*h)*x+(b*f-c*e)*z)/det,((f*g-d*i)*x+(c*d-a*f)*z)/det,((d*h-e*g)*x+(a*e-b*d)*z)/det];
}

export function removeVerifiedObstacles(boxes, removals=[]) {
  const result=boxes.map(box=>[...box]);
  for(const old of removals) {
    if(!Array.isArray(old)||old.length!==4||!old.every(Number.isFinite))throw Error('Invalid removed navigation obstacle');
    const index=result.findIndex(box=>box.every((v,i)=>Math.abs(v-old[i])<.0001));
    if(index<0)throw Error(`Removed navigation obstacle not found: ${old}`);
    result.splice(index,1);
  }
  return result;
}
