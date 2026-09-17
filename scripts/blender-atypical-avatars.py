"""Create wardrobe variants of existing Mokaid humans, preserving their anatomy.

Run in Blender: --background --python scripts/blender-atypical-avatars.py.
Only a garment atlas is changed. The complete original GLB BIN chunk is kept
byte-for-byte, with a lossless PNG appended. Meshes, skins, rest poses, sockets,
transforms, UVs and the 48 animations are never regenerated or requantized.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import json
import re
import struct
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/avatar-atypical'
CATALOG = (ROOT / 'apps/api/lib/mokaid/assets_3d.ex').read_text()
SPECS = {
    'byte': {'name': 'Hugo', 'donor_slug': 'avatar_corporate',
             'style': 'Human / petrol-blue rolled-sleeve shirt, charcoal tailored trousers, wristwatch',
             'colors': ['#506e7a', '#252729', '#44372e']},
    'nyx': {'name': 'Inès', 'donor_slug': 'avatar_finance',
            'style': 'Human / terracotta blazer, ivory blouse, charcoal trousers, glasses and natural bun',
            'colors': ['#965645', '#e8e2d6', '#45474b']},
    'moss': {'name': 'Malik', 'donor_slug': 'avatar_developer',
             'style': 'Human / forest-green hoodie, dark indigo denim, sneakers, beard and glasses',
             'colors': ['#405f47', '#293b52', '#e6e2da']},
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_glb(path):
    data=path.read_bytes()
    assert data[:4]==b'glTF' and struct.unpack_from('<II',data,4)==(2,len(data))
    offset=12;document=None;binary=None
    while offset<len(data):
        size,kind=struct.unpack_from('<I4s',data,offset);offset+=8
        payload=data[offset:offset+size];offset+=size
        if kind==b'JSON':document=json.loads(payload)
        elif kind==b'BIN\0':binary=payload
    assert document is not None and binary is not None
    return document,binary


def write_glb(path,document,binary):
    payload=json.dumps(document,separators=(',',':'),ensure_ascii=False).encode()
    payload+=b' '*(-len(payload)%4)
    binary+=b'\0'*(-len(binary)%4)
    path.write_bytes(struct.pack('<4sII',b'glTF',2,28+len(payload)+len(binary))+
                     struct.pack('<I4s',len(payload),b'JSON')+payload+
                     struct.pack('<I4s',len(binary),b'BIN\0')+binary)


def donor_path(slug):
    match=re.search(r'"slug" => "'+slug+r'".*?"cdn_path" => "([^"]+)"',CATALOG,re.S)
    assert match,slug
    return ROOT/'apps/web/public'/match.group(1).lstrip('/')


def load_character(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps=60
    bpy.ops.import_scene.gltf(filepath=str(path))
    arm=next(o for o in bpy.data.objects if o.type=='ARMATURE')
    arm.animation_data.action=bpy.data.actions['idle']
    bpy.context.scene.frame_set(0);bpy.context.view_layer.update()
    body=[o for o in bpy.data.objects if o.type=='MESH' and o.vertex_groups and not o.name.startswith('Office')]
    for obj in bpy.data.objects:
        if obj.type=='MESH' and (not obj.vertex_groups or obj.name.startswith('Office')):
            obj.hide_render=True
            if not obj.vertex_groups:obj.hide_set(True)
    return arm,body


def atlas_height_field(body,width,height):
    """Rasterize existing UV triangles to local body height; no mesh modifications."""
    field=np.full((height,width),np.nan,dtype=np.float32)
    body.data.calc_loop_triangles()
    uv=body.data.uv_layers.active.data
    coords=np.asarray([list(body.matrix_world@v.co) for v in body.data.vertices])
    low,high=float(coords[:,2].min()),float(coords[:,2].max())
    for triangle in body.data.loop_triangles:
        points=np.array([list(uv[i].uv) for i in triangle.loops])*[width,height]-.5
        xmin=max(0,int(np.ceil(points[:,0].min())));xmax=min(width-1,int(np.floor(points[:,0].max())))
        ymin=max(0,int(np.ceil(points[:,1].min())));ymax=min(height-1,int(np.floor(points[:,1].max())))
        if xmin>xmax or ymin>ymax:continue
        a,b,c=points;denom=(b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
        if abs(denom)<1e-8:continue
        yy,xx=np.mgrid[ymin:ymax+1,xmin:xmax+1]
        w0=((b[1]-c[1])*(xx-c[0])+(c[0]-b[0])*(yy-c[1]))/denom
        w1=((c[1]-a[1])*(xx-c[0])+(a[0]-c[0])*(yy-c[1]))/denom
        w2=1-w0-w1;inside=(w0>=-1e-5)&(w1>=-1e-5)&(w2>=-1e-5)
        z=coords[list(triangle.vertices),2]
        values=(w0*z[0]+w1*z[1]+w2*z[2]-low)/(high-low)
        view=field[ymin:ymax+1,xmin:xmax+1];view[inside]=values[inside]
    # Cover the original atlas padding, avoiding filtering seams at UV borders.
    for _ in range(4):
        old=field.copy();valid=np.isfinite(old);total=np.zeros_like(field);count=np.zeros_like(field)
        for dy,dx in [(0,1),(0,-1),(1,0),(-1,0)]:
            sample=np.roll(old,(dy,dx),(0,1));mask=np.roll(valid,(dy,dx),(0,1))
            total+=np.where(mask,sample,0);count+=mask
        fill=~valid&(count>0);field[fill]=total[fill]/count[fill]
    return field


def recolor_atlas(kind,body,output):
    shader=body.data.materials[0]
    node=next(n for n in shader.node_tree.nodes if n.type=='TEX_IMAGE' and n.image)
    original=node.image;w,h=original.size
    pixels=np.array(original.pixels[:],dtype=np.float32).reshape(h,w,4)
    result=pixels.copy();rgb=pixels[:,:,:3]
    r,g,b=rgb[:,:,0],rgb[:,:,1],rgb[:,:,2]
    value=np.max(rgb,axis=2);saturation=(value-np.min(rgb,axis=2))/np.maximum(value,1e-6)
    height=atlas_height_field(body,w,h)
    known=np.isfinite(height)
    luminance=rgb@np.array([.2126,.7152,.0722],dtype=np.float32)
    edits=[]
    def tint(name,mask,target):
        mask=mask&known
        assert int(mask.sum())>500,(kind,name,'empty garment mask')
        median=float(np.median(luminance[mask]))
        shade=np.clip(luminance/median,.12,1.8)
        colors=np.clip(shade[:,:,None]*np.array(target,dtype=np.float32),0,1)
        result[:,:,:3][mask]=colors[mask]
        edits.append({'garment':name,'pixels':int(mask.sum()),'target_rgb':list(target),
                      'original_median_luminance':median})
    if kind=='byte':
        tint('rolled-sleeve shirt',(.49<height)&(height<.835)&(saturation<.23)&(value>.34),(.31,.44,.49))
    elif kind=='nyx':
        blue=(b>r*1.7)&(b>g*1.20)&(b>.09)&(height<.82)
        tint('blazer and matching heels',blue,(.57,.31,.24))
        tan=(r>g*1.08)&(g>b*1.06)&(value>.28)&(.085<height)&(height<.58)
        tint('tailored trousers',tan,(.245,.255,.275))
    else:
        hoodie=(b>r*.80)&(g<r*1.65)&(value<.42)&(value>.004)&(.44<height)&(height<.845)
        tint('cotton hoodie',hoodie,(.22,.34,.25))
        denim=(b>r*1.45)&(g>r*1.30)&(value>.13)&(.055<height)&(height<.60)
        tint('indigo denim',denim,(.145,.225,.32))
    # Head/face texture pixels are protected, including hair, eyes and glasses.
    protected=known&(height>=.845)
    assert np.array_equal(result[protected],pixels[protected]),'Head texture changed'
    image=bpy.data.images.new(SPECS[kind]['name']+' / wardrobe atlas',width=w,height=h,alpha=True)
    image.colorspace_settings.name=original.colorspace_settings.name
    image.pixels.foreach_set(result.ravel())
    image.filepath_raw=str(output);image.file_format='PNG';image.save()
    return {'texture_dimensions':[w,h],'garment_edits':edits,
            'face_and_hair_pixels_preserved':True,'texture_sha256':sha(output.read_bytes())}


def make_variant(source,texture,destination):
    original,binary=read_glb(source);document=copy.deepcopy(original)
    image_bytes=texture.read_bytes();offset=len(binary)
    assert offset%4==0
    texture_index=document['materials'][0]['pbrMetallicRoughness']['baseColorTexture']['index']
    tex=document['textures'][texture_index]
    image_index=tex.get('source',tex.get('extensions',{}).get('EXT_texture_webp',{}).get('source'))
    assert image_index is not None
    view_index=len(document['bufferViews'])
    document['bufferViews'].append({'buffer':0,'byteOffset':offset,'byteLength':len(image_bytes)})
    document['images'][image_index]={'name':texture.stem,'mimeType':'image/png','bufferView':view_index}
    tex['source']=image_index
    tex.pop('extensions',None)
    for key in ['extensionsUsed','extensionsRequired']:
        document[key]=[name for name in document.get(key,[]) if name!='EXT_texture_webp']
    appended=binary+image_bytes;appended+=b'\0'*(-len(appended)%4)
    document['buffers'][0]['byteLength']=len(appended)
    # Structural invariants complement the byte-exact preservation proof.
    for key in ['meshes','nodes','skins','accessors','animations','scenes']:
        assert document[key]==original[key],key
    assert document['bufferViews'][:-1]==original['bufferViews']
    write_glb(destination,document,appended)
    delivered,delivered_bin=read_glb(destination)
    assert delivered_bin[:len(binary)]==binary
    return sha(binary)


def measured_points(objects,head_only=False):
    points=[];dg=bpy.context.evaluated_depsgraph_get()
    for obj in objects:
        head_groups={g.index for g in obj.vertex_groups if g.name in {'Head','head.x'}}
        evaluated=obj.evaluated_get(dg);mesh=evaluated.to_mesh()
        for vertex in mesh.vertices:
            if head_only and sum(g.weight for g in vertex.groups if g.group in head_groups)<.65:continue
            points.append(list(evaluated.matrix_world@vertex.co))
        evaluated.to_mesh_clear()
    return np.asarray(points)


def studio(body):
    points=measured_points(body);lower,upper=points.min(0),points.max(0);height=float(upper[2]-lower[2])
    scene=bpy.context.scene;scene.render.engine='BLENDER_EEVEE';scene.view_settings.view_transform='AgX'
    scene.render.resolution_x=scene.render.resolution_y=1200;scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA';scene.render.film_transparent=True
    scene.world=bpy.data.worlds.new('Neutral character studio');scene.world.use_nodes=True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(.15,.15,.15,1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.35
    target=Vector((float((lower[0]+upper[0])/2),float((lower[1]+upper[1])/2),float(lower[2]+height*.5)))
    camera_data=bpy.data.cameras.new('Character camera');camera=bpy.data.objects.new('Character camera',camera_data)
    scene.collection.objects.link(camera);scene.camera=camera;camera_data.type='ORTHO'
    camera.location=target+Vector((.35,-4.2,.45))*height
    camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler();camera_data.ortho_scale=height*1.15
    for name,position,power,size in [('Key',(-2,-3,3),260,3),('Fill',(2,-2,1.5),140,3),('Rim',(0,2,2.5),240,2)]:
        data=bpy.data.lights.new(name,'AREA');data.energy=power*height**2;data.size=size*height
        light=bpy.data.objects.new(name,data);scene.collection.objects.link(light);light.location=target+Vector(position)*height
        light.rotation_euler=(target-light.location).to_track_quat('-Z','Y').to_euler()
    return scene,camera,lower,upper


def save_source_and_portraits(kind,output):
    arm,body=load_character(output)
    scene,camera,lower,upper=studio(body)
    scene.render.filepath=str(OUT/(kind+'-hero.png'));bpy.ops.render.render(write_still=True)
    hero_location=camera.location.copy();hero_rotation=camera.rotation_euler.copy();hero_scale=camera.data.ortho_scale
    heads=measured_points(body,True);lo,hi=heads.min(0),heads.max(0)
    head_height=float(hi[2]-lo[2]);target=Vector((float((lo[0]+hi[0])/2),float((lo[1]+hi[1])/2),float(lo[2]+head_height*.48)))
    camera.location=target+Vector((.45,-3.5,.10))*(head_height/.4)
    camera.rotation_euler=(target-camera.location).to_track_quat('-Z','Y').to_euler()
    camera.data.ortho_scale=max(head_height*1.40,float(hi[0]-lo[0])*1.42)
    scene.render.resolution_x=scene.render.resolution_y=384
    scene.render.filepath=str(OUT/('portrait-'+kind+'.png'));bpy.ops.render.render(write_still=True)
    camera.location=hero_location;camera.rotation_euler=hero_rotation;camera.data.ortho_scale=hero_scale
    scene.render.resolution_x=scene.render.resolution_y=1200
    bpy.ops.file.pack_all()
    bpy.ops.wm.save_as_mainfile(filepath=str(OUT/('avatar_'+kind+'.blend')))
    return len(arm.data.bones),sum(len(o.data.vertices) for o in body),[lower.tolist(),upper.tolist()]


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--only',nargs='+',choices=list(SPECS))
    args=parser.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    OUT.mkdir(exist_ok=True,parents=True)
    report=json.loads((OUT/'report.json').read_text()) if (OUT/'report.json').exists() else {}
    originals=json.loads((ROOT/'artifacts/avatar-life/report.json').read_text())
    for kind in args.only or SPECS:
        spec=SPECS[kind];source=donor_path(spec['donor_slug']);donor=originals[spec['donor_slug']]
        assert sha(source.read_bytes())==donor['sha256'],'Source report does not match shipped GLB'
        print('PRESERVE SOURCE ANATOMY',kind,spec['donor_slug'],flush=True)
        arm,body=load_character(source);assert len(body)==1 and body[0].name=='char1'
        texture=OUT/(kind+'-wardrobe.png')
        appearance=recolor_atlas(kind,body[0],texture)
        output=OUT/('avatar_'+kind+'.glb');buffer_sha=make_variant(source,texture,output)
        bones,vertices,bounds=save_source_and_portraits(kind,output)
        report['avatar_'+kind]={**spec,**appearance,'source_asset':str(source.relative_to(ROOT)),
            'source_sha256':sha(source.read_bytes()),'geometry_buffer_sha256':buffer_sha,
            'anatomy_preserved':True,'geometry_and_animation_bytes_preserved':True,
            'skeleton':'mixamo_biped','output':str(output.relative_to(ROOT)),
            'sha256':sha(output.read_bytes()),'bytes':output.stat().st_size,'bones':bones,'vertices':vertices,
            'height_m':donor['height_m'],'evaluated_idle_bounds_m':bounds,
            'animation_donor':spec['donor_slug'],'clips':donor['clips'],
            'non_loop_clips':donor['non_loop_clips'],'cup_offset_m':donor['cup_offset_m'],
            'authoring':'Wardrobe variant of the existing source model; original geometry, proportions, rig, skinning and animation bytes are unchanged'}
        (OUT/'report.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
        print('FINISHED PRESERVED HUMAN',kind,flush=True)


if __name__=='__main__':main()
