#!/bin/bash
# Render Pier's app icon to PNG/icns.
#   assets/app-icon.svg  -> assets/Pier.iconset/* -> assets/Pier.icns
# (The menu bar glyph is drawn in code: Sources/Pier/PierGlyph.swift.)
#
# Backends, in preference order: rsvg-convert, Chrome headless,
# Playwright (set PIER_PLAYWRIGHT_NODE_MODULES), qlmanage. Nothing is installed.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PLAYWRIGHT_NODE_MODULES="${PIER_PLAYWRIGHT_NODE_MODULES:-}"

if command -v rsvg-convert >/dev/null 2>&1; then
  BACKEND=rsvg
elif [[ -x "$CHROME" ]]; then
  BACKEND=chrome
elif node -e "require('$PLAYWRIGHT_NODE_MODULES/playwright')" >/dev/null 2>&1; then
  BACKEND=playwright
elif command -v qlmanage >/dev/null 2>&1; then
  BACKEND=qlmanage
else
  echo "error: no SVG renderer found (rsvg-convert, Chrome, Playwright, qlmanage)" >&2
  exit 1
fi
echo "==> Rendering icons with $BACKEND"

# render <svg> <size> <out.png>
render() {
  local svg="$1" size="$2" out="$3"
  case "$BACKEND" in
    rsvg)
      rsvg-convert -w "$size" -h "$size" -o "$out" "$svg"
      ;;
    chrome)
      # Wrap the SVG in HTML with explicit CSS sizing: Chrome renders a bare
      # SVG document at its intrinsic (viewBox) size instead of the viewport.
      local wrapper
      wrapper="$(mktemp /tmp/pier-render-XXXXXX.html)"
      {
        printf '<!doctype html><meta charset="utf-8"><style>html,body{margin:0;padding:0}svg{display:block;width:%spx;height:%spx}</style>' "$size" "$size"
        cat "$svg"
      } > "$wrapper"
      "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
        --default-background-color=00000000 \
        --screenshot="$PWD/$out" --window-size="$size,$size" \
        "file://$wrapper" >/dev/null 2>&1
      rm -f "$wrapper"
      ;;
    playwright)
      SVG="$svg" SIZE="$size" OUT="$out" MODS="$PLAYWRIGHT_NODE_MODULES" node -e '
        const { chromium } = require(process.env.MODS + "/playwright");
        (async () => {
          const browser = await chromium.launch();
          const page = await browser.newPage({
            viewport: { width: +process.env.SIZE, height: +process.env.SIZE },
          });
          await page.goto("file://" + process.cwd() + "/" + process.env.SVG);
          await page.screenshot({ path: process.env.OUT, omitBackground: true });
          await browser.close();
        })();
      '
      ;;
    qlmanage)
      local tmpdir
      tmpdir="$(mktemp -d)"
      qlmanage -t -s "$size" -o "$tmpdir" "$svg" >/dev/null 2>&1
      mv "$tmpdir/$(basename "$svg").png" "$out"
      rm -rf "$tmpdir"
      ;;
  esac
}

# --- App icon (.iconset -> .icns) ---
ICONSET=assets/Pier.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
render assets/app-icon.svg 16   "$ICONSET/icon_16x16.png"
render assets/app-icon.svg 32   "$ICONSET/icon_16x16@2x.png"
render assets/app-icon.svg 32   "$ICONSET/icon_32x32.png"
render assets/app-icon.svg 64   "$ICONSET/icon_32x32@2x.png"
render assets/app-icon.svg 128  "$ICONSET/icon_128x128.png"
render assets/app-icon.svg 256  "$ICONSET/icon_128x128@2x.png"
render assets/app-icon.svg 256  "$ICONSET/icon_256x256.png"
render assets/app-icon.svg 512  "$ICONSET/icon_256x256@2x.png"
render assets/app-icon.svg 512  "$ICONSET/icon_512x512.png"
render assets/app-icon.svg 1024 "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o assets/Pier.icns
echo "==> Wrote assets/Pier.icns"
