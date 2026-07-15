"""
Dump lights, camera, and world settings from office.blend to JSON.

Run:
  blender -b office.blend -P scripts/dump_blender_lights.py
"""

from __future__ import annotations

import json
import math
import os
import sys

import bpy
from mathutils import Vector


OUT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "scratchpad",
    "blender_scene.json",
)


def mat4_list(m):
    return [[float(m[r][c]) for c in range(4)] for r in range(4)]


def vec3(v):
    return [float(v.x), float(v.y), float(v.z)]


def dump_light(obj):
    data = obj.data
    loc, rot, scale = obj.matrix_world.decompose()
    # Blender light local -Z is the forward direction.
    direction = (obj.matrix_world.to_3x3() @ Vector((0.0, 0.0, -1.0))).normalized()
    entry = {
        "name": obj.name,
        "type": data.type,  # POINT, SUN, SPOT, AREA
        "location": vec3(loc),
        "rotation_euler": [float(a) for a in rot.to_euler("XYZ")],
        "direction": vec3(direction),
        "scale": vec3(scale),
        "matrix_world": mat4_list(obj.matrix_world),
        "color": [float(c) for c in data.color],
        "energy": float(data.energy),
        "specular_factor": float(getattr(data, "specular_factor", 1.0)),
    }
    if data.type == "AREA":
        entry["shape"] = data.shape
        entry["size"] = float(data.size)
        entry["size_y"] = float(getattr(data, "size_y", data.size))
    if data.type == "SPOT":
        entry["spot_size"] = float(data.spot_size)
        entry["spot_blend"] = float(data.spot_blend)
    if data.type == "POINT":
        entry["shadow_soft_size"] = float(getattr(data, "shadow_soft_size", 0.0))
    return entry


def dump_camera(obj):
    data = obj.data
    loc, rot, scale = obj.matrix_world.decompose()
    # Camera looks along local -Z.
    forward = (obj.matrix_world.to_3x3() @ Vector((0.0, 0.0, -1.0))).normalized()
    up = (obj.matrix_world.to_3x3() @ Vector((0.0, 1.0, 0.0))).normalized()
    sensor = float(data.sensor_width)
    lens = float(data.lens)
    # Vertical FOV approximation from horizontal lens / sensor (degrees).
    fov_h = 2.0 * math.atan((sensor / 2.0) / lens)
    aspect = 16.0 / 9.0
    fov_v = 2.0 * math.atan(math.tan(fov_h / 2.0) / aspect)
    return {
        "name": obj.name,
        "type": data.type,  # PERSP / ORTHO / PANO
        "location": vec3(loc),
        "rotation_euler": [float(a) for a in rot.to_euler("XYZ")],
        "forward": vec3(forward),
        "up": vec3(up),
        "matrix_world": mat4_list(obj.matrix_world),
        "lens": lens,
        "sensor_width": sensor,
        "sensor_height": float(data.sensor_height),
        "ortho_scale": float(data.ortho_scale),
        "clip_start": float(data.clip_start),
        "clip_end": float(data.clip_end),
        "fov_horizontal_rad": fov_h,
        "fov_vertical_rad": fov_v,
    }


def dump_world():
    world = bpy.context.scene.world
    if world is None:
        return {"color": [0, 0, 0], "strength": 0.0}
    # Prefer background node if present.
    if world.use_nodes and world.node_tree:
        for node in world.node_tree.nodes:
            if node.type == "BACKGROUND":
                col = node.inputs["Color"].default_value
                return {
                    "color": [float(col[0]), float(col[1]), float(col[2])],
                    "strength": float(node.inputs["Strength"].default_value),
                }
    col = world.color
    return {"color": [float(col[0]), float(col[1]), float(col[2])], "strength": 1.0}


def main():
    lights = []
    cameras = []
    for obj in bpy.data.objects:
        if obj.type == "LIGHT":
            lights.append(dump_light(obj))
        elif obj.type == "CAMERA":
            cameras.append(dump_camera(obj))

    scene = bpy.context.scene
    active_cam = scene.camera.name if scene.camera else None
    view = {
        "engine": scene.render.engine,
        "resolution_x": int(scene.render.resolution_x),
        "resolution_y": int(scene.render.resolution_y),
        "resolution_percentage": int(scene.render.resolution_percentage),
        "fps": float(scene.render.fps),
    }

    # Eevee bloom settings when available.
    bloom = {}
    try:
        eevee = scene.eevee
        bloom = {
            "use_bloom": bool(getattr(eevee, "use_bloom", False)),
            "bloom_threshold": float(getattr(eevee, "bloom_threshold", 0.8)),
            "bloom_intensity": float(getattr(eevee, "bloom_intensity", 0.05)),
            "bloom_radius": float(getattr(eevee, "bloom_radius", 6.5)),
            "bloom_knee": float(getattr(eevee, "bloom_knee", 0.5)),
            "bloom_clamp": float(getattr(eevee, "bloom_clamp", 0.0)),
        }
    except Exception as exc:  # noqa: BLE001
        bloom = {"error": str(exc)}

    payload = {
        "blender_version": list(bpy.app.version),
        "active_camera": active_cam,
        "render": view,
        "eevee_bloom": bloom,
        "world": dump_world(),
        "lights": lights,
        "cameras": cameras,
    }

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)

    print(f"[dump_blender_lights] wrote {OUT_PATH}")
    print(f"  lights={len(lights)} cameras={len(cameras)} active={active_cam}")
    for L in lights:
        print(
            f"  LIGHT {L['type']:5} {L['name']!r:30} energy={L['energy']:.3f} "
            f"loc={[round(x, 3) for x in L['location']]} color={L['color']}"
        )
    for C in cameras:
        print(
            f"  CAM   {C['type']:5} {C['name']!r:30} lens={C['lens']} "
            f"loc={[round(x, 3) for x in C['location']]} fov_v={C['fov_vertical_rad']:.3f}"
        )


if __name__ == "__main__":
    main()
    # Exit blender after script in background mode.
    if bpy.app.background:
        sys.exit(0)
