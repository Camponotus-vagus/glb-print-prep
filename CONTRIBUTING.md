# Contributing

Thanks for helping! Issues, ideas and pull requests are all welcome.

## Project layout

```
engine/   Node.js engine and CLI (glTF-Transform, meshoptimizer, Draco) — runs on any OS
app/      macOS SwiftUI app (Swift package: GLBPrintPrepCore library + GLBPrintPrep executable)
docs/     Documentation
```

The app runs the engine as a child process and reads NDJSON progress events from it
(see [docs/how-it-works.md](docs/how-it-works.md#engine-protocol)).

## Setup

- Engine: Node.js 22+ → `make setup`
- App: macOS 26+, Xcode 26+ (Swift 6.2), and `brew install swiftlint`

## Everyday commands

| Command       | What it does                                              |
| ------------- | --------------------------------------------------------- |
| `make lint`   | Biome (engine), swift-format and SwiftLint (app)          |
| `make format` | Auto-format everything                                    |
| `make test`   | Engine tests (`node:test`) and app core tests (Swift Testing) |
| `make app`    | Build `dist/GLB Print Prep.app` with bundled Node.js      |
| `make app-dev`| Faster app build using the system Node.js                 |

## Guidelines

- Keep the engine's promise: **inputs are never modified or deleted by the engine**; outputs are written
  atomically and verified. Only the app moves files to the Trash, and only after its own independent check.
- New engine behaviour needs a test in `engine/test/` (synthetic fixtures live in `test/fixtures.mjs`;
  please don't commit binary models).
- Keep `DetailLevel` (Swift) and `DETAIL_LEVELS` (JS) in sync.
- User-facing text is in English; follow Apple's HIG for the app.
- Add a line to `CHANGELOG.md` under "Unreleased".

By contributing you agree that your contributions are licensed under the MIT License.
