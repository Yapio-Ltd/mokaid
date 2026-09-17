#!/usr/bin/env python3
"""Author distinct gait, social life, desk phone and seated coffee in Blender.

The material-corrected 28-clip sources remain in artifacts/avatar-quality.
New editable sources, GLBs and measurements are staged in artifacts/avatar-life.
"""
from __future__ import annotations
import argparse,hashlib,json,math,runpy,sys
from pathlib import Path
import bpy,bmesh
import numpy as np
from mathutils import Matrix,Quaternion,Vector
BASE=runpy.run_path(str(Path(__file__).with_name('blender-avatar-quality.py')))
ROOT=Path(__file__).resolve().parents[1]
FPS=60;TAU=math.tau
smooth=BASE['smooth'];ramp=BASE['ramp'];Rig=BASE['Rig']
NEW_CLIPS=dict(walking_brisk=.72,walking_relaxed=1.1,typing_focused=2.8,typing_relaxed=5.,
 phone_pickup=1.1,phone_call=5.,phone_putdown=1.,greeting=1.2,laughing=3.,laughing_coffee=3.,talking_standing=5.,
 sitting_sofa_coffee=4.,talking_sofa_coffee=5.,drinking_sofa_coffee=3.6,laughing_sofa_coffee=3.,
 sit_down_sofa_coffee=1.,stand_up_sofa_coffee=1.,talking_sofa_coffee_left=5.,talking_sofa_coffee_right=5.,coffee_putdown=1.1)
DURATIONS=BASE['DURATIONS']|NEW_CLIPS
NON_LOOP=BASE['NON_LOOP']|{'phone_pickup','phone_putdown','greeting','laughing','laughing_coffee','laughing_sofa_coffee','sit_down_sofa_coffee','stand_up_sofa_coffee','coffee_putdown'}
SOFA_COFFEE={n for n in NEW_CLIPS if 'sofa_coffee' in n}
COFFEE=BASE['COFFEE']|SOFA_COFFEE|{'laughing_coffee','coffee_putdown'}
PHONE_CLIPS={'phone_pickup','phone_call','phone_putdown'}
PHONE_DESK=BASE['DESK']|PHONE_CLIPS|{'typing_focused','typing_relaxed'}
WALKS={'walking','walking_coffee','walking_brisk','walking_relaxed'}
WALK_SPEEDS=dict(walking=1.,walking_coffee=1.,walking_brisk=1.35,walking_relaxed=.7)
GAITS={
 'avatar_male':dict(label='purposeful',period=.90,bob=.0028,sway=.0055,arm_swing=.43,lift=.041,yaw=.024),
 'avatar_design':dict(label='light and quick',period=.84,bob=.0030,sway=.0080,arm_swing=.49,lift=.050,yaw=.032),
 'avatar_finance':dict(label='measured',period=.88,bob=.0018,sway=.0038,arm_swing=.27,lift=.033,yaw=.017),
 'avatar_corporate':dict(label='deliberate',period=.96,bob=.0022,sway=.0048,arm_swing=.34,lift=.035,yaw=.020),
 'avatar_legal':dict(label='smooth',period=.94,bob=.0020,sway=.0060,arm_swing=.30,lift=.037,yaw=.022),
 'avatar_research':dict(label='nimble',period=.60,bob=.0038,sway=.0075,arm_swing=.45,lift=.045,yaw=.030),
 'avatar_developer':dict(label='loose',period=.92,bob=.0038,sway=.0082,arm_swing=.52,lift=.046,yaw=.035),
}
# Coordinates are normalized metres, Blender (right=+X, front=-Y, height=Z).
# The phone uses LeftHand, the source skeleton's hand on +X, nearest the dock.
PHONE_DOCK=Vector((.30,-.40,.778))
PHONE_CENTER=Vector((.30,-.40,.783))
PHONE_FLAT=Matrix((Vector((0,0,1)),Vector((-1,0,0)),Vector((0,-1,0)))).transposed().to_quaternion()
PHONE_HELD=Quaternion((0,0,1),math.pi)
PHONE_OFFSET=PHONE_HELD.inverted()@Vector((-.023,0,.035))

def add_bone(arm,name,parent,head,tail):
 bpy.context.view_layer.objects.active=arm;arm.select_set(True);bpy.ops.object.mode_set(mode='EDIT')
 bone=arm.data.edit_bones.new(name);bone.parent=arm.data.edit_bones[parent];bone.use_connect=False
 bone.head=arm.matrix_world.inverted()@head;bone.tail=arm.matrix_world.inverted()@tail
 bpy.ops.object.mode_set(mode='OBJECT')

def hand_geometry(rig,side):
 hand=rig.limbs[side]['hand'];wrist=rig.rest[hand].translation;frame=rig.hand_frames[side]
 axes=[frame@Vector(axis) for axis in [(1,0,0),(0,1,0),(0,0,1)]];points=[];refs=[]
 for obj in rig.meshes:
  group=obj.vertex_groups.get(hand)
  if not group:continue
  for vertex in obj.data.vertices:
   weight=next((g.weight for g in vertex.groups if g.group==group.index),0)
   if weight>.5:
    delta=obj.matrix_world@vertex.co-wrist;points.append([delta.dot(axis) for axis in axes]);refs.append((obj,vertex.index,weight))
 values=np.array(points);length=float(np.quantile(values[:,1],.99))
 if 'root.x' in rig.names:
  # Hand weights omit the separately rigged fingers, so use their true tips.
  tips=[rig.rest[n].translation for n in rig.names if n.startswith(('index3.','middle3.','ring3.','pinky3.')) and n.endswith('.'+side)]
  length=max(length,max((v-wrist).dot(axes[1]) for v in tips)*1.18)
 return dict(wrist=wrist,axes=axes,points=values,refs=refs,length=length)

