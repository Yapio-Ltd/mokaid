#!/usr/bin/env python3
"""Render a Blender contact sheet of activity timing from a delivered .blend.
blender -b --python scripts/blender-avatar-motion-sheet.py -- source.blend output.png
"""
import math,runpy,sys
from pathlib import Path
import bpy
from mathutils import Matrix,Vector
helper=runpy.run_path(str(Path(__file__).with_name('blender-avatar-quality.py')))
source,output=map(Path,sys.argv[sys.argv.index('--')+1:])
bpy.ops.wm.open_mainfile(filepath=str(source))
arm=next(obj for obj in bpy.data.objects if obj.type=='ARMATURE')
meshes=[obj for obj in bpy.data.objects if obj.type=='MESH' and obj.vertex_groups]
rig=helper['Rig'](arm,meshes);h=rig.height;scene=bpy.context.scene
rows=['walking','sit_down','preparing_coffee','drinking_coffee','playing_foosball','chair_pullback','chair_pushin']
for row,name in enumerate(rows):
 action=bpy.data.actions[name];arm.animation_data.action=action
 for column,phase in enumerate([0,.25,.5,.75,1]):
  frame=action.frame_range[1]*phase;scene.frame_set(int(frame),subframe=frame%1);bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get()
  offset=Vector((column*1.1*h,0,-row*1.3*h));rotation=Matrix.Rotation(.32,4,'Z')
  for obj in meshes:
   evaluated=obj.evaluated_get(dg);mesh=bpy.data.meshes.new_from_object(evaluated,depsgraph=dg)
   snap=bpy.data.objects.new(name+'-'+str(column)+'-'+obj.name,mesh);scene.collection.objects.link(snap);snap.matrix_world=Matrix.Translation(offset)@rotation@obj.matrix_world
  text=bpy.data.curves.new(name+' time','FONT');text.body=f'{name}  {frame/scene.render.fps:.2f}s';text.align_x='CENTER';text.size=.045*h
  obj=bpy.data.objects.new(text.name,text);scene.collection.objects.link(obj);obj.location=offset+Vector((0,-.25*h,-.12*h));obj.rotation_euler=(math.pi/2,0,0)
for obj in meshes:obj.hide_render=True
scene.world=bpy.data.worlds.new('MotionStudio');scene.world.color=(.14,.14,.14);scene.render.engine='BLENDER_EEVEE';scene.view_settings.view_transform='AgX'
scene.render.resolution_x=2200;scene.render.resolution_y=450*len(rows)+250;scene.render.resolution_percentage=100;scene.render.image_settings.file_format='PNG'
target=Vector((2.2*h,0,(.4-(len(rows)-1)*.65)*h));helper['camera_at'](target+Vector((0,-10*h,.7*h)),target,(1.3*len(rows)+.30)*h)
for name,position,energy,color in [('Key',(-2,-4,4),1600,(1,.89,.79)),('Fill',(6,-3,2),1300,(.75,.84,1)),('Rim',(3,2,4),1800,(.75,.90,1))]:
 data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.size=6;data.color=color
 obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);obj.location=target+Vector(position);obj.rotation_euler=(target-obj.location).to_track_quat('-Z','Y').to_euler()
scene.render.filepath=str(output);bpy.ops.render.render(write_still=True)
