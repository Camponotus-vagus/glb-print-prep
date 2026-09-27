// Triangle reduction for 3D printing.
//
// Algorithm: meshoptimizer `simplifyWithUpdate` — edge collapse driven by Quadric Error Metrics,
// attribute-aware, with optimal vertex placement. On Tripo models (1.9 M → 900k triangles) it halves
// the mean error of the classic `simplify` at the same speed, without introducing topological
// defects. After simplification we remove rare "fins" (pairs of coincident, opposite triangles) and
// protect thin regions where two surfaces would be pinched into a shared, non-manifold edge.

import { MeshoptSimplifier as S } from 'meshoptimizer';
import { topology } from './metrics.mjs';

// Attribute weights in the error metric (meshoptimizer README: normals ~0.5–1, UVs ~1+).
const ATTR = [
  ['NORMAL', 3, 0.5],
  ['TEXCOORD_0', 2, 1.0],
  ['COLOR_0', 3, 1.0],
];
const MAX_REL_ERROR = 1e-2; // never beyond 1% of the model extent: better to stop before the target

function floatArray(acc, comps) {
  const n = acc.getCount(),
    out = new Float32Array(n * comps),
    el = [];
  const src = acc.getArray();
  if (src instanceof Float32Array && acc.getElementSize() === comps) return new Float32Array(src);
  for (let i = 0; i < n; i++) {
    acc.getElement(i, el);
    for (let k = 0; k < comps; k++) out[i * comps + k] = el[k] ?? 0;
  }
  return out;
}

/** Removes duplicate triangles: opposite pairs (zero-thickness fins) → both; identical → one. */
export function removeFins(idx, remap) {
  // exact two-level key: (s0, s1) → number < 2^53, then s2 in a small bucket
  const seen = new Map(),
    drop = new Uint8Array(idx.length / 3);
  let removed = 0;
  const K = 4294967296;
  for (let t = 0; t < idx.length / 3; t++) {
    const a = remap[idx[t * 3]],
      b = remap[idx[t * 3 + 1]],
      c = remap[idx[t * 3 + 2]];
    let s0 = a,
      s1 = b,
      s2 = c,
      x;
    if (s0 > s1) {
      x = s0;
      s0 = s1;
      s1 = x;
    }
    if (s1 > s2) {
      x = s1;
      s1 = s2;
      s2 = x;
    }
    if (s0 > s1) {
      x = s0;
      s0 = s1;
      s1 = x;
    }
    // permutation parity → orientation
    const rot = (a === s0 && b === s1) || (b === s0 && c === s1) || (c === s0 && a === s1);
    const k = s0 * K + s1;
    const bucket = seen.get(k);
    if (!bucket) {
      seen.set(k, [s2, t, rot]);
      continue;
    }
    let found = -1;
    for (let i = 0; i < bucket.length; i += 3)
      if (bucket[i] === s2 && !drop[bucket[i + 1]]) {
        found = i;
        break;
      }
    if (found < 0) {
      bucket.push(s2, t, rot);
      continue;
    }
    const pt = bucket[found + 1];
    if (bucket[found + 2] !== rot) {
      drop[pt] = 1;
      drop[t] = 1;
      removed += 2;
    } else {
      drop[t] = 1;
      removed += 1;
    }
  }
  if (!removed) return { idx, removed };
  const out = new Uint32Array(idx.length - removed * 3);
  let j = 0;
  for (let t = 0; t < idx.length / 3; t++)
    if (!drop[t]) {
      out[j++] = idx[t * 3];
      out[j++] = idx[t * 3 + 1];
      out[j++] = idx[t * 3 + 2];
    }
  return { idx: out, removed };
}