def repair_legal_weights(arm,meshes,height):
 """Remove imported hand influences from the robe and shoes.

 The source labels garment vertices near the lowered hands as hand skin.
 Identify actual exposed hands using both their location and atlas colour;
 rebind the remaining lower garment to the nearby hip/leg segments.
 """
 ns=height/1.75;rest={b.name:arm.matrix_world@b.matrix_local for b in arm.data.bones};hands={s:rest[s+'Hand'].translation for s in ['Left','Right']};changed=0;actual_hands={s:0 for s in hands}
 segments={}
 for side in hands:
  for name,end in [('UpLeg','Leg'),('Leg','Foot'),('Foot','ToeBase')]:
   a=rest[side+name].translation;b=rest[side+end].translation if side+end in rest else a+Vector((0,-.10*ns,0));segments[side+name]=(a,b)
 hips=rest['Hips'].translation;segments['Hips']=(hips,rest['Spine02'].translation)
 def distance(point,a,b):
  delta=b-a;t=max(0,min(1,(point-a).dot(delta)/max(1e-9,delta.length_squared)));return (point-a-delta*t).length
 for obj in meshes:
  if obj.name=='OfficeCoffeeCup':continue
  skin=np.zeros(len(obj.data.vertices),dtype=bool);uv=obj.data.uv_layers.active;cache={}
  if uv:
   for polygon in obj.data.polygons:
    atlas_material=obj.data.materials[polygon.material_index];images=[n.image for n in atlas_material.node_tree.nodes if n.type=='TEX_IMAGE' and n.image]
    if not images:continue
    image=images[0]
    if image.name not in cache:cache[image.name]=np.array(image.pixels[:]).reshape((image.size[1],image.size[0],4))
    pixels=cache[image.name];height_px,width_px=pixels.shape[:2]
    for loop in polygon.loop_indices:
     tex=uv.data[loop].uv;r,g,b=pixels[min(height_px-1,max(0,int(tex.y*height_px))),min(width_px-1,max(0,int(tex.x*width_px))),:3]
     if r>.25 and g>.12 and r>b*1.12:skin[obj.data.loops[loop].vertex_index]=True
  # Include dark palm creases and fingertips adjoining the skin samples.
  # Colour alone creates an alternating hand/robe assignment at UV shadows.
  coords=np.array([list(obj.matrix_world@v.co) for v in obj.data.vertices]);hand_ids={}
  for side,wrist in hands.items():
   candidates=np.where((np.linalg.norm(coords-np.array(wrist),axis=1)<.21*ns)&(coords[:,2]>wrist.z-.20*ns)&(coords[:,2]<wrist.z+.035*ns)&(np.abs(coords[:,0])>.14*ns))[0]
   seeds=candidates[skin[candidates]];selected=[]
   for index in candidates:
    if len(seeds) and np.min(np.linalg.norm(coords[seeds]-coords[index],axis=1))<.011*ns:selected.append(index)
   hand_ids[side]=set(selected)
  sleeve_ids={}
  for side,wrist in hands.items():
   sign=1 if side=='Left' else -1;elbow=rest[side+'ForeArm'].translation
   sleeve_ids[side]=set(np.where((coords[:,0]*sign>.14*ns)&(coords[:,2]>wrist.z-.045*ns)&(coords[:,2]<elbow.z+.025*ns))[0])-hand_ids[side]
  for vertex in obj.data.vertices:
   point=obj.matrix_world@vertex.co;old={obj.vertex_groups[g.group].name:g.weight for g in vertex.groups};side=min(hands,key=lambda s:(point-hands[s]).length);wrist=hands[side]
   hand_region=(point-wrist).length<.21*ns and point.z>wrist.z-.20*ns and point.z<wrist.z+.10*ns and abs(point.x)>.14*ns
   if vertex.index in hand_ids[side]:
    weights={side+'Hand':1.};actual_hands[side]+=1
   elif vertex.index in sleeve_ids[side]:
    blend=smooth((point.z-(rest[side+'ForeArm'].translation.z-.080*ns))/(.105*ns));weights={n:w*blend for n,w in old.items()};weights[side+'ForeArm']=weights.get(side+'ForeArm',0)+1-blend
    weights=dict(sorted(weights.items(),key=lambda p:-p[1])[:4]);total=sum(weights.values());weights={n:w/total for n,w in weights.items() if w>1e-9}
   elif point.z<rest[side+'ForeArm'].translation.z+.020*ns and any(('Hand' in n or 'ForeArm' in n) and w>0 for n,w in old.items()):
    # Smooth inverse-distance binding stays within the four-joint GPU limit.
    nearest=sorted(((n,distance(point,a,b)) for n,(a,b) in segments.items()),key=lambda pair:pair[1])[:4]
    weights={n:1/(d+.035*ns)**4 for n,d in nearest};total=sum(weights.values());weights={n:w/total for n,w in weights.items()}
   else:continue
   for group_index in [g.group for g in vertex.groups]:obj.vertex_groups[group_index].remove([vertex.index])
   for name,weight in weights.items():(obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)).add([vertex.index],weight,'REPLACE')
   changed+=1
  # The generated source also welded the lowered fingertips to the robe.
  # Remove only that invalid bridge and close its boundary on each surface.
  limb_ids={s:hand_ids[s]|sleeve_ids[s] for s in hands};labels={i:s+'_hand' for s,ids in hand_ids.items() for i in ids}|{i:s+'_sleeve' for s,ids in sleeve_ids.items() for i in ids};bad=[]
  for polygon in obj.data.polygons:
   for side,wrist in hands.items():
    count=sum(i in limb_ids[side] for i in polygon.vertices)
    if 0<count<len(polygon.vertices) and max(coords[i,2] for i in polygon.vertices)<rest[side+'ForeArm'].translation.z+.020*ns:bad.append(polygon.index);break
    hand_count=sum(i in hand_ids[side] for i in polygon.vertices)
    if 0<hand_count<len(polygon.vertices) and max(coords[i,2] for i in polygon.vertices)<wrist.z-.010*ns:bad.append(polygon.index);break
  if bad:
   bm=bmesh.new();bm.from_mesh(obj.data);bm.faces.ensure_lookup_table();removed=[bm.faces[i] for i in bad];edges={e for f in removed for e in f.edges};bmesh.ops.delete(bm,geom=removed,context='FACES_ONLY')
   boundary=[e for e in edges if e.is_valid and e.is_boundary];remaining=set(boundary);closed=[]
   hand_material=len(obj.data.materials);obj.data.materials.append(material('Legal inner hand repair',(.67,.42,.30,1)))
   robe_material=len(obj.data.materials);obj.data.materials.append(material('Legal inner robe repair',(.045,.050,.060,1),.9))
   # A generic hole fill reconnects the two surfaces. Split each boundary
   # loop by anatomical surface and close hand and garment independently.
   while remaining:
    edge=min(remaining,key=lambda e:e.index);start=edge.verts[0];current=start;previous=None;loop=[]
    while True:
     loop.append(current);options=[e for e in current.link_edges if e in remaining]
     if not options:break
     edge=options[0];remaining.remove(edge);current=edge.other_vert(current)
     if current==start:break
    for label in ['Left_hand','Left_sleeve','Right_hand','Right_sleeve',None]:
     vertices=list(dict.fromkeys(v for v in loop if labels.get(v.index)==label))
     if len(vertices)>=3:
      try:face=bm.faces.new(vertices)
      except ValueError:continue # boundary already closed by a retained face
      face.material_index=hand_material if label and label.endswith('_hand') else robe_material;closed.append(face)
   bmesh.ops.triangulate(bm,faces=closed)
   wires=[e for e in bm.edges if e.is_wire]
   if wires:bmesh.ops.delete(bm,geom=wires,context='EDGES')
   bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(obj.data);bm.free();obj.data.update()
   print('LEGAL topology bridge faces removed',len(bad),'independent closed patches',len(closed),flush=True)
 return {'reweighted_vertices':changed,'exposed_hand_vertices':actual_hands,'removed_bridge_faces':len(bad),'closed_surface_patches':len(closed) if bad else 0,'method':'atlas skin + anatomical hand region; cuffs bound to forearm; lower garment hip/leg binding; independently close welded limb/robe bridges'}

def add_grip_bones(rig):
 """Give fused Meshy finger geometry a smooth two-joint collective curl.

 Existing topology, UVs and bind positions remain identical. Distal geometry
 identifies the four-finger span; the lateral thumb stays on its own joint.
 """
 report={}
 if 'root.x' in rig.names:return {'existing_articulated_fingers':True}
 for side in ['l','r']:
  data=hand_geometry(rig,side);length=data['length'];points=data['points'];wrist=data['wrist'];across,forward,back=data['axes']
  distal=points[points[:,1]>.70*length];lower,upper=np.quantile(distal[:,0],[.01,.99]);margin=.06*length
  for name,start,end in [('grip_prox',.43,.69),('grip_dist',.69,.94)]:
   add_bone(rig.arm,name+'.'+side,rig.limbs[side]['hand'] if name=='grip_prox' else 'grip_prox.'+side,wrist+forward*length*start,wrist+forward*length*end)
  thumb_mask=((points[:,0]<lower-margin)|(points[:,0]>upper+margin))&(points[:,1]>.20*length)
  thumb_points=points[thumb_mask]
  thumb_sign=1 if len(thumb_points) and float(thumb_points[:,0].mean())>0 else -1
  thumb_head=wrist+forward*.30*length+across*(upper if thumb_sign>0 else lower)*.65
  thumb_direction=(forward*.35+across*thumb_sign*.65).normalized()
  add_bone(rig.arm,'grip_thumb.'+side,rig.limbs[side]['hand'],thumb_head,thumb_head+thumb_direction*.30*length)
  changed=0
  for (obj,index,weight),point in zip(data['refs'],points):
   a,f,b=point;hand=rig.limbs[side]['hand'];old=obj.vertex_groups[hand]
   is_thumb=(a<lower-margin or a>upper+margin) and f>.20*length
   if is_thumb:
    blend=smooth((abs(a-(lower+upper)/2)-(upper-lower)*.40)/(.25*length))
    assignments=[(hand,1-blend),('grip_thumb.'+side,blend)]
   elif lower-margin<=a<=upper+margin and f>.36*length:
    if f<.49*length:
     blend=smooth((f/length-.36)/.13);assignments=[(hand,1-blend),('grip_prox.'+side,blend)]
    else:
     blend=smooth((f/length-.62)/.15);assignments=[('grip_prox.'+side,1-blend),('grip_dist.'+side,blend)]
   else:continue
   groups=[g for g in obj.data.vertices[index].groups if g.weight>0]
   if len(groups)>=4:assignments=[max(assignments,key=lambda pair:pair[1])];assignments=[(assignments[0][0],1)]
   old.remove([index])
   for name,fraction in assignments:
    if fraction>1e-6:(obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)).add([index],weight*fraction,'REPLACE')
   changed+=1
  report[side]={'hand_length_m':length,'weighted_vertices':changed,'thumb_sign':thumb_sign,'new_joints':['grip_prox.'+side,'grip_dist.'+side,'grip_thumb.'+side]}
 return report

