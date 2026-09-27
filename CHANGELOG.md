# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org).

## [Unreleased]

## [3.0.0] — 2026-09-27

First public release as **GLB Print Prep** (previously a private tool).

### Added
- Fully English UI, CLI and documentation.
- Standalone command-line interface (`glb-print-prep`) with `--optimize`, `--detail`, `--nozzle`, `--layer`,
  `--tolerance`, `--base`, `--cap`, `--target`, `--json` and `--preview-dir`.
- Node.js runtime bundled inside the app.
- Help menu and Settings links for GitHub, issue reporting and sponsorship.
- Automated tests (engine: `node:test`; app core: Swift Testing), Biome, SwiftLint, swift-format and CI.

### Carried over from the private versions
- Meshopt / quantization / Draco repair with five independent checks and restorable Trash handling.
- Adaptive print optimization within a measured tolerance, base detection, fin removal and pinch protection.
- Folder import, "keep only optimized versions", live progress with heartbeat, RealityKit previews,
  Liquid Glass UI and Icon Composer icon.

[Unreleased]: https://github.com/Camponotus-vagus/glb-print-prep/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/Camponotus-vagus/glb-print-prep/releases/tag/v3.0.0
