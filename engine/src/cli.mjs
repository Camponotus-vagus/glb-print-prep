// Command-line interface. Also the process the macOS app spawns (with --json).

import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { createReporter, EngineError } from './events.mjs';
import { createIO } from './io.mjs';
import { OPTIMIZE_STEPS, optimizeFile, REDUCE_STEPS, reduceFile } from './optimize.mjs';
import { REPAIR_STEPS, repairFile } from './repair.mjs';
import { DETAIL_LEVELS, toleranceFor } from './tolerance.mjs';

const pkg = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

export const USAGE = `GLB Print Prep ${pkg.version}
Repair compressed GLB files and optimize them for FDM/resin printing.

Usage:
  glb-print-prep [options] <file.glb>...

Modes (default: repair):
  (none)                 Decompress meshopt / quantization / Draco into a standard GLB,
                         verified against the original. Writes model.glb or model_fixed.glb.
  --optimize             Reduce triangles adaptively, keeping the measured deviation
                         (Hausdorff, in mm) under the print tolerance. Writes model_print-<base>mm.glb.
  --target <N>           Reduce to about N triangles (no tolerance). Writes model_reduced-<N/1000>k.glb.

Optimize options:
  --base <mm>            Diameter/width of the model's base once printed (default 32)
  --tolerance <mm>       Maximum allowed deviation; overrides --detail/--nozzle/--layer
  --detail <level>       ${Object.keys(DETAIL_LEVELS).join(' | ')} (default high)
  --nozzle <mm>          Nozzle diameter (default 0.2)
  --layer <mm>           Layer height (default 0.08)
  --cap <N>              Maximum triangles in the output (default 1000000)

General:
  --json                 Emit NDJSON progress events on stdout (used by the macOS app)
  --preview-dir <dir>    Also write lightweight preview GLBs into <dir>
  -h, --help             Show this help
  -v, --version          Show the version

Input files are never modified. Exit codes: 0 ok, 1 at least one file failed, 2 usage error.`;

const OPTIONS = {
  json: { type: 'boolean', default: false },
  'preview-dir': { type: 'string' },
  optimize: { type: 'boolean', default: false },
  target: { type: 'string' },
  base: { type: 'string', default: '32' },
  tolerance: { type: 'string' },
  detail: { type: 'string', default: 'high' },
  nozzle: { type: 'string', default: '0.2' },
  layer: { type: 'string', default: '0.08' },
  cap: { type: 'string', default: '1000000' },
  help: { type: 'boolean', short: 'h', default: false },
  version: { type: 'boolean', short: 'v', default: false },
};

class UsageError extends Error {}

function positive(name, raw, { integer = false } = {}) {
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0 || (integer && !Number.isInteger(n))) {
    throw new UsageError(`--${name} must be a positive ${integer ? 'integer' : 'number'} (got "${raw}")`);
  }
  return n;
}

/** Parses argv into a run plan. Throws UsageError on invalid input. */
export function parseCli(argv) {
  let parsed;
  try {
    parsed = parseArgs({ args: argv, options: OPTIONS, allowPositionals: true, strict: true });
  } catch (e) {
    throw new UsageError(e.message);
  }
  const { values: v, positionals: files } = parsed;
  if (v.help) return { help: true };
  if (v.version) return { version: true };
  if (!files.length) throw new UsageError('no input files');
  if (v.optimize && v.target) throw new UsageError('--optimize and --target are mutually exclusive');

  const plan = { files: files.map((f) => path.resolve(f)), json: v.json, previewDir: v['preview-dir'] ?? null };
  if (v.optimize) {
    let toleranceMM;
    if (v.tolerance !== undefined) toleranceMM = positive('tolerance', v.tolerance);
    else {
      if (!DETAIL_LEVELS[v.detail])
        throw new UsageError(`--detail must be one of ${Object.keys(DETAIL_LEVELS).join(', ')}`);
      toleranceMM = toleranceFor(v.detail, { layer: positive('layer', v.layer), nozzle: positive('nozzle', v.nozzle) });
    }
    plan.mode = 'optimize';
    plan.options = { baseMM: positive('base', v.base), toleranceMM, cap: positive('cap', v.cap, { integer: true }) };
  } else if (v.target !== undefined) {
    plan.mode = 'reduce';
    plan.options = { target: positive('target', v.target, { integer: true }) };
  } else {
    plan.mode = 'repair';
  }
  return plan;
}

const STEPS = { repair: REPAIR_STEPS, optimize: OPTIMIZE_STEPS, reduce: REDUCE_STEPS };

/** Runs the CLI; returns the process exit code. */
export async function main(argv = process.argv.slice(2)) {
  let plan;
  try {
    plan = parseCli(argv);
  } catch (e) {
    if (!(e instanceof UsageError)) throw e;
    process.stderr.write(`glb-print-prep: ${e.message}\nRun with --help for usage.\n`);
    return 2;
  }
  if (plan.help) {
    process.stdout.write(`${USAGE}\n`);
    return 0;
  }
  if (plan.version) {
    process.stdout.write(`${pkg.version}\n`);
    return 0;
  }

  const reporter = createReporter({ json: plan.json });
  const io = await createIO();
  const ctx = { io, reporter, previewDir: plan.previewDir };
  reporter.emit({
    t: 'ready',
    pid: process.pid,
    version: pkg.version,
    steps: STEPS[plan.mode].map(([id, label, w]) => ({ id, label, w })),
  });

  let anyFail = false;
  for (const input of plan.files) {
    const t0 = performance.now();
    reporter.emit({ t: 'start', file: input });
    let r;
    try {
      if (plan.mode === 'optimize') r = await optimizeFile(input, ctx, plan.options);
      else if (plan.mode === 'reduce') r = await reduceFile(input, ctx, plan.options);
      else r = await repairFile(input, ctx);
    } catch (e) {
      anyFail = true;
      const detail = e instanceof EngineError ? e.message : `unexpected error: ${e.message}`;
      r = { status: 'FAIL', detail };
      reporter.say(`  ✗ ${detail}`);
    }
    const ms = Math.round(performance.now() - t0);
    reporter.emit({
      t: 'result',
      file: input,
      status: r.status,
      detail: r.detail,
      out: r.out ?? null,
      preview: r.preview ?? null,
      stats: r.stats ?? null,
      ms,
    });
    reporter.say(`RESULT\t${r.status}\t${input}\t${r.detail}`);
  }
  return anyFail ? 1 : 0;
}
