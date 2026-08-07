#!/usr/bin/env bash
# Optimize 3D assets before upload.
# Avatars: Draco + WebP 1024 (budget ~5 MB).
# Office environment:
#   - desktop: max texture 2048 + WebP (≈17 MB, replaces 4K chair atlases)
#   - mobile:  max texture 1024 (+ optional mobile filename) for tablet VRAM
# KTX2 is preferred when toktx/basisu is installed; currently office uses WebP.
#
# Usage: ./scripts/optimize-assets.sh <input_dir> <output_dir>

set -euo pipefail

INPUT_DIR="${1:-assets/raw}"
OUTPUT_DIR="${2:-assets/optimized}"
GLTF_TRANSFORM=(npx --yes @gltf-transform/cli)

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
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" == *office* ]] && [[ "$lower" != *mobile* ]]; then
    echo "Optimizing OFFICE $name -> desktop + mobile variants"
    desktop="$OUTPUT_DIR/office.glb"
    mobile="$OUTPUT_DIR/office.mobile.glb"
    "${GLTF_TRANSFORM[@]}" resize "$file" "$desktop" --width 2048 --height 2048
    "${GLTF_TRANSFORM[@]}" resize "$file" "$mobile" --width 1024 --height 1024
    ls -lh "$desktop" "$mobile"
  else
    echo "Optimizing AVATAR $name -> $out (Draco + WebP 1024)"
    "${GLTF_TRANSFORM[@]}" optimize "$file" "$out" \
      --compress draco \
      --texture-compress webp \
      --texture-size 1024
  fi
done

echo "Done. Optimized file(s) into $OUTPUT_DIR"
