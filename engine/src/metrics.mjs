// Geometric quality metrics.
//
// - `hausdorff`: symmetric Hausdorff distance between two triangle meshes, estimated by
//   area-weighted surface sampling. Nearest-surface queries use a uniform grid (CSR layout)
//   over the target triangles plus an exact point–triangle distance.
// - `topology`: open (boundary) edges, non-manifold edges and degenerate triangles, computed
//   on vertices welded by position.

function bbox(pos) {
  const mn = [Infinity, Infinity, Infinity],
    mx = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < pos.length; i += 3)
    for (let k = 0; k < 3; k++) {
      const v = pos[i + k];
      if (v < mn[k]) mn[k] = v;
      if (v > mx[k]) mx[k] = v;
    }
  return { mn, mx };
}

class TriGrid {
  constructor(pos, idx, box) {
    this.pos = pos;
    this.idx = idx;
    const nt = idx.length / 3;
    const ext = [0, 1, 2].map((k) => Math.max(box.mx[k] - box.mn[k], 1e-9));
    const vol = ext[0] * ext[1] * ext[2];
    const cell = Math.cbrt(vol / Math.max(1, nt / 2)) || 1; // ~2 triangles per cell
    this.cell = cell;
    this.mn = box.mn;
    this.res = ext.map((e) => Math.min(1024, Math.max(1, Math.ceil(e / cell))));
    const [rx, ry, rz] = this.res;
    const ncell = rx * ry * rz;
    const counts = new Uint32Array(ncell + 1);
    const cellRange = (t, fn) => {
      const a = idx[t * 3] * 3,
        b = idx[t * 3 + 1] * 3,
        c = idx[t * 3 + 2] * 3;
      const lo = [0, 0, 0],
        hi = [0, 0, 0];
      for (let k = 0; k < 3; k++) {
        const vmin = Math.min(pos[a + k], pos[b + k], pos[c + k]),
          vmax = Math.max(pos[a + k], pos[b + k], pos[c + k]);
        lo[k] = Math.min(this.res[k] - 1, Math.max(0, Math.floor((vmin - this.mn[k]) / cell)));
        hi[k] = Math.min(this.res[k] - 1, Math.max(0, Math.floor((vmax - this.mn[k]) / cell)));
      }
      for (let z = lo[2]; z <= hi[2]; z++)
        for (let y = lo[1]; y <= hi[1]; y++) for (let x = lo[0]; x <= hi[0]; x++) fn((z * ry + y) * rx + x);
    };
    for (let t = 0; t < nt; t++) cellRange(t, (c) => counts[c + 1]++);
    for (let i = 0; i < ncell; i++) counts[i + 1] += counts[i];
    const fill = counts.slice(0, ncell);
    const list = new Uint32Array(counts[ncell]);
    for (let t = 0; t < nt; t++)
      cellRange(t, (c) => {
        list[fill[c]++] = t;
      });
    this.offsets = counts;
    this.list = list;
    this.stamp = new Uint32Array(nt);
    this.q = 0;
  }

  // Minimum point → surface distance (search in growing rings of cells).
  nearest(px, py, pz) {
    const { cell, mn, res, offsets, list, idx, pos } = this;
    const [rx, ry, rz] = res;
    const cx = Math.min(rx - 1, Math.max(0, Math.floor((px - mn[0]) / cell)));
    const cy = Math.min(ry - 1, Math.max(0, Math.floor((py - mn[1]) / cell)));
    const cz = Math.min(rz - 1, Math.max(0, Math.floor((pz - mn[2]) / cell)));
    let best = Infinity;
    const q = ++this.q;
    const maxR = Math.max(rx, ry, rz);
    for (let r = 0; r <= maxR; r++) {
      // once a candidate is known, stop after the ring that covers its distance
      if (best !== Infinity && (r - 1) * cell > Math.sqrt(best)) break;
      for (let z = cz - r; z <= cz + r; z++) {
        if (z < 0 || z >= rz) continue;
        for (let y = cy - r; y <= cy + r; y++) {
          if (y < 0 || y >= ry) continue;
          const shell = Math.abs(z - cz) === r || Math.abs(y - cy) === r;
          for (let x = cx - r; x <= cx + r; x += shell || r === 0 ? 1 : 2 * r) {
            if (x < 0 || x >= rx) continue;
            const c = (z * ry + y) * rx + x;
            if (offsets[c] === offsets[c + 1]) continue;
            if (best !== Infinity) {
              // point → cell box distance: skip cells that cannot improve the best candidate
              const x0 = mn[0] + x * cell,
                y0 = mn[1] + y * cell,
                z0 = mn[2] + z * cell;
              const dx = px < x0 ? x0 - px : px > x0 + cell ? px - x0 - cell : 0;
              const dy = py < y0 ? y0 - py : py > y0 + cell ? py - y0 - cell : 0;
              const dz = pz < z0 ? z0 - pz : pz > z0 + cell ? pz - z0 - cell : 0;
              if (dx * dx + dy * dy + dz * dz >= best) continue;
            }
            for (let j = offsets[c]; j < offsets[c + 1]; j++) {
              const t = list[j];
              if (this.stamp[t] === q) continue;
              this.stamp[t] = q;
              const d = pointTri2(px, py, pz, pos, idx[t * 3] * 3, idx[t * 3 + 1] * 3, idx[t * 3 + 2] * 3);
              if (d < best) best = d;
            }
          }
        }
      }
    }
    return Math.sqrt(best);
  }
}