def material(name,color,rough=.7):
 mat=bpy.data.materials.new(name);mat.use_nodes=True;mat.diffuse_color=color
 node=mat.node_tree.nodes.get('Principled BSDF');node.inputs['Base Color'].default_value=color;node.inputs['Metallic'].default_value=0;node.inputs['Roughness'].default_value=rough
 return mat

def rigid_mesh(rig,name,bone,verts,faces,materials,indices):
 mesh=bpy.data.meshes.new(name);mesh.from_pydata(verts,[],faces);mesh.update()
 obj=bpy.data.objects.new(name,mesh);bpy.context.scene.collection.objects.link(obj)
 for mat in materials:mesh.materials.append(mat)
 for polygon,index in zip(mesh.polygons,indices):polygon.material_index=index
 obj.vertex_groups.new(name=bone).add(list(range(len(verts))),1,'REPLACE');obj.modifiers.new('RigidAccessorySkin','ARMATURE').object=rig.arm
 return obj

def add_phone(rig):
 ns=rig.height/1.75;center=rig.rest[rig.limbs['l']['hand']].translation+Vector((0,0,.04*ns))
 add_bone(rig.arm,'phone_socket',rig.limbs['l']['hand'],center,center+Vector((0,0,.07*ns)))
 verts=[];faces=[];indices=[];ring=[]
 # Rounded rectangle in YZ, extruded through X; front screen and rear case.
 for cy,cz,start in [(.026,.064,0),(-.026,.064,math.pi/2),(-.026,-.064,math.pi),(.026,-.064,3*math.pi/2)]:
  for step in range(6):
   angle=start+step*math.pi/10;ring.append((cy+.010*math.cos(angle),cz+.010*math.sin(angle)))
 n=len(ring)
 for x in [-.005,.005]:
  for y,z in ring:verts.append(tuple(center+Vector((x,y,z))*ns))
 faces.extend([tuple(reversed(range(n))),tuple(range(n,2*n))]);indices.extend([0,1])
 for i in range(n):faces.append((i,(i+1)%n,(i+1)%n+n,i+n));indices.append(0)
 case=material('Desktop phone',(.055,.065,.075,1));screen=material('Desktop phone screen',(.016,.030,.045,1),.65)
 phone=rigid_mesh(rig,'OfficePhone','phone_socket',verts,faces,[case,screen],indices)
 dock_center=rig.origin+PHONE_DOCK*ns;dock_center.z=rig.floor+PHONE_DOCK.z*ns
 add_bone(rig.arm,'phone_dock_socket',rig.hips,dock_center,dock_center+Vector((0,0,.06*ns)))
 verts=[tuple(dock_center+Vector((x,y,z))*ns) for x,y,z in [(-.050,-.087,-.016),(.050,-.087,-.016),(.050,.087,-.016),(-.050,.087,-.016),(-.050,-.087,0),(.050,-.087,0),(.050,.087,0),(-.050,.087,0)]]
 faces=[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)]
 dock=rigid_mesh(rig,'OfficePhoneDock','phone_dock_socket',verts,faces,[material('Desktop phone dock',(.085,.10,.11,1))],[0]*6)
 return rig.meshes+[phone,dock]

def set_hand(rig,side,target,fingers,back):
 limb=rig.limbs[side];h=rig.height;sign=1 if side=='l' else -1
 for bone in [limb['arm'],limb['elbow'],limb['hand']]:rig.basis[bone]=Matrix.Identity(4)
 rig.recalculate();shoulder=rig.pos(limb['arm'])
 total=(rig.rest[limb['elbow']].translation-rig.rest[limb['arm']].translation).length+(rig.rest[limb['hand']].translation-rig.rest[limb['elbow']].translation).length
 requested=target.copy();delta=target-shoulder
 if delta.length>total*.98:target=shoulder+delta.normalized()*total*.98
 rig.ik(limb['arm'],limb['elbow'],limb['hand'],target,shoulder+Vector((sign*.30*h,.05*h,-.20*h)))
 fingers=fingers.normalized();back=(back-fingers*back.dot(fingers)).normalized();across=fingers.cross(back).normalized()
 goal=Matrix((across,fingers,back)).transposed().to_quaternion()
 forearm=(rig.pos(limb['hand'])-rig.pos(limb['elbow'])).normalized()
 current=rig.pose[limb['hand']].to_quaternion()@rig.rest[limb['hand']].to_quaternion().inverted()@rig.hand_frames[side]
 present=current@Vector((0,0,1));present=(present-forearm*present.dot(forearm)).normalized();targetback=(back-forearm*back.dot(forearm)).normalized()
 roll=math.atan2(forearm.dot(present.cross(targetback)),present.dot(targetback));rig.offset_rotation(limb['elbow'],forearm,roll)
 rig.rotate_world(limb['hand'],goal@rig.hand_frames[side].inverted()@rig.rest[limb['hand']].to_quaternion())
 return (rig.pos(limb['hand'])-requested).length*1.75/h

def grip(rig,side,kind,strength=1.):
 limb=rig.limbs[side];frame=rig.pose[limb['hand']].to_quaternion()@rig.rest[limb['hand']].to_quaternion().inverted()@rig.hand_frames[side]
 across=frame@Vector((1,0,0));forward=frame@Vector((0,1,0));length=rig.hand_lengths[side]*1.75/rig.height
 if kind=='cup':angles=(.56,.88,.58)
 elif kind=='phone':
  amount=min(1,max(0,(length-.13)/.13));angles=(.16+.35*amount,.25+.50*amount,.18+.25*amount)
 elif kind=='typing':angles=(.07,.12,.04)
 else:angles=(.20,.26,.14)
 if 'root.x' in rig.names:
  names=[n for n in rig.names if n.startswith(('index','middle','ring','pinky','thumb')) and n.endswith('.'+side)]
  for name in names:rig.basis[name]=Matrix.Identity(4)
  rig.recalculate()
  for finger in ['index','middle','ring','pinky']:
   for segment,angle in enumerate(angles,1):
    name=f'{finger}{segment}.{side}'
    if name in rig.names:rig.offset_rotation(name,across,-angle*strength)
  for segment,angle in [(1,.22),(2,.36),(3,.20)]:
   name=f'thumb{segment}.{side}'
   if name in rig.names:rig.offset_rotation(name,across,-angle*strength)
 else:
  for name in ['grip_prox.'+side,'grip_dist.'+side,'grip_thumb.'+side]:rig.basis[name]=Matrix.Identity(4)
  rig.recalculate();rig.offset_rotation('grip_prox.'+side,across,-angles[0]*strength);rig.offset_rotation('grip_dist.'+side,across,-angles[1]*strength)
  sign=rig.grip_report[side]['thumb_sign'];rig.offset_rotation('grip_thumb.'+side,forward,sign*.28*strength)