/** Vertex → vertices adjacency (CSR) on position-welded vertices. */
function buildAdjacency(idx, nv, remap) {
  const deg = new Uint32Array(nv + 1);
  for (let t = 0; t < idx.length; t += 3)
    for (let e = 0; e < 3; e++) {
      deg[remap[idx[t + e]] + 1] += 2;
    }
  for (let i = 0; i < nv; i++) deg[i + 1] += deg[i];
  const fill = deg.slice(0, nv),
    list = new Uint32Array(deg[nv]);
  for (let t = 0; t < idx.length; t += 3)
    for (let e = 0; e < 3; e++) {
      const a = remap[idx[t + e]],
        b = remap[idx[t + ((e + 1) % 3)]];
      list[fill[a]++] = b;
      list[fill[b]++] = a;
    }
  return { off: deg, list };
}

/** Non-manifold edges (shared by >2 triangles) → set of involved vertices (original indices). */
function nonManifoldVertices(idx, remap) {
  const K = 4294967296,
    n = idx.length;
  const keys = new Float64Array(n),
    owner = new Uint32Array(n); // edge key + owning triangle
  for (let t = 0; t < n; t += 3)
    for (let e = 0; e < 3; e++) {
      const a = remap[idx[t + e]],
        b = remap[idx[t + ((e + 1) % 3)]];
      keys[t + e] = a < b ? a * K + b : b * K + a;
      owner[t + e] = t;
    }
  const order = Uint32Array.from({ length: n }, (_, i) => i).sort((x, y) => keys[x] - keys[y]);
  const verts = new Set(),
    edgeKeys = new Set();
  for (let i = 0; i < n; ) {
    let j = i + 1;
    while (j < n && keys[order[j]] === keys[order[i]]) j++;
    if (j - i > 2) {
      edgeKeys.add(keys[order[i]]);
      for (let q = i; q < j; q++) {
        const t = owner[order[q]];
        verts.add(idx[t]);
        verts.add(idx[t + 1]);
        verts.add(idx[t + 2]);
      }
    }
    i = j;
  }
  return { verts, edgeKeys };
}

export function countTriangles(doc) {
  let tris = 0;
  for (const m of doc.getRoot().listMeshes())
    for (const p of m.listPrimitives()) {
      if (p.getMode() !== 4) continue;
      tris += (p.getIndices()?.getCount() ?? p.getAttribute('POSITION')?.getCount() ?? 0) / 3;
    }
  return Math.round(tris);
}

/**
 * Simplifies all triangle primitives of `doc` in place towards `target` total triangles.
 * Returns, per primitive, the geometry before/after (for verification) and statistics.
 */
