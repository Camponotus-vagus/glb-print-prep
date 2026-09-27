import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MeshoptSimplifier } from 'meshoptimizer';
import { topology } from '../src/metrics.mjs';
import { countTriangles, detectBase, reduceDocument } from '../src/simplify.mjs';
import { miniature, sphere, toDocument } from './fixtures.mjs';

test('detectBase finds the round base of a miniature', () => {
  const base = detectBase(toDocument(miniature()));
  assert.equal(base.round, true);
  assert.ok(Math.abs(base.baseUnits - 2) < 0.02, `base ${base.baseUnits}`);
  assert.ok(Math.abs(base.heightUnits - 1.35) < 0.01, `height ${base.heightUnits}`);
});

test('reduceDocument reaches the target and keeps the mesh closed', async () => {
  const doc = toDocument(sphere({ rings: 128, segments: 256 }));
  const before = countTriangles(doc);
  await reduceDocument(doc, 8_000);
  const after = countTriangles(doc);
  assert.ok(after < before);
  assert.ok(after <= 8_000 * 1.05, `after ${after}`);
  assert.ok(after >= 8_000 * 0.8, `after ${after}`);

  await MeshoptSimplifier.ready;
  const p = doc.getRoot().listMeshes()[0].listPrimitives()[0];
  const pos = p.getAttribute('POSITION').getArray();
  const t = topology(p.getIndices().getArray(), MeshoptSimplifier.generatePositionRemap(pos, 3));
  assert.equal(t.boundaryEdges, 0);
  assert.equal(t.nonManifoldEdges, 0);
});
