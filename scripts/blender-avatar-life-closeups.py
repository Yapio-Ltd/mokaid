#!/usr/bin/env python3
"""Render actual exported hand/cup and ear/phone contacts in Blender."""
import sys,json,math
from pathlib import Path
import bpy
import numpy as np
from mathutils import Vector
root=Path(sys.argv[sys.argv.index('--')+1]);report=json.loads((root/'report.json').read_text())
panels=[('carrying_coffee',0),('preparing_coffee',.39),('coffee_putdown',.61),('phone_pickup',.5),('phone_call',.3)]
for key in ['avatar_male','avatar_design']:
 bpy.ops.wm.read_factory_settings(use_empty=True);bpy.ops.import_scene.gltf(filepath=str(root/(key+'.glb')))
 scene=bpy.context.scene;arm=next(o for o in bpy.data.objects if o.type=='ARMATURE');ns=report[key]['height_m']/1.75
 scene.world=bpy.data.worlds.new('Contact studio');scene.world.color=(.22,.22,.22)
 scene.render.engine='BLENDER_EEVEE';scene.render.resolution_x=640;scene.render.resolution_y=640;scene.render.resolution_percentage=100;scene.render.image_settings.file_format='PNG';scene.view_settings.view_transform='AgX'
 data=bpy.data.cameras.new('Contact camera');camera=bpy.data.objects.new('Contact camera',data);scene.collection.objects.link(camera);scene.camera=camera;data.type='ORTHO';data.lens=70
 lights=[]
 for name,pos,energy in [('Key',(-2,-4,3),1100),('Fill',(3,-3,2),800),('Rim',(0,3,4),1000)]:
  data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.size=4;obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);lights.append((obj,Vector(pos)))
 rows=[]
 for clip,phase in panels:
  action=bpy.data.actions[clip];arm.animation_data.action=action;frame=action.frame_range[1]*phase;scene.frame_set(int(frame),subframe=frame%1);bpy.context.view_layer.update()
  socket='phone_socket' if clip.startswith('phone') else 'cup_socket';target=(arm.matrix_world@arm.pose.bones[socket].matrix).translation.copy()
  if clip=='phone_call':target.z+=.015*ns
  delta=Vector((1,-1,.15)) if clip.startswith('phone') else Vector((-.7,-1,.3))
  camera.location=target+delta*ns;camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler();camera.data.ortho_scale=(.44 if clip=='phone_call' else .39)*ns
  for light,offset in lights:light.location=target+offset;light.rotation_euler=(target-light.location).to_track_quat('-Z','Y').to_euler()
  path=root/f'{key}-{clip}-closeup.png';scene.render.filepath=str(path);bpy.ops.render.render(write_still=True)
  image=bpy.data.images.load(str(path));rows.append(np.array(image.pixels[:],dtype=np.float32).reshape((640,640,4)));bpy.data.images.remove(image)
 combined=np.concatenate(rows,axis=1);image=bpy.data.images.new(key+' contact closeups',width=640*len(rows),height=640);image.pixels.foreach_set(combined.ravel());image.filepath_raw=str(root/(key+'-contact-closeups.png'));image.file_format='PNG';image.save()
