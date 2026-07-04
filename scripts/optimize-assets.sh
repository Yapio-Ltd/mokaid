#!/usr/bin/env bash
# Optimize 3D assets before upload: Draco-compress GLB meshes and convert
# textures to KTX2. Requires gltf-transform (npm i -g @gltf-transform/cli).
#
# Usage: ./scripts/optimize-assets.sh <input_dir> <output_dir>

set -euo pipefail

INPUT_DIR="${1:-assets/raw}"
OUTPUT_DIR="${2:-assets/optimized}"

if ! command -v gltf-transform &>/dev/null; then
  echo "error: gltf-transform not found. Install with: npm install -g @gltf-transform/cli" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

shopt -s nullglob
files=("$INPUT_DIR"/*.glb "$INPUT_DIR"/*.gltf)

if [ ${#files[@]} -eq 0 ]; then
  echo "No GLB/GLTF files found in $INPUT_DIR (final 3D assets not delivered yet — this is expected)."
  exit 0
fi

for file in "${files[@]}"; do
  name="$(basename "$file")"
  out="$OUTPUT_DIR/${name%.*}.glb"
  echo "Optimizing $name -> $out"
  gltf-transform optimize "$file" "$out" \
    --compress draco \
    --texture-compress ktx2 \
    --texture-size 1024
done

echo "Done. Optimized $((${#files[@]})) file(s) into $OUTPUT_DIR"
