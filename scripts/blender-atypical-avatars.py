"""Author three original characters on the proven office animation skeleton.

Run with Blender --background --python scripts/blender-atypical-avatars.py --.
All new surfaces are skinned. Hands, shoe contact surfaces and interaction props
retain the calibrated donor weights; the 48 original actions remain editable.
Exports are staged for independent validation before catalog registration.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from pathlib import Path
import runpy
import sys

import bpy
from mathutils import Matrix, Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/avatar-atypical'
CATALOG = (ROOT / 'apps/api/lib/mokaid/assets_3d.ex').read_text()
DONOR = ROOT / 'apps/web/public' / re.search(
    r'"slug" => "avatar_design".*?"cdn_path" => "([^"]+)"', CATALOG, re.S).group(1).lstrip('/')
HELPERS = runpy.run_path(str(ROOT / 'scripts/blender-avatar-quality.py'))
SPECS = {
    'byte': {'name': 'Byte', 'style': 'Retro ceramic robot / ivory, coral and petrol',
             'colors': ['#e5dbc4', '#e97343', '#183d43']},
    'nyx': {'name': 'Nyx', 'style': 'Cyberpunk hacker / violet undercut, cyan accents, biker jacket',
            'colors': ['#7837b8', '#56ddd9', '#202031']},
    'moss': {'name': 'Moss', 'style': 'Botanical sprite / leaf crown, amber workwear and moss green',
             'colors': ['#689a60', '#db9c3c', '#263e38']},
}
ARM = None
PARTS = []


def material(name, color, roughness=.72):
    m = bpy.data.materials.new(name)
    m.diffuse_color = (*color, 1)
    m.use_nodes = True
    shader = m.node_tree.nodes.get('Principled BSDF')
    shader.inputs['Base Color'].default_value = (*color, 1)
    shader.inputs['Roughness'].default_value = roughness
    shader.inputs['Metallic'].default_value = 0
    return m


def bind(obj, bone, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    bpy.ops.object.select_all(action='DESELECT')
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    group = obj.vertex_groups.new(name=bone)
    group.add(list(range(len(obj.data.vertices))), 1, 'REPLACE')
    modifier = obj.modifiers.new('Office skin', 'ARMATURE')
    modifier.object = ARM
    for face in obj.data.polygons:
        face.use_smooth = True
    PARTS.append(obj)
    return obj


def sphere(name, center, scale, bone, mat, segments=24):
    bpy.ops.object.select_all(action='DESELECT')
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=16, location=center)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    return bind(obj, bone, mat)


def box(name, center, size, bone, mat, bevel=.015):
    bpy.ops.object.select_all(action='DESELECT')
    bpy.ops.mesh.primitive_cube_add(size=1, location=center)
    obj = bpy.context.object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    modifier = obj.modifiers.new('Soft manufactured edges', 'BEVEL')
    modifier.width = bevel
    modifier.segments = 3
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    return bind(obj, bone, mat)


def mesh(name, vertices, faces, bone, mat):
    data = bpy.data.meshes.new(name)
    data.from_pydata(vertices, [], faces)
    data.update()
    obj = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(obj)
    return bind(obj, bone, mat)


def tube(name, points, radius, bone, mat):
    data = bpy.data.curves.new(name, 'CURVE')
    data.dimensions = '3D'
    data.resolution_u = 12
    data.bevel_depth = radius
    data.bevel_resolution = 3
    spline = data.splines.new('BEZIER')
    spline.bezier_points.add(len(points)-1)
    for p, co in zip(spline.bezier_points, points):
        p.co = co
        p.handle_left_type = p.handle_right_type = 'AUTO'
    obj = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(obj)
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.convert(target='MESH')
    return bind(bpy.context.object, bone, mat)


def segment(name, a, b, radii, bone, mat):
    a, b = Vector(a), Vector(b)
    axis = (b-a).normalized()
    u = axis.cross(Vector((0, 1, 0))).normalized()
    v = axis.cross(u).normalized()
    vertices, faces = [], []
    n = 20
    for i, radius in enumerate(radii):
        center = a.lerp(b, i/(len(radii)-1))
        for j in range(n):
            angle = math.tau*j/n
            vertices.append(center + radius*(math.cos(angle)*u + math.sin(angle)*v))
    for i in range(len(radii)-1):
        for j in range(n):
            faces.append((i*n+j, i*n+(j+1)%n, (i+1)*n+(j+1)%n, (i+1)*n+j))
    faces += [tuple(reversed(range(n))), tuple((len(radii)-1)*n+j for j in range(n))]
    return mesh(name, vertices, faces, bone, mat)


def leaf(name, start, tip, width, bone, mat, arch=0):
    start, tip = Vector(start), Vector(tip)
    axis = (tip-start).normalized()
    side = axis.cross(Vector((0, 1, 0))).normalized()
    vertices = []
    rings = 10
    for i in range(rings+1):
        t = i/rings
        center = start.lerp(tip, t) + Vector((0, -.12*arch, arch))*math.sin(math.pi*t)
        bulge = math.sin(math.pi*t)
        vertices.extend([center-side*width*bulge,
                         center+Vector((0, -.018*bulge, 0)),
                         center+side*width*bulge,
                         center+Vector((0, .008*bulge, 0))])
    faces = [(i*4+j, i*4+(j+1)%4, (i+1)*4+(j+1)%4, (i+1)*4+j)
             for i in range(rings) for j in range(4)]
    return mesh(name, vertices, faces, bone, mat)


def head(name):
    return ARM.matrix_world @ ARM.data.bones[name].head_local


def copy_contact_mesh(source, name, names, mat, max_z=None):
    selected = []
    for v in source.data.vertices:
        weight = sum(g.weight for g in v.groups if source.vertex_groups[g.group].name in names)
        p = source.matrix_world @ v.co
        if weight > .45 and (max_z is None or p.z < max_z):
            selected.append(v.index)
    indices = {old: new for new, old in enumerate(selected)}
    vertices = [source.matrix_world @ source.data.vertices[i].co for i in selected]
    faces = [tuple(indices[i] for i in p.vertices) for p in source.data.polygons
             if all(i in indices for i in p.vertices)]
    data = bpy.data.meshes.new(name)
    data.from_pydata(vertices, [], faces)
    obj = bpy.data.objects.new(name, data)
    bpy.context.scene.collection.objects.link(obj)
    data.materials.append(mat)
    for old, new in indices.items():
        for g in source.data.vertices[old].groups:
            group_name = source.vertex_groups[g.group].name
            group = obj.vertex_groups.get(group_name) or obj.vertex_groups.new(name=group_name)
            group.add([new], g.weight, 'REPLACE')
    modifier = obj.modifiers.new('Calibrated office contact skin', 'ARMATURE')
    modifier.object = ARM
    for p in data.polygons:
        p.use_smooth = True
    PARTS.append(obj)
    return obj


def torso(mat, robot=False):
    rings = [(.845,.105,.087),(.88,.145,.10),(.93,.154,.103),(.98,.138,.092),
             (1.035,.128,.088),(1.10,.155,.104),(1.15,.174,.108),(1.18,.115,.080)]
    vertices, faces = [], []
    for z, rx, ry in rings:
        for j in range(32):
            t = j*math.tau/32
            vertices.append((.005+rx*math.cos(t), -.106+ry*math.sin(t), z))
    for i in range(len(rings)-1):
        for j in range(32):
            faces.append((i*32+j,i*32+(j+1)%32,(i+1)*32+(j+1)%32,(i+1)*32+j))
    faces += [tuple(reversed(range(32))),tuple((len(rings)-1)*32+j for j in range(32))]
    obj = mesh('Tailored torso', vertices, faces, 'Hips', mat)
    obj.vertex_groups.clear()
    chain = ['Hips', 'Spine02', 'Spine01', 'Spine']
    for vertex in obj.data.vertices:
        z = vertex.co.z
        nearest = sorted(chain,key=lambda n:abs(head(n).z-z))[:2]
        weights = [1/max(.008,abs(head(n).z-z))**2 for n in nearest]
        for n, w in zip(nearest,weights):
            group = obj.vertex_groups.get(n) or obj.vertex_groups.new(name=n)
            group.add([vertex.index],w/sum(weights),'REPLACE')


def limbs(source, kind, p):
    robot = kind == 'byte'
    for side, sign, suffix in [('Left',1,'l'),('Right',-1,'r')]:
        for start,end,bone,r in [('UpLeg','Leg','UpLeg',.075),('Leg','Foot','Leg',.063),
                                 ('Arm','ForeArm','Arm',.058),('ForeArm','Hand','ForeArm',.047)]:
            a,b = head(side+start),head(side+end)
            cloth = p['body'] if start in {'Arm','ForeArm'} else p['pants']
            if robot:
                sphere('Graphite joint '+side+start,a,(r*.86,)*3,side+bone,p['dark'])
                segment('Ceramic shell '+side+start,a.lerp(b,.09),a.lerp(b,.92),
                        [r*.78,r,r*.91,r*.78],side+bone,cloth)
                c = a.lerp(b,.72)
                sphere('Coral inset '+side+start,c+Vector((0,-r*.88,0)),
                       (r*.50,.008,r*.17),side+bone,p['accent'])
            else:
                segment('Tailored limb '+side+start,a,b,[r*.80,r,r*.97,r*.79],side+bone,cloth)
                sphere('Soft joint '+side+start,a,(r*.91,)*3,side+bone,cloth)
        hand_names = {side+'Hand','grip_prox.'+suffix,'grip_dist.'+suffix,'grip_thumb.'+suffix}
        copy_contact_mesh(source,'Articulated fingers '+side,hand_names,p['skin'])
        feet_names = {side+'Foot',side+'ToeBase'}
        copy_contact_mesh(source,'Contact shoes '+side,feet_names,p['boots'],max_z=.22)
        wrist = head(side+'Hand')
        segment('Wrist cuff '+side,head(side+'ForeArm').lerp(wrist,.79),wrist,
                [.049,.051,.047],side+'ForeArm',p['accent'])
        foot = head(side+'Foot')
        box('Boot tongue '+side,foot+Vector((0,-.050,-.010)),(.072,.044,.092),side+'Foot',p['accent'],.012)
        for z in [.005,.025,.045]:
            tube('Laces '+side,[(foot.x-.035,foot.y-.076,foot.z-z),
                               (foot.x+.035,foot.y-.076,foot.z-z)],.004,side+'Foot',p['trim'])
        knee = head(side+'Leg')
        box('Knee inset '+side,knee+Vector((0,-.065,.018)),(.077,.025,.096),side+'Leg',p['accent'],.016)


def human_face(p, moss=False):
    x,y,z = .002,-.080,1.400
    sphere('Sculpted face',(x,y,z),(.155,.133,.184),'Head',p['skin'],32)
    for sign in [-1,1]:
        eye_x=x+sign*.065
        sphere('Eye white',(eye_x,-.201,1.418),(.043,.016,.036),'Head',p['white'])
        sphere('Iris',(eye_x+sign*.002,-.216,1.418),(.018,.006,.025),'Head',p['iris'])
        sphere('Pupil',(eye_x+sign*.002,-.222,1.418),(.009,.003,.017),'Head',p['dark'])
        sphere('Eye catchlight',(eye_x-.006,-.226,1.428),(.005,.002,.006),'Head',p['white'],16)
        tube('Upper eyelid',[(eye_x-.039,-.200,1.429),(eye_x,-.212,1.452),
                             (eye_x+.039,-.197,1.430)],.005,'Head',p['hair'])
        tube('Expressive brow',[(eye_x-sign*.039,-.203,1.483),
                                (eye_x,-.216,1.487),(eye_x+sign*.039,-.193,1.476)],.009,'Head',p['hair'])
        if moss:
            leaf('Pointed ear',(sign*.13,-.079,1.399),(sign*.278,-.069,1.477),.046,'Head',p['skin'])
            leaf('Ear inner',(sign*.158,-.110,1.41),(sign*.25,-.086,1.465),.022,'Head',p['accent'])
        else:
            sphere('Ear',(sign*.157,-.060,1.401),(.024,.025,.046),'Head',p['skin'])
        for dx,dz in [(0,0),(.018,.006),(-.013,.008)]:
            sphere('Freckle',(eye_x+dx,-.195,1.36+dz),(.003,.002,.003),'Head',p['freckle'],12)
    sphere('Nose',(x,-.221,1.369),(.027,.032,.026),'Head',p['skin'])
    tube('Smile',[(-.033,-.200,1.329),(0,-.211,1.320),(.034,-.198,1.330)],.004,'Head',p['lip'])
    sphere('Lower lip',(0,-.200,1.315),(.026,.008,.007),'Head',p['lip'])


def byte(p):
    box('CRT ceramic housing',(0,-.080,1.415),(.407,.306,.362),'Head',p['skin'],.066)
    box('Coral monitor gasket',(0,-.241,1.414),(.363,.034,.299),'Head',p['accent'],.048)
    box('Petrol face glass',(0,-.263,1.417),(.331,.019,.267),'Head',p['dark'],.042)
    for sign in [-1,1]:
        box('Luminous eye',(sign*.077,-.277,1.445),(.032,.009,.070),'Head',p['iris'],.014)
        tube('Friendly brow',[(sign*.047,-.277,1.509),(sign*.076,-.280,1.516),
                              (sign*.105,-.277,1.506)],.007,'Head',p['iris'])
        sphere('Ear hinge',(sign*.215,-.072,1.426),(.029,.068,.072),'Head',p['accent'])
        sphere('Ear inset',(sign*.240,-.072,1.426),(.007,.039,.041),'Head',p['dark'])
        for zz in [1.43,1.46,1.49]:
            box('Cooling slit',(sign*.204,.014,zz),(.009,.064,.006),'Head',p['dark'],.002)
    tube('Pixel smile',[(-.053,-.278,1.365),(-.032,-.280,1.348),(.032,-.280,1.348),(.053,-.278,1.365)],.007,'Head',p['iris'])
    segment('Antenna',(0.137,.002,1.565),(.178,.002,1.607),[.008,.006],'Head',p['dark'])
    sphere('Antenna tip',(.178,.002,1.607),(.017,)*3,'Head',p['accent'])
    for sign in [-1,1]:
        box('Chest side armor',(sign*.116,-.163,1.108),(.068,.072,.112),'Spine',p['skin'],.020)
    sphere('Gauge bezel',(0,-.223,1.115),(.055,.017,.055),'Spine',p['accent'])
    sphere('Gauge face',(0,-.239,1.115),(.043,.006,.043),'Spine',p['trim'])
    tube('Gauge needle',[(0,-.247,1.115),(.021,-.247,1.137)],.004,'Spine',p['dark'])
    for i in range(4):
        box('Belly grille',(-.043+i*.029,-.206,.995),(.010,.016,.043),'Spine02',p['dark'],.004)
    box('Utility belt',(0,-.108,.926),(.300,.228,.035),'Hips',p['dark'],.013)
    box('Belt battery',(0,-.236,.926),(.084,.025,.043),'Hips',p['accent'],.006)


def hair_cap(mat):
    vertices, faces = [], []
    n, rings = 48, 12
    for i in range(rings+1):
        theta = .015 + (1.25-.015)*i/rings
        for j in range(n):
            phi = math.tau*j/n
            vertices.append((.164*math.sin(theta)*math.cos(phi),
                             -.08+.142*math.sin(theta)*math.sin(phi),
                             1.4+.193*math.cos(theta)))
    for i in range(rings):
        for j in range(n):
            faces.append((i*n+j,i*n+(j+1)%n,(i+1)*n+(j+1)%n,(i+1)*n+j))
    mesh('Shaped crown cap',vertices,faces,'Head',mat)


def nyx(p):
    human_face(p)
    hair_cap(p['hair'])
    for i in range(9):
        x = -.140+i*.025
        tip = (x-.017,-.219,1.492-.105*(i/8)**1.8)
        leaf('Swept violet fringe',(x+.056,-.033,1.592),tip,.029,'Head',p['hair'],.070)
    for i in range(3):
        leaf('Cyan fringe streak',(-.080+i*.021,-.020,1.594),
             (-.118+i*.018,-.222,1.508),.010,'Head',p['accent'],.075)
    for i in range(5):
        leaf('Bob locks',(-.153,.003,1.52),(-.167+i*.013,-.035,1.276+i*.015),.031,'Head',p['hair'])
    box('Temple interface',(.155,-.130,1.443),(.023,.074,.035),'Head',p['dark'],.006)
    box('Temple light',(.170,-.130,1.443),(.006,.042,.013),'Head',p['accent'],.003)
    tube('Ear cuff',[(.167,-.080,1.382),(.182,-.088,1.355),(.157,-.089,1.345)],.006,'Head',p['trim'])
    for sign in [-1,1]:
        mesh('Biker lapel',[(sign*.018,-.221,1.16),(sign*.116,-.206,1.184),
                           (sign*.070,-.220,1.055),(sign*.037,-.217,1.08)],[(0,1,2,3)],'Spine',p['hair'])
    tube('Jacket zip',[(-.038,-.211,.99),(.053,-.215,1.13)],.006,'Spine01',p['trim'])
    box('Zip pull',(.036,-.226,1.116),(.012,.010,.023),'Spine01',p['accent'],.003)
    box('Waistband',(0,-.110,.915),(.300,.211,.032),'Hips',p['dark'],.010)
    for sign in [-1,1]:
        box('Utility hip tab',(sign*.143,-.136,.91),(.039,.047,.107),'Hips',p['hair'],.009)
    tube('Neck band',[(-.047,-.107,1.222),(0,-.143,1.214),(.047,-.107,1.222)],.014,'neck',p['accent'])


def moss(p):
    human_face(p,True)
    hair_cap(p['hair'])
    for i in range(13):
        angle=i*math.tau/13
        start=(.016*math.cos(angle),-.025,1.590)
        tip=(.170*math.sin(angle),-.044-.132*math.cos(angle),1.46+.032*math.sin(angle*2))
        leaf('Layered crown leaf',start,tip,.045,'Head',p['leaf2'] if i%3 else p['hair'],.083)
        if i%2==0:
            tube('Leaf midrib',[start,Vector(start).lerp(Vector(tip),.55)+Vector((0,-.015,0)),tip],.002,'Head',p['accent'])
    leaf('Crown shoot',(-.019,-.017,1.571),(-.091,-.019,1.626),.028,'Head',p['leaf2'])
    leaf('Crown shoot right',(-.010,-.014,1.584),(.065,-.018,1.629),.025,'Head',p['accent'])
    for i in range(3):
        sphere('Seed pod',(.117+i*.012,-.112,1.516+i*.013),(.012,.011,.015),'Head',p['boots'],16)
    box('Overalls bib',(0,-.210,1.087),(.149,.024,.135),'Spine01',p['pants'],.018)
    for sign in [-1,1]:
        tube('Overall strap',[(sign*.067,-.216,1.086),(sign*.096,-.205,1.159),
                              (sign*.087,-.087,1.184)],.014,'Spine',p['pants'])
        sphere('Brass button',(sign*.063,-.228,1.132),(.010,.005,.010),'Spine01',p['trim'],16)
        box('Garden pocket',(sign*.106,-.219,.955),(.075,.032,.072),'Hips',p['accent'],.013)
    leaf('Chest leaf badge',(-.025,-.231,1.06),(.027,-.236,1.10),.018,'Spine01',p['leaf2'])
    tube('Scarf',[(-.068,-.115,1.213),(0,-.149,1.204),(.068,-.115,1.213)],.022,'neck',p['boots'])
    leaf('Scarf knot',(-.036,-.145,1.207),(-.093,-.169,1.142),.024,'Spine',p['boots'])


def palettes(kind):
    colors = {
        'byte': dict(skin=(.76,.70,.55),body=(.76,.70,.55),pants=(.66,.61,.49),accent=(.80,.19,.07),
                     dark=(.025,.075,.082),trim=(.95,.88,.64),iris=(.22,.80,.75),boots=(.14,.24,.24)),
        'nyx': dict(skin=(.48,.245,.13),body=(.035,.030,.065),pants=(.09,.046,.17),accent=(.10,.72,.68),
                    dark=(.010,.016,.025),trim=(.64,.72,.77),iris=(.10,.42,.45),boots=(.06,.055,.10),
                    hair=(.21,.038,.40),white=(.91,.90,.80),freckle=(.25,.085,.05),lip=(.26,.045,.062)),
        'moss': dict(skin=(.40,.62,.32),body=(.70,.36,.075),pants=(.055,.13,.12),accent=(.66,.64,.20),
                     dark=(.018,.047,.032),trim=(.88,.66,.29),iris=(.48,.22,.032),boots=(.39,.14,.065),
                     hair=(.055,.21,.11),leaf2=(.18,.39,.11),white=(.93,.88,.69),freckle=(.19,.33,.10),lip=(.12,.22,.075)),
    }[kind]
    return {key:material(kind+' / '+key,color) for key,color in colors.items()}


def evaluated_points(objects):
    bpy.context.view_layer.update()
    dg=bpy.context.evaluated_depsgraph_get()
    result=[]
    for obj in objects:
        evaluated=obj.evaluated_get(dg)
        data=evaluated.to_mesh()
        result.extend(obj.matrix_world@v.co for v in data.vertices)
        evaluated.to_mesh_clear()
    return result


def studio():
    scene=bpy.context.scene
    scene.render.engine='BLENDER_EEVEE'
    scene.render.resolution_x=scene.render.resolution_y=1000
    scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG'
    scene.render.image_settings.color_mode='RGBA'
    scene.render.film_transparent=True
    scene.view_settings.view_transform='AgX'
    scene.world=bpy.data.worlds.new('Character studio')
    scene.world.use_nodes=True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(.15,.17,.22,1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.35
    target=Vector((0,-.04,.86))
    camera_data=bpy.data.cameras.new('Character camera')
    camera=bpy.data.objects.new('Character camera',camera_data)
    scene.collection.objects.link(camera)
    camera.location=(2.8,-7.3,2.8)
    camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
    camera_data.type='ORTHO'
    camera_data.ortho_scale=1.95
    scene.camera=camera
    for name,location,energy,size,color in [
        ('Large warm key',(-3,-4,5),480,4,(1,.86,.71)),
        ('Cool fill',(3,-2,3),280,3,(.64,.80,1)),
        ('Soft rim',(1,3,4),620,3,(.73,.73,1))]:
        data=bpy.data.lights.new(name,'AREA')
        obj=bpy.data.objects.new(name,data)
        scene.collection.objects.link(obj)
        obj.location=location
        obj.rotation_euler=(target-obj.location).to_track_quat('-Z','Y').to_euler()
        data.energy,data.shape,data.size,data.color=energy,'DISK',size,color
    return scene,camera


def main():
    global ARM,PARTS
    parser=argparse.ArgumentParser()
    parser.add_argument('--only',nargs='+',choices=list(SPECS))
    parser.add_argument('--skip-export',action='store_true')
    args=parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    OUT.mkdir(parents=True,exist_ok=True)
    report=json.loads((OUT/'report.json').read_text()) if (OUT/'report.json').exists() else {}
    donor_report=json.loads((ROOT/'artifacts/avatar-life/report.json').read_text())['avatar_design']
    for kind in args.only or SPECS:
        print('AUTHOR ORIGINAL CHARACTER',kind,flush=True)
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.context.scene.render.fps=60
        bpy.ops.import_scene.gltf(filepath=str(DONOR))
        ARM=next(o for o in bpy.data.objects if o.type=='ARMATURE')
        rig_scale=tuple(ARM.scale)
        ARM.animation_data.action=bpy.data.actions['idle']
        bpy.context.scene.frame_set(0)
        source=bpy.data.objects['char1']
        donor_points=evaluated_points([source])
        donor_top=max(p.z for p in donor_points)
        for obj in list(bpy.data.objects):
            if obj.type in {'LIGHT','CAMERA'}:
                bpy.data.objects.remove(obj,do_unlink=True)
        ARM.data.pose_position='REST'
        PARTS=[]
        p=palettes(kind)
        torso(p['body'],kind=='byte')
        limbs(source,kind,p)
        segment('Neck',head('neck'),head('Head'),[.038,.037,.038],'neck',p['dark'] if kind=='byte' else p['skin'])
        {'byte':byte,'nyx':nyx,'moss':moss}[kind](p)
        bpy.data.objects.remove(source,do_unlink=True)
        ARM.data.pose_position='POSE'
        # Keep the donor's evaluated height: this preserves the native 1.75 m
        # normalization and all calibrated seat/foot/prop contact positions.
        points=evaluated_points(PARTS)
        top=max(v.z for v in points)
        rest=ARM.matrix_world@ARM.data.bones['Head'].matrix_local
        pose=ARM.matrix_world@ARM.pose.bones['Head'].matrix
        delta=(pose@rest.inverted()).to_3x3().inverted()@Vector((0,0,donor_top-top))
        for obj in PARTS:
            group=obj.vertex_groups.get('Head')
            if group:
                for v in obj.data.vertices:
                    if any(g.group==group.index and g.weight>.999 for g in v.groups):
                        v.co+=delta
        # A single mesh per character keeps material draw calls bounded; props
        # stay separate because the renderer identifies their semantic materials.
        bpy.ops.object.select_all(action='DESELECT')
        for obj in PARTS:obj.select_set(True)
        bpy.context.view_layer.objects.active=PARTS[0]
        bpy.ops.object.join()
        body=bpy.context.object
        body.name=SPECS[kind]['name']+' / skinned character'
        # Color the editable rig without changing its calibrated rest axes.
        for bone in ARM.data.bones:
            bone.color.palette='THEME04'
        ARM.name=SPECS[kind]['name']+' / office rig'
        ARM.show_in_front=True
        props=[o for o in bpy.data.objects if o.type=='MESH' and o.name.startswith('Office')]
        all_meshes=[body]+props
        for obj in all_meshes:
            world=obj.matrix_world.copy()
            obj.parent=ARM
            obj.matrix_world=world
        assert all(abs(s-original)<1e-6 for s,original in zip(ARM.scale,rig_scale)), 'Preserve donor animation rig scale'
        bpy.context.scene.render.fps=60
        bpy.context.scene.frame_start=0
        bpy.context.scene.frame_end=240
        path=OUT/('avatar_'+kind+'.glb')
        if not args.skip_export:
            HELPERS['export_avatar'](ARM,all_meshes,path)
        scene,camera=studio()
        for obj in props:obj.hide_render=True
        scene.render.filepath=str(OUT/(kind+'-hero.png'))
        bpy.ops.render.render(write_still=True)
        scene.render.resolution_x=scene.render.resolution_y=384
        camera.location=(.50,-3.5,1.49)
        target=Vector((0,-.07,1.41))
        camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
        camera.data.ortho_scale=.66 if kind=='moss' else .57
        scene.render.filepath=str(OUT/('portrait-'+kind+'.png'))
        bpy.ops.render.render(write_still=True)
        for obj in props:obj.hide_render=False
        camera.location=(2.8,-7.3,2.8)
        camera.rotation_euler=(Vector((0,-.04,.86))-camera.location).to_track_quat('-Z','Y').to_euler()
        camera.data.ortho_scale=1.95
        scene.render.resolution_x=scene.render.resolution_y=1000
        bpy.ops.wm.save_as_mainfile(filepath=str(OUT/('avatar_'+kind+'.blend')))
        if not args.skip_export:
            report['avatar_'+kind]={**SPECS[kind], 'source_asset':str(DONOR.relative_to(ROOT)),
                'source_sha256':hashlib.sha256(DONOR.read_bytes()).hexdigest(),
                'output':str(path.relative_to(ROOT)), 'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                'bytes':path.stat().st_size,'bones':len(ARM.data.bones),'vertices':len(body.data.vertices),
                'height_m':donor_report['height_m'],'animation_donor':'avatar_design',
                'clips':donor_report['clips'],'non_loop_clips':donor_report['non_loop_clips'],
                'cup_offset_m':donor_report['cup_offset_m'],
                'authoring':'Original Blender meshes; calibrated articulated hands, shoe contacts and office animation rig retained',
                'head_top_adjustment_m':donor_top-top}
            (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
        print('FINISHED CHARACTER',kind,flush=True)


if __name__=='__main__':
    main()