def gait_config(key,name):
 gait=dict(GAITS[key]);gait['stance']=.6;gait['lean']=0
 period=gait.pop('period');gait.pop('label')
 if name=='walking_brisk':
  period*=.78;gait['arm_swing']*=1.35;gait['lift']*=1.12;gait['sway']*=.8;gait['lean']=.015
 elif name=='walking_relaxed':
  period*=1.22;gait['arm_swing']*=.65;gait['lift']*=.80;gait['sway']*=1.10;gait['yaw']*=.8
 elif name=='walking_coffee':
  period*=.88;gait['arm_swing']*=.45;gait['lift']*=.72;gait['sway']*=.45;gait['bob']*=.35;gait['yaw']*=.4
 return round(period*FPS)/FPS,gait

def anchor(rig,value):
 p=rig.origin+value*(rig.height/1.75);p.z=rig.floor+value.z*(rig.height/1.75);return p

def replant(rig,feet):
 for side,l in rig.limbs.items():
  rig.ik(l['thigh'],l['knee'],l['foot'],feet[side],rig.pos(l['thigh'])+Vector((0,-rig.height,0)))
  rig.rotate_world(l['foot'],rig.rest[l['foot']].to_quaternion())

def reach_body(rig,feet,amount,standing=False):
 ns=rig.height/1.75;root_offset=rig.pos(rig.hips)-rig.rest[rig.hips].translation
 root_offset.y-=getattr(rig,'coffee_forward_m',.10)*ns*amount if standing else getattr(rig,'phone_forward_m',.06)*ns*amount
 if standing:root_offset.z-=getattr(rig,'coffee_drop_m',.12)*ns*amount
 rig.move_root(root_offset)
 rig.offset_rotation(rig.hips,(1,0,0),.08*amount)
 for bone in rig.spine:rig.offset_rotation(bone,(1,0,0),.12*amount)
 replant(rig,feet)

def phone_pose(rig,name,u,feet):
 ns=rig.height/1.75;phase=TAU*u
 t=1-u if name=='phone_putdown' else u
 holding=1 if name=='phone_call' else ramp(t,.40,.83)
 grasp=1 if name=='phone_call' else ramp(t,.25,.39)
 approaching=1 if name=='phone_call' else ramp(t,.06,.26)
 reach=(1-holding)*approaching
 # Small forward pelvic roll and thorax lean keep short arms within reach.
 reach_body(rig,feet,reach)
 rig.offset_rotation(rig.head,(0,0,1),-.06*holding)
 if name=='phone_call':rig.offset_rotation(rig.head,(1,0,0),.025*math.sin(phase*2))
 dock=anchor(rig,PHONE_CENTER)
 head_motion=rig.pose[rig.head].to_quaternion()@rig.rest[rig.head].to_quaternion().inverted()
 ear=rig.pos(rig.head)+head_motion@Vector((rig.ear_width,0,.09*ns))
 phone_center=dock.lerp(ear,holding);phone_rotation=PHONE_FLAT.slerp(PHONE_HELD,holding)
 # Grip the outer edge while the device is flat. Keeping the wrist above
 # its centre lets the rotating phone slice through the palm mid-pickup.
 offset=Vector((-.068,0,-.025)).lerp(Vector((-.023,0,.035)),holding)*ns
 contact=phone_center-offset
 hand=rig.pos(rig.limbs['l']['hand']);target=hand.lerp(contact,approaching)
 fingers=Vector((0,-1,0)).lerp(Vector((0,0,1)),holding).normalized();back=Vector((1,0,0))
 current=rig.pose[rig.limbs['l']['hand']].to_quaternion()@rig.rest[rig.limbs['l']['hand']].to_quaternion().inverted()@rig.hand_frames['l']
 if approaching>1e-9:
  error=set_hand(rig,'l',target,(current@Vector((0,1,0))).lerp(fingers,approaching),(current@Vector((0,0,1))).lerp(back,approaching))
  if grasp>.99:rig.phone_hand_error=max(getattr(rig,'phone_hand_error',0),error)
 if grasp>0:grip(rig,'l','phone',grasp)
 # Before grasp the phone stays on its dock. Once lifted, it is rigid in hand.
 if holding>0:phone_center=rig.pos(rig.limbs['l']['hand'])+offset
 rig.transform_world('phone_socket',phone_center,phone_rotation@rig.rest['phone_socket'].to_quaternion(),1)


def coffee_machine(rig,name,u,feet):
 ns=rig.height/1.75;t=1-u if name=='coffee_putdown' else u
 grasp=ramp(t,.24,.39);lift=ramp(t,.40,.84);reach=ramp(t,.04,.24)*(1-lift)
 reach_body(rig,feet,reach,standing=True)
 tray=anchor(rig,Vector((-.20,-.45,.764913)))
 carry=rig.carry_target+rig.cup_offset
 center=tray.lerp(carry,lift);target=center-rig.cup_offset
 start=rig.pos(rig.limbs['r']['hand']);target=start.lerp(target,ramp(t,.04,.24))
 amount=ramp(t,.04,.24)
 current=rig.pose[rig.limbs['r']['hand']].to_quaternion()@rig.rest[rig.limbs['r']['hand']].to_quaternion().inverted()@rig.hand_frames['r']
 if amount>1e-9:
  error=set_hand(rig,'r',target,(current@Vector((0,1,0))).lerp(Vector((0,0,-1)),amount),(current@Vector((0,0,1))).lerp(Vector((-1,0,0)),amount))
  if grasp>.99:rig.coffee_hand_error=max(getattr(rig,'coffee_hand_error',0),error)
  if getattr(rig,'probe',False) and grasp>.99 and error>.003:print('COFFEE CLAMP',rig.key,name,round(u,3),round(error,4),'lift',round(lift,3),'reach',round(reach,3),flush=True)
 grip(rig,'r','cup',grasp)
 if lift>0:center=rig.pos(rig.limbs['r']['hand'])+rig.cup_offset
 if name=='preparing_coffee':
  press=ramp(t,.28,.40)*(1-ramp(t,.55,.68))
  if press>0:
   hand=rig.pos(rig.limbs['l']['hand']);button=anchor(rig,Vector((.11,-.43,1.02)))
   set_hand(rig,'l',hand.lerp(button,press),Vector((0,-1,-.10)),Vector((0,0,1)))
 # A released cup is transferred under the machine canopy, after contact.
 visible=.0001 if name=='coffee_putdown' and t<.12 else 1
 rig.transform_world('cup_socket',center,rig.rest['cup_socket'].to_quaternion(),visible)


