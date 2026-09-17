#!/usr/bin/env python3
"""Audit the catalogued Legal mesh, including all clips and transition blends.

The robe test measures skin dependency on upper limbs, independently of edge
stretch. Blender reimports the delivered GLB rather than trusting its author.
"""
import bpy,sys,json,hashlib,math,runpy
import numpy as np
from pathlib import Path
from mathutils import Vector,Quaternion,Matrix
source=Path(sys.argv[sys.argv.index('--')+1]).resolve();out=Path(sys.argv[sys.argv.index('--')+2]).resolve();out.mkdir(parents=True,exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True);bpy.context.scene.render.fps=60;bpy.ops.import_scene.gltf(filepath=str(source));arm=next(o for o in bpy.data.objects if o.type=='ARMATURE');meshes=[o for o in bpy.data.objects if o.type=='MESH' and o.vertex_groups];obj=next(o for o in meshes if o.name=='char1');actions={a.name:a for a in bpy.data.actions};scene=bpy.context.scene
def points():
 evaluated=obj.evaluated_get(bpy.context.evaluated_depsgraph_get());mesh=evaluated.to_mesh();coords=np.empty(len(mesh.vertices)*3);mesh.vertices.foreach_get('co',coords);coords=coords.reshape((-1,3));matrix=np.array(obj.matrix_world);result=coords@matrix[:3,:3].T+matrix[:3,3];evaluated.to_mesh_clear();return result
def action_pose(name,phase):
 arm.animation_data.action=actions[name];f=actions[name].frame_range[1]*phase;scene.frame_set(int(f),subframe=f%1);bpy.context.view_layer.update()
def basis():return {b.name:b.matrix_basis.decompose() for b in arm.pose.bones}
def blended(a,b,t):
 arm.animation_data.action=None
 for name,(p,q,s) in a.items():
  bp,bq,bs=b[name];bone=arm.pose.bones[name];bone.location=p.lerp(bp,t);bone.rotation_mode='QUATERNION';bone.rotation_quaternion=q.slerp(bq,t);bone.scale=s.lerp(bs,t)
 bpy.context.view_layer.update()
action_pose('idle',0);reference=points();height=reference[:,2].max()-reference[:,2].min();scale=1.75/height
rest=np.array([list(obj.matrix_world@v.co) for v in obj.data.vertices]);edges=np.array([list(e.vertices) for e in obj.data.edges]);rest_lengths=np.linalg.norm(rest[edges[:,0]]-rest[edges[:,1]],axis=1)*scale
# Anatomical garment zones are defined in the unchanged source coordinate
# system: central torso/skirt, plus the full lower hem below fingertips.
robe=((np.abs(rest[:,0])<.13)&(rest[:,2]>.20)&(rest[:,2]<1.02))|((np.abs(rest[:,0])<.24)&(rest[:,2]>.22)&(rest[:,2]<.445))
arm_names={b.name for b in arm.data.bones if any(p in b.name for p in ['Hand','ForeArm','Shoulder']) or b.name.endswith('Arm') or b.name.startswith('grip_')}
weights=np.array([sum(g.weight for g in v.groups if obj.vertex_groups[g.group].name in arm_names) for v in obj.data.vertices]);robe_arm_weight=float(weights[robe].max());print('ROBE DEPENDENCY',int(robe.sum()),robe_arm_weight,flush=True)
valid=rest_lengths>.002;robe_edges=robe[edges[:,0]]&robe[edges[:,1]]&valid
def metrics(posed):
 lengths=np.linalg.norm(posed[edges[:,0]]-posed[edges[:,1]],axis=1)*scale;ratio=lengths/np.maximum(rest_lengths,1e-12);growth=lengths-rest_lengths
 return {'max_edge_stretch':float(ratio[valid].max()),'max_edge_growth_m':float(growth[valid].max()),'max_robe_edge_stretch':float(ratio[robe_edges].max()),'max_robe_edge_growth_m':float(growth[robe_edges].max()),'pathological_edges':int(np.sum(valid&(ratio>8)&(growth>.025)))}
