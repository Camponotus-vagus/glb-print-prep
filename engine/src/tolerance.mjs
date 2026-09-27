// Detail levels, inspired by Bambu Studio's simplify presets but expressed in real millimetres
// derived from the print profile. Keep in sync with `DetailLevel` in the macOS app.
//
//   tolerance = min(layerHeight × a, nozzleDiameter × b)
//
// With a 0.08 mm layer and a 0.2 mm nozzle: extra-high 0.01, high 0.02, medium 0.04, low 0.08 mm.

export const DETAIL_LEVELS = {
  'extra-high': { layer: 1 / 8, nozzle: 1 / 20 },
  high: { layer: 1 / 4, nozzle: 1 / 10 },
  medium: { layer: 1 / 2, nozzle: 1 / 5 },
  low: { layer: 1, nozzle: 2 / 5 },
};

/** Tolerance in mm, rounded to the micrometre. */
export function toleranceFor(level, { layer, nozzle }) {
  const k = DETAIL_LEVELS[level];
  if (!k) throw new Error(`unknown detail level "${level}" (${Object.keys(DETAIL_LEVELS).join(', ')})`);
  return Math.round(Math.min(layer * k.layer, nozzle * k.nozzle) * 1000) / 1000;
}
