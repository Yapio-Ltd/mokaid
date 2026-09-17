import {strict as assert} from 'node:assert';
import {test} from 'node:test';
import {surfaceKind} from './surface-kinds.mjs';

test('Only explicitly authored display surfaces select the screen shader', () => {
  assert.equal(surfaceKind('Desktop screen 8', true), 1);
  assert.equal(surfaceKind('Desktop screen', true), 1);
  for (const name of ['Monitor ', 'Lap Top', 'Desktop screen imitation', 'Desktop phone screen'])
    assert.notEqual(surfaceKind(name, true), 1);
  assert.equal(surfaceKind('Desktop screen 1', false), 0);
});
test('Phone and dock remain separate PBR surfaces with explicit visibility bits', () => {
  assert.equal(surfaceKind('Desktop phone'), 2);
  assert.equal(surfaceKind('Desktop phone screen'), 2);
  assert.equal(surfaceKind('Desktop phone dock'), 3);
  assert.equal(surfaceKind('Phone body paint'), 0);
});
