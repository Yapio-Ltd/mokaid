#!/usr/bin/env python3
"""Add distance-driven seated chair locomotion to an existing Blender bake."""
import hashlib,json,runpy,sys
from pathlib import Path
import bpy
helper=runpy.run_path(str(Path(__file__).with_name('blender-avatar-quality.py')))
staged=Path(sys.argv[sys.argv.index('--')+1]);report=json.loads((staged/'report.json').read_text())
for key,entry in report.items():
 bpy.ops.wm.open_mainfile(filepath=str(staged/(key+'.blend')))
 arm=next(obj for obj in bpy.data.objects if obj.type=='ARMATURE');arm.animation_data_clear()
 meshes=[obj for obj in bpy.data.objects if obj.type=='MESH' and obj.vertex_groups];rig=helper['Rig'](arm,meshes);rig.height=entry['height_m']
 for name in sorted(helper['CHAIR_LOCOMOTION']):
  if name in bpy.data.actions:bpy.data.actions.remove(bpy.data.actions[name])
  action=bpy.data.actions.new(name);action.use_fake_user=True;arm.animation_data_create();arm.animation_data.action=action
  frames=round(helper['DURATIONS'][name]*helper['FPS']);max_contact=0;rig.max_ik_error=0
  for frame in range(frames+1):
   feet=helper['animate'](rig,name,frame/frames if frame<frames else 0);rig.apply(frame)
   for side,limb in rig.limbs.items():max_contact=max(max_contact,(rig.pos(limb['foot'])-feet[side]).length)
  assert max_contact<.001,(key,name,'unreachable seated step',max_contact)
  for curve in helper['channel_curves'](action):
   for point in curve.keyframe_points:point.interpolation='LINEAR'
  entry['clips'][name]={'duration_seconds':helper['DURATIONS'][name],'frames':frames+1,'foot_target_error_m':max_contact,'max_ik_target_error_m':rig.max_ik_error,'reference_speed_mps':helper['CHAIR_SPEED'],'distance_per_cycle_m':helper['CHAIR_SPEED']*helper['DURATIONS'][name]}
 arm.animation_data.action=bpy.data.actions['idle'];bpy.context.scene.frame_set(0);bpy.context.view_layer.update()
 output=staged/(key+'.glb');helper['export_avatar'](arm,meshes,output);bpy.ops.wm.save_as_mainfile(filepath=str(staged/(key+'.blend')))
 entry['sha256']=hashlib.sha256(output.read_bytes()).hexdigest();entry['bytes']=output.stat().st_size
 (staged/'report.json').write_text(json.dumps(report,indent=2));print('CHAIR',key,entry['clips']['chair_pullback'],entry['clips']['chair_pushin'],flush=True)
