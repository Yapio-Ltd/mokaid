import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {Document, NodeIO} from '@gltf-transform/core';
import {ALL_EXTENSIONS} from '@gltf-transform/extensions';
import draco from 'draco3dgltf';
import {applyCharacterExpression, characterExpressionDelta, characterExpressionProfiles} from './character-expressions.mjs';
import {avatarKeys, catalogEntry, parseAvatarCatalog} from './source-policy.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const bytes = array => Buffer.from(array.buffer, array.byteOffset, array.byteLength);
const identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

test('seven anatomical profiles lift symmetric lip corners and protect eyes, nose and body', () => {
  assert.equal(Object.keys(characterExpressionProfiles).length, 7);
  for (const [family, profile] of Object.entries(characterExpressionProfiles)) {
    const key = `avatar_${family}`;
    const right = characterExpressionDelta(key, profile.mouth);
    const left = characterExpressionDelta(key, [-profile.mouth[0], ...profile.mouth.slice(1)]);
    assert(right[1] > 0 && right[0] > 0, family);
    assert.deepEqual(left, [-right[0], right[1], 0]);
    assert(Math.hypot(...right) < .012, family);
    assert.deepEqual(characterExpressionDelta(key, profile.eyes), [0, 0, 0], `${family}: eyes`);
    assert.deepEqual(characterExpressionDelta(key, [0, profile.mouth[1], profile.mouth[2]]), [0, 0, 0], `${family}: central lips`);
    assert.deepEqual(characterExpressionDelta(key, [0, .7, 0]), [0, 0, 0], `${family}: body`);
  }
  const legal = characterExpressionProfiles.legal;
  assert(characterExpressionDelta('avatar_legal', legal.innerBrows)[1] > .004);
  assert.deepEqual(characterExpressionDelta('custom_unknown', legal.mouth), [0, 0, 0]);
  assert.deepEqual(applyCharacterExpression(new Document(), 'custom_unknown'),
    {profile: null, correctedVertices: 0, skipped: true});
});

function bindFixture() {
  const document = new Document(), buffer = document.createBuffer();
  const make = (type, array) => document.createAccessor().setType(type).setArray(array).setBuffer(buffer);
  const profile = characterExpressionProfiles.legal;
  const world = [...profile.mouth, ...profile.eyes, 0, .7, 0];
  const local = new Float32Array(world.map((v, i) => (v - (i % 3 === 1 ? .1 : 0)) / [2, 3, 4][i % 3]));
  const head = document.createNode('Head').setScale([2, 3, 4]).setTranslation([0, .1, 0]);
  const body = document.createNode('Hips').setScale([2, 3, 4]).setTranslation([0, .1, 0]);
  const skin = document.createSkin().addJoint(head).addJoint(body)
    .setInverseBindMatrices(make('MAT4', new Float32Array([...identity, ...identity])));
  const mesh = document.createMesh();
  for (const weight of [1, .2]) {
    mesh.addPrimitive(document.createPrimitive()
      .setAttribute('POSITION', make('VEC3', local.slice()))
      .setAttribute('NORMAL', make('VEC3', new Float32Array([0, 0, 1, 0, 0, 1, 0, 0, 1])))
      .setAttribute('TEXCOORD_0', make('VEC2', new Float32Array([weight, 0, 1, 0, 0, 1])))
      .setAttribute('JOINTS_0', make('VEC4', new Uint16Array([0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0])))
      .setAttribute('WEIGHTS_0', make('VEC4', new Float32Array(Array(3).fill([weight, 1 - weight, 0, 0]).flat()))));
  }
  const node = document.createNode('char1').setMesh(mesh).setSkin(skin).setScale([.01, .01, .01]);
  document.createScene().addChild(head).addChild(body).addChild(node);
  return {document, mesh, local, profile};
}

test('bind-world deformation survives mesh scale and keeps duplicated facial seam positions together', () => {
  const {document, mesh, local, profile} = bindFixture();
  const original = mesh.listPrimitives().map(p => p.getAttribute('POSITION'));
  const result = applyCharacterExpression(document, 'avatar_legal');
  assert.equal(result.correctedVertices, 2);
  assert.equal(result.correctedPrimitives, 2);
  const outputs = mesh.listPrimitives().map(p => p.getAttribute('POSITION').getArray());
  const expected = characterExpressionDelta('avatar_legal', profile.mouth);
  for (let axis = 0; axis < 3; axis++)
    assert(Math.abs(outputs[0][axis] - local[axis] - expected[axis] / [2, 3, 4][axis]) < 1e-7);
  assert.deepEqual(outputs[0], outputs[1]);
  assert.deepEqual(outputs[0].slice(3), local.slice(3));
  for (const accessor of original) assert.deepEqual(accessor.getArray(), local);
});