// Squared point–triangle distance (Ericson, Real-Time Collision Detection, §5.1.5).
function pointTri2(px, py, pz, P, a, b, c) {
  const ax = P[a],
    ay = P[a + 1],
    az = P[a + 2];
  const abx = P[b] - ax,
    aby = P[b + 1] - ay,
    abz = P[b + 2] - az;
  const acx = P[c] - ax,
    acy = P[c + 1] - ay,
    acz = P[c + 2] - az;
  const apx = px - ax,
    apy = py - ay,
    apz = pz - az;
  const d1 = abx * apx + aby * apy + abz * apz,
    d2 = acx * apx + acy * apy + acz * apz;
  let qx, qy, qz;
  if (d1 <= 0 && d2 <= 0) {
    qx = ax;
    qy = ay;
    qz = az;
  } else {
    const bpx = px - P[b],
      bpy = py - P[b + 1],
      bpz = pz - P[b + 2];
    const d3 = abx * bpx + aby * bpy + abz * bpz,
      d4 = acx * bpx + acy * bpy + acz * bpz;
    if (d3 >= 0 && d4 <= d3) {
      qx = P[b];
      qy = P[b + 1];
      qz = P[b + 2];
    } else {
      const vc = d1 * d4 - d3 * d2;
      if (vc <= 0 && d1 >= 0 && d3 <= 0) {
        const v = d1 / (d1 - d3);
        qx = ax + v * abx;
        qy = ay + v * aby;
        qz = az + v * abz;
      } else {
        const cpx = px - P[c],
          cpy = py - P[c + 1],
          cpz = pz - P[c + 2];
        const d5 = abx * cpx + aby * cpy + abz * cpz,
          d6 = acx * cpx + acy * cpy + acz * cpz;
        if (d6 >= 0 && d5 <= d6) {
          qx = P[c];
          qy = P[c + 1];
          qz = P[c + 2];
        } else {
          const vb = d5 * d2 - d1 * d6;
          if (vb <= 0 && d2 >= 0 && d6 <= 0) {
            const w = d2 / (d2 - d6);
            qx = ax + w * acx;
            qy = ay + w * acy;
            qz = az + w * acz;
          } else {
            const va = d3 * d6 - d5 * d4;
            if (va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0) {
              const w = (d4 - d3) / (d4 - d3 + (d5 - d6));
              qx = P[b] + w * (P[c] - P[b]);
              qy = P[b + 1] + w * (P[c + 1] - P[b + 1]);
              qz = P[b + 2] + w * (P[c + 2] - P[b + 2]);
            } else {
              const den = 1 / (va + vb + vc),
                v = vb * den,
                w = vc * den;
              qx = ax + abx * v + acx * w;
              qy = ay + aby * v + acy * w;
              qz = az + abz * v + acz * w;
            }
          }
        }
      }
    }
  }
  const dx = px - qx,
    dy = py - qy,
    dz = pz - qz;
  return dx * dx + dy * dy + dz * dz;
}

// Deterministic PRNG (LCG): repeatable measurements across runs.
function rng(seed) {
  let s = seed >>> 0;
  return () => (s = (s * 1664525 + 1013904223) >>> 0) / 4294967296;
}

