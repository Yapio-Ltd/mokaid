#!/usr/bin/env python3
"""Promote a locally validated Blender bake into the web/API/desktop catalog.
No network access or deployment. Retain content-addressed historical assets.
python3 scripts/promote-avatar-quality.py /tmp/avatar-quality
"""
import argparse,hashlib,json,re,shutil,sys
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('staged',type=Path);parser.add_argument('--artifacts',type=Path);parser.add_argument('--only',nargs='+');args=parser.parse_args()
root=Path(__file__).resolve().parents[1];staged=args.staged.resolve()
report=json.loads((staged/'report.json').read_text());validation=json.loads((staged/'validation.json').read_text())
sources=json.loads((root/'assets/avatar-authoring-sources.json').read_text())['avatars']
assert set(report)==set(validation)==set(sources)
catalog=root/'apps/api/lib/mokaid/assets_3d.ex';content=catalog.read_text()
references=[root/'apps/web/src/three/agent-cdn.ts',root/'apps/web/src/three/asset-manifest.ts',root/'apps/web/src/components/landing/agent-tour.tsx']
artifacts=(args.artifacts or root/'artifacts/avatar-quality').resolve();artifacts.mkdir(parents=True,exist_ok=True)
clip_names=list(next(iter(report.values()))['clips']);assert all(set(e['clips'])==set(clip_names) for e in report.values())
content=re.sub(r'@all_clips ~w\(.*?\)', '@all_clips ~w(\n    '+'\n    '.join(' '.join(clip_names[i:i+6]) for i in range(0,len(clip_names),6))+'\n  )',content,flags=re.S)
selected={k:v for k,v in report.items() if not args.only or k in args.only}
assert selected and (not args.only or set(selected)==set(args.only))
for key,entry in selected.items():
 source=staged/(key+'.glb');sha=hashlib.sha256(source.read_bytes()).hexdigest();assert sha==entry['sha256']
 assert validation[key]['clips']==len(clip_names) and validation[key]['sha256']==sha
 if key=='avatar_legal' and (staged/'legal-regression/audit.json').exists():
  audit=json.loads((staged/'legal-regression/audit.json').read_text());assert audit['passed'] and audit['source_sha256']==sha, 'Legal dense robe regression must pass for this exact export'
 previous=re.search(r'"slug" => "'+key+r'".*?"cdn_path" => "([^"]+)".*?"sha256" => "([^"]+)".*?"byte_size" => ([\d_]+)',content,re.S)
 assert previous,key
 old_path,old_sha,_=previous.groups();filename=f'{key}.{sha[:12]}.glb';new_path='/assets3d/'+filename
 for destination in [root/'assets/optimized'/filename,root/'apps/web/public/assets3d'/filename]:shutil.copy2(source,destination)
 block=previous.group().replace(old_path,new_path).replace(old_sha,sha)
 block=re.sub(r'"byte_size" => [\d_]+','"byte_size" => '+format(source.stat().st_size,',').replace(',','_'),block)
 content=content[:previous.start()]+block+content[previous.end():]
 # storage_key precedes cdn_path and is included in the block; replace its
 # non-leading-slash form too.
 content=content.replace(old_path.lstrip('/'),new_path.lstrip('/'))
 for path in references:path.write_text(path.read_text().replace(old_path,new_path))
 for suffix in ['.blend','-contact-sheet.png']:
  if staged!=artifacts:shutil.copy2(staged/(key+suffix),artifacts/(key+suffix))
catalog.write_text(content)
for filename in ['report.json','validation.json']:
 if staged!=artifacts:shutil.copy2(staged/filename,artifacts/filename)
print(f'Promoted {len(selected)} validated avatars. Editable Blender sources: {artifacts}')
