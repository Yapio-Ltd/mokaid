#!/usr/bin/env bash
# Validate GLB/GLTF assets against budgets from docs/ASSETS_3D.md.
# Office environment assets are allowed a higher byte budget (textures dominate).
#
# Usage: ./scripts/validate-gltf.sh <assets_dir>

set -euo pipefail

ASSETS_DIR="${1:-assets/optimized}"
MAX_AVATAR_BYTES=$((5 * 1024 * 1024))
MAX_OFFICE_BYTES=$((50 * 1024 * 1024))
MAX_TRIANGLES_OFFICE=200000
MAX_TEX_DIM_OFFICE=4096

shopt -s nullglob
files=("$ASSETS_DIR"/*.glb)

if [ ${#files[@]} -eq 0 ]; then
  echo "No GLB files found in $ASSETS_DIR (final 3D assets not delivered yet — this is expected)."
  exit 0
fi

failed=0

for file in "${files[@]}"; do
  size=$(wc -c <"$file" | tr -d ' ')
  name="$(basename "$file")"
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  is_office=0
  [[ "$lower" == *office* ]] && is_office=1

  max_bytes=$MAX_AVATAR_BYTES
  [ "$is_office" -eq 1 ] && max_bytes=$MAX_OFFICE_BYTES

  if [ "$size" -gt "$max_bytes" ]; then
    echo "FAIL $name — $((size / 1024 / 1024)) MB exceeds $((max_bytes / 1024 / 1024)) MB budget"
    failed=1
  else
    echo "OK   $name — $((size / 1024)) KB"
  fi

  if command -v npx &>/dev/null; then
    if ! npx --yes @gltf-transform/cli inspect "$file" >/dev/null 2>&1; then
      echo "FAIL $name — invalid GLTF"
      failed=1
    fi
  fi
done

# Soft guidance for office VRAM (logged, does not fail without inspect JSON tooling).
if [ "$failed" -eq 0 ]; then
  echo "Validation complete (office budget ${MAX_OFFICE_BYTES}, avatar ${MAX_AVATAR_BYTES}, max tris hint ${MAX_TRIANGLES_OFFICE}, max tex ${MAX_TEX_DIM_OFFICE})."
fi

exit $failed
