#!/usr/bin/env bash
# Optimize 3D assets before upload.
# Avatars: Draco + WebP 1024 (budget ~5 MB).
# Office environment:
#   - desktop: max texture 2048 + WebP
#   - mobile:  max texture 1024 for tablet VRAM
#   - ALWAYS dequantize + expand GPU instances (Windows ANGLE / Chrome
#     mishandles KHR_mesh_quantization SHORT positions → vertex explosion).
#   - NEVER re-apply quantize on office assets.
# KTX2 is preferred when toktx/basisu is installed; currently office uses WebP.
#
# Usage: ./scripts/optimize-assets.sh <input_dir> <output_dir>

set -euo pipefail

INPUT_DIR="${1:-assets/raw}"
OUTPUT_DIR="${2:-assets/optimized}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLTF_TRANSFORM=(npx --yes @gltf-transform/cli)
# expand-office-instances.mjs needs the gltf-transform SDK packages.
EXPAND_NPX=(npx --yes -p @gltf-transform/core@4.4.2 -p @gltf-transform/extensions@4.4.2 -p @gltf-transform/functions@4.4.2)

mkdir -p "$OUTPUT_DIR"

shopt -s nullglob
files=("$INPUT_DIR"/*.glb "$INPUT_DIR"/*.gltf)

if [ ${#files[@]} -eq 0 ]; then
  echo "No GLB/GLTF files found in $INPUT_DIR (final 3D assets not delivered yet — this is expected)."
  exit 0
fi

# Resize → dequantize → expand GPU instancing. Never quantize office meshes.
harden_office() {
  local src="$1"
  local dest="$2"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/office-harden.XXXXXX.glb")"
  "${GLTF_TRANSFORM[@]}" dequantize "$src" "$tmp"
  "${EXPAND_NPX[@]}" node "$SCRIPT_DIR/expand-office-instances.mjs" "$tmp" "$dest"
  rm -f "$tmp"
}

for file in "${files[@]}"; do
  name="$(basename "$file")"
  out="$OUTPUT_DIR/${name%.*}.glb"
  lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" == *office* ]] && [[ "$lower" != *mobile* ]]; then
    echo "Optimizing OFFICE $name -> desktop + mobile variants (float attrs, no GPU instancing)"
    desktop="$OUTPUT_DIR/office.glb"
    mobile="$OUTPUT_DIR/office.mobile.glb"
    desk_resized="$(mktemp "${TMPDIR:-/tmp}/office-desk.XXXXXX.glb")"
    mob_resized="$(mktemp "${TMPDIR:-/tmp}/office-mob.XXXXXX.glb")"
    "${GLTF_TRANSFORM[@]}" resize "$file" "$desk_resized" --width 2048 --height 2048
    "${GLTF_TRANSFORM[@]}" resize "$file" "$mob_resized" --width 1024 --height 1024
    harden_office "$desk_resized" "$desktop"
    harden_office "$mob_resized" "$mobile"
    rm -f "$desk_resized" "$mob_resized"
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
