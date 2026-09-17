"""Render the delivered avatars, their live poses, and their original proportions.

All display placement and height normalization live on an empty parent. Imported
meshes, armature transforms, skin weights and animation actions remain untouched.
"""
from __future__ import annotations

import json
import math
import re
from pathlib import Path

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/avatar-atypical'
KINDS = ('byte', 'nyx', 'moss')
DISPLAY_HEIGHT = 1.75


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = 60
    scene.render.engine = 'BLENDER_EEVEE'
    scene.view_settings.view_transform = 'AgX'
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    return scene


def body_bounds(meshes):
    """Evaluated body only: carried props and bone display geometry do not count."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    lower = Vector((float('inf'),) * 3)
    upper = Vector((float('-inf'),) * 3)
    for obj in meshes:
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        try:
            for vertex in mesh.vertices:
                point = evaluated.matrix_world @ vertex.co
                for axis in range(3):
                    lower[axis] = min(lower[axis], point[axis])
                    upper[axis] = max(upper[axis], point[axis])
        finally:
            evaluated.to_mesh_clear()
    if upper.z - lower.z <= 0:
        raise ValueError('Imported character has no measurable skinned body')
    return lower, upper


def import_character(path, label, x):
    previous_objects = set(bpy.data.objects)
    previous_actions = set(bpy.data.actions)
    bpy.ops.import_scene.gltf(filepath=str(path))
    imported = set(bpy.data.objects) - previous_objects
    actions = set(bpy.data.actions) - previous_actions
    arm = next(obj for obj in imported if obj.type == 'ARMATURE')
    by_name = {re.sub(r'\.\d+$', '', action.name): action for action in actions}
    if 'idle' not in by_name:
        raise ValueError(f'{path} has no idle action')
    arm.animation_data_create()
    arm.animation_data.action = by_name['idle']
    arm.data.pose_position = 'POSE'
    body, props = [], []
    for obj in imported:
        if obj.type != 'MESH':
            continue
        if not obj.vertex_groups:
            # The glTF importer creates an Icosphere for bone display.
            obj.hide_render = True
            obj.hide_set(True)
        elif obj.name.startswith('Office'):
            props.append(obj)
            obj.hide_render = True
        else:
            body.append(obj)
    scene = bpy.context.scene
    scene.frame_set(0)
    bpy.context.view_layer.update()
    lower, upper = body_bounds(body)
    height = upper.z - lower.z
    scale = DISPLAY_HEIGHT / height
    # Keep all imported local transforms, especially the 0.01 armature scale.
    placement = bpy.data.objects.new(label + ' display placement', None)
    scene.collection.objects.link(placement)
    for obj in imported:
        if obj.parent not in imported:
            world = obj.matrix_world.copy()
            obj.parent = placement
            obj.matrix_world = world
    placement.scale = (scale,) * 3
    placement.location = (
        x - (lower.x + upper.x) * .5 * scale,
        -(lower.y + upper.y) * .5 * scale,
        -lower.z * scale,
    )
    bpy.context.view_layer.update()
    return {
        'label': label, 'arm': arm, 'actions': by_name, 'body': body,
        'props': props, 'placement': placement,
        'measurement': {
            'path': str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path),
            'idle_body_bounds_m': [list(lower), list(upper)],
            'idle_body_height_m': height, 'display_scale': scale,
            'display_height_m': DISPLAY_HEIGHT,
            'display_body_width_m': (upper.x - lower.x) * scale,
            'display_body_depth_m': (upper.y - lower.y) * scale,
        },
    }


def material(name, color):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    shader = mat.node_tree.nodes['Principled BSDF']
    shader.inputs['Base Color'].default_value = (*color, 1)
    shader.inputs['Roughness'].default_value = .8
    return mat


def text_label(text, x, z, size, mat, y=-.52):
    data = bpy.data.curves.new(text, 'FONT')
    data.body = text
    data.align_x = 'CENTER'
    data.size = size
    data.extrude = .0004
    obj = bpy.data.objects.new(text, data)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = (x, y, z)
    obj.rotation_euler = (math.pi / 2, 0, 0)
    data.materials.append(mat)
    return obj


def podium(x, name, mat, radius=.43):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=96, radius=radius, depth=.09, location=(x, 0, -.045))
    obj = bpy.context.object
    obj.name = name + ' podium'
    obj.data.materials.append(mat)
    bevel = obj.modifiers.new('Soft podium edge', 'BEVEL')
    bevel.width = .015
    bevel.segments = 3
    return obj


def studio(scene, comparison=False):
    floor = material('Neutral graphite stage', (.045, .048, .052))
    base = material('Neutral slate podium', (.082, .088, .093))
    label = material('Soft white typography', (.88, .89, .89))
    muted = material('Secondary typography', (.44, .48, .50))
    bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, -.16))
    bpy.context.object.name = 'Studio floor'
    bpy.context.object.data.materials.append(floor)
    scene.world = bpy.data.worlds.new('Neutral studio world')
    scene.world.use_nodes = True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (.15, .15, .15, 1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value = .35
    target = Vector((0, 0, .85))
    # White area lights preserve the actual outfit colors in every image.
    for name, position, energy, size in [
        ('Soft key', (-3, -4, 6), 650, 5),
        ('Soft fill', (4, -3, 3), 450, 5),
        ('Soft rim', (0, 3, 5), 700, 4),
    ]:
        data = bpy.data.lights.new(name, 'AREA')
        data.energy, data.size, data.color = energy, size, (1, 1, 1)
        obj = bpy.data.objects.new(name, data)
        scene.collection.objects.link(obj)
        obj.location = position
        obj.rotation_euler = (target - obj.location).to_track_quat('-Z', 'Y').to_euler()
    data = bpy.data.cameras.new('Comparison camera' if comparison else 'Gallery camera')
    camera = bpy.data.objects.new(data.name, data)
    scene.collection.objects.link(camera)
    camera.location = (0, -10, 1.12) if comparison else (1.7, -9, 3.1)
    camera.rotation_euler = (target - camera.location).to_track_quat('-Z', 'Y').to_euler()
    data.type = 'ORTHO'
    data.ortho_scale = 6.25 if comparison else 3.9
    scene.camera = camera
    scene.render.resolution_x = 2400 if comparison else 1800
    scene.render.resolution_y = 1100 if comparison else 1150
    return base, label, muted


def render_gallery(specs):
    scene = reset_scene()
    rigs = []
    for index, kind in enumerate(KINDS):
        entry = specs['avatar_' + kind]
        rigs.append(import_character(OUT / ('avatar_' + kind + '.glb'), entry['name'], (index - 1) * 1.12))
    base, label, muted = studio(scene)
    for index, (kind, rig) in enumerate(zip(KINDS, rigs)):
        x = (index - 1) * 1.12
        podium(x, rig['label'], base)
        text_label(rig['label'].upper(), x, -.044, .086, label)
        # Names are authoritative; neutral captions avoid inventing a profession.
        text_label('COLLECTION MOKAID', x, -.106, .027, muted)
    scene.frame_set(0)
    scene.render.filepath = str(OUT / 'characters-gallery.png')
    bpy.ops.render.render(write_still=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT / 'atypical-collection.blend'))
    for pose in ('typing', 'walking', 'carrying_coffee'):
        for rig in rigs:
            rig['arm'].animation_data.action = rig['actions'][pose]
            for obj in rig['props']:
                obj.hide_render = not (pose == 'carrying_coffee' and obj.name.startswith('OfficeCoffeeCup'))
        scene.frame_set(20 if pose == 'walking' else 45)
        scene.render.filepath = str(OUT / ('characters-' + pose + '.png'))
        bpy.ops.render.render(write_still=True)
    return {kind: rig['measurement'] for kind, rig in zip(KINDS, rigs)}


def render_comparison(specs):
    scene = reset_scene()
    pairs = []
    donor_names = {'byte': 'CORPORATE', 'nyx': 'FINANCE', 'moss': 'DEVELOPER'}
    for index, kind in enumerate(KINDS):
        entry = specs['avatar_' + kind]
        source = Path(entry['source_asset'])
        if not source.is_absolute():
            source = ROOT / source
        center = (index - 1) * 2.05
        original = import_character(source, donor_names[kind] + ' original', center - .45)
        variant = import_character(OUT / ('avatar_' + kind + '.glb'), entry['name'], center + .45)
        pairs.append((kind, original, variant))
    base, label, muted = studio(scene, comparison=True)
    for index, (kind, original, variant) in enumerate(pairs):
        center = (index - 1) * 2.05
        for rig, x in ((original, center - .45), (variant, center + .45)):
            podium(x, rig['label'], base, radius=.38)
        text_label(donor_names[kind], center - .45, -.07, .064, label)
        text_label('ORIGINAL', center - .45, -.145, .034, muted)
        text_label(variant['label'].upper(), center + .45, -.07, .070, label)
        text_label('VARIANTE', center + .45, -.145, .034, muted)
    text_label('COMPARAISON DES PROPORTIONS', 0, 2.03, .092, label, y=0)
    text_label('Meme hauteur de presentation : 1,75 m', 0, 1.91, .040, muted, y=0)
    scene.frame_set(0)
    scene.render.filepath = str(OUT / 'proportions-reference.png')
    bpy.ops.render.render(write_still=True)
    return {kind: {'original': original['measurement'], 'variant': variant['measurement']}
            for kind, original, variant in pairs}


def main():
    specs = json.loads((OUT / 'report.json').read_text())
    gallery = render_gallery(specs)
    comparison = render_comparison(specs)
    (OUT / 'gallery-measurements.json').write_text(json.dumps({
        'method': 'Evaluated idle body bounds, excluding props; uniform display-parent scale only',
        'gallery': gallery, 'comparison': comparison,
    }, indent=2) + '\n')
    print('GALLERY_ANIMATION_POSES_AND_PROPORTIONS_RENDERED', flush=True)


if __name__ == '__main__':
    main()
