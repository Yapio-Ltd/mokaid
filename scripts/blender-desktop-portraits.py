"""Render native UI portraits from the actual character assets, plus a brand orb."""
import bpy
import argparse
import hashlib
import json
import math
import numpy as np
import re
import sys
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'apps/desktop/presentation/assets'
OUT.mkdir(parents=True, exist_ok=True)
catalog = (ROOT / 'apps/api/lib/mokaid/assets_3d.ex').read_text()
parser = argparse.ArgumentParser()
parser.add_argument('--only', nargs='+', choices=['male','design','finance','corporate','developer','research','legal','orb'])
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
records = json.loads((OUT / 'provenance.json').read_text()) if (OUT / 'provenance.json').exists() else {}

def studio():
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_EEVEE'
    scene.render.resolution_x = scene.render.resolution_y = 384
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_mode = 'RGBA'
    scene.render.film_transparent = True
    scene.view_settings.view_transform = 'AgX'
    scene.world = bpy.data.worlds.new('Midnight portrait studio')
    scene.world.use_nodes = True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (.08, .09, .17, 1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value = .35
    camera_data = bpy.data.cameras.new('Portrait')
    camera = bpy.data.objects.new('Portrait', camera_data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    camera_data.type = 'ORTHO'
    return scene, camera

def area(name, position, target, energy, size, color):
    data = bpy.data.lights.new(name, 'AREA')
    data.energy, data.size, data.color = energy, size, color
    light = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(light)
    light.location = position
    light.rotation_euler = (target - light.location).to_track_quat('-Z', 'Y').to_euler()

for kind in ['male', 'design', 'finance', 'corporate', 'developer', 'research', 'legal']:
    if args.only and kind not in args.only:
        continue
    name = re.search(r'assets3d/(avatar_' + kind + r'\.[a-f0-9]+\.glb)', catalog).group(1)
    path = ROOT / 'assets/optimized' / name
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = 60
    bpy.ops.import_scene.gltf(filepath=str(path))
    arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
    if arm.animation_data and bpy.data.actions.get('idle'):
        arm.animation_data.action = bpy.data.actions['idle']
    bpy.context.scene.frame_set(0)
    bpy.context.view_layer.update()
    bone = next(b for b in arm.pose.bones if b.name.lower().split(':')[-1] in {'head', 'head.x'})
    # Fit evaluated head geometry, not a guessed fraction of body height.
    # The seven source rigs have very different head/body proportions.
    head_bones = {bone.name} | {b.name for b in bone.children_recursive}
    head_points = []
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for obj in bpy.data.objects:
        if obj.type != 'MESH' or not obj.vertex_groups:
            continue
        indices = [v.index for v in obj.data.vertices
                   if sum(g.weight for g in v.groups
                          if obj.vertex_groups[g.group].name in head_bones) > .65]
        if not indices:
            continue
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        head_points.extend(obj.matrix_world @ mesh.vertices[i].co for i in indices)
        evaluated.to_mesh_clear()
    assert head_points, 'No weighted head vertices for ' + kind
    points = np.array([list(p) for p in head_points])
    lower, upper = points.min(axis=0), points.max(axis=0)
    head_height = float(upper[2] - lower[2])
    head_width = float(upper[0] - lower[0])
    unit = head_height / .40
    target = Vector((float((lower[0]+upper[0])/2), float((lower[1]+upper[1])/2), float(lower[2]+.43*head_height)))
    scene, camera = studio()
    camera.location = target + Vector((.45, -3.5, .10)) * unit
    camera.rotation_euler = (target - camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera.data.ortho_scale = max(1.43 * head_height, 1.42 * head_width)
    area('Soft key', target + Vector((-1.7, -2.6, 2.6)) * unit, target, 210 * unit**2, 3 * unit, (1,.90,.82))
    area('Cool fill', target + Vector((2,-1,1)) * unit, target, 100 * unit**2, 2 * unit, (.60,.68,1))
    area('Violet rim', target + Vector((.4,1.2,1.5)) * unit, target, 190 * unit**2, 2 * unit, (.50,.25,1))
    for obj in bpy.data.objects:
        if obj.type == 'MESH' and any(m and (m.name.startswith('Desktop ') or 'cup' in m.name.lower() or 'coffee' in m.name.lower()) for m in obj.data.materials):
            obj.hide_render = True
    output = OUT / ('portrait-' + kind + '.png')
    scene.render.filepath = str(output)
    bpy.ops.render.render(write_still=True)
    records[kind] = {'source':str(path.relative_to(ROOT)), 'sourceSha256':hashlib.sha256(path.read_bytes()).hexdigest(), 'render':str(output.relative_to(ROOT)), 'size':[384,384], 'headBounds':[lower.tolist(),upper.tolist()], 'orthoScale':camera.data.ortho_scale}

if not args.only or 'orb' in args.only:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene, camera = studio()
    scene.render.resolution_x = scene.render.resolution_y = 512
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value = .025
    bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=64, radius=1)
    orb = bpy.context.object
    bpy.ops.object.shade_smooth()
    material = bpy.data.materials.new('Obsidian violet')
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    shader = nodes.get('Principled BSDF')
    shader.inputs['Base Color'].default_value = (.004,.003,.019,1)
    shader.inputs['Metallic'].default_value = .82
    shader.inputs['Roughness'].default_value = .24
    noise = nodes.new('ShaderNodeTexNoise'); noise.inputs['Scale'].default_value=3.8; noise.inputs['Detail'].default_value=6
    bump = nodes.new('ShaderNodeBump'); bump.inputs['Strength'].default_value=.15; bump.inputs['Distance'].default_value=.035
    links.new(noise.outputs['Fac'], bump.inputs['Height']); links.new(bump.outputs['Normal'], shader.inputs['Normal'])
    layer = nodes.new('ShaderNodeLayerWeight'); layer.inputs['Blend'].default_value=.3
    ramp = nodes.new('ShaderNodeValToRGB')
    ramp.color_ramp.elements[0].position=.66; ramp.color_ramp.elements[0].color=(0,0,0,1)
    ramp.color_ramp.elements[1].position=1; ramp.color_ramp.elements[1].color=(.20,.065,.65,1)
    links.new(layer.outputs['Fresnel'], ramp.inputs[0]); links.new(ramp.outputs['Color'],shader.inputs['Emission Color'])
    shader.inputs['Emission Strength'].default_value=2.8
    orb.data.materials.append(material)
    camera.location=(0,-4,1); camera.rotation_euler=(Vector((0,0,0))-camera.location).to_track_quat('-Z','Y').to_euler(); camera.data.ortho_scale=2.35
    area('Violet crescent',Vector((2,1,1.5)),Vector((0,0,0)),1100,1.4,(.35,.09,1))
    area('Blue north light',Vector((-1,1,2)),Vector((0,0,0)),420,1.8,(.09,.17,1))
    scene.render.filepath=str(OUT/'brand-orb.png'); bpy.ops.render.render(write_still=True)
    records['orb']={'source':'Procedural Blender sphere, authored violet rim and material', 'render':'apps/desktop/presentation/assets/brand-orb.png'}
(OUT/'provenance.json').write_text(json.dumps(records,indent=2)+'\n')
