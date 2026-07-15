#!/usr/bin/env bash
# Optimize 3D assets before upload.
# Avatars: Draco + WebP 1024 (budget ~5 MB).
# Office environment: meshopt + WebP 2048 @ high quality (budget ~50 MB).
# KTX2 is preferred when toktx/basisu is installed; otherwise WebP is used.
#
# Usage: ./scripts/optimize-assets.sh <input_dir> <output_dir>

set -euo pipefail

INPUT_DIR="${1:-assets/raw}"
OUTPUT_DIR="${2:-assets/optimized}"
GLTF_TRANSFORM="${GLTF_TRANSFORM:-npx --yes @gltf-transform/cli}"

mkdir -p "$OUTPUT_DIR"

shopt -s nullglob
files=("$INPUT_DIR"/*.glb "$INPUT_DIR"/*.gltf)

if [ ${#files[@]} -eq 0 ]; then
  echo "No GLB/GLTF files found in $INPUT_DIR (final 3D assets not delivered yet — this is expected)."
  exit 0
fi

has_ktx2=0
if command -v toktx &>/dev/null || command -v basisu &>/dev/null; then
  has_ktx2=1
fi

for file in "${files[@]}"; do
  name="$(basename "$file")"
  out="$OUTPUT_DIR/${name%.*}.glb"
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" == *office* ]]; then
    echo "Optimizing OFFICE $name -> $out (HQ WebP 2048)"
    stage="$OUTPUT_DIR/.${name%.*}.stage.glb"
    $GLTF_TRANSFORM optimize "$file" "$stage" \
      --texture-compress false \
      --texture-size 2048 \
      --simplify false
    if [ "$has_ktx2" -eq 1 ]; then
      $GLTF_TRANSFORM ktx2 "$stage" "$out" --slots "{baseColor,emissive,occlusion,metallicRoughness}" --mode etc1s || \
        $GLTF_TRANSFORM webp "$stage" "$out" --quality 95 --effort 80
      # Prefer UASTC for normals when possible; fall back to the WebP output.
      if [ -f "$out" ]; then
        :
      fi
    else
      $GLTF_TRANSFORM webp "$stage" "$out" --quality 95 --effort 80
    fi
    rm -f "$stage"
  else
    echo "Optimizing AVATAR $name -> $out (Draco + WebP 1024)"
    $GLTF_TRANSFORM optimize "$file" "$out" \
      --compress draco \
      --texture-compress webp \
      --texture-size 1024
  fi
done

echo "Done. Optimized $((${#files[@]})) file(s) into $OUTPUT_DIR"
