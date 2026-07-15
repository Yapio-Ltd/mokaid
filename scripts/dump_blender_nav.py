"""
Dump walkable surfaces, obstacles, desk slots and named POIs from office.blend.

Run:
  blender --background office.blend --python scripts/dump_blender_nav.py

Writes scratchpad/blender_nav.json (Blender Z-up world space).
"""

from __future__ import annotations

import json
import math
import os
from pathlib import Path

import bpy
from mathutils import Vector

OUT = Path(os.environ.get("MOKAID_NAV_OUT", "scratchpad/blender_nav.json"))
POI_PREFIXES = ("POI_", "poi_")
DESK_PREFIXES = ("DESK_", "desk_", "Seat_", "seat_")
FLOOR_HINTS = ("floor", "sol", "plancher", "base")
OBSTACLE_HINTS = (
    "table",
    "desk",
    "chair",
    "sofa",
    "wall",
    "cupboard",
    "cabinet",
    "plant",
    "monitor",
    "printer",
    "foosball",
    "soccer",
    "partition",
)


def bl_to_gltf(v: Vector) -> list[float]:
    """Blender Z-up → glTF Y-up: (x, y, z) → (x, z, -y)."""
    return [float(v.x), float(v.z), float(-v.y)]


def mesh_world_bounds(obj) -> dict | None:
    if obj.type != "MESH" or obj.data is None:
        return None
    coords = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    xs = [c.x for c in coords]
    ys = [c.y for c in coords]
    zs = [c.z for c in coords]
    return {
        "name": obj.name,
        "min": bl_to_gltf(Vector((min(xs), min(ys), min(zs)))),
        "max": bl_to_gltf(Vector((max(xs), max(ys), max(zs)))),
        "center": bl_to_gltf(Vector(((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, (min(zs) + max(zs)) / 2))),
    }


def collect_empties(prefix_tuple: tuple[str, ...]) -> list[dict]:
    items = []
    for obj in bpy.data.objects:
        if obj.type != "EMPTY" and not obj.name.startswith(prefix_tuple):
            # Also accept empties or meshes whose name starts with the prefix.
            if not any(obj.name.startswith(p) for p in prefix_tuple):
                continue
        if not any(obj.name.startswith(p) for p in prefix_tuple):
            continue
        loc = obj.matrix_world.translation
        # Facing from object's -Y in Blender (forward) converted to glTF XZ.
        forward = obj.matrix_world.to_3x3() @ Vector((0, -1, 0))
        facing = math.atan2(float(forward.x), float(-forward.y))
        items.append(
            {
                "name": obj.name,
                "position": bl_to_gltf(loc),
                "facing": facing,
            }
        )
    return items


def main() -> None:
    floors = []
    obstacles = []
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        name_l = obj.name.lower()
        bounds = mesh_world_bounds(obj)
        if not bounds:
            continue
        if any(h in name_l for h in FLOOR_HINTS):
            floors.append(bounds)
        elif any(h in name_l for h in OBSTACLE_HINTS):
            # Inflate slightly in XZ for agent radius (~0.35 m).
            pad = 0.35
            mn, mx = bounds["min"], bounds["max"]
            obstacles.append(
                {
                    **bounds,
                    "min": [mn[0] - pad, mn[1], mn[2] - pad],
                    "max": [mx[0] + pad, mx[1], mx[2] + pad],
                }
            )

    data = {
        "floors": floors,
        "obstacles": obstacles,
        "pois": collect_empties(POI_PREFIXES),
        "desks": collect_empties(DESK_PREFIXES),
        "note": "Coordinates are glTF/Babylon Y-up. OfficeScene still subtracts AABB center.",
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, indent=2))
    print(f"Wrote {OUT} floors={len(floors)} obstacles={len(obstacles)} pois={len(data['pois'])} desks={len(data['desks'])}")


if __name__ == "__main__":
    main()
