#!/usr/bin/env bash
# Downloads the latest Node.js LTS (default: v24.x) for macOS arm64, verifies its SHA-256
# against the official SHASUMS256.txt and caches the binary in app/.cache/node-<version>/.
# Prints the path of the cached `node` binary on stdout.
#
#   NODE_MAJOR=24 app/scripts/fetch-node.sh
set -euo pipefail

MAJOR="${NODE_MAJOR:-24}"
ARCH="darwin-arm64"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cache"
mkdir -p "$CACHE"

VERSION="${NODE_VERSION:-$(curl -fsSL https://nodejs.org/dist/index.json |
  python3 -c "import json,sys; print(next(r['version'] for r in json.load(sys.stdin) if r['version'].startswith('v$MAJOR.') and r['lts']))")}"
DEST="$CACHE/node-$VERSION"
if [[ -x "$DEST/bin/node" ]]; then
  echo "$DEST/bin/node"
  exit 0
fi

TARBALL="node-$VERSION-$ARCH.tar.gz"
BASE="https://nodejs.org/dist/$VERSION"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Node.js $VERSION ($ARCH)…" >&2
curl -fsSL "$BASE/$TARBALL" -o "$TMP/$TARBALL"
curl -fsSL "$BASE/SHASUMS256.txt" -o "$TMP/SHASUMS256.txt"
(cd "$TMP" && grep " $TARBALL\$" SHASUMS256.txt | shasum -a 256 -c - >&2)

tar -xzf "$TMP/$TARBALL" -C "$TMP"
mkdir -p "$DEST/bin"
cp "$TMP/node-$VERSION-$ARCH/bin/node" "$DEST/bin/node"
cp "$TMP/node-$VERSION-$ARCH/LICENSE" "$DEST/LICENSE"
echo "$DEST/bin/node"
