"""Render a reproducible close-up of Legal's repaired coffee-pose flank."""
import bpy,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
source=Path(args[0]) if args else root/'artifacts/avatar-life/avatar_legal.glb'
output=Path(args[1]) if len(args)>1 else root/'artifacts/avatar-life/legal-regression/flank-after.png'
output.parent.mkdir(parents=True,exist_ok=True)
from mathutils import Vector
bpy.ops.wm.read_factory_settings(use_empty=True);bpy.context.scene.render.fps=60;bpy.ops.import_scene.gltf(filepath=str(source.resolve()));scene=bpy.context.scene;arm=next(o for o in bpy.data.objects if o.type=='ARMATURE');a=bpy.data.actions['preparing_coffee'];arm.animation_data.action=a;scene.frame_set(int(a.frame_range[1]*.25));bpy.context.view_layer.update();scene.world=bpy.data.worlds.new('Flank studio');scene.world.color=(.18,.18,.18);scene.render.engine='BLENDER_EEVEE';scene.render.resolution_x=1000;scene.render.resolution_y=1200;scene.render.resolution_percentage=100
point=Vector((0,-.05,.78));data=bpy.data.cameras.new('Flank');cam=bpy.data.objects.new('Flank',data);scene.collection.objects.link(cam);scene.camera=cam;cam.location=point+Vector((-2,-2,.1));cam.rotation_euler=(point-cam.location).to_track_quat('-Z','Y').to_euler();data.type='ORTHO';data.ortho_scale=.95
for loc,energy in [((-3,-4,4),1300),((3,-4,2),700),((0,3,4),1000)]:
 d=bpy.data.lights.new('Light','AREA');d.energy=energy;d.size=4;o=bpy.data.objects.new('Light',d);scene.collection.objects.link(o);o.location=loc;o.rotation_euler=(point-o.location).to_track_quat('-Z','Y').to_euler()
scene.render.filepath=str(output.resolve());bpy.ops.render.render(write_still=True)