def animate(rig,name,u):
 phase=TAU*u;h=rig.height;ns=h/1.75
 rig.gait={};BASE['animate'].__globals__['WALK_SPEED']=1
 if name in WALKS:
  rig.walk_duration,rig.gait=gait_config(rig.key,name);BASE['animate'].__globals__['WALK_SPEED']=WALK_SPEEDS[name]
  base_name='walking_coffee' if name=='walking_coffee' else 'walking';base_u=u
 elif name in PHONE_CLIPS:base_name='typing';base_u=u if name=='phone_call' else 0
 elif name in {'typing_focused','typing_relaxed'}:base_name='typing';base_u=u
 elif name in SOFA_COFFEE:
  base_name='sit_down_sofa' if name=='sit_down_sofa_coffee' else 'stand_up_sofa' if name=='stand_up_sofa_coffee' else 'sitting_sofa';base_u=u
 elif name in {'greeting','laughing','talking_standing'}:base_name='idle';base_u=u
 elif name in {'laughing_coffee'}:base_name='carrying_coffee';base_u=u
 elif name in {'preparing_coffee','coffee_putdown'}:base_name='idle';base_u=0
 else:base_name=name;base_u=u
 feet=BASE['animate'](rig,base_name,base_u)
 # Default accessory state is explicit in every action, so crossfades never
 # inherit a phone or dock from a sparse previous clip.
 dock=anchor(rig,PHONE_DOCK);phone=anchor(rig,PHONE_CENTER)
 rig.transform_world('phone_dock_socket',dock,rig.rest['phone_dock_socket'].to_quaternion(),1 if name in PHONE_DESK else .0001)
 rig.transform_world('phone_socket',phone,PHONE_FLAT@rig.rest['phone_socket'].to_quaternion(),1 if name in PHONE_DESK else .0001)
 if name in {'typing','working','typing_focused','typing_relaxed'}|PHONE_CLIPS:
  focus={'typing':.7,'working':.5,'typing_focused':1.,'typing_relaxed':.35}.get(name,.7)
  pause=1 if name!='typing_relaxed' else .3+.7*max(0,math.sin(phase))
  for side in ['l','r']:
   hand=rig.pos(rig.limbs[side]['hand']);beat=math.sin(phase*6+(0 if side=='l' else 1.6))
   target=hand+Vector((.004*h*math.sin(phase*2),0,.0018*h*beat*focus*pause))
   set_hand(rig,side,target,Vector(((1 if side=='l' else -1)*.08,-1,-.16)),Vector((0,0,1)))
   grip(rig,side,'typing',focus*pause*(.6+.4*beat))
  if name=='typing_relaxed':rig.offset_rotation(rig.head,(0,0,1),.07*math.sin(phase));rig.offset_rotation(rig.head,(1,0,0),-.045*max(0,-math.sin(phase)))
 if name=='playing_foosball':
  for side in ['l','r']:grip(rig,side,'cup',.8)
 if name in PHONE_CLIPS:phone_pose(rig,name,u,feet)
 if name in {'greeting','laughing','laughing_coffee','talking_standing','talking_sofa_coffee','talking_sofa_coffee_left','talking_sofa_coffee_right','laughing_sofa_coffee'}:
  laughing=name.startswith('laughing');envelope=math.sin(math.pi*u)**2 if laughing or name=='greeting' else 1
  if laughing:
   for bone in rig.spine:rig.offset_rotation(bone,(1,0,0),.020*envelope*math.sin(phase*3))
   rig.offset_rotation(rig.head,(1,0,0),-.055*envelope+.025*envelope*math.sin(phase*3))
  if name.startswith('talking_sofa_coffee'):
   direction=1 if name.endswith('_left') else -1 if name.endswith('_right') else 0
   for bone in rig.spine:rig.offset_rotation(bone,(0,0,1),direction*.035)
   rig.offset_rotation(rig.head,(0,0,1),direction*.33+.022*math.sin(phase))
  if name=='greeting' and envelope>1e-9:
   hand=rig.pos(rig.limbs['r']['hand']);shoulder=rig.pos(rig.limbs['r']['arm'])
   target=hand.lerp(shoulder+Vector((-.10*h,-.10*h,.10*h)),envelope)
   current=rig.pose[rig.limbs['r']['hand']].to_quaternion()@rig.rest[rig.limbs['r']['hand']].to_quaternion().inverted()@rig.hand_frames['r']
   wave=Quaternion((0,1,0),.16*math.sin(phase*2)*envelope)
   set_hand(rig,'r',target,(current@Vector((0,1,0))).lerp(wave@Vector((0,0,1)),envelope),(current@Vector((0,0,1))).lerp(Vector((0,1,0)),envelope));grip(rig,'r','typing',.2*envelope)
  elif name!='greeting' and (not laughing or envelope>1e-9):
   for side in (['l'] if name in COFFEE else ['l','r']):
    sign=1 if side=='l' else -1;hip=rig.pos(rig.hips);hand=rig.pos(rig.limbs[side]['hand'])
    if laughing:target=hand.lerp(hip+Vector((sign*.11*h,-.12*h,.16*h)),envelope)
    else:target=hip+Vector((sign*(.15+.022*math.sin(phase))*h,-.15*h,(.14+.045*(.5-.5*math.cos(phase+(0 if side=='l' else 1.3))))*h))
    set_hand(rig,side,target,Vector((sign*.25,-1,.05)),Vector((0,0,-1)));grip(rig,side,'typing',.25*envelope)
  replant(rig,feet)
 if name in COFFEE and name not in {'preparing_coffee','coffee_putdown'}:
  sofa=name in SOFA_COFFEE;transition=name in {'sit_down_sofa_coffee','stand_up_sofa_coffee'}
  amount=(1-smooth(u) if name.startswith('stand_up') else smooth(u)) if transition else float(sofa)
  carry=rig.carry_target;seated=rig.pos(rig.hips)+Vector((-.15*h,-.15*h,.18*h))
  target=carry.lerp(seated,amount)
  sip=ramp(u,.12,.37)*(1-ramp(u,.60,.86)) if name in {'drinking_coffee','drinking_sofa_coffee'} else 0
  if sip:target=target.lerp(rig.pos(rig.head)+Vector((-.062*h,-.10*h,.025*h)),sip)
  tilt=Quaternion((1,0,0),-.38*sip)
  set_hand(rig,'r',target,tilt@Vector((0,0,-1)),tilt@Vector((-1,0,0)));grip(rig,'r','cup')
  center=rig.pos(rig.limbs['r']['hand'])+tilt@rig.cup_offset
  rig.transform_world('cup_socket',center,tilt@rig.rest['cup_socket'].to_quaternion(),1)
 if name in {'preparing_coffee','coffee_putdown'}:coffee_machine(rig,name,u,feet)
 return feet

