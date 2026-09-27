#!/usr/bin/env bash
# Builds "GLB Print Prep.app" into dist/ (Apple Silicon, macOS 26+).
#
#   app/scripts/build-app.sh                 # release build, bundled Node.js, ad-hoc signature
#   BUNDLE_NODE=0 app/scripts/build-app.sh   # use the system Node.js instead (smaller, for development)
#   CODESIGN_IDENTITY="Developer ID Application: …" app/scripts/build-app.sh   # signed, hardened runtime
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$APP_DIR/.." && pwd)"
ENGINE="$REPO/engine"
DIST="$REPO/dist"
APP="$DIST/GLB Print Prep.app"
CONTENTS="$APP/Contents"

echo "→ Swift release build"
swift build --package-path "$APP_DIR" -c release --arch arm64
BIN="$(swift build --package-path "$APP_DIR" -c release --arch arm64 --show-bin-path)/GLBPrintPrep"

echo "→ Assembling bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/engine"
cp "$BIN" "$CONTENTS/MacOS/GLBPrintPrep"
cp "$APP_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
VERSION="$(python3 -c "import json; print(json.load(open('$ENGINE/package.json'))['version'])")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"

echo "→ Engine $VERSION"
cp -R "$ENGINE/bin" "$ENGINE/src" "$ENGINE/package.json" "$ENGINE/package-lock.json" "$CONTENTS/Resources/engine/"
(cd "$CONTENTS/Resources/engine" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund --silent)

if [[ "${BUNDLE_NODE:-1}" != "0" ]]; then
  NODE_BIN="$("$APP_DIR/scripts/fetch-node.sh")"
  echo "→ Bundling $("$NODE_BIN" --version) ($NODE_BIN)"
  mkdir -p "$CONTENTS/Resources/node/bin"
  cp "$NODE_BIN" "$CONTENTS/Resources/node/bin/node"
  cp "$(dirname "$NODE_BIN")/../LICENSE" "$CONTENTS/Resources/node/LICENSE"
fi

echo "→ Icon (Icon Composer → actool)"
# The actool agent can outlive a deleted working directory and then fail silently: restart it
# and always pass absolute paths.
pkill -x ibtoold 2>/dev/null || true
pkill -f AssetCatalogAgent 2>/dev/null || true
xcrun actool "$APP_DIR/Resources/AppIcon.icon" --compile "$CONTENTS/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$DIST/icon-partial.plist" >/dev/null
rm -f "$DIST/icon-partial.plist"

echo "→ Code signing"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  ENT="$APP_DIR/Resources/node.entitlements"
  if [[ -f "$CONTENTS/Resources/node/bin/node" ]]; then
    codesign --force --options runtime --timestamp --entitlements "$ENT" -s "$CODESIGN_IDENTITY" \
      "$CONTENTS/Resources/node/bin/node"
  fi
  codesign --force --options runtime --timestamp -s "$CODESIGN_IDENTITY" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "✓ $APP"
