#!/usr/bin/env python3
"""Merge feminine character + walking clip, then bake the 13 missing AgentVisualState clips.

Mixamo biped bones (Hips, LeftArm, …). Walking is taken from the freelance file
and renamed to `walking`; other clips are procedural.

Usage:
  python3 scripts/bake-avatar-female.py \\
    Stylish_Feminine_Char_biped_Character_output.glb \\
    Stylish_Feminine_Char_biped_Animation_Walking_withSkin.glb \\
    -o assets/raw/avatar_female.glb
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path
from typing import Any

CLIP_NAMES = [
    "idle",
    "walking",
    "typing",
    "working",
    "thinking",
    "talking",
    "waiting",
    "blocked",
    "celebrating",
    "away",
    "offline",
    "reviewing",
    "learning",
    "requesting_approval",
]

BAKE_CLIPS = [c for c in CLIP_NAMES if c != "walking"]


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


def q_from_euler(rx: float, ry: float, rz: float) -> list[float]:
    cx, sx = math.cos(rx * 0.5), math.sin(rx * 0.5)
    cy, sy = math.cos(ry * 0.5), math.sin(ry * 0.5)
    cz, sz = math.cos(rz * 0.5), math.sin(rz * 0.5)
    return q_normalize(
        [
            sx * cy * cz - cx * sy * sz,
            cx * sy * cz + sx * cy * sz,
            cx * cy * sz - sx * sy * cz,
            cx * cy * cz + sx * sy * sz,
        ]
    )


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


def sample_times(duration: float, fps: float = 30.0) -> list[float]:
    n = max(2, int(round(duration * fps)) + 1)
    return [i * duration / (n - 1) for i in range(n)]


def pack_f32(values: list[float]) -> bytes:
    return struct.pack(f"<{len(values)}f", *values)


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
    bv: dict[str, Any] = {"buffer": 0, "byteOffset": offset, "byteLength": length}
    buffer_views.append(bv)

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
    # Strided — pack tightly
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


def merge_walking(
    char_gltf: dict[str, Any],
    char_bin: bytes,
    walk_gltf: dict[str, Any],
    walk_bin: bytes,
) -> tuple[dict[str, Any], bytes]:
    """Copy walking animation into character GLB, remap nodes by name, drop clip0."""
    char_nodes = char_gltf["nodes"]
    walk_nodes = walk_gltf["nodes"]
    char_by = node_index_by_name(char_nodes)
    walk_by_idx_name = {i: n.get("name") for i, n in enumerate(walk_nodes)}

    walk_anim = None
    for a in walk_gltf.get("animations") or []:
        name = (a.get("name") or "").lower()
        if "walk" in name:
            walk_anim = a
            break
    if walk_anim is None:
        raise SystemExit("no walking animation found in walking GLB")

    # Start from character, wipe animations
    out = json.loads(json.dumps(char_gltf))
    out["animations"] = []
    builder = BufferBuilder(char_bin)

    new_channels: list[dict[str, Any]] = []
    new_samplers: list[dict[str, Any]] = []

    for ch in walk_anim["channels"]:
        src_node = ch["target"]["node"]
        bone = walk_by_idx_name.get(src_node)
        if bone not in char_by:
            print(f"warning: skip channel for unknown bone {bone!r}", file=sys.stderr)
            continue
        samp = walk_anim["samplers"][ch["sampler"]]
        in_acc = copy_accessor(out, builder, walk_gltf, walk_bin, samp["input"])
        out_acc = copy_accessor(out, builder, walk_gltf, walk_bin, samp["output"])
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

    out["animations"].append({"name": "walking", "channels": new_channels, "samplers": new_samplers})
    out.setdefault("buffers", [{"byteLength": 0}])[0]["byteLength"] = len(builder.data)
    return out, bytes(builder.data)


def make_channel(
    gltf: dict[str, Any],
    builder: BufferBuilder,
    node_i: int,
    path: str,
    times: list[float],
    values: list[float],
) -> tuple[dict[str, Any], dict[str, Any]]:
    type_name = "VEC3" if path == "translation" else "VEC4"
    comps = 3 if path == "translation" else 4
    if len(values) != len(times) * comps:
        raise ValueError(f"bad value count for {path}")
    input_acc = append_accessor(
        gltf,
        builder,
        pack_f32(times),
        component_type=5126,
        type_name="SCALAR",
        count=len(times),
        min_v=[times[0]],
        max_v=[times[-1]],
    )
    output_acc = append_accessor(
        gltf,
        builder,
        pack_f32(values),
        component_type=5126,
        type_name=type_name,
        count=len(times),
    )
    ch = {"sampler": None, "target": {"node": node_i, "path": path}}
    samp = {"input": input_acc, "output": output_acc, "interpolation": "LINEAR"}
    return ch, samp


def rot_track(
    gltf: dict[str, Any],
    builder: BufferBuilder,
    nodes: list[dict[str, Any]],
    node_i: int,
    times: list[float],
    deltas: list[tuple[float, float, float]],
) -> tuple[dict[str, Any], dict[str, Any]]:
    rest = rest_rotation(nodes[node_i])
    values: list[float] = []
    for rx, ry, rz in deltas:
        values.extend(q_mul(rest, q_from_euler(rx, ry, rz)))
    return make_channel(gltf, builder, node_i, "rotation", times, values)


def trans_track(
    gltf: dict[str, Any],
    builder: BufferBuilder,
    nodes: list[dict[str, Any]],
    node_i: int,
    times: list[float],
    deltas: list[tuple[float, float, float]],
) -> tuple[dict[str, Any], dict[str, Any]]:
    rest = rest_translation(nodes[node_i])
    values: list[float] = []
    for dx, dy, dz in deltas:
        values.extend([rest[0] + dx, rest[1] + dy, rest[2] + dz])
    return make_channel(gltf, builder, node_i, "translation", times, values)


def vadd(a: tuple[float, float, float], b: tuple[float, float, float]) -> tuple[float, float, float]:
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


# Mixamo-ish local deltas (approximate). Bind is usually A/T-pose.
ARM_DOWN_L = (0.15, 0.0, 1.25)
ARM_DOWN_R = (0.15, 0.0, -1.25)
FOREARM_L = (-0.35, 0.0, 0.1)
FOREARM_R = (-0.35, 0.0, -0.1)
# Sitting: hips drop + thighs bend forward
SIT_HIPS_Y = -0.42
SIT_THIGH_L = (1.15, 0.0, 0.05)
SIT_THIGH_R = (1.15, 0.0, -0.05)
SIT_LEG_L = (-1.35, 0.0, 0.0)
SIT_LEG_R = (-1.35, 0.0, 0.0)


def build_mixamo_clip(
    name: str,
    gltf: dict[str, Any],
    builder: BufferBuilder,
    nodes: list[dict[str, Any]],
    by_name: dict[str, int],
) -> dict[str, Any] | None:
    channels: list[dict[str, Any]] = []
    samplers: list[dict[str, Any]] = []

    def add_rot(bone: str, times: list[float], deltas: list[tuple[float, float, float]]) -> None:
        if bone not in by_name:
            return
        ch, samp = rot_track(gltf, builder, nodes, by_name[bone], times, deltas)
        ch["sampler"] = len(samplers)
        samplers.append(samp)
        channels.append(ch)

    def add_trans(bone: str, times: list[float], deltas: list[tuple[float, float, float]]) -> None:
        if bone not in by_name:
            return
        ch, samp = trans_track(gltf, builder, nodes, by_name[bone], times, deltas)
        ch["sampler"] = len(samplers)
        samplers.append(samp)
        channels.append(ch)

    def arms_relaxed(times: list[float], l_extra=(0.0, 0.0, 0.0), r_extra=(0.0, 0.0, 0.0)) -> None:
        add_rot("LeftArm", times, [vadd(ARM_DOWN_L, l_extra) for _ in times])
        add_rot("RightArm", times, [vadd(ARM_DOWN_R, r_extra) for _ in times])
        add_rot("LeftForeArm", times, [FOREARM_L for _ in times])
        add_rot("RightForeArm", times, [FOREARM_R for _ in times])

    def sit_pose(times: list[float]) -> None:
        add_trans("Hips", times, [(0.0, SIT_HIPS_Y, 0.05) for _ in times])
        add_rot("LeftUpLeg", times, [SIT_THIGH_L for _ in times])
        add_rot("RightUpLeg", times, [SIT_THIGH_R for _ in times])
        add_rot("LeftLeg", times, [SIT_LEG_L for _ in times])
        add_rot("RightLeg", times, [SIT_LEG_R for _ in times])
        add_rot("Spine", times, [(0.08, 0.0, 0.0) for _ in times])

    def stand_legs(times: list[float]) -> None:
        add_trans("Hips", times, [(0.0, 0.0, 0.0) for _ in times])
        add_rot("LeftUpLeg", times, [(0.0, 0.0, 0.0) for _ in times])
        add_rot("RightUpLeg", times, [(0.0, 0.0, 0.0) for _ in times])
        add_rot("LeftLeg", times, [(0.0, 0.0, 0.0) for _ in times])
        add_rot("RightLeg", times, [(0.0, 0.0, 0.0) for _ in times])

    if name == "idle":
        duration = 2.4
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        stand_legs(times)
        add_rot("Spine01", times, [(0.03 * math.sin(u * math.pi * 2), 0.0, 0.0) for u in us])
        add_rot("Spine02", times, [(0.02 * math.sin(u * math.pi * 2 + 0.3), 0.0, 0.0) for u in us])
        add_rot(
            "Head",
            times,
            [(0.03 * math.sin(u * math.pi * 2 * 0.5), 0.04 * math.sin(u * math.pi * 2 * 0.35), 0.0) for u in us],
        )
        add_rot(
            "LeftArm",
            times,
            [vadd(ARM_DOWN_L, (0.03 * math.sin(u * math.pi * 2 + 1.0), 0.0, 0.03)) for u in us],
        )
        add_rot(
            "RightArm",
            times,
            [vadd(ARM_DOWN_R, (0.03 * math.sin(u * math.pi * 2 + 2.0), 0.0, -0.03)) for u in us],
        )
        add_rot("LeftForeArm", times, [FOREARM_L for _ in times])
        add_rot("RightForeArm", times, [FOREARM_R for _ in times])

    elif name == "typing":
        duration = 1.2
        times = sample_times(duration, fps=36)
        us = [ti / duration for ti in times]
        sit_pose(times)
        add_rot("LeftArm", times, [vadd(ARM_DOWN_L, (-0.55, 0.4, -0.35)) for _ in us])
        add_rot("RightArm", times, [vadd(ARM_DOWN_R, (-0.55, -0.4, 0.35)) for _ in us])
        add_rot(
            "LeftForeArm",
            times,
            [vadd(FOREARM_L, (-0.5 + 0.08 * math.sin(u * math.pi * 2 * 5), 0.0, 0.0)) for u in us],
        )
        add_rot(
            "RightForeArm",
            times,
            [vadd(FOREARM_R, (-0.5 + 0.08 * math.sin(u * math.pi * 2 * 5 + 1.2), 0.0, 0.0)) for u in us],
        )
        add_rot(
            "Head",
            times,
            [(0.25 + 0.02 * math.sin(u * math.pi * 2), 0.03 * math.sin(u * math.pi * 2 * 0.7), 0.0) for u in us],
        )
        add_rot("LeftHand", times, [(0.2 * math.sin(u * math.pi * 2 * 5), 0.0, 0.0) for u in us])
        add_rot("RightHand", times, [(0.2 * math.sin(u * math.pi * 2 * 5 + 1.0), 0.0, 0.0) for u in us])

    elif name == "working":
        duration = 2.0
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        sit_pose(times)
        add_rot(
            "RightArm",
            times,
            [vadd(ARM_DOWN_R, (-0.4, -0.25, 0.2 + 0.12 * math.sin(u * math.pi * 2))) for u in us],
        )
        add_rot(
            "RightForeArm",
            times,
            [vadd(FOREARM_R, (-0.3 + 0.1 * math.sin(u * math.pi * 2 + 0.5), 0.0, 0.0)) for u in us],
        )
        add_rot("LeftArm", times, [vadd(ARM_DOWN_L, (-0.3, 0.2, -0.15)) for _ in us])
        add_rot("LeftForeArm", times, [FOREARM_L for _ in us])
        add_rot(
            "Head",
            times,
            [(0.08 * math.sin(u * math.pi * 2), 0.1 * math.sin(u * math.pi * 2 * 0.5), 0.0) for u in us],
        )

    elif name == "thinking":
        duration = 2.5
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        sit_pose(times)
        add_rot("RightArm", times, [vadd(ARM_DOWN_R, (-1.0, -0.6, 0.6)) for _ in us])
        add_rot("RightForeArm", times, [(-1.4, 0.3, -0.2) for _ in us])
        add_rot("RightHand", times, [(0.3, 0.3, 0.3) for _ in us])
        add_rot("LeftArm", times, [vadd(ARM_DOWN_L, (0.0, 0.0, 0.0)) for _ in us])
        add_rot("LeftForeArm", times, [FOREARM_L for _ in us])
        add_rot(
            "Head",
            times,
            [(0.15, 0.2 + 0.05 * math.sin(u * math.pi * 2 * 0.4), 0.08) for u in us],
        )

    elif name == "talking":
        duration = 1.6
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        sit_pose(times)
        add_rot(
            "Head",
            times,
            [(0.08 * math.sin(u * math.pi * 2 * 2.2), 0.06 * math.sin(u * math.pi * 2), 0.0) for u in us],
        )
        add_rot(
            "RightArm",
            times,
            [vadd(ARM_DOWN_R, (-0.3, -0.2, 0.25 + 0.18 * math.sin(u * math.pi * 2))) for u in us],
        )
        add_rot(
            "RightForeArm",
            times,
            [vadd(FOREARM_R, (-0.2 + 0.12 * math.sin(u * math.pi * 2 + 0.3), 0.0, 0.0)) for u in us],
        )
        add_rot("LeftArm", times, [vadd(ARM_DOWN_L, (0.0, 0.0, 0.0)) for _ in us])
        add_rot("LeftForeArm", times, [FOREARM_L for _ in us])

    elif name == "waiting":
        duration = 3.0
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        sit_pose(times)
        arms_relaxed(times)
        add_rot(
            "Head",
            times,
            [(0.02, 0.25 * math.sin(u * math.pi * 2 * 0.25), 0.0) for u in us],
        )
        add_rot("Spine", times, [(0.05, 0.04 * math.sin(u * math.pi * 2 * 0.3), 0.0) for u in us])

    elif name == "blocked":
        duration = 1.0
        times = sample_times(duration, fps=36)
        us = [ti / duration for ti in times]
        sit_pose(times)
        add_rot("Head", times, [(0.05, 0.18 * math.sin(u * math.pi * 2 * 3), 0.0) for u in us])
        arms_relaxed(times, l_extra=(0.1, 0.1, 0.15), r_extra=(0.1, -0.1, -0.15))
        add_rot("Spine01", times, [(0.1, 0.0, 0.0) for _ in us])

    elif name == "celebrating":
        duration = 1.2
        times = sample_times(duration, fps=36)
        us = [ti / duration for ti in times]
        stand_legs(times)
        add_rot(
            "LeftArm",
            times,
            [(-1.2 + 0.12 * math.sin(u * math.pi * 2 * 2), 0.3, 0.4) for u in us],
        )
        add_rot(
            "RightArm",
            times,
            [(-1.2 + 0.12 * math.sin(u * math.pi * 2 * 2 + math.pi), -0.3, -0.4) for u in us],
        )
        add_rot("LeftForeArm", times, [(-0.3, 0.0, 0.0) for _ in us])
        add_rot("RightForeArm", times, [(-0.3, 0.0, 0.0) for _ in us])
        add_trans("Hips", times, [(0.0, 0.08 * abs(math.sin(u * math.pi * 2 * 2)), 0.0) for u in us])
        add_rot("Head", times, [(-0.1, 0.0, 0.0) for _ in us])

    elif name == "away":
        duration = 3.0
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        sit_pose(times)
        add_rot("Spine01", times, [(0.2, 0.0, 0.0) for _ in us])
        add_rot("Head", times, [(0.3, 0.15, 0.0) for _ in us])
        arms_relaxed(times, l_extra=(0.1, 0.0, 0.08), r_extra=(0.1, 0.0, -0.08))
        add_rot("Spine", times, [(0.02 * math.sin(u * math.pi * 2 * 0.3), 0.0, 0.0) for u in us])

    elif name == "offline":
        duration = 2.0
        times = sample_times(duration, fps=12)
        sit_pose(times)
        add_rot("Head", times, [(0.15, 0.0, 0.0) for _ in times])
        arms_relaxed(times)

    elif name == "reviewing":
        duration = 2.4
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        sit_pose(times)
        add_rot(
            "Head",
            times,
            [(0.35, 0.3 * math.sin(u * math.pi * 2 * 0.4), 0.0) for u in us],
        )
        add_rot("LeftArm", times, [vadd(ARM_DOWN_L, (-0.4, 0.25, -0.2)) for _ in us])
        add_rot("RightArm", times, [vadd(ARM_DOWN_R, (-0.35, -0.2, 0.15)) for _ in us])
        add_rot("LeftForeArm", times, [FOREARM_L for _ in us])
        add_rot(
            "RightForeArm",
            times,
            [vadd(FOREARM_R, (-0.2 + 0.05 * math.sin(u * math.pi * 2), 0.0, 0.0)) for u in us],
        )

    elif name == "learning":
        duration = 2.2
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        sit_pose(times)
        add_rot(
            "Head",
            times,
            [
                (
                    0.15 + 0.06 * math.sin(u * math.pi * 2 * 0.6),
                    0.08 * math.sin(u * math.pi * 2 * 0.3),
                    0.0,
                )
                for u in us
            ],
        )
        add_rot("LeftArm", times, [vadd(ARM_DOWN_L, (-0.45, 0.3, -0.25)) for _ in us])
        add_rot("RightArm", times, [vadd(ARM_DOWN_R, (-0.45, -0.3, 0.25)) for _ in us])
        add_rot(
            "LeftForeArm",
            times,
            [vadd(FOREARM_L, (-0.25 + 0.06 * math.sin(u * math.pi * 2 * 2), 0.0, 0.0)) for u in us],
        )
        add_rot(
            "RightForeArm",
            times,
            [vadd(FOREARM_R, (-0.25 + 0.06 * math.sin(u * math.pi * 2 * 2 + 1.0), 0.0, 0.0)) for u in us],
        )

    elif name == "requesting_approval":
        duration = 1.8
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        sit_pose(times)
        add_rot(
            "RightArm",
            times,
            [(-1.0 + 0.1 * math.sin(u * math.pi * 2 * 1.5), -0.25, -0.4) for u in us],
        )
        add_rot(
            "RightForeArm",
            times,
            [(-0.3, 0.0, 0.2 * math.sin(u * math.pi * 2 * 1.5)) for u in us],
        )
        add_rot("RightHand", times, [(0.0, 0.0, 0.15 * math.sin(u * math.pi * 2 * 1.5)) for u in us])
        add_rot("LeftArm", times, [vadd(ARM_DOWN_L, (0.0, 0.0, 0.0)) for _ in us])
        add_rot("LeftForeArm", times, [FOREARM_L for _ in us])
        add_rot("Head", times, [(-0.05, 0.1 * math.sin(u * math.pi * 2 * 0.5), 0.0) for u in us])

    else:
        return None

    if not channels:
        return None
    return {"name": name, "channels": channels, "samplers": samplers}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("character", type=Path)
    parser.add_argument("walking", type=Path)
    parser.add_argument("-o", "--output", type=Path, required=True)
    args = parser.parse_args()

    char_gltf, char_bin = load_glb(args.character)
    walk_gltf, walk_bin = load_glb(args.walking)

    merged, merged_bin = merge_walking(char_gltf, char_bin, walk_gltf, walk_bin)
    nodes = merged["nodes"]
    by_name = node_index_by_name(nodes)

    required = ["Hips", "LeftArm", "RightArm", "LeftUpLeg", "Head"]
    missing = [n for n in required if n not in by_name]
    if missing:
        raise SystemExit(f"missing Mixamo bones: {missing}")

    builder = BufferBuilder(merged_bin)
    animations = merged.setdefault("animations", [])
    baked = 0
    for clip in BAKE_CLIPS:
        anim = build_mixamo_clip(clip, merged, builder, nodes, by_name)
        if anim:
            animations.append(anim)
            baked += 1
        else:
            print(f"warning: failed to bake {clip}", file=sys.stderr)

    merged.setdefault("buffers", [{"byteLength": 0}])[0]["byteLength"] = len(builder.data)
    write_glb(args.output, merged, bytes(builder.data))

    names = [a.get("name") for a in merged.get("animations", [])]
    print(f"Wrote {args.output} ({args.output.stat().st_size} bytes)")
    print(f"Clips ({len(names)}): {names} (baked {baked}/{len(BAKE_CLIPS)} + walking)")


if __name__ == "__main__":
    main()
