// Content equivalence between the original (decoded) document and the repaired one.

import { fail, tick } from './events.mjs';
import { sha256 } from './glb.mjs';

function primitiveList(doc) {
  const out = [];
  doc
    .getRoot()
    .listMeshes()
    .forEach((mesh, mi) => {
      mesh.listPrimitives().forEach((p, pi) => {
        out.push({ id: `mesh ${mi} "${mesh.getName()}" primitive ${pi}`, p });
      });
    });
  return out;
}

function counts(root) {
  return {
    nodes: root.listNodes().length,
    meshes: root.listMeshes().length,
    materials: root.listMaterials().length,
    textures: root.listTextures().length,
    animations: root.listAnimations().length,
    skins: root.listSkins().length,
  };
}

/**
 * Verifies that `fixed` holds the same content as `orig`: object counts, node world matrices,
 * every vertex attribute element by element (tolerance 1e-5, indices exact), materials and
 * texture bytes (SHA-256). Throws on the first difference; returns statistics otherwise.
 */
export async function compareDocuments(orig, fixed, onProgress) {
  const ro = orig.getRoot();
  const rf = fixed.getRoot();
  const co = counts(ro);
  const cf = counts(rf);
  for (const key of Object.keys(co)) if (co[key] !== cf[key]) fail(`${key} count: ${co[key]} ≠ ${cf[key]}`);

  const worldFixed = rf.listNodes().map((n) => n.getWorldMatrix());
  ro.listNodes().forEach((node, i) => {
    node.getWorldMatrix().forEach((v, k) => {
      if (Math.abs(v - worldFixed[i][k]) > 1e-5 * Math.max(1, Math.abs(v))) fail(`node ${i} matrix differs`);
    });
  });

  const po = primitiveList(orig);
  const pf = primitiveList(fixed);
  if (po.length !== pf.length) fail(`primitives: ${po.length} ≠ ${pf.length}`);

  const pairs = [];
  po.forEach(({ id, p }, i) => {
    const q = pf[i].p;
    if (p.getMode() !== q.getMode()) fail(`${id}: draw mode differs`);
    const sa = p.listSemantics().sort().join(',');
    const sb = q.listSemantics().sort().join(',');
    if (sa !== sb) fail(`${id}: attributes ${sa} ≠ ${sb}`);
    if (p.getMaterial()?.getName() !== q.getMaterial()?.getName()) fail(`${id}: material differs`);
    for (const s of p.listSemantics()) pairs.push([p.getAttribute(s), q.getAttribute(s), `${id} ${s}`, 1e-5]);
    if (p.getIndices() || q.getIndices()) pairs.push([p.getIndices(), q.getIndices(), `${id} indices`, 0]);
  });

  const totalWork = pairs.reduce((s, [a]) => s + (a?.getCount() || 0), 0) || 1;
  let done = 0;
  let maxErr = 0;
  let lastYield = performance.now();
  for (const [a, b, label, tol] of pairs) {
    if (!a || !b) fail(`${label}: present in only one of the two files`);
    if (a.getCount() !== b.getCount()) fail(`${label}: count ${a.getCount()} ≠ ${b.getCount()}`);
    if (a.getElementSize() !== b.getElementSize()) fail(`${label}: type ${a.getType()} ≠ ${b.getType()}`);
    const ea = [];
    const eb = [];
    let err = 0;
    for (let i = 0, n = a.getCount(); i < n; i++) {
      a.getElement(i, ea);
      b.getElement(i, eb);
      for (let k = 0; k < ea.length; k++) {
        const d = Math.abs(ea[k] - eb[k]);
        if (d > err) err = d;
      }
      if ((i & 0x3fff) === 0 && performance.now() - lastYield > 100) {
        onProgress?.((done + i) / totalWork);
        await tick();
        lastYield = performance.now();
      }
    }
    if (err > tol) fail(`${label}: max difference ${err} exceeds tolerance ${tol}`);
    if (err > maxErr) maxErr = err;
    done += a.getCount();
  }

  ro.listTextures().forEach((t, i) => {
    const a = t.getImage();
    const b = rf.listTextures()[i].getImage();
    if (!a || !b || sha256(a) !== sha256(b)) fail(`texture ${i} "${t.getName()}" differs`);
  });

  let verts = 0;
  let tris = 0;
  let points = 0;
  for (const { p } of po) {
    verts += p.getAttribute('POSITION')?.getCount() || 0;
    const n = p.getIndices()?.getCount() ?? p.getAttribute('POSITION')?.getCount() ?? 0;
    if (p.getMode() === 4) tris += n / 3;
    else if (p.getMode() === 0) points += n;
  }
  return { ...co, primitives: po.length, verts, tris: Math.round(tris), points, maxErr };
}
