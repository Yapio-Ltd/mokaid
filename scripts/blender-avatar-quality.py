#!/usr/bin/env python3
"""Author the complete office avatar library using Blender's actual armatures.

blender --background --python scripts/blender-avatar-quality.py -- --output /tmp/avatar-quality
The source manifest pins the pre-repair API catalog. Outputs are staged until promoted.
Rig geometry, bind matrices, material images and bone names are preserved. New
60 fps actions use geometric two-segment IK, never guessed bone-local Euler axes.
"""
from __future__ import annotations
import argparse, hashlib, json, math, re, struct, sys
from pathlib import Path
import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector

ROOT = Path(__file__).resolve().parents[1]
TAU = math.tau
FPS = 60
SOFA_SEAT_HEIGHT = .70
DESK_SEAT_HEIGHT = .51  # matches office-navdata.ts / floor y = 0
WALK_DURATION_OVERRIDES = {'avatar_research': .6}  # short legs need shorter, quicker steps
WALK_SPEED = 1.0  # metres/s after the runtime's 1.75 m normalization
DURATIONS = dict(idle=4.0, walking=.9, typing=2.0, working=4.0,
 thinking=4.0, talking=4.0, waiting=4.0, blocked=3.0, celebrating=2.4,
 away=4.0, offline=4.0, reviewing=4.0, learning=4.0,
 requesting_approval=3.0, sitting=4.0, sitting_sofa=4.0, preparing_coffee=4.0, playing_foosball=2.0,
 sit_down=1.1, stand_up=1.0, sit_down_sofa=1.0, stand_up_sofa=1.0,
 walking_coffee=.9, carrying_coffee=3.0, drinking_coffee=3.6, talking_coffee=5.0,
 chair_pullback=1.3, chair_pushin=1.3)
CHAIR_LOCOMOTION = {'chair_pullback','chair_pushin'}
CHAIR_SPEED = .5
NON_LOOP = {'sit_down','stand_up','sit_down_sofa','stand_up_sofa','preparing_coffee'}
COFFEE = {'preparing_coffee','walking_coffee','carrying_coffee','drinking_coffee','talking_coffee'}
SEAT_TRANSITIONS = {'sit_down','stand_up','sit_down_sofa','stand_up_sofa'}
SEAT_ADVANCE = {'desk': .23, 'sofa': .14}
DESK = {'typing','working','thinking','talking','waiting','blocked','reviewing','learning','requesting_approval','sitting','chair_pullback','chair_pushin'}

def glb_read(path):
 data=path.read_bytes(); out={}; binary=b''; offset=12
 while offset<len(data):
  size,kind=struct.unpack_from('<I4s',data,offset); offset+=8
  block=data[offset:offset+size];offset+=size
  if kind==b'JSON':out=json.loads(block)
  elif kind==b'BIN\0':binary=block
 return out,binary

def glb_write(path,gltf,binary):
 raw=json.dumps(gltf,separators=(',',':')).encode();raw+=b' '*((-len(raw))%4)
 binary+=b'\0'*((-len(binary))%4)
 path.write_bytes(struct.pack('<4sII',b'glTF',2,28+len(raw)+len(binary))+struct.pack('<I4s',len(raw),b'JSON')+raw+struct.pack('<I4s',len(binary),b'BIN\0')+binary)

def normalize_avatar_materials(meshes):
 """Keep authored albedo; make skin/clothing nonmetallic and nonemissive."""
 materials={slot.material for obj in meshes for slot in obj.material_slots if slot.material}
 for material in materials:
  material.metallic=0
  material.roughness=max(.65,material.roughness)
  if not material.use_nodes:continue
  for node in material.node_tree.nodes:
   if node.type!='BSDF_PRINCIPLED':continue
   settings={'Metallic':0.0,'Emission Strength':0.0,'Emission Color':(0,0,0,1),
             'Specular IOR Level':.5,'Specular Tint':(1,1,1,1)}
   roughness=node.inputs.get('Roughness')
   if roughness:settings['Roughness']=max(.65,float(roughness.default_value))
   for name,value in settings.items():
    socket=node.inputs.get(name)
    if socket is None:continue
    for link in list(socket.links):material.node_tree.links.remove(link)
    socket.default_value=value
 return len(materials)

