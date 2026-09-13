import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { avatarKeys, parseAvatarCatalog, catalogEntry, validateAnimationValues } from './source-policy.mjs';

const catalogSource = await readFile(new URL('../../../api/lib/mokaid/assets_3d.ex', import.meta.url), 'utf8');
test('desktop uses all seven content-addressed, actually shipped avatar revisions', async () => {
  const catalog = parseAvatarCatalog(catalogSource);
  for (const key of avatarKeys) {
    const entry = catalogEntry(catalog, key);
    const bytes = await readFile(new URL(`../../../web/public${entry.path}`, import.meta.url));
    assert.equal(createHash('sha256').update(bytes).digest('hex'), entry.sha256);
  }
  assert.equal(catalogEntry(catalog, 'avatar_female'), catalogEntry(catalog, 'avatar_design'));
});
test('catalog path/hash inconsistencies fail closed', () => {
  assert.throws(() => parseAvatarCatalog(catalogSource.replace('/assets3d/avatar_male.', '/assets3d/not_male.')));
  assert.throws(() => parseAvatarCatalog(''));
  assert.throws(() => parseAvatarCatalog(catalogSource + catalogSource));
});
const accessor = rows => ({ getCount: () => rows.length, getElement: index => rows[index] });
test('legacy constant seated tracks can be expanded or reduced without inventing motion', () => {
  validateAnimationValues(7, accessor([[0, .5, 0], [0, .5, 0]]), 'constant');
  validateAnimationValues(1, accessor([[0, .5, 0], [0, .5, 0]]), 'constant');
});
test('nonconstant count mismatches and empty tracks are rejected', () => {
  assert.throws(() => validateAnimationValues(3, accessor([[0, 0, 0], [1, 0, 0]]), 'moving'));
  assert.throws(() => validateAnimationValues(0, accessor([]), 'empty'));
  validateAnimationValues(2, accessor([[0, 0, 0], [1, 0, 0]]), 'valid motion');
});
