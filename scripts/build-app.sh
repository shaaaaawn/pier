#!/bin/bash
# Assemble Pier.app from the SPM build.
# Usage: ./scripts/build-app.sh [--release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
if [[ "${1:-}" == "--release" ]]; then CONFIG=release; fi

echo "==> Building Swift ($CONFIG)"
if [[ "$CONFIG" == "release" ]]; then
  swift build -c release
else
  swift build
fi

BIN=".build/$CONFIG/Pier"
APP="dist/Pier.app"

# Icons are checked in as SVG; render PNG/icns on first build (or after
# `scripts/render-icons.sh` is run manually).
if [[ ! -f assets/Pier.icns || ! -f Sources/Pier/Resources/menubar-icon.png ]]; then
  echo "==> Rendering icons"
  ./scripts/render-icons.sh
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pier"
cp Info.plist "$APP/Contents/Info.plist"

# SPM executable resources land in a bundle next to the binary; Bundle.module
# only resolves inside the .app if we copy it into Contents/Resources.
if [[ -d ".build/$CONFIG/Pier_Pier.bundle" ]]; then
  cp -R ".build/$CONFIG/Pier_Pier.bundle" "$APP/Contents/Resources/"
fi
cp assets/Pier.icns "$APP/Contents/Resources/Pier.icns"

# Ad-hoc sign so TCC/AppKit treat it as a proper app bundle.
codesign --force --sign - "$APP"

echo "==> Done: $APP"
