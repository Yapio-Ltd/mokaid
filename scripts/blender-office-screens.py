"""Give the nine existing desktop displays dedicated, upright screen UVs.

Run after blender-office-desktop.py. No vertex, transform, collider or socket
changes: only the existing display faces receive a semantic screen material.
"""
import hashlib
import json
from pathlib import Path

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/desktop-office-quality'
MANIFEST = ROOT / 'assets/office-desktop.json'
initial = json.loads(MANIFEST.read_text())
source_path = initial.get('screens', {}).get('sourceOfficePath', initial['path'])
source_sha = initial.get('screens', {}).get('sourceOfficeSha256', initial['sha256'])
source = ROOT / source_path
assert hashlib.sha256(source.read_bytes()).hexdigest() == source_sha

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.import_scene.gltf(filepath=str(source))

def geometry_digest(obj):
    return hashlib.sha256(repr((tuple(obj.matrix_world),
        [tuple(v.co) for v in obj.data.vertices],
        [tuple(p.vertices) for p in obj.data.polygons])).encode()).hexdigest()

before = {obj: geometry_digest(obj) for obj in bpy.context.scene.objects if obj.type == 'MESH'}
screen = bpy.data.materials.new('Desktop screen')
screen.use_nodes = True
bsdf = screen.node_tree.nodes.get('Principled BSDF')
bsdf.inputs['Base Color'].default_value = (.015, .022, .037, 1)
bsdf.inputs['Metallic'].default_value = 0
bsdf.inputs['Roughness'].default_value = .45
bsdf.inputs['Emission Color'].default_value = (.12, .20, .32, 1)
bsdf.inputs['Emission Strength'].default_value = 1

records = []
for obj in list(before):
    names = [material.name.strip() for material in obj.data.materials]
    if not any(name in {'Monitor', 'Lap Top'} for name in names):
        continue
    obj.data = obj.data.copy()
    mesh = obj.data
    uv = mesh.uv_layers.active.data
    selected = []
    for face in mesh.polygons:
        name = mesh.materials[face.material_index].name.strip()
        coordinates = [uv[index].uv for index in face.loop_indices]
        points = [obj.matrix_world @ mesh.vertices[index].co for index in face.vertices]
        area = sum((points[i] - points[0]).cross(points[i + 1] - points[0]).length / 2
                   for i in range(1, len(points) - 1))
        # Exact atlas islands measured in the pinned source, with glTF V flipped
        # by Blender's importer. Small bezel triangles remain untouched.
        bounds = (.0102, .3583, .0131, .6204) if name == 'Monitor' else (.5332, .7784, .3852, .7538)
        if name in {'Monitor', 'Lap Top'} and area > .005 and all(
            bounds[0] <= p.x <= bounds[1] and bounds[2] <= p.y <= bounds[3]
            for p in coordinates):
            selected.append(face)
    if not selected:
        raise RuntimeError(f'Display face atlas changed: {obj.name}')
    # A merged laptop node contains two separate displays. Normalize each one.
    groups = []
    remaining = set(face.index for face in selected)
    welded = {face.index: {tuple(round(value, 5) for value in mesh.vertices[index].co)
                          for index in face.vertices} for face in selected}
    while remaining:
        pending = [remaining.pop()]
        group = []
        while pending:
            index = pending.pop()
            group.append(mesh.polygons[index])
            connected = {other for other in remaining if welded[index] & welded[other]}
            remaining -= connected
            pending.extend(connected)
        groups.append(group)
    for group in groups:
        display_material = screen.copy()
        display_material.name = f'Desktop screen {len(records)}'
        material_index = len(mesh.materials)
        mesh.materials.append(display_material)
        world_points = [obj.matrix_world @ mesh.vertices[index].co for face in group for index in face.vertices]
        normal = Vector((0, 0, 0))
        for face in group:
            vertices = [obj.matrix_world @ mesh.vertices[index].co for index in face.vertices]
            normal += (vertices[1] - vertices[0]).cross(vertices[2] - vertices[0])
        normal.normalize()
        up = (Vector((0, 0, 1)) - normal * normal.z).normalized()
        right = up.cross(normal).normalized()
        x_values, y_values = [p.dot(right) for p in world_points], [p.dot(up) for p in world_points]
        left, bottom = min(x_values), min(y_values)
        width, height = max(x_values) - left, max(y_values) - bottom
        assert .30 < width < 1.1 and .20 < height < .65, (obj.name, width, height)
        for face in group:
            face.material_index = material_index
            for index in face.loop_indices:
                point = obj.matrix_world @ mesh.vertices[mesh.loops[index].vertex_index].co
                uv[index].uv = ((point.dot(right) - left) / width, (point.dot(up) - bottom) / height)
        center = sum(world_points, Vector()) / len(world_points)
        records.append({'node': obj.name, 'triangles': sum(len(face.vertices) - 2 for face in group),
                        'width': width, 'height': height,
                        'nativeCenter': [-center.x, center.z, center.y]})
    mesh.update()

assert len(records) == 9, records
assert sum(record['triangles'] for record in records) == 22, records
assert all(geometry_digest(obj) == digest for obj, digest in before.items())
OUT.mkdir(parents=True, exist_ok=True)
blend = OUT / 'office-desktop-screens.blend'
bpy.ops.wm.save_as_mainfile(filepath=str(blend))
temporary = OUT / 'office-desktop-screens.glb'
bpy.ops.export_scene.gltf(filepath=str(temporary), export_format='GLB',
    export_yup=True, export_apply=False, export_animations=True)
sha = hashlib.sha256(temporary.read_bytes()).hexdigest()
target = ROOT / f'assets/optimized/office.desktop.{sha[:12]}.glb'
temporary.replace(target)
latest = json.loads(MANIFEST.read_text())
assert latest['path'] == initial['path'], 'Office changed concurrently; do not overwrite its manifest'
latest.update({'path': str(target.relative_to(ROOT)), 'sha256': sha})
latest['screens'] = {'sourceOfficePath': source_path, 'sourceOfficeSha256': source_sha,
    'authoringFile': str(blend.relative_to(ROOT)), 'materialPrefix': 'Desktop screen ',
    'surfaceKind': 1, 'screenCount': len(records), 'geometryPreserved': True, 'displays': records}
MANIFEST.write_text(json.dumps(latest, indent=2) + '\n')
(OUT / 'screens-report.json').write_text(json.dumps(latest['screens'], indent=2) + '\n')
print(json.dumps({'path': latest['path'], 'sha256': sha, **latest['screens']}, indent=2))
