// Lightweight preview copies for thumbnails (~50k triangles or ≤60k points, textures unchanged).

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { compactPrimitive, prune } from '@gltf-transform/functions';
import { MeshoptSimplifier } from 'meshoptimizer';

const PREVIEW_TRIANGLES = 50_000;
const PREVIEW_POINTS = 60_000;

export async function makePreview(bytes, io, input, previewDir) {
  fs.mkdirSync(previewDir, { recursive: true });
  const doc = await io.readBinary(bytes);
  let tris = 0;
  let points = 0;
  for (const mesh of doc.getRoot().listMeshes()) {
    for (const p of mesh.listPrimitives()) {
      const n = p.getIndices()?.getCount() ?? p.getAttribute('POSITION')?.getCount() ?? 0;
      if (p.getMode() === 4) tris += n / 3;
      else if (p.getMode() === 0) points += n;
    }
  }
  if (tris > PREVIEW_TRIANGLES) {
    // simplifySloppy: ~5× faster than the topological simplifier; plenty for a thumbnail.
    await MeshoptSimplifier.ready;
    const ratio = PREVIEW_TRIANGLES / tris;
    for (const mesh of doc.getRoot().listMeshes()) {
      for (const p of mesh.listPrimitives()) {
        const idx = p.getIndices();
        if (p.getMode() !== 4 || !idx) continue;
        const target = Math.max(3, Math.floor((idx.getCount() * ratio) / 3) * 3);
        const pos = p.getAttribute('POSITION').getArray();
        const positions = pos instanceof Float32Array ? pos : new Float32Array(pos);
        const [simplified] = MeshoptSimplifier.simplifySloppy(
          new Uint32Array(idx.getArray()),
          positions,
          3,
          null,
          target,
          0.01,
        );
        idx.setArray(simplified);
        compactPrimitive(p);
      }
    }
    await doc.transform(prune({ keepSolidTextures: true }));
  }
  if (points > PREVIEW_POINTS) {
    // uniform subsampling of point clouds
    const step = Math.ceil(points / PREVIEW_POINTS);
    for (const mesh of doc.getRoot().listMeshes()) {
      for (const p of mesh.listPrimitives()) {
        if (p.getMode() !== 0 || p.getIndices()) continue;
        for (const semantic of p.listSemantics()) {
          const a = p.getAttribute(semantic);
          const size = a.getElementSize();
          const src = a.getArray();
          const n = Math.ceil(a.getCount() / step);
          const dst = new src.constructor(n * size);
          for (let i = 0; i < n; i++) for (let k = 0; k < size; k++) dst[i * size + k] = src[i * step * size + k];
          const accessor = doc
            .createAccessor()
            .setType(a.getType())
            .setArray(dst)
            .setNormalized(a.getNormalized())
            .setBuffer(a.getBuffer());
          p.setAttribute(semantic, accessor);
        }
      }
    }
    await doc.transform(prune({ keepSolidTextures: true }));
  }
  const name = `${crypto
    .createHash('sha1')
    .update(input + Date.now())
    .digest('hex')
    .slice(0, 16)}.glb`;
  const out = path.join(previewDir, name);
  fs.writeFileSync(out, await io.writeBinary(doc));
  return out;
}
