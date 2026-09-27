import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { parseCli } from '../src/cli.mjs';
import { miniature, tempDir, writeMeshopt, writePlain } from './fixtures.mjs';

const BIN = fileURLToPath(new URL('../bin/glb-print-prep.mjs', import.meta.url));

function run(args) {
  const r = spawnSync(process.execPath, [BIN, ...args], { encoding: 'utf8', timeout: 300_000 });
  const events = args.includes('--json')
    ? r.stdout
        .split('\n')
        .filter(Boolean)
        .map((line) => JSON.parse(line))
    : [];
  return { code: r.status, stdout: r.stdout, stderr: r.stderr, events };
}
const resultOf = (events) => events.filter((e) => e.t === 'result');

let dir;
let input;
let plainInput;
before(async () => {
  dir = tempDir();
  input = await writeMeshopt(path.join(dir, 'mini_meshopt.glb'), miniature());
  fs.mkdirSync(path.join(dir, 'plain'));
  plainInput = await writePlain(path.join(dir, 'plain', 'mini.glb'), miniature());
});

test('parseCli: defaults, detail levels and validation', () => {
  assert.equal(parseCli(['a.glb']).mode, 'repair');
  const opt = parseCli(['--optimize', 'a.glb']);
  assert.deepEqual(opt.options, { baseMM: 32, toleranceMM: 0.02, cap: 1_000_000 });
  assert.equal(parseCli(['--optimize', '--detail', 'low', '--base', '25', 'a.glb']).options.toleranceMM, 0.08);
  assert.equal(parseCli(['--optimize', '--tolerance', '0.05', 'a.glb']).options.toleranceMM, 0.05);
  assert.deepEqual(parseCli(['--target', '50000', 'a.glb']).options, { target: 50_000 });
  assert.throws(() => parseCli([]), /no input files/);
  assert.throws(() => parseCli(['--optimize', '--target', '5', 'a.glb']), /mutually exclusive/);
  assert.throws(() => parseCli(['--optimize', '--base=-3', 'a.glb']), /positive number/);
  assert.throws(() => parseCli(['--target', '1.5', 'a.glb']), /positive integer/);
  assert.throws(() => parseCli(['--optimize', '--detail', 'ultra', 'a.glb']), /--detail/);
});

test('usage errors exit with code 2; --help and --version exit 0', () => {
  assert.equal(run([]).code, 2);
  assert.equal(run(['--nope', 'a.glb']).code, 2);
  const help = run(['--help']);
  assert.equal(help.code, 0);
  assert.match(help.stdout, /Usage:/);
  assert.match(run(['--version']).stdout, /^\d+\.\d+\.\d+/);
});

test('repair: decompresses, passes every test, then a second run is a SKIP', () => {
  const r = run(['--json', '--preview-dir', path.join(dir, 'previews'), input]);
  assert.equal(r.code, 0, r.stderr);
  assert.equal(r.events[0].t, 'ready');
  const [res] = resultOf(r.events);
  assert.equal(res.status, 'OK', res.detail);
  assert.equal(res.out, path.join(dir, 'mini.glb'));
  assert.ok(fs.existsSync(res.out));
  assert.ok(res.preview && fs.existsSync(res.preview));
  const tests = r.events.filter((e) => e.t === 'test').map((e) => e.id);
  assert.deepEqual(tests, ['structure', 'plain', 'validate', 'compare', 'disk']);
  assert.ok(fs.existsSync(input), 'the input must never be deleted');

  const again = run(['--json', res.out]);
  assert.equal(again.code, 0);
  assert.equal(resultOf(again.events)[0].status, 'SKIP');
});

test('optimize: stays within tolerance and keeps the mesh closed', () => {
  const r = run(['--json', '--optimize', '--base', '32', '--tolerance', '0.05', plainInput]);
  assert.equal(r.code, 0, r.stderr);
  const [res] = resultOf(r.events);
  assert.equal(res.status, 'OK', res.detail);
  assert.equal(path.basename(res.out), 'mini_print-32mm.glb');
  const s = res.stats;
  assert.equal(s.withinTolerance, true);
  assert.ok(s.devMaxMM <= 0.05, `deviation ${s.devMaxMM}`);
  assert.ok(s.tris <= s.trisBefore);
  assert.equal(s.baseDetected, true);
  assert.ok(Math.abs(s.heightMM - 21.6) < 0.2, `height ${s.heightMM}`);
});

test('optimize refuses a still-compressed file', () => {
  const r = run(['--json', '--optimize', input]);
  assert.equal(r.code, 1);
  assert.match(resultOf(r.events)[0].detail, /repair it first/);
});

test('reduce to a target triangle count', () => {
  const r = run(['--json', '--target', '10000', plainInput]);
  assert.equal(r.code, 0, r.stderr);
  const [res] = resultOf(r.events);
  assert.equal(res.status, 'OK', res.detail);
  assert.equal(path.basename(res.out), 'mini_reduced-10k.glb');
  assert.ok(res.stats.tris <= 10_500, `tris ${res.stats.tris}`);
});

test('invalid files fail with exit code 1 without stopping the batch', () => {
  const garbage = path.join(dir, 'garbage.glb');
  fs.writeFileSync(garbage, 'this is not a GLB file at all, just text');
  const missing = path.join(dir, 'missing.glb');
  const r = run(['--json', garbage, missing, input]);
  assert.equal(r.code, 1);
  const results = resultOf(r.events);
  assert.deepEqual(
    results.map((x) => x.status),
    ['FAIL', 'FAIL', 'OK'],
  );
  assert.match(results[1].detail, /not found/);
});
