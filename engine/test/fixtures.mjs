// Synthetic test models, generated on the fly (no binary fixtures in the repository).

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Document, Logger, NodeIO } from '@gltf-transform/core';
import { EXTMeshoptCompression, KHRMeshQuantization } from '@gltf-transform/extensions';
import { meshopt } from '@gltf-transform/functions';
import { MeshoptEncoder } from 'meshoptimizer';

/** Closed UV sphere (single pole vertices, so it is watertight and manifold). */
export function sphere({ radius = 1, rings = 64, segments = 128, center = [0, 0, 0] } = {}) {
  const pos = [center[0], center[1] + radius, center[2]];
  for (let r = 1; r < rings; r++) {
    const phi = (Math.PI * r) / rings;
    for (let s = 0; s < segments; s++) {
      const theta = (2 * Math.PI * s) / segments;
      pos.push(
        center[0] + radius * Math.sin(phi) * Math.cos(theta),
        center[1] + radius * Math.cos(phi),
        center[2] + radius * Math.sin(phi) * Math.sin(theta),
      );
    }
  }
  pos.push(center[0], center[1] - radius, center[2]);
  const south = pos.length / 3 - 1;
  const ring = (r, s) => 1 + (r - 1) * segments + (s % segments);
  const idx = [];
  for (let s = 0; s < segments; s++) idx.push(0, ring(1, s + 1), ring(1, s));
  for (let r = 1; r < rings - 1; r++)
    for (let s = 0; s < segments; s++) {
      idx.push(ring(r, s), ring(r, s + 1), ring(r + 1, s));
      idx.push(ring(r, s + 1), ring(r + 1, s + 1), ring(r + 1, s));
    }
  for (let s = 0; s < segments; s++) idx.push(south, ring(rings - 1, s), ring(rings - 1, s + 1));
  return { pos, idx };
}

/** Closed cylinder along Y from y0 to y1 (capped, with centre vertices). */
export function cylinder({ radius = 1, y0 = 0, y1 = 0.1, segments = 256 } = {}) {
  const pos = [0, y0, 0, 0, y1, 0];
  for (let s = 0; s < segments; s++) {
    const a = (2 * Math.PI * s) / segments;
    pos.push(radius * Math.cos(a), y0, radius * Math.sin(a), radius * Math.cos(a), y1, radius * Math.sin(a));
  }
  const lo = (s) => 2 + 2 * (s % segments);
  const hi = (s) => 3 + 2 * (s % segments);
  const idx = [];
  for (let s = 0; s < segments; s++) {
    idx.push(0, lo(s), lo(s + 1));
    idx.push(1, hi(s + 1), hi(s));
    idx.push(lo(s), hi(s), lo(s + 1));
    idx.push(lo(s + 1), hi(s), hi(s + 1));
  }
  return { pos, idx };
}

export function merge(...parts) {
  const pos = [];
  const idx = [];
  for (const p of parts) {
    const offset = pos.length / 3;
    pos.push(...p.pos);
    for (const i of p.idx) idx.push(i + offset);
  }
  return { pos, idx };
}

function vertexNormals(pos, idx) {
  const n = new Float32Array(pos.length);
  for (let t = 0; t < idx.length; t += 3) {
    const [a, b, c] = [idx[t] * 3, idx[t + 1] * 3, idx[t + 2] * 3];
    const u = [pos[b] - pos[a], pos[b + 1] - pos[a + 1], pos[b + 2] - pos[a + 2]];
    const v = [pos[c] - pos[a], pos[c + 1] - pos[a + 1], pos[c + 2] - pos[a + 2]];
    const cr = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    for (const i of [a, b, c]) for (let k = 0; k < 3; k++) n[i + k] += cr[k];
  }
  for (let i = 0; i < n.length; i += 3) {
    const l = Math.hypot(n[i], n[i + 1], n[i + 2]) || 1;
    n[i] /= l;
    n[i + 1] /= l;
    n[i + 2] /= l;
  }
  return n;
}

/** Wraps a mesh into a glTF Document (one node, one primitive with POSITION + NORMAL). */
export function toDocument({ pos, idx }) {
  const doc = new Document().setLogger(new Logger(Logger.Verbosity.SILENT));
  const buffer = doc.createBuffer();
  const position = doc.createAccessor().setType('VEC3').setArray(new Float32Array(pos)).setBuffer(buffer);
  const normal = doc.createAccessor().setType('VEC3').setArray(vertexNormals(pos, idx)).setBuffer(buffer);
  const indices = doc.createAccessor().setType('SCALAR').setArray(new Uint32Array(idx)).setBuffer(buffer);
  const material = doc.createMaterial('clay').setBaseColorFactor([0.8, 0.7, 0.6, 1]);
  const prim = doc
    .createPrimitive()
    .setAttribute('POSITION', position)
    .setAttribute('NORMAL', normal)
    .setIndices(indices)
    .setMaterial(material);
  const mesh = doc.createMesh('model').addPrimitive(prim);
  doc.createScene().addChild(doc.createNode('model').setMesh(mesh));
  return doc;
}

/** A "miniature": a round base (Ø 2 units) with a sphere standing on it. */
export const miniature = () =>
  merge(
    cylinder({ radius: 1, y0: 0, y1: 0.1 }),
    sphere({ radius: 0.6, center: [0, 0.75, 0], rings: 96, segments: 192 }),
  );

export async function writePlain(file, mesh) {
  fs.writeFileSync(file, await new NodeIO().writeBinary(toDocument(mesh)));
  return file;
}

/** Same model, compressed with EXT_meshopt_compression + KHR_mesh_quantization (like AI generators). */
export async function writeMeshopt(file, mesh) {
  await MeshoptEncoder.ready;
  const io = new NodeIO()
    .registerExtensions([EXTMeshoptCompression, KHRMeshQuantization])
    .registerDependencies({ 'meshopt.encoder': MeshoptEncoder });
  const doc = toDocument(mesh);
  await doc.transform(meshopt({ encoder: MeshoptEncoder, level: 'high' }));
  fs.writeFileSync(file, await io.writeBinary(doc));
  return file;
}

export function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'glb-print-prep-test-'));
}