export async function reduceDocument(doc, target, { onProgress } = {}) {
  await S.ready;
  const prims = [];
  for (const m of doc.getRoot().listMeshes())
    for (const p of m.listPrimitives()) if (p.getMode() === 4 && p.getAttribute('POSITION')) prims.push(p);
  const total = countTriangles(doc);
  const ratio = Math.min(1, target / Math.max(1, total));
  const report = [];
  let done = 0;

  for (const p of prims) {
    const posAcc = p.getAttribute('POSITION');
    const nv = posAcc.getCount();
    const pos0 = floatArray(posAcc, 3);
    const idx0 = p.getIndices()
      ? new Uint32Array(p.getIndices().getArray())
      : Uint32Array.from({ length: nv }, (_, i) => i);
    const nt = idx0.length / 3;

    // attributes used by the metric (and updated by the simplifier)
    const used = ATTR.filter(([s]) => p.getAttribute(s));
    const stride = used.reduce((s, [, c]) => s + c, 0);
    const attrs = new Float32Array(Math.max(1, nv * stride));
    const weights = [];
    let off = 0;
    for (const [s, c, w] of used) {
      const a = floatArray(p.getAttribute(s), c);
      for (let i = 0; i < nv; i++) for (let k = 0; k < c; k++) attrs[i * stride + off + k] = a[i * c + k];
      for (let k = 0; k < c; k++) weights.push(w);
      off += c;
    }

    const primTarget = Math.max(1, Math.floor(nt * ratio));
    // non-manifold edges already present in the original (not counted as new)
    const nm0 = nonManifoldVertices(idx0, S.generatePositionRemap(pos0, 3)).edgeKeys.size;
    const attrs0 = attrs;
    const lock = new Uint8Array(nv);
    let pos,
      out,
      fin,
      err,
      locked = 0,
      rounds = 0,
      adj = null,
      remap0 = null;
    // Simplify; if new "pinches" appear (edges shared by 4 triangles where two thin parts touch),
    // lock the involved vertices and repeat: that region keeps its detail.
    for (;;) {
      pos = new Float32Array(pos0);
      const at = new Float32Array(attrs0);
      const idx = new Uint32Array(idx0);
      const [n, e] = stride
        ? S.simplifyWithUpdate(idx, pos, 3, at, stride, weights, lock, primTarget * 3, MAX_REL_ERROR)
        : S.simplifyWithUpdate(idx, pos, 3, new Float32Array(nv), 1, [0], lock, primTarget * 3, MAX_REL_ERROR);
      err = e;
      const rm = S.generatePositionRemap(pos, 3);
      fin = removeFins(idx.slice(0, n), rm);
      out = fin.idx;
      attrs.set(at);
      const nm = nonManifoldVertices(out, rm);
      if (nm.edgeKeys.size <= nm0 || rounds >= 4) break;
      // lock the involved vertices and their neighbourhood (2 rings) in the original mesh,
      // so that the pinch does not simply move to the adjacent vertices
      if (!adj) adj = buildAdjacency(idx0, nv, (remap0 ??= S.generatePositionRemap(pos0, 3)));
      let frontier = [...nm.verts].map((v) => remap0[v]);
      const mark = new Set(frontier);
      for (let ring = 0; ring < 2; ring++) {
        const nextF = [];
        for (const v of frontier)
          for (let j = adj.off[v]; j < adj.off[v + 1]; j++) {
            const w = adj.list[j];
            if (!mark.has(w)) {
              mark.add(w);
              nextF.push(w);
            }
          }
        frontier = nextF;
      }
      let added = 0;
      for (let v = 0; v < nv; v++)
        if (!lock[v] && mark.has(remap0[v])) {
          lock[v] = 1;
          added++;
        }
      if (!added) break;
      locked += added;
      rounds++;
    }
    const [remap, unique] = S.compactMesh(out);

    const compact = (src, comps, Ctor = Float32Array) => {
      const dst = new Ctor(unique * comps);
      for (let v = 0; v < nv; v++) {
        const r = remap[v];
        if (r === 0xffffffff || r >= unique) continue;
        for (let k = 0; k < comps; k++) dst[r * comps + k] = src[v * comps + k];
      }
      return dst;
    };
    const newPos = compact(pos, 3);
    const posOut = posAcc.clone().setArray(newPos).setNormalized(false);
    p.setAttribute('POSITION', posOut);

    // attributes updated by the simplifier
    off = 0;
    for (const [s, c] of used) {
      const a = new Float32Array(nv * c);
      for (let i = 0; i < nv; i++) for (let k = 0; k < c; k++) a[i * c + k] = attrs[i * stride + off + k];
      if (s === 'NORMAL')
        for (let i = 0; i < nv; i++) {
          const l = Math.hypot(a[i * 3], a[i * 3 + 1], a[i * 3 + 2]) || 1;
          a[i * 3] /= l;
          a[i * 3 + 1] /= l;
          a[i * 3 + 2] /= l;
        }
      const acc = p.getAttribute(s);
      p.setAttribute(s, acc.clone().setArray(compact(a, c)).setNormalized(false));
      off += c;
    }
    // other attributes (TANGENT, TEXCOORD_1, JOINTS…): original values of surviving vertices
    for (const s of p.listSemantics()) {
      if (s === 'POSITION' || used.some(([u]) => u === s)) continue;
      const acc = p.getAttribute(s),
        src = acc.getArray(),
        c = acc.getElementSize();
      p.setAttribute(s, acc.clone().setArray(compact(src, c, src.constructor)));
    }
    const IdxCtor = unique > 65535 ? Uint32Array : Uint16Array;
    const idxAcc = (p.getIndices() ?? posAcc)
      .clone()
      .setType('SCALAR')
      .setNormalized(false)
      .setArray(IdxCtor.from(out));
    p.setIndices(idxAcc);

    report.push({
      pos0,
      idx0,
      pos: newPos,
      idx: out,
      trisBefore: nt,
      trisAfter: out.length / 3,
      finsRemoved: fin.removed,
      relError: err,
      lockedVertices: locked,
      lockRounds: rounds,
    });
    done += nt;
    onProgress?.(done / total);
  }
  return {
    report,
    totalBefore: total,
    totalAfter: report.reduce((s, r) => s + r.trisAfter, 0) + (total - report.reduce((s, r) => s + r.trisBefore, 0)),
  };
}

