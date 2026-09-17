"""Render and save an editable gallery of the three delivered GLBs in Blender."""
import bpy
import math
from mathutils import Vector
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts/avatar-atypical'
bpy.ops.wm.read_factory_settings(use_empty=True)
scene=bpy.context.scene
scene.render.fps=60
rigs=[]
props=[]
for i,kind in enumerate(['byte','nyx','moss']):
    previous=set(bpy.data.objects)
    previous_actions=set(bpy.data.actions)
    bpy.ops.import_scene.gltf(filepath=str(OUT/('avatar_'+kind+'.glb')))
    imported=set(bpy.data.objects)-previous
    actions=set(bpy.data.actions)-previous_actions
    arm=next(o for o in imported if o.type=='ARMATURE')
    by_name={a.name.split('.')[0]:a for a in actions}
    arm.animation_data.action=by_name['idle']
    parent=bpy.data.objects.new(kind.upper()+' placement',None)
    scene.collection.objects.link(parent)
    for obj in imported:
        if obj.type=='MESH' and obj.name.startswith('Office'):
            props.append(obj)
            obj.hide_render=True
        if obj.type=='MESH' and not obj.vertex_groups:
            obj.hide_render=True
            obj.hide_set(True)
        if obj.parent not in imported:
            world=obj.matrix_world.copy()
            obj.parent=parent
            obj.matrix_world=world
    parent.location.x=(i-1)*1.12
    rigs.append((kind,arm,by_name))
scene.frame_set(0)

def mat(name,color):
    m=bpy.data.materials.new(name)
    m.use_nodes=True
    m.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(*color,1)
    m.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value=.8
    return m

floor=mat('Warm graphite stage',(.022,.029,.035))
plinth=mat('Slate podium',(.045,.065,.07))
label_mat=mat('Cream typography',(.86,.86,.75))
muted=mat('Muted typography',(.29,.44,.43))
bpy.ops.mesh.primitive_plane_add(size=200,location=(0,0,-.16))
bpy.context.object.name='Studio floor'
bpy.context.object.data.materials.append(floor)
for i,(kind,_,_) in enumerate(rigs):
    x=(i-1)*1.12
    bpy.ops.mesh.primitive_cylinder_add(vertices=96,radius=.43,depth=.09,location=(x,-.05,-.05))
    base=bpy.context.object
    base.name=kind+' podium'
    base.data.materials.append(plinth)
    bevel=base.modifiers.new('Soft podium edge','BEVEL');bevel.width=.02;bevel.segments=3
    for name,size,z,material in [(kind.upper(),.086,-.045,label_mat),
                                ({'byte':'RETRO ROBOT','nyx':'CYBERPUNK','moss':'BOTANICAL SPRITE'}[kind],.030,-.103,muted)]:
        data=bpy.data.curves.new(name,'FONT');data.body=name;data.align_x='CENTER';data.size=size;data.extrude=.0004
        obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj)
        obj.location=(x,-.502,z);obj.rotation_euler=(math.pi/2,0,0);data.materials.append(material)
scene.world=bpy.data.worlds.new('Gallery world');scene.world.use_nodes=True
scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(.10,.13,.18,1)
scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.28
target=Vector((0,0,.82))
for name,position,energy,size,color in [('Warm key',(-3,-4,6),650,5,(1,.86,.72)),
    ('Cool fill',(4,-3,3),340,4,(.57,.78,1)),('Rim',(0,3,5),950,4,(.77,.89,1))]:
    light=bpy.data.lights.new(name,'AREA');light.energy=energy;light.size=size;light.color=color
    obj=bpy.data.objects.new(name,light);scene.collection.objects.link(obj);obj.location=position
    obj.rotation_euler=(target-obj.location).to_track_quat('-Z','Y').to_euler()
data=bpy.data.cameras.new('Gallery camera');camera=bpy.data.objects.new('Gallery camera',data)
scene.collection.objects.link(camera);camera.location=(1.7,-9,3.1)
camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
data.type='ORTHO';data.ortho_scale=3.9;scene.camera=camera
scene.render.engine='BLENDER_EEVEE';scene.view_settings.view_transform='AgX'
scene.render.resolution_x=1800;scene.render.resolution_y=1150;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG'
scene.render.filepath=str(OUT/'characters-gallery.png')
bpy.ops.render.render(write_still=True)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'atypical-collection.blend'))
for pose in ['typing','walking','carrying_coffee']:
    for kind,arm,actions in rigs:
        arm.animation_data.action=actions[pose]
    frame=20 if pose=='walking' else 45
    scene.frame_set(frame)
    # Match the runtime's activity-dependent visibility of carried props.
    for obj in props:
        obj.hide_render=not (pose=='carrying_coffee' and obj.name.startswith('OfficeCoffeeCup'))
    scene.render.filepath=str(OUT/('characters-'+pose+'.png'))
    bpy.ops.render.render(write_still=True)
print('GALLERY_AND_ANIMATION_POSES_RENDERED',flush=True)
