// Print optimization: reduce the triangle count of a standard (uncompressed) GLB.
//
// - optimizeFile: adaptive. Finds the MINIMUM triangle count whose measured maximum deviation
//   (symmetric Hausdorff) stays within a tolerance in real millimetres, given the miniature's base
//   diameter; never above `cap` and never with worse topology than the original.
// - reduceFile: fixed target triangle count.
//
// Both always write a NEW file next to the input; nothing is ever modified or deleted.

import fs from 'node:fs';
import path from 'node:path';
import { prune } from '@gltf-transform/functions';
import validator from 'gltf-validator';
import { fail, formatInt, makeTracker } from './events.mjs';
import {
  baseName,
  compressionExtensions,
  readGlbRaw,
  structuralCheck,
  uniqueOutputPath,
  writeVerified,
} from './glb.mjs';
import { hausdorff } from './metrics.mjs';
import { makePreview } from './preview.mjs';
import { countTriangles, detectBase, primTopology, primWorldScale, reduceDocument } from './simplify.mjs';

export const OPTIMIZE_STEPS = [
  ['read', 'Reading the model and detecting the base', 0.04],
  ['search', 'Searching the fewest triangles within tolerance', 0.62],
  ['encode', 'Encoding GLB in memory', 0.04],
  ['validate', 'Test: Khronos validator', 0.06],
  ['deviation', 'Final test: deviation from the original surface', 0.16],
  ['disk', 'Writing to disk and checksum', 0.04],
  ['preview', 'Preview', 0.04],
];

export const REDUCE_STEPS = [
  ['read', 'Reading the model', 0.06],
  ['simplify', 'Reducing triangles (meshoptimizer)', 0.3],
  ['topology', 'Test: holes and non-manifold edges', 0.06],
  ['encode', 'Encoding GLB in memory', 0.08],
  ['validate', 'Test: Khronos validator', 0.1],
  ['deviation', 'Test: deviation from the original surface', 0.3],
  ['disk', 'Writing to disk and checksum', 0.05],
  ['preview', 'Preview', 0.05],
];

/** Same number of Hausdorff samples (and seeds) for search and final check: no discrepancies. */
const SAMPLES = 150_000;
const PRUNE = { keepSolidTextures: true }; // do not decode texture pixels

function loadStandard(input) {
  if (!fs.existsSync(input)) fail('file not found');
  const bytes = new Uint8Array(fs.readFileSync(input));
  const { json } = readGlbRaw(bytes);
  const compressed = compressionExtensions(json);
  if (compressed.length) fail(`the file is still compressed (${compressed.join(', ')}): repair it first`);
  return bytes;
}

/** Deviation (mm) between original and reduced primitives, scaled to real-world size. */
function measure(red, doc, mmPerUnit, samples, onProgress) {
  const prims = [];
  for (const mesh of doc.getRoot().listMeshes()) {
    for (const p of mesh.listPrimitives()) if (p.getMode() === 4 && p.getAttribute('POSITION')) prims.push(p);
  }
  let max = 0;
  let mean = 0;
  let p99 = 0;
  red.report.forEach((r, i) => {
    const scale = primWorldScale(prims[i]) * mmPerUnit;
    const h = hausdorff(r.pos0, r.idx0, r.pos, r.idx, {
      samples,
      onProgress: onProgress && ((f) => onProgress((i + f) / red.report.length)),
    });
    max = Math.max(max, h.max * scale);
    mean = Math.max(mean, h.mean * scale);
    p99 = Math.max(p99, h.p99 * scale);
  });
  return { max, mean, p99 };
}

/** Topology must not get worse: boundary and non-manifold edges may not increase. */
function topologyCheck(red) {
  let bOld = 0;
  let bNew = 0;
  let nmOld = 0;
  let nmNew = 0;
  let degenerate = 0;
  for (const r of red.report) {
    const a = primTopology(r.pos0, r.idx0);
    const b = primTopology(r.pos, r.idx);
    bOld += a.boundaryEdges;
    nmOld += a.nonManifoldEdges;
    bNew += b.boundaryEdges;
    nmNew += b.nonManifoldEdges;
    degenerate += b.degenerate;
  }
  return { ok: bNew <= bOld && nmNew <= nmOld && degenerate === 0, bOld, bNew, nmOld, nmNew, degenerate };
}

