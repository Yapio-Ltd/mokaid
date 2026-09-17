#!/usr/bin/env python3
"""Validate delivered GLBs by reimporting them into Blender, independently of bake.
blender --background --python scripts/validate-avatar-quality.py -- /tmp/avatar-quality
Fails on incomplete clips, malformed samples, discontinuous loops, unweighted
vertices, drifting seated feet, or loss of skin precision. Writes validation.json.
"""
import hashlib,json,math,runpy,struct,sys
from pathlib import Path
import bpy
import numpy as np
from mathutils import Vector
helper=runpy.run_path(str(Path(__file__).with_name('blender-avatar-quality.py')))
CLIPS=helper['DURATIONS'];DESK=helper['DESK'];read=helper['glb_read'];SEAT=helper['DESK_SEAT_HEIGHT'];SOFA=helper['SOFA_SEAT_HEIGHT']

def accessor(gltf,blob,index):
 acc=gltf['accessors'][index];view=gltf['bufferViews'][acc['bufferView']]
 components={'SCALAR':1,'VEC3':3,'VEC4':4}[acc['type']]
 assert acc['componentType']==5126
 start=view.get('byteOffset',0)+acc.get('byteOffset',0)
 return np.frombuffer(blob,dtype='<f4',count=acc['count']*components,offset=start).reshape((-1,components))

