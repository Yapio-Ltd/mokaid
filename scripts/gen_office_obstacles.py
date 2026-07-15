#!/usr/bin/env python3
"""
Generate the complete OFFICE_OBSTACLES list from scratchpad/blender_obstacles.json.

Keeps every physical box (raw, uninflated — runtime applies clearance):
- drops desktop clutter fully contained (2D) in a bigger furniture box,
- drops boxes fully contained in another box,
- rounds to cm.

Usage: python3 scripts/gen_office_obstacles.py > snippet
"""

from __future__ import annotations

import json
from pathlib import Path

SRC = Path("scratchpad/blender_obstacles.json")


def contains_2d(outer: dict, inner: dict, eps: float = 0.01) -> bool:
    return (
        outer["minX"] - eps <= inner["minX"] and outer["maxX"] + eps >= inner["maxX"]
        and outer["minZ"] - eps <= inner["minZ"] and outer["maxZ"] + eps >= inner["maxZ"]
    )


def main() -> None:
    raw = json.loads(SRC.read_text())["obstacles"]

    kept: list[dict] = []
    for b in sorted(raw, key=lambda x: -(x["maxX"] - x["minX"]) * (x["maxZ"] - x["minZ"])):
        # Desktop clutter riding on furniture already blocked: drop.
        if b["minY"] > 0.6 and any(contains_2d(k, b) for k in kept):
            continue
        if any(contains_2d(k, b) for k in kept):
            continue
        kept.append(b)

    kept.sort(key=lambda b: (round(b["minX"], 2), round(b["minZ"], 2)))
    lines = []
    for b in kept:
        lines.append(
            f'  {{ minX: {b["minX"]:.2f}, maxX: {b["maxX"]:.2f}, '
            f'minZ: {b["minZ"]:.2f}, maxZ: {b["maxZ"]:.2f} }}, // {b["name"]}'
        )
    out = "export const OFFICE_OBSTACLES: Aabb2[] = [\n" + "\n".join(lines) + "\n];\n"
    Path("scratchpad/office_obstacles_generated.ts").write_text(out)
    print(f"raw={len(raw)} kept={len(kept)}")
    print("Wrote scratchpad/office_obstacles_generated.ts")


if __name__ == "__main__":
    main()
