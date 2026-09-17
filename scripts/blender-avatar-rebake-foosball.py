#!/usr/bin/env python3
"""Rebake only measured foosball contacts without changing other actions."""
import hashlib,json,runpy,sys
from pathlib import Path
import bpy
helper=runpy.run_path(str(Path(__file__).with_name('blender-avatar-quality.py')))
staged=Path(sys.argv[sys.argv.index('--')+1]);report=json.loads((staged/'report.json').read_text())
for key,entry in report.items():
 bpy.ops.wm.open_mainfile(filepath=str(staged/(key+'.blend')))
 arm=next(obj for obj in bpy.data.objects if obj.type=='ARMATURE');arm.animation_data_clear()
 meshes=[obj for obj in bpy.data.objects if obj.type=='MESH' and obj.vertex_groups]
 rig=helper['Rig'](arm,meshes);rig.height=entry['height_m'];rig.walk_duration=entry['clips']['walking']['duration_seconds']
 bpy.data.actions.remove(bpy.data.actions['playing_foosball']);action=bpy.data.actions.new('playing_foosball');action.use_fake_user=True;arm.animation_data_create();arm.animation_data.action=action
 frames=round(helper['DURATIONS']['playing_foosball']*helper['FPS']);max_contact=0
 for frame in range(frames+1):
  feet=helper['animate'](rig,'playing_foosball',frame/frames if frame<frames else 0);rig.apply(frame)
  for side,limb in rig.limbs.items():max_contact=max(max_contact,(rig.pos(limb['foot'])-feet[side]).length)
 assert rig.foos_hand_error<.001,(key,'cannot reach table handles',rig.foos_hand_error)
 for curve in helper['channel_curves'](action):
  for point in curve.keyframe_points:point.interpolation='LINEAR'
 entry['clips']['playing_foosball'].update(foot_target_error_m=max_contact,max_ik_target_error_m=rig.max_ik_error,max_runtime_hand_target_error_m=rig.foos_hand_error,handle_height_m=.956,forward_reach_m=.36,hand_spacing_m=.38,extra_torso_lean_rad=rig.foos_extra_lean,pelvis_advance_m=.10,pelvis_drop_m=.09+rig.foos_extra_drop_m)
 arm.animation_data.action=bpy.data.actions['idle'];bpy.context.scene.frame_set(0);bpy.context.view_layer.update()
 output=staged/(key+'.glb');helper['export_avatar'](arm,meshes,output);bpy.ops.wm.save_as_mainfile(filepath=str(staged/(key+'.blend')))
 helper['render_preview'](rig,{a.name:a for a in bpy.data.actions},staged/(key+'-contact-sheet.png'))
 entry['sha256']=hashlib.sha256(output.read_bytes()).hexdigest();entry['bytes']=output.stat().st_size
 (staged/'report.json').write_text(json.dumps(report,indent=2));print('FOOSBALL',key,entry['clips']['playing_foosball'],flush=True)
