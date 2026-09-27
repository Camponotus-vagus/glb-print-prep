import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MeshoptSimplifier } from 'meshoptimizer';
import { hausdorff, topology } from '../src/metrics.mjs';
import { removeFins } from '../src/simplify.mjs';
import { cylinder, sphere } from './fixtures.mjs';

await MeshoptSimplifier.ready;
const remapOf = (pos) => MeshoptSimplifier.generatePositionRemap(new Float32Array(pos), 3);

test('a closed sphere is watertight and manifold', () => {
  const { pos, idx } = sphere();
  const t = topology(new Uint32Array(idx), remapOf(pos));
  assert.equal(t.boundaryEdges, 0);
  assert.equal(t.nonManifoldEdges, 0);
});

test('removing a triangle opens exactly three boundary edges', () => {
  const { pos, idx } = sphere();
  const t = topology(new Uint32Array(idx.slice(3)), remapOf(pos));
  assert.equal(t.boundaryEdges, 3);
});

test('Hausdorff distance of a mesh to itself is zero', () => {
  const { pos, idx } = sphere({ rings: 24, segments: 48 });
  const P = new Float32Array(pos);
  const I = new Uint32Array(idx);
  const d = hausdorff(P, I, P, I, { samples: 20_000 });
  assert.ok(d.max < 1e-6, `max ${d.max}`);
});

test('Hausdorff distance between concentric spheres equals the radius difference', () => {
  const a = sphere({ radius: 1, rings: 48, segments: 96 });
  const b = sphere({ radius: 1.05, rings: 48, segments: 96 });
  const d = hausdorff(
    new Float32Array(a.pos),
    new Uint32Array(a.idx),
    new Float32Array(b.pos),
    new Uint32Array(b.idx),
    {
      samples: 20_000,
    },
  );
  assert.ok(Math.abs(d.max - 0.05) < 0.005, `max ${d.max}`);
  assert.ok(Math.abs(d.mean - 0.05) < 0.005, `mean ${d.mean}`);
});

test('Hausdorff sampling is deterministic', () => {
  const a = sphere({ rings: 24, segments: 48 });
  const b = sphere({ radius: 1.01, rings: 20, segments: 40 });
  const args = [new Float32Array(a.pos), new Uint32Array(a.idx), new Float32Array(b.pos), new Uint32Array(b.idx)];
  assert.deepEqual(hausdorff(...args, { samples: 10_000 }), hausdorff(...args, { samples: 10_000 }));
});

test('removeFins drops opposite pairs entirely and exact duplicates once', () => {
  const { pos, idx } = cylinder({ segments: 16 });
  const remap = remapOf(pos);
  const n = idx.length;
  const [a, b, c] = idx.slice(0, 3);
  const withFin = new Uint32Array([...idx, c, b, a]); // reversed copy of triangle 0 → fin
  const fin = removeFins(withFin, remap);
  assert.equal(fin.removed, 2);
  assert.equal(fin.idx.length, n - 3);

  const withDuplicate = new Uint32Array([...idx, b, c, a]); // same winding, rotated → duplicate
  const dup = removeFins(withDuplicate, remap);
  assert.equal(dup.removed, 1);
  assert.equal(dup.idx.length, n);
});
