// Progress reporting.
//
// In `--json` mode the engine writes one NDJSON event per line to stdout; the macOS app
// consumes these to drive its progress UI. Otherwise it prints a human-readable log.
//
// fs.writeSync is used on purpose: on macOS, pipes behind process.stdout are asynchronous,
// so events would sit in a queue while the (single) thread is busy computing.

import fs from 'node:fs';

/** Creates the output functions for one engine run. */
export function createReporter({ json }) {
  return {
    json,
    /** Structured event (JSON mode only). */
    emit(event) {
      if (json) fs.writeSync(1, `${JSON.stringify(event)}\n`);
    },
    /** Human-readable line (text mode only). */
    say(line) {
      if (!json) fs.writeSync(1, `${line}\n`);
    },
  };
}

/** Yields to the event loop so that emitted events are flushed and timers can fire. */
export const tick = () => new Promise((resolve) => setImmediate(resolve));

/**
 * Weighted pipeline steps: `steps` is a list of [id, label, weight] with weights summing to ~1.
 * The tracker emits `step`, `progress` and `stepDone` events with an overall 0–1 progress value.
 */
export function makeTracker(steps, file, reporter) {
  const start = {};
  const weight = {};
  const label = {};
  let acc = 0;
  for (const [id, text, w] of steps) {
    start[id] = acc;
    weight[id] = w;
    label[id] = text;
    acc += w;
  }
  let current = null;
  let t0 = 0;
  return {
    async step(id) {
      const now = performance.now();
      if (current) reporter.emit({ t: 'stepDone', file, step: current, ms: Math.round(now - t0) });
      current = id;
      t0 = now;
      reporter.emit({ t: 'step', file, step: id, label: label[id], progress: start[id] });
      await tick();
    },
    sub(fraction) {
      if (!current) return;
      const progress = start[current] + weight[current] * Math.min(1, fraction);
      reporter.emit({ t: 'progress', file, step: current, progress });
    },
    end() {
      if (current) reporter.emit({ t: 'stepDone', file, step: current, ms: Math.round(performance.now() - t0) });
      current = null;
    },
  };
}

/** Error raised for expected failures (bad input, failed checks): message is user-facing. */
export class EngineError extends Error {}

export function fail(message) {
  throw new EngineError(message);
}

export const formatInt = (n) => Math.round(n).toLocaleString('en-US');
