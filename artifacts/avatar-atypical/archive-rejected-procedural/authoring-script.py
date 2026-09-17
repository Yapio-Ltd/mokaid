"""Author three original characters on the proven office animation skeleton.

Run with Blender --background --python scripts/blender-atypical-avatars.py --.
All human meshes are newly skinned against the calibrated office skeleton.
Socket transforms and the 48 original actions remain intact and editable.
Exports are staged for independent validation before catalog registration.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
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
    'byte': {'name': 'Hugo', 'style': 'Human architect / navy blazer, ecru henley, tailored chinos, salt-and-pepper beard',
             'colors': ['#25354a', '#e5dcc9', '#66503c']},
    'nyx': {'name': 'Inès', 'style': 'Human creative director / chestnut bob, ecru blouse, brick scarf, charcoal trousers',
            'colors': ['#e2d7c2', '#8e4332', '#363638']},
    'moss': {'name': 'Malik', 'style': 'Human artisan / natural curls, olive overshirt, indigo apron, tobacco chinos',
             'colors': ['#647051', '#284355', '#866248']},
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
    if bone in {'Hips','Spine02','Spine01','Spine'}:
        # Accessories follow the same smooth spine blend as the cloth beneath.
        obj.vertex_groups.clear()
        for vertex in obj.data.vertices:
            chain=['Hips','Spine02','Spine01','Spine']
            nearest=sorted(chain,key=lambda n:abs(head(n).z-vertex.co.z))[:2]
            weights=[1/max(.008,abs(head(n).z-vertex.co.z))**2 for n in nearest]
            for n,w in zip(nearest,weights):
                vg=obj.vertex_groups.get(n) or obj.vertex_groups.new(name=n)
                vg.add([vertex.index],w/sum(weights),'REPLACE')
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
    data.use_fill_caps = True
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


def torso(mat):
    rings = [(.845,.105,.087),(.88,.145,.10),(.93,.154,.103),(.98,.138,.092),
             (1.035,.128,.088),(1.10,.155,.104),(1.17,.174,.108),(1.19,.145,.085),(1.205,.052,.043)]
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


def skin_weights(obj, weights):
    obj.vertex_groups.clear()
    for index, values in enumerate(weights):
        total=sum(values.values())
        for name, weight in values.items():
            if weight<=0:continue
            group=obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)
            group.add([index],weight/total,'REPLACE')


def subdivide(obj, levels=1):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True);bpy.context.view_layer.objects.active=obj
    mod=obj.modifiers.new('Smooth cloth topology','SUBSURF');mod.levels=levels
    bpy.ops.object.modifier_move_up(modifier=mod.name)
    bpy.ops.object.modifier_apply(modifier=mod.name)
    return obj


def tailored_chain(name, a, b, c, bones, radii, mat, exposed=None):
    # One continuous surface across the elbow/knee, with a gradual skin blend.
    a,b,c=Vector(a),Vector(b),Vector(c)
    rings,n=32,24
    vertices,faces,weights=[],[],[]
    for i in range(rings+1):
        t=i/rings
        center=a.lerp(b,2*t) if t<=.5 else b.lerp(c,2*t-1)
        axis=(b-a).normalized() if t<.45 else (c-b).normalized() if t>.55 else (c-a).normalized()
        u=axis.cross(Vector((0,1,0))).normalized();v=axis.cross(u).normalized()
        uidx=min(len(radii)-2,int(t*(len(radii)-1)))
        frac=t*(len(radii)-1)-uidx
        radius=radii[uidx]*(1-frac)+radii[uidx+1]*frac
        blend=max(0,min(1,(t-.40)/.20));blend=blend*blend*(3-2*blend)
        for j in range(n):
            theta=math.tau*j/n
            # Small, broad folds retain a fabric silhouette without joint balls.
            fold=1+.025*math.sin(theta*3+t*30)*math.sin(t*math.pi)
            vertices.append(center+radius*fold*(math.cos(theta)*u+.90*math.sin(theta)*v))
            weights.append({bones[0]:1-blend,bones[1]:blend})
    for i in range(rings):
        for j in range(n):faces.append((i*n+j,i*n+(j+1)%n,(i+1)*n+(j+1)%n,(i+1)*n+j))
    faces.extend([tuple(reversed(range(n))),tuple(rings*n+j for j in range(n))])
    obj=mesh(name,vertices,faces,bones[0],mat)
    skin_weights(obj,weights)
    if exposed:
        obj.data.materials.append(exposed)
        for face in obj.data.polygons:
            if min(face.vertices)//n>24:face.material_index=1
    return subdivide(obj)


def seam(name, points, bone, mat, width=.0013):
    return tube(name,points,width,bone,mat)


def stitch_line(name, a, b, bone, mat, count=16):
    a,b=Vector(a),Vector(b)
    for i in range(count):
        seam(name,[a.lerp(b,(i+.16)/count),a.lerp(b,(i+.68)/count)],bone,mat,.00065)


def garment_panel(name, outline, bone, mat, thickness=.002):
    obj=mesh(name,outline,[tuple(range(len(outline)))],bone,mat)
    bpy.ops.object.select_all(action='DESELECT');obj.select_set(True);bpy.context.view_layer.objects.active=obj
    # A dense cloth patch follows the curved torso and its skin deformation.
    mod=obj.modifiers.new('Tailoring surface grid','SUBSURF');mod.subdivision_type='SIMPLE';mod.levels=3
    bpy.ops.object.modifier_move_up(modifier=mod.name)
    bpy.ops.object.modifier_apply(modifier=mod.name)
    profile=[(.845,.105,.087),(.88,.145,.10),(.93,.154,.103),(.98,.138,.092),
             (1.035,.128,.088),(1.10,.155,.104),(1.17,.174,.108),(1.19,.145,.085),(1.205,.052,.043)]
    for vertex in obj.data.vertices:
        x,y,z=vertex.co
        if profile[0][0]<=z<=profile[-1][0]:
            index=next(i for i in range(len(profile)-1) if profile[i][0]<=z<=profile[i+1][0])
            lo,hi=profile[index],profile[index+1];t=(z-lo[0])/(hi[0]-lo[0])
            rx=lo[1]*(1-t)+hi[1]*t;ry=lo[2]*(1-t)+hi[2]*t
            surface=-.106-ry*math.sqrt(max(0,1-((x-.005)/rx)**2))
            # The scarf lies over the collar, so its surface needs a distinct layer.
            offset=.028 if name.startswith('Scarf') else .011
            vertex.co.y=min(y,surface-offset)
    chain=['Hips','Spine02','Spine01','Spine']
    weights=[]
    for vertex in obj.data.vertices:
        nearest=sorted(chain,key=lambda n:abs(head(n).z-vertex.co.z))[:2]
        weights.append({n:1/max(.008,abs(head(n).z-vertex.co.z))**2 for n in nearest})
    skin_weights(obj,weights)
    mod=obj.modifiers.new('Fabric thickness','SOLIDIFY');mod.thickness=thickness
    bpy.ops.object.modifier_move_up(modifier=mod.name)
    bpy.ops.object.modifier_apply(modifier=mod.name)
    return obj


def button(name, location, bone, p, radius=.006):
    sphere(name,location,(radius,.0025,radius),bone,p['button'],16)
    x,y,z=location
    for dx in [-1,1]:sphere(name+' stitch',(x+dx*radius*.27,y-.0026,z),(.0008,.0008,.0008),bone,p['thread'],12)


def human_hand(side,suffix,p):
    wrist=head(side+'Hand');prox=head('grip_prox.'+suffix);dist=head('grip_dist.'+suffix)
    axis=(dist-prox).normalized();u=Vector((0,0,1)).cross(axis).normalized();v=axis.cross(u).normalized()
    center=wrist.lerp(prox,.52)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=24,ring_count=16,location=center)
    obj=bpy.context.object;obj.name='Anatomical palm '+side
    obj.rotation_euler=Matrix((u,v,axis)).transposed().to_euler()
    obj.scale=(.022,.012,(prox-wrist).length*.60)
    bind(obj,side+'Hand',p['skin'])
    for i,(offset,length) in enumerate([(-.016,.84),(-.0055,1),(.0055,.96),(.016,.76)]):
        base=prox+u*offset-axis*.006
        middle=dist+u*offset-axis*(1-length)*.020
        tip=middle+axis*.025*length
        segment(side+' proximal finger '+str(i),base,middle,[.0057,.0061,.0051],'grip_prox.'+suffix,p['skin'])
        segment(side+' distal finger '+str(i),middle,tip,[.0052,.0050,.0042],'grip_dist.'+suffix,p['skin'])
        sphere(side+' fingertip '+str(i),tip,(.005,)*3,'grip_dist.'+suffix,p['skin'],16)
        nail_center=tip-axis*.006+v*.0043
        bpy.ops.mesh.primitive_uv_sphere_add(segments=16,ring_count=12,location=nail_center)
        obj=bpy.context.object;obj.name=side+' fingernail '+str(i)
        obj.rotation_euler=Matrix((u,v,axis)).transposed().to_euler();obj.scale=(.0035,.0012,.005)
        bind(obj,'grip_dist.'+suffix,p['nails'])
    thumb=head('grip_thumb.'+suffix)
    tip=ARM.matrix_world@ARM.data.bones['grip_thumb.'+suffix].tail_local
    tip=thumb+(tip-thumb).normalized()*.037
    segment(side+' thumb',thumb,tip,[.009,.008,.0055],'grip_thumb.'+suffix,p['skin'])
    sphere(side+' thumb tip',tip,(.006,)*3,'grip_thumb.'+suffix,p['skin'],16)


def shoe_upper(side,contact,p):
    coords=[vertex.co for vertex in contact.data.vertices]
    minx,maxx=min(v.x for v in coords),max(v.x for v in coords)
    miny,maxy=min(v.y for v in coords),max(v.y for v in coords)
    ankle=head(side+'Foot');cx=(minx+maxx)*.5;cy=(miny+maxy)*.5
    rx=(maxx-minx)*.47;ry=(maxy-miny)*.47
    vertices,faces,weights=[],[],[];n=48
    floor=min(v.z for v in coords)
    sections=[(floor,0),(floor+.006,0),(.038,0),(.048,0),(.065,.10),(.092,.35),(.125,.67),(.160,.88),(.195,1)]
    for z,t in sections:
        x=cx*(1-t)+ankle.x*t;y=cy*(1-t)+ankle.y*t
        sx=rx*(1-t)+.036*t;sy=ry*(1-t)+.043*t
        for j in range(n):
            angle=math.tau*j/n
            point=Vector((x+sx*math.cos(angle),y+sy*math.sin(angle),z))
            vertices.append(point)
            toe=max(0,min(.9,(ankle.y-.067-point.y)/.095))
            weights.append({side+'Foot':1-toe,side+'ToeBase':toe})
    for i in range(len(sections)-1):
        for j in range(n):faces.append((i*n+j,i*n+(j+1)%n,(i+1)*n+(j+1)%n,(i+1)*n+j))
    faces.append(tuple(reversed(range(n))))
    obj=mesh(side+' smooth leather shoe',vertices,faces,side+'Foot',p['boots']);skin_weights(obj,weights)
    obj.data.materials.append(p['sole'])
    for face in obj.data.polygons:
        if all(obj.data.vertices[i].co.z<.041 for i in face.vertices):face.material_index=1
    PARTS.remove(contact);bpy.data.objects.remove(contact,do_unlink=True)


def limbs(source, kind, p):
    for side,sign,suffix in [('Left',1,'l'),('Right',-1,'r')]:
        shoulder,elbow,wrist=(head(side+n) for n in ['Arm','ForeArm','Hand'])
        hip,knee,ankle=(head(side+n) for n in ['UpLeg','Leg','Foot'])
        arm_r=[.048,.060,.052,.043,.034] if kind=='nyx' else [.051,.056,.049,.041,.033]
        tailored_chain(side+' continuous sleeve',shoulder,elbow,wrist,
                       [side+'Arm',side+'ForeArm'],arm_r,p['body'],p['skin'] if kind=='moss' else None)
        leg_r=[.078,.078,.063,.060,.048] if kind=='nyx' else [.073,.076,.061,.059,.040]
        tailored_chain(side+' tailored trousers',hip,knee,ankle,
                       [side+'UpLeg',side+'Leg'],leg_r,p['pants'])
        human_hand(side,suffix,p)
        shoes=copy_contact_mesh(source,'Shoe contact sole '+side,{side+'Foot',side+'ToeBase'},p['boots'],max_z=.22)
        # Use the donor shoe envelope to derive a smooth, closed leather shoe.
        neighbors={v.index:set() for v in shoes.data.vertices}
        for edge in shoes.data.edges:
            x,y=edge.vertices;neighbors[x].add(y);neighbors[y].add(x)
        for iteration in range(3):
            coords=[v.co.copy() for v in shoes.data.vertices]
            for vertex in shoes.data.vertices:
                if vertex.co.z>.07 and neighbors[vertex.index]:
                    average=sum((coords[n] for n in neighbors[vertex.index]),Vector())/len(neighbors[vertex.index])
                    vertex.co=coords[vertex.index].lerp(average,.36)
        for face in shoes.data.polygons:
            if all(shoes.data.vertices[i].co.z<.05 for i in face.vertices):
                if len(shoes.data.materials)==1:shoes.data.materials.append(p['sole'])
                face.material_index=1
        shoe_upper(side,shoes,p)
        cuff=wrist if kind!='moss' else elbow.lerp(wrist,.56)
        segment(side+' rolled cuff',cuff.lerp(elbow,.14),cuff,[.041,.043,.041],side+'ForeArm',p['cuff'])
        seam(side+' cuff seam',[cuff+Vector((0,-.040,-.015)),cuff+Vector((.015,-.039,.005))],side+'ForeArm',p['thread'])
        # Flat stitching and a vamp make everyday shoes instead of armor plates.
        foot=head(side+'Foot')
        for i in range(4):
            z=foot.z-.014-i*.014;y=foot.y-.090-i*.011
            tube(side+' cotton laces',[(foot.x-.028,y,z),(foot.x+.028,y,z)],.0017,side+'Foot',p['thread'])
        seam(side+' shoe vamp',[foot+Vector((-.042,-.092,-.051)),foot+Vector((0,-.132,-.07)),
                               foot+Vector((.042,-.092,-.051))],side+'Foot',p['thread'],.0015)
        if kind!='nyx':
            # A pressed trouser crease follows each leg segment independently.
            seam(side+' upper trouser crease',[hip+Vector((0,-.067,-.015)),hip.lerp(knee,.65)+Vector((0,-.071,0)),
                 knee+Vector((0,-.055,.02))],side+'UpLeg',p['pants_detail'])
            seam(side+' lower trouser crease',[knee+Vector((0,-.055,-.018)),knee.lerp(ankle,.55)+Vector((0,-.054,0)),
                 ankle+Vector((0,-.035,.035))],side+'Leg',p['pants_detail'])


def face_profile(kind):
    jaw=.079 if kind=='byte' else .067 if kind=='nyx' else .083
    return [(1.277,.027,.038),(1.289,.054,.062),(1.313,jaw,.078),
            (1.348,.100,.088),(1.385,.110,.095),(1.420,.106,.093),
            (1.458,.104,.096),(1.492,.105,.094),(1.530,.093,.080),
            (1.559,.064,.056),(1.580,.005,.006)]


def face_surface(kind, z, angle):
    rings=face_profile(kind)
    i=next((i for i in range(len(rings)-1) if rings[i][0]<=z<=rings[i+1][0]),len(rings)-2)
    lo,hi=rings[i],rings[i+1];t=max(0,min(1,(z-lo[0])/(hi[0]-lo[0])))
    rx=lo[1]*(1-t)+hi[1]*t;ry=lo[2]*(1-t)+hi[2]*t
    return Vector((rx*math.cos(angle),-.078+ry*math.sin(angle),z))


def human_face(p,kind):
    vertices,faces=[],[];n=64
    profile=face_profile(kind)
    for z,_,_ in profile:
        vertices.extend(face_surface(kind,z,math.tau*j/n) for j in range(n))
    for i in range(len(profile)-1):
        for j in range(n):faces.append((i*n+j,i*n+(j+1)%n,(i+1)*n+(j+1)%n,(i+1)*n+j))
    faces.extend([tuple(reversed(range(n))),tuple((len(profile)-1)*n+j for j in range(n))])
    obj=mesh('Anatomical face / cheeks jaw and chin',vertices,faces,'Head',p['skin'])
    subdivide(obj,2)
    for sign in [-1,1]:
        x=sign*.044;z=1.429;y=-.172
        # Almond-shaped sclera, seated within sculpted lids; adult eye scale.
        verts=[(x,y-.006,z)];segments=32
        for j in range(segments):
            angle=math.tau*j/segments
            verts.append((x+.024*math.cos(angle),y+.005*abs(math.cos(angle)),
                          z+(.012 if math.sin(angle)>0 else .009)*math.sin(angle)))
        eye_faces=[(0,j+1,(j+1)%segments+1) for j in range(segments)]
        mesh('Almond eye',verts,eye_faces,'Head',p['white'])
        sphere('Natural iris',(x,-.180,z),(.0088,.003,.010),'Head',p['iris'],24)
        sphere('Round pupil',(x,-.183,z),(.004,.0015,.005),'Head',p['dark'],20)
        sphere('Eye reflection',(x-.0023,-.185, z+.0031),(.0018,.0008,.0018),'Head',p['white'],12)
        tube('Upper eyelid',[(x-.024,-.166,z),(x,-.174,z+.013),(x+.024,-.166,z)],.0032,'Head',p['skin_detail'])
        tube('Lower eyelid',[(x-.024,-.166,z),(x,-.173,z-.010),(x+.024,-.166,z)],.0024,'Head',p['skin'])
        tube('Lash line',[(x-.022,-.169,z+.002),(x,-.178,z+.012),(x+.022,-.169,z+.001)],.0012,'Head',p['hair'])
        tube('Brow volume',[(x-sign*.024,-.173,1.459),(x,-.180,1.468),
                            (x+sign*.026,-.161,1.458)],.0040,'Head',p['hair'])
        for i in range(11):
            bx=x-.021+i*.004
            bz=1.461+.006*math.sin(math.pi*i/10)
            seam('Eyebrow hair',[(bx,-.179,bz),(bx+.002,-.180,bz+.004)],'Head',p['hair_detail'],.0007)
        sphere('Ear helix',(sign*.110,-.070,1.398),(.018,.022,.036),'Head',p['skin'],24)
        sphere('Ear concha',(sign*.122,-.083,1.398),(.009,.009,.022),'Head',p['skin_detail'],20)
        tube('Inner ear fold',[(sign*.125,-.087,1.417),(sign*.127,-.090,1.401),
                                (sign*.123,-.089,1.387)],.003,'Head',p['skin'])
        if kind=='nyx':
            points=[(sign*.119+.009*math.cos(math.tau*i/24),-.082,1.360+.014*math.sin(math.tau*i/24)) for i in range(25)]
            tube('Small gold hoop earring',points,.0018,'Head',p['button'])
        if kind=='byte':
            seam('Under eye crease',[(x-.020,-.164,1.412),(x,-.170,1.406),(x+.017,-.163,1.410)],'Head',p['skin_detail'],.0009)
        if kind=='nyx':
            for dx,dz in [(-.004,0),(.009,-.003),(.019,.004)]:
                sphere('Subtle natural freckle',(x+dx,-.166,1.397+dz),(.0012,.0008,.0012),'Head',p['freckle'],12)
    # A shaped bridge, tip, alae and nostrils give the face an actual nose.
    sphere('Nose bridge',(0,-.178,1.414),(.013,.016,.038),'Head',p['skin'],32)
    sphere('Nose tip',(0,-.198,1.389),(.018,.020,.014),'Head',p['skin'],32)
    for sign in [-1,1]:
        sphere('Nose ala',(sign*.015,-.187,1.386),(.008,.011,.009),'Head',p['skin'],20)
        sphere('Nostril',(sign*.011,-.198,1.382),(.0043,.0025,.0026),'Head',p['nostril'],16)
    tube('Philtrum',[(-.004,-.169,1.379),(0,-.173,1.368),(.004,-.169,1.379)],.0013,'Head',p['skin_detail'])
    tube('Upper lip cupid bow',[(-.026,-.163,1.352),(-.009,-.172,1.357),(0,-.173,1.354),
                                (.009,-.172,1.357),(.026,-.163,1.352)],.0028,'Head',p['lip'])
    tube('Mouth line',[(-.026,-.164,1.350),(0,-.176,1.349),(.026,-.164,1.350)],.0011,'Head',p['nostril'])
    tube('Lower lip',[(-.021,-.167,1.347),(0,-.173,1.343),(.021,-.167,1.347)],.003,'Head',p['lip'])


def hair_shell(kind,p,bob=False):
    n,rings=72,20;vertices,faces=[],[]
    for i in range(rings+1):
        t=i/rings
        for j in range(n):
            phi=math.tau*j/n
            front=max(0,-math.sin(phi))
            end=1.60-front*.42 if bob else 1.78-front*.61
            theta=.02+(end-.02)*t
            x=.123*math.sin(theta)*math.cos(phi)
            y=-.074+.116*math.sin(theta)*math.sin(phi)
            z=1.435+.171*math.cos(theta)
            if bob and t>.62:
                z-=.135*((t-.62)/.38)*(1-front**4)
            vertices.append((x,y,z))
    for i in range(rings):
        for j in range(n):faces.append((i*n+j,i*n+(j+1)%n,(i+1)*n+(j+1)%n,(i+1)*n+j))
    return mesh('Natural hair silhouette',vertices,faces,'Head',p['hair'])


def glasses(p,round_frame=False):
    for sign in [-1,1]:
        cx=sign*.046;points=[]
        for i in range(49):
            t=math.tau*i/48
            x=math.cos(t);z=math.sin(t)
            if not round_frame:
                x=math.copysign(abs(x)**.55,x);z=math.copysign(abs(z)**.55,z)
            points.append((cx+.031*x,-.189+.010*abs(x),1.430+.023*z))
        tube('Optical frame',points,.0022,'Head',p['glasses'])
        tube('Glasses temple',[(sign*.078,-.180,1.439),(sign*.109,-.151,1.435),
                               (sign*.120,-.074,1.409)],.002,'Head',p['glasses'])
        sphere('Glasses hinge',(sign*.079,-.18,1.437),(.003,.003,.003),'Head',p['button'],12)
    tube('Nose bridge of glasses',[(-.014,-.192,1.433),(0,-.196,1.439),(.014,-.192,1.433)],.002,'Head',p['glasses'])


def short_beard(p, kind):
    vertices,faces=[],[];n=64;rings=16
    for i in range(rings+1):
        t=i/rings
        for j in range(n+1):
            angle=math.pi+math.pi*j/n
            edge=abs(math.cos(angle))
            top=1.330+.074*edge**1.5
            z=1.291+(top-1.291)*t
            point=face_surface(kind,z,angle)
            point.x*=1.006;point.y-=.0025
            vertices.append(point)
    for i in range(rings):
        for j in range(n):faces.append((i*(n+1)+j,i*(n+1)+j+1,(i+1)*(n+1)+j+1,(i+1)*(n+1)+j))
    mesh('Close cut beard base',vertices,faces,'Head',p['beard'])
    rng=random.Random(715)
    for i in range(200):
        angle=rng.uniform(math.pi,math.tau);edge=abs(math.cos(angle))
        z=rng.uniform(1.296,1.327+.07*edge**1.5)
        point=face_surface(kind,z,angle);point.y-=.004
        seam('Fine beard texture',[point,point+Vector((0,-.0005,-.0018))],'Head',
             p['hair_detail'] if kind=='byte' and i%3==0 else p['hair'],.00045)
    for sign in [-1,1]:
        tube('Trimmed moustache',[(sign*.004,-.177,1.371),(sign*.016,-.179,1.369),
                                  (sign*.027,-.167,1.361)],.0028,'Head',p['beard'])


def byte(p):
    human_face(p,'byte');hair_shell('byte',p);glasses(p);short_beard(p,'byte')
    # A side part and fine swept locks replace the monitor housing completely.
    for i in range(33):
        phi=math.pi+.04+i*(math.pi-.08)/32
        points=[]
        for j in range(8):
            t=j/7;theta=.12+.95*t
            angle=phi+.28*(1-t)
            points.append((.125*math.sin(theta)*math.cos(angle),
                           -.074+.118*math.sin(theta)*math.sin(angle),
                           1.435+.173*math.cos(theta)))
        seam('Combed fine hair',points,'Head',p['hair_detail'] if i%5==0 else p['hair'],.0015)
    garment_panel('Ecru henley front',[(-.052,-.232,.956),(.052,-.232,.956),(.055,-.235,1.16),
                                     (.030,-.150,1.203),(-.030,-.150,1.203),(-.055,-.235,1.16)],'Spine01',p['shirt'])
    for sign in [-1,1]:
        outline=[(sign*.031,-.177,1.195),(sign*.112,-.215,1.163),(sign*.085,-.241,1.087),
                 (sign*.045,-.246,1.03),(sign*.026,-.241,1.12)]
        garment_panel('Soft blazer lapel',outline,'Spine',p['body_detail'])
        seam('Lapel edge',[Vector(c)+Vector((0,-.002,0)) for c in outline[:4]],'Spine',p['thread'])
        box('Welt pocket',(sign*.105,-.195,1.008),(.061,.008,.011),'Spine02',p['body_detail'],.002)
        stitch_line('Pocket stitching',(sign*.08,-.201,1.00),(sign*.132,-.201,1.00),'Spine02',p['thread'],8)
    for z in [1.177,1.158,1.139]:button('Henley button',(0,-.239,z),'Spine',p,.0033)
    button('Blazer horn button',(.042,-.220,1.011),'Spine02',p,.006)
    box('Chest pocket',(-.093,-.211,1.113),(.045,.006,.008),'Spine',p['body_detail'],.001)
    garment_panel('Folded pocket square',[(-.108,-.215,1.113),(-.074,-.215,1.113),
                                          (-.079,-.213,1.125),(-.106,-.213,1.122)],'Spine',p['shirt'])
    waist(p)
    watch(p,'Left')


def nyx(p):
    human_face(p,'nyx');hair_shell('nyx',p,True)
    # Tucked chestnut bob, with a continuous cap and rounded cut ends.
    for i in range(42):
        phi=math.tau*i/42;front=max(0,-math.sin(phi))
        if front>.80:continue
        points=[]
        for t in [0,.25,.55,.8,1]:
            theta=.22+1.27*t
            points.append((.126*math.sin(theta)*math.cos(phi),
                           -.074+.119*math.sin(theta)*math.sin(phi),
                           1.435+.174*math.cos(theta)-.135*t**3*(1-front**4)))
        tube('Bob shaped lock',points,.006,'Head',p['hair'])
        seam('Chestnut strand',[(x,y-.001,z+.001) for x,y,z in points],'Head',p['hair_detail'],.0009)
    for i in range(13):
        x=-.09+i*.013
        tube('Side swept fringe',[(.032+x*.42,-.03,1.594),(x+.015,-.125,1.570),
             (x,-.175,1.498+.036*(i/12))],.0048,'Head',p['hair'])
    for z in [.974,1.010,1.047,1.084,1.120]:
        button('Mother of pearl shirt button',(0,-.215,z),'Spine01' if z>1.04 else 'Spine02',p,.0039)
    seam('Shirt placket',[(-.012,-.217,.948),(-.012,-.217,1.157)],'Spine01',p['thread'])
    for sign in [-1,1]:
        garment_panel('Open shirt collar',[(sign*.035,-.151,1.204),(sign*.083,-.204,1.165),
                     (sign*.054,-.222,1.111),(sign*.006,-.203,1.174)],'Spine',p['shirt'])
    tube('Woven neck scarf',[(-.047,-.111,1.220),(-.015,-.155,1.208),(.035,-.149,1.215),(.050,-.111,1.222)],.012,'neck',p['accent'])
    garment_panel('Scarf folded tail',[(.020,-.173,1.211),(.046,-.176,1.208),(.087,-.212,1.133),
                                       (.059,-.221,1.143)],'Spine',p['accent'])
    for i in range(3):
        seam('Scarf woven stripe',[(.030+i*.005,-.178,1.202),(.066+i*.004,-.220,1.151)],'Spine',p['thread'],.0012)
    waist(p);watch(p,'Right')
    for sign in [-1,1]:
        seam('Trouser front pleat',[(sign*.072,-.218,.891),(sign*.082,-.195,.848)],'Hips',p['pants_detail'],.0015)


def moss(p):
    human_face(p,'moss');hair_shell('moss',p);glasses(p,True);short_beard(p,'moss')
    rng=random.Random(3301)
    for i in range(340):
        theta=rng.uniform(.07,1.45);phi=rng.uniform(0,math.tau)
        if math.sin(phi)<-.6:theta=min(theta,1.0)
        point=Vector((.125*math.sin(theta)*math.cos(phi),-.071+.117*math.sin(theta)*math.sin(phi),
                      1.435+.174*math.cos(theta)))
        r=rng.uniform(.013,.019)
        sphere('Natural tight curl',point,(r,r*.84,r*.80),'Head',p['hair'],16)
        if i%3==0:
            tube('Curl highlight',[point+Vector((-.005,-.006,.007)),point+Vector((.001,-.010,.009)),
                                   point+Vector((.007,-.004,.005))],.0014,'Head',p['hair_detail'])
    for sign in [-1,1]:
        garment_panel('Overshirt collar',[(sign*.032,-.138,1.204),(sign*.092,-.195,1.158),
                   (sign*.052,-.224,1.108),(sign*.010,-.204,1.161)],'Spine',p['body_detail'])
        garment_panel('Chest patch pocket',[(sign*.076,-.211,1.072),(sign*.135,-.194,1.078),
                     (sign*.132,-.192,1.128),(sign*.073,-.211,1.123)],'Spine',p['body_detail'])
        button('Pocket horn button',(sign*.104,-.208,1.117),'Spine',p,.004)
    garment_panel('Indigo apron bib',[(-.070,-.227,.970),(.070,-.227,.970),(.064,-.230,1.137),
                                     (-.064,-.230,1.137)],'Spine01',p['denim'])
    garment_panel('Indigo apron waist panel',[(-.143,-.215,.842),(.143,-.215,.842),(.144,-.223,.961),
                                            (-.144,-.223,.961)],'Hips',p['denim'])
    for sign in [-1,1]:
        tube('Leather apron strap',[(sign*.059,-.235,1.126),(sign*.077,-.207,1.169),
                                    (sign*.067,-.087,1.211)],.008,'Spine',p['accent'])
        button('Apron rivet',(sign*.057,-.234,1.125),'Spine01',p,.004)
        stitch_line('Bib top stitching',(sign*.064,-.234,.978),(sign*.061,-.236,1.117),'Spine01',p['thread'],23)
        box('Apron waist pocket',(sign*.074,-.228,.90),(.104,.009,.064),'Hips',p['denim_detail'],.003)
        stitch_line('Apron pocket top',(sign*.028,-.235,.93),(sign*.12,-.235,.93),'Hips',p['thread'],14)
    box('Pencil pocket',(-.032,-.237,1.070),(.026,.006,.075),'Spine01',p['denim_detail'],.002)
    segment('Carpenter pencil',(-.032,-.243,1.072),(-.032,-.243,1.125),[.0026,.0026],'Spine01',p['pencil'])
    sphere('Pencil graphite',(-.032,-.243,1.128),(.0013,.0013,.004),'Spine01',p['dark'],12)
    waist(p)


def waist(p):
    # Belt, buckle and loops are normal garment construction details.
    segment('Trouser waistband',(.005,-.106,.896),(.005,-.106,.926),[.132,.134,.132],'Hips',p['pants'])
    box('Leather belt front',(0,-.217,.921),(.252,.010,.020),'Hips',p['accent'],.003)
    box('Belt buckle',(0,-.225,.921),(.026,.006,.022),'Hips',p['button'],.003)
    box('Buckle interior',(0,-.230,.921),(.016,.002,.013),'Hips',p['accent'],.002)
    for x in [-.105,-.058,.058,.105]:box('Belt loop',(x,-.226,.923),(.008,.005,.029),'Hips',p['pants'],.002)


def watch(p,side):
    wrist=head(side+'ForeArm').lerp(head(side+'Hand'),.82)
    sphere('Leather watch strap',wrist,(.020,.044,.043),side+'ForeArm',p['accent'])
    sphere('Watch steel case',wrist+Vector((0,-.044,0)),(.014,.006,.017),side+'ForeArm',p['button'])
    sphere('Watch face',wrist+Vector((0,-.050,0)),(.011,.002,.014),side+'ForeArm',p['shirt'])
    seam('Watch hands',[wrist+Vector((.006,-.053,.005)),wrist+Vector((0,-.053,0)),
                        wrist+Vector((-.004,-.053,.008))],side+'ForeArm',p['dark'],.0008)


def palettes(kind):
    colors={
        'byte':dict(skin=(.55,.32,.22),skin_detail=(.40,.20,.14),body=(.029,.046,.075),body_detail=(.047,.064,.095),
            pants=(.25,.21,.17),pants_detail=(.20,.16,.12),accent=(.115,.058,.030),hair=(.050,.042,.037),hair_detail=(.13,.12,.11),
            iris=(.105,.145,.105),lip=(.26,.105,.078),boots=(.077,.041,.024),glasses=(.022,.025,.028)),
        'nyx':dict(skin=(.43,.235,.145),skin_detail=(.31,.139,.082),body=(.72,.65,.52),body_detail=(.63,.55,.44),
            pants=(.055,.055,.060),pants_detail=(.092,.090,.092),accent=(.28,.065,.034),hair=(.040,.022,.014),hair_detail=(.105,.054,.027),
            iris=(.095,.048,.017),lip=(.27,.058,.049),boots=(.047,.025,.015),glasses=(.032,.017,.010)),
        'moss':dict(skin=(.20,.082,.040),skin_detail=(.135,.039,.022),body=(.14,.18,.10),body_detail=(.19,.23,.13),
            pants=(.27,.18,.10),pants_detail=(.22,.135,.073),accent=(.18,.074,.024),hair=(.011,.008,.007),hair_detail=(.043,.027,.017),
            iris=(.065,.030,.012),lip=(.115,.030,.023),boots=(.085,.037,.018),glasses=(.060,.038,.020)),
    }[kind]
    colors.update(white=(.72,.73,.68),dark=(.004,.005,.007),shirt=(.76,.70,.59),
                  sole=(.040,.037,.032),thread=(.43,.36,.24),button=(.32,.255,.15),
                  denim=(.030,.070,.105),denim_detail=(.043,.092,.13),pencil=(.46,.19,.018),
                  nostril=(.050,.018,.012),freckle=(.17,.060,.025))
    colors['beard']=(.082,.075,.068) if kind=='byte' else colors['hair']
    colors['nails']=tuple(min(1,v*1.12+.03) for v in colors['skin'])
    colors['cuff']=colors['body_detail'] if kind=='moss' else colors['shirt']
    return {key:material(kind+' / '+key,color,.79 if key in {'body','pants','denim'} else .68) for key,color in colors.items()}


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
    camera.location=(1.8,-7.3,2.5)
    camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
    camera_data.type='ORTHO'
    camera_data.ortho_scale=1.95
    scene.camera=camera
    for name,location,energy,size,color in [
        ('Large warm key',(-3,-4,5),350,4,(1,.86,.71)),
        ('Cool fill',(3,-2,3),190,3,(.64,.80,1)),
        ('Soft rim',(1,3,4),450,3,(.73,.73,1))]:
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
        torso(p['body'])
        cloth=PARTS[-1];cloth.data.materials.append(p['pants'])
        for face in cloth.data.polygons:
            if all(cloth.data.vertices[i].co.z<.932 for i in face.vertices):face.material_index=1
        limbs(source,kind,p)
        segment('Neck',head('neck'),head('Head')+Vector((0,0,.023)),[.039,.036,.037],'neck',p['skin'])
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
        # Keep the chin connected to the neck while matching the calibrated height.
        # Scaling above the jaw avoids lifting the whole head off its socket.
        pivot=head('Head').z
        head_top=max(v.co.z for obj in PARTS if obj.vertex_groups.get('Head') for v in obj.data.vertices)
        for obj in PARTS:
            group=obj.vertex_groups.get('Head')
            if group:
                for v in obj.data.vertices:
                    if any(g.group==group.index and g.weight>.999 for g in v.groups):
                        fraction=max(0,(v.co.z-pivot)/(head_top-pivot))
                        v.co+=delta*fraction
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
        camera.location=(.30,-3.5,1.48)
        target=Vector((0,-.07,1.41))
        camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
        camera.data.ortho_scale=.50
        scene.render.filepath=str(OUT/('portrait-'+kind+'.png'))
        bpy.ops.render.render(write_still=True)
        for obj in props:obj.hide_render=False
        camera.location=(1.8,-7.3,2.5)
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
                'authoring':'Original human faces, natural hair, tailored clothing, articulated hands, shoes and accessories; donor skeleton, interaction sockets and 48 office actions retained',
                'head_top_adjustment_m':donor_top-top}
            (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
        print('FINISHED CHARACTER',kind,flush=True)


if __name__=='__main__':
    main()
