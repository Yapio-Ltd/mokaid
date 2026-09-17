#!/usr/bin/env python3
"""Measure evaluated hand geometry against cup surfaces, not only socket joints."""
import json,sys
from pathlib import Path
import bpy
import numpy as np
from mathutils import Vector
root=Path(sys.argv[sys.argv.index('--')+1]);report={}
for path in sorted(root.glob('avatar_*.glb')):
 bpy.ops.wm.read_factory_settings(use_empty=True);bpy.ops.import_scene.gltf(filepath=str(path));arm=next(o for o in bpy.data.objects if o.type=='ARMATURE');meshes=[o for o in bpy.data.objects if o.type=='MESH' and o.vertex_groups]
 male='root.x' in arm.data.bones;cup=next(o for o in meshes if o.name=='OfficeCoffeeCup');rest=arm.matrix_world@arm.data.bones['cup_socket'].matrix_local
 arm.animation_data.action=bpy.data.actions['idle'];bpy.context.scene.frame_set(0);bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get();zs=[]
 for obj in meshes:
  evaluated=obj.evaluated_get(dg);mesh=evaluated.to_mesh();zs.extend((obj.matrix_world@v.co).z for v in mesh.vertices);evaluated.to_mesh_clear()
 scale=1.75/(max(zs)-min(zs))
 hand_names={'hand.r','RightHand','grip_prox.r','grip_dist.r','grip_thumb.r'}|{n for n in arm.data.bones.keys() if n.startswith(('thumb','index','middle','ring','pinky')) and n.endswith('.r')}
 hands={o:[v.index for v in o.data.vertices if any(o.vertex_groups[g.group].name in hand_names and g.weight>.25 for g in v.groups)] for o in meshes if o!=cup}
 handles=[v.index for v in cup.data.vertices if ((cup.matrix_world@v.co)-rest.translation).x*scale<-.05]
 metrics={}
 for name,t in [('carrying_coffee',0),('preparing_coffee',.39),('preparing_coffee',.6),('coffee_putdown',.61),('sitting_sofa_coffee',0),('drinking_coffee',.5)]:
  arm.animation_data.action=bpy.data.actions[name];frame=arm.animation_data.action.frame_range[1]*t;bpy.context.scene.frame_set(int(frame),subframe=frame%1);bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get();points=[]
  for obj,ids in hands.items():
   if not ids:continue
   evaluated=obj.evaluated_get(dg);mesh=evaluated.to_mesh();points.extend(obj.matrix_world@mesh.vertices[i].co for i in ids);evaluated.to_mesh_clear()
  evaluated=cup.evaluated_get(dg);mesh=evaluated.to_mesh();handle=np.array([list(cup.matrix_world@mesh.vertices[i].co) for i in handles])*scale;evaluated.to_mesh_clear()
  hand=np.array([list(p) for p in points])*scale;distance=float(np.linalg.norm(hand[:,None,:]-handle[None,:,:],axis=2).min())
  socket=arm.matrix_world@arm.pose.bones['cup_socket'].matrix;rotation=socket.to_quaternion()@rest.to_quaternion().inverted();local=np.array([list(rotation.inverted()@(p-socket.translation)*scale) for p in points])
  inside=(local[:,0]**2+local[:,1]**2<.032**2)&(np.abs(local[:,2])<.047)
  depth=np.minimum(.032-np.sqrt(local[:,0]**2+local[:,1]**2),.047-np.abs(local[:,2]))
  metrics[f'{name}@{t}']={'handle_surface_gap_m':distance,'hand_vertices_inside_cup_interior':int(inside.sum()),'max_cup_interior_penetration_m':max(0.,float(depth.max())),'hand_vertices':len(hand)}
 report[path.stem]=metrics;print(path.stem,metrics,flush=True)
(root/'surface-contacts.json').write_text(json.dumps(report,indent=2))
assert all(v['hand_vertices_inside_cup_interior']==0 for m in report.values() for v in m.values()),'hand penetrates cup interior; see surface-contacts.json'
assert max(v['handle_surface_gap_m'] for m in report.values() for v in m.values())<.012,'hand misses handle; see surface-contacts.json'
