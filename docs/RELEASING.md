# Releasing

1. Update the version in `engine/package.json` (the app reads it at build time) and bump
   `CFBundleVersion` in `app/Resources/Info.plist`.
2. Move the "Unreleased" entries in `CHANGELOG.md` under the new version and date.
3. `make lint test app` and try `dist/GLB Print Prep.app` on a few real models.
4. Commit, tag and push: `git tag -a v1.1.0 -m "v1.1.0" && git push --follow-tags`.
5. The **Release** workflow builds the app with bundled Node.js, zips it, packs the engine and creates a
   **draft** GitHub release with checksums. Review the notes and publish it.

## Notarization (optional, needs a paid Apple Developer account)

Unsigned apps trigger Gatekeeper warnings. To notarize locally:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" app/scripts/build-app.sh
ditto -c -k --sequesterRsrc --keepParent "dist/GLB Print Prep.app" dist/app.zip
xcrun notarytool submit dist/app.zip --keychain-profile notary --wait
xcrun stapler staple "dist/GLB Print Prep.app"
```

The bundled `node` binary is signed with `app/Resources/node.entitlements` (JIT is required by V8 under
the hardened runtime). To automate this in CI, store the certificate and an App Store Connect API key as
repository secrets.

## One-time GitHub setup

- Settings → General → Features: enable **Discussions** (the issue template links to it) and **Sponsorships**.
- Settings → Code security: enable **Private vulnerability reporting** (referenced by `SECURITY.md`).
- Add topics: `gltf`, `glb`, `meshopt`, `3d-printing`, `bambu-lab`, `macos`, `swiftui`.
