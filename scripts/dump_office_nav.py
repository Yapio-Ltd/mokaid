"""
Regenerate the office navigation data from office.blend.

    blender --background office.blend --python scripts/dump_office_nav.py

Writes TypeScript-ready blocks to scripts/out/office_nav.txt: the obstacle
table, the desk-chair seats and the measured seat heights. Paste them into
apps/web/src/three/office-navdata.ts.

AXIS CONVENTION — the important part. The glTF exporter mirrors Blender's X
axis, so a Blender coordinate maps to the scene frame as:

    sceneX = -blenderX,  sceneY = blenderZ,  sceneZ = -blenderY

Getting this wrong (using +blenderX) puts every obstacle, desk and POI on the
opposite side of the room while still looking plausible: the office footprint
is nearly symmetric, so the data validates fine and only the render disagrees.
Verify after regenerating by dropping markers at known furniture:

    window.__mokaidOfficeMark(-2.27, 4.13, "#ff0000")   // foosball corner

If the pillar does not land on the table, the mirror is wrong.

Obstacles cover only geometry intersecting an agent's body slab
(AGENT_LOW..AGENT_HIGH); rugs underfoot and ceiling lamps are skipped so they
do not block aisles. Room-shell walls are rasterised separately, which keeps
door openings walkable.
"""

import json
import math
import os
import sys

import bpy

# Body slab an agent actually has to clear, in metres above the floor.
AGENT_LOW = 0.10
AGENT_HIGH = 1.75
# Rasteriser resolution for the wall shell.
CELL = 0.10
# Meshes forming the room shell (walls + floor); rasterised, not boxed.
SHELL_NAMES = {"Plane.005", "Plane"}

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


def scene_bounds(inst, mesh):
    """World-space bounds of one evaluated instance, in scene axes."""
    mw = inst.matrix_world
    xs, ys, zs = [], [], []
    for v in mesh.vertices:
        w = mw @ v.co
        xs.append(-w.x)  # mirror: sceneX = -blenderX
        ys.append(w.z)  # sceneY = blenderZ
        zs.append(-w.y)  # sceneZ = -blenderY
    return (min(xs), max(xs)), (min(ys), max(ys)), (min(zs), max(zs))


def collect():
    deps = bpy.context.evaluated_depsgraph_get()
    objects = []
    for inst in deps.object_instances:
        ob = inst.object
        if ob.type != "MESH":
            continue
        try:
            me = ob.to_mesh()
        except RuntimeError:
            continue
        if me is None or len(me.vertices) == 0:
            ob.to_mesh_clear()
            continue
        (x0, x1), (y0, y1), (z0, z1) = scene_bounds(inst, me)
        ob.to_mesh_clear()
        objects.append(
            {
                "name": ob.name,
                "minX": x0,
                "maxX": x1,
                "minY": y0,
                "maxY": y1,
                "minZ": z0,
                "maxZ": z1,
            }
        )
    return objects


def obstacle_rows(objects):
    rows = []
    for o in objects:
        if o["name"] in SHELL_NAMES:
            continue
        if o["maxY"] < AGENT_LOW:  # rug / floor decal
            continue
        if o["minY"] > AGENT_HIGH:  # ceiling lamp, high wall art
            continue
        w = o["maxX"] - o["minX"]
        d = o["maxZ"] - o["minZ"]
        if w < 0.03 or d < 0.03 or w * d < 0.015:
            continue  # trinkets an agent walks past
        rows.append(o)
    rows.sort(key=lambda r: (r["minX"], r["minZ"]))
    return rows


