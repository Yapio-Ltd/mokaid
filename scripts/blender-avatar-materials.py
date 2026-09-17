#!/usr/bin/env python3
"""Correct avatar surface materials in existing baked .blend files, preserving poses.
blender --background --python-exit-code 1 --python scripts/blender-avatar-materials.py -- /tmp/avatar-quality
The full authoring pipeline shares the same material policy and exporter.
"""
import hashlib,json,runpy,struct,sys
from pathlib import Path
import bpy

helpers=runpy.run_path(str(Path(__file__).with_name('blender-avatar-quality.py')))

def animation_signature(path):
 gltf,blob=helpers['glb_read'](path);curves=[]
 for animation in gltf['animations']:
  for channel in animation['channels']:
   target=channel['target'];sampler=animation['samplers'][channel['sampler']];data=[]
   for key in ['input','output']:
    accessor=gltf['accessors'][sampler[key]];view=gltf['bufferViews'][accessor['bufferView']]
    components={'SCALAR':1,'VEC3':3,'VEC4':4}[accessor['type']]
    start=view.get('byteOffset',0)+accessor.get('byteOffset',0);count=accessor['count']*components
    data.append(hashlib.sha256(blob[start:start+count*4]).hexdigest())
   curves.append((animation['name'],gltf['nodes'][target['node']]['name'],target['path'],*data))
 return hashlib.sha256(json.dumps(sorted(curves)).encode()).hexdigest()

def albedo_signature(path):
 gltf,blob=helpers['glb_read'](path);result={}
 for material in gltf['materials']:
  pbr=material.get('pbrMetallicRoughness',{});texture=pbr.get('baseColorTexture');image=None
  if texture:
   texture_data=gltf['textures'][texture['index']]
   image_index=texture_data.get('source')
   if image_index is None:
    image_index=next(extension['source'] for extension in texture_data.get('extensions',{}).values() if 'source' in extension)
   view=gltf['bufferViews'][gltf['images'][image_index]['bufferView']]
   start=view.get('byteOffset',0);image=hashlib.sha256(blob[start:start+view['byteLength']]).hexdigest()
  result[material['name']]=(pbr.get('baseColorFactor',[1,1,1,1]),image)
 return result

def main():
 output=Path(sys.argv[sys.argv.index('--')+1]);report=json.loads((output/'report.json').read_text())
 for key,entry in report.items():
  path=output/(key+'.glb');animation_before=animation_signature(path);albedo_before=albedo_signature(path)
  bpy.ops.wm.open_mainfile(filepath=str(output/(key+'.blend')))
  arm=next(obj for obj in bpy.data.objects if obj.type=='ARMATURE')
  meshes=[obj for obj in bpy.data.objects if obj.type=='MESH' and obj.vertex_groups]
  count=helpers['normalize_avatar_materials'](meshes)
  helpers['export_avatar'](arm,meshes,path)
  assert animation_signature(path)==animation_before,(key,'material export changed animation curves')
  assert albedo_signature(path)==albedo_before,(key,'material export changed albedo')
  bpy.ops.wm.save_as_mainfile(filepath=str(output/(key+'.blend')))
  rig=helpers['Rig'](arm,meshes);actions={name:bpy.data.actions[name] for name in helpers['DURATIONS']}
  helpers['render_preview'](rig,actions,output/(key+'-contact-sheet.png'))
  entry.update(sha256=hashlib.sha256(path.read_bytes()).hexdigest(),bytes=path.stat().st_size,
               material_policy={'metallic':0,'emission':0,'roughness_min':.65,'specular_ior_level':.5},
               corrected_materials=count,animation_signature=animation_before,albedo_preserved=True)
  (output/'report.json').write_text(json.dumps(report,indent=2))
  print('MATERIALS PASS',key,count,entry['sha256'],flush=True)
if __name__=='__main__':main()
