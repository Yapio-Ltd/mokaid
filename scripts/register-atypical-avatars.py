"""Register independently validated Blender characters in local asset catalogs.

No upload, deployment, database writes or modification of existing agents.
Historical content-addressed GLBs remain available.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct

ROOT = Path(__file__).resolve().parents[1]
STAGED = ROOT / 'artifacts/avatar-atypical'
KINDS = ('byte', 'nyx', 'moss')


def glb_bin(data):
    """Read the complete padded BIN chunk after validating GLB framing."""
    if len(data) < 12:
        raise ValueError('Truncated GLB header')
    magic, version, length = struct.unpack_from('<4sII', data)
    if magic != b'glTF' or version != 2 or length != len(data):
        raise ValueError('Invalid GLB header or declared length')
    offset, binary, seen_json = 12, None, False
    while offset < length:
        if length - offset < 8:
            raise ValueError('Truncated GLB chunk header')
        size, kind = struct.unpack_from('<I4s', data, offset)
        end = offset + 8 + size
        if size % 4 or end > length:
            raise ValueError('Invalid GLB chunk length')
        payload = data[offset + 8:end]
        if offset == 12 and kind != b'JSON':
            raise ValueError('GLB must start with a JSON chunk')
        if kind == b'JSON':
            if seen_json:
                raise ValueError('Duplicate GLB JSON chunk')
            json.loads(payload)
            seen_json = True
        elif kind == b'BIN\0':
            if binary is not None:
                raise ValueError('Duplicate GLB BIN chunk')
            binary = payload
        offset = end
    if not seen_json or binary is None:
        raise ValueError('GLB must contain JSON and BIN chunks')
    return binary


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
        output_bytes = source.read_bytes()
        digest = hashlib.sha256(output_bytes).hexdigest()
        entry, checked = report[key], validation[key]
        if (entry.get('anatomy_preserved') is not True or
                entry.get('geometry_and_animation_bytes_preserved') is not True):
            raise ValueError(f'{key}: donor anatomy and animation preservation required')
        donor_bytes = (ROOT / entry['source_asset']).read_bytes()
        if hashlib.sha256(donor_bytes).hexdigest() != entry['source_sha256']:
            raise ValueError(f'{key}: source asset checksum mismatch')
        donor_bin = glb_bin(donor_bytes)
        if hashlib.sha256(donor_bin).hexdigest() != entry['geometry_buffer_sha256']:
            raise ValueError(f'{key}: original geometry buffer checksum mismatch')
        if not glb_bin(output_bytes).startswith(donor_bin):
            raise ValueError(f'{key}: original geometry and animation bytes changed')
        assert digest == entry['sha256'] == checked['sha256']
        assert checked['clips'] == len(entry['clips']) == 48
        assert checked['max_weight_sum_error'] < .0001
        assert checked['max_runtime_phone_grip_error_m'] < .001
        filename = f'{key}.{digest[:12]}.glb'
        path = '/assets3d/' + filename
        style_line = f'        "style" => "{entry["style"]}",'
        if len(style_line) > 98:
            style_line = f'        "style" =>\n          "{entry["style"]}",'
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
        "source" =>
          "Derived from existing Mokaid character; anatomy, rig and 48 animations preserved",
        "skeleton" => "{entry['skeleton']}",
        "donor_slug" => "{entry['donor_slug']}",
{style_line}
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
            'donor_slug': entry['donor_slug'], 'skeleton': entry['skeleton'],
            'anatomy_preserved': entry['anatomy_preserved'],
            'geometry_and_animation_bytes_preserved': entry['geometry_and_animation_bytes_preserved'],
            'geometry_buffer_sha256': entry['geometry_buffer_sha256'],
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
