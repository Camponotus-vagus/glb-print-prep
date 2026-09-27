# Benchmarks

Measured on a Mac mini M1 (16 GB), engine 1.0.0, "high" detail (0.2 mm nozzle, 0.08 mm layers →
0.02 mm tolerance). Times include validation, the final deviation measurement and writing to disk.

## Print optimization

| Model (AI-generated miniature) | Base    | Triangles in | Triangles out | Max deviation | Time |
| ------------------------------ | ------- | -----------: | ------------: | ------------: | ---: |
| Miniature A                    | 18.9 mm |    1,887,413 |       124,037 |      0.018 mm | 37 s |
| Miniature B (knight)           | 32 mm   |    1,993,090 |       240,872 |      0.018 mm | 48 s |

Search trace for miniature A:

| Attempt | Triangles | Max deviation |
| ------: | --------: | ------------: |
|       1 |   299,990 |     0.0089 mm |
|       2 |   149,999 |     0.0164 mm |
|       3 |   124,037 |     0.0177 mm |
|       4 |   116,607 |     0.0212 mm ✗ |

### Versus Bambu Studio

Bambu Studio's "Simplify model" (`its_quadric_edge_collapse`) uses fixed quadric-error thresholds per
detail level, expressed in model units rather than printed millimetres, and does not measure the result or
check for holes. On miniature A, "Extra high" produced 133,529 triangles. GLB Print Prep produced
124,037 triangles — 7 % fewer — with a *measured* maximum deviation of 0.018 mm and unchanged topology.

## Repair

| Model                                   | Size in → out    | Triangles | Time  |
| --------------------------------------- | ---------------- | --------: | ----: |
| Tripo PBR model (meshopt + quantization) | 9.7 MB → 21.3 MB |   501,440 | 2.4 s |

Maximum attribute difference against the decoded original: 3 × 10⁻⁸.