report={'source':str(source),'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'reference_height_m':height,'robe_vertices':int(robe.sum()),'max_robe_upper_limb_weight':robe_arm_weight,'clips':{},'crossfades':{},'robe_isolation':{}};snapshots=[];pose_count=0
relevant=[n for n in actions if any(word in n for word in ['coffee','sofa','phone','sit_','stand_','typing'])]
for name,action in actions.items():
 count=round(float(action.frame_range[1]))+1;aggregate=None;worst=None
 for phase in np.linspace(0,1,count):
  action_pose(name,float(phase));m=metrics(points());pose_count+=1
  if aggregate is None:aggregate=dict(m);worst=(m['max_edge_stretch'],float(phase))
  else:
   for k,v in m.items():aggregate[k]=max(aggregate[k],v)
   if m['max_edge_stretch']>worst[0]:worst=(m['max_edge_stretch'],float(phase))
 aggregate.update(samples=count,worst_edge_phase=worst[1]);report['clips'][name]=aggregate
 print('CLIP',name,count,round(aggregate['max_edge_stretch'],3),'robe',round(aggregate['max_robe_edge_stretch'],3),'bad',aggregate['pathological_edges'],flush=True)
 # Freeze the rest of the skeleton and rotate every arm/hand joint to
 # prove whether robe geometry can follow an upper limb at all.
 if name in ['preparing_coffee','coffee_putdown','phone_call','typing','sitting_sofa_coffee']:
  action_pose(name,.5);before=points();saved=basis();arm.animation_data.action=None
  for b in arm.pose.bones:
   if b.name in arm_names:b.rotation_mode='QUATERNION';b.rotation_quaternion=b.rotation_quaternion@Quaternion((1,0,0),.75)
  bpy.context.view_layer.update();delta=np.linalg.norm(points()-before,axis=1)*scale;report['robe_isolation'][name]={'max_upper_limb_only_displacement_m':float(delta[robe].max())};blended(saved,saved,0)
transitions=[('walking','preparing_coffee'),('preparing_coffee','carrying_coffee'),('carrying_coffee','talking_coffee'),('talking_coffee','laughing_coffee'),('talking_coffee','drinking_coffee'),('walking_coffee','sit_down_sofa_coffee'),('sit_down_sofa_coffee','sitting_sofa_coffee'),('sitting_sofa_coffee','talking_sofa_coffee_left'),('talking_sofa_coffee_left','drinking_sofa_coffee'),('talking_sofa_coffee_right','laughing_sofa_coffee'),('sitting_sofa_coffee','stand_up_sofa_coffee'),('stand_up_sofa_coffee','walking_coffee'),('walking_coffee','coffee_putdown'),('coffee_putdown','idle'),('typing','phone_pickup'),('phone_pickup','phone_call'),('phone_call','phone_putdown'),('phone_putdown','typing'),('chair_pullback','stand_up'),('sit_down','chair_pushin')]
for first,second in transitions:
 key=first+' -> '+second;aggregate=None
 for phase in [.1,.5,.9]:
  action_pose(first,phase);a=basis()
  for t in np.linspace(0,1,21):
   action_pose(second,float(t)*.10);b=basis();blended(a,b,float(t));m=metrics(points());pose_count+=1
   if aggregate is None:aggregate=dict(m)
   else:
    for k,v in m.items():aggregate[k]=max(aggregate[k],v)
 report['crossfades'][key]=aggregate;print('BLEND',key,round(aggregate['max_edge_stretch'],3),'robe',round(aggregate['max_robe_edge_stretch'],3),'bad',aggregate['pathological_edges'],flush=True)
report['sampled_poses']=pose_count
report['passed']=robe_arm_weight<1e-5 and all(v['max_upper_limb_only_displacement_m']<1e-5 for v in report['robe_isolation'].values()) and all(v['pathological_edges']==0 for v in list(report['clips'].values())+list(report['crossfades'].values()))
(out/'audit.json').write_text(json.dumps(report,indent=2))
# Real Blender snapshots of the coffee gesture and adjacent activities,
# viewed from the side so a spurious hand-to-skirt bridge cannot hide.
panels=[('preparing_coffee',p) for p in [.1,.25,.4,.55,.75,.9]]+[('coffee_putdown',.5),('phone_pickup',.5),('phone_call',.5),('sitting_sofa_coffee',.5),('talking_sofa_coffee_left',.5),('drinking_sofa_coffee',.5)]
for i,(name,phase) in enumerate(panels):
 action_pose(name,phase);dg=bpy.context.evaluated_depsgraph_get();offset=Vector(((i%4)*1.10*height,0,-(i//4)*1.15*height));rotation=Matrix.Rotation(-.80,4,'Z')
 for item in meshes:
  mesh=bpy.data.meshes.new_from_object(item.evaluated_get(dg),depsgraph=dg);snap=bpy.data.objects.new(name+str(phase)+item.name,mesh);scene.collection.objects.link(snap);snap.matrix_world=Matrix.Translation(offset)@rotation@item.matrix_world
 font=bpy.data.curves.new(name,'FONT');font.body=f'{name} {phase:.2f}';font.size=.04*height;font.align_x='CENTER';text=bpy.data.objects.new(name,font);scene.collection.objects.link(text);text.location=offset+Vector((0,-.3*height,-.11*height));text.rotation_euler=(math.pi/2,0,0)
for item in meshes:item.hide_render=True
scene.world=bpy.data.worlds.new('Robe audit studio');scene.world.color=(.18,.18,.18);scene.render.engine='BLENDER_EEVEE';scene.render.resolution_x=2000;scene.render.resolution_y=1650;scene.render.resolution_percentage=100;scene.view_settings.view_transform='AgX'
target=Vector((1.65*height,0,-.65*height));data=bpy.data.cameras.new('Audit camera');camera=bpy.data.objects.new('Audit camera',data);scene.collection.objects.link(camera);camera.location=target+Vector((0,-8*height,.12*height));camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler();data.type='ORTHO';data.ortho_scale=4.7*height;scene.camera=camera
for location,energy in [((-2,-4,5),1500),((4,-3,3),1000),((1,3,4),1500)]:
 data=bpy.data.lights.new('Light','AREA');data.energy=energy;data.size=5;light=bpy.data.objects.new('Light',data);scene.collection.objects.link(light);light.location=target+Vector(location);light.rotation_euler=(target-light.location).to_track_quat('-Z','Y').to_euler()
scene.render.filepath=str(out/'coffee-and-transitions.png');bpy.ops.render.render(write_still=True)
assert report['passed'],'Robe/skin regression; see audit.json and Blender contact sheet'
