"""Register independently validated Blender characters in local asset catalogs.

No upload, deployment, database writes or modification of existing agents.
Historical content-addressed GLBs remain available.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
STAGED = ROOT / 'artifacts/avatar-atypical'
KINDS = ('byte', 'nyx', 'moss')


def main():
    report = json.loads((STAGED / 'report.json').read_text())
    validation = json.loads((STAGED / 'validation.json').read_text())
    catalog_path = ROOT / 'apps/api/lib/mokaid/assets_3d.ex'
    catalog = catalog_path.read_text()
    web_manifest_path = ROOT / 'apps/web/src/three/asset-manifest.ts'
    web_manifest = web_manifest_path.read_text()
    portraits_path = ROOT / 'apps/web/src/components/agents/workforce-agent-portrait.tsx'
    portraits = portraits_path.read_text()
    native_provenance_path = ROOT / 'apps/desktop/presentation/assets/provenance.json'
    native_provenance = json.loads(native_provenance_path.read_text())
    web_provenance_path = ROOT / 'apps/web/public/branding/agent-portraits/provenance.json'
    web_provenance = json.loads(web_provenance_path.read_text())
    manifest = {'blender': '5.2.0 LTS', 'authoring_script': 'scripts/blender-atypical-avatars.py',
                'validation_script': 'scripts/validate-avatar-life.py', 'avatars': {}}
    prepared = []
    for kind in KINDS:
        key = 'avatar_' + kind
        source = STAGED / (key + '.glb')
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        entry, checked = report[key], validation[key]
        assert digest == entry['sha256'] == checked['sha256']
        assert checked['clips'] == len(entry['clips']) == 48
        assert checked['max_weight_sum_error'] < .0001
        assert checked['max_runtime_phone_grip_error_m'] < .001
        filename = f'{key}.{digest[:12]}.glb'
        path = '/assets3d/' + filename
        block = f'''    %{{
      "slug" => "{key}",
      "kind" => "character",
      "storage_key" => "assets3d/{filename}",
      "cdn_path" => "{path}",
      "sha256" => "{digest}",
      "byte_size" => {source.stat().st_size:_},
      "animation_clips" => @all_clips,
      "metadata" => %{{
        "display_name" => "{entry['name']}",
        "target_height_m" => 1.75,
        "source" => "Original Blender character with calibrated office rig and 48 animations",
        "skeleton" => "mixamo_biped",
        "style" => "{entry['style']}",
        "authoring_file" => "artifacts/avatar-atypical/{key}.blend"
      }}
    }}'''
        pattern = r'    %\{\n      "slug" => "' + key + r'",.*?\n    \}'
        if re.search(pattern, catalog, flags=re.S):
            catalog = re.sub(pattern, lambda _: block, catalog, flags=re.S)
        else:
            marker = '\n  ]\n\n  @archetype_avatar_slugs'
            assert marker in catalog
            catalog = catalog.replace(marker, ',\n' + block + marker)
        web_entry = f'''  {key}: {{
    id: "{key}",
    url: resolveAgentGlbUrl("{path}"),
    kind: "avatar",
  }},'''
        pattern = r'  ' + key + r': \{.*?\n  \},'
        if re.search(pattern, web_manifest, flags=re.S):
            web_manifest = re.sub(pattern, lambda _: web_entry, web_manifest, flags=re.S)
        else:
            web_manifest = web_manifest.replace('\n};', '\n' + web_entry + '\n};', 1)
        portrait_entry = f'  ["{filename}", "{kind}"],'
        pattern = r'  \["' + key + r'\.[a-f0-9]+\.glb", "' + kind + r'"\],'
        if re.search(pattern, portraits):
            portraits = re.sub(pattern, lambda _: portrait_entry, portraits)
        else:
            portraits = portraits.replace('] as const;', portrait_entry + '\n] as const;', 1)
        native_provenance[kind] = {'source': 'assets/optimized/' + filename,
            'sourceSha256': digest, 'render': f'apps/desktop/presentation/assets/portrait-{kind}.png',
            'size': [384, 384], 'renderer': 'scripts/blender-atypical-avatars.py'}
        web_provenance['portraits'] = [p for p in web_provenance['portraits']
                                     if not p['render'].endswith(f'portrait-{kind}.png')]
        web_provenance['portraits'].append({'avatar_cdn_path': path,
            'source': 'assets/optimized/' + filename, 'sourceSha256': digest,
            'render': f'/branding/agent-portraits/portrait-{kind}.png', 'size': [384, 384],
            'renderer': 'scripts/blender-atypical-avatars.py'})
        manifest['avatars'][key] = {'name': entry['name'], 'style': entry['style'],
            'path': path, 'sha256': digest, 'bytes': source.stat().st_size,
            'authoring_file': f'artifacts/avatar-atypical/{key}.blend',
            'rig_donor': entry['source_asset'], 'rig_donor_sha256': entry['source_sha256'],
            'bones': entry['bones'], 'animation_clips': list(entry['clips']),
            'validation': f'artifacts/avatar-atypical/validation.json',
            'portrait': f'/branding/agent-portraits/portrait-{kind}.png'}
        prepared.append((kind, source, filename))
    for kind, source, filename in prepared:
        for directory in ['assets/optimized', 'apps/web/public/assets3d']:
            shutil.copy2(source, ROOT / directory / filename)
        for directory in ['apps/desktop/presentation/assets', 'apps/web/public/branding/agent-portraits']:
            shutil.copy2(STAGED / f'portrait-{kind}.png', ROOT / directory / f'portrait-{kind}.png')
    catalog_path.write_text(catalog)
    web_manifest_path.write_text(web_manifest)
    portraits_path.write_text(portraits)
    native_provenance_path.write_text(json.dumps(native_provenance, indent=2) + '\n')
    web_provenance_path.write_text(json.dumps(web_provenance, indent=2) + '\n')
    (ROOT / 'assets/avatar-atypical.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Registered three validated characters in local API, web and desktop catalogs.')


if __name__ == '__main__':
    main()
