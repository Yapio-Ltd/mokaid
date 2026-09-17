"""Author the desktop room's cutaway plinth without moving any furniture.

Run: blender --background --python scripts/blender-office-desktop.py
The published web room is the pinned input; the native cooker uses the manifest.
Blender world (X,Y,Z) maps to native (-X,Z,Y).
"""
import hashlib
import json
import math
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'apps/web/public/assets3d/office.a830ba995121.glb'
OUT = ROOT / 'artifacts/desktop-office-quality'
CUT = 11.2
CHAIR_PULLBACKS = [.45, .50, .60, .45, .58, .925, .55, .58, .60]


def material(name, color, roughness, metallic=0, emission=None):
    result = bpy.data.materials.new(name)
    result.use_nodes = True
    bsdf = result.node_tree.nodes.get('Principled BSDF')
    bsdf.inputs['Base Color'].default_value = (*color, 1)
    bsdf.inputs['Roughness'].default_value = roughness
    bsdf.inputs['Metallic'].default_value = metallic
    if emission:
        bsdf.inputs['Emission Color'].default_value = (*emission, 1)
        bsdf.inputs['Emission Strength'].default_value = 1
    return result


def clipped_polygon(points):
    # Sutherland-Hodgman clipping in the native horizontal plane.
    result = []
    for a, b in zip(points, points[1:] + points[:1]):
        da, db = a[0] - a[1] - CUT, b[0] - b[1] - CUT
        if da <= 0:
            result.append(a)
        if (da <= 0) != (db <= 0):
            t = da / (da - db)
            result.append((a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])))
    return result


def geometry_digest(obj):
    return hashlib.sha256(repr((tuple(obj.matrix_world),
        [tuple(v.co) for v in obj.data.vertices],
        [tuple(p.vertices) for p in obj.data.polygons])).encode()).hexdigest()


OUT.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.import_scene.gltf(filepath=str(SOURCE))
floor = bpy.data.objects['Plane.005']
unchanged = {o: geometry_digest(o) for o in bpy.context.scene.objects
             if o.type == 'MESH' and o != floor and o.name not in {'wall 1', 'Object_122.012', 'Object_122.002'}}

# This atlas node contains two leather chairs. Adjust only the occupied one:
# set its adjustable pedestal so its cushion is .51 m above the measured
# meeting-room platform (.064917 m), preserving the wheels and original floor.
chair = bpy.data.objects['Object_122.012']
chair_original = [v.co.copy() for v in chair.data.vertices]
chair_vertices = {v.index for v in chair.data.vertices
                  if (chair.matrix_world @ v.co).y < -.20}
assert chair_vertices and len(chair_vertices) < len(chair.data.vertices)
assert all(not any(i in chair_vertices for i in p.vertices) or
           all(i in chair_vertices for i in p.vertices) for p in chair.data.polygons)
chair_inverse = chair.matrix_world.inverted()
for index in chair_vertices:
    p = chair.matrix_world @ chair.data.vertices[index].co
    u = max(0, min(1, (p.z - .18) / .20))
    p.z += .012687 * u * u * (3 - 2 * u)
    chair.data.vertices[index].co = chair_inverse @ p
chair.data.update()
assert all(v.co == chair_original[v.index] for v in chair.data.vertices if v.index not in chair_vertices)

def separate_chair(obj, indices, name):
    """Unbatch a complete physical chair so the runtime can roll it back."""
    clone = obj.copy()
    clone.data = obj.data.copy()
    clone.name = name
    bpy.context.collection.objects.link(clone)
    obj.data = obj.data.copy()
    for target, keep in ((clone, True), (obj, False)):
        bm = bmesh.new()
        bm.from_mesh(target.data)
        bm.verts.ensure_lookup_table()
        remove = [v for v in bm.verts if (v.index in indices) != keep]
        bmesh.ops.delete(bm, geom=remove, context='VERTS')
        bm.to_mesh(target.data)
        bm.free()
        target.data.update()
    return clone

separate_chair(chair, chair_vertices, 'chair_5')
chair3 = bpy.data.objects['Object_122.002']
chair3_indices = {v.index for v in chair3.data.vertices
                  if (chair3.matrix_world @ v.co).x < 0}
assert chair3_indices and len(chair3_indices) < len(chair3.data.vertices)
assert all(not any(i in chair3_indices for i in p.vertices) or
           all(i in chair3_indices for i in p.vertices) for p in chair3.data.polygons)
separate_chair(chair3, chair3_indices, 'chair_3')
for seat, name in {0:'instance_8', 1:'instance_2', 2:'instance_6',
                    4:'instance_1', 6:'instance_5', 7:'instance_0', 8:'instance_3'}.items():
    bpy.data.objects[name].name = f'chair_{seat}'

