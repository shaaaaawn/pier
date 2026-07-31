#!/bin/bash
# Render every fixture PNG and compare against a baseline captured earlier.
#
# This is the verification method that proved the PortListView split changed
# nothing: byte-identical renders are a far stronger statement about a
# mechanical refactor than any unit test this repo could reasonably write.
# It was done by hand the first time; this makes it repeatable.
#
#   make fixture-baseline   # before your change
#   ...refactor...
#   make fixture-check      # after — fails loudly on any pixel difference
#
# Baselines are NOT committed. PNGs churn on every intentional UI tweak, and a
# megabyte of binary diff per redesign is a worse trade than re-running one
# command before you start.
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="${PIER_FIXTURE_DIR:-.fixtures}"
MODE="${1:-check}"
OUT="$DIR/$([[ "$MODE" == "baseline" ]] && echo baseline || echo current)"

RENDERS=(
  "--render-fixture:list.png"
  "--render-fixture-expanded:expanded.png"
  "--render-fixture-activity:activity.png"
  "--render-fixture-idle:idle.png"
  "--render-fixture-down:down.png"
  "--render-fixture-narrow:narrow.png"
  "--render-fixture-logs:logs.png"
)

swift build >/dev/null
rm -rf "$OUT" && mkdir -p "$OUT"
for spec in "${RENDERS[@]}"; do
  .build/debug/Pier "${spec%%:*}" "$OUT/${spec##*:}" >/dev/null 2>&1
done

if [[ "$MODE" == "baseline" ]]; then
  echo "==> Baseline captured: $(ls "$OUT" | wc -l | tr -d ' ') renders in $OUT"
  exit 0
fi

if [[ ! -d "$DIR/baseline" ]]; then
  echo "No baseline. Run 'make fixture-baseline' before your change." >&2
  exit 2
fi

failed=0
for f in "$DIR/baseline"/*.png; do
  n=$(basename "$f")
  if cmp -s "$f" "$OUT/$n"; then
    echo "  same   $n"
  else
    echo "  DIFF   $n" >&2
    failed=1
  fi
done

if [[ $failed -eq 1 ]]; then
  echo >&2
  echo "Renders changed. Intentional UI change? Re-baseline. Otherwise the" >&2
  echo "refactor altered behaviour — compare $DIR/baseline vs $OUT." >&2
  exit 1
fi
echo "==> All renders byte-identical"
