#!/usr/bin/env python3
"""Retarget a Mixamo `walking` clip onto a Rigify male avatar GLB.

Replaces (or inserts) the AgentVisualState `walking` animation using local
rotation/translation deltas from the Mixamo rest pose applied onto Rigify rest.

Usage:
  python3 scripts/retarget-mixamo-walk-to-male.py \\
    apps/web/public/assets3d/avatar_male.bb932add4243.glb \\
    apps/web/public/assets3d/avatar_female.dbad3a7ec430.glb \\
    -o assets/raw/avatar_male.glb
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path
from typing import Any

# Mixamo biped → Rigify stretch bones (major contributors to a walk cycle).
BONE_MAP: dict[str, str] = {
    "Hips": "root.x",
    "Spine": "spine_01.x",
    "Spine01": "spine_02.x",
    "Spine02": "spine_03.x",
    "Neck": "neck.x",
    "Head": "head.x",
    "LeftShoulder": "shoulder.l",
    "RightShoulder": "shoulder.r",
    "LeftArm": "arm_stretch.l",
    "RightArm": "arm_stretch.r",
    "LeftForeArm": "forearm_stretch.l",
    "RightForeArm": "forearm_stretch.r",
    "LeftHand": "hand.l",
    "RightHand": "hand.r",
    "LeftUpLeg": "thigh_stretch.l",
    "RightUpLeg": "thigh_stretch.r",
    "LeftLeg": "leg_stretch.l",
    "RightLeg": "leg_stretch.r",
    "LeftFoot": "foot.l",
    "RightFoot": "foot.r",
}

# Mixamo is authored in centimeters; Rigify male is meters.
CM_TO_M = 0.01


def q_mul(a: list[float], b: list[float]) -> list[float]:
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return [
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    ]


def q_normalize(q: list[float]) -> list[float]:
    n = math.sqrt(sum(c * c for c in q)) or 1.0
    return [c / n for c in q]


def q_conj(q: list[float]) -> list[float]:
    return [-q[0], -q[1], -q[2], q[3]]


def q_inv(q: list[float]) -> list[float]:
    return q_normalize(q_conj(q))


def rest_rotation(node: dict[str, Any]) -> list[float]:
    r = node.get("rotation")
    if r and len(r) == 4:
        return list(r)
    return [0.0, 0.0, 0.0, 1.0]


def rest_translation(node: dict[str, Any]) -> list[float]:
    t = node.get("translation")
    if t and len(t) == 3:
        return list(t)
    return [0.0, 0.0, 0.0]


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
    bvs = gltf.setdefault("bufferViews", [])
    bvs.append({"buffer": 0, "byteOffset": offset, "byteLength": length})
    accs = gltf.setdefault("accessors", [])
    acc: dict[str, Any] = {
        "bufferView": len(bvs) - 1,
        "componentType": component_type,
        "count": count,
        "type": type_name,
    }
    if min_v is not None:
        acc["min"] = min_v
    if max_v is not None:
        acc["max"] = max_v
    accs.append(acc)
    return len(accs) - 1


def read_f32_accessor(gltf: dict[str, Any], bin_blob: bytes, accessor_index: int) -> list[float]:
    acc = gltf["accessors"][accessor_index]
    bv = gltf["bufferViews"][acc["bufferView"]]
    offset = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    typ = acc["type"]
    count = acc["count"]
    ncomp = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[typ]
    stride = bv.get("byteStride") or (4 * ncomp)
    out: list[float] = []
    for i in range(count):
        start = offset + i * stride
        out.extend(struct.unpack_from(f"<{ncomp}f", bin_blob, start))
    return out


def pack_f32(values: list[float]) -> bytes:
    return struct.pack(f"<{len(values)}f", *values)


def find_walking(anims: list[dict[str, Any]]) -> dict[str, Any]:
    for a in anims:
        if (a.get("name") or "").lower() == "walking":
            return a
    for a in anims:
        if "walk" in (a.get("name") or "").lower():
            return a
    raise SystemExit("no walking clip in Mixamo source")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("male", type=Path, help="Rigify male GLB (destination)")
    parser.add_argument("mixamo", type=Path, help="Mixamo GLB with a walking clip (source)")
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()

    male_gltf, male_bin = load_glb(args.male)
    mix_gltf, mix_bin = load_glb(args.mixamo)

    male_nodes = male_gltf["nodes"]
    mix_nodes = mix_gltf["nodes"]
    male_by = node_index_by_name(male_nodes)
    mix_by = node_index_by_name(mix_nodes)

    walk = find_walking(mix_gltf.get("animations") or [])
    print(f"Source walking: {walk.get('name')} ({len(walk['channels'])} channels)")

    out = json.loads(json.dumps(male_gltf))
    # Drop existing walking so we replace it cleanly.
    out["animations"] = [a for a in (out.get("animations") or []) if (a.get("name") or "") != "walking"]
    builder = BufferBuilder(male_bin)

    new_channels: list[dict[str, Any]] = []
    new_samplers: list[dict[str, Any]] = []
    mapped = 0
    skipped = 0

    mix_idx_name = {i: n.get("name") for i, n in enumerate(mix_nodes)}

    for ch in walk["channels"]:
        src_bone = mix_idx_name.get(ch["target"]["node"])
        dst_bone = BONE_MAP.get(src_bone or "")
        if not dst_bone or dst_bone not in male_by:
            skipped += 1
            continue

        path = ch["target"]["path"]
        if path not in ("rotation", "translation"):
            skipped += 1
            continue

        samp = walk["samplers"][ch["sampler"]]
        times = read_f32_accessor(mix_gltf, mix_bin, samp["input"])
        values = read_f32_accessor(mix_gltf, mix_bin, samp["output"])
        n_keys = len(times)

        src_rest_r = rest_rotation(mix_nodes[mix_by[src_bone]])
        src_rest_t = rest_translation(mix_nodes[mix_by[src_bone]])
        dst_rest_r = rest_rotation(male_nodes[male_by[dst_bone]])
        dst_rest_t = rest_translation(male_nodes[male_by[dst_bone]])

        out_values: list[float] = []
        if path == "rotation":
            inv_src = q_inv(src_rest_r)
            for i in range(n_keys):
                q = values[i * 4 : (i + 1) * 4]
                delta = q_mul(inv_src, q)
                out_values.extend(q_normalize(q_mul(dst_rest_r, delta)))
            type_name = "VEC4"
            comps = 4
        else:
            # Only transfer relative bob / sway; kill large forward root motion
            # so the office can move the character in world space.
            for i in range(n_keys):
                t = values[i * 3 : (i + 1) * 3]
                dx = (t[0] - src_rest_t[0]) * CM_TO_M
                dy = (t[1] - src_rest_t[1]) * CM_TO_M
                dz = (t[2] - src_rest_t[2]) * CM_TO_M
                if src_bone == "Hips":
                    # Keep vertical bob + tiny lateral sway; zero forward travel.
                    dx *= 0.35
                    dz = 0.0
                out_values.extend(
                    [dst_rest_t[0] + dx, dst_rest_t[1] + dy, dst_rest_t[2] + dz]
                )
            type_name = "VEC3"
            comps = 3

        in_acc = append_accessor(
            out,
            builder,
            pack_f32(times),
            component_type=5126,
            type_name="SCALAR",
            count=n_keys,
            min_v=[times[0]],
            max_v=[times[-1]],
        )
        out_acc = append_accessor(
            out,
            builder,
            pack_f32(out_values),
            component_type=5126,
            type_name=type_name,
            count=n_keys,
        )
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
                "target": {"node": male_by[dst_bone], "path": path},
            }
        )
        mapped += 1

    if not new_channels:
        raise SystemExit("retarget produced no channels")

    out["animations"].append({"name": "walking", "channels": new_channels, "samplers": new_samplers})
    out.setdefault("buffers", [{"byteLength": 0}])[0]["byteLength"] = len(builder.data)
    write_glb(args.output, out, bytes(builder.data))

    names = [a.get("name") for a in out["animations"]]
    print(f"Wrote {args.output} ({args.output.stat().st_size} bytes)")
    print(f"Retargeted channels={mapped} skipped={skipped}")
    print(f"Clips: {names}")


if __name__ == "__main__":
    main()