def main():
 directory=Path(sys.argv[sys.argv.index('--')+1]);report={}
 for path in sorted(directory.glob('avatar_*.glb')):
  durations=dict(CLIPS);durations['walking']=helper['WALK_DURATION_OVERRIDES'].get(path.stem,CLIPS['walking']);durations['walking_coffee']=durations['walking']
  gltf,blob=read(path);animations=gltf['animations'];assert {a['name'] for a in animations}==set(CLIPS),path
  loop_gap=0
  for material in gltf.get('materials',[]):
   pbr=material.get('pbrMetallicRoughness',{})
   assert pbr.get('metallicFactor',1)==0,(path,material['name'],'skin/clothing must be nonmetallic')
   assert pbr.get('roughnessFactor',1)>=.65-1e-6,(path,material['name'],'roughness below material policy')
   assert not material.get('emissiveTexture') and not any(material.get('emissiveFactor',[0,0,0])),(path,material['name'],'avatar must not emit light')
   specular=material.get('extensions',{}).get('KHR_materials_specular',{})
   assert 0<=specular.get('specularFactor',1)<=1,(path,material['name'],'invalid specular factor')
   assert all(0<=v<=1 for v in specular.get('specularColorFactor',[1,1,1])),(path,material['name'],'specular amplification')
  for skin in gltf['skins']:
   assert gltf['nodes'][skin['joints'][0]]['name'].split('|')[-1] in {'Hips','root.x','pelvis'},(path,'pelvis must lead native skin palette')
  for action in animations:
   seen=set()
   for channel in action['channels']:
    sampler=action['samplers'][channel['sampler']];times=accessor(gltf,blob,sampler['input']);values=accessor(gltf,blob,sampler['output'])
    assert len(times)==len(values) and len(times)>1 and np.isfinite(values).all()
    assert np.all(np.diff(times[:,0])>0) and abs(float(times[0,0]))<1e-5
    assert abs(float(times[-1,0])-durations[action['name']])<1e-4
    node=channel['target']['node'];prop=channel['target']['path'];assert (node,prop) not in seen;seen.add((node,prop))
    if prop=='rotation':
     assert np.max(np.abs(np.linalg.norm(values,axis=1)-1))<1e-4
     gap=min(np.max(np.abs(values[0]-values[-1])),np.max(np.abs(values[0]+values[-1])))
    else:gap=np.max(np.abs(values[0]-values[-1]))
    if action['name'] not in helper['NON_LOOP']:loop_gap=max(loop_gap,float(gap))
   assert loop_gap<1e-5,(path,action['name'],loop_gap)
  # Seat transitions join the exact idle/seat pose; preparing ends holding the
  # cup. Compare exported samplers, not authoring IK targets.
  def endpoint(name,last):
   action=next(a for a in animations if a['name']==name);result={}
   for channel in action['channels']:
    sampler=action['samplers'][channel['sampler']];values=accessor(gltf,blob,sampler['output'])
    result[(channel['target']['node'],channel['target']['path'])]=values[-1 if last else 0]
   return result
  transition_gap=0
  for name,first,last in [('sit_down','idle','sitting'),('stand_up','sitting','idle'),('sit_down_sofa','idle','sitting_sofa'),('stand_up_sofa','sitting_sofa','idle'),('preparing_coffee',None,'carrying_coffee')]:
   for end,other in [(False,first),(True,last)]:
    if other is None:continue
    a=endpoint(name,end);b=endpoint(other,False)
    for key in a:
     # Hidden cup position is immaterial; scale is still checked above/below.
     if gltf['nodes'][key[0]]['name']=='cup_socket' and name!='preparing_coffee':continue
     gap=float(np.max(np.abs(a[key]-b[key])))
     if key[1]=='rotation':gap=min(gap,float(np.max(np.abs(a[key]+b[key]))))
     transition_gap=max(transition_gap,gap)
  assert transition_gap<1e-4,(path,'transition endpoint pose mismatch',transition_gap)
  bpy.ops.wm.read_factory_settings(use_empty=True);bpy.ops.import_scene.gltf(filepath=str(path))
  arm=next(o for o in bpy.data.objects if o.type=='ARMATURE');meshes=[o for o in bpy.data.objects if o.type=='MESH' and o.vertex_groups]
  male='root.x' in arm.data.bones;hips='root.x' if male else 'Hips';feet=['foot.l','foot.r'] if male else ['LeftFoot','RightFoot']
  weight_error=0;vertices=0
  for obj in meshes:
   for vertex in obj.data.vertices:
    weights=[g.weight for g in vertex.groups if obj.vertex_groups[g.group].name in arm.data.bones and g.weight>0]
    assert 1<=len(weights)<=4,(path,obj.name,vertex.index)
    weight_error=max(weight_error,abs(sum(weights)-1));vertices+=1
  assert weight_error<1e-4,(path,weight_error)
  bind_coords=[obj.matrix_world@v.co for obj in meshes for v in obj.data.vertices]
  bind_height=max(v.z for v in bind_coords)-min(v.z for v in bind_coords)
  def deformed_bounds():
   dg=bpy.context.evaluated_depsgraph_get();minimum=1e9;maximum=-1e9
   for obj in meshes:
    evaluated=obj.evaluated_get(dg);mesh=evaluated.to_mesh();coords=np.empty(len(mesh.vertices)*3);mesh.vertices.foreach_get('co',coords);coords=coords.reshape((-1,3))
    mat=np.array(obj.matrix_world);zs=coords@mat[2,:3]+mat[2,3];minimum=min(minimum,float(zs.min()));maximum=max(maximum,float(zs.max()));evaluated.to_mesh_clear()
   return minimum,maximum
  arm.animation_data.action=bpy.data.actions['idle'];bpy.context.scene.frame_set(0);bpy.context.view_layer.update()
  reference_floor,reference_top=deformed_bounds();height=reference_top-reference_floor;scale=1.75/height
  assert 'cup_socket' in arm.data.bones,(path,'missing rigid cup socket')
  actions={a.name:a for a in bpy.data.actions};desk_hips=[];foot_drift=0;ground_samples=[];desk_floor_error=0;sofa_floor_error=0;walk_speed_error=0;transition_drift=0;cup_grip_drift=0;cup_upright_error=0;foos_height_error=0;foos_spacing_error=0;chair_speed_error=0
  for name in CLIPS:
   action=actions[name];arm.animation_data.action=action;start,end=action.frame_range
   initial=None;previous=None
   for frame in np.linspace(start,end,13):
    bpy.context.scene.frame_set(int(frame),subframe=float(frame)%1);bpy.context.view_layer.update()
    positions=[(arm.matrix_world@arm.pose.bones[f].matrix).translation.copy() for f in feet]
    if initial is None:initial=positions
    phase=(frame-start)/(end-start);seconds=phase*durations[name]
    if name in {'walking','walking_coffee'} and previous:
     old_seconds,old_phase,old_positions=previous
     for side in range(2):
      p=(phase+side*.5)%1;old_p=(old_phase+side*.5)%1
      if 0<=old_p<p<=.6:
       speed=(positions[side].y-old_positions[side].y)/(seconds-old_seconds)*scale
       walk_speed_error=max(walk_speed_error,abs(speed-helper['WALK_SPEED']))
    if name in helper['CHAIR_LOCOMOTION'] and previous:
     old_seconds,old_phase,old_positions=previous
     for side in range(2):
      p=(2*phase+side*.5)%1;old_p=(2*old_phase+side*.5)%1
      if 0<=old_p<p<=.6:
       speed=(positions[side].y-old_positions[side].y)/(seconds-old_seconds)*scale
       expected=helper['CHAIR_SPEED']*(-1 if name=='chair_pullback' else 1)
       chair_speed_error=max(chair_speed_error,abs(speed-expected))
    previous=(seconds,phase,positions)
    if name in helper['SEAT_TRANSITIONS']:
     amount=helper['smooth'](phase);advance=helper['SEAT_ADVANCE']['sofa' if name.endswith('_sofa') else 'desk']*height
     compensation=Vector((0,(-1 if name.startswith('stand_up') else 1)*advance*amount,0))
     transition_drift=max(transition_drift,max((a+compensation-b).length*scale for a,b in zip(positions,initial)))
    elif name not in {'walking','walking_coffee'}|helper['CHAIR_LOCOMOTION']:foot_drift=max(foot_drift,max((a-b).length for a,b in zip(positions,initial)))
    socket=arm.pose.bones['cup_socket'];socket_world=arm.matrix_world@socket.matrix;rest_world=arm.matrix_world@arm.data.bones['cup_socket'].matrix_local
    visibility=socket_world.to_scale().length/rest_world.to_scale().length
    assert abs(visibility-(1 if name in helper['COFFEE'] else .0001))<1e-4,(path,name,'cup visibility',visibility)
    if name in helper['COFFEE']:
     hand=arm.pose.bones['hand.r' if male else 'RightHand'];delta=socket_world.translation-(arm.matrix_world@hand.matrix).translation
     expected=math.sqrt(.075**2+.035**2)
     cup_grip_drift=max(cup_grip_drift,abs(delta.length*scale-expected))
     rotation=socket_world.to_quaternion()@rest_world.to_quaternion().inverted();up=rotation@Vector((0,0,1))
     if name!='drinking_coffee':cup_upright_error=max(cup_upright_error,up.angle(Vector((0,0,1))))
    if name=='playing_foosball':
     hands=[(arm.matrix_world@arm.pose.bones[n].matrix).translation for n in (['hand.l','hand.r'] if male else ['LeftHand','RightHand'])]
     foos_height_error=max(foos_height_error,max(abs((hand.z-reference_floor)*scale-.956) for hand in hands))
     foos_spacing_error=max(foos_spacing_error,abs(abs(hands[0].x-hands[1].x)*scale-.38))
    if name in DESK:desk_hips.append((arm.matrix_world@arm.pose.bones[hips].matrix).translation.z)
    minimum,maximum=deformed_bounds()
    ground_samples.append(minimum)
    if name in DESK:
     pelvis=(arm.matrix_world@arm.pose.bones[hips].matrix).translation.z
     desk_floor_error=max(desk_floor_error,abs(SEAT+(minimum-pelvis)*scale))
    if name=='sitting_sofa':
     pelvis=(arm.matrix_world@arm.pose.bones[hips].matrix).translation.z
     sofa_floor_error=max(sofa_floor_error,abs(SOFA+(minimum-pelvis)*scale))
  assert chair_speed_error<.015,(path,'seated chair push stance speed',chair_speed_error)
  assert foos_height_error<.002,(path,'foosball hands miss measured rod height',foos_height_error)
  assert foos_spacing_error<.001,(path,'foosball hand spacing',foos_spacing_error)
  assert transition_drift<.002,(path,'transition stance drift after synchronized root motion',transition_drift)
  assert cup_grip_drift<.001,(path,'cup grip drift',cup_grip_drift)
  assert cup_upright_error<.005,(path,'cup spills when carried',cup_upright_error)
  assert sofa_floor_error<.012,(path,'sofa sole offset after runtime placement',sofa_floor_error)
  assert desk_floor_error<.012,(path,'seated sole offset after runtime placement',desk_floor_error)
  # Interpolated FK at fractional 60 fps samples has submillimetre
  # residuals; keep the resulting stance-speed error below 5%.
  assert walk_speed_error<.05,(path,'walking velocity mismatch',walk_speed_error)
  assert foot_drift<1e-4,(path,foot_drift)
  assert max(desk_hips)-min(desk_hips)<1e-5,(path,'desk pelvis mismatch')
  ground_drift=max(ground_samples)-min(ground_samples)
  assert ground_drift<.018,(path,'ground variation',ground_drift)
  # The old male eye highlights stayed bound to an independent neutral bone.
  if male:
   eye=next(obj for obj in meshes if obj.name=='Eye')
   assert all(eye.vertex_groups[g.group].name!='neutral_bone' or g.weight==0 for v in eye.data.vertices for g in v.groups)
  report[path.stem]={'max_runtime_chair_stance_speed_error_mps':chair_speed_error,'max_runtime_foosball_hand_height_error_m':foos_height_error,'max_runtime_foosball_hand_spacing_error_m':foos_spacing_error,'max_transition_endpoint_component_gap':transition_gap,'reference_height_m':height,'bind_height_m':bind_height,'max_runtime_transition_foot_drift_m':transition_drift,'max_runtime_cup_grip_error_m':cup_grip_drift,'max_carry_cup_upright_error_rad':cup_upright_error,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'clips':len(actions),'nonmetallic_nonemissive_materials':len(gltf.get('materials',[])),'skinned_vertices':vertices,'max_weight_sum_error':weight_error,'max_loop_component_error':loop_gap,'max_standing_and_seated_foot_drift_m':foot_drift,'desk_pelvis_height_spread_m':max(desk_hips)-min(desk_hips),'mesh_ground_height_range_m':ground_drift,'max_runtime_desk_sole_offset_m':desk_floor_error,'max_runtime_sofa_sole_offset_m':sofa_floor_error,'max_runtime_walk_stance_speed_error_mps':walk_speed_error}
  print('PASS',path.stem,report[path.stem],flush=True)
 (directory/'validation.json').write_text(json.dumps(report,indent=2))
if __name__=='__main__':main()
