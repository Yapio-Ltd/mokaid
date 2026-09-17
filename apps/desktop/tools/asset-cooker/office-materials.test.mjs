import assert from 'node:assert/strict';
import { test } from 'node:test';
import { filterOfficePixels } from './office-materials.mjs';

test('neon atlas retains purple and lamp emission but removes portrait cyan/white', () => {
  const source = Buffer.from([170, 30, 255, 255, 240, 140, 20, 180,
    220, 250, 250, 255, 255, 255, 255, 255]);
  assert.deepEqual([...filterOfficePixels(source, 'emission')],
    [170, 30, 255, 255, 240, 140, 20, 180, 0, 0, 0, 255, 0, 0, 0, 255]);
  assert.equal(source[8], 220, 'shared source atlas is never mutated');
});
test('meeting-room screens stay luminous while neutral paper remains matte', () => {
  const source = Buffer.from([45, 120, 220, 255, 240, 240, 240, 255]);
  assert.deepEqual([...filterOfficePixels(source, 'screen')],
    [38, 108, 231, 255, 0, 0, 0, 255]);
  assert.deepEqual([...filterOfficePixels(source, 'paper')],
    [45, 120, 220, 255, 84, 84, 84, 255]);
});