function topologyLabel(topo, lockedVertices) {
  const note = lockedVertices ? ` · ${formatInt(lockedVertices)} vertices protected in thin regions` : '';
  if (topo.bNew === 0 && topo.nmNew === 0) {
    return `Topology intact: no holes, no non-manifold edges (closed and printable)${note}`;
  }
  if (topo.bNew < topo.bOld || topo.nmNew < topo.nmOld) {
    return `Topology improved over the original (open edges ${topo.bOld}→${topo.bNew}, non-manifold ${topo.nmOld}→${topo.nmNew})${note}`;
  }
  return `Topology identical to the original (open edges ${topo.bOld}, non-manifold ${topo.nmOld}: defects already present in the source file)${note}`;
}

async function validate(bytes) {
  const post = structuralCheck(bytes);
  if (post.problems.length) fail(`structural test failed: ${post.problems.join('; ')}`);
  const report = await validator.validateBytes(bytes, { maxIssues: 50, format: 'glb' });
  if (report.issues.numErrors > 0) fail(`Khronos validator: ${report.issues.numErrors} errors`);
  return report.issues.numWarnings;
}

export async function optimizeFile(input, { io, reporter, previewDir }, { baseMM, toleranceMM, cap }) {
  const T = makeTracker(OPTIMIZE_STEPS, input, reporter);
  const pass = (id, label) => reporter.emit({ t: 'test', file: input, id, label, ok: true });
  const log = (msg) => {
    reporter.emit({ t: 'log', file: input, msg });
    reporter.say(`  ${msg}`);
  };
  reporter.say(`\n=== ${path.basename(input)} → base Ø ${baseMM} mm, tolerance ${toleranceMM} mm`);

  await T.step('read');
  const inBytes = loadStandard(input);
  const doc0 = await io.readBinary(inBytes);
  const total = countTriangles(doc0);
  const base = detectBase(doc0);
  if (!(base.baseUnits > 0)) fail('cannot determine the model size');
  const mmPerUnit = baseMM / base.baseUnits;
  const heightMM = base.heightUnits * mmPerUnit;
  reporter.emit({ t: 'diag', file: input, extensions: [], problems: [], inSize: inBytes.byteLength, triangles: total });
  log(
    `${base.round ? 'round base detected' : 'no round base (estimated from the footprint)'}: Ø ${base.baseUnits.toFixed(3)} units = ${baseMM} mm → miniature ${heightMM.toFixed(1)} mm tall`,
  );

  await T.step('search');
  const hi = Math.min(cap, total);
  const floor = Math.min(hi, 20_000);
  // Bracketing search: `best` = smallest count within tolerance and topology, `bad` = largest count
  // that is not. The next guess comes from an empirical model (deviation ∝ triangles^-0.6), kept inside
  // the bracket and limited to a factor 2 per step.
  let n = Math.min(hi, 300_000); // starting point, from benchmarks on Tripo miniatures
  let best = null;
  let bad = 0;
  const tried = new Set();
  const MAX_ITERATIONS = 7;
  for (let it = 0; it < MAX_ITERATIONS; it++) {
    n = Math.round(Math.max(floor, Math.min(hi, n)));
    if (tried.has(n)) break;
    tried.add(n);
    const doc = await io.readBinary(inBytes);
    const red = await reduceDocument(doc, n);
    const topo = topologyCheck(red);
    const dev = measure(red, doc, mmPerUnit, SAMPLES);
    T.sub((it + 1) / MAX_ITERATIONS);
    const feasible = dev.max <= toleranceMM && topo.ok;
    log(
      `attempt ${it + 1}: ${formatInt(red.totalAfter)} triangles → max deviation ${dev.max.toFixed(4)} mm${topo.ok ? '' : ' (topology worse: rejected)'}${feasible ? ' ✓' : ''}`,
    );
    if (feasible) {
      if (!best || red.totalAfter < best.got) best = { n, got: red.totalAfter, doc, red, dev, topo };
    } else {
      bad = Math.max(bad, n);
    }
    if (!feasible && n >= hi) break; // not enough even at the cap
    if (best && bad && best.n / bad < 1.12) break; // bracket already tight (≤ 12%)
    let next = topo.ok ? n * (dev.max / (toleranceMM * 0.92)) ** (1 / 0.6) : n * 1.15;
    next = Math.min(n * 2, Math.max(n / 2, next));
    if (best && bad) {
      if (next <= bad || next >= best.n) next = Math.sqrt(bad * best.n);
    } else if (best) {
      next = Math.min(next, best.n * 0.95);
    } else if (bad) {
      next = Math.max(next, bad * 1.05);
    }
    if (best && Math.abs(next - best.n) / best.n < 0.05) break;
    n = next;
  }
  if (!best) {
    // tolerance unreachable within the cap: use the cap if topology holds
    const doc = await io.readBinary(inBytes);
    const red = await reduceDocument(doc, hi);
    const topo = topologyCheck(red);
    if (!topo.ok) fail('every reduction tried would make the topology worse');
    best = { n: hi, got: red.totalAfter, doc, red, dev: measure(red, doc, mmPerUnit, SAMPLES), topo };
    log(`tolerance ${toleranceMM} mm not reachable within ${formatInt(hi)} triangles: using the cap`);
  }
  const { doc, red, topo } = best;
  await doc.transform(prune(PRUNE));
  const locked = red.report.reduce((s, r) => s + (r.lockedVertices || 0), 0);
  pass('topology', topologyLabel(topo, locked));

  await T.step('encode');
  const outBytes = await io.writeBinary(doc);

  await T.step('validate');
  const warnings = await validate(outBytes);
  pass('validate', `Official Khronos validator: 0 errors, ${warnings} warnings`);

  await T.step('deviation');
  // `best.dev` was measured with the full sample count. As a safety net, if the tolerance is still
  // exceeded, go up in triangles (≤ +20% per step) and measure again.
  let final = { doc, red, dev: best.dev, bytes: outBytes };
  let nFinal = best.n;
  let corrections = 0;
  while (final.dev.max > toleranceMM && nFinal < hi && corrections < 2) {
    corrections++;
    nFinal = Math.min(hi, Math.round(nFinal * Math.min(1.2, (final.dev.max / (toleranceMM * 0.9)) ** (1 / 0.6))));
    const d2 = await io.readBinary(inBytes);
    const r2 = await reduceDocument(d2, nFinal);
    if (!topologyCheck(r2).ok) {
      nFinal = Math.round(nFinal * 1.05);
      continue;
    }
    await d2.transform(prune(PRUNE));
    const dev2 = measure(r2, d2, mmPerUnit, SAMPLES, (f) => T.sub((corrections + f) / 3));
    log(`correction ${corrections}: ${formatInt(r2.totalAfter)} triangles → max deviation ${dev2.max.toFixed(4)} mm`);
    const bytes2 = await io.writeBinary(d2);
    await validate(bytes2);
    final = { doc: d2, red: r2, dev: dev2, bytes: bytes2 };
  }
  const dev = final.dev;
  const within = dev.max <= toleranceMM;
  const reason = within ? '' : nFinal >= hi ? ' (not reachable within the triangle cap)' : ' (slightly exceeded)';
  pass(
    'deviation',
    `Deviation at real size (base ${baseMM} mm): max ${dev.max.toFixed(3)} mm, 99% of the surface ≤ ${dev.p99.toFixed(3)} mm, mean ${dev.mean.toFixed(4)} mm (tolerance ${toleranceMM} mm)${reason}`,
  );

  await T.step('disk');
  const out = uniqueOutputPath(path.dirname(input), `${baseName(input)}_print-${baseMM}mm`);
  writeVerified(out, final.bytes, (tmp) => reporter.emit({ t: 'tmp', file: input, path: tmp }));
  pass('disk', 'Written to disk and read back: identical SHA-256 checksum');

  let preview = null;
  if (previewDir) {
    await T.step('preview');
    try {
      preview = await makePreview(final.bytes, io, input, previewDir);
    } catch (e) {
      reporter.emit({ t: 'log', file: input, msg: `preview not generated: ${e.message}` });
    }
  }
  T.end();
  const after = countTriangles(final.doc);
  reporter.say(
    `  ${formatInt(total)} → ${formatInt(after)} triangles · max ${dev.max.toFixed(3)} mm (tolerance ${toleranceMM}) · ${heightMM.toFixed(1)} mm tall`,
  );
  const root = final.doc.getRoot();
  return {
    status: 'OK',
    detail: out,
    out,
    preview,
    stats: {
      trisBefore: total,
      tris: after,
      verts: final.red.report.reduce((s, r) => s + r.pos.length / 3, 0),
      points: 0,
      textures: root.listTextures().length,
      materials: root.listMaterials().length,
      meshes: root.listMeshes().length,
      inSize: inBytes.byteLength,
      outSize: final.bytes.byteLength,
      maxErr: dev.max,
      devMaxMM: dev.max,
      devMeanMM: dev.mean,
      devP99MM: dev.p99,
      tolMM: toleranceMM,
      baseMM,
      baseDetected: base.round,
      heightMM,
      withinTolerance: within,
      finsRemoved: final.red.report.reduce((s, r) => s + r.finsRemoved, 0),
      iterations: tried.size + corrections,
    },
  };
}

