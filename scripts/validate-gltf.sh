#!/usr/bin/env bash
# Validate GLB/GLTF assets against budgets from docs/ASSETS_3D.md.
# Requires gltf-transform (npm i -g @gltf-transform/cli).
#
# Usage: ./scripts/validate-gltf.sh <assets_dir>

set -euo pipefail

ASSETS_DIR="${1:-assets/optimized}"
MAX_SIZE_BYTES=$((5 * 1024 * 1024)) # 5 MB per asset

shopt -s nullglob
files=("$ASSETS_DIR"/*.glb)

if [ ${#files[@]} -eq 0 ]; then
  echo "No GLB files found in $ASSETS_DIR (final 3D assets not delivered yet — this is expected)."
  exit 0
fi

failed=0

for file in "${files[@]}"; do
  size=$(wc -c <"$file")
  name="$(basename "$file")"

  if [ "$size" -gt "$MAX_SIZE_BYTES" ]; then
    echo "FAIL $name — $((size / 1024 / 1024)) MB exceeds 5 MB budget"
    failed=1
  else
    echo "OK   $name — $((size / 1024)) KB"
  fi

  if command -v gltf-transform &>/dev/null; then
    gltf-transform inspect "$file" >/dev/null || { echo "FAIL $name — invalid GLTF"; failed=1; }
  fi
done

exit $failed
