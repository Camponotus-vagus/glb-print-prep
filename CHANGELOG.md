# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

## [1.0.0] — 2026-09-27

First public release.

### Added
- **Repair** of GLB files compressed with meshopt, mesh quantization or Draco into standard GLB, verified by
  five independent tests before the original is moved to the Trash (always restorable).
- **Print optimization**: adaptive triangle reduction within a measured tolerance in millimetres
  (symmetric Hausdorff distance), derived from nozzle diameter and layer height, with automatic detection of
  the round base for real-world scale, fin removal and protection against non-manifold pinches.
- Native macOS app (SwiftUI, RealityKit, Liquid Glass): drag & drop of files and folders, parallel batch
  processing on Apple Silicon, live progress with ETA and CPU/RAM heartbeat, 3D thumbnails and viewer,
  "keep only optimized versions" mode, Settings for printer profile and detail level. Node.js is bundled.
- Cross-platform command-line interface (`glb-print-prep`) with `--optimize`, `--detail`, `--nozzle`,
  `--layer`, `--tolerance`, `--base`, `--cap`, `--target`, `--json` and `--preview-dir`.
- Support links for GitHub Sponsors and Ko-fi in the Help menu and Settings.
- Tests (engine: `node:test`; app core: Swift Testing), Biome, SwiftLint, swift-format and CI on
  macOS, Linux and Windows.

[Unreleased]: https://github.com/Camponotus-vagus/glb-print-prep/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Camponotus-vagus/glb-print-prep/releases/tag/v1.0.0
