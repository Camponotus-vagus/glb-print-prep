# How it works

GLB Print Prep has two parts:

- **Engine** (`engine/`, Node.js): does all the geometry work. Usable on its own as a CLI.
- **App** (`app/`, SwiftUI + RealityKit): queue, progress, previews, Trash handling. It spawns one engine
  process per file (up to half the performance cores, bounded by RAM) and reads its NDJSON events.

## Repair

1. **Diagnosis.** Read the GLB container and JSON, list compression extensions
   (`EXT_meshopt_compression`, `KHR_mesh_quantization`, `KHR_draco_mesh_compression`) and structural
   problems (for example meshopt fallback buffers without data, which cause "Invalid byteLength" errors).
   Files without compression are reported as `SKIP` and left alone.
2. **Decode** with glTF-Transform plus the meshoptimizer and Draco decoders.
3. **Convert** to standard glTF: `dequantize()` (quantized attributes → float), `unpartition()` (one
   buffer), and the compression extensions are removed.
4. **Tests**, all of which must pass before anything is written:
   - container structure: a single buffer, no compression extension left;
   - re-read with a plain glTF reader that has no decoders registered;
   - the official Khronos glTF Validator reports 0 errors;
   - content equivalence with the decoded original: counts of nodes/meshes/materials/textures/animations/
     skins, node world matrices, every vertex attribute element by element (tolerance 1e-5, indices
     exact), material assignment, and texture bytes (SHA-256).
5. **Write atomically**: `name.glb.partial` → read back → SHA-256 match → rename. Output names never
   overwrite existing files (`model.glb`, `model_2.glb`, …).

The app then runs its own **independent check** (GLB magic, version, declared length = file size, no
compression extension) and only then moves the original to the Trash (restorable from the card).

## Print optimization

The engine looks for the smallest number of triangles for which the surface stays within the printer's
resolution of the original.

1. **Scale.** A glTF file doesn't say how large the printed miniature will be, so the engine detects the base: it takes the
   lowest 3 % of the model's height; if that slice is round (extent ratio > 0.85) its diameter is the base,
   otherwise the largest horizontal extent is used. `mm per unit = base diameter (mm) / base (units)`.
2. **Tolerance** in millimetres from the print profile, `min(layer × a, nozzle × b)`; see the table in the
   README. With a 0.2 mm nozzle and 0.08 mm layers, "high" is 0.02 mm.
3. **Simplification** with meshoptimizer's `simplifyWithUpdate` (quadric error metric with optimal vertex
   placement, normals/UV/colour as weighted attributes), followed by:
   - **Fin removal.** Meshopt can collapse two sides of a thin part into coincident, opposite triangles
     (zero-thickness "fins"); both are removed, exact duplicates are reduced to one;
   - **Pinch protection.** If simplification creates new non-manifold edges, the involved vertices and
     their 2-ring neighbourhood are locked and the primitive is simplified again (up to 4 rounds).
4. **Measurement.** Symmetric Hausdorff distance between the original and simplified surfaces:
   150,000 area-weighted samples on each side (deterministic seeds), point-to-triangle distance on a uniform
   grid with cell pruning. Max, mean and 99th percentile are reported in millimetres.
5. **Search.** Start at 300k triangles, then a bracketing search that uses the empirical relation
   `deviation ∝ triangles^-0.6` to aim at 92 % of the tolerance, with steps of at most 2×, until the bracket
   is within 12 %. Bounds: at least 20k and at most the cap (1M by default). Up to two correction rounds.
6. **Final tests**: topology (no new boundary or non-manifold edges compared with the input), Khronos
   validator, the final deviation measured with the same sampling as the search, atomic write.

The output is `model_print-32mm.glb`. The source file is never modified; the app can optionally trash it
("Keep only optimized versions"), but only when the result is within tolerance.

## Engine protocol

With `--json`, the engine writes one JSON object per line on stdout (written synchronously so events are
not delayed while the thread is busy):

| `t`        | Fields                                                           | Meaning                                  |
| ---------- | ---------------------------------------------------------------- | ---------------------------------------- |
| `ready`    | `pid`, `version`, `steps[{id,label,w}]`                          | engine started; weighted step list       |
| `start`    | `file`                                                           | a file begins                            |
| `diag`     | `file`, `extensions`, `problems`, `inSize`, `triangles`          | diagnosis of the input                   |
| `step`     | `file`, `step`, `label`, `progress`                              | a step begins (overall progress 0–1)     |
| `progress` | `file`, `progress`                                               | progress within a step                   |
| `stepDone` | `file`, `step`, `ms`                                             | a step ended                             |
| `test`     | `file`, `id`, `label`, `ok`                                      | a test passed                            |
| `tmp`      | `file`, `path`                                                   | temporary file to delete if cancelled    |
| `log`      | `file`, `msg`                                                    | informational message                    |
| `result`   | `file`, `status` (`OK`/`SKIP`/`FAIL`), `detail`, `out`, `preview`, `stats`, `ms` | final outcome |

`stats` for optimization also contains `trisBefore`, `devMaxMM`, `devMeanMM`, `devP99MM`, `tolMM`,
`baseMM`, `baseDetected`, `heightMM`, `withinTolerance`, `finsRemoved` and `iterations`.