def source(path,tmp):
 # Ignore old animation curves at import: finance's invalid sampler lengths
 # otherwise prevent Blender from loading its valid geometry/skin at all.
 gltf,binary=glb_read(path);gltf.pop('animations',None);glb_write(tmp,gltf,binary)
 bpy.ops.wm.read_factory_settings(use_empty=True)
 bpy.ops.import_scene.gltf(filepath=str(tmp))
 arm=next(o for o in bpy.data.objects if o.type=='ARMATURE')
 for obj in list(bpy.data.objects):
  if obj.name=='Icosphere' and obj.type=='MESH' and not obj.vertex_groups:
   bpy.data.objects.remove(obj,do_unlink=True)
 meshes=[o for o in bpy.data.objects if o.type=='MESH']
 normalize_avatar_materials(meshes)
 # The male asset contains eye highlights bound to an independent neutral bone.
 # Bind those existing vertices to the head so they cannot float above seated
 # characters. No geometry/proportions are changed.
 if 'head.x' in arm.data.bones:
  eye=next((obj for obj in meshes if obj.name=='Eye'),None)
  neutral=eye.vertex_groups.get('neutral_bone') if eye else None
  if neutral:
   head=eye.vertex_groups.get('head.x') or eye.vertex_groups.new(name='head.x')
   for vertex in eye.data.vertices:
    weight=sum(g.weight for g in vertex.groups if g.group==neutral.index)
    if weight:
     prior=sum(g.weight for g in vertex.groups if g.group==head.index)
     head.add([vertex.index],prior+weight,'REPLACE');neutral.remove([vertex.index])
 repaired=0
 for obj in meshes:
  for v in obj.data.vertices:
   groups=[g for g in v.groups if obj.vertex_groups[g.group].name in arm.data.bones and g.weight>0]
   if not groups:raise ValueError(f'{obj.name}: unweighted vertex {v.index}')
   if len(groups)>4:raise ValueError(f'{obj.name}: more than 4 bone influences')
   total=sum(g.weight for g in groups)
   repaired+=abs(total-1)>1e-6
   for g in groups:obj.vertex_groups[g.group].add([v.index],g.weight/total,'REPLACE')
 # Once its eye weights are repaired, remove the disconnected neutral joint.
 # Keeping it lets Blender put that root before the pelvis in the skin palette,
 # which violates the native renderer's pelvis calibration contract.
 if 'neutral_bone' in arm.data.bones:
  used=any(obj.vertex_groups[g.group].name=='neutral_bone' and g.weight>0 for obj in meshes for vertex in obj.data.vertices for g in vertex.groups)
  if not used:
   bpy.context.view_layer.objects.active=arm;arm.select_set(True)
   bpy.ops.object.mode_set(mode='EDIT');arm.data.edit_bones.remove(arm.data.edit_bones['neutral_bone']);bpy.ops.object.mode_set(mode='OBJECT')
 return arm,meshes,repaired

class Rig:
 def __init__(self,arm,meshes):
  self.arm=arm;self.meshes=meshes
  self.names=[b.name for b in arm.data.bones]
  self.rest={b.name:arm.matrix_world@b.matrix_local for b in arm.data.bones}
  self.parents={b.name:b.parent.name if b.parent else None for b in arm.data.bones}
  self.pose={n:m.copy() for n,m in self.rest.items()}
  self.basis={n:Matrix.Identity(4) for n in self.names}
  male='root.x' in self.names
  self.hips='root.x' if male else 'Hips'
  self.head='head.x' if male else 'Head'
  self.spine=[n for n in self.names if n.startswith('spine_')][:3] if male else ['Spine02','Spine01','Spine']
  self.limbs={}
  for side,prefix in [('l','Left'),('r','Right')]:
   self.limbs[side] = dict(thigh=f'thigh_stretch.{side}' if male else prefix+'UpLeg',
    knee=f'leg_stretch.{side}' if male else prefix+'Leg', foot=f'foot.{side}' if male else prefix+'Foot',
    arm=f'arm_stretch.{side}' if male else prefix+'Arm', elbow=f'forearm_stretch.{side}' if male else prefix+'ForeArm',
    hand=f'hand.{side}' if male else prefix+'Hand')
  coords=[o.matrix_world@v.co for o in meshes for v in o.data.vertices]
  self.floor=min(v.z for v in coords);self.height=max(v.z for v in coords)-self.floor
  self.origin=self.rest[self.hips].translation.copy()
  self.hand_frames={}
  for side,limb in self.limbs.items():
   name=limb['hand'];points=[]
   for obj in meshes:
    group=obj.vertex_groups.get(name)
    if not group:continue
    for vertex in obj.data.vertices:
     if any(g.group==group.index and g.weight>.7 for g in vertex.groups):points.append(list(obj.matrix_world@vertex.co))
   if len(points)<4:raise ValueError(f'{name}: insufficient hand weights for palm calibration')
   points=np.array(points);forward=Vector(points.mean(axis=0))-self.rest[name].translation;forward.normalize()
   values,axes=np.linalg.eigh(np.cov(points.T));normal=Vector(axes[:,0])
   if male:
    # Finger bones give an exact palm frame; hand-only weights omit the
    # separately rigged fingers and bias the centroid toward the wrist.
    forward=(self.rest[f'middle1.{side}'].translation-self.rest[name].translation).normalized()
    width=self.rest[f'pinky1_base.{side}'].translation-self.rest[f'index1_base.{side}'].translation
    normal=forward.cross(width).normalized()
    if normal.z<0:normal.negate()
   sign=1 if side=='l' else -1
   if (normal.x*sign if abs(normal.x)>.2 else normal.z)<0:normal.negate()
   normal=(normal-forward*normal.dot(forward)).normalized();across=forward.cross(normal).normalized()
   self.hand_frames[side]=Matrix((across,forward,normal)).transposed().to_quaternion()
  self.max_ik_error=0
 def reset(self):
  self.basis={n:Matrix.Identity(4) for n in self.names};self.recalculate()
 def recalculate(self):
  for n in self.names:
   p=self.parents[n]
   self.pose[n]=(self.pose[p]@self.rest[p].inverted() if p else Matrix.Identity(4))@self.rest[n]@self.basis[n]
 def pos(self,n):return self.pose[n].translation.copy()
 def move_root(self,offset):
  self.basis[self.hips]=Matrix.Translation(self.rest[self.hips].to_3x3().inverted()@offset);self.recalculate()
 def rotate_world(self,n,quat):
  p=self.parents[n];parent=(self.pose[p]@self.rest[p].inverted()) if p else Matrix.Identity(4)
  rest=(parent@self.rest[n]).to_quaternion()
  self.basis[n]=Matrix.Translation(self.basis[n].translation)@(rest.inverted()@quat).to_matrix().to_4x4()
  self.recalculate()
 def offset_rotation(self,n,axis,angle):
  self.rotate_world(n,Quaternion(axis,angle)@self.pose[n].to_quaternion())
 def aim(self,n,child,point):
  current=self.pos(child)-self.pos(n);target=point-self.pos(n)
  if current.length>1e-7 and target.length>1e-7:self.rotate_world(n,current.rotation_difference(target)@self.pose[n].to_quaternion())
 def ik(self,a,b,c,target,pole):
  start=self.pos(a);l1=(self.rest[b].translation-self.rest[a].translation).length;l2=(self.rest[c].translation-self.rest[b].translation).length
  vector=target-start;raw=vector.length;distance=min(l1+l2-0.0001,max(abs(l1-l2)+0.0001,raw));direction=vector.normalized()
  bend=pole-start;bend=(bend-direction*direction.dot(bend)).normalized()
  along=(l1*l1-l2*l2+distance*distance)/(2*distance)
  knee=start+direction*along+bend*math.sqrt(max(0,l1*l1-along*along))
  self.aim(a,b,knee);self.aim(b,c,start+direction*distance)
  self.max_ik_error=max(self.max_ik_error,(self.pos(c)-target).length)
 def transform_world(self,n,location,rotation,visibility=1):
  parent=self.parents[n]
  inherited=(self.pose[parent]@self.rest[parent].inverted() if parent else Matrix.Identity(4))@self.rest[n]
  scale=self.rest[n].decompose()[2]*visibility
  goal=Matrix.LocRotScale(location,rotation,scale)
  self.basis[n]=inherited.inverted()@goal;self.recalculate()
 def apply(self,frame):
  for n in self.names:
   pb=self.arm.pose.bones[n];loc,rot,scale=self.basis[n].decompose()
   pb.rotation_mode='QUATERNION';pb.location=loc;pb.rotation_quaternion=rot;pb.scale=scale if n.endswith('_socket') else (1,1,1)
   if frame is not None:
    pb.keyframe_insert('location',frame=frame,group=n);pb.keyframe_insert('rotation_quaternion',frame=frame,group=n)
    pb.keyframe_insert('scale',frame=frame,group=n)

