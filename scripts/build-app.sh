#!/bin/bash
# Build remap.app for local use or GitHub Releases distribution.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="remap"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"

echo "==> Compiling arm64 macOS binary"
xcrun swiftc \
  -O \
  -target arm64-apple-macos13.0 \
  src/main.swift \
  -o "$MACOS_DIR/$APP_NAME"

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Release builds pass VERSION from the tag. Local builds keep Info.plist's default.
if [ -n "${VERSION:-}" ]; then
  echo "==> Setting CFBundleShortVersionString to $VERSION"
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
fi

# A local stable signing identity keeps Accessibility permission stable across
# rebuilds on the same Mac. GitHub Actions has no such identity, so releases
# intentionally fall back to ad-hoc signing.
SIGN_IDENTITY="${SIGN_IDENTITY:-remap-signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_IDENTITY\""; then
  echo "==> Signing with local identity: $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
  echo "==> Ad-hoc signing"
  codesign --force --sign - "$APP_BUNDLE"
fi

codesign --verify --strict "$APP_BUNDLE"
echo "==> Built $APP_BUNDLE"
