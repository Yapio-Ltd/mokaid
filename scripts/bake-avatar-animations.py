#!/usr/bin/env python3
"""Bake procedural skeletal animation clips into a rigged avatar GLB.

Adds the 14 AgentVisualState clips expected by the Babylon office scene.
Walk is in-place (the scene moves the root in world space).

Usage:
  python3 scripts/bake-avatar-animations.py assets/raw/avatar_male.glb
  python3 scripts/bake-avatar-animations.py in.glb -o out.glb
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

# Joint name → (axis, amp_rad) helpers use bone local space approximations
# for a Rigify-like humanoid (+Y up, facing −Z / +Z depending on export).


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
    """XYZ intrinsic euler → quaternion [x,y,z,w]."""
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
        # Align to 4 bytes
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
    buffer_views.append(
        {
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": length,
            "target": 34962 if type_name != "SCALAR" else None,
        }
    )
    # Remove null target for SCALAR (animation inputs) — cleaner
    if buffer_views[-1]["target"] is None:
        del buffer_views[-1]["target"]

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


def make_channel(
    gltf: dict[str, Any],
    builder: BufferBuilder,
    node_i: int,
    path: str,
    times: list[float],
    values: list[float],
) -> dict[str, Any]:
    t_blob = pack_f32(times)
    v_blob = pack_f32(values)
    type_name = "VEC3" if path == "translation" else "VEC4"
    comps = 3 if path == "translation" else 4

    input_acc = append_accessor(
        gltf,
        builder,
        t_blob,
        component_type=5126,
        type_name="SCALAR",
        count=len(times),
        min_v=[times[0]],
        max_v=[times[-1]],
    )
    output_acc = append_accessor(
        gltf,
        builder,
        v_blob,
        component_type=5126,
        type_name=type_name,
        count=len(times),
    )
    # Validate value count
    if len(values) != len(times) * comps:
        raise ValueError(f"bad value count for {path}: {len(values)} vs {len(times)*comps}")

    return {
        "sampler": None,  # filled by caller after appending sampler
        "target": {"node": node_i, "path": path},
        "_input": input_acc,
        "_output": output_acc,
    }


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
        q = q_mul(rest, q_from_euler(rx, ry, rz))
        values.extend(q)
    ch = make_channel(gltf, builder, node_i, "rotation", times, values)
    sampler = {
        "input": ch.pop("_input"),
        "output": ch.pop("_output"),
        "interpolation": "LINEAR",
    }
    return ch, sampler


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
    ch = make_channel(gltf, builder, node_i, "translation", times, values)
    sampler = {
        "input": ch.pop("_input"),
        "output": ch.pop("_output"),
        "interpolation": "LINEAR",
    }
    return ch, sampler


def finger_curl(t: float, phase: float, amp: float = 0.55) -> float:
    return amp * (0.55 + 0.45 * math.sin(t * math.pi * 2 * 4 + phase))


def vadd(a: tuple[float, float, float], b: tuple[float, float, float]) -> tuple[float, float, float]:
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


# Bind pose is T-pose. Swing arms down to the sides (not behind the back).
# On this Rigify export, negative Z on .l / positive Z on .r drops the arms
# forward-of-torso; the previous +1.45 / -1.45 signs pinned them rearward.
ARM_DOWN_L = (0.10, 0.22, -1.18)
ARM_DOWN_R = (0.10, -0.22, 1.18)
FOREARM_RELAX_L = (-0.32, 0.06, 0.10)
FOREARM_RELAX_R = (-0.32, -0.06, -0.10)
# Legs: keep rest unless walking — zero deltas reset mid-stride leftovers.
LEG_REST = (0.0, 0.0, 0.0)


def build_clip(
    name: str,
    gltf: dict[str, Any],
    builder: BufferBuilder,
    nodes: list[dict[str, Any]],
    by_name: dict[str, int],
) -> dict[str, Any] | None:
    """Return one glTF animation dict, or None if required bones missing."""

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

    def arms_down(
        times: list[float],
        *,
        l_extra: tuple[float, float, float] = (0.0, 0.0, 0.0),
        r_extra: tuple[float, float, float] = (0.0, 0.0, 0.0),
        l_fore: tuple[float, float, float] | None = None,
        r_fore: tuple[float, float, float] | None = None,
    ) -> None:
        add_rot("arm_stretch.l", times, [vadd(ARM_DOWN_L, l_extra) for _ in times])
        add_rot("arm_stretch.r", times, [vadd(ARM_DOWN_R, r_extra) for _ in times])
        add_rot("forearm_stretch.l", times, [l_fore if l_fore is not None else FOREARM_RELAX_L for _ in times])
        add_rot("forearm_stretch.r", times, [r_fore if r_fore is not None else FOREARM_RELAX_R for _ in times])

    def legs_rest(times: list[float]) -> None:
        add_rot("thigh_stretch.l", times, [LEG_REST for _ in times])
        add_rot("thigh_stretch.r", times, [LEG_REST for _ in times])
        add_rot("leg_stretch.l", times, [LEG_REST for _ in times])
        add_rot("leg_stretch.r", times, [LEG_REST for _ in times])

    if name == "idle":
        duration = 2.4
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        add_rot("spine_02.x", times, [(0.025 * math.sin(u * math.pi * 2), 0.0, 0.0) for u in us])
        add_rot("spine_03.x", times, [(0.018 * math.sin(u * math.pi * 2 + 0.4), 0.0, 0.0) for u in us])
        add_rot(
            "head.x",
            times,
            [(0.03 * math.sin(u * math.pi * 2 * 0.5), 0.04 * math.sin(u * math.pi * 2 * 0.35), 0.0) for u in us],
        )
        add_rot(
            "arm_stretch.l",
            times,
            [vadd(ARM_DOWN_L, (0.03 * math.sin(u * math.pi * 2 + 1.0), 0.02 * math.sin(u * math.pi * 2), 0.03)) for u in us],
        )
        add_rot(
            "arm_stretch.r",
            times,
            [vadd(ARM_DOWN_R, (0.03 * math.sin(u * math.pi * 2 + 2.0), -0.02 * math.sin(u * math.pi * 2), -0.03)) for u in us],
        )
        add_rot("forearm_stretch.l", times, [FOREARM_RELAX_L for _ in times])
        add_rot("forearm_stretch.r", times, [FOREARM_RELAX_R for _ in times])
        legs_rest(times)

    elif name == "walking":
        # In-place walk cycle tuned for this Rigify export.
        # Thigh bones sit near ±90° on Y in rest — sagittal swing is local Z.
        # Arms stay in ARM_DOWN and rock on Y (forward/back), opposite the legs.
        duration = 1.05
        times = sample_times(duration, fps=40)
        us = [ti / duration for ti in times]

        def gait(u: float, phase: float = 0.0) -> float:
            return math.sin(u * math.pi * 2 + phase)

        # Legs — opposite phase, moderate amplitude (avoid hyperextension)
        add_rot(
            "thigh_stretch.l",
            times,
            [(0.0, 0.0, 0.50 * gait(u)) for u in us],
        )
        add_rot(
            "thigh_stretch.r",
            times,
            [(0.0, 0.0, -0.50 * gait(u)) for u in us],
        )
        add_rot(
            "leg_stretch.l",
            times,
            [(0.0, 0.0, 0.65 * max(0.0, -gait(u))) for u in us],
        )
        add_rot(
            "leg_stretch.r",
            times,
            [(0.0, 0.0, -0.65 * max(0.0, gait(u))) for u in us],
        )
        # Feet tip slightly with the stride
        if "foot.l" in by_name:
            add_rot("foot.l", times, [(0.18 * max(0.0, gait(u)), 0.0, 0.0) for u in us])
        if "foot.r" in by_name:
            add_rot("foot.r", times, [(0.18 * max(0.0, -gait(u)), 0.0, 0.0) for u in us])

        # Arms — hang at sides, swing forward/back opposite same-side leg
        add_rot(
            "arm_stretch.l",
            times,
            [vadd(ARM_DOWN_L, (0.0, 0.30 * gait(u, math.pi), 0.04)) for u in us],
        )
        add_rot(
            "arm_stretch.r",
            times,
            [vadd(ARM_DOWN_R, (0.0, -0.30 * gait(u, math.pi), -0.04)) for u in us],
        )
        add_rot(
            "forearm_stretch.l",
            times,
            [vadd(FOREARM_RELAX_L, (-0.12 * max(0.0, gait(u, math.pi)), 0.0, 0.0)) for u in us],
        )
        add_rot(
            "forearm_stretch.r",
            times,
            [vadd(FOREARM_RELAX_R, (-0.12 * max(0.0, gait(u)), 0.0, 0.0)) for u in us],
        )

        # Subtle torso counter-rotation + vertical bob (2 bounces / cycle)
        add_rot(
            "spine_01.x",
            times,
            [(0.015 * gait(u, 0.3), 0.07 * gait(u), 0.0) for u in us],
        )
        add_rot(
            "spine_02.x",
            times,
            [(0.0, 0.04 * gait(u, math.pi), 0.0) for u in us],
        )
        add_rot(
            "head.x",
            times,
            [(0.0, -0.04 * gait(u), 0.0) for u in us],
        )
        if "root.x" in by_name:
            add_trans(
                "root.x",
                times,
                [(0.0, 0.018 * abs(math.sin(u * math.pi * 4)), 0.0) for u in us],
            )

    elif name == "typing":
        duration = 1.2
        times = sample_times(duration, fps=36)
        us = [ti / duration for ti in times]
        # Arms down + forward toward keyboard
        add_rot("arm_stretch.l", times, [vadd(ARM_DOWN_L, (-0.55, 0.35, -0.25)) for _ in us])
        add_rot("arm_stretch.r", times, [vadd(ARM_DOWN_R, (-0.55, -0.35, 0.25)) for _ in us])
        add_rot(
            "forearm_stretch.l",
            times,
            [vadd(FOREARM_RELAX_L, (-0.55 + 0.08 * math.sin(u * math.pi * 2 * 5), 0.0, 0.05)) for u in us],
        )
        add_rot(
            "forearm_stretch.r",
            times,
            [vadd(FOREARM_RELAX_R, (-0.55 + 0.08 * math.sin(u * math.pi * 2 * 5 + 1.2), 0.0, -0.05)) for u in us],
        )
        add_rot("spine_03.x", times, [(0.12, 0.0, 0.0) for _ in us])
        add_rot(
            "head.x",
            times,
            [(0.22 + 0.02 * math.sin(u * math.pi * 2), 0.03 * math.sin(u * math.pi * 2 * 0.7), 0.0) for u in us],
        )
        legs_rest(times)
        for side, phase0 in (("l", 0.0), ("r", 1.1)):
            for finger, phase in (
                ("index", 0.0),
                ("middle", 0.7),
                ("ring", 1.4),
                ("pinky", 2.1),
            ):
                for joint, amp in (("1", 0.5), ("2", 0.7), ("3", 0.55)):
                    bone = f"{finger}{joint}.{side}"
                    add_rot(
                        bone,
                        times,
                        [(finger_curl(u, phase0 + phase, amp), 0.0, 0.0) for u in us],
                    )

    elif name == "working":
        duration = 2.0
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        add_rot(
            "arm_stretch.r",
            times,
            [vadd(ARM_DOWN_R, (-0.35, -0.2, 0.15 + 0.12 * math.sin(u * math.pi * 2))) for u in us],
        )
        add_rot(
            "forearm_stretch.r",
            times,
            [vadd(FOREARM_RELAX_R, (-0.35 + 0.12 * math.sin(u * math.pi * 2 + 0.5), 0.0, 0.0)) for u in us],
        )
        add_rot("arm_stretch.l", times, [vadd(ARM_DOWN_L, (-0.25, 0.15, -0.1)) for _ in us])
        add_rot("forearm_stretch.l", times, [FOREARM_RELAX_L for _ in us])
        add_rot(
            "head.x",
            times,
            [(0.08 * math.sin(u * math.pi * 2), 0.1 * math.sin(u * math.pi * 2 * 0.5), 0.0) for u in us],
        )
        add_rot("spine_02.x", times, [(0.05, 0.04 * math.sin(u * math.pi * 2 * 0.5), 0.0) for u in us])
        legs_rest(times)

    elif name == "thinking":
        duration = 2.5
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        add_rot("arm_stretch.r", times, [vadd(ARM_DOWN_R, (-0.9, -0.55, 0.55)) for _ in us])
        add_rot("forearm_stretch.r", times, [(-1.5, 0.25, -0.2) for _ in us])
        add_rot("hand.r", times, [(0.25, 0.35, 0.35) for _ in us])
        add_rot("arm_stretch.l", times, [vadd(ARM_DOWN_L, (0.05, 0.0, 0.05)) for _ in us])
        add_rot("forearm_stretch.l", times, [FOREARM_RELAX_L for _ in us])
        add_rot(
            "head.x",
            times,
            [(0.15, 0.2 + 0.05 * math.sin(u * math.pi * 2 * 0.4), 0.08) for u in us],
        )
        add_rot("spine_03.x", times, [(0.05, 0.08, 0.0) for _ in us])
        legs_rest(times)

    elif name == "talking":
        duration = 1.6
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        add_rot(
            "head.x",
            times,
            [(0.08 * math.sin(u * math.pi * 2 * 2.2), 0.06 * math.sin(u * math.pi * 2), 0.0) for u in us],
        )
        add_rot(
            "arm_stretch.r",
            times,
            [vadd(ARM_DOWN_R, (-0.25, -0.15, 0.2 + 0.18 * math.sin(u * math.pi * 2))) for u in us],
        )
        add_rot(
            "forearm_stretch.r",
            times,
            [vadd(FOREARM_RELAX_R, (-0.2 + 0.15 * math.sin(u * math.pi * 2 + 0.3), 0.0, 0.0)) for u in us],
        )
        add_rot("arm_stretch.l", times, [vadd(ARM_DOWN_L, (0.0, 0.0, 0.0)) for _ in us])
        add_rot("forearm_stretch.l", times, [FOREARM_RELAX_L for _ in us])
        add_rot("spine_02.x", times, [(0.02 * math.sin(u * math.pi * 2), 0.0, 0.0) for u in us])
        legs_rest(times)

    elif name == "waiting":
        duration = 3.0
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        arms_down(times)
        add_rot(
            "spine_01.x",
            times,
            [(0.0, 0.0, 0.05 * math.sin(u * math.pi * 2 * 0.35)) for u in us],
        )
        add_rot(
            "head.x",
            times,
            [(0.02, 0.25 * math.sin(u * math.pi * 2 * 0.25), 0.0) for u in us],
        )
        add_rot(
            "thigh_stretch.l",
            times,
            [(0.03 * math.sin(u * math.pi * 2 * 0.35), 0.0, 0.0) for u in us],
        )
        add_rot(
            "thigh_stretch.r",
            times,
            [(-0.03 * math.sin(u * math.pi * 2 * 0.35), 0.0, 0.0) for u in us],
        )
        add_rot("leg_stretch.l", times, [LEG_REST for _ in times])
        add_rot("leg_stretch.r", times, [LEG_REST for _ in times])

    elif name == "blocked":
        duration = 1.0
        times = sample_times(duration, fps=36)
        us = [ti / duration for ti in times]
        add_rot("head.x", times, [(0.05, 0.18 * math.sin(u * math.pi * 2 * 3), 0.0) for u in us])
        add_rot("arm_stretch.l", times, [vadd(ARM_DOWN_L, (0.15, 0.1, 0.2)) for _ in us])
        add_rot("arm_stretch.r", times, [vadd(ARM_DOWN_R, (0.15, -0.1, -0.2)) for _ in us])
        add_rot("forearm_stretch.l", times, [FOREARM_RELAX_L for _ in us])
        add_rot("forearm_stretch.r", times, [FOREARM_RELAX_R for _ in us])
        add_rot("spine_02.x", times, [(0.08, 0.0, 0.0) for _ in us])
        legs_rest(times)

    elif name == "celebrating":
        duration = 1.2
        times = sample_times(duration, fps=36)
        us = [ti / duration for ti in times]
        # Arms up from T-pose (raise further), not arms-down
        add_rot(
            "arm_stretch.l",
            times,
            [(-1.1 + 0.12 * math.sin(u * math.pi * 2 * 2), 0.25, 0.35) for u in us],
        )
        add_rot(
            "arm_stretch.r",
            times,
            [(-1.1 + 0.12 * math.sin(u * math.pi * 2 * 2 + math.pi), -0.25, -0.35) for u in us],
        )
        add_rot("forearm_stretch.l", times, [(-0.35, 0.0, 0.0) for _ in us])
        add_rot("forearm_stretch.r", times, [(-0.35, 0.0, 0.0) for _ in us])
        if "root.x" in by_name:
            add_trans(
                "root.x",
                times,
                [(0.0, 0.1 * abs(math.sin(u * math.pi * 2 * 2)), 0.0) for u in us],
            )
        add_rot("spine_01.x", times, [(-0.08, 0.08 * math.sin(u * math.pi * 2 * 2), 0.0) for u in us])
        add_rot("head.x", times, [(-0.1, 0.0, 0.0) for _ in us])
        legs_rest(times)

    elif name == "away":
        duration = 3.0
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        add_rot("spine_02.x", times, [(0.18, 0.0, 0.0) for _ in us])
        add_rot("spine_03.x", times, [(0.12, 0.0, 0.0) for _ in us])
        add_rot("head.x", times, [(0.25, 0.15, 0.0) for _ in us])
        arms_down(times, l_extra=(0.1, 0.0, 0.08), r_extra=(0.1, 0.0, -0.08))
        add_rot("spine_01.x", times, [(0.02 * math.sin(u * math.pi * 2 * 0.3), 0.0, 0.0) for u in us])
        legs_rest(times)

    elif name == "offline":
        duration = 2.0
        times = sample_times(duration, fps=12)
        add_rot("spine_02.x", times, [(0.05, 0.0, 0.0) for _ in times])
        add_rot("head.x", times, [(0.1, 0.0, 0.0) for _ in times])
        arms_down(times)
        legs_rest(times)

    elif name == "reviewing":
        duration = 2.4
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        add_rot("spine_03.x", times, [(0.18, 0.0, 0.0) for _ in us])
        add_rot(
            "head.x",
            times,
            [(0.35, 0.3 * math.sin(u * math.pi * 2 * 0.4), 0.0) for u in us],
        )
        add_rot("arm_stretch.l", times, [vadd(ARM_DOWN_L, (-0.35, 0.2, -0.15)) for _ in us])
        add_rot("arm_stretch.r", times, [vadd(ARM_DOWN_R, (-0.3, -0.15, 0.1)) for _ in us])
        add_rot("forearm_stretch.l", times, [FOREARM_RELAX_L for _ in us])
        add_rot(
            "forearm_stretch.r",
            times,
            [vadd(FOREARM_RELAX_R, (-0.25 + 0.05 * math.sin(u * math.pi * 2), 0.0, 0.0)) for u in us],
        )
        legs_rest(times)

    elif name == "learning":
        duration = 2.2
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        add_rot("spine_03.x", times, [(0.1, 0.0, 0.0) for _ in us])
        add_rot(
            "head.x",
            times,
            [
                (
                    0.12 + 0.06 * math.sin(u * math.pi * 2 * 0.6),
                    0.08 * math.sin(u * math.pi * 2 * 0.3),
                    0.0,
                )
                for u in us
            ],
        )
        add_rot("arm_stretch.l", times, [vadd(ARM_DOWN_L, (-0.4, 0.25, -0.2)) for _ in us])
        add_rot("arm_stretch.r", times, [vadd(ARM_DOWN_R, (-0.4, -0.25, 0.2)) for _ in us])
        add_rot(
            "forearm_stretch.l",
            times,
            [vadd(FOREARM_RELAX_L, (-0.25 + 0.06 * math.sin(u * math.pi * 2 * 2), 0.0, 0.0)) for u in us],
        )
        add_rot(
            "forearm_stretch.r",
            times,
            [vadd(FOREARM_RELAX_R, (-0.25 + 0.06 * math.sin(u * math.pi * 2 * 2 + 1.0), 0.0, 0.0)) for u in us],
        )
        legs_rest(times)

    elif name == "requesting_approval":
        duration = 1.8
        times = sample_times(duration)
        us = [ti / duration for ti in times]
        add_rot(
            "arm_stretch.r",
            times,
            [(-0.9 + 0.1 * math.sin(u * math.pi * 2 * 1.5), -0.2, -0.35) for u in us],
        )
        add_rot(
            "forearm_stretch.r",
            times,
            [(-0.25, 0.0, 0.2 * math.sin(u * math.pi * 2 * 1.5)) for u in us],
        )
        add_rot("hand.r", times, [(0.0, 0.0, 0.15 * math.sin(u * math.pi * 2 * 1.5)) for u in us])
        add_rot("arm_stretch.l", times, [vadd(ARM_DOWN_L, (0.0, 0.0, 0.0)) for _ in us])
        add_rot("forearm_stretch.l", times, [FOREARM_RELAX_L for _ in us])
        add_rot("head.x", times, [(-0.05, 0.1 * math.sin(u * math.pi * 2 * 0.5), 0.0) for u in us])
        legs_rest(times)

    else:
        return None

    if not channels:
        print(f"warning: clip {name!r} produced no channels (bones missing?)", file=sys.stderr)
        return None

    return {"name": name, "channels": channels, "samplers": samplers}


def strip_existing_clips(gltf: dict[str, Any]) -> None:
    """Remove previously baked AgentVisualState clips so re-runs are idempotent."""
    anims = gltf.get("animations") or []
    keep = [a for a in anims if a.get("name") not in CLIP_NAMES]
    gltf["animations"] = keep


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("-o", "--output", type=Path, default=None)
    args = parser.parse_args()
    out = args.output or args.input

    gltf, bin_blob = load_glb(args.input)
    nodes = gltf.get("nodes") or []
    by_name = node_index_by_name(nodes)

    required = ["spine_02.x", "arm_stretch.l", "thigh_stretch.l", "head.x"]
    missing = [n for n in required if n not in by_name]
    if missing:
        raise SystemExit(f"missing required bones: {missing}")

    strip_existing_clips(gltf)
    # Ensure single buffer
    buffers = gltf.setdefault("buffers", [{"byteLength": len(bin_blob)}])
    if not buffers:
        buffers.append({"byteLength": len(bin_blob)})

    builder = BufferBuilder(bin_blob)
    animations = gltf.setdefault("animations", [])
    baked = 0
    for clip in CLIP_NAMES:
        anim = build_clip(clip, gltf, builder, nodes, by_name)
        if anim:
            animations.append(anim)
            baked += 1

    buffers[0]["byteLength"] = len(builder.data)
    write_glb(out, gltf, bytes(builder.data))

    # Verify
    verify, _ = load_glb(out)
    names = [a.get("name") for a in verify.get("animations", [])]
    print(f"Wrote {out} ({out.stat().st_size} bytes)")
    print(f"Baked {baked}/{len(CLIP_NAMES)} clips: {names}")


if __name__ == "__main__":
    main()
