// Repair: decompress meshopt / quantization / Draco into a standard GLB and verify it.
// The input file is never modified or deleted.

import fs from 'node:fs';
import path from 'node:path';
import { EXTMeshoptCompression, KHRDracoMeshCompression, KHRMeshQuantization } from '@gltf-transform/extensions';
import { dequantize, unpartition } from '@gltf-transform/functions';
import validator from 'gltf-validator';
import { compareDocuments } from './compare.mjs';
import { fail, formatInt, makeTracker } from './events.mjs';
import {
  compressionExtensions,
  jsonTriangleCount,
  readGlbRaw,
  structuralCheck,
  uniqueOutputPath,
  writeVerified,
} from './glb.mjs';
import { createPlainIO } from './io.mjs';
import { makePreview } from './preview.mjs';

export const REPAIR_STEPS = [
  ['read', 'Reading and diagnosis', 0.01],
  ['decode', 'Decompressing (meshopt/Draco)', 0.05],
  ['convert', 'Converting to standard glTF', 0.02],
  ['encode', 'Encoding GLB in memory', 0.15],
  ['structure', 'Test: container structure', 0.01],
  ['plain', 'Test: opens without decoders', 0.02],
  ['validate', 'Test: Khronos validator', 0.14],
  ['compare', 'Test: identical to the original', 0.33],
  ['disk', 'Writing to disk and checksum', 0.13],
  ['preview', 'Preview', 0.14],
];

/** `model_meshopt.glb` → `model.glb`; anything else → `model_fixed.glb` (never overwrites). */
export function repairedPathFor(input) {
  const stem = path.basename(input, path.extname(input));
  const base = /_meshopt$/i.test(stem) ? stem.replace(/_meshopt$/i, '') : `${stem}_fixed`;
  return uniqueOutputPath(path.dirname(input), base);
}

export async function repairFile(input, { io, reporter, previewDir }) {
  const T = makeTracker(REPAIR_STEPS, input, reporter);
  const tests = [];
  const pass = (id, label) => {
    tests.push(label);
    reporter.emit({ t: 'test', file: input, id, label, ok: true });
  };
  reporter.say(`\n=== ${path.basename(input)}`);

  await T.step('read');
  if (!fs.existsSync(input)) fail('file not found');
  if (path.extname(input).toLowerCase() !== '.glb') fail('not a .glb file');
  const inBytes = new Uint8Array(fs.readFileSync(input));
  const { json } = readGlbRaw(inBytes);
  const found = compressionExtensions(json);
  const pre = structuralCheck(inBytes);
  const triangles = jsonTriangleCount(json);
  reporter.emit({
    t: 'diag',
    file: input,
    extensions: found,
    problems: pre.problems,
    inSize: inBytes.byteLength,
    triangles,
  });
  if (!found.length && !pre.problems.length) {
    const required = json.extensionsRequired || [];
    const note = required.length ? ` (uses ${required.join(', ')}, which is not compression)` : '';
    T.end();
    return {
      status: 'SKIP',
      detail: `no compression to remove: already opens everywhere${note}`,
      stats: {
        verts: 0,
        tris: triangles,
        points: 0,
        textures: (json.textures || []).length,
        materials: (json.materials || []).length,
        meshes: (json.meshes || []).length,
        inSize: inBytes.byteLength,
        outSize: 0,
        maxErr: 0,
      },
    };
  }
  reporter.say(`Diagnosis: ${found.join(', ') || 'no compression'}; ${pre.problems.length} structural problems`);

  await T.step('decode');
  const orig = await io.readBinary(inBytes);
  const doc = await io.readBinary(inBytes);

  await T.step('convert');
  await doc.transform(dequantize({ pattern: /.*/ }), unpartition());
  for (const E of [EXTMeshoptCompression, KHRMeshQuantization, KHRDracoMeshCompression]) {
    for (const ext of doc.getRoot().listExtensionsUsed()) if (ext instanceof E) ext.dispose();
  }

  await T.step('encode');
  const outBytes = await io.writeBinary(doc);

  await T.step('structure');
  const post = structuralCheck(outBytes);
  if (post.problems.length) fail(`structural test failed: ${post.problems.join('; ')}`);
  pass('structure', 'Consistent GLB structure: a single buffer, no compression extensions');

  await T.step('plain');
  const reread = await createPlainIO().readBinary(outBytes);
  if (!reread.getRoot().listMeshes().length) fail('re-read without decoders: no meshes');
  pass('plain', 'Opens with a plain glTF reader (no decoders)');

  await T.step('validate');
  const report = await validator.validateBytes(outBytes, { maxIssues: 50, format: 'glb' });
  if (report.issues.numErrors > 0) {
    const examples = report.issues.messages
      .filter((m) => m.severity === 0)
      .slice(0, 3)
      .map((m) => m.message)
      .join(' | ');
    fail(`Khronos validator: ${report.issues.numErrors} errors, e.g. ${examples}`);
  }
  pass('validate', `Official Khronos validator: 0 errors, ${report.issues.numWarnings} warnings`);

  await T.step('compare');
  const cmp = await compareDocuments(orig, await io.readBinary(outBytes), (f) => T.sub(f));
  const geometry = [cmp.tris && `${formatInt(cmp.tris)} triangles`, cmp.points && `${formatInt(cmp.points)} points`]
    .filter(Boolean)
    .join(', ');
  pass(
    'compare',
    `Identical to the original: ${formatInt(cmp.verts)} vertices, ${geometry}, ${cmp.textures} textures (max error ${cmp.maxErr.toExponential(1)})`,
  );

  await T.step('disk');
  const out = repairedPathFor(input);
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

  for (const t of tests) reporter.say(`  ✓ ${t}`);
  reporter.say(`  ${(inBytes.byteLength / 1e6).toFixed(1)} MB → ${(outBytes.byteLength / 1e6).toFixed(1)} MB`);
  return {
    status: 'OK',
    detail: out,
    out,
    preview,
    stats: { ...cmp, inSize: inBytes.byteLength, outSize: outBytes.byteLength },
  };
}