def preview(rig,actions,path):
 scene=bpy.context.scene;names=['walking_relaxed','walking','walking_brisk','walking_coffee',
 'typing_focused','typing_relaxed','phone_pickup','phone_call',
 'phone_putdown','greeting','laughing_coffee','talking_standing',
 'sit_down_sofa_coffee','sitting_sofa_coffee','talking_sofa_coffee_left','drinking_sofa_coffee',
 'talking_sofa_coffee_right','laughing_sofa_coffee','preparing_coffee','coffee_putdown']
 for i,name in enumerate(names):
  action=actions[name];rig.arm.animation_data.action=action
  phase=.5 if name in {'phone_pickup','phone_putdown','sit_down_sofa_coffee','drinking_sofa_coffee','coffee_putdown'} else .28
  frame=action.frame_range[1]*phase;scene.frame_set(int(frame),subframe=frame%1);bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get()
  offset=Vector(((i%4)*1.15*rig.height,0,-(i//4)*1.35*rig.height));rotation=Matrix.Rotation(.28,4,'Z')
  for obj in rig.meshes:
   mesh=bpy.data.meshes.new_from_object(obj.evaluated_get(dg),depsgraph=dg);snap=bpy.data.objects.new(name+' '+obj.name,mesh);scene.collection.objects.link(snap);snap.matrix_world=Matrix.Translation(offset)@rotation@obj.matrix_world
  data=bpy.data.curves.new(name,'FONT');data.body=name;data.align_x='CENTER';data.size=.043*rig.height
  text=bpy.data.objects.new(name,data);scene.collection.objects.link(text);text.location=offset+Vector((0,-.30*rig.height,-.14*rig.height));text.rotation_euler=(math.pi/2,0,0)
 for obj in rig.meshes:obj.hide_render=True
 scene.world=bpy.data.worlds.new('LifeStudio');scene.world.color=(.15,.15,.15);scene.render.engine='BLENDER_EEVEE';scene.view_settings.view_transform='AgX'
 scene.render.resolution_x=1800;scene.render.resolution_y=2450;scene.render.resolution_percentage=100;scene.render.image_settings.file_format='PNG'
 target=Vector((1.72*rig.height,0,-2.25*rig.height));BASE['camera_at'](target+Vector((0,-9*rig.height,.75*rig.height)),target,6.95*rig.height)
 for name,position,energy,color in [('Key',(-2,-4,4),1600,(1,.89,.8)),('Fill',(5,-3,2),1200,(.75,.84,1)),('Rim',(2,2,4),1800,(.74,.91,1))]:
  data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.size=6;data.color=color
  obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);obj.location=target+Vector(position);obj.rotation_euler=(target-obj.location).to_track_quat('-Z','Y').to_euler()
 scene.render.filepath=str(path);bpy.ops.render.render(write_still=True)


def calibrate_cup(rig):
 # Solve grip against the actual deformed hand surface. A wrist/socket
 # distance alone can pass while curled fingers penetrate the cup bowl.
 BASE['animate'](rig,'idle',0);set_hand(rig,'r',rig.carry_target,Vector((0,0,-1)),Vector((-1,0,0)));grip(rig,'r','cup');rig.apply(None)
 bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get();points=[];wrist=rig.pos(rig.limbs['r']['hand']);ns=rig.height/1.75
 names={'hand.r','RightHand','grip_prox.r','grip_dist.r','grip_thumb.r'}|{n for n in rig.names if n.startswith(('thumb','index','middle','ring','pinky')) and n.endswith('.r')}
 for obj in rig.meshes:
  ids=[v.index for v in obj.data.vertices if any(obj.vertex_groups[g.group].name in names and g.weight>.25 for g in v.groups)]
  if not ids:continue
  evaluated=obj.evaluated_get(dg);mesh=evaluated.to_mesh();points.extend(list((obj.matrix_world@mesh.vertices[i].co-wrist)/ns) for i in ids);evaluated.to_mesh_clear()
 point_sets=[np.array(points)]
 if rig.key=='avatar_legal':
  # This mesh has long fingers with some wrist/forearm blended weights.
  # Solve against seated and sipping deformations as well as neutral carry.
  for seated,sipping in [(True,False),(False,True)]:
   BASE['animate'](rig,'sitting_sofa' if seated else 'idle',0)
   target=rig.pos(rig.hips)+Vector((-.15*rig.height,-.15*rig.height,.18*rig.height)) if seated else rig.pos(rig.head)+Vector((-.062*rig.height,-.10*rig.height,.025*rig.height))
   tilt=Quaternion((1,0,0),-.38 if sipping else 0)
   set_hand(rig,'r',target,tilt@Vector((0,0,-1)),tilt@Vector((-1,0,0)));grip(rig,'r','cup');rig.apply(None);bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get();wrist=rig.pos(rig.limbs['r']['hand']);sample=[]
   for obj in rig.meshes:
    ids=[v.index for v in obj.data.vertices if any(obj.vertex_groups[g.group].name in names and g.weight>.25 for g in v.groups)]
    if not ids:continue
    evaluated=obj.evaluated_get(dg);mesh=evaluated.to_mesh();sample.extend(list(tilt.inverted()@(obj.matrix_world@mesh.vertices[i].co-wrist)/ns) for i in ids);evaluated.to_mesh_clear()
   point_sets.append(np.array(sample))
 points=np.concatenate(point_sets);length=rig.hand_lengths['r']/ns;best=None
 for x in np.linspace(.065,.17,43):
  for y in [-.015,-.0075,0,.0075,.015]:
   for z in np.linspace(-.60*length,-.22*length,30):
    local=points-np.array((x,y,z));interior=(local[:,0]**2+local[:,1]**2<.035**2)&(np.abs(local[:,2])<.051)
    if np.any(interior):continue
    torus=np.sqrt((np.sqrt((local[:,0]+.053)**2+local[:,2]**2)-.030)**2+local[:,1]**2)-.006
    gap=max(float(np.abs(part).min()) for part in np.split(torus,np.cumsum([len(p) for p in point_sets])[:-1]));contacts=int(np.count_nonzero(np.abs(torus)<.006))
    if gap>.007:continue
    score=gap+.012*abs(x-.09)+.015*abs(z+.38*length)+.02*abs(y)-min(contacts,30)*.000025
    if best is None or score<best[0]:best=(score,x,y,z,gap,contacts)
 assert best is not None,(rig.key,'no surface-conforming cup grip')
 _,x,y,z,gap,contacts=best;rig.cup_offset=Vector((x,y,z))*ns
 rig.cup_surface_calibration={'analytic_handle_gap_m':gap,'near_handle_vertices':contacts,'bowl_interior_vertices':0,'hand_vertices':len(points),'cup_offset_m':[x,y,z]}
 rig.reset()

def calibrate_reach(rig):
 ns=rig.height/1.75
 # Use measured limb lengths, not a guess based on avatar height. Pelvic
 # motion stays inside a planted-foot IK pose; no arm or leg is stretched.
 rig.gait={};rig.walk_duration=gait_config(rig.key,'walking')[0]
 BASE['animate'](rig,'idle',0);limb=rig.limbs['r'];shoulder=rig.pos(limb['arm'])
 desired=rig.origin+Vector((-.16*rig.height,-.17*rig.height,.18*rig.height));length=(rig.rest[limb['elbow']].translation-rig.rest[limb['arm']].translation).length+(rig.rest[limb['hand']].translation-rig.rest[limb['elbow']].translation).length
 delta=desired-shoulder;rig.carry_target=shoulder+delta.normalized()*min(delta.length,length*.90)
 calibrate_cup(rig)
 for kind,side in [('coffee','r'),('phone','l')]:
  limb=rig.limbs[side];length=(rig.rest[limb['elbow']].translation-rig.rest[limb['arm']].translation).length+(rig.rest[limb['hand']].translation-rig.rest[limb['elbow']].translation).length
  for step in range(20):
   forward=(.10 if kind=='coffee' else .06)+step*.01
   setattr(rig,kind+'_forward_m',forward)
   feet=BASE['animate'](rig,'idle' if kind=='coffee' else 'typing',0);reach_body(rig,feet,1,standing=kind=='coffee')
   target=anchor(rig,Vector((-.20,-.45,.764913)))-rig.cup_offset if kind=='coffee' else anchor(rig,PHONE_CENTER)-Vector((-.068,0,-.025))*ns
   delta=rig.pos(limb['arm'])-target
   horizontal=delta.x*delta.x+delta.y*delta.y
   if kind=='coffee' and horizontal<(.78*length)**2:break
   if kind=='phone' and delta.length<length*.94:break
  if kind=='coffee':
   rig.coffee_drop_m=.12+max(0,(delta.z-math.sqrt(max(1e-8,(length*.94)**2-horizontal)))/ns)
  else:
   assert delta.length<length*.98,(rig.key,'phone reach cannot be calibrated',delta.length/ns,length/ns)
 rig.reset()

def repair_legal_torso_and_cuffs(rig):
 """Keep the entire central robe on the body; soften the wrist skin seam."""
 obj=next(o for o in rig.meshes if o.name=='char1');ns=rig.height/1.75;torso=0;cuffs=0
 levels=sorted([(rig.rest[n].translation.z,n) for n in [rig.hips,'Spine02','Spine01','Spine']]);arm_names={n for n in rig.names if 'Hand' in n or 'ForeArm' in n or n.endswith('Arm') or 'Shoulder' in n or n.startswith('grip_')}
 for vertex in obj.data.vertices:
  p=obj.matrix_world@vertex.co;old={obj.vertex_groups[g.group].name:g.weight for g in vertex.groups};weights=None
  if (abs(p.x)<.13 or (abs(p.x)<.18 and not any(n in arm_names and w>1e-5 for n,w in old.items()))) and .20<p.z<1.02:
   if p.z>=levels[0][0]:
    a,b=next(((a,b) for a,b in zip(levels,levels[1:]) if a[0]<=p.z<=b[0]),(levels[-2],levels[-1]));t=max(0,min(1,(p.z-a[0])/(b[0]-a[0])));weights={a[1]:1-t,b[1]:t}
   elif any(n in arm_names and w>0 for n,w in old.items()):
    weights={n:w for n,w in old.items() if n not in arm_names};total=sum(weights.values());weights={n:w/total for n,w in weights.items()} if total else {rig.hips:1.}
   if weights is not None:torso+=1
  if weights is None and not any(n.startswith('grip_') and w>.01 for n,w in old.items()):
   for side,limb in rig.limbs.items():
    wrist=rig.rest[limb['hand']].translation
    if (p-wrist).length<.095*ns and wrist.z-.018*ns<p.z<wrist.z+.06*ns and sum(old.get(n,0) for n in [limb['hand'],limb['elbow']])>.95:
     t=smooth((wrist.z+.04*ns-p.z)/(.06*ns));weights={limb['hand']:t,limb['elbow']:1-t};cuffs+=1;break
  if weights is not None:
   for index in [g.group for g in vertex.groups]:obj.vertex_groups[index].remove([vertex.index])
   for name,weight in weights.items():
    if weight>1e-8:(obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)).add([vertex.index],weight,'REPLACE')
 for polygon in obj.data.polygons:
  if obj.data.materials[polygon.material_index].name.startswith('Legal inner'):polygon.use_smooth=True
 return {'central_torso_vertices':torso,'wrist_transition_vertices':cuffs,'central_robe_bounds':{'abs_x_lt':.13,'z_min':.20,'z_max':1.02}}

def rebuild_legal_flanks(rig):
 """Rebuild the two robe side openings without reconnecting either sleeve.

 UV seams are merged only on body-bound vertices. The new thin panels use
 the original cloth atlas and retain body-only skinning at their boundary.
 Their triangulation is computed in each flank's Y/Z plane, never between
 the independently moving wrist and skirt surfaces.
 """
 from mathutils.geometry import delaunay_2d_cdt
 obj=next(o for o in rig.meshes if o.name=='char1')
 if obj.get('legal_flank_repair'):return json.loads(obj['legal_flank_repair'])
 bm=bmesh.new();bm.from_mesh(obj.data);bm.verts.ensure_lookup_table();deform=bm.verts.layers.deform.active;uv=bm.loops.layers.uv.active
 arm_names={n for n in rig.names if 'Hand' in n or 'ForeArm' in n or n.endswith('Arm') or 'Shoulder' in n or n.startswith('grip_')}
 def body(v):return sum(w for g,w in v[deform].items() if obj.vertex_groups[g].name in arm_names)<1e-5
 bmesh.ops.remove_doubles(bm,verts=[v for v in bm.verts if body(v)],dist=.00001)
 material_index=next(i for i,m in enumerate(obj.data.materials) if m.name=='Material_1')
 # Pick an existing black-cloth texel on the intact centre of the robe.
 candidates=[];atlas=obj.data.materials[material_index];image=next(n.image for n in atlas.node_tree.nodes if n.type=='TEX_IMAGE' and n.image);pixels=np.array(image.pixels[:]).reshape((image.size[1],image.size[0],4))
 for f in bm.faces:
  if f.material_index!=material_index:continue
  for loop in f.loops:
   p=obj.matrix_world@loop.vert.co
   if abs(p.x)<.09 and .50<p.z<.72:
    tex=loop[uv].uv;rgb=pixels[min(image.size[1]-1,max(0,int(tex.y*image.size[1]))),min(image.size[0]-1,max(0,int(tex.x*image.size[0]))),:3]
    if max(rgb)-min(rgb)<.03 and .012<float(np.mean(rgb))<.12:candidates.append((float(np.mean(rgb)),tex.copy()))
 assert candidates,'No intact cloth sample found'
 candidates.sort(key=lambda p:p[0]);cloth_uv=candidates[len(candidates)//2][1]
 oldcaps=[f for f in bm.faces if obj.data.materials[f.material_index].name=='Legal inner robe repair' and all(body(v) for v in f.verts)]
 bmesh.ops.delete(bm,geom=oldcaps,context='FACES_ONLY')
 remapped=0
 for f in bm.faces:
  if obj.data.materials[f.material_index].name=='Legal inner robe repair':
   f.material_index=material_index;f.smooth=True;remapped+=1
   for loop in f.loops:loop[uv].uv=cloth_uv
 edges={e for e in bm.edges if e.is_boundary and all(body(v) for v in e.verts) and all(.42<(obj.matrix_world@v.co).z<1.025 and abs((obj.matrix_world@v.co).x)>.03 for v in e.verts)};panels=[]
 while edges:
  stack=[edges.pop()];component=[]
  while stack:
   edge=stack.pop();component.append(edge)
   for v in edge.verts:
    for adjacent in v.link_edges:
     if adjacent in edges:edges.remove(adjacent);stack.append(adjacent)
  vertices=list(dict.fromkeys(v for e in component for v in e.verts))
  if len(vertices)<12:continue
  points=[obj.matrix_world@v.co for v in vertices];sign=1 if sum(p.x for p in points)>0 else -1
  if any(p.x*sign<0 for p in points):continue
  projected=[Vector((p.y,p.z)) for p in points];result=delaunay_2d_cdt(projected,[],[],0,1e-7,True);new_verts=[]
  for p,origin in zip(result[0],result[3]):
   ids=list(origin) or [min(range(len(projected)),key=lambda i:(projected[i]-p).length)];x=sum(points[i].x for i in ids)/len(ids)+sign*.0006;v=bm.verts.new(obj.matrix_world.inverted()@Vector((x,p.x,p.y)));weights={}
   for i in ids:
    for g,w in vertices[i][deform].items():weights[g]=weights.get(g,0)+w/len(ids)
   weights=dict(sorted(weights.items(),key=lambda kv:-kv[1])[:4]);total=sum(weights.values())
   for g,w in weights.items():v[deform][g]=w/total
   new_verts.append(v)
  count=0
  for ids in result[2]:
   if len(ids)!=3:continue
   f=bm.faces.new([new_verts[i] for i in ids]);f.material_index=material_index;f.smooth=True;f.normal_update()
   if f.normal.x*sign<0:f.normal_flip()
   for loop in f.loops:loop[uv].uv=cloth_uv
   count+=1
  panels.append({'side':int(sign),'vertices':len(new_verts),'triangles':count,'upper_limb_weight':0.})
 # All existing surface normals follow the repaired topology. Panels are
 # independently oriented outwards above, so no fill can bridge the cuffs.
 bm.normal_update();bm.to_mesh(obj.data);bm.free();obj.data.update()
 print('LEGAL reconstructed cloth panels',panels,'atlas UV',list(cloth_uv),flush=True)
 result={'panels':panels,'removed_old_body_cap_faces':len(oldcaps),'retinted_cuff_cap_faces':remapped,'cloth_uv':list(cloth_uv),'material':'Material_1','outward_clearance_m':.0006}
 obj['legal_flank_repair']=json.dumps(result);return result

def remove_degenerate_skin_bridges(rig,actions):
 # The generated cloth contains a few residual welded sliver triangles
 # around open cuffs. Remove their union over articulated poses. Do not
 # refill these tiny garment openings across independently moving parts.
 weights_repair=repair_legal_torso_and_cuffs(rig);obj=next(o for o in rig.meshes if o.name=='char1');scale=1.75/rig.height
 edges=np.array([list(e.vertices) for e in obj.data.edges]);points=np.array([list(obj.matrix_world@v.co) for v in obj.data.vertices]);rest=np.linalg.norm(points[edges[:,0]]-points[edges[:,1]],axis=1);bad_edges=np.zeros(len(edges),dtype=bool)
 sampled=0
 for name in actions:
  rig.arm.animation_data.action=actions[name]
  for phase in np.linspace(0,1,max(33,min(121,round(actions[name].frame_range[1])+1))):
   frame=actions[name].frame_range[1]*phase;bpy.context.scene.frame_set(int(frame),subframe=frame%1);bpy.context.view_layer.update();evaluated=obj.evaluated_get(bpy.context.evaluated_depsgraph_get());mesh=evaluated.to_mesh();coords=np.empty(len(mesh.vertices)*3);mesh.vertices.foreach_get('co',coords);coords=coords.reshape((-1,3));matrix=np.array(obj.matrix_world);posed=coords@matrix[:3,:3].T+matrix[:3,3];evaluated.to_mesh_clear();length=np.linalg.norm(posed[edges[:,0]]-posed[edges[:,1]],axis=1);sampled+=1
   bad_edges|=(length>rest*8)&((rest>.002)|((length-rest)*scale>.025))
 bad_pairs={tuple(sorted(e)) for e in edges[bad_edges]};bad_faces=[f.index for f in obj.data.polygons if any(tuple(sorted(e)) in bad_pairs for e in f.edge_keys)]
 if bad_faces:
  bm=bmesh.new();bm.from_mesh(obj.data);bm.faces.ensure_lookup_table();bmesh.ops.delete(bm,geom=[bm.faces[i] for i in bad_faces],context='FACES_ONLY');wires=[e for e in bm.edges if e.is_wire]
  if wires:bmesh.ops.delete(bm,geom=wires,context='EDGES')
  bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(obj.data);bm.free();obj.data.update()
 print('LEGAL residual welded slivers removed',len(bad_faces),flush=True)
 return {'sampled_poses':sampled,'clips':len(actions),'removed_welded_sliver_triangles':len(bad_faces),'ratio_threshold':8,'growth_threshold_m':.025,'weights_repair':weights_repair}

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--source',type=Path,default=ROOT/'artifacts/avatar-quality');parser.add_argument('--output',type=Path,default=ROOT/'artifacts/avatar-life');parser.add_argument('--only');parser.add_argument('--preview',action='store_true');parser.add_argument('--probe',action='store_true');parser.add_argument('--clips',nargs='+')
 args=parser.parse_args(sys.argv[sys.argv.index('--')+1:]);args.output.mkdir(parents=True,exist_ok=True)
 source_report=json.loads((args.source/'report.json').read_text());report=json.loads((args.output/'report.json').read_text()) if (args.output/'report.json').exists() else {}
 for key,old in source_report.items():
  if args.only and key not in args.only.split(','):continue
  print('AUTHOR LIFE',key,flush=True);bpy.ops.wm.open_mainfile(filepath=str(args.source/(key+'.blend')))
  arm=next(obj for obj in bpy.data.objects if obj.type=='ARMATURE');arm.animation_data_clear()
  for action in list(bpy.data.actions):bpy.data.actions.remove(action)
  meshes=[obj for obj in bpy.data.objects if obj.type=='MESH' and obj.vertex_groups]
  repair=repair_legal_weights(arm,meshes,old['height_m']) if key=='avatar_legal' else None
  rig=Rig(arm,meshes);rig.height=old['height_m']
  before=[(obj.name,hashlib.sha256(np.array([list(v.co) for v in obj.data.vertices],dtype='<f4').tobytes()).hexdigest()) for obj in meshes]
  hand_frames={side:q.copy() for side,q in rig.hand_frames.items()};hand_lengths={side:hand_geometry(rig,side)['length'] for side in ['l','r']}
  grips=add_grip_bones(rig);meshes=add_phone(rig);rig=Rig(arm,meshes);rig.height=old['height_m'];rig.key=key;rig.grip_report=grips
  rig.hand_frames=hand_frames;rig.hand_lengths=hand_lengths
  rig.cup_offset=Vector((.063*rig.height/1.75,0,-.38*rig.hand_lengths['r']))
  ns=rig.height/1.75;head=rig.rest[rig.head].translation
  head_points=[]
  for obj in meshes:
   group=obj.vertex_groups.get(rig.head)
   if group:
    for vertex in obj.data.vertices:
     p=obj.matrix_world@vertex.co
     if head.z+.02*ns<p.z<head.z+.18*ns and any(g.group==group.index and g.weight>.7 for g in vertex.groups):head_points.append(p.x-head.x)
  rig.ear_width=max(.080*ns,min(.16*ns,float(np.quantile(head_points,.92)) if head_points else .11*ns))+.013*ns
  calibrate_reach(rig)
  if args.probe:
   rig.probe=True
   for name in ['phone_pickup','phone_call','phone_putdown','preparing_coffee','coffee_putdown']:
    for frame in range(49):animate(rig,name,frame/48)
   print('REACH PROBE',key,'coffee forward/drop',rig.coffee_forward_m,rig.coffee_drop_m,'phone forward',rig.phone_forward_m,'phone error',getattr(rig,'phone_hand_error',0),'coffee error',getattr(rig,'coffee_hand_error',0),flush=True)
   continue
  BASE['normalize_avatar_materials'](meshes);bpy.context.scene.render.fps=FPS;actions={};metrics={}
  if args.clips:
   assert set(args.clips)<=set(DURATIONS)
   with bpy.data.libraries.load(str(args.output/(key+'.blend'))) as (available,loaded):loaded.actions=[n for n in DURATIONS if n not in args.clips]
   actions={a.name:a for a in loaded.actions};metrics={n:m for n,m in report[key]['clips'].items() if n not in args.clips}
   for action in actions.values():action.use_fake_user=True
  for name,default_duration in DURATIONS.items():
   if args.clips and name not in args.clips:continue
   duration,gait=gait_config(key,name) if name in WALKS else (default_duration,{})
   rig.walk_duration=gait_config(key,'walking')[0];action=bpy.data.actions.new(name);action.use_fake_user=True;arm.animation_data_create();arm.animation_data.action=action
   frames=round(duration*FPS);max_contact=0;rig.max_ik_error=0
   for frame in range(frames+1):
    u=frame/frames if frame<frames or name in NON_LOOP else 0
    feet=animate(rig,name,u);rig.apply(frame)
    for side,limb in rig.limbs.items():max_contact=max(max_contact,(rig.pos(limb['foot'])-feet[side]).length*1.75/rig.height)
   for curve in BASE['channel_curves'](action):
    for point in curve.keyframe_points:point.interpolation='LINEAR'
   metrics[name]={'duration_seconds':duration,'frames':frames+1,'foot_target_error_m':max_contact,'max_ik_target_error_m':rig.max_ik_error,'loop':name not in NON_LOOP}
   if name in WALKS:metrics[name].update(reference_speed_mps=WALK_SPEEDS[name],gait=gait)
   actions[name]=action
  sliver_repair=remove_degenerate_skin_bridges(rig,actions) if key=='avatar_legal' else None
  if sliver_repair is not None:sliver_repair['flank_surface_repair']=rebuild_legal_flanks(rig)
  arm.animation_data.action=actions['idle'];bpy.context.scene.frame_set(0);bpy.context.view_layer.update()
  output=args.output/(key+'.glb');BASE['export_avatar'](arm,meshes,output)
  blend=args.output/(key+'.blend');saved=blend.with_suffix('.updated.blend') if args.clips else blend
  bpy.ops.wm.save_as_mainfile(filepath=str(saved))
  if saved!=blend:saved.replace(blend)
  after=[(obj.name,hashlib.sha256(np.array([list(v.co) for v in obj.data.vertices],dtype='<f4').tobytes()).hexdigest()) for obj in meshes if obj.name not in {'OfficePhone','OfficePhoneDock'}]
  if key!='avatar_legal':assert before==after,'source geometry changed'
  report[key]={'source_blend':str(args.source/(key+'.blend')),'source':old['source'],'height_m':rig.height,'output':str(output),'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'bytes':output.stat().st_size,'bones':len(rig.names),'gait_signature':GAITS[key]['label'],'grip_rigging':grips,'original_vertex_positions_preserved':True,'hand_lengths_m':rig.hand_lengths,'cup_surface_calibration':rig.cup_surface_calibration,'cup_offset_m':list(rig.cup_offset/ns),'carry_hand_m':list((rig.carry_target-rig.origin)/ns),'phone_dock_m':list(PHONE_DOCK),'phone_center_m':list(PHONE_CENTER),'coffee_forward_m':rig.coffee_forward_m,'coffee_drop_m':rig.coffee_drop_m,'phone_forward_m':rig.phone_forward_m,'phone_grasp_target_error_m':getattr(rig,'phone_hand_error',0),'coffee_grasp_target_error_m':getattr(rig,'coffee_hand_error',0),'non_loop_clips':sorted(NON_LOOP),'clips':metrics}
  if repair:report[key].update(source_weight_repair=repair,source_topology_repair=sliver_repair,original_vertex_positions_preserved=False)
  (args.output/'report.json').write_text(json.dumps(report,indent=2))
  print('EXPORTED LIFE',key,report[key]['sha256'],'phone error',report[key]['phone_grasp_target_error_m'],'coffee error',report[key]['coffee_grasp_target_error_m'],flush=True)
  if args.preview:preview(rig,actions,args.output/(key+'-contact-sheet.png'))
if __name__=='__main__':main()