# The foosball table is packed into the same atlas mesh as room partitions.
# Select complete connected islands inside its measured bounds, preserving
# every other vertex of that mesh. Give both players a usable side and scale
# the formerly 64 cm tall model to the character's interaction height.
atlas = bpy.data.objects['wall 1']
adjacency = [[] for _ in atlas.data.vertices]
for edge in atlas.data.edges:
    a, b = edge.vertices
    adjacency[a].append(b)
    adjacency[b].append(a)
seen, table_vertices = set(), set()
original_atlas = [v.co.copy() for v in atlas.data.vertices]
for seed in range(len(atlas.data.vertices)):
    if seed in seen:
        continue
    stack, component, coords = [seed], [], []
    seen.add(seed)
    while stack:
        index = stack.pop()
        component.append(index)
        p = atlas.matrix_world @ atlas.data.vertices[index].co
        coords.append(Vector((-p.x, p.z, p.y)))
        for neighbor in adjacency[index]:
            if neighbor not in seen:
                seen.add(neighbor)
                stack.append(neighbor)
    if all(-2.30 <= p.x <= -1.39 and -.03 <= p.y <= .66 and
           -5.24 <= p.z <= -4.10 for p in coords):
        table_vertices.update(component)
assert 1500 <= len(table_vertices) <= 3500, len(table_vertices)
inverse_atlas = atlas.matrix_world.inverted()
table_bounds = []
for index in table_vertices:
    p = atlas.matrix_world @ atlas.data.vertices[index].co
    x, y, z = -3.10 + (-p.x + 1.845) * 1.6, p.z * 1.6, -4.67 + (p.y + 4.67) * 1.6
    atlas.data.vertices[index].co = inverse_atlas @ Vector((-x, z, y))
    table_bounds.append((x, y, z))
atlas.data.update()
assert all(v.co == original_atlas[v.index] for v in atlas.data.vertices if v.index not in table_vertices)

# Only the empty tip of the floor is trimmed. Its material UVs and room walls
# survive; every piece of furniture, lamp and interaction point is unchanged.
bpy.ops.object.select_all(action='DESELECT')
floor.select_set(True)
bpy.context.view_layer.objects.active = floor
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
# Widen the open side aisle by 30 cm. The old chamfer left less than a 70 cm
# passage beside a fixed partition and disconnected a desk from the room.
for v in floor.data.vertices:
    native_x, native_z = -v.co.x, v.co.y
    if native_z < 0 and native_x > 5:
        v.co.x -= .30
bm = bmesh.new()
bm.from_mesh(floor.data)
bmesh.ops.bisect_plane(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
    dist=0.00001, plane_co=(-CUT / 2, -CUT / 2, 0), plane_no=(-1, -1, 0),
    clear_outer=True, clear_inner=False)
bm.to_mesh(floor.data)
bm.free()
floor.data.update()

outline = clipped_polygon([(-7.429588, 6.472565), (7.067595, 6.472565),
    (7.367595, -0.1398), (5.8049, -6.472565), (-7.429588, -6.472565)])
n = len(outline)
vertices = [(-x, z, h) for h in (-.19, -.012) for x, z in outline]
faces = [tuple(range(n - 1, -1, -1)), tuple(range(n, n * 2))]
faces += [(i, (i + 1) % n, (i + 1) % n + n, i + n) for i in range(n)]
mesh = bpy.data.meshes.new('Desktop plinth geometry')
mesh.from_pydata(vertices, [], faces)
mesh.update()
plinth = bpy.data.objects.new('Desktop plinth', mesh)
bpy.context.collection.objects.link(plinth)
plinth.data.materials.append(material('Desktop plinth', (.055, .045, .08), .62, .24))
bevel = plinth.modifiers.new('Soft machined edge', 'BEVEL')
bevel.width, bevel.segments = .035, 3
bpy.context.view_layer.objects.active = plinth
bpy.ops.object.modifier_apply(modifier=bevel.name)

# A fine inlaid rim follows only the open cutaway edges, below the walking
# surface. It gives the room a finished silhouette without hiding the people.
curve = bpy.data.curves.new('Desktop perimeter inlay', 'CURVE')
curve.dimensions = '3D'
curve.bevel_depth, curve.bevel_resolution = .012, 2
spline = curve.splines.new('POLY')
edge = outline[1:]  # omit the rear wall edge
spline.points.add(len(edge) - 1)
for p, (x, z) in zip(spline.points, edge):
    p.co = (-x, z, -.075, 1)
rim = bpy.data.objects.new('Desktop perimeter inlay', curve)
bpy.context.collection.objects.link(rim)
rim.data.materials.append(material('Desktop rim', (.12, .05, .25), .4,
    emission=(.20, .045, .5)))
