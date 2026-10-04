#!/usr/bin/env bash
# Fetch Filament's prebuilt iOS artifacts (headers + static-lib
# xcframeworks) and vendor them into ios/vendor/filament/.
#
# Pinned version: v1.75.1 — the newest release published BOTH as a GitHub
# release (iOS tgz) and to Maven Central (Android AARs); v1.76.0 exists on
# GitHub but its AARs are not on Maven Central yet (checked 2026-08-30).
#
# The vendored tree is gitignored (~100 MB extracted); run this once per
# checkout before `mix mob.deploy --native` for iOS.
set -euo pipefail

FILAMENT_VERSION="v1.75.1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ios/vendor/filament"
URL="https://github.com/google/filament/releases/download/${FILAMENT_VERSION}/filament-${FILAMENT_VERSION}-ios.tgz"

if [ -d "$DEST/lib" ] && [ -d "$DEST/include" ]; then
  echo "filament already vendored at $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL ..."
curl -sfL -o "$TMP/filament-ios.tgz" "$URL"
tar xzf "$TMP/filament-ios.tgz" -C "$TMP"

mkdir -p "$DEST"
cp -R "$TMP/filament/include" "$DEST/include"
cp -R "$TMP/filament/lib" "$DEST/lib"
cp "$TMP/filament/LICENSE" "$DEST/LICENSE"

echo "Vendored filament ${FILAMENT_VERSION} at $DEST"