def smooth(x):
 x=max(0,min(1,x));return x*x*(3-2*x)
def ramp(u,a,b):return smooth((u-a)/(b-a))

def add_cup(rig):
 """One rigid skin joint keeps the cup in the native renderer's existing path.

 The socket is a deformation bone, never a separate object animation. Its
 hidden scale is positive to keep skin matrices invertible during crossfades.
 """
 if 'cup_socket' in rig.arm.data.bones:return rig.meshes
 ns=rig.height/1.75;hand=rig.limbs['r']['hand']
 center=rig.rest[hand].translation+Vector((.075*ns,0,-.035*ns))
 bpy.context.view_layer.objects.active=rig.arm;rig.arm.select_set(True)
 bpy.ops.object.mode_set(mode='EDIT');bone=rig.arm.data.edit_bones.new('cup_socket')
 bone.parent=rig.arm.data.edit_bones[hand];bone.use_connect=False
 bone.head=rig.arm.matrix_world.inverted()@center
 bone.tail=rig.arm.matrix_world.inverted()@(center+Vector((0,0,.06*ns)))
 bpy.ops.object.mode_set(mode='OBJECT')
 verts=[];faces=[];materials=[];n=32
 # Ceramic shell includes an inner wall and rim, not an opaque cylinder.
 for radius,z in [(.038,-.06),(.045,.062),(.038,.062),(.033,-.05)]:
  for i in range(n):
   angle=TAU*i/n;verts.append(tuple(center+Vector((radius*math.cos(angle),radius*math.sin(angle),z))*ns))
 for ring in range(3):
  for i in range(n):faces.append((ring*n+i,ring*n+(i+1)%n,(ring+1)*n+(i+1)%n,(ring+1)*n+i));materials.append(0)
 faces.append(tuple(reversed(range(n))));materials.append(0)
 # Coffee surface is inset below the rim, matte enough to avoid HDR sparks.
 start=len(verts)
 for i in range(n):
  a=TAU*i/n;verts.append(tuple(center+Vector((.037*math.cos(a),.037*math.sin(a),.049))*ns))
 faces.append(tuple(range(start,start+n)));materials.append(1)
 # Rounded handle in the XZ plane, on the wrist-facing side.
 start=len(verts);rings=24;segments=8
 for i in range(rings):
  a=TAU*i/rings
  for j in range(segments):
   b=TAU*j/segments;r=.030+.006*math.cos(b)
   verts.append(tuple(center+Vector((-.053+r*math.cos(a),.006*math.sin(b),r*math.sin(a)))*ns))
 for i in range(rings):
  for j in range(segments):
   faces.append((start+i*segments+j,start+((i+1)%rings)*segments+j,start+((i+1)%rings)*segments+(j+1)%segments,start+i*segments+(j+1)%segments));materials.append(0)
 mesh=bpy.data.meshes.new('OfficeCoffeeCup');mesh.from_pydata(verts,[],faces);mesh.update()
 obj=bpy.data.objects.new('OfficeCoffeeCup',mesh);bpy.context.scene.collection.objects.link(obj)
 for name,color,rough in [('CeramicWarmWhite',(.78,.73,.64,1),.68),('FreshCoffee',(.038,.013,.005,1),.85)]:
  material=bpy.data.materials.new(name);material.diffuse_color=color;material.use_nodes=True
  principled=material.node_tree.nodes.get('Principled BSDF');principled.inputs['Base Color'].default_value=color;principled.inputs['Roughness'].default_value=rough
  obj.data.materials.append(material)
 for polygon,material in zip(mesh.polygons,materials):polygon.material_index=material;polygon.use_smooth=len(polygon.vertices)==4
 obj.vertex_groups.new(name='cup_socket').add(list(range(len(verts))),1,'REPLACE')
 obj.modifiers.new('CupRigidSkin','ARMATURE').object=rig.arm
 return rig.meshes+[obj]