def wall_rects(objects):
    """
    Rasterise the room shell into boxes, keeping door openings open.

    The shell meshes are single planes with holes cut for the doors, so their
    bounding box is the whole room — useless as an obstacle. Instead sample a
    grid, mark a cell when shell geometry occupies the agent's body slab there,
    then merge the marked cells back into rectangles.
    """
    deps = bpy.context.evaluated_depsgraph_get()
    furniture = [o for o in objects if o["name"] not in SHELL_NAMES]
    cells = set()

    for inst in deps.object_instances:
        ob = inst.object
        # Rasterise *everything*, not just the shell: walls in this file are
        # split across many meshes (partitions, door frames, the glazed
        # meeting-room front), and only the union of them draws the real
        # boundary. Cells already covered by a furniture box are dropped below.
        if ob.type != "MESH":
            continue
        try:
            me = ob.to_mesh()
        except RuntimeError:
            continue
        if me is None:
            ob.to_mesh_clear()
            continue
        mw = inst.matrix_world
        for poly in me.polygons:
            vs = [mw @ me.vertices[i].co for i in poly.vertices]
            ys = [v.z for v in vs]
            if max(ys) < AGENT_LOW or min(ys) > AGENT_HIGH:
                continue  # floor underfoot or ceiling overhead
            xs = [-v.x for v in vs]
            zs = [-v.y for v in vs]
            i0 = int(math.floor(min(xs) / CELL))
            i1 = int(math.ceil(max(xs) / CELL))
            j0 = int(math.floor(min(zs) / CELL))
            j1 = int(math.ceil(max(zs) / CELL))
            for i in range(i0, i1 + 1):
                for j in range(j0, j1 + 1):
                    cells.add((i, j))
        ob.to_mesh_clear()

    # Drop cells already covered by a furniture box so walls do not duplicate
    # obstacles that are listed individually.
    def covered(i, j):
        x, z = i * CELL, j * CELL
        return any(
            f["minX"] - 0.02 <= x <= f["maxX"] + 0.02
            and f["minZ"] - 0.02 <= z <= f["maxZ"] + 0.02
            for f in furniture
        )

    cells = {c for c in cells if not covered(*c)}

    rects, remaining = [], set(cells)
    while remaining:
        i, j = min(remaining)
        w = 0
        while (i + w, j) in remaining:
            w += 1
        h = 1
        while all((i + k, j + h) in remaining for k in range(w)):
            h += 1
        for k in range(w):
            for m in range(h):
                remaining.discard((i + k, j + m))
        rect = (
            i * CELL - CELL / 2,
            (i + w - 1) * CELL + CELL / 2,
            j * CELL - CELL / 2,
            (j + h - 1) * CELL + CELL / 2,
        )
        if (rect[1] - rect[0]) * (rect[3] - rect[2]) >= 0.04:
            rects.append(rect)
    return sorted(rects)


def main():
    objects = collect()
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, "office_nav.txt")

    with open(out, "w") as f:
        f.write("// --- OFFICE_OBSTACLES: furniture ---\n")
        for o in obstacle_rows(objects):
            f.write(
                "  { minX: %.2f, maxX: %.2f, minZ: %.2f, maxZ: %.2f }, // %s\n"
                % (o["minX"], o["maxX"], o["minZ"], o["maxZ"], o["name"])
            )
        f.write("\n// --- OFFICE_OBSTACLES: wall segments (door openings preserved) ---\n")
        for x0, x1, z0, z1 in wall_rects(objects):
            f.write("  { minX: %.2f, maxX: %.2f, minZ: %.2f, maxZ: %.2f }, // wall\n" % (x0, x1, z0, z1))

        f.write("\n// --- desk chairs (Object_122*) — pick nine and pair with a desk ---\n")
        for o in objects:
            if not o["name"].startswith("Object_122"):
                continue
            f.write(
                "  // %s centre=(%.3f, %.3f) seatTop=%.2f\n"
                % (o["name"], (o["minX"] + o["maxX"]) / 2, (o["minZ"] + o["maxZ"]) / 2, o["maxY"])
            )

    json.dump(objects, open(os.path.join(OUT_DIR, "office_objects.json"), "w"))
    print("wrote %s (%d objects)" % (out, len(objects)), file=sys.stderr)


main()