// Surface samples, area-weighted.
function samplePoints(pos, idx, n, seed = 1) {
  const nt = idx.length / 3,
    cdf = new Float64Array(nt);
  let acc = 0;
  for (let t = 0; t < nt; t++) {
    const a = idx[t * 3] * 3,
      b = idx[t * 3 + 1] * 3,
      c = idx[t * 3 + 2] * 3;
    const ux = pos[b] - pos[a],
      uy = pos[b + 1] - pos[a + 1],
      uz = pos[b + 2] - pos[a + 2];
    const vx = pos[c] - pos[a],
      vy = pos[c + 1] - pos[a + 1],
      vz = pos[c + 2] - pos[a + 2];
    const cx = uy * vz - uz * vy,
      cy = uz * vx - ux * vz,
      cz = ux * vy - uy * vx;
    acc += Math.sqrt(cx * cx + cy * cy + cz * cz);
    cdf[t] = acc;
  }
  const R = rng(seed),
    out = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    const r = R() * acc;
    let lo = 0,
      hi = nt - 1;
    while (lo < hi) {
      const m = (lo + hi) >> 1;
      if (cdf[m] < r) lo = m + 1;
      else hi = m;
    }
    let u = R(),
      v = R();
    if (u + v > 1) {
      u = 1 - u;
      v = 1 - v;
    }
    const a = idx[lo * 3] * 3,
      b = idx[lo * 3 + 1] * 3,
      c = idx[lo * 3 + 2] * 3;
    for (let k = 0; k < 3; k++)
      out[i * 3 + k] = pos[a + k] + u * (pos[b + k] - pos[a + k]) + v * (pos[c + k] - pos[a + k]);
  }
  return out;
}

function oneWay(samples, grid, onProgress) {
  const n = samples.length / 3,
    d = new Float32Array(n);
  let sum = 0,
    sum2 = 0,
    max = 0;
  for (let i = 0; i < n; i++) {
    const x = grid.nearest(samples[i * 3], samples[i * 3 + 1], samples[i * 3 + 2]);
    d[i] = x;
    sum += x;
    sum2 += x * x;
    if (x > max) max = x;
    if (onProgress && (i & 0x3fff) === 0) onProgress(i / n);
  }
  d.sort();
  return { max, mean: sum / n, rms: Math.sqrt(sum2 / n), p99: d[Math.floor(n * 0.99)] };
}

/**
 * Symmetric Hausdorff distance estimate between mesh A and mesh B (flat position/index arrays).
 * Returns distances in model units: { max, mean, rms, p99, diag } where diag is A's bbox diagonal.
 */
export function hausdorff(posA, idxA, posB, idxB, { samples = 150_000, onProgress } = {}) {
  const box = bbox(posA);
  const diag = Math.hypot(box.mx[0] - box.mn[0], box.mx[1] - box.mn[1], box.mx[2] - box.mn[2]);
  const gridB = new TriGrid(posB, idxB, bbox(posB));
  const gridA = new TriGrid(posA, idxA, box);
  const ab = oneWay(samplePoints(posA, idxA, samples, 1), gridB, onProgress && ((f) => onProgress(f / 2)));
  const ba = oneWay(samplePoints(posB, idxB, samples, 2), gridA, onProgress && ((f) => onProgress(0.5 + f / 2)));
  return {
    diag,
    max: Math.max(ab.max, ba.max),
    mean: (ab.mean + ba.mean) / 2,
    rms: Math.sqrt((ab.rms ** 2 + ba.rms ** 2) / 2),
    p99: Math.max(ab.p99, ba.p99),
  };
}

/**
 * Topology statistics after welding by position (`remap` from meshopt generatePositionRemap):
 * boundary edges = holes, non-manifold edges = edges shared by more than two triangles.
 * Edge keys are sorted in a Float64Array, which is much faster than a Map for millions of edges.
 */
export function topology(idx, remap) {
  const nt = idx.length / 3,
    keys = new Float64Array(nt * 3);
  let n = 0,
    degenerate = 0;
  const K = 4294967296;
  for (let t = 0; t < idx.length; t += 3) {
    const a = remap[idx[t]],
      b = remap[idx[t + 1]],
      c = remap[idx[t + 2]];
    if (a === b || b === c || a === c) {
      degenerate++;
      continue;
    }
    keys[n++] = a < b ? a * K + b : b * K + a;
    keys[n++] = b < c ? b * K + c : c * K + b;
    keys[n++] = c < a ? c * K + a : a * K + c;
  }
  const e = keys.subarray(0, n).sort();
  let boundary = 0,
    nonManifold = 0;
  for (let i = 0; i < n; ) {
    let j = i + 1;
    while (j < n && e[j] === e[i]) j++;
    const run = j - i;
    if (run === 1) boundary++;
    else if (run > 2) nonManifold++;
    i = j;
  }
  return { boundaryEdges: boundary, nonManifoldEdges: nonManifold, degenerate };
}
