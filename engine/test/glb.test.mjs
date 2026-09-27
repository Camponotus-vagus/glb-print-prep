import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { before, test } from 'node:test';
import { EngineError } from '../src/events.mjs';
import {
  baseName,
  compressionExtensions,
  jsonTriangleCount,
  readGlbRaw,
  structuralCheck,
  uniqueOutputPath,
  writeVerified,
} from '../src/glb.mjs';
import { repairedPathFor } from '../src/repair.mjs';
import { sphere, tempDir, writeMeshopt, writePlain } from './fixtures.mjs';

let dir;
let plain;
let compressed;
before(async () => {
  dir = tempDir();
  plain = await writePlain(path.join(dir, 'ball.glb'), sphere({ rings: 16, segments: 32 }));
  compressed = await writeMeshopt(path.join(dir, 'ball_meshopt.glb'), sphere({ rings: 16, segments: 32 }));
});

test('readGlbRaw parses the JSON chunk', () => {
  const { json } = readGlbRaw(new Uint8Array(fs.readFileSync(plain)));
  assert.equal(json.asset.version, '2.0');
  assert.equal(jsonTriangleCount(json), 2 * 32 * 15);
});

test('compression extensions are detected; a plain file has none', () => {
  const plainJson = readGlbRaw(new Uint8Array(fs.readFileSync(plain))).json;
  const meshoptJson = readGlbRaw(new Uint8Array(fs.readFileSync(compressed))).json;
  assert.deepEqual(compressionExtensions(plainJson), []);
  assert.ok(compressionExtensions(meshoptJson).includes('EXT_meshopt_compression'));
});

test('structuralCheck reports no problems for a plain GLB', () => {
  assert.deepEqual(structuralCheck(new Uint8Array(fs.readFileSync(plain))).problems, []);
});

test('garbage is rejected with an EngineError', () => {
  assert.throws(() => readGlbRaw(new TextEncoder().encode('definitely not a glb file')), EngineError);
});

test('baseName strips suffixes added by previous runs', () => {
  assert.equal(baseName('/x/model_meshopt.glb'), 'model');
  assert.equal(baseName('/x/model_print-32mm.glb'), 'model');
  assert.equal(baseName('/x/model_print-18.9mm_2.glb'), 'model');
  assert.equal(baseName('/x/model_reduced-300k.glb'), 'model');
  assert.equal(baseName('/x/model.glb'), 'model');
});

test('output paths never overwrite existing files', () => {
  assert.equal(uniqueOutputPath(dir, 'ball'), path.join(dir, 'ball_2.glb'));
  assert.equal(uniqueOutputPath(dir, 'fresh'), path.join(dir, 'fresh.glb'));
  assert.equal(repairedPathFor(path.join(dir, 'ball_meshopt.glb')), path.join(dir, 'ball_2.glb'));
  assert.equal(repairedPathFor(path.join(dir, 'other.glb')), path.join(dir, 'other_fixed.glb'));
});

test('writeVerified writes atomically and leaves no partial file', () => {
  const out = path.join(dir, 'written.glb');
  const bytes = new Uint8Array([1, 2, 3, 4]);
  let temp;
  writeVerified(out, bytes, (t) => {
    temp = t;
  });
  assert.equal(temp, `${out}.partial`);
  assert.deepEqual(new Uint8Array(fs.readFileSync(out)), bytes);
  assert.equal(fs.existsSync(temp), false);
});
