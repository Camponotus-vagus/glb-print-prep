import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DETAIL_LEVELS, toleranceFor } from '../src/tolerance.mjs';

const profile = { layer: 0.08, nozzle: 0.2 };

test('detail levels map to the documented tolerances for a 0.2 mm nozzle / 0.08 mm layer', () => {
  assert.equal(toleranceFor('extra-high', profile), 0.01);
  assert.equal(toleranceFor('high', profile), 0.02);
  assert.equal(toleranceFor('medium', profile), 0.04);
  assert.equal(toleranceFor('low', profile), 0.08);
});

test('the tighter of layer and nozzle bounds wins', () => {
  // 0.4 nozzle, 0.08 layer: layer bound (0.02) is tighter than nozzle bound (0.04)
  assert.equal(toleranceFor('high', { layer: 0.08, nozzle: 0.4 }), 0.02);
  // 0.2 nozzle, 0.28 layer: nozzle bound (0.02) is tighter than layer bound (0.07)
  assert.equal(toleranceFor('high', { layer: 0.28, nozzle: 0.2 }), 0.02);
});

test('levels are strictly ordered', () => {
  const values = Object.keys(DETAIL_LEVELS).map((level) => toleranceFor(level, profile));
  for (let i = 1; i < values.length; i++) assert.ok(values[i] > values[i - 1]);
});

test('unknown level throws', () => {
  assert.throws(() => toleranceFor('ultra', profile), /unknown detail level/);
});
