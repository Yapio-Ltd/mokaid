import test from 'node:test';
import assert from 'node:assert/strict';
import { Document, NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import draco from 'draco3dgltf';
import sharp from 'sharp';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { applyVerifiedCharacterTexture, restoreCharacterTextures, characterTextureSources,
  characterUvHash, embeddedGlbImage, bakeOriginalCharacterAtlas, sha256 } from './character-textures.mjs';
import { parseAvatarCatalog, catalogEntry } from './source-policy.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
async function fixture() {
  const document = new Document(), buffer = document.createBuffer();
  const before = await sharp({ create: { width: 2, height: 2, channels: 4, background: '#da9072' } }).png().toBuffer();
  const after = await sharp({ create: { width: 4, height: 4, channels: 4, background: '#da9072' } }).webp({ lossless: true }).toBuffer();
  const texture = document.createTexture('skin').setImage(before).setMimeType('image/png');
  const material = document.createMaterial('jacket').setBaseColorTexture(texture).setBaseColorFactor([.9, .8, .7, 1]).setRoughnessFactor(.82);
  const position = document.createAccessor().setType('VEC3').setArray(new Float32Array([0, 0, 0, 1, 0, 0, 0, 1, 0])).setBuffer(buffer);
  const uv = document.createAccessor().setType('VEC2').setArray(new Float32Array([0, 0, 1, 0, 0, 1])).setBuffer(buffer);
  document.createMesh().addPrimitive(document.createPrimitive().setMaterial(material).setAttribute('POSITION', position).setAttribute('TEXCOORD_0', uv));
  const source = { catalogSourceSha256: 'reviewed-source', catalogImageSha256: sha256(before), catalogUvSha256: characterUvHash(document),
    path: 'assets/character-textures/fixture.webp', sha256: sha256(after), width: 4, height: 4, mimeType: 'image/webp',
    original: { width: 8, height: 8, imageSha256: 'original-atlas', sha256: 'original-glb' } };
  return { document, texture, material, position, uv, source, before, after };
}

test('verified recovery changes only the reviewed texture image, retaining UVs, rig geometry and material colors', async () => {
  const f = await fixture(), uv = f.uv.getArray(), geometry = f.position.getArray(), factors = f.material.getBaseColorFactor();
  const result = await applyVerifiedCharacterTexture(f.document, f.source, { sourceSha256: 'reviewed-source', image: f.after });
  assert.deepEqual(Buffer.from(f.texture.getImage()), f.after);
  assert.equal(f.texture.getMimeType(), 'image/webp');
  assert.strictEqual(f.uv.getArray(), uv); assert.strictEqual(f.position.getArray(), geometry);
  assert.deepEqual(f.material.getBaseColorFactor(), factors); assert.equal(f.material.getRoughnessFactor(), .82);
  assert.deepEqual(result.resolution, [4, 4]); assert.equal(result.originalSourceSha256, 'original-glb');
});

test('an unmapped revision and recolored variants retain their exact image bytes', async () => {
  const f = await fixture();
  assert.equal(await applyVerifiedCharacterTexture(f.document, f.source, { sourceSha256: 'another-revision', image: f.after }), null);
  for (const key of ['avatar_byte', 'avatar_nyx', 'avatar_moss', 'custom:generated', 'office'])
    assert.equal(await restoreCharacterTextures(f.document, key, { sourceSha256: 'reviewed-source' }), null);
  assert.deepEqual(Buffer.from(f.texture.getImage()), f.before);
});

test('altered image, UV layout, prepared file, and invented source resolution fail before mutation', async () => {
  for (const kind of ['image', 'uv', 'hash', 'upscale']) {
    const f = await fixture();
    if (kind === 'image') f.source.catalogImageSha256 = 'changed';
    if (kind === 'uv') f.uv.setArray(new Float32Array([0, 0, .5, 0, 0, 1]));
    if (kind === 'hash') f.source.sha256 = 'changed';
    if (kind === 'upscale') f.source.original.width = 2;
    await assert.rejects(applyVerifiedCharacterTexture(f.document, f.source, { sourceSha256: 'reviewed-source', image: f.after }),
      /image changed|UV layout changed|hash mismatch|additional source resolution/);
    assert.deepEqual(Buffer.from(f.texture.getImage()), f.before);
  }
});

function glbImage(image) {
  const source = Buffer.from(JSON.stringify({ asset: { version: '2.0' }, buffers: [{ byteLength: image.length }],
    bufferViews: [{ buffer: 0, byteOffset: 0, byteLength: image.length }], images: [{ bufferView: 0, mimeType: 'image/png' }] }));
  const json = Buffer.alloc(Math.ceil(source.length / 4) * 4, 32); source.copy(json);
  const binary = Buffer.alloc(Math.ceil(image.length / 4) * 4); image.copy(binary);
  const bytes = Buffer.alloc(28 + json.length + binary.length);
  bytes.writeUInt32LE(0x46546c67, 0); bytes.writeUInt32LE(2, 4); bytes.writeUInt32LE(bytes.length, 8);
  bytes.writeUInt32LE(json.length, 12); bytes.writeUInt32LE(0x4e4f534a, 16); json.copy(bytes, 20);
  bytes.writeUInt32LE(binary.length, 20 + json.length); bytes.writeUInt32LE(0x004e4942, 24 + json.length); binary.copy(bytes, 28 + json.length);
  return bytes;
}

test('optional source rebake verifies both GLB and embedded atlas hashes and never enlarges', async () => {
  const original = await sharp({ create: { width: 8, height: 8, channels: 4, background: '#b47562' } }).png().toBuffer();
  const bytes = glbImage(original), output = await sharp(original).resize({ width: 4, height: 4, fit: 'inside', withoutEnlargement: true, kernel: 'lanczos3' })
    .webp({ lossless: true, effort: 6 }).toBuffer();
  const source = { width: 4, height: 4, sha256: sha256(output), original: { width: 8, height: 8, imageIndex: 0, sha256: sha256(bytes), imageSha256: sha256(original) } };
  assert.deepEqual(embeddedGlbImage(bytes, 0), original);
  assert.deepEqual(await bakeOriginalCharacterAtlas(bytes, source), output);
  await assert.rejects(bakeOriginalCharacterAtlas(Buffer.from('not the reviewed source'), source), /GLB hash mismatch/);
  assert.throws(() => embeddedGlbImage(bytes.subarray(0, bytes.length - 2), 0), /Invalid original character GLB/);
  await assert.rejects(bakeOriginalCharacterAtlas(bytes, { ...source, width: 16 }), /resolution mismatch/);
});

test('all six portable atlases match pinned provenance and a bounded 2K GPU budget', async () => {
  assert.equal(Object.keys(characterTextureSources).length, 6);
  let residentBytes = 0;
  for (const source of Object.values(characterTextureSources)) {
    const bytes = await readFile(resolve(repository, source.path));
    assert.equal(sha256(bytes), source.sha256);
    const metadata = await sharp(bytes).metadata();
    assert.deepEqual([metadata.width, metadata.height], [source.width, source.height]);
    assert.ok(source.width <= 2048 && source.height <= 2048);
    assert.ok(source.width < source.original.width && source.height < source.original.height);
    assert.ok(source.verification.uvMaxNearestDistance < .00022);
    residentBytes += source.width * source.height * 4 * 4 / 3;
  }
  assert.ok(residentBytes <= 128 * 1024 * 1024);
});

test('reviewed catalog revisions accept recovery without changing the three recolored atlases',
  { skip: !process.env.MOKAID_CHARACTER_SOURCE_AUDIT }, async () => {
    const io = new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({ 'draco3d.decoder': await draco.createDecoderModule() });
    for (const [key, source] of Object.entries(characterTextureSources)) {
      const file = resolve(repository, `apps/web/public/assets3d/${key}.${source.catalogSourceSha256.slice(0, 12)}.glb`);
      const bytes = await readFile(file); assert.equal(sha256(bytes), source.catalogSourceSha256);
      const document = await io.readBinary(bytes);
      const recovered = await restoreCharacterTextures(document, key, { sourceSha256: sha256(bytes) });
      assert.deepEqual(recovered.resolution, [2048, 2048]);
    }
    const catalog = parseAvatarCatalog(await readFile(resolve(repository, 'apps/api/lib/mokaid/assets_3d.ex'), 'utf8'));
    for (const key of ['avatar_female', 'avatar_byte', 'avatar_nyx', 'avatar_moss']) {
      const entry = catalogEntry(catalog, key), bytes = await readFile(resolve(repository, 'apps/web/public' + entry.path));
      const document = await io.readBinary(bytes);
      const before = document.getRoot().listTextures().map(texture => sha256(texture.getImage()));
      const result = await restoreCharacterTextures(document, key, { sourceSha256: sha256(bytes) });
      if (key === 'avatar_female') assert.deepEqual(result.resolution, [2048, 2048]);
      else {
        assert.equal(result, null);
        assert.deepEqual(document.getRoot().listTextures().map(texture => sha256(texture.getImage())), before);
      }
    }
  });