export async function reduceFile(input, { io, reporter, previewDir }, { target }) {
  const T = makeTracker(REDUCE_STEPS, input, reporter);
  const pass = (id, label) => reporter.emit({ t: 'test', file: input, id, label, ok: true });
  reporter.say(`\n=== ${path.basename(input)} → ≤ ${formatInt(target)} triangles`);

  await T.step('read');
  const inBytes = loadStandard(input);
  const doc = await io.readBinary(inBytes);
  const before = countTriangles(doc);
  reporter.emit({
    t: 'diag',
    file: input,
    extensions: [],
    problems: [],
    inSize: inBytes.byteLength,
    triangles: before,
  });
  if (before <= target) {
    T.end();
    return { status: 'SKIP', detail: `already has ${formatInt(before)} triangles (≤ ${formatInt(target)})` };
  }

  await T.step('simplify');
  const red = await reduceDocument(doc, target, { onProgress: (f) => T.sub(f) });
  await doc.transform(prune(PRUNE));
  const after = countTriangles(doc);

  await T.step('topology');
  const topo = topologyCheck(red);
  if (topo.bNew > topo.bOld) fail(`the reduction would open holes (${topo.bNew - topo.bOld} more boundary edges)`);
  if (topo.nmNew > topo.nmOld) fail(`the reduction would create ${topo.nmNew - topo.nmOld} non-manifold edges`);
  if (topo.degenerate > 0) fail(`${topo.degenerate} degenerate triangles after reduction`);
  pass(
    'topology',
    topologyLabel(
      topo,
      red.report.reduce((s, r) => s + (r.lockedVertices || 0), 0),
    ),
  );

  await T.step('encode');
  const outBytes = await io.writeBinary(doc);

  await T.step('validate');
  const warnings = await validate(outBytes);
  pass('validate', `Official Khronos validator: 0 errors, ${warnings} warnings`);

  await T.step('deviation');
  // deviation relative to the model height (no real-world scale in this mode)
  let dev = { max: 0, mean: 0, p99: 0 };
  red.report.forEach((r, i) => {
    const h = hausdorff(r.pos0, r.idx0, r.pos, r.idx, {
      samples: 120_000,
      onProgress: (f) => T.sub((i + f) / red.report.length),
    });
    dev = { max: Math.max(dev.max, h.max), mean: Math.max(dev.mean, h.mean), p99: Math.max(dev.p99, h.p99) };
  });
  let lo = Number.POSITIVE_INFINITY;
  let hi = Number.NEGATIVE_INFINITY;
  for (const r of red.report) {
    for (let k = 1; k < r.pos0.length; k += 3) {
      lo = Math.min(lo, r.pos0[k]);
      hi = Math.max(hi, r.pos0[k]);
    }
  }
  const height = hi - lo;
  const rel = (x) => (height > 0 ? x / height : 0);
  if (rel(dev.max) > 0.01) {
    fail(`max deviation ${(rel(dev.max) * 100).toFixed(2)}% of the height: too much to keep the detail`);
  }
  pass(
    'deviation',
    `Deviation from the original surface: max ${(rel(dev.max) * 100).toFixed(3)}%, mean ${(rel(dev.mean) * 100).toFixed(4)}% of the model height`,
  );

  await T.step('disk');
  const out = uniqueOutputPath(path.dirname(input), `${baseName(input)}_reduced-${Math.round(target / 1000)}k`);
  writeVerified(out, outBytes, (tmp) => reporter.emit({ t: 'tmp', file: input, path: tmp }));
  pass('disk', 'Written to disk and read back: identical SHA-256 checksum');

  let preview = null;
  if (previewDir) {
    await T.step('preview');
    try {
      preview = await makePreview(outBytes, io, input, previewDir);
    } catch (e) {
      reporter.emit({ t: 'log', file: input, msg: `preview not generated: ${e.message}` });
    }
  }
  T.end();
  reporter.say(`  ${formatInt(before)} → ${formatInt(after)} triangles`);
  return {
    status: 'OK',
    detail: out,
    out,
    preview,
    stats: {
      trisBefore: before,
      tris: after,
      verts: red.report.reduce((s, r) => s + r.pos.length / 3, 0),
      points: 0,
      textures: doc.getRoot().listTextures().length,
      materials: doc.getRoot().listMaterials().length,
      meshes: doc.getRoot().listMeshes().length,
      inSize: inBytes.byteLength,
      outSize: outBytes.byteLength,
      maxErr: dev.max,
      devMaxRel: rel(dev.max),
      devMeanRel: rel(dev.mean),
      devP99Rel: rel(dev.p99),
      finsRemoved: red.report.reduce((s, r) => s + r.finsRemoved, 0),
    },
  };
}