bpy.ops.object.select_all(action='DESELECT')
rim.select_set(True)
bpy.context.view_layer.objects.active = rim
bpy.ops.object.convert(target='MESH')

assert all(geometry_digest(obj) == digest for obj, digest in unchanged.items())
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / 'office-desktop.blend'))
temporary = OUT / 'office-desktop.glb'
bpy.ops.export_scene.gltf(filepath=str(temporary), export_format='GLB',
    export_animations=False, export_cameras=False, export_lights=False,
    export_yup=True, export_apply=True)
data = temporary.read_bytes()
sha = hashlib.sha256(data).hexdigest()
target = ROOT / f'assets/optimized/office.desktop.{sha[:12]}.glb'
target.write_bytes(data)
temporary.unlink()
manifest = {
    'path': str(target.relative_to(ROOT)), 'sha256': sha,
    'sourcePath': str(SOURCE.relative_to(ROOT)),
    'sourceSha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
    'authoringFile': str((OUT / 'office-desktop.blend').relative_to(ROOT)),
    'floorOutlineNativeXZ': outline, 'frontChamferXMinusZ': CUT,
    'floorSideWidening': .30,
    'unchangedFurnitureMeshes': len(unchanged),
    'adjustedDeskChair': {'seat': 5, 'vertices': len(chair_vertices),
                         'translationNativeXZ': [0, 0],
                         'cushionHeight': .574917, 'pedestalAdjustment': .012687},
    'foosball': {
        'sourceCenterNativeXZ': [-1.845, -4.67], 'centerNativeXZ': [-3.10, -4.67],
        'scale': 1.6, 'vertices': len(table_vertices), 'handleHeight': .956,
        'min': [min(p[i] for p in table_bounds) for i in range(3)],
        'max': [max(p[i] for p in table_bounds) for i in range(3)],
        'playerWest': [-4.1408, -4.67], 'playerEast': [-2.0672, -4.67]
    },
    'navigation': {
        'sockets': {
            'coffee_active': {'x': -1.79, 'z': 5.23, 'yaw': -math.pi},
            **{f'desk_{i}': {'chairNode': f'chair_{i}', 'pullback': CHAIR_PULLBACKS[i]} for i in range(9)},
            'desk_5': {'x': -6.019, 'z': -.665, 'yaw': -math.pi / 2,
                       'approachX': -5.6165, 'approachZ': -.665,
                       'chairNode': 'chair_5', 'pullback': .925,
                       'seatHeight': .574917, 'floorHeight': .064917},
            'desk_8': {'chairNode': 'chair_8', 'pullback': .60},
            'foosball_a': {'x': -4.1408, 'z': -4.67, 'yaw': -math.pi / 2,
                          'approachX': -4.30, 'approachZ': -4.67},
            'foosball_b': {'x': -2.0672, 'z': -4.67, 'yaw': math.pi / 2,
                          'approachX': -1.88, 'approachZ': -4.67},
            'coffee_chat_0': {'x': -2.74, 'z': 5.10, 'approachX': -2.74, 'approachZ': 5.10,
                              'yaw': math.atan2(-1.89, .20)},
            'coffee_chat_1': {'x': -.85, 'z': 4.90, 'approachX': -.85, 'approachZ': 4.90,
                              'yaw': math.atan2(1.89, -.20)}
        },
        'obstacles': [{
            'old': [-2.27, -1.42, -5.21, -4.13],
            'new': [min(p[0] for p in table_bounds), max(p[0] for p in table_bounds),
                    min(p[2] for p in table_bounds), max(p[2] for p in table_bounds)]
        }],
        # Verified against source/final triangles: these four raster fragments
        # belonged exclusively to the relocated foosball table.
        'removeObstacles': [[-2.35, -2.25, -5.35, -4.15], [-2.35, -1.25, -4.15, -4.05], [-2.25, -1.35, -5.35, -5.25], [-1.45, -1.25, -5.05, -4.15]],
        'anchors': {'foosball_w': {'x': -4.30, 'z': -4.67},
                    'foosball_s': {'x': -3.10, 'z': -3.30}},
        'floorSurfaces': [{'minX': -7.381761, 'maxX': -4.393354,
                           'minZ': -2.386491, 'maxZ': 1.822855, 'height': .064917}]
    },
    'notes': 'Blender-authored cutaway plinth and full-size foosball table with two accessible opposing sides. Other atlas geometry and furniture preserved.'
}
(ROOT / 'assets/office-desktop.json').write_text(json.dumps(manifest, indent=2) + '\n')
(OUT / 'geometry-report.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