def animate(rig,name,u):
 rig.reset();h=rig.height;o=rig.origin.copy();phase=TAU*u;gait=getattr(rig,'gait',{})
 walking=name in {'walking','walking_coffee'};transition=name in SEAT_TRANSITIONS
 sofa=name=='sitting_sofa' or (transition and name.endswith('_sofa'))
 seat=name in DESK or sofa or transition
 amount=(1-smooth(u) if name.startswith('stand_up') else smooth(u)) if transition else float(seat)
 # Transition endpoints exactly match idle/sitting frame zero. This breathing
 # envelope vanishes at both ends, so the runtime can join without a pose jump.
 breath=math.sin(math.pi*u)**2 if transition else 1
 foot_advance=SEAT_ADVANCE['sofa' if sofa else 'desk']*h
 feet={s:rig.rest[v['foot']].translation.copy() for s,v in rig.limbs.items()}
 hipoffset=Vector((0,0,0));lift={s:0 for s in feet}
 if seat:
  hipoffset.z=(rig.floor+(SOFA_SEAT_HEIGHT if sofa else DESK_SEAT_HEIGHT)*h/1.75-o.z)*amount
  for foot in feet.values():foot.y-=foot_advance*amount
 elif walking:
  stance=gait.get('stance',.6);swing=1-stance
  speed=WALK_SPEED*h/1.75;travel=speed*rig.walk_duration*stance;drops=[]
  for side,l in rig.limbs.items():
   thigh=rig.rest[l['thigh']].translation;ankle=feet[side]
   length=(rig.rest[l['knee']].translation-thigh).length+(ankle-rig.rest[l['knee']].translation).length
   drops.append(thigh.z-ankle.z-math.sqrt(max(.001,(length*.98)**2-(abs(ankle.y-thigh.y)+travel*.55)**2-(ankle.x-thigh.x)**2)))
  hipoffset.z=-max(.010*h,max(drops))-gait.get('bob',.003)*h*(1-math.cos(phase*2))
  hipoffset.x=gait.get('sway',.006)*h*math.sin(phase)
  for side in feet:
   p=(u+(0 if side=='l' else .5))%1
   if p<=stance:feet[side].y+=travel*(p/stance-.5)
   else:
    t=(p-stance)/swing;m=speed*rig.walk_duration*swing
    feet[side].y+=(2*t**3-3*t*t+1)*travel/2+(t**3-2*t*t+t)*m+(-2*t**3+3*t*t)*(-travel/2)+(t**3-t*t)*m
    lift[side]=math.sin(math.pi*t)**2;feet[side].z+=gait.get('lift',.047)*h*lift[side]
 elif name=='playing_foosball':hipoffset=Vector((.007*math.sin(phase),-.10,-.09-getattr(rig,'foos_extra_drop_m',0)))*h/1.75
 if name in CHAIR_LOCOMOTION:
  # Two small seated steps per leg per 1.3 s cycle move the chair .65 m.
  # Runtime phase follows actual chair travel / .5 m/s, including braking.
  speed=CHAIR_SPEED*h/1.75;duration=DURATIONS[name]/2;travel=speed*duration*.6
  for side in feet:
   feet[side]=rig.rest[rig.limbs[side]['foot']].translation.copy();feet[side].y-=.19*h
   p=(2*u+(0 if side=='l' else .5))%1
   if p<=.6:advance=travel*(p/.6-.5)
   else:
    t=(p-.6)/.4;m=speed*duration*.4
    advance=(2*t**3-3*t*t+1)*travel/2+(t**3-2*t*t+t)*m+(-2*t**3+3*t*t)*(-travel/2)+(t**3-t*t)*m
    feet[side].z+=.018*h*math.sin(math.pi*t)**2
   feet[side].y+=advance*(-1 if name=='chair_pullback' else 1)
 rig.move_root(hipoffset)
 if walking:rig.offset_rotation(rig.hips,(0,0,1),gait.get('yaw',.025)*math.sin(phase))
 for i,n in enumerate(rig.spine):
  breathing=.006*math.sin(phase+i*.3)*breath if not transition else .006*math.sin(i*.3)
  lean=.10*math.sin(math.pi*u)**2 if transition else (.08 if name=='playing_foosball' else 0)
  rig.offset_rotation(n,(1,0,0),breathing+.025*amount+lean)
  if walking:
   rig.offset_rotation(n,(0,0,1),-gait.get('yaw',.025)*.52*math.sin(phase))
   rig.offset_rotation(n,(1,0,0),gait.get('lean',0))
 rig.offset_rotation(rig.head,(0,0,1),(.045 if name in {'thinking','talking','talking_coffee','reviewing','learning'} else .014)*math.sin(phase)*breath)
 rig.offset_rotation(rig.head,(1,0,0),.06*amount+.012*math.sin(phase*2)*breath)
 if name=='playing_foosball':
  # The map's full-size table has rod axes at .956 m, measured from its
  # transformed mesh. Lean from the torso until short arms can reach the
  # farthest pull position, then keep that lean stable throughout the cycle.
  if not hasattr(rig,'foos_extra_lean'):
   original={n:rig.basis[n].copy() for n in rig.spine};low=0;high=.12
   for iteration in range(12):
    extra=(low+high)/2
    for n in rig.spine:rig.basis[n]=original[n].copy()
    rig.recalculate()
    for n in rig.spine:rig.offset_rotation(n,(1,0,0),extra)
    reachable=True
    for side,l in rig.limbs.items():
     sign=1 if side=='l' else -1;ns=h/1.75
     target=Vector((o.x+sign*.19*ns,o.y-.395*ns,rig.floor+.956*ns))
     length=(rig.rest[l['elbow']].translation-rig.rest[l['arm']].translation).length+(rig.rest[l['hand']].translation-rig.rest[l['elbow']].translation).length
     reachable=reachable and (target-rig.pos(l['arm'])).length<length*.955
    if reachable:high=extra
    else:low=extra
   rig.foos_extra_lean=high
   for n in rig.spine:rig.basis[n]=original[n]
   rig.recalculate()
  for n in rig.spine:rig.offset_rotation(n,(1,0,0),rig.foos_extra_lean)
  if not hasattr(rig,'foos_extra_drop_m'):
   drop=0;ns=h/1.75
   for side,l in rig.limbs.items():
    sign=1 if side=='l' else -1;shoulder=rig.pos(l['arm'])
    target=Vector((o.x+sign*.19*ns,o.y-.395*ns,rig.floor+.956*ns))
    length=(rig.rest[l['elbow']].translation-rig.rest[l['arm']].translation).length+(rig.rest[l['hand']].translation-rig.rest[l['elbow']].translation).length
    horizontal=(target.x-shoulder.x)**2+(target.y-shoulder.y)**2
    assert horizontal<(length*.95)**2,('foosball horizontal reach',rig.arm.name)
    vertical=math.sqrt((length*.95)**2-horizontal)
    drop=max(drop,shoulder.z-target.z-vertical)
   rig.foos_extra_drop_m=max(0,drop/ns)
   hipoffset.z-=rig.foos_extra_drop_m*ns;rig.move_root(hipoffset)
 sip=ramp(u,.12,.37)*(1-ramp(u,.60,.86)) if name=='drinking_coffee' else 0
 if sip:rig.offset_rotation(rig.head,(1,0,0),-.06*sip)
 tilt=Quaternion((1,0,0),-.38*sip)
 for side,l in rig.limbs.items():
  sign=1 if side=='l' else -1
  rig.ik(l['thigh'],l['knee'],l['foot'],feet[side],rig.pos(l['thigh'])+Vector((0,-h,0)))
  rig.rotate_world(l['foot'],Quaternion((1,0,0),-.11*lift[side])@rig.rest[l['foot']].to_quaternion())
  shoulder=rig.pos(l['arm']);total=(rig.rest[l['elbow']].translation-rig.rest[l['arm']].translation).length+(rig.rest[l['hand']].translation-rig.rest[l['elbow']].translation).length
  standing=shoulder+Vector((sign*.045*h,-.035*h,-total*.92))
  target=standing.copy();pole=shoulder+Vector((sign*.25*h,.35*h,-.25*h))
  if walking:
   # Contralateral swing follows the authored stance, rather than drifting a
   # quarter-cycle out of phase with the legs.
   target.y-=gait.get('arm_swing',.42)*(feet[side].y-rig.rest[l['foot']].translation.y)
   target.z+=.005*h*math.cos(phase*2)
  if seat:
   seated=rig.pos(rig.hips)+Vector((sign*.12*h,-.20*h,.15*h))
   if name in {'sitting','sitting_sofa'} or name in CHAIR_LOCOMOTION or transition:seated=rig.pos(rig.hips)+Vector((sign*.11*h,-.14*h,.045*h))
   target=standing.lerp(seated,amount);pole=pole.lerp(shoulder+Vector((sign*.35*h,.08*h,-.2*h)),amount)
   if name in {'typing','working'}:
    target.z+=.0035*h*math.sin(phase*4+(0 if side=='l' else 1.4));target.y+=.006*h*math.sin(phase*2)
   if name in {'thinking','reviewing','learning'} and side=='r':target=rig.pos(rig.head)+Vector((.05*h,-.085*h,-.085*h));target.z+=.004*h*math.sin(phase)
   if name in {'talking','requesting_approval'}:target.z+=.045*h*(1+math.sin(phase+(0 if side=='l' else 1.0)));target.x+=sign*.025*h*math.sin(phase)
   if name=='blocked':target.z+=.018*h*(1+math.sin(phase));target.x+=sign*.025*h
  if name in COFFEE:
   if side=='r':
    # Normalized height is fixed while walking: knees absorb the gait, cup
    # stays upright and does not bounce with the pelvis.
    carry=o+Vector((-.16*h,-.17*h,.18*h));target=carry
    if name=='preparing_coffee':target=(o+Vector((-.15*h,-.31*h,.13*h))).lerp(carry,ramp(u,.48,.88))
    if sip:target=carry.lerp(rig.pos(rig.head)+Vector((-.062*h,-.10*h,.025*h)),sip)
    pole=shoulder+Vector((-.30*h,.03*h,-.16*h))
   elif name=='preparing_coffee':
    press=ramp(u,.08,.23)*(1-ramp(u,.43,.64));target=standing.lerp(o+Vector((.13*h,-.34*h,.31*h)),press)
    target.y-=.015*h*math.sin(math.pi*ramp(u,.25,.38))**2*press
   elif name=='talking_coffee':
    gesture=.5-.5*math.cos(phase);target=o+Vector((.17*h+.035*h*math.sin(phase),-.16*h,.13*h+.065*h*gesture))
  if name=='playing_foosball':
   stroke=math.sin(phase+(0 if side=='l' else 1.1))
   ns=h/1.75;target=Vector((o.x+sign*.19*ns,o.y+(-.36+sign*.030*stroke)*ns,rig.floor+.956*ns))
   pole=shoulder+Vector((sign*.3*h,.03*h,-.20*h))
  if name=='celebrating':
   raised=math.sin(math.pi*u)**2;target=shoulder+Vector((sign*(.1+.10*raised)*h,-.05*h,(-.3+.57*raised)*h));pole=shoulder+Vector((sign*h,0,0))
  requested=target.copy();direction=target-shoulder
  if direction.length>total*.97:target=shoulder+direction.normalized()*total*.97
  rig.ik(l['arm'],l['elbow'],l['hand'],target,pole)
  if name=='playing_foosball':rig.foos_hand_error=max(getattr(rig,'foos_hand_error',0),(rig.pos(l['hand'])-requested).length*1.75/h)
  forearm=(rig.pos(l['hand'])-rig.pos(l['elbow'])).normalized()
  down=Vector((sign*.03,-.05,-1)).normalized();rest_back=Vector((sign,0,0))
  if seat:
   fingers=down.lerp(Vector((sign*.08,-1,-.16)).normalized(),amount).normalized();back=rest_back.lerp(Vector((0,0,1)),amount).normalized()
  elif name in COFFEE and side=='r':fingers=tilt@Vector((0,0,-1));back=tilt@Vector((-1,0,0))
  elif name=='talking_coffee' and side=='l':fingers=Vector((.35,-1,.1)).normalized();back=Vector((0,0,-1))
  elif name=='preparing_coffee' and side=='l':
   press=ramp(u,.08,.23)*(1-ramp(u,.43,.64));fingers=down.lerp(Vector((0,-1,-.12)).normalized(),press).normalized();back=rest_back.lerp(Vector((0,0,1)),press).normalized()
  elif name=='playing_foosball':
   twist=.24*math.sin(phase*2+(0 if side=='l' else 1.3));rotation=Quaternion((1,0,0),twist)
   fingers=rotation@Vector((0,-.3,-1)).normalized();back=rotation@Vector((0,-1,.3)).normalized()
  elif name=='celebrating':fingers=Vector((sign*.15,-.12,-1+2*math.sin(math.pi*u)**2)).normalized();back=rest_back
  else:fingers=down;back=rest_back
  back=(back-fingers*back.dot(fingers)).normalized();across=fingers.cross(back).normalized();goal=Matrix((across,fingers,back)).transposed().to_quaternion()
  current=rig.pose[l['hand']].to_quaternion()@rig.rest[l['hand']].to_quaternion().inverted()@rig.hand_frames[side]
  present=current@Vector((0,0,1));present=(present-forearm*present.dot(forearm)).normalized();targetback=(back-forearm*back.dot(forearm)).normalized()
  roll=math.atan2(forearm.dot(present.cross(targetback)),present.dot(targetback));rig.offset_rotation(l['elbow'],forearm,roll)
  rig.rotate_world(l['hand'],goal@rig.hand_frames[side].inverted()@rig.rest[l['hand']].to_quaternion())
  if 'root.x' in rig.names and ((name in COFFEE and side=='r') or name=='playing_foosball'):
   # The authored Rigify character has actual finger joints. Curl them around
   # the cup handle / rod instead of leaving an open, flat greeting hand.
   for finger in ['index','middle','ring','pinky']:
    for segment,angle in [(1,.50),(2,.75),(3,.55)]:
     bone=f'{finger}{segment}.{side}'
     if bone in rig.names:rig.offset_rotation(bone,across,-angle)
 if 'cup_socket' in rig.names:
  hand=rig.pos(rig.limbs['r']['hand']);ns=h/1.75
  center=hand+tilt@Vector((.075*ns,0,-.035*ns))
  rig.transform_world('cup_socket',center,tilt@rig.rest['cup_socket'].to_quaternion(),1 if name in COFFEE else .0001)
 return feet