const catalog = parseAvatarCatalog(await readFile(new URL('../../../api/lib/mokaid/assets_3d.ex', import.meta.url), 'utf8'));
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS)
  .registerDependencies({'draco3d.decoder': await draco.createDecoderModule()});
const aliases = {avatar_female: 'avatar_design', avatar_byte: 'avatar_corporate', avatar_nyx: 'avatar_finance', avatar_moss: 'avatar_developer'};
const positionResults = new Map();

test('all eleven bundled agents smile without changing source files, UVs, skinning or animation data', async t => {
  for (const key of [...avatarKeys, 'avatar_female']) await t.test(key, async () => {
    const entry = catalogEntry(catalog, key);
    const path = new URL(`../../../web/public${entry.path}`, import.meta.url);
    const source = await readFile(path);
    const document = await io.readBinary(new Uint8Array(source));
    const root = document.getRoot();
    const originalAccessors = root.listAccessors().map(a => [a, hash(bytes(a.getArray()))]);
    const nodes = root.listNodes().map(n => [n, n.getMatrix(), n.getMesh(), n.getSkin()]);
    const textures = root.listTextures().map(texture => [texture, hash(texture.getImage())]);
    const primitives = root.listMeshes().flatMap(mesh => mesh.listPrimitives()).map(primitive => ({
      primitive,
      positions: primitive.getAttribute('POSITION'),
      indices: primitive.getIndices(),
      attributes: primitive.listSemantics().filter(s => s !== 'POSITION').map(s => [s, primitive.getAttribute(s)]),
      material: primitive.getMaterial(),
    }));
    const result = applyCharacterExpression(document, key);
    assert(result.correctedVertices >= 20 && result.correctedVertices < 2000, `${key}: bounded facial change`);
    assert(result.maximumDisplacement > 0 && result.maximumDisplacement < .012, `${key}: gentle displacement`);
    assert.equal(result.normalsRequireUpdate, true);
    assert.equal(root.listAnimations().length, 48);
    for (const [accessor, digest] of originalAccessors) assert.equal(hash(bytes(accessor.getArray())), digest);
    for (const [node, matrix, mesh, skin] of nodes) {
      assert.deepEqual(node.getMatrix(), matrix);
      assert.equal(node.getMesh(), mesh);
      assert.equal(node.getSkin(), skin);
    }
    for (const [texture, digest] of textures) assert.equal(hash(texture.getImage()), digest);
    let changed = 0;
    const outputDigest = createHash('sha256');
    const seams = new Map();
    for (const {primitive, positions, indices, attributes, material} of primitives) {
      assert.equal(primitive.getIndices(), indices);
      assert.equal(primitive.getMaterial(), material);
      for (const [semantic, accessor] of attributes) assert.equal(primitive.getAttribute(semantic), accessor);
      const after = primitive.getAttribute('POSITION');
      outputDigest.update(bytes(after.getArray()));
      for (let i = 0; i < positions.getCount(); i++) {
        const a = positions.getElement(i, []), b = after.getElement(i, []);
        if (a.every((value, axis) => value === b[axis])) continue;
        changed++;
        assert(Math.hypot(...b.map((value, axis) => value - a[axis])) < .012);
        // Identical UV seam positions must remain welded after the expression.
        const seamKey = a.join(',');
        if (seams.has(seamKey)) assert(Math.hypot(...b.map((value, axis) => value - seams.get(seamKey)[axis])) < 3e-7);
        else seams.set(seamKey, b);
      }
    }
    assert(changed > 0);
    const digest = outputDigest.digest('hex');
    if (aliases[key]) {
      assert.deepEqual(positionResults.get(aliases[key]), {digest, count: result.correctedVertices, profile: result.profile});
    } else positionResults.set(key, {digest, count: result.correctedVertices, profile: result.profile});
    assert.equal(hash(await readFile(path)), hash(source), 'source GLB stays untouched');
    t.diagnostic(`${key}: ${result.correctedVertices} vertices, ${(result.maximumDisplacement * 1000).toFixed(3)} mm maximum, profile ${result.profile}`);
  });
});