/** Topology of a primitive, welded by position. */
export function primTopology(pos, idx) {
  return topology(idx, S.generatePositionRemap(pos instanceof Float32Array ? pos : new Float32Array(pos), 3));
}

// ---------------------------------------------------------------- real-world scale (miniatures on round bases)

/** Uniform world scale of the mesh containing the primitive (Tripo exports: 1). */
export function primWorldScale(p) {
  let s = 0;
  for (const mesh of p.listParents()) {
    if (mesh.propertyType !== 'Mesh') continue;
    for (const node of mesh.listParents()) {
      if (node.propertyType !== 'Node') continue;
      const m = node.getWorldMatrix();
      const det =
        m[0] * (m[5] * m[10] - m[6] * m[9]) - m[4] * (m[1] * m[10] - m[2] * m[9]) + m[8] * (m[1] * m[6] - m[2] * m[5]);
      s = Math.max(s, Math.cbrt(Math.abs(det)));
    }
  }
  return s || 1;
}

/**
 * Detects a round base: the lowest slice (3% of the height, glTF Y-up) with a ~circular footprint.
 * Without one, the diameter is estimated from the horizontal extent (the figure stands on its base).
 */
export function detectBase(doc) {
  const pts = [];
  for (const node of doc.getRoot().listNodes()) {
    const mesh = node.getMesh();
    if (!mesh) continue;
    const m = node.getWorldMatrix();
    for (const p of mesh.listPrimitives()) {
      if (p.getMode() !== 4) continue;
      const a = p.getAttribute('POSITION');
      if (!a) continue;
      const n = a.getCount(),
        step = Math.max(1, Math.floor(n / 200_000)),
        el = [0, 0, 0];
      for (let i = 0; i < n; i += step) {
        a.getElement(i, el);
        pts.push(
          m[0] * el[0] + m[4] * el[1] + m[8] * el[2] + m[12],
          m[1] * el[0] + m[5] * el[1] + m[9] * el[2] + m[13],
          m[2] * el[0] + m[6] * el[1] + m[10] * el[2] + m[14],
        );
      }
    }
  }
  const mn = [Infinity, Infinity, Infinity],
    mx = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < pts.length; i += 3)
    for (let k = 0; k < 3; k++) {
      mn[k] = Math.min(mn[k], pts[i + k]);
      mx[k] = Math.max(mx[k], pts[i + k]);
    }
  const H = mx[1] - mn[1];
  const lo = [Infinity, Infinity],
    hi = [-Infinity, -Infinity];
  let cnt = 0;
  for (let i = 0; i < pts.length; i += 3)
    if (pts[i + 1] < mn[1] + 0.03 * H) {
      cnt++;
      lo[0] = Math.min(lo[0], pts[i]);
      hi[0] = Math.max(hi[0], pts[i]);
      lo[1] = Math.min(lo[1], pts[i + 2]);
      hi[1] = Math.max(hi[1], pts[i + 2]);
    }
  const ex = hi[0] - lo[0],
    ez = hi[1] - lo[1];
  const round = cnt > 50 && Math.min(ex, ez) / Math.max(ex, ez) > 0.85;
  const baseUnits = round ? (ex + ez) / 2 : Math.max(mx[0] - mn[0], mx[2] - mn[2]);
  return { baseUnits, round, heightUnits: H };
}