def channel_curves(action):
 return [fc for layer in action.layers for strip in layer.strips for cb in strip.channelbags for fc in cb.fcurves]

def camera_at(location,target,scale):
 data=bpy.data.cameras.new('QualityCamera');obj=bpy.data.objects.new('QualityCamera',data);bpy.context.scene.collection.objects.link(obj)
 obj.location=location;obj.rotation_euler=(Vector(target)-obj.location).to_track_quat('-Z','Y').to_euler();data.type='ORTHO';data.ortho_scale=scale;bpy.context.scene.camera=obj
 return obj

def render_preview(rig,actions,path):
 # Freeze evaluated deformations at representative poses, as a true Blender
 # contact sheet with consistent scale, lighting and front/three-quarter views.
 scene=bpy.context.scene;scene.render.engine='BLENDER_EEVEE';scene.render.resolution_x=1600;scene.render.resolution_y=1500;scene.render.resolution_percentage=100
 scene.render.image_settings.file_format='PNG';scene.world=bpy.data.worlds.new('Studio');scene.world.color=(.16,.16,.16)
 scene.view_settings.view_transform='AgX'
 previews=[]
 names=['idle','walking','walking_coffee','sit_down','sitting','sitting_sofa','stand_up','preparing_coffee','carrying_coffee','drinking_coffee','talking_coffee','playing_foosball']
 for i,name in enumerate(names):
  action=actions[name];rig.arm.animation_data.action=action
  scene.frame_set(round(action.frame_range[1]*(.5 if name in {'sit_down','stand_up','drinking_coffee'} else .23)));bpy.context.view_layer.update()
  dg=bpy.context.evaluated_depsgraph_get()
  offset=Vector(((i%4)*1.18*rig.height,0,-(i//4)*1.45*rig.height))
  rot=Matrix.Rotation(.32,4,'Z')
  for obj in rig.meshes:
   evaluated=obj.evaluated_get(dg);mesh=bpy.data.meshes.new_from_object(evaluated,depsgraph=dg)
   snap=bpy.data.objects.new(name+'-'+obj.name,mesh);scene.collection.objects.link(snap);snap.matrix_world=Matrix.Translation(offset)@rot@obj.matrix_world;previews.append(snap)
  data=bpy.data.curves.new(name,'FONT');data.body=name;data.align_x='CENTER';data.size=.065*rig.height
  text=bpy.data.objects.new(name,data);scene.collection.objects.link(text);text.location=offset+Vector((0,-.3*rig.height,-.14*rig.height));text.rotation_euler=(math.pi/2,0,0);previews.append(text)
 for obj in rig.meshes:obj.hide_render=True
 target=Vector((1.7*rig.height,0,-.8*rig.height));camera_at(target+Vector((0,-8*rig.height,1.0*rig.height)),target,5.35*rig.height)
 for name,pos,energy,size,color in [('Key',(-2,-4,5),1200,5,(1,.89,.78)),('Fill',(5,-3,3),900,5,(.7,.82,1)),('Rim',(2,2,4),1500,4,(.74,.91,1))]:
  data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.shape='DISK';data.size=size;data.color=color
  obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);obj.location=target+Vector(pos);obj.rotation_euler=(target-obj.location).to_track_quat('-Z','Y').to_euler()
 scene.render.filepath=str(path);bpy.ops.render.render(write_still=True)
 for obj in rig.meshes:obj.hide_render=False


def export_avatar(arm,meshes,output):
 bpy.ops.object.select_all(action='DESELECT');arm.select_set(True)
 for obj in meshes:obj.select_set(True)
 bpy.context.view_layer.objects.active=arm
 bpy.ops.export_scene.gltf(filepath=str(output),export_format='GLB',use_selection=True,export_animations=True,export_animation_mode='ACTIONS',export_frame_range=False,export_force_sampling=True,export_anim_slide_to_zero=True,export_skins=True,export_morph=True,export_apply=False,export_rest_position_armature=True,export_draco_mesh_compression_enable=True,export_draco_position_quantization=16,export_draco_normal_quantization=12,export_draco_texcoord_quantization=14,export_draco_generic_quantization=16,export_optimize_animation_size=False)

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);parser.add_argument('--only');parser.add_argument('--preview',action='store_true');parser.add_argument('--save-blend',action='store_true');parser.add_argument('--from-blend',type=Path)
 args=parser.parse_args(sys.argv[sys.argv.index('--')+1:]);args.output.mkdir(parents=True,exist_ok=True)
 entries=[(key,entry['path']) for key,entry in json.loads((ROOT/'assets/avatar-authoring-sources.json').read_text())['avatars'].items()]
 report=json.loads((args.output/'report.json').read_text()) if args.only and (args.output/'report.json').exists() else {}
 for key,path in entries:
  if args.only and key!=args.only:continue
  print('AUTHOR',key,flush=True);original=ROOT/'apps/web/public'/path.lstrip('/')
  if args.from_blend:
   bpy.ops.wm.open_mainfile(filepath=str(args.from_blend/(key+'.blend')))
   arm=next(obj for obj in bpy.data.objects if obj.type=='ARMATURE');arm.animation_data_clear()
   for action in list(bpy.data.actions):bpy.data.actions.remove(action)
   meshes=[obj for obj in bpy.data.objects if obj.type=='MESH' and obj.vertex_groups];repaired=0
  else:arm,meshes,repaired=source(original,args.output/'source-without-clips.glb')
  rig=Rig(arm,meshes);bind_height=rig.height;rig.walk_duration=WALK_DURATION_OVERRIDES.get(key,DURATIONS['walking'])
  # Match referenceHeight in the native scene: bounds of the actual skinned
  # idle(0) pose, not the undeformed T-pose stored in the GLB vertex buffer.
  for iteration in range(2):
   animate(rig,'idle',0);rig.apply(None);bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get();zs=[]
   for obj in meshes:
    evaluated=obj.evaluated_get(dg);mesh=evaluated.to_mesh();zs.extend((obj.matrix_world@v.co).z for v in mesh.vertices);evaluated.to_mesh_clear()
   rig.height=max(zs)-min(zs)
  reference_height=rig.height
  meshes=add_cup(rig);rig=Rig(arm,meshes);rig.height=reference_height;rig.walk_duration=WALK_DURATION_OVERRIDES.get(key,DURATIONS['walking'])
  normalize_avatar_materials(meshes)
  scene=bpy.context.scene;scene.render.fps=FPS;scene.frame_start=0;actions={};metrics={}
  for name,duration in DURATIONS.items():
   if name in {'walking','walking_coffee'}:duration=rig.walk_duration
   action=bpy.data.actions.new(name);action.use_fake_user=True;arm.animation_data_create();arm.animation_data.action=action
   frames=round(duration*FPS);max_contact=0;rig.max_ik_error=0
   for frame in range(frames+1):
    # Loops close exactly; one-shot transitions retain their final pose.
    u=frame/frames if frame<frames or name in NON_LOOP else 0
    feet=animate(rig,name,u);rig.apply(frame)
    for side,limb in rig.limbs.items():max_contact=max(max_contact,(rig.pos(limb['foot'])-feet[side]).length)
   for fc in channel_curves(action):
    for kp in fc.keyframe_points:kp.interpolation='LINEAR'
   actions[name]=action;metrics[name]={'duration_seconds':duration,'frames':frames+1,'foot_target_error_m':max_contact,'max_ik_target_error_m':rig.max_ik_error}
   if name in CHAIR_LOCOMOTION:metrics[name].update(reference_speed_mps=CHAIR_SPEED,distance_per_cycle_m=CHAIR_SPEED*duration)
   if name=='playing_foosball':metrics[name].update(max_runtime_hand_target_error_m=rig.foos_hand_error,handle_height_m=.956,forward_reach_m=.36,hand_spacing_m=.38,extra_torso_lean_rad=rig.foos_extra_lean,pelvis_advance_m=.10,pelvis_drop_m=.09+rig.foos_extra_drop_m)
  arm.animation_data.action=actions['idle'];scene.frame_set(0);bpy.context.view_layer.update()
  bpy.ops.object.select_all(action='DESELECT');arm.select_set(True)
  for obj in meshes:obj.select_set(True)
  bpy.context.view_layer.objects.active=arm
  output=args.output/(key+'.glb')
  export_avatar(arm,meshes,output)
  if args.save_blend:bpy.ops.wm.save_as_mainfile(filepath=str(args.output/(key+'.blend')))
  if args.preview:render_preview(rig,actions,args.output/(key+'-contact-sheet.png'))
  sha=hashlib.sha256(output.read_bytes()).hexdigest()
  report[key]={'source':path,'output':str(output),'sha256':sha,'bytes':output.stat().st_size,'height_m':rig.height,'bind_height_m':bind_height,'reference_height_source':'evaluated idle frame zero','material_policy':True,'non_loop_clips':sorted(NON_LOOP),'normalized_weight_vertices':repaired,'bones':len(rig.names),'walk_speed_at_1_75_m':WALK_SPEED,'clips':metrics}
  (args.output/'report.json').write_text(json.dumps(report,indent=2));print('FINISHED',key,sha,flush=True)
if __name__=='__main__':main()
