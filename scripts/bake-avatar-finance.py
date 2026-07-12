#!/usr/bin/env python3
"""Merge finance female character mesh with Meshy biped animations.

Maps Meshy clip names → AgentVisualState, copies channels onto the character
skeleton (bones remapped by name), and writes a single catalog-ready GLB.

Usage:
  python3 scripts/bake-avatar-finance.py \\
    Femal_finance_Character_V3_Rigg_biped_Character_output.glb \\
    Femal_finance_Character_V3_Rigg_biped_Meshy_AI_Meshy_Merged_Animations.glb \\
    -o assets/raw/avatar_finance.glb
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path
from typing import Any

# AgentVisualState → preferred Meshy source clip (first match wins).
CLIP_MAP: dict[str, list[str]] = {
    "idle": ["Idle_9", "Chair_Sit_Idle_F"],
    "walking": ["Walking", "Casual_Walk_inplace"],
    "typing": ["Sitting_Answering_Questions"],
    "working": ["Sit_on_Chair_Arms_Crossed", "Chair_Sit_Idle_M"],
    "thinking": ["Sit_Hands_on_Head_Lean_Back"],
    "talking": ["Sitting_Answering_Questions"],
    "waiting": ["Chair_Sit_Idle_F", "Chair_Sit_Idle_M"],
    "blocked": ["Sit_Finger_Wag_No"],
    "celebrating": ["Victory_Cheer", "Sit_Cheer_with_Left_Hand"],
    "away": ["Dozing_Elderly"],
    "offline": ["Dozing_Elderly"],
    "reviewing": ["Chair_Sit_Idle_M", "Chair_Sit_Idle_F"],
    "learning": ["Sitting_Answering_Questions"],
    "requesting_approval": ["Sit_Cheer_with_Left_Hand", "Victory_Cheer"],
}


def load_glb(path: Path) -> tuple[dict[str, Any], bytes]:
    data = path.read_bytes()
    magic, version, length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        raise SystemExit(f"not a GLB: {path}")
    offset = 12
    json_chunk: dict[str, Any] | None = None
    bin_chunk = b""
    while offset < length:
        chunk_len, chunk_type = struct.unpack_from("<I4s", data, offset)
        offset += 8
        chunk = data[offset : offset + chunk_len]
        offset += chunk_len
        if chunk_type == b"JSON":
            json_chunk = json.loads(chunk.decode("utf-8"))
        elif chunk_type == b"BIN\x00":
            bin_chunk = chunk
    if json_chunk is None:
        raise SystemExit("GLB missing JSON chunk")
    return json_chunk, bin_chunk


def write_glb(path: Path, gltf: dict[str, Any], bin_blob: bytes) -> None:
    json_bytes = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    json_pad = (4 - (len(json_bytes) % 4)) % 4
    json_bytes += b" " * json_pad
    bin_pad = (4 - (len(bin_blob) % 4)) % 4
    bin_blob = bin_blob + (b"\x00" * bin_pad)

    total = 12 + 8 + len(json_bytes) + 8 + len(bin_blob)
    out = bytearray()
    out += struct.pack("<4sII", b"glTF", 2, total)
    out += struct.pack("<I4s", len(json_bytes), b"JSON")
    out += json_bytes
    out += struct.pack("<I4s", len(bin_blob), b"BIN\x00")
    out += bin_blob
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(out)


def node_index_by_name(nodes: list[dict[str, Any]]) -> dict[str, int]:
    return {n.get("name", f"node_{i}"): i for i, n in enumerate(nodes)}


class BufferBuilder:
    def __init__(self, existing: bytes):
        self.data = bytearray(existing)
        while len(self.data) % 4:
            self.data.append(0)

    def add(self, blob: bytes) -> tuple[int, int]:
        while len(self.data) % 4:
            self.data.append(0)
        offset = len(self.data)
        self.data.extend(blob)
        return offset, len(blob)


def append_accessor(
    gltf: dict[str, Any],
    builder: BufferBuilder,
    blob: bytes,
    *,
    component_type: int,
    type_name: str,
    count: int,
    min_v: list[float] | None = None,
    max_v: list[float] | None = None,
) -> int:
    offset, length = builder.add(blob)
    buffer_views = gltf.setdefault("bufferViews", [])
    bv_index = len(buffer_views)
    buffer_views.append({"buffer": 0, "byteOffset": offset, "byteLength": length})

    accessors = gltf.setdefault("accessors", [])
    acc: dict[str, Any] = {
        "bufferView": bv_index,
        "componentType": component_type,
        "count": count,
        "type": type_name,
    }
    if min_v is not None:
        acc["min"] = min_v
    if max_v is not None:
        acc["max"] = max_v
    accessors.append(acc)
    return len(accessors) - 1


def read_accessor_bytes(gltf: dict[str, Any], bin_blob: bytes, accessor_index: int) -> bytes:
    acc = gltf["accessors"][accessor_index]
    bv = gltf["bufferViews"][acc["bufferView"]]
    offset = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    comp = acc["componentType"]
    typ = acc["type"]
    count = acc["count"]
    comp_size = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}[comp]
    ncomp = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[typ]
    stride = bv.get("byteStride") or (comp_size * ncomp)
    if stride == comp_size * ncomp:
        return bin_blob[offset : offset + count * stride]
    out = bytearray()
    for i in range(count):
        start = offset + i * stride
        out.extend(bin_blob[start : start + comp_size * ncomp])
    return bytes(out)


def copy_accessor(
    dst_gltf: dict[str, Any],
    builder: BufferBuilder,
    src_gltf: dict[str, Any],
    src_bin: bytes,
    src_acc_i: int,
) -> int:
    acc = src_gltf["accessors"][src_acc_i]
    blob = read_accessor_bytes(src_gltf, src_bin, src_acc_i)
    return append_accessor(
        dst_gltf,
        builder,
        blob,
        component_type=acc["componentType"],
        type_name=acc["type"],
        count=acc["count"],
        min_v=acc.get("min"),
        max_v=acc.get("max"),
    )


def find_anim(anims: list[dict[str, Any]], candidates: list[str]) -> dict[str, Any] | None:
    by_lower = {(a.get("name") or "").lower(): a for a in anims}
    for cand in candidates:
        hit = by_lower.get(cand.lower())
        if hit:
            return hit
    # Fuzzy contains
    for cand in candidates:
        key = cand.lower()
        for name, anim in by_lower.items():
            if key in name or name in key:
                return anim
    return None


def copy_animation(
    *,
    out_gltf: dict[str, Any],
    builder: BufferBuilder,
    char_by: dict[str, int],
    src_gltf: dict[str, Any],
    src_bin: bytes,
    src_anim: dict[str, Any],
    out_name: str,
) -> dict[str, Any]:
    src_nodes = src_gltf["nodes"]
    src_by_idx_name = {i: n.get("name") for i, n in enumerate(src_nodes)}
    new_channels: list[dict[str, Any]] = []
    new_samplers: list[dict[str, Any]] = []
    skipped = 0

    for ch in src_anim["channels"]:
        bone = src_by_idx_name.get(ch["target"]["node"])
        if bone not in char_by:
            skipped += 1
            continue
        samp = src_anim["samplers"][ch["sampler"]]
        in_acc = copy_accessor(out_gltf, builder, src_gltf, src_bin, samp["input"])
        out_acc = copy_accessor(out_gltf, builder, src_gltf, src_bin, samp["output"])
        new_samplers.append(
            {
                "input": in_acc,
                "output": out_acc,
                "interpolation": samp.get("interpolation", "LINEAR"),
            }
        )
        new_channels.append(
            {
                "sampler": len(new_samplers) - 1,
                "target": {"node": char_by[bone], "path": ch["target"]["path"]},
            }
        )

    if skipped:
        print(f"  warning: {out_name}: skipped {skipped} channels (unknown bones)", file=sys.stderr)
    if not new_channels:
        raise SystemExit(f"no channels copied for {out_name} from {src_anim.get('name')}")

    return {"name": out_name, "channels": new_channels, "samplers": new_samplers}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("character", type=Path)
    parser.add_argument("animations", type=Path)
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()

    char_gltf, char_bin = load_glb(args.character)
    anim_gltf, anim_bin = load_glb(args.animations)

    char_by = node_index_by_name(char_gltf["nodes"])
    required = ["Hips", "LeftArm", "RightArm", "LeftUpLeg", "Head"]
    missing = [n for n in required if n not in char_by]
    if missing:
        raise SystemExit(f"missing Mixamo bones on character: {missing}")

    out = json.loads(json.dumps(char_gltf))
    out["animations"] = []
    builder = BufferBuilder(char_bin)
    src_anims = anim_gltf.get("animations") or []

    print(f"Source clips: {[a.get('name') for a in src_anims]}")

    for state, candidates in CLIP_MAP.items():
        src = find_anim(src_anims, candidates)
        if src is None:
            print(f"error: no source clip for {state} (tried {candidates})", file=sys.stderr)
            raise SystemExit(1)
        print(f"  {state} ← {src.get('name')}")
        out["animations"].append(
            copy_animation(
                out_gltf=out,
                builder=builder,
                char_by=char_by,
                src_gltf=anim_gltf,
                src_bin=anim_bin,
                src_anim=src,
                out_name=state,
            )
        )

    out.setdefault("buffers", [{"byteLength": 0}])[0]["byteLength"] = len(builder.data)
    write_glb(args.output, out, bytes(builder.data))

    names = [a.get("name") for a in out["animations"]]
    print(f"Wrote {args.output} ({args.output.stat().st_size} bytes)")
    print(f"Clips ({len(names)}): {names}")


if __name__ == "__main__":
    main()
