// Low-level GLB container helpers: parsing, structural checks, output paths.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fail } from './events.mjs';

/** Extensions that make a GLB unreadable for tools without the matching decoder. */
export const COMPRESSION_EXTENSIONS = [
  'EXT_meshopt_compression',
  'KHR_mesh_quantization',
  'KHR_draco_mesh_compression',
];

const MAGIC_GLTF = 0x46546c67;
const CHUNK_JSON = 0x4e4f534a;
const CHUNK_BIN = 0x004e4942;

/** Parses the GLB header and chunks without decoding any geometry. */
export function readGlbRaw(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.byteLength < 20) fail('file too short to be a GLB');
  if (dv.getUint32(0, true) !== MAGIC_GLTF) fail('missing "glTF" magic: not a GLB file');
  const version = dv.getUint32(4, true);
  const total = dv.getUint32(8, true);
  if (version !== 2) fail(`unsupported GLB version ${version}`);
  if (total !== bytes.byteLength) fail(`declared length ${total} ≠ file size ${bytes.byteLength}`);
  let offset = 12;
  let json = null;
  let binLength = 0;
  while (offset < total) {
    const length = dv.getUint32(offset, true);
    const type = dv.getUint32(offset + 4, true);
    if (offset + 8 + length > total) fail('chunk extends past the end of the file');
    if (type === CHUNK_JSON) {
      json = JSON.parse(Buffer.from(bytes.subarray(offset + 8, offset + 8 + length)).toString('utf8'));
    } else if (type === CHUNK_BIN) {
      binLength = length;
    }
    offset += 8 + length;
  }
  if (!json) fail('missing JSON chunk');
  return { json, binLength };
}

/** Compression extensions declared (used or required) by a glTF JSON document. */
export function compressionExtensions(json) {
  const used = new Set([...(json.extensionsUsed || []), ...(json.extensionsRequired || [])]);
  return COMPRESSION_EXTENSIONS.filter((e) => used.has(e));
}

/** Triangle count read from the JSON only (no geometry decoding). */
export function jsonTriangleCount(json) {
  let triangles = 0;
  for (const mesh of json.meshes || []) {
    for (const prim of mesh.primitives || []) {
      if ((prim.mode ?? 4) !== 4) continue;
      const accessor = json.accessors?.[prim.indices ?? prim.attributes?.POSITION];
      if (accessor) triangles += Math.floor(accessor.count / 3);
    }
  }
  return triangles;
}

/**
 * Structural problems that make simple GLB readers fail — e.g. the meshopt "fallback" buffer
 * without data, which produces "Invalid byteLength" errors in viewers without a meshopt decoder.
 */
export function structuralCheck(bytes) {
  const { json, binLength } = readGlbRaw(bytes);
  const problems = [];
  const buffers = json.buffers || [];
  buffers.forEach((buffer, i) => {
    if (buffer.uri === undefined) {
      if (i !== 0) problems.push(`buffer ${i} has no uri (only buffer 0 may live in the BIN chunk)`);
      else if (buffer.byteLength > binLength) {
        problems.push(`buffer 0 byteLength ${buffer.byteLength} > BIN chunk ${binLength}`);
      }
    }
    if (buffer.extensions && Object.keys(buffer.extensions).length) {
      problems.push(`buffer ${i} has extensions ${Object.keys(buffer.extensions)}`);
    }
  });
  (json.bufferViews || []).forEach((view, i) => {
    const buffer = buffers[view.buffer];
    if (!buffer) problems.push(`bufferView ${i} points to a missing buffer`);
    else if ((view.byteOffset || 0) + view.byteLength > buffer.byteLength) {
      problems.push(`bufferView ${i} extends past its buffer`);
    }
    if (view.extensions && Object.keys(view.extensions).length) {
      problems.push(`bufferView ${i} has extensions ${Object.keys(view.extensions)}`);
    }
  });
  for (const ext of compressionExtensions(json)) problems.push(`still uses ${ext}`);
  return { json, problems };
}

export const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

/** `dir/base.glb`, or `dir/base_2.glb`, `_3`… if taken. Never overwrites anything. */
export function uniqueOutputPath(dir, base) {
  let out = path.join(dir, `${base}.glb`);
  let n = 2;
  while (fs.existsSync(out) || fs.existsSync(`${out}.partial`)) out = path.join(dir, `${base}_${n++}.glb`);
  return out;
}

/** Input file name without extension and without suffixes added by previous runs. */
export function baseName(input) {
  return path
    .basename(input, path.extname(input))
    .replace(/_meshopt$/i, '')
    .replace(/_(reduced-\d+k|print-[\d.]+mm)(_\d+)?$/i, '');
}

/**
 * Atomic write with read-back verification: writes `out.partial`, re-reads it, compares the
 * SHA-256 and only then renames it. `onTemp` receives the temporary path (for cleanup on cancel).
 */
export function writeVerified(out, bytes, onTemp) {
  const tmp = `${out}.partial`;
  onTemp?.(tmp);
  fs.writeFileSync(tmp, bytes);
  if (sha256(new Uint8Array(fs.readFileSync(tmp))) !== sha256(bytes)) {
    fs.rmSync(tmp, { force: true });
    fail('the file written to disk does not match');
  }
  fs.renameSync(tmp, out);
}
