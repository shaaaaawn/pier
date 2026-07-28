#!/bin/bash
# Convert third-party harness brand icons to canonical 32px PNGs in
# Sources/Pier/Resources/icons/.
#
# The brand-icon sources are NOT in this repo (they're third-party marks — see
# "Icon credits" in the README). Point PIER_ICON_SRC at a directory containing
# them, or skip this script entirely: the converted PNGs are checked in.
# SVGs render via Chrome headless (HTML wrapper with explicit pixel size —
# bare SVG documents render at intrinsic viewBox size, not the window size).
# PNG/ICO sources (the .ico files are actually PNG data) resize via sips.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC_DIR="${PIER_ICON_SRC:-$HOME/harness-icons}"
OUT_DIR="Sources/Pier/Resources/icons"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SIZE=32

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Icon sources not found at $SRC_DIR" >&2
  echo "Set PIER_ICON_SRC=<dir> to re-convert; the PNGs are already checked in." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

# convert <src-file> <out-name>
convert() {
  local src="$SRC_DIR/$1" name="$2"
  local ext="${1##*.}"
  if [[ ! -f "$src" ]]; then
    echo "  !! missing source: $1" >&2
    return 1
  fi
  case "$ext" in
    svg)
      local wrapper
      wrapper="$(mktemp /tmp/pier-icon-XXXXXX.html)"
      {
        printf '<!doctype html><meta charset="utf-8"><style>html,body{margin:0;padding:0}svg{display:block;width:%dpx;height:%dpx}</style>' "$SIZE" "$SIZE"
        cat "$src"
      } > "$wrapper"
      "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
        --default-background-color=00000000 \
        --screenshot="$PWD/$OUT_DIR/$name.png" --window-size="$SIZE,$SIZE" \
        "file://$wrapper" >/dev/null 2>&1
      rm -f "$wrapper"
      ;;
    png|ico)
      # .ico sources are PNG data; normalize the extension so sips reads them.
      local tmp
      tmp="$(mktemp /tmp/pier-icon-XXXXXX.png)"
      cp "$src" "$tmp"
      sips -Z "$SIZE" -s format png "$tmp" --out "$OUT_DIR/$name.png" >/dev/null
      rm -f "$tmp"
      ;;
    *)
      echo "  !! unsupported format: $1" >&2
      return 1
      ;;
  esac
  echo "  $name.png <- $1"
}

echo "==> Converting harness icons ($SRC_DIR)"
convert aider.png aider
convert amp.svg amp
convert antigravity.ico antigravity
convert claude-code.png claude-code
convert codex.png codex
convert copilot.svg copilot
convert crush.ico crush
convert cursor.svg cursor
convert goose.ico goose
convert kimi-code.png kimi-code
convert opencode.png opencode
convert warp.png warp
convert windsurf.svg windsurf
convert cline.png cline
convert kilo.svg kilo
convert roo.svg roo
convert kiro.svg kiro
convert junie.svg junie
convert jules.svg jules
convert factory-droid.svg factory-droid
convert qwen-code.ico qwen-code
convert qoder.ico qoder
convert refact-ai.png refact-ai
convert baidu-comate.png baidu-comate
convert codebuddy.svg codebuddy
convert openhands.svg openhands
convert devin.png devin
convert augment-code.svg augment-code
convert mistral-vibe.svg mistral-vibe
convert trae.svg trae
convert zencoder.svg zencoder
convert sweep.svg sweep
convert replit-agent.svg replit-agent
convert snowflake-coco.svg snowflake-coco
convert mimo-code.ico mimo-code
convert cosine-genie.ico cosine-genie
convert pi.svg pi
convert zed.png zed

# Engine icons vendored into this repo (assets/vendor) rather than fetched,
# since they aren't agent harnesses.
echo "==> Converting vendored engine icons (assets/vendor)"
SRC_DIR="assets/vendor"
convert docker.svg docker

echo "==> Done: $OUT_DIR"
